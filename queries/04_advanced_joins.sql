-- 04_advanced_joins.sql
-- LATERAL, anti/semi joins, FULL OUTER JOIN for reconciliation.

\echo '=== Q1: LATERAL — top 3 events per user (one row per user) ==='
SELECT u.id AS user_id, u.email, t.event_name, t.occurred_at
FROM users u
CROSS JOIN LATERAL (
    SELECT e.event_name, e.occurred_at
    FROM events e
    WHERE e.user_id = u.id
    ORDER BY e.occurred_at DESC
    LIMIT 3
) t
WHERE u.status = 'active'
ORDER BY u.email;

\echo '=== Q2: LATERAL — latest successful payment per invoice ==='
SELECT i.id AS invoice_id, i.amount_cents, p.id AS payment_id, p.status
FROM invoices i
LEFT JOIN LATERAL (
    SELECT *
    FROM payments p
    WHERE p.invoice_id = i.id
    ORDER BY p.attempted_at DESC
    LIMIT 1
) p ON TRUE
WHERE i.status = 'open'
ORDER BY i.issued_at DESC
LIMIT 20;

\echo '=== Q3: ANTI JOIN — users who have NEVER had a login event ==='
SELECT u.id, u.email, u.signup_at
FROM users u
WHERE NOT EXISTS (
    SELECT 1 FROM events e
    WHERE e.user_id = u.id AND e.event_name = 'login'
)
ORDER BY u.signup_at DESC;

\echo '=== Q4: SEMI JOIN — users who triggered feature_use last week ==='
SELECT u.id, u.email
FROM users u
WHERE EXISTS (
    SELECT 1 FROM events e
    WHERE e.user_id = u.id
      AND e.event_name = 'feature_use'
      AND e.occurred_at >= NOW() - INTERVAL '7 days'
)
ORDER BY u.email;

\echo '=== Q5: FULL OUTER JOIN — reconcile invoices to payments (find orphans) ==='
SELECT
    i.id AS invoice_id,
    i.status AS invoice_status,
    p.id AS payment_id,
    p.status AS payment_status,
    CASE
        WHEN i.id IS NULL THEN 'payment_without_invoice'
        WHEN p.id IS NULL THEN 'invoice_without_payment'
        ELSE 'matched'
    END AS reconciliation_state
FROM invoices i
FULL OUTER JOIN payments p ON p.invoice_id = i.id
WHERE (i.id IS NULL OR p.id IS NULL)
ORDER BY reconciliation_state;
