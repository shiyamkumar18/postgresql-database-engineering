-- 01_acid_demo.sql
-- Atomicity in practice: subscription renewal = invoice + payment + period bump.
-- Run from a single psql session. It selects the nearest active paid subscription,
-- so the demo remains runnable after earlier executions. If any statement fails,
-- the whole transaction rolls back
-- and the subscription is left untouched.

\pset pager off
\set ON_ERROR_STOP on

\echo '=== Setup: pick the most recent active subscription to renew ==='
SELECT s.id AS sub_to_renew
FROM subscriptions s
JOIN plans p ON p.id = s.plan_id
WHERE s.status = 'active'
  AND p.price_cents > 0
ORDER BY s.current_period_end
LIMIT 1
\gset

\echo ''
\echo '=== BEGIN: subscription renewal transaction ==='
BEGIN;

-- 1. Lock the subscription row so no other renewal can run concurrently.
SELECT id, status, current_period_end
FROM subscriptions
WHERE id = :'sub_to_renew'
FOR UPDATE;

-- 2. Compute new period from the plan's actual billing interval.
UPDATE subscriptions s
SET current_period_end = s.current_period_end +
        CASE p.interval
            WHEN 'monthly' THEN INTERVAL '1 month'
            WHEN 'quarterly' THEN INTERVAL '3 months'
            WHEN 'yearly' THEN INTERVAL '1 year'
        END,
    status = 'active'
FROM plans p
WHERE s.id = :'sub_to_renew'
  AND p.id = s.plan_id
RETURNING s.id, s.status, s.current_period_end \gset

-- 3. Issue the invoice for the new period.
INSERT INTO invoices
    (subscription_id, user_id, period_start, period_end,
     amount_cents, currency, status, issued_at, due_at)
SELECT
    s.id, s.user_id,
    s.current_period_end - CASE p.interval
        WHEN 'monthly' THEN INTERVAL '1 month'
        WHEN 'quarterly' THEN INTERVAL '3 months'
        WHEN 'yearly' THEN INTERVAL '1 year'
    END,
    s.current_period_end,
    p.price_cents, p.currency, 'open', NOW(), NOW() + INTERVAL '7 days'
FROM subscriptions s
JOIN plans p ON p.id = s.plan_id
WHERE s.id = :'sub_to_renew'
RETURNING id, amount_cents, currency \gset

\echo 'Invoice :invoice_id issued for :amount_cents cents.'

-- 4. Simulate a successful payment charge (Stripe webhook would normally fire this).
INSERT INTO payments
    (invoice_id, amount_cents, currency,
     settlement_amount_cents, settlement_currency, exchange_rate,
     provider, provider_charge_id, status, attempted_at, succeeded_at)
VALUES
    (:'invoice_id', :'amount_cents', :'currency',
     :'amount_cents', :'currency', 1.0,
     'stripe', 'ch_demo_' || REPLACE(CAST(NOW() AS TEXT), ' ', '_'),
     'succeeded', NOW(), NOW())
RETURNING id, status \gset

-- 5. Mark invoice as paid (depends on payment success).
UPDATE invoices
SET status  = 'paid',
    paid_at = NOW()
WHERE id = :'invoice_id';

\echo ''
\echo '=== COMMIT ==='
COMMIT;

\echo 'Renewal complete: subscription extended, invoice paid, payment recorded.'
\echo 'If ANY of the above statements had failed, ROLLBACK would leave all four tables untouched.'
