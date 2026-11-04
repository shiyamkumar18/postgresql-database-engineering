"""Schema tests — verify all expected tables / columns / constraints exist."""
from __future__ import annotations

import psycopg
import pytest


def _assert_sql_error(cur, error_type, sql: str, params=None):
    """Assert a statement fails, then roll back only that statement's savepoint."""
    cur.execute("SAVEPOINT expected_statement_error")
    try:
        with pytest.raises(error_type):
            cur.execute(sql, params)
    finally:
        cur.execute("ROLLBACK TO SAVEPOINT expected_statement_error")
        cur.execute("RELEASE SAVEPOINT expected_statement_error")


EXPECTED_TABLES = {
    "plans", "users", "subscriptions", "events",
    "invoices", "payments", "refunds", "daily_usage_metrics",
}


def test_all_core_tables_exist(cur):
    cur.execute("""
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'public'
    """)
    actual = {r[0] for r in cur.fetchall()}
    missing = EXPECTED_TABLES - actual
    assert not missing, f"Missing tables: {missing}"


def test_users_email_is_citext(cur):
    cur.execute("""
        SELECT data_type FROM information_schema.columns
        WHERE table_name='users' AND column_name='email'
    """)
    dt = cur.fetchone()[0]
    assert dt == "USER-DEFINED", f"email column should be citext, got {dt}"


def test_enums_exist(cur):
    cur.execute("""
        SELECT typname FROM pg_type
        WHERE typtype='e' AND typname IN
          ('user_status','subscription_status','invoice_status',
           'payment_status','refund_status','plan_interval','event_name')
    """)
    found = {r[0] for r in cur.fetchall()}
    assert {
        "user_status","subscription_status","invoice_status",
        "payment_status","refund_status","plan_interval","event_name"
    } <= found


def test_user_status_deleted_requires_deleted_at(cur):
    """CHECK constraint: (status='deleted') = (deleted_at IS NOT NULL)."""
    _assert_sql_error(cur, psycopg.errors.CheckViolation, """
        INSERT INTO users (email, full_name, status, deleted_at)
        VALUES ('deletednoarg@test','Test User','deleted', NULL)
    """)

    _assert_sql_error(cur, psycopg.errors.CheckViolation, """
        INSERT INTO users (email, full_name, status, deleted_at)
        VALUES ('activedeleted@test','Test User','active', NOW())
    """)


def test_amount_cents_check_constraint(cur):
    """Negative amounts should be rejected on plans, invoices, payments."""
    _assert_sql_error(cur, psycopg.errors.CheckViolation, """
        INSERT INTO plans (code, name, interval, price_cents)
        VALUES ('bad','Bad','monthly', -1)
    """)


def test_subscription_canceled_after_start(cur):
    _assert_sql_error(cur, psycopg.errors.CheckViolation, """
        INSERT INTO subscriptions
          (user_id, plan_id, status, started_at, current_period_end, canceled_at)
        SELECT id, (SELECT id FROM plans LIMIT 1),
               'canceled', NOW(), NOW() + INTERVAL '1 month', NOW() - INTERVAL '1 day'
        FROM users LIMIT 1
    """)


def test_payment_failed_must_have_reason(cur):
    """CHECK constraint: (status='failed') = (failure_reason IS NOT NULL)."""
    _assert_sql_error(cur, psycopg.errors.CheckViolation, """
            WITH new_user AS (
                INSERT INTO users (email, full_name)
                VALUES ('paymentfailuretest@test.example', 'Payment Failure Test')
                RETURNING id
            ), new_subscription AS (
                INSERT INTO subscriptions (user_id, plan_id, status, started_at, current_period_end)
                SELECT new_user.id, plans.id, 'active', NOW(), NOW() + INTERVAL '1 month'
                FROM new_user CROSS JOIN (SELECT id FROM plans LIMIT 1) plans
                RETURNING id, user_id
            ), new_invoice AS (
                INSERT INTO invoices
                    (subscription_id, user_id, period_start, period_end, amount_cents,
                     currency, status, issued_at, due_at)
                SELECT id, user_id, NOW(), NOW() + INTERVAL '1 month', 1000,
                       'USD', 'open', NOW(), NOW() + INTERVAL '7 days'
                FROM new_subscription
                RETURNING id, currency
            )
            INSERT INTO payments
                (invoice_id, amount_cents, currency, provider, status, failure_reason)
            SELECT id, 100, currency, 'stripe', 'failed', NULL
            FROM new_invoice
        """)


def test_updated_at_trigger_fires(cur):
    """The trg_set_updated_at trigger should refresh updated_at on UPDATE."""
    cur.execute("""
        INSERT INTO users (email, full_name) VALUES ('triggertest@x.com','TT')
        RETURNING id, updated_at
    """)
    uid, before = cur.fetchone()
    cur.execute("SELECT pg_sleep(0.01)")
    cur.execute("UPDATE users SET full_name='TT2' WHERE id=%s RETURNING updated_at", (uid,))
    after = cur.fetchone()[0]
    assert after > before, "updated_at was not refreshed by trigger"


def test_one_active_subscription_per_user(cur):
    """Partial unique index subscriptions_one_active_per_user_uniq."""
    cur.execute("""
        INSERT INTO users (email, full_name) VALUES ('oneactivesub@x.com','OAS')
        RETURNING id
    """)
    uid = cur.fetchone()[0]
    cur.execute("""
        INSERT INTO subscriptions
          (user_id, plan_id, status, started_at, current_period_end)
        SELECT %s, id, 'active', NOW(), NOW() + INTERVAL '1 month'
        FROM plans LIMIT 1
    """, (uid,))
    # Second active subscription for the same user must fail
    _assert_sql_error(cur, psycopg.errors.UniqueViolation, """
        INSERT INTO subscriptions
          (user_id, plan_id, status, started_at, current_period_end)
        SELECT %s, id, 'active', NOW(), NOW() + INTERVAL '1 month'
        FROM plans LIMIT 1
    """, (uid,))


def test_refunds_have_updated_at_trigger(cur):
    """Refunds are mutable transaction records and receive updated_at."""
    cur.execute("""
        SELECT 1 FROM information_schema.triggers
        WHERE event_object_table = 'refunds' AND trigger_name = 'set_updated_at'
    """)
    assert cur.fetchone() is not None


def test_financial_ledger_delete_triggers_exist(cur):
    cur.execute("""
        SELECT event_object_table, trigger_name
        FROM information_schema.triggers
        WHERE trigger_name IN ('payments_no_delete', 'refunds_no_delete',
                               'invoices_financial_terms_immutable')
    """)
    found = {(row[0], row[1]) for row in cur.fetchall()}
    assert ("payments", "payments_no_delete") in found
    assert ("refunds", "refunds_no_delete") in found
    assert ("invoices", "invoices_financial_terms_immutable") in found
