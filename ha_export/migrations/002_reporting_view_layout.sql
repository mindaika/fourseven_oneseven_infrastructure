-- MIGRATION 002 - upgrade the Phase 3 reporting views to their final layout.
--
-- WHO NEEDS THIS
-- Any database where an earlier revision of reporting_schema.sql was applied.
--
-- WHY reporting_schema.sql CANNOT DO IT ALONE
-- That file is now CREATE OR REPLACE VIEW throughout, which permits APPENDING
-- columns but not renaming, reordering or removing them. Three views changed in
-- ways that violate that rule relative to the previously installed layout:
--
--   ha_energy          - review_decision inserted BEFORE the existing
--                        quality_flags column
--   ha_energy_daily    - clean_bucket_count replaced by allocated_buckets,
--                        followed by new count/coverage columns
--   ha_energy_billing  - review_decision inserted BEFORE quality_flags, and
--                        billable_kwh appended
--
-- Against a database holding the earlier layout, CREATE OR REPLACE rejects each
-- of these as a column rename. Re-applying successfully on a database that
-- already has the FINAL layout only demonstrates idempotency from that state --
-- it does not exercise the upgrade path at all.
--
-- This is precisely the exceptional case the append-only policy carves out:
-- an explicit, numbered migration that drops the known dependents in dependency
-- order, WITHOUT CASCADE, and recreates them in one transaction.
--
-- No CASCADE: dropping blind would silently take out any downstream object.
-- Listing the dependents by name means an unknown dependent causes a loud
-- failure and a rolled-back transaction instead of silent data-surface loss.
--
-- The views are recreated by including reporting_schema.sql rather than by
-- copying its definitions here, so there is one source of truth and no risk of
-- the migration and the schema file drifting apart.

BEGIN;

-- Dependency order: both dependents before the view they are built on.
DROP VIEW IF EXISTS reporting.ha_energy_daily;
DROP VIEW IF EXISTS reporting.ha_energy_billing;
DROP VIEW IF EXISTS reporting.ha_energy;

-- Recreates all six views in their final layout, plus grants.
-- Path is relative to THIS file (\ir, not \i).
\ir ../reporting_schema.sql

COMMIT;
