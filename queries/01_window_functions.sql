-- 01_window_functions.sql
-- Window function patterns for SaaS analytics.
-- Each query is self-contained and \echo-labelled for psql readability.

\echo '=== Q1: Row number — last 3 events per user ==='
SELECT user_id, event_name, occurred_at, rn
FROM (
    SELECT user_id, event_name, occurred_at,
           ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY occurred_at DESC) AS rn
    FROM events
) t
WHERE rn <= 3
ORDER BY user_id, rn;

\echo '=== Q2: Rank — top users by event count ==='
SELECT user_id, event_count,
       RANK() OVER (ORDER BY event_count DESC) AS rank,
       DENSE_RANK() OVER (ORDER BY event_count DESC) AS dense_rank
FROM (
    SELECT user_id, COUNT(*) AS event_count
    FROM events
    GROUP BY user_id
) t
ORDER BY rank
LIMIT 10;

\echo '=== Q3: Lag — gap between consecutive logins ==='
WITH logins AS (
    SELECT user_id, occurred_at,
           LAG(occurred_at) OVER (PARTITION BY user_id ORDER BY occurred_at) AS prev_login
    FROM events
    WHERE event_name = 'login'
)
SELECT user_id, occurred_at, prev_login,
       EXTRACT(EPOCH FROM (occurred_at - prev_login))/3600 AS hours_since_last_login
FROM logins
WHERE prev_login IS NOT NULL
ORDER BY hours_since_last_login DESC
LIMIT 20;

\echo '=== Q4: Cumulative revenue by day ==='
SELECT
    d::date                                        AS day,
    COALESCE(SUM(p.amount_cents), 0)               AS daily_revenue_cents,
    SUM(SUM(p.amount_cents))
        OVER (ORDER BY d)                          AS cumulative_revenue_cents
FROM generate_series(
        (SELECT MIN(issued_at)::date FROM invoices),
        NOW()::date,
        INTERVAL '1 day'
    ) d
LEFT JOIN invoices  i ON i.issued_at::date = d
LEFT JOIN payments  p ON p.invoice_id = i.id AND p.status = 'succeeded'
GROUP BY d
ORDER BY d;

\echo '=== Q5: Percentile of invoice amount within plan ==='
SELECT
    s.plan_id,
    p.code AS plan_code,
    PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY i.amount_cents) AS p50_cents,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY i.amount_cents) AS p95_cents,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY i.amount_cents) AS p99_cents
FROM invoices i
JOIN subscriptions s ON s.id = i.subscription_id
JOIN plans p         ON p.id = s.plan_id
GROUP BY s.plan_id, p.code
ORDER BY p95_cents DESC;

\echo '=== Q6: First/last value per user without self-join ==='
SELECT DISTINCT
    user_id,
    FIRST_VALUE(occurred_at) OVER w AS first_event_at,
    LAST_VALUE (occurred_at)  OVER w AS last_event_at_in_window,
    COUNT(*) OVER w                 AS event_count_in_window
FROM events
WINDOW w AS (PARTITION BY user_id ORDER BY occurred_at
             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
ORDER BY user_id;
