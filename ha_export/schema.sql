-- Home Assistant long-term statistics mirror.
--
-- Follows the pattern established by the `oura` schema: one schema per data
-- source inside the shared `garbanzodb`, owned by a dedicated least-privilege
-- role rather than the shared `garbanzo` superuser.
--
-- DESIGN: this table is a FIELD-FOR-FIELD mirror of the selected statistics,
-- not a byte-for-byte copy. HA's internal `id`, `metadata_id` and `created_ts`
-- are deliberately omitted -- they are implementation detail and are not
-- stable across a recorder rebuild.
--
-- NO DERIVED COLUMNS LIVE HERE. Energy deltas, coverage intervals and quality
-- flags are functions of these observations and are computed in
-- reporting_schema.sql. Storing them would break reconciliation, which
-- compares every column of this table against SQLite without exclusions.
--
-- Idempotent: safe to re-run.

-- Required by the grain-period exclusion constraint below. Creating an
-- extension is a superuser-level act, so this file must be run as `garbanzo`,
-- NOT as ha_sync.
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE SCHEMA IF NOT EXISTS homeassistant;


-- ---------------------------------------------------------------------------
-- Catalog: the selection contract, and the ONLY home for metric metadata.
--
-- Metadata is deliberately not stored per fact row. HA keeps a single current
-- statistics_meta row per statistic and attaches no historical snapshot, so
-- per-row copies would record *when a row was synced* rather than any real
-- historical distinction. If a unit ever changes, the correct response is a
-- full reimport of that statistic.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS homeassistant.metric_catalog (
    statistic_id        text PRIMARY KEY,
    category            text NOT NULL CHECK (category IN (
                            'environmental_temperature', 'machine_temperature',
                            'home_energy', 'device_energy', 'device_power')),
    display_name        text NOT NULL,
    source              text NOT NULL,
    unit_of_measurement text,
    unit_class          text,
    mean_type           smallint,
    has_sum             boolean NOT NULL DEFAULT false,
    energy_role         text CHECK (energy_role IN ('lifetime', 'cycle')),

    -- Plausibility ceiling as sustained average POWER, not energy. Multiplying
    -- by a bucket's duration yields its kWh ceiling, so a single value serves
    -- hourly, daily and billing-period grains alike.
    max_plausible_kw    double precision CHECK (max_plausible_kw > 0),

    default_grain       text NOT NULL DEFAULT 'hour'
                        CHECK (default_grain IN ('hour', 'day', 'billing_period')),
    is_active           boolean NOT NULL DEFAULT true,

    -- Set by the cadence audit when observed spacing stops matching the
    -- configured grain inside an open-ended period. Blocks further export
    -- for this metric until a human updates the reviewed ranges.
    grain_review_required boolean NOT NULL DEFAULT false,

    notes               text,

    -- energy_role is required for energy categories and forbidden elsewhere.
    CONSTRAINT energy_role_iff_energy CHECK (
        (category IN ('home_energy', 'device_energy')) = (energy_role IS NOT NULL)),
    CONSTRAINT ceiling_iff_energy CHECK (
        (category IN ('home_energy', 'device_energy')) = (max_plausible_kw IS NOT NULL))
);


-- ---------------------------------------------------------------------------
-- Reviewed grain ranges, for imported sources whose reporting grain changes.
--
-- INTERVAL CONVENTION: half-open, [valid_from, valid_until). A row matches
-- when valid_from <= start_at AND (valid_until IS NULL OR start_at < valid_until).
--
-- Grain is NEVER inferred from LEAD(start_at) - start_at: that measures the
-- spacing between observations, not the duration one represents, and it
-- misclassifies the last row before any outage.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS homeassistant.metric_grain_period (
    statistic_id text NOT NULL REFERENCES homeassistant.metric_catalog
                     ON DELETE CASCADE,
    valid_from   timestamptz NOT NULL,
    valid_until  timestamptz,
    grain        text NOT NULL CHECK (grain IN ('hour', 'day', 'billing_period')),

    CONSTRAINT grain_period_ordered CHECK (
        valid_until IS NULL OR valid_until > valid_from),
    PRIMARY KEY (statistic_id, valid_from),

    -- A PK on (statistic_id, valid_from) does NOT prevent overlapping ranges.
    -- This does. (Gaps between ranges are caught by seed validation, which a
    -- constraint cannot express.)
    CONSTRAINT grain_period_no_overlap EXCLUDE USING gist (
        statistic_id WITH =,
        tstzrange(valid_from, valid_until, '[)') WITH &&
    )
);


-- ---------------------------------------------------------------------------
-- The mirror.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS homeassistant.statistic (
    statistic_id  text NOT NULL REFERENCES homeassistant.metric_catalog,
    start_at      timestamptz NOT NULL,          -- always UTC
    grain         text NOT NULL CHECK (grain IN ('hour', 'day', 'billing_period')),

    mean          double precision,
    mean_weight   double precision,   -- mirrored; NULL for all metrics in HA 2026.7.2
    min           double precision,
    max           double precision,
    state         double precision,
    sum           double precision,
    last_reset_at timestamptz,

    synced_at     timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (statistic_id, start_at)
);

-- The PK already serves per-metric time-range queries. This index exists only
-- for cross-metric "everything in the last N days" scans; drop it if the API
-- never issues those.
CREATE INDEX IF NOT EXISTS statistic_start_idx
    ON homeassistant.statistic (start_at DESC);


-- ---------------------------------------------------------------------------
-- Reviewed overrides: which source_disagreement rows are trusted enough to
-- count toward billing totals. Kept as data, never hard-coded into a view.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS homeassistant.disagreement_review (
    statistic_id text NOT NULL,
    start_at     timestamptz NOT NULL,
    decision     text NOT NULL CHECK (decision IN ('accept_sum', 'accept_state', 'exclude')),
    reviewed_at  timestamptz NOT NULL DEFAULT now(),
    note         text,
    PRIMARY KEY (statistic_id, start_at),
    FOREIGN KEY (statistic_id, start_at)
        REFERENCES homeassistant.statistic (statistic_id, start_at) ON DELETE CASCADE
);


-- ---------------------------------------------------------------------------
-- Per-metric sync watermark: the newest source timestamp a successful run
-- actually observed for THIS metric.
--
-- Reconciliation needs it to compare like with like. Its snapshot is taken at
-- run time, so it always contains rows Home Assistant compiled after the last
-- sync; those are legitimately absent from the mirror and must not be reported
-- as missing. Both the source and destination streams are bounded by this
-- value, so the comparison domains are identical.
--
-- Per-metric rather than a single global maximum: a global one assumes every
-- statistic advances together within a Home Assistant compile pass, and a
-- metric that lagged would have its later rows compared against a mirror that
-- never had the chance to import them.
--
-- Derived state maintained by the sync runtime, NOT reviewed configuration --
-- which is why ha_sync may write it while it may not write the catalog.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS homeassistant.metric_watermark (
    statistic_id  text PRIMARY KEY
                  REFERENCES homeassistant.metric_catalog ON DELETE CASCADE,
    source_max_ts timestamptz NOT NULL,
    observed_at   timestamptz NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------------
-- Sync history. Pure history: concurrency is enforced by a PostgreSQL advisory
-- lock, NOT by a uniqueness constraint here.
--
-- A `UNIQUE INDEX ... WHERE status = 'running'` would block concurrent runs
-- correctly and then block ALL runs permanently after a SIGKILL or power loss,
-- since the row survives while the process does not. An advisory lock is
-- released by the server when the connection dies.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS homeassistant.sync_run (
    id               bigserial PRIMARY KEY,
    started_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz,
    mode             text NOT NULL CHECK (mode IN ('backfill', 'incremental', 'repair')),
    window_start     timestamptz,
    window_end       timestamptz,
    source_max_ts    timestamptz,

    rows_read        integer CHECK (rows_read      >= 0),
    rows_inserted    integer CHECK (rows_inserted  >= 0),
    rows_updated     integer CHECK (rows_updated   >= 0),
    rows_unchanged   integer CHECK (rows_unchanged >= 0),

    exporter_version text NOT NULL,
    schema_version   integer NOT NULL,
    ha_version       text,

    status           text NOT NULL DEFAULT 'running'
                     CHECK (status IN ('running', 'success', 'failed', 'abandoned')),
    error            text
);

CREATE INDEX IF NOT EXISTS sync_run_started_idx
    ON homeassistant.sync_run (started_at DESC);


-- ---------------------------------------------------------------------------
-- Roles.
--
-- Created NOLOGIN and WITHOUT a password, deliberately. An earlier version
-- used `LOGIN PASSWORD 'changeme-see-dot-env'`, which handed every fresh
-- deployment a working account with a password published in this repository --
-- while the comment above it claimed passwords were never committed.
--
-- The role cannot authenticate until an operator provisions it:
--     ALTER ROLE ha_sync LOGIN PASSWORD '<from .env>';
-- Until then a misconfigured deploy fails closed with an auth error rather
-- than succeeding with a public credential.
--
-- IMPORTANT: this fix only protects a role this file CREATES. The CREATE below
-- is guarded by IF NOT EXISTS, so re-running this file on a database that
-- already ran the vulnerable version leaves the published password in place.
-- Those databases need migrations/001_neutralize_published_password.sql, which
-- must be run explicitly. Applied to garbanzodb on piberry5 on 2026-08-11.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ha_sync') THEN
        CREATE ROLE ha_sync NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
        RAISE NOTICE 'Created role ha_sync (NOLOGIN). Provision it with: ALTER ROLE ha_sync LOGIN PASSWORD ''<from .env>'';';
    END IF;
END
$$;

ALTER ROLE ha_sync SET search_path TO homeassistant;

GRANT CONNECT ON DATABASE garbanzodb TO ha_sync;
GRANT USAGE ON SCHEMA homeassistant TO ha_sync;

-- Converge, don't just add. GRANT is purely additive, so a database that ran
-- an earlier version of this file would keep the blanket ALL TABLES grant
-- forever and the per-table grants below would be decoration. Revoke first.
REVOKE ALL ON ALL TABLES IN SCHEMA homeassistant FROM ha_sync;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA homeassistant FROM ha_sync;
ALTER DEFAULT PRIVILEGES IN SCHEMA homeassistant
    REVOKE ALL ON TABLES FROM ha_sync;
ALTER DEFAULT PRIVILEGES IN SCHEMA homeassistant
    REVOKE ALL ON SEQUENCES FROM ha_sync;

-- Per-table grants, not blanket ALL TABLES. The sync runtime writes facts and
-- its own run history; it must NOT be able to rewrite catalog membership,
-- grain ranges, or human disagreement decisions -- those are reviewed
-- configuration, and an ingest bug should not be able to edit them.
GRANT SELECT, INSERT, UPDATE ON homeassistant.statistic TO ha_sync;
GRANT SELECT, INSERT, UPDATE ON homeassistant.sync_run  TO ha_sync;
GRANT USAGE, SELECT ON SEQUENCE homeassistant.sync_run_id_seq TO ha_sync;

-- Derived state the runtime maintains, written in the same transaction as the
-- rows it describes.
GRANT SELECT, INSERT, UPDATE ON homeassistant.metric_watermark TO ha_sync;

GRANT SELECT ON homeassistant.metric_catalog       TO ha_sync;
GRANT SELECT ON homeassistant.metric_grain_period  TO ha_sync;
GRANT SELECT ON homeassistant.disagreement_review  TO ha_sync;

-- The single catalog field the runtime legitimately writes: the cadence audit
-- raising grain_review_required to halt export for a metric.
GRANT UPDATE (grain_review_required) ON homeassistant.metric_catalog TO ha_sync;

-- No ALTER DEFAULT PRIVILEGES: a future table should require a deliberate
-- grant rather than silently inheriting write access.

-- ha_sync has no business anywhere else in this database.
-- Revoked only where the schema actually exists. A bare REVOKE on a missing
-- schema raises, which aborts the rest of this file -- so on a fresh database
-- without the sibling applications, the grants below this point never ran.
-- Found by running schema.sql into an empty database rather than assuming.
DO $$
DECLARE s text;
BEGIN
    FOREACH s IN ARRAY ARRAY['oura', 'dancetrak', 'website', 'public'] LOOP
        IF EXISTS (SELECT FROM pg_namespace WHERE nspname = s) THEN
            EXECUTE format('REVOKE ALL ON SCHEMA %I FROM ha_sync', s);
        END IF;
    END LOOP;
END
$$;

-- NOTE: the loop above cannot remove USAGE on `public`. PostgreSQL grants
-- that via the PUBLIC pseudo-role and a per-role REVOKE cannot take back a
-- privilege held that way. The real boundary is at table level and holds:
-- ha_sync has SELECT on no table in `public` (where Vaultwarden stores its
-- vault) and CREATE on the schema is denied. Closing the schema-level hole
-- needs REVOKE USAGE ON SCHEMA public FROM PUBLIC, which is database-wide
-- and affects every other application -- a deliberate decision, not a side
-- effect of this project.
