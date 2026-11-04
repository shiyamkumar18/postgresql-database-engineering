# Query Optimization

A practical workflow for finding and fixing slow queries, with worked examples from Subly. Companion to [`explain/01_explain_analyze.sql`](../explain/01_explain_analyze.sql).

## The slow-query workflow

1. **Find them.** Either `log_min_duration_statement=200` (set in our `docker-compose.yml`) or `pg_stat_statements`.
2. **Reproduce.** Run the offending query with `EXPLAIN (ANALYZE, BUFFERS)` to get actual execution stats, not just the planner's estimate.
3. **Read the plan bottom-up.** The plan is a tree; the leaf nodes execute first. Look for:
   - `Seq Scan` on a large table → missing index or wrong index
   - `Sort` node before a `Limit` → missing leading sort index
   - `Hash Join` with huge build side → wrong join order or missing index on probe side
   - `Rows Removed by Filter` very high → wrong index (Postgres scanned many rows to find few)
   - `actual rows` wildly off from `estimated rows` → stale stats; `ANALYZE` the table
4. **Hypothesize a fix.** Add an index, rewrite the query, materialize an aggregate.
5. **Measure again.** Drop into `EXPLAIN ANALYZE` and confirm the plan changed *and* the timings dropped.

## Reading an EXPLAIN plan

```text
Limit  (cost=0.29..8.31 rows=5 width=104) (actual time=0.018..0.024 rows=5 loops=1)
  ->  Index Scan using events_user_occurred_idx on events
        (cost=0.29..8.31 rows=5 width=104) (actual time=0.017..0.022 rows=5 loops=1)
        Index Cond: (user_id = '...'::uuid)
```

Reading this:
- **`Index Scan`** — Postgres used the index `events_user_occurred_idx`
- **`Index Cond: (user_id = ...)`** — only the user_id column was used by the index
- **`actual time=0.017..0.022`** — start..end of this node in ms
- **`rows=5`** — actual rows returned (vs `rows=5` estimate — perfect estimate)
- **`loops=1`** — number of times this node was executed (matters for nested loops)

If you see `actual rows=1000000` next to `estimated rows=1000`, run `ANALYZE events;` and re-run.

## Worked example — Pattern 1: latest 5 events for a user

### Naive query (no useful index)
```sql
SELECT id, event_name, occurred_at
FROM events
WHERE user_id = '...'
ORDER BY occurred_at DESC
LIMIT 5;
```

With no composite index on `(user_id, occurred_at)`:
1. Postgres does `Seq Scan on events` — reads every row
2. `Sort` the matching rows by `occurred_at DESC`
3. `Limit` to 5

For a million-row events table, this is hundreds of milliseconds.

### With `events_user_occurred_idx (user_id, occurred_at DESC)`
Postgres does an **Index Scan** that walks the index tree directly to user X's first row, then descends 5 entries and stops. Cost is proportional to 5, not to the table size. ~0.02ms.

> See `explain/01_explain_analyze.sql` Pattern 1 for the actual plan output.

## Worked example — Pattern 3: JSONB containment

```sql
SELECT COUNT(*) FROM events
WHERE properties @> '{"feature":"export"}'::jsonb;
```

Without a GIN index: full table scan, parse every JSONB, test containment. Slow at scale.

With `events_properties_gin_idx` (GIN, `jsonb_path_ops`): Postgres does a **Bitmap Index Scan** that directly returns the matching row IDs. Cost is proportional to the number of matching rows, not the table size.

> See `explain/01_explain_analyze.sql` Pattern 3 for both before/after plans.

## Worked example — Pitfall: wrong index for a range

```sql
SELECT * FROM invoices
WHERE status = 'open' AND due_at <= NOW() + INTERVAL '7 days'
ORDER BY due_at;
```

A naive index `(status, due_at)` works but wastes space — 95% of invoices are `paid` and never queried this way.

Our `invoices_open_due_idx` is a **partial index**: `WHERE status='open'`. It's ~5% the size, faster to scan, and faster to maintain on every insert.

## Using `pg_stat_statements`

Enabled in `docker-compose.yml` via `shared_preload_libraries=pg_stat_statements`. Query it:

```sql
SELECT
    substring(query, 1, 80) AS query,
    calls, mean_exec_time_ms, total_exec_time_ms, rows
FROM pg_stat_statements
ORDER BY mean_exec_time_ms DESC
LIMIT 10;
```

This is your **daily dashboard** — the top-10 queries by mean execution time are the optimization candidates that matter most. Mean is more useful than total here: a query called 1M times at 5ms each deserves more attention than one called once at 5s.

## When to stop optimizing

Two rules of thumb:
1. If a query is under 50ms and called rarely, leave it alone.
2. If a query is over 1s or called more than 1k/sec, it deserves a second look.

The optimization chapter isn't about making every query fast — it's about making the **right** queries fast.
