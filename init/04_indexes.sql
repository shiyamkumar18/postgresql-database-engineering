-- 04_indexes.sql
-- Index strategy documented in docs/indexing.md.
-- Run AFTER seed data so partial indexes apply cleanly.

BEGIN;

-- users: email already unique via CITEXT constraint, but add trigram for LIKE
CREATE INDEX IF NOT EXISTS users_full_name_trgm_idx
    ON users USING GIN (full_name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS users_status_signup_idx
    ON users (status, signup_at DESC);

-- subscriptions: enforce "one active subscription per user" via PARTIAL UNIQUE
CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_one_active_per_user_uniq
    ON subscriptions (user_id)
    WHERE status IN ('trialing', 'active', 'past_due');

CREATE INDEX IF NOT EXISTS subscriptions_status_period_end_idx
    ON subscriptions (status, current_period_end)
    WHERE status IN ('trialing', 'active', 'past_due');

CREATE INDEX IF NOT EXISTS subscriptions_canceled_at_idx
    ON subscriptions (canceled_at DESC)
    WHERE status = 'canceled';

-- events: composite btree for the two most common access patterns
CREATE INDEX IF NOT EXISTS events_user_occurred_idx
    ON events (user_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS events_name_occurred_idx
    ON events (event_name, occurred_at DESC);

-- events: GIN for jsonb property filtering (e.g. feature=export)
CREATE INDEX IF NOT EXISTS events_properties_gin_idx
    ON events USING GIN (properties jsonb_path_ops);

-- events: BRIN for time-series bulk scans (low write overhead)
CREATE INDEX IF NOT EXISTS events_occurred_brin_idx
    ON events USING BRIN (occurred_at) WITH (pages_per_range = 32);

-- invoices: partial btree for "open invoices due soon" queries
CREATE INDEX IF NOT EXISTS invoices_open_due_idx
    ON invoices (due_at)
    WHERE status = 'open';

CREATE INDEX IF NOT EXISTS invoices_user_issued_idx
    ON invoices (user_id, issued_at DESC);

-- payments
CREATE INDEX IF NOT EXISTS payments_invoice_idx       ON payments (invoice_id);
CREATE INDEX IF NOT EXISTS payments_status_attempted_idx
    ON payments (status, attempted_at DESC);

CREATE INDEX IF NOT EXISTS refunds_payment_idx ON refunds (payment_id, requested_at DESC);

-- daily_usage_metrics: composite PK already covers (user,date,feature);
-- add a reverse for date-first scans (e.g. "all users active on date X")
CREATE INDEX IF NOT EXISTS daily_usage_date_feature_idx
    ON daily_usage_metrics (metric_date, feature);

COMMIT;

-- Helpful view: index usage stats for the optimization writeup
CREATE OR REPLACE VIEW v_index_usage AS
SELECT
    schemaname AS schema,
    relname    AS table,
    indexrelname AS index,
    idx_scan   AS scans,
    idx_tup_read,
    idx_tup_fetch,
    size       AS bytes
FROM (
    SELECT s.schemaname, s.relname, s.indexrelname, s.idx_scan,
           s.idx_tup_read, s.idx_tup_fetch,
           pg_relation_size(s.indexrelid) AS size,
           ROW_NUMBER() OVER (PARTITION BY s.relname ORDER BY s.idx_scan DESC) AS rn
    FROM pg_stat_user_indexes s
    WHERE s.schemaname = 'public'
) t WHERE rn = 1;
