-- 02_ctes.sql
-- Common Table Expressions — recursive + chained for SaaS analytics.

\echo '=== Q1: Subscription lifecycle funnel (chained CTEs) ==='
WITH signed_up AS (
    SELECT user_id, MIN(occurred_at) AS signup_at
    FROM events WHERE event_name = 'signup' GROUP BY user_id
),
trial_started AS (
    SELECT user_id, started_at FROM subscriptions WHERE status = 'trialing'
),
paid AS (
    SELECT s.user_id, MIN(p.succeeded_at) AS first_paid_at
    FROM subscriptions s
    JOIN invoices  i ON i.subscription_id = s.id
    JOIN payments  p ON p.invoice_id = i.id AND p.status = 'succeeded'
    GROUP BY s.user_id
)
SELECT
    (SELECT COUNT(*) FROM signed_up)      AS signups,
    (SELECT COUNT(*) FROM trial_started)  AS trials,
    (SELECT COUNT(*) FROM paid)           AS first_paid,
    ROUND(100.0 * (SELECT COUNT(*) FROM trial_started)
                  / NULLIF((SELECT COUNT(*) FROM signed_up), 0), 2) AS trial_pct,
    ROUND(100.0 * (SELECT COUNT(*) FROM paid)
                  / NULLIF((SELECT COUNT(*) FROM signed_up), 0), 2) AS paid_pct;

\echo '=== Q2: Recursive — daily cohort expansion (day 1..30 retention) ==='
WITH RECURSIVE cohort AS (
    SELECT user_id, DATE(signup_at) AS cohort_day
    FROM users WHERE signup_at >= NOW() - INTERVAL '90 days'
),
days(n) AS (
    SELECT 0 UNION ALL SELECT n+1 FROM days WHERE n < 30
),
retention AS (
    SELECT c.cohort_day, d.n,
           COUNT(DISTINCT e.user_id) AS retained_users
    FROM cohort c
    CROSS JOIN days d
    LEFT JOIN events e
           ON e.user_id = c.user_id
          AND e.occurred_at::date = c.cohort_day + d.n
    GROUP BY c.cohort_day, d.n
)
SELECT cohort_day, n AS day_n, retained_users,
       ROUND(100.0 * retained_users
             / NULLIF(MAX(retained_users) OVER (PARTITION BY cohort_day WHERE n=0), 0), 1)
       AS retention_pct
FROM retention
ORDER BY cohort_day, n;

\echo '=== Q3: MRR (Monthly Recurring Revenue) by month ==='
WITH monthly_mrr AS (
    SELECT
        DATE_TRUNC('month', started_at) AS month,
        plan_id,
        SUM(p.price_cents) AS mrr_cents
    FROM subscriptions s
    JOIN plans p ON p.id = s.plan_id
    WHERE s.status IN ('trialing','active','past_due')
      AND s.started_at <= NOW()
      AND (s.current_period_end > NOW() OR s.canceled_at > DATE_TRUNC('month', NOW()))
    GROUP BY 1, 2
)
SELECT month,
       SUM(mrr_cents) AS mrr_cents,
       SUM(SUM(mrr_cents)) OVER (ORDER BY month) AS cumulative_mrr_cents
FROM monthly_mrr
GROUP BY month
ORDER BY month;

\echo '=== Q4: CTE with NOT EXISTS — users with no paid invoices ==='
WITH paid_users AS (
    SELECT DISTINCT i.user_id
    FROM invoices i
    JOIN payments p ON p.invoice_id = i.id AND p.status = 'succeeded'
)
SELECT u.id, u.email, u.signup_at
FROM users u
WHERE u.status = 'active'
  AND NOT EXISTS (SELECT 1 FROM paid_users pu WHERE pu.user_id = u.id)
ORDER BY u.signup_at DESC
LIMIT 50;
