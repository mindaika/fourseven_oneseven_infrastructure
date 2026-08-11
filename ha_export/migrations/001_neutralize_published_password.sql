-- MIGRATION 001 - neutralize roles created with a published password.
--
-- WHO NEEDS THIS
-- Any database where an earlier revision of schema.sql or reporting_schema.sql
-- was applied. Those files created login roles as:
--
--     CREATE ROLE ha_sync       LOGIN PASSWORD 'changeme-see-dot-env' ...
--     CREATE ROLE ha_api_reader LOGIN PASSWORD 'changeme-see-dot-env' ...
--
-- so both accounts were left able to authenticate with a password committed to
-- this repository.
--
-- WHY IT IS A SEPARATE FILE
-- schema.sql cannot fix this on its own. Its CREATE ROLE is guarded by
-- IF NOT EXISTS, so re-running the corrected file skips an already-existing
-- role and leaves the bad credential in place. And it must NOT unconditionally
-- reset the password on every run, because that would repeatedly break a
-- deployment an operator has legitimately provisioned.
--
-- Detection by password hash is not possible either: PostgreSQL 16 defaults to
-- scram-sha-256, which is salted, so the stored verifier cannot be compared
-- against a known plaintext.
--
-- That leaves an explicit, operator-run migration. It is deliberately blunt:
-- it revokes login from both roles regardless of current state, so a
-- provisioned deployment must re-provision afterwards. Failing closed is the
-- correct trade for a credential that may be public.
--
-- STATUS
-- Applied by hand to garbanzodb on piberry5 on 2026-08-11. Recorded here so
-- any other database that ran the vulnerable SQL gets the same treatment.
--
-- AFTER RUNNING THIS, provision each role you actually use:
--     ALTER ROLE ha_sync       LOGIN PASSWORD '<strong value from .env>';
--     ALTER ROLE ha_api_reader LOGIN PASSWORD '<strong value from .env>';

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'ha_sync') THEN
        ALTER ROLE ha_sync NOLOGIN PASSWORD NULL;
        RAISE NOTICE 'ha_sync: login revoked, password cleared. Re-provision from .env.';
    END IF;

    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'ha_api_reader') THEN
        ALTER ROLE ha_api_reader NOLOGIN PASSWORD NULL;
        RAISE NOTICE 'ha_api_reader: login revoked, password cleared. Re-provision from .env.';
    END IF;
END
$$;

-- Verification: both must report can_login = false, has_password = false.
SELECT rolname,
       rolcanlogin                AS can_login,
       (rolpassword IS NOT NULL)  AS has_password
FROM pg_authid
WHERE rolname IN ('ha_sync', 'ha_api_reader')
ORDER BY rolname;

COMMIT;
