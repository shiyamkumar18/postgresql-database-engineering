"""Dataset-level data-quality assertions (zero violations expected)."""
from __future__ import annotations


def _count_violations(cur, sql: str) -> int:
    cur.execute(f"SELECT COUNT(*) FROM ({sql}) AS violations")
    return cur.fetchone()[0]


def test_paid_invoices_are_covered_by_successful_captures(cur):
    sql = """
        SELECT i.id
        FROM invoices i
        LEFT JOIN payments p ON p.invoice_id = i.id AND p.status = 'succeeded'
        WHERE i.status = 'paid' AND i.amount_cents > 0
        GROUP BY i.id, i.amount_cents
        HAVING COALESCE(SUM(p.amount_cents), 0) < i.amount_cents
    """
    assert _count_violations(cur, sql) == 0, "Paid invoice is not fully covered by captures"


def test_t3_one_active_subscription_per_user(cur):
    sql = """
        SELECT user_id FROM subscriptions
        WHERE status IN ('trialing','active','past_due')
        GROUP BY user_id HAVING COUNT(*) > 1
    """
    assert _count_violations(cur, sql) == 0, "User with multiple active subscriptions"


def test_successful_payments_do_not_overcollect_invoice(cur):
    sql = """
        SELECT i.id
        FROM invoices i JOIN payments p ON p.invoice_id = i.id
        GROUP BY i.id, i.amount_cents
        HAVING COALESCE(SUM(p.amount_cents) FILTER (WHERE p.status = 'succeeded'), 0) > i.amount_cents
    """
    assert _count_violations(cur, sql) == 0, "Successful captures exceed invoice amount"


def test_refunds_do_not_exceed_successful_payment(cur):
    sql = """
        SELECT p.id
        FROM payments p JOIN refunds r ON r.payment_id = p.id
        GROUP BY p.id, p.amount_cents
        HAVING COALESCE(SUM(r.amount_cents) FILTER (WHERE r.status = 'succeeded'), 0) > p.amount_cents
    """
    assert _count_violations(cur, sql) == 0, "Refunds exceed captured payment"


def test_payment_currency_matches_invoice_currency(cur):
    sql = """
        SELECT p.id FROM payments p JOIN invoices i ON i.id = p.invoice_id
        WHERE p.currency <> i.currency
    """
    assert _count_violations(cur, sql) == 0, "Payment allocation currency differs from invoice currency"


def test_t7_events_not_before_signup(cur):
    sql = """
        SELECT e.id FROM events e JOIN users u ON u.id = e.user_id
        WHERE e.occurred_at < u.signup_at
    """
    assert _count_violations(cur, sql) == 0, "Event occurred before user signup"


def test_daily_usage_metrics_reconcile_with_events(cur):
    sql = """
        WITH event_aggregate AS (
            SELECT user_id, (occurred_at AT TIME ZONE 'UTC')::date AS metric_date,
                   properties->>'feature' AS feature, COUNT(*)::integer AS usage_count,
                   SUM((properties->>'duration_secs')::integer)::integer AS total_duration_secs
            FROM events WHERE event_name = 'feature_use'
            GROUP BY user_id, (occurred_at AT TIME ZONE 'UTC')::date, properties->>'feature'
        )
        SELECT COALESCE(m.user_id, e.user_id) AS user_id
        FROM daily_usage_metrics m
        FULL OUTER JOIN event_aggregate e
          ON e.user_id = m.user_id AND e.metric_date = m.metric_date AND e.feature = m.feature
        WHERE m.usage_count IS DISTINCT FROM e.usage_count
           OR m.total_duration_secs IS DISTINCT FROM e.total_duration_secs
    """
    assert _count_violations(cur, sql) == 0, "Daily aggregates do not reconcile with source events"


def test_only_successful_transactions_have_settlement_values(cur):
    sql = """
        SELECT id FROM payments
        WHERE status <> 'succeeded'
          AND (settlement_amount_cents IS NOT NULL
               OR settlement_currency IS NOT NULL OR exchange_rate IS NOT NULL)
        UNION ALL
        SELECT id FROM refunds
        WHERE status <> 'succeeded'
          AND (settlement_amount_cents IS NOT NULL
               OR settlement_currency IS NOT NULL OR exchange_rate IS NOT NULL)
    """
    assert _count_violations(cur, sql) == 0, "Unsettled records contain settlement values"
