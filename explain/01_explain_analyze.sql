-- 01_explain_analyze.sql
-- Reading EXPLAIN (ANALYZE, BUFFERS) — three query patterns.
-- Each block: problem query → EXPLAIN → optimized variant → EXPLAIN.
-- See docs/optimization.md for the writeup interpreting these plans.

\pset pager off

\echo ''
\echo '############################################################'
\echo '# PATTERN 1: "events for user X, latest first"            #'
\echo '############################################################'

\echo ''
\echo '--- EXPLAIN for: latest 5 events for one user ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, event_name, occurred_at, properties
FROM events
WHERE user_id = '11111111-1111-1111-1111-111111111101'
ORDER BY occurred_at DESC
LIMIT 5;

\echo ''
\echo 'Expected: Index Scan using events_user_occurred_idx (user_id, occurred_at DESC).'
\echo '         Without that index, you would see a Sort over a Seq Scan.'


\echo ''
\echo '############################################################'
\echo '# PATTERN 2: "logins in last 7 days"                       #'
\echo '############################################################'

\echo ''
\echo '--- EXPLAIN for: logins in last 7 days ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id, occurred_at
FROM events
WHERE event_name = 'login'
  AND occurred_at >= NOW() - INTERVAL '7 days'
ORDER BY occurred_at DESC;

\echo ''
\echo 'Expected: Index Scan on events_name_occurred_idx. If you only'
\echo '         had an index on (event_name), Postgres would still need a sort.'


\echo ''
\echo '############################################################'
\echo '# PATTERN 3: "events where properties.feature = export"    #'
\echo '############################################################'

\echo ''
\echo '--- (a) Without GIN index: full table scan + jsonb filter ---'
DROP INDEX IF EXISTS events_properties_gin_idx;
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM events
WHERE properties @> '{"feature":"export"}'::jsonb;

\echo ''
\echo '--- (b) With GIN index: Bitmap Index Scan ---'
CREATE INDEX IF NOT EXISTS events_properties_gin_idx
    ON events USING GIN (properties jsonb_path_ops);
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM events
WHERE properties @> '{"feature":"export"}'::jsonb;

\echo ''
\echo 'Expected: (a) Seq Scan filtering every row; (b) Bitmap Index Scan'
\echo '         using events_properties_gin_idx — orders of magnitude cheaper'
\echo '         once the table is large.'


\echo ''
\echo '############################################################'
\echo '# PATTERN 4: classic pitfall — wrong index for a range     #'
\echo '############################################################'

\echo ''
\echo '--- EXPLAIN for: open invoices due in next 7 days ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, amount_cents, due_at
FROM invoices
WHERE status = 'open'
  AND due_at <= NOW() + INTERVAL '7 days'
ORDER BY due_at;

\echo ''
\echo 'Expected: Index Scan on invoices_open_due_idx (partial btree).'
\echo '         A naive (status, due_at) composite index would also work but'
\echo '         wastes space on the 95% of invoices that are paid.'


\echo ''
\echo '############################################################'
\echo '# BONUS: pg_stat_statements — top 5 slowest queries        #'
\echo '############################################################'
SELECT
    substring(query, 1, 80) AS query,
    calls,
    ROUND(mean_exec_time::numeric, 3) AS mean_exec_time_ms,
    ROUND(total_exec_time::numeric, 3) AS total_exec_time_ms,
    rows
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 5;
