-- 03_aggregations.sql
-- GROUPING SETS / ROLLUP / CUBE / FILTER for analytic-style summaries.

\echo '=== Q1: Revenue by country + plan (ROLLUP) ==='
SELECT
    COALESCE(u.country_code, 'ALL') AS country,
    COALESCE(p.code,           'ALL') AS plan_code,
    COUNT(DISTINCT i.user_id)        AS paying_users,
    SUM(p.amount_cents)              AS revenue_cents
FROM invoices  i
JOIN payments  p ON p.invoice_id = i.id AND p.status = 'succeeded'
JOIN users     u ON u.id = i.user_id
JOIN subscriptions s ON s.id = i.subscription_id
JOIN plans     pl ON pl.id = s.plan_id
GROUP BY ROLLUP (u.country_code, pl.code)
ORDER BY country, plan_code;

\echo '=== Q2: Event counts by name and weekday (CUBE) ==='
SELECT
    COALESCE(event_name::text, 'ALL')                       AS event_name,
    COALESCE(TO_CHAR(occurred_at, 'Dy'), 'ALL')            AS weekday,
    COUNT(*)                                                AS events
FROM events
WHERE occurred_at >= NOW() - INTERVAL '30 days'
GROUP BY CUBE (event_name, TO_CHAR(occurred_at, 'Dy'))
ORDER BY event_name, weekday;

\echo '=== Q3: FILTER clause — funnel counts in one pass ==='
SELECT
    user_id,
    COUNT(*) FILTER (WHERE event_name = 'signup')                 AS signups,
    COUNT(*) FILTER (WHERE event_name = 'login')                  AS logins,
    COUNT(*) FILTER (WHERE event_name = 'feature_use')            AS feature_uses,
    COUNT(*) FILTER (WHERE event_name = 'plan_change')            AS plan_changes,
    COUNT(*) FILTER (WHERE event_name = 'subscription_canceled')  AS cancels
FROM events
WHERE occurred_at >= NOW() - INTERVAL '30 days'
GROUP BY user_id
ORDER BY logins DESC NULLS LAST
LIMIT 20;

\echo '=== Q4: GROUPING SETS — revenue by (country), (plan), and grand total ==='
SELECT
    COALESCE(u.country_code, 'ALL') AS country,
    COALESCE(pl.code,         'ALL') AS plan_code,
    SUM(p.amount_cents)              AS revenue_cents
FROM payments p
JOIN invoices i ON i.id = p.invoice_id
JOIN subscriptions s ON s.id = i.subscription_id
JOIN plans pl ON pl.id = s.plan_id
JOIN users u  ON u.id  = i.user_id
WHERE p.status = 'succeeded'
GROUP BY GROUPING SETS (
    (u.country_code),
    (pl.code),
    ()
)
ORDER BY country NULLS LAST, plan_code NULLS LAST;
