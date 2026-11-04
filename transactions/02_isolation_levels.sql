-- 02_isolation_levels.sql
-- Demonstrates READ COMMITTED vs REPEATABLE READ.
--
-- Run in TWO terminals:
--   Terminal A: psql ... -f transactions/02_isolation_levels.sql   (the "writer")
--   Terminal B: psql ...   then paste the SELECTs labelled "B"     (the "reader")
--
-- Effect of switching the writer's SET TRANSACTION ISOLATION LEVEL:
--   * READ COMMITTED  (default): a SELECT inside the txn sees committed
--     changes made by OTHER txns after the SELECT began (so non-repeatable reads).
--   * REPEATABLE READ:           a SELECT inside the txn sees a stable snapshot
--     taken at the first SELECT — the same query returns the same rows.
--
-- PostgreSQL doesn't allow READ UNCOMMITTED; SERIALIZABLE behaves like RR + SSI.

\pset pager off

-- ============================================================================
-- SESSION A: WRITER
-- ============================================================================
\echo '=== SESSION A (writer): BEGIN and UPDATE one user''s name ==='
BEGIN;
-- Change isolation here to compare behavior:
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;   -- try REPEATABLE READ next

UPDATE users
SET full_name = full_name || ' (edited)'
WHERE email = 'alice@subly.demo'
RETURNING id, email, full_name;

\echo '!!! A has NOT committed yet. Run the B queries below in another psql session !!!'
\echo '!!! Then return here and run COMMIT;                          !!!'
-- COMMIT;
