-- MIGRATION 003 - per-metric sync watermark.
--
-- WHY
-- Reconciliation must compare like with like. Its snapshot is taken NOW, so it
-- always contains rows Home Assistant compiled after the last sync ran; those
-- are legitimately absent from the mirror and must not be reported as missing.
--
-- The first attempt bounded the comparison by a GLOBAL max(source_max_ts)
-- across all metrics. That is inexact: if metric A had compiled hour 18 when
-- the sync ran while metric B had only reached hour 17, the global watermark is
-- already 18, so B's hour-18 row -- compiled afterwards -- gets compared and
-- reported missing. Whether HA advances every statistic atomically within a
-- compile pass is an assumption this pipeline should not have to make.
--
-- A per-metric watermark removes the assumption entirely: each metric records
-- the newest source timestamp that a successful run actually observed for IT.
--
-- SEEDING
-- Existing rows are seeded from the current mirror maximum per metric. That is
-- the best available evidence for what has already been synced, and it is
-- correct for any metric whose last sync succeeded -- which is all of them at
-- the time this migration is written (reconciliation is clean).

BEGIN;

CREATE TABLE IF NOT EXISTS homeassistant.metric_watermark (
    statistic_id  text PRIMARY KEY
                  REFERENCES homeassistant.metric_catalog ON DELETE CASCADE,
    source_max_ts timestamptz NOT NULL,
    observed_at   timestamptz NOT NULL DEFAULT now()
);

INSERT INTO homeassistant.metric_watermark (statistic_id, source_max_ts)
SELECT statistic_id, max(start_at)
FROM homeassistant.statistic
GROUP BY statistic_id
ON CONFLICT (statistic_id) DO NOTHING;

-- The sync runtime maintains this; it is derived state, not reviewed
-- configuration, so ha_sync legitimately writes it.
GRANT SELECT, INSERT, UPDATE ON homeassistant.metric_watermark TO ha_sync;

-- An earlier version of this migration also granted ha_api_reader SELECT here.
-- That was wrong: the API never reads this table, and the grant widened the
-- reader beyond the stated "reporting views only" boundary. Revoked explicitly
-- rather than merely removed, so a database that already ran that version
-- converges instead of silently keeping the extra privilege.
REVOKE ALL ON homeassistant.metric_watermark FROM ha_api_reader;

SELECT count(*) AS seeded_watermarks FROM homeassistant.metric_watermark;

COMMIT;
