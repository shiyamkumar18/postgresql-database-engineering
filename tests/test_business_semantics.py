"""Business-semantic regression tests for billing, refunds and cohorts."""
from __future__ import annotations

import psycopg
import pytest


def _make_invoice(cur, email: str, amount_cents: int = 10_000, currency: str = "USD") -> str:
    cur.execute(
        "INSERT INTO users (email, full_name) VALUES (%s, 'Billing Test') RETURNING id",
        (email,),
    )
    user_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM plans ORDER BY code LIMIT 1")
    plan_id = cur.fetchone()[0]
    cur.execute(
        """INSERT INTO subscriptions (user_id, plan_id, status, started_at, current_period_end)
           VALUES (%s, %s, 'active', NOW(), NOW() + INTERVAL '1 month') RETURNING id""",
        (user_id, plan_id),
    )
    subscription_id = cur.fetchone()[0]
    cur.execute(
        """INSERT INTO invoices
             (subscription_id, user_id, period_start, period_end, amount_cents,
              currency, status, issued_at, due_at)
           VALUES (%s, %s, NOW(), NOW() + INTERVAL '1 month', %s,
                   %s, 'open', NOW(), NOW() + INTERVAL '7 days')
           RETURNING id""",
        (subscription_id, user_id, amount_cents, currency),
    )
    return cur.fetchone()[0]


def _insert_successful_payment(cur, invoice_id: str, amount_cents: int,
                               currency: str = "USD", settlement_amount: int | None = None,
                               settlement_currency: str | None = None,
                               exchange_rate: str | None = None) -> str:
    cur.execute(
        """INSERT INTO payments
             (invoice_id, amount_cents, currency, settlement_amount_cents,
              settlement_currency, exchange_rate, provider, provider_charge_id,
              status, succeeded_at)
           VALUES (%s, %s, %s, %s, %s, %s, 'test-provider', %s,
                   'succeeded', NOW()) RETURNING id""",
        (invoice_id, amount_cents, currency, settlement_amount,
         settlement_currency, exchange_rate, f"test_{invoice_id}_{amount_cents}"),
    )
    return cur.fetchone()[0]


def test_invoice_can_be_settled_by_split_payments_and_fx(cur):
    invoice_id = _make_invoice(cur, "split-payment@test.example", amount_cents=10_000)
    _insert_successful_payment(cur, invoice_id, 4_000, "USD", 4_000, "USD", "1.0")
    _insert_successful_payment(cur, invoice_id, 6_000, "USD", 498_000, "INR", "83.0")

    cur.execute(
        """SELECT SUM(amount_cents), COUNT(*) FROM payments
           WHERE invoice_id = %s AND status = 'succeeded'""",
        (invoice_id,),
    )
    captured, payment_count = cur.fetchone()
    assert captured == 10_000
    assert payment_count == 2


def test_partial_refunds_are_allowed_but_cannot_exceed_capture(cur):
    invoice_id = _make_invoice(cur, "partial-refund@test.example", amount_cents=8_000)
    payment_id = _insert_successful_payment(cur, invoice_id, 8_000)
    cur.execute(
        """INSERT INTO refunds (payment_id, amount_cents, status, completed_at)
           VALUES (%s, 2_000, 'succeeded', NOW())""",
        (payment_id,),
    )
    cur.execute(
        """INSERT INTO refunds (payment_id, amount_cents, status, completed_at)
           VALUES (%s, 1_000, 'succeeded', NOW())""",
        (payment_id,),
    )
    with pytest.raises(psycopg.errors.CheckViolation):
        cur.execute(
            """INSERT INTO refunds (payment_id, amount_cents, status, completed_at)
               VALUES (%s, 6_000, 'succeeded', NOW())""",
            (payment_id,),
        )


def test_payment_currency_must_match_invoice_currency(cur):
    invoice_id = _make_invoice(cur, "currency-mismatch@test.example", currency="USD")
    with pytest.raises(psycopg.errors.CheckViolation):
        _insert_successful_payment(cur, invoice_id, 1_000, "EUR")


def test_cohort_view_returns_expected_known_counts(cur):
    # Compare the cohort's before/after values so unrelated generated users in
    # the same calendar week cannot make this test flaky.
    cur.execute("""SELECT (DATE_TRUNC('week', NOW() AT TIME ZONE 'UTC')::date - 21)""")
    cohort_week = cur.fetchone()[0]
    cur.execute(
        """SELECT week_n, cohort_size, retained_users
           FROM v_user_cohort_week
           WHERE cohort_week = %s AND week_n IN (0, 2)""",
        (cohort_week,),
    )
    before = {row[0]: (row[1], row[2]) for row in cur.fetchall()}

    cur.execute(
        """INSERT INTO users (email, full_name, signup_at)
           VALUES ('cohort-a@test.example', 'Cohort A', %s::date + INTERVAL '1 day'),
                  ('cohort-b@test.example', 'Cohort B', %s::date + INTERVAL '2 days')
           RETURNING id""",
        (cohort_week, cohort_week),
    )
    user_ids = [row[0] for row in cur.fetchall()]
    cur.execute(
        """INSERT INTO events (user_id, event_name, occurred_at)
           VALUES (%s, 'login', %s::date + INTERVAL '2 days'),
                  (%s, 'login', %s::date + INTERVAL '3 days'),
                  (%s, 'login', %s::date + INTERVAL '15 days')""",
        (user_ids[0], cohort_week, user_ids[1], cohort_week,
         user_ids[0], cohort_week),
    )
    cur.execute(
        """SELECT week_n, cohort_size, retained_users
           FROM v_user_cohort_week
           WHERE cohort_week = %s AND week_n IN (0, 2)
           ORDER BY week_n""",
        (cohort_week,),
    )
    after = {row[0]: (row[1], row[2]) for row in cur.fetchall()}
    assert after[0] == (before.get(0, (0, 0))[0] + 2,
                        before.get(0, (0, 0))[1] + 2)
    assert after[2] == (before.get(2, (0, 0))[0] + 2,
                        before.get(2, (0, 0))[1] + 1)


def test_successful_captures_cannot_exceed_invoice_total(cur):
    invoice_id = _make_invoice(cur, "overcapture@test.example", amount_cents=5_000)
    _insert_successful_payment(cur, invoice_id, 3_000)
    with pytest.raises(psycopg.errors.CheckViolation):
        _insert_successful_payment(cur, invoice_id, 2_001)


def test_captured_payment_financial_fields_are_immutable(cur):
    invoice_id = _make_invoice(cur, "immutable-payment@test.example", amount_cents=2_000)
    payment_id = _insert_successful_payment(cur, invoice_id, 2_000)
    with pytest.raises(psycopg.errors.CheckViolation):
        cur.execute("UPDATE payments SET amount_cents = 1_000 WHERE id = %s", (payment_id,))


def test_invoice_amount_and_currency_are_immutable_after_payment(cur):
    invoice_id = _make_invoice(cur, "immutable-invoice@test.example", amount_cents=2_000)
    _insert_successful_payment(cur, invoice_id, 2_000)
    with pytest.raises(psycopg.errors.CheckViolation):
        cur.execute("UPDATE invoices SET amount_cents = 1_000 WHERE id = %s", (invoice_id,))




def test_invoice_currency_is_immutable_after_payment(cur):
    invoice_id = _make_invoice(cur, "immutable-invoice-currency@test.example", amount_cents=2_000)
    _insert_successful_payment(cur, invoice_id, 2_000)
    with pytest.raises(psycopg.errors.CheckViolation):
        cur.execute("UPDATE invoices SET currency = 'EUR' WHERE id = %s", (invoice_id,))


def test_payment_ledger_rows_cannot_be_deleted(cur):
    invoice_id = _make_invoice(cur, "no-delete-payment@test.example", amount_cents=2_000)
    payment_id = _insert_successful_payment(cur, invoice_id, 2_000)
    with pytest.raises(psycopg.errors.CheckViolation):
        cur.execute("DELETE FROM payments WHERE id = %s", (payment_id,))


def test_refund_ledger_rows_cannot_be_deleted(cur):
    invoice_id = _make_invoice(cur, "no-delete-refund@test.example", amount_cents=2_000)
    payment_id = _insert_successful_payment(cur, invoice_id, 2_000)
    cur.execute(
        """INSERT INTO refunds (payment_id, amount_cents, status, completed_at)
           VALUES (%s, 500, 'succeeded', NOW()) RETURNING id""",
        (payment_id,),
    )
    refund_id = cur.fetchone()[0]
    with pytest.raises(psycopg.errors.CheckViolation):
        cur.execute("DELETE FROM refunds WHERE id = %s", (refund_id,))


def test_failed_payment_cannot_claim_settlement(cur):
    invoice_id = _make_invoice(cur, "failed-settlement@test.example", amount_cents=2_000)
    with pytest.raises(psycopg.errors.CheckViolation):
        cur.execute(
            """INSERT INTO payments
                 (invoice_id, amount_cents, currency, settlement_amount_cents,
                  settlement_currency, exchange_rate, provider, status, failure_reason)
               VALUES (%s, 2_000, 'USD', 2_000, 'USD', 1.0,
                       'test-provider', 'failed', 'card_declined')""",
            (invoice_id,),
        )


def test_pending_payment_can_resolve_with_settlement_metadata(cur):
    invoice_id = _make_invoice(cur, "pending-payment-resolution@test.example", amount_cents=2_500)
    cur.execute(
        """INSERT INTO payments (invoice_id, amount_cents, currency, provider, status)
           VALUES (%s, 2_500, 'USD', 'test-provider', 'pending') RETURNING id""",
        (invoice_id,),
    )
    payment_id = cur.fetchone()[0]
    cur.execute(
        """UPDATE payments
           SET status = 'succeeded', succeeded_at = NOW(),
               provider_charge_id = 'ch_resolution_test',
               settlement_amount_cents = 207_500,
               settlement_currency = 'INR', exchange_rate = 83.0
           WHERE id = %s
           RETURNING status, settlement_currency""",
        (payment_id,),
    )
    assert cur.fetchone() == ('succeeded', 'INR')


def test_pending_refund_can_resolve_with_settlement_metadata(cur):
    invoice_id = _make_invoice(cur, "pending-refund-resolution@test.example", amount_cents=2_500)
    payment_id = _insert_successful_payment(cur, invoice_id, 2_500)
    cur.execute(
        """INSERT INTO refunds (payment_id, amount_cents, status)
           VALUES (%s, 500, 'pending') RETURNING id""",
        (payment_id,),
    )
    refund_id = cur.fetchone()[0]
    cur.execute(
        """UPDATE refunds
           SET status = 'succeeded', completed_at = NOW(),
               provider_refund_id = 're_resolution_test',
               settlement_amount_cents = 41_500,
               settlement_currency = 'INR', exchange_rate = 83.0
           WHERE id = %s
           RETURNING status, settlement_currency""",
        (refund_id,),
    )
    assert cur.fetchone() == ('succeeded', 'INR')
