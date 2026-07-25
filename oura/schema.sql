-- Oura Ring data warehouse — weekly sync target
--
-- Mirrors the pattern already used by the `dancetrak` and `website` schemas:
-- one schema per app inside the shared `garbanzodb` database, owned by a
-- dedicated least-privilege role rather than the shared `garbanzo` superuser
-- everything else currently connects as.
--
-- Design choice: every table keeps the full raw API response in a `data`
-- jsonb column alongside a handful of indexed columns pulled out for
-- convenient querying (day, score, timestamps). Oura's API adds/renames
-- fields over time; storing the raw payload means a field Oura adds next
-- year is still captured even before this schema is updated for it, and
-- nothing is lost to a parsing assumption that turns out wrong.
--
-- Idempotent: safe to re-run.

CREATE SCHEMA IF NOT EXISTS oura;

-- /v2/usercollection/daily_activity
CREATE TABLE IF NOT EXISTS oura.daily_activity (
    id          text PRIMARY KEY,
    day         date NOT NULL,
    score       integer,
    data        jsonb NOT NULL,
    synced_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS daily_activity_day_idx ON oura.daily_activity (day);

-- /v2/usercollection/daily_sleep (nightly sleep score/summary)
CREATE TABLE IF NOT EXISTS oura.daily_sleep (
    id          text PRIMARY KEY,
    day         date NOT NULL,
    score       integer,
    data        jsonb NOT NULL,
    synced_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS daily_sleep_day_idx ON oura.daily_sleep (day);

-- /v2/usercollection/sleep (detailed per-period sleep records; a night can
-- have more than one period, e.g. a nap)
CREATE TABLE IF NOT EXISTS oura.sleep_periods (
    id                      text PRIMARY KEY,
    day                     date NOT NULL,
    bedtime_start           timestamptz,
    bedtime_end             timestamptz,
    total_sleep_duration    integer,
    data                    jsonb NOT NULL,
    synced_at               timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sleep_periods_day_idx ON oura.sleep_periods (day);

-- /v2/usercollection/daily_readiness
CREATE TABLE IF NOT EXISTS oura.daily_readiness (
    id          text PRIMARY KEY,
    day         date NOT NULL,
    score       integer,
    data        jsonb NOT NULL,
    synced_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS daily_readiness_day_idx ON oura.daily_readiness (day);

-- /v2/usercollection/daily_spo2
CREATE TABLE IF NOT EXISTS oura.daily_spo2 (
    id                  text PRIMARY KEY,
    day                 date NOT NULL,
    spo2_percentage     numeric,
    data                jsonb NOT NULL,
    synced_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS daily_spo2_day_idx ON oura.daily_spo2 (day);

-- /v2/usercollection/daily_stress (keyed by day, not id, in the Oura API)
CREATE TABLE IF NOT EXISTS oura.daily_stress (
    day         date PRIMARY KEY,
    data        jsonb NOT NULL,
    synced_at   timestamptz NOT NULL DEFAULT now()
);

-- /v2/usercollection/heartrate (raw samples; no id in the API, so the
-- natural key is the (timestamp, source) pair)
CREATE TABLE IF NOT EXISTS oura.heart_rate (
    "timestamp"     timestamptz NOT NULL,
    source          text NOT NULL,
    bpm             integer NOT NULL,
    synced_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("timestamp", source)
);

-- /v2/usercollection/workout
CREATE TABLE IF NOT EXISTS oura.workouts (
    id              text PRIMARY KEY,
    day             date NOT NULL,
    activity        text,
    calories        numeric,
    start_datetime  timestamptz,
    end_datetime    timestamptz,
    data            jsonb NOT NULL,
    synced_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS workouts_day_idx ON oura.workouts (day);

-- /v2/usercollection/session (guided breathing / meditation / naps)
CREATE TABLE IF NOT EXISTS oura.sessions (
    id              text PRIMARY KEY,
    day             date NOT NULL,
    session_type    text,
    start_datetime  timestamptz,
    end_datetime    timestamptz,
    data            jsonb NOT NULL,
    synced_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sessions_day_idx ON oura.sessions (day);

-- /v2/usercollection/enhanced_tag (user-entered tags/notes; keyed by
-- start_day/end_day, not day, since a tag can span multiple days)
CREATE TABLE IF NOT EXISTS oura.tags (
    id          text PRIMARY KEY,
    start_day   date NOT NULL,
    end_day     date,
    data        jsonb NOT NULL,
    synced_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tags_start_day_idx ON oura.tags (start_day);

-- Tracks each weekly run per endpoint so the sync script can fetch only
-- what's new (window_start = last successful window_end) instead of
-- re-downloading full history every week.
CREATE TABLE IF NOT EXISTS oura.sync_log (
    id              serial PRIMARY KEY,
    endpoint        text NOT NULL,
    window_start    date NOT NULL,
    window_end      date NOT NULL,
    started_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    records_synced  integer,
    status          text NOT NULL DEFAULT 'running',  -- running | success | failed
    error           text
);
CREATE INDEX IF NOT EXISTS sync_log_endpoint_idx ON oura.sync_log (endpoint, completed_at DESC);

-- Dedicated least-privilege role for the sync job, instead of reusing the
-- shared `garbanzo` superuser the other apps connect as. Scoped to the
-- `oura` schema only: no access to `dancetrak`, `website`, or `public`
-- (which is where Vaultwarden's tables live). No DELETE — the sync job
-- only ever needs to append/update, so it can't lose currently-existing
-- data even if the token or script were ever compromised.
-- Password is a throwaway placeholder here on purpose (this file is safe to
-- commit) — the real password is set immediately after via a separate
-- ALTER ROLE ... PASSWORD command run by hand, and lives only in the
-- gitignored oura/.env.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'oura_sync') THEN
        CREATE ROLE oura_sync LOGIN PASSWORD 'changeme-see-dot-env';
    END IF;
END
$$;

ALTER ROLE oura_sync SET search_path TO oura;

GRANT CONNECT ON DATABASE garbanzodb TO oura_sync;
GRANT USAGE ON SCHEMA oura TO oura_sync;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA oura TO oura_sync;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA oura TO oura_sync;
ALTER DEFAULT PRIVILEGES IN SCHEMA oura GRANT SELECT, INSERT, UPDATE ON TABLES TO oura_sync;
ALTER DEFAULT PRIVILEGES IN SCHEMA oura GRANT USAGE, SELECT ON SEQUENCES TO oura_sync;
