-- 02_data_tests.sql
-- SQL-level data quality assertions. Each query returns VIOLATIONS only.
-- Empty result sets indicate the corresponding rule passes.

\echo '=== T1: Active subscription periods must be in the future ==='
SELECT id AS subscription_id, user_id, current_period_end
FROM subscriptions
WHERE status IN ('trialing','active','past_due')
  AND current_period_end <= NOW();

\echo '=== T2: Paid invoices must be fully covered by successful captures ==='
SELECT i.id AS invoice_id, i.amount_cents,
       COALESCE(SUM(p.amount_cents) FILTER (WHERE p.status = 'succeeded'), 0) AS captured_cents
FROM invoices i
LEFT JOIN payments p ON p.invoice_id = i.id
WHERE i.status = 'paid' AND i.amount_cents > 0
GROUP BY i.id, i.amount_cents
HAVING COALESCE(SUM(p.amount_cents) FILTER (WHERE p.status = 'succeeded'), 0) < i.amount_cents;

\echo '=== T3: A user must not have more than one current subscription ==='
SELECT user_id, COUNT(*) AS active_subs
FROM subscriptions
WHERE status IN ('trialing','active','past_due')
GROUP BY user_id
HAVING COUNT(*) > 1;

\echo '=== T4: Successful captures must not exceed invoice balances ==='
SELECT i.id AS invoice_id, i.amount_cents,
       SUM(p.amount_cents) FILTER (WHERE p.status = 'succeeded') AS captured_cents
FROM invoices i
JOIN payments p ON p.invoice_id = i.id
GROUP BY i.id, i.amount_cents
HAVING SUM(p.amount_cents) FILTER (WHERE p.status = 'succeeded') > i.amount_cents;

\echo '=== T5: Payment currency must match invoice currency ==='
SELECT p.id AS payment_id, p.currency AS payment_currency, i.currency AS invoice_currency
FROM payments p JOIN invoices i ON i.id = p.invoice_id
WHERE p.currency <> i.currency;

\echo '=== T6: Successful refunds must not exceed their successful payment ==='
SELECT p.id AS payment_id, p.amount_cents AS captured_cents,
       SUM(r.amount_cents) FILTER (WHERE r.status = 'succeeded') AS refunded_cents
FROM payments p JOIN refunds r ON r.payment_id = p.id
GROUP BY p.id, p.amount_cents
HAVING SUM(r.amount_cents) FILTER (WHERE r.status = 'succeeded') > p.amount_cents;

\echo '=== T7: Events must not precede user signup ==='
SELECT e.id AS event_id, e.user_id, e.occurred_at, u.signup_at
FROM events e JOIN users u ON u.id = e.user_id
WHERE e.occurred_at < u.signup_at;

\echo '=== T8: Feature-use events must have valid feature and duration properties ==='
SELECT id, properties
FROM events
WHERE event_name = 'feature_use'
  AND (jsonb_typeof(properties->'feature') IS DISTINCT FROM 'string'
       OR COALESCE(properties->>'feature', '') = ''
       OR jsonb_typeof(properties->'duration_secs') IS DISTINCT FROM 'number'
       OR NOT COALESCE((properties->>'duration_secs') ~ '^[0-9]+$', FALSE));

\echo '=== T9: Daily usage metrics must exactly reconcile with feature-use events ==='
WITH event_aggregate AS (
    SELECT user_id,
           (occurred_at AT TIME ZONE 'UTC')::date AS metric_date,
           properties->>'feature' AS feature,
           COUNT(*)::integer AS usage_count,
           SUM(COALESCE((properties->>'duration_secs')::integer, 0))::integer AS total_duration_secs
    FROM events
    WHERE event_name = 'feature_use'
    GROUP BY user_id, (occurred_at AT TIME ZONE 'UTC')::date, properties->>'feature'
), comparison AS (
    SELECT COALESCE(m.user_id, e.user_id) AS user_id,
           COALESCE(m.metric_date, e.metric_date) AS metric_date,
           COALESCE(m.feature, e.feature) AS feature,
           m.usage_count AS metric_count,
           e.usage_count AS event_count,
           m.total_duration_secs AS metric_duration_secs,
           e.total_duration_secs AS event_duration_secs
    FROM daily_usage_metrics m
    FULL OUTER JOIN event_aggregate e
      ON e.user_id = m.user_id
     AND e.metric_date = m.metric_date
     AND e.feature = m.feature
)
SELECT * FROM comparison
WHERE metric_count IS DISTINCT FROM event_count
   OR metric_duration_secs IS DISTINCT FROM event_duration_secs;

\echo '=== T10: Only successful financial transactions may contain settlement values ==='
SELECT id AS payment_id, 'payment' AS record_type
FROM payments
WHERE status <> 'succeeded'
  AND (settlement_amount_cents IS NOT NULL
       OR settlement_currency IS NOT NULL
       OR exchange_rate IS NOT NULL)
UNION ALL
SELECT id AS payment_id, 'refund' AS record_type
FROM refunds
WHERE status <> 'succeeded'
  AND (settlement_amount_cents IS NOT NULL
       OR settlement_currency IS NOT NULL
       OR exchange_rate IS NOT NULL);
