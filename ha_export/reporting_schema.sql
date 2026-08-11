-- Read-only reporting layer over the Home Assistant statistics mirror.
--
-- Everything downstream -- the API, the dashboard, ad-hoc analysis -- reads
-- these views and never the ingest tables, so the pipeline underneath can
-- change without breaking consumers, and a compromised reader credential can
-- only ever SELECT from a curated surface.
--
-- Views are SPARSE: they project what is stored and nothing more. A view
-- cannot emit rows for buckets that do not exist. Gap filling is the API's
-- job, because only a request carries a start, end and bucket size.
--
-- All timestamps are UTC. Local time is applied only where a calendar day is
-- genuinely required (ha_energy_daily).
--
-- Idempotent: safe to re-run.

CREATE SCHEMA IF NOT EXISTS reporting;

-- COLUMN EVOLUTION IS APPEND-ONLY.
--
-- This file uses CREATE OR REPLACE VIEW throughout, which permits adding
-- columns at the END of a view's select list but not reordering, renaming, or
-- removing them. That restriction is accepted deliberately, because the
-- alternative is worse: an earlier revision used DROP VIEW ... CASCADE, which
-- would silently delete any future API view, function, or materialized view
-- built on these -- turning a routine re-apply into a destructive operation
-- and contradicting the "safe to re-run" promise above.
--
-- So: new columns go at the end. A change that genuinely requires reordering
-- or removing a column belongs in a numbered file under migrations/, which
-- recreates every known dependent explicitly, inside a single transaction,
-- and without CASCADE.


-- ---------------------------------------------------------------------------
-- Temperature, normalised to degrees Celsius.
--
-- Conversion happens HERE, not at ingest: the mirror stays a verifiable copy
-- of what HA recorded, so a bug in this expression can be fixed by replacing
-- a view rather than by re-importing history.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.ha_temperature AS
SELECT
    s.statistic_id,
    c.display_name,
    c.category,                              -- environmental_ vs machine_
    s.start_at,
    s.grain,
    CASE WHEN c.unit_of_measurement = '°F'
         THEN (s.mean - 32) * 5.0 / 9.0 ELSE s.mean END AS mean_c,
    CASE WHEN c.unit_of_measurement = '°F'
         THEN (s.min  - 32) * 5.0 / 9.0 ELSE s.min  END AS min_c,
    CASE WHEN c.unit_of_measurement = '°F'
         THEN (s.max  - 32) * 5.0 / 9.0 ELSE s.max  END AS max_c,
    c.unit_of_measurement AS source_unit,
    c.is_active
FROM homeassistant.statistic s
JOIN homeassistant.metric_catalog c USING (statistic_id)
WHERE c.category IN ('environmental_temperature', 'machine_temperature');


-- ---------------------------------------------------------------------------
-- Instantaneous power. Measurement statistics: mean/min/max are read
-- directly. Never summed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.ha_power AS
SELECT
    s.statistic_id, c.display_name, s.start_at, s.grain,
    s.mean AS mean_w, s.min AS min_w, s.max AS max_w,
    c.is_active
FROM homeassistant.statistic s
JOIN homeassistant.metric_catalog c USING (statistic_id)
WHERE c.category = 'device_power';


-- ---------------------------------------------------------------------------
-- Energy. Derived entirely here -- delta, covered interval, quality flags.
--
-- Energy is sum-delta, never summed `state`: HA's `sum` is reset-aware and
-- keeps accumulating across a counter reset, while `state` collapses. Adding
-- `state` values double-counts every partial cycle.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.ha_energy AS
WITH base AS (
    SELECT
        s.statistic_id, s.start_at, s.grain, s.sum, s.state,
        c.display_name, c.category, c.energy_role, c.max_plausible_kw,
        c.source, c.is_active,
        LAG(s.sum)      OVER w AS prev_sum,
        LAG(s.start_at) OVER w AS prev_at,
        -- Carried so gap detection can tell a real gap from a grain change.
        LAG(s.grain)    OVER w AS prev_grain
    FROM homeassistant.statistic s
    JOIN homeassistant.metric_catalog c USING (statistic_id)
    WHERE c.category IN ('home_energy', 'device_energy')
    WINDOW w AS (PARTITION BY s.statistic_id ORDER BY s.start_at)
),
calc AS (
    SELECT
        b.*,
        r.decision AS review_decision,
        -- For a cumulative meter, the delta between two consecutive
        -- observations genuinely covers the span between them -- regardless
        -- of grain. (This is not grain inference: grain is a stored column.)
        b.prev_at  AS covered_from,
        b.start_at AS covered_until,
        EXTRACT(EPOCH FROM (b.start_at - b.prev_at)) / 3600.0 AS covered_hours,

        -- Irregular billing periods have no expected step, so gap detection
        -- does not apply to them (measured: 15-34 days, 7 distinct lengths).
        CASE b.grain WHEN 'hour' THEN interval '1 hour'
                     WHEN 'day'  THEN interval '1 day'
                     ELSE NULL END AS expected_step,

        -- Delta source, honouring any human review of a disagreement.
        -- The first row of an imported series has no predecessor, but opower
        -- carries that period's consumption in `state`, so it is recoverable.
        -- Device meters have no such fallback and stay genuinely unknown.
        -- accept_state requires a state to accept. Without the IS NOT NULL
        -- guard, reviewing a row whose state is NULL produced delta_kwh NULL
        -- with delta_source 'state_reviewed', which then earned the
        -- reviewed_state flag and was classified ALLOCATED -- a broken review
        -- silently counted as a good bucket. Such a row now falls through to
        -- the sum delta and is flagged review_invalid below.
        CASE WHEN r.decision = 'accept_state' AND b.state IS NOT NULL THEN b.state
             WHEN b.prev_sum IS NULL AND b.source = 'opower' AND b.state IS NOT NULL
                  THEN b.state
             WHEN b.prev_sum IS NULL THEN NULL
             ELSE b.sum - b.prev_sum END AS delta_kwh,
        CASE WHEN r.decision = 'accept_state' AND b.state IS NOT NULL THEN 'state_reviewed'
             WHEN b.prev_sum IS NULL AND b.source = 'opower' AND b.state IS NOT NULL
                  THEN 'state'
             WHEN b.prev_sum IS NULL THEN NULL
             ELSE 'sum_delta' END AS delta_source
    FROM base b
    LEFT JOIN homeassistant.disagreement_review r
           ON r.statistic_id = b.statistic_id AND r.start_at = b.start_at
)
SELECT
    statistic_id, display_name, category, energy_role, grain, is_active,
    start_at, covered_from, covered_until, covered_hours,
    delta_kwh, delta_source, review_decision,

    -- Flags are built by CONCATENATION, not a mutually-exclusive CASE, so
    -- co-occurring conditions are both recorded (a row can follow a gap AND
    -- disagree with `state`). 'ok' appears only when nothing else did, so it
    -- can never coexist with an anomaly, and the array is never empty.
    COALESCE(NULLIF(
        -- Two different situations, kept distinct: seeding the first row of a
        -- series from `state` is automatic, while accepting `state` over the
        -- sum delta is a reviewed human decision about a specific row.
        (CASE WHEN delta_source = 'state'
              THEN ARRAY['seeded_from_state'] ELSE '{}'::text[] END) ||
        (CASE WHEN delta_source = 'state_reviewed'
              THEN ARRAY['reviewed_state'] ELSE '{}'::text[] END) ||
        (CASE WHEN delta_kwh IS NULL AND delta_source IS NULL
              THEN ARRAY['missing_predecessor'] ELSE '{}'::text[] END) ||
        (CASE WHEN delta_kwh < 0
              THEN ARRAY['negative_delta'] ELSE '{}'::text[] END) ||

        -- A grain change is NOT a gap. At the day -> hour transition the
        -- predecessor is legitimately 24h back while expected_step is 1h;
        -- comparing them without this guard flagged the first real hourly
        -- row as a gap and dropped it out of hourly allocation entirely.
        (CASE WHEN prev_grain IS NOT NULL AND prev_grain <> grain
              THEN ARRAY['grain_transition'] ELSE '{}'::text[] END) ||
        (CASE WHEN expected_step IS NOT NULL AND prev_at IS NOT NULL
                   AND prev_grain = grain
                   AND (start_at - prev_at) > expected_step
              THEN ARRAY['gap'] ELSE '{}'::text[] END) ||

        (CASE WHEN delta_kwh > max_plausible_kw * covered_hours
              THEN ARRAY['implausible_positive'] ELSE '{}'::text[] END) ||

        -- `state` means different things depending on where the statistic came
        -- from, so this cross-check is only valid for IMPORTED statistics:
        --
        --   imported (opower): state IS the period's consumption, so it should
        --                      equal the sum delta -- a mismatch is a real
        --                      signal (17 such rows exist, likely rebills).
        --   recorder:          state is the sensor's reading at period end (a
        --                      lifetime total, or today's running total). It
        --                      has no expected relationship to an hourly delta.
        --
        -- Without the source guard this fired on 37,051 rows -- 4,195 of 4,417
        -- for sensor.p1_total_consumption alone -- pushing ordinary consumption
        -- out of `allocated` and into `unresolved`, which left daily totals
        -- empty while the energy sat in an anomaly bucket.
        -- A reviewed disagreement is resolved, not outstanding.
        (CASE WHEN source <> 'recorder'
                   AND state IS NOT NULL AND prev_sum IS NOT NULL
                   AND abs(state - (sum - prev_sum)) > 0.011
                   AND review_decision IS DISTINCT FROM 'accept_sum'
                   AND review_decision IS DISTINCT FROM 'accept_state'
              THEN ARRAY['source_disagreement'] ELSE '{}'::text[] END) ||
        (CASE WHEN review_decision = 'exclude'
              THEN ARRAY['reviewed_excluded'] ELSE '{}'::text[] END) ||

        -- A review that cannot be honoured is a configuration error, not a
        -- clean row. Surfaced rather than silently ignored.
        (CASE WHEN review_decision = 'accept_state' AND state IS NULL
              THEN ARRAY['review_invalid'] ELSE '{}'::text[] END),
        '{}'::text[]), ARRAY['ok']) AS quality_flags
FROM calc;


-- ---------------------------------------------------------------------------
-- Daily energy, DST-safe.
--
-- Sums hourly deltas rather than multiplying an average by 24, which is what
-- makes DST correct for free: a spring-forward day simply contains 23 rows
-- and a fall-back day 25.
--
-- Three quantities, not two. `unresolved_kwh` is reported separately and is
-- deliberately NOT folded into any coverage ratio -- blending a suspect value
-- into a completeness percentage would launder an anomaly into a measurement.
-- ---------------------------------------------------------------------------
-- The three quantities are MUTUALLY EXCLUSIVE by construction, in strict
-- precedence: unresolved > unallocated > allocated. An earlier version used
-- independent filters, so a row flagged both `gap` and `source_disagreement`
-- was counted in unallocated AND unresolved -- making the three unsafe to add
-- and breaking the reconciliation contract they exist to support.
--
-- Precedence rationale: a suspect value should not be presented as a known
-- gap total. Anomalies win.
CREATE OR REPLACE VIEW reporting.ha_energy_daily AS
WITH classified AS (
    SELECT
        statistic_id, display_name, category, delta_kwh, quality_flags,
        (start_at AT TIME ZONE 'America/Los_Angeles')::date AS local_day,
        CASE
            WHEN quality_flags && ARRAY['negative_delta',
                                        'implausible_positive',
                                        'source_disagreement',
                                        'reviewed_excluded',
                                        'review_invalid'] THEN 'unresolved'
            WHEN 'gap' = ANY(quality_flags)                   THEN 'unallocated'
            WHEN quality_flags <@ ARRAY['ok', 'seeded_from_state',
                                        'reviewed_state',
                                        'grain_transition']   THEN 'allocated'
            ELSE 'unknown'      -- must stay empty; asserted by a view test
        END AS bucket_class
    FROM reporting.ha_energy
    WHERE grain = 'hour'      -- coarse buckets cannot be attributed to a day
),
agg AS (
    SELECT
        statistic_id, display_name, category, local_day,
        sum(delta_kwh) FILTER (WHERE bucket_class = 'allocated')   AS allocated_kwh,
        sum(delta_kwh) FILTER (WHERE bucket_class = 'unallocated') AS unallocated_kwh,
        sum(delta_kwh) FILTER (WHERE bucket_class = 'unresolved')  AS unresolved_kwh,
        count(*)                                                   AS bucket_count,
        count(*) FILTER (WHERE bucket_class = 'allocated')         AS allocated_buckets,
        count(*) FILTER (WHERE bucket_class = 'unknown')           AS unclassified_buckets,
        -- DST-aware: 23 on spring-forward, 25 on fall-back, else 24.
        EXTRACT(EPOCH FROM (
            ((local_day + 1)::timestamp AT TIME ZONE 'America/Los_Angeles')
          - ( local_day     ::timestamp AT TIME ZONE 'America/Los_Angeles')
        )) / 3600.0                                                AS expected_buckets
    FROM classified
    GROUP BY 1, 2, 3, 4
)
SELECT
    a.*,
    -- How much of the day was observed at all.
    round((a.bucket_count / a.expected_buckets)::numeric, 4) AS temporal_coverage,
    -- Of the energy we can account for, how much is attributable to buckets.
    -- unresolved_kwh is deliberately EXCLUDED from this ratio: folding a
    -- suspect value into a completeness percentage launders an anomaly into
    -- an apparent measurement.
    CASE WHEN coalesce(a.allocated_kwh, 0) + coalesce(a.unallocated_kwh, 0) = 0
         THEN NULL
         ELSE round((coalesce(a.allocated_kwh, 0)
                     / (coalesce(a.allocated_kwh, 0)
                        + coalesce(a.unallocated_kwh, 0)))::numeric, 4)
    END AS allocation_coverage
FROM agg a;


-- ---------------------------------------------------------------------------
-- The long utility history at its native grain. Billing periods are irregular
-- (15-34 days) and are NOT months -- presenting them as months would be a
-- quieter version of the same error as calling them hours.
-- ---------------------------------------------------------------------------
-- Reviewed disagreements become eligible here: accepting a row (accept_sum or
-- accept_state) drops its `source_disagreement` flag upstream in ha_energy, so
-- it falls into billable_kwh below. `exclude` decisions carry
-- `reviewed_excluded` and stay out. review_decision is surfaced so a consumer
-- can always see that a human touched the row.
CREATE OR REPLACE VIEW reporting.ha_energy_billing AS
SELECT
    statistic_id, display_name, grain,
    covered_from, covered_until, covered_hours,
    delta_kwh, delta_source, review_decision, quality_flags,
    CASE WHEN quality_flags <@ ARRAY['ok', 'seeded_from_state',
                                     'reviewed_state', 'grain_transition']
         THEN delta_kwh END AS billable_kwh
FROM reporting.ha_energy
WHERE grain IN ('billing_period', 'day');


-- ---------------------------------------------------------------------------
-- Freshness. A gap must read as missing -- never as zero, never as a flat
-- carried-forward line.
--
-- NOTE: this cannot report a Postgres outage, since a failure that prevents
-- writing to sync_run also prevents writing here. External monitoring of the
-- age of last_success_at is required alongside it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.ha_source_status AS
WITH observed AS (
    SELECT statistic_id,
           max(start_at) AS last_value_at,
           min(start_at) AS first_value_at,
           count(*)      AS rows_imported
    FROM homeassistant.statistic
    GROUP BY 1
),
runs AS (
    SELECT
        max(finished_at) FILTER (WHERE status = 'success') AS last_success_at,
        max(started_at)                                    AS last_run_at,
        (SELECT error FROM homeassistant.sync_run
          WHERE status = 'failed' ORDER BY started_at DESC LIMIT 1) AS last_error
    FROM homeassistant.sync_run
)
SELECT
    c.statistic_id,
    c.display_name,
    c.category,
    c.is_active,
    c.grain_review_required,
    c.default_grain            AS expected_cadence,
    o.first_value_at,
    o.last_value_at,
    o.rows_imported,
    now() - o.last_value_at    AS stale_for,
    r.last_success_at,
    r.last_run_at,
    r.last_error
FROM homeassistant.metric_catalog c
LEFT JOIN observed o USING (statistic_id)
CROSS JOIN runs r;


-- ---------------------------------------------------------------------------
-- API reader role: SELECT on reporting views only. Never the ingest tables,
-- never another application's schema. Password set by hand via ALTER ROLE and
-- kept only in .env.
-- ---------------------------------------------------------------------------
-- Created NOLOGIN without a password: see the note in schema.sql. Provision
-- with  ALTER ROLE ha_api_reader LOGIN PASSWORD '<from .env>';
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ha_api_reader') THEN
        CREATE ROLE ha_api_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
        RAISE NOTICE 'Created role ha_api_reader (NOLOGIN). Provision it with: ALTER ROLE ha_api_reader LOGIN PASSWORD ''<from .env>'';';
    END IF;
END
$$;

ALTER ROLE ha_api_reader SET search_path TO reporting;

GRANT CONNECT ON DATABASE garbanzodb TO ha_api_reader;
GRANT USAGE ON SCHEMA reporting TO ha_api_reader;

GRANT SELECT ON reporting.ha_temperature    TO ha_api_reader;
GRANT SELECT ON reporting.ha_power          TO ha_api_reader;
GRANT SELECT ON reporting.ha_energy         TO ha_api_reader;
GRANT SELECT ON reporting.ha_energy_daily   TO ha_api_reader;
GRANT SELECT ON reporting.ha_energy_billing TO ha_api_reader;
GRANT SELECT ON reporting.ha_source_status  TO ha_api_reader;

-- Explicitly denied everywhere else, including the ingest schema.
-- Verified 2026-08-11: has_schema_privilege is false for homeassistant, oura,
-- dancetrak and website, and has_table_privilege is false for
-- homeassistant.statistic.
REVOKE ALL ON SCHEMA homeassistant FROM ha_api_reader;
REVOKE ALL ON SCHEMA oura          FROM ha_api_reader;
REVOKE ALL ON SCHEMA dancetrak     FROM ha_api_reader;
REVOKE ALL ON SCHEMA website       FROM ha_api_reader;

-- See the matching note in schema.sql: this cannot remove USAGE on `public`,
-- which PostgreSQL grants via the PUBLIC pseudo-role. Table-level access is
-- what actually matters and is denied.
REVOKE ALL ON SCHEMA public        FROM ha_api_reader;
