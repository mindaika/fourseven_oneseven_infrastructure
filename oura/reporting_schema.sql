-- Read-only reporting layer for external analysis tools (e.g. an MCP server
-- backing Claude). Sits between the raw `oura` ingest tables and anything
-- that reads the data: the analysis surface only ever touches views here,
-- never the ingest tables directly, so the pipeline underneath (columns,
-- upsert logic, new endpoints) can change without breaking a downstream
-- consumer's queries, and a compromised reader credential can only ever
-- run SELECT against a curated set of columns — never touch `oura.*`,
-- `dancetrak.*`, `website.*`, or `public.*` (Vaultwarden).
--
-- Each view pulls the handful of fields actually useful for analysis out
-- of the jsonb payload and leaves noisy raw arrays (minute-by-minute MET,
-- second-by-second sleep phase strings, per-sample heart rate arrays from
-- sessions, etc.) out entirely — those are ingest/debugging detail, not
-- something a reporting query needs.
--
-- Idempotent: safe to re-run (CREATE OR REPLACE VIEW).

CREATE SCHEMA IF NOT EXISTS reporting;

CREATE OR REPLACE VIEW reporting.oura_daily_sleep AS
SELECT
    day,
    score,
    (data->'contributors'->>'timing')::int       AS timing_score,
    (data->'contributors'->>'latency')::int      AS latency_score,
    (data->'contributors'->>'rem_sleep')::int     AS rem_sleep_score,
    (data->'contributors'->>'deep_sleep')::int    AS deep_sleep_score,
    (data->'contributors'->>'efficiency')::int    AS efficiency_score,
    (data->'contributors'->>'restfulness')::int   AS restfulness_score,
    (data->'contributors'->>'total_sleep')::int   AS total_sleep_score
FROM oura.daily_sleep;

CREATE OR REPLACE VIEW reporting.oura_daily_readiness AS
SELECT
    day,
    score,
    (data->'contributors'->>'hrv_balance')::int             AS hrv_balance_score,
    (data->'contributors'->>'sleep_balance')::int           AS sleep_balance_score,
    (data->'contributors'->>'previous_night')::int          AS previous_night_score,
    (data->'contributors'->>'recovery_index')::int          AS recovery_index_score,
    (data->'contributors'->>'activity_balance')::int        AS activity_balance_score,
    (data->'contributors'->>'body_temperature')::int        AS body_temperature_score,
    (data->'contributors'->>'sleep_regularity')::int        AS sleep_regularity_score,
    (data->'contributors'->>'resting_heart_rate')::int      AS resting_heart_rate_score,
    (data->'contributors'->>'previous_day_activity')::int   AS previous_day_activity_score,
    (data->>'temperature_deviation')::numeric                AS temperature_deviation,
    (data->>'temperature_trend_deviation')::numeric           AS temperature_trend_deviation
FROM oura.daily_readiness;

CREATE OR REPLACE VIEW reporting.oura_daily_activity AS
SELECT
    day,
    score,
    (data->>'steps')::int                          AS steps,
    (data->>'active_calories')::int                 AS active_calories,
    (data->>'total_calories')::int                  AS total_calories,
    (data->>'target_calories')::int                 AS target_calories,
    (data->>'average_met_minutes')::numeric          AS average_met_minutes,
    (data->>'high_activity_time')::int               AS high_activity_time_seconds,
    (data->>'medium_activity_time')::int             AS medium_activity_time_seconds,
    (data->>'low_activity_time')::int                AS low_activity_time_seconds,
    (data->>'sedentary_time')::int                   AS sedentary_time_seconds,
    (data->>'resting_time')::int                     AS resting_time_seconds,
    (data->>'equivalent_walking_distance')::int      AS equivalent_walking_distance_meters,
    (data->>'meters_to_target')::int                 AS meters_to_target
FROM oura.daily_activity;

CREATE OR REPLACE VIEW reporting.oura_sleep_periods AS
SELECT
    id,
    day,
    data->>'type'                              AS sleep_type,
    bedtime_start,
    bedtime_end,
    (data->>'time_in_bed')::int                AS time_in_bed_seconds,
    total_sleep_duration                        AS total_sleep_duration_seconds,
    (data->>'efficiency')::int                  AS efficiency,
    (data->>'average_hrv')::int                 AS average_hrv,
    (data->>'average_heart_rate')::numeric      AS average_heart_rate,
    (data->>'lowest_heart_rate')::int           AS lowest_heart_rate,
    (data->>'average_breath')::numeric          AS average_breath,
    (data->>'rem_sleep_duration')::int          AS rem_sleep_duration_seconds,
    (data->>'deep_sleep_duration')::int         AS deep_sleep_duration_seconds,
    (data->>'light_sleep_duration')::int        AS light_sleep_duration_seconds,
    (data->>'awake_time')::int                  AS awake_time_seconds,
    (data->>'restless_periods')::int            AS restless_periods,
    (data->'readiness'->>'score')::int          AS readiness_score
FROM oura.sleep_periods;

CREATE OR REPLACE VIEW reporting.oura_daily_stress AS
SELECT
    day,
    data->>'day_summary'            AS day_summary,
    (data->>'stress_high')::int     AS stress_high_seconds,
    (data->>'recovery_high')::int   AS recovery_high_seconds
FROM oura.daily_stress;

CREATE OR REPLACE VIEW reporting.oura_daily_spo2 AS
SELECT
    day,
    (data->'spo2_percentage'->>'average')::numeric   AS spo2_percentage_average,
    (data->>'breathing_disturbance_index')::int      AS breathing_disturbance_index
FROM oura.daily_spo2;

CREATE OR REPLACE VIEW reporting.oura_workouts AS
SELECT
    id,
    day,
    activity,
    data->>'intensity'          AS intensity,
    data->>'source'             AS source,
    (data->>'calories')::numeric AS calories,
    (data->>'distance')::numeric AS distance_meters,
    start_datetime,
    end_datetime
FROM oura.workouts;

CREATE OR REPLACE VIEW reporting.oura_sessions AS
SELECT
    id,
    day,
    session_type,
    data->>'mood'   AS mood,
    start_datetime,
    end_datetime
FROM oura.sessions;

CREATE OR REPLACE VIEW reporting.oura_tags AS
SELECT
    id,
    start_day,
    end_day,
    data->>'tag_type_code'   AS tag_type_code,
    data->>'custom_name'     AS custom_name,
    data->>'comment'         AS comment
FROM oura.tags;

CREATE OR REPLACE VIEW reporting.oura_heart_rate AS
SELECT "timestamp", source, bpm
FROM oura.heart_rate;

-- Sync status, so an analysis session can sanity-check freshness before
-- trusting the numbers ("last synced 3 hours ago" vs "last synced 6 weeks ago").
CREATE OR REPLACE VIEW reporting.oura_sync_status AS
SELECT endpoint, window_start, window_end, completed_at, status, records_synced
FROM oura.sync_log
WHERE id IN (
    SELECT DISTINCT ON (endpoint) id
    FROM oura.sync_log
    ORDER BY endpoint, started_at DESC
);

-- Dedicated read-only role for external tools (e.g. an MCP server). Never
-- reused for anything else. SELECT on the reporting schema only — no
-- INSERT/UPDATE/DELETE, no DDL, no access to oura/dancetrak/website/public.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'claude_reader') THEN
        CREATE ROLE claude_reader LOGIN PASSWORD 'changeme-see-dot-env' NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;
END
$$;

ALTER ROLE claude_reader SET search_path TO reporting;

GRANT CONNECT ON DATABASE garbanzodb TO claude_reader;
GRANT USAGE ON SCHEMA reporting TO claude_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO claude_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA reporting GRANT SELECT ON TABLES TO claude_reader;

-- Explicit, redundant-by-design: make the isolation visible in the SQL
-- itself rather than relying on "no grant was ever given."
REVOKE ALL ON SCHEMA oura FROM claude_reader;
REVOKE ALL ON SCHEMA dancetrak FROM claude_reader;
REVOKE ALL ON SCHEMA website FROM claude_reader;
REVOKE ALL ON SCHEMA public FROM claude_reader;
