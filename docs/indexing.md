# Indexing Strategy

Indexing is the single highest-leverage skill in database engineering. This document explains the indexes chosen for Subly, *why* each was chosen, and how to read the resulting query plans.

> All indexes live in [`init/04_indexes.sql`](../init/04_indexes.sql). Run `make seed` after the schema to create them.

## Mental model

A query is slow when Postgres has to look at too many rows to answer it. The job of an index is to **reduce the rows touched** — not "make the query fast" in the abstract. Always ask: *which rows does this query need, and what index lets Postgres find only those?*

## The catalog

| # | Index | Type | Purpose |
|---|---|---|---|
| 1 | `users_full_name_trgm_idx` | GIN trigram | LIKE/ILIKE name search ("find users named 'shiy%') |
| 2 | `users_status_signup_idx` | btree | "active users by signup date" (admin dashboard) |
| 3 | `subscriptions_one_active_per_user_uniq` | **partial unique btree** | Enforce business rule: one active sub per user |
| 4 | `subscriptions_status_period_end_idx` | partial btree | "subscriptions expiring this week" |
| 5 | `subscriptions_canceled_at_idx` | partial btree | "recent cancellations" report |
| 6 | `events_user_occurred_idx` | **composite btree** | "events for user X, latest first" (most common query) |
| 7 | `events_name_occurred_idx` | composite btree | "logins in last 7 days" |
| 8 | `events_properties_gin_idx` | GIN jsonb_path_ops | Filter events by JSON property (`@>`) |
| 9 | `events_occurred_brin_idx` | **BRIN** | Time-series bulk scan ("all events in March") |
| 10 | `invoices_open_due_idx` | partial btree | "open invoices due soon" |
| 11 | `invoices_user_issued_idx` | composite btree | "user's invoices, newest first" |
| 12 | `payments_invoice_idx` | btree | Join payments to invoices |
| 13 | `payments_status_attempted_idx` | composite btree | "failed payments for retry" job |
| 14 | `daily_usage_date_feature_idx` | composite btree | "all users active on date X" |

## When to use which type

### B-tree (default)
Use when:
- You query `=`, `<`, `>`, `BETWEEN`, or `ORDER BY` on a column
- Cardinality is high (lots of distinct values)
- The column appears in joins

**Don't use for**: low-cardinality boolean/enum-only columns on their own (a seq scan is often cheaper).

### Composite B-tree `(a, b)`
The golden rule: **leftmost prefix**. The index is usable for `WHERE a=?`, `WHERE a=? AND b=?`, and `WHERE a=? ORDER BY b`. It is **not** usable for `WHERE b=?` alone.

Picking the column order:
1. Equality columns first (`WHERE a = ?`)
2. Then range/order columns (`WHERE b > ?`, `ORDER BY b`)
3. Put more selective columns earlier *only* if equality doesn't pin them down

`events_user_occurred_idx (user_id, occurred_at DESC)` follows this: filter by `user_id` (equality), then sort by `occurred_at DESC`.

### Partial: `WHERE condition`
For indexes that only matter on a subset of rows. Massive wins on tables where a small slice is queried hot:
- `subscriptions_one_active_per_user_uniq` only covers active subscriptions (the 80% that are canceled never enter the index)
- `invoices_open_due_idx` only covers open invoices

Partial indexes are smaller, faster to scan, and faster to maintain on every insert.

### GIN
For composite/searchable types: arrays, full-text `tsvector`, `jsonb`, trigrams.

`events_properties_gin_idx` with `jsonb_path_ops` is the right choice when you only ever do `@>` containment queries. It's smaller and faster than the default `jsonb_ops` for that pattern.

### BRIN
For **naturally physically ordered** large tables (time-series). A BRIN index stores min/max per block range — essentially free to maintain, tiny on disk, and lets Postgres skip huge ranges of rows.

`events_occurred_brin_idx` shines for "give me all events in March" — Postgres skips block ranges outside that month. Useless for "events for user X" because rows for one user are scattered.

## Common pitfalls

### Pitfall 1: Indexing a function on the column
```sql
WHERE LOWER(email) = 'alice@x.com'   -- won't use a plain index on email
```
Either use `CITEXT` (as we do), or define an expression index: `CREATE INDEX ON users (LOWER(email))`.

### Pitfall 2: Wrong composite order
```sql
CREATE INDEX ON events (occurred_at, user_id);   -- WRONG for "events for user X"
```
You can't lead with a range column if you want to filter on equality. Put equality first.

### Pitfall 3: Indexing high-cardinality columns you never query
Every index has a write cost. Don't index columns "just in case" — measure with `pg_stat_user_indexes`, drop the unused ones.

### Pitfall 4: Forcing an index via `SET enable_seqscan=off`
If Postgres chose a seq scan, it's usually right (e.g. the query touches >5% of the table). The fix is almost always a *better* index or rewriting the query — not disabling the planner.

## How to verify your indexes are doing their job

```sql
-- Which indexes are actually used?
SELECT relname, indexrelname, idx_scan, idx_tup_read
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;

-- Which indexes are unused (candidates for dropping)?
SELECT relname, indexrelname
FROM pg_stat_user_indexes
WHERE idx_scan = 0;

-- Index bloat (run after VACUUM):
SELECT relname, pg_size_pretty(pg_relation_size(relname::regclass)) AS size
FROM pg_class WHERE relkind='i' ORDER BY pg_relation_size(relname::regclass) DESC;
```

The `v_index_usage` view in [`04_indexes.sql`](../init/04_indexes.sql) wraps the first query.
