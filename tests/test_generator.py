"""Unit tests for deterministic transformations in the mock-data generator."""
from __future__ import annotations

import importlib.util
import random
from datetime import datetime, timezone
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = PROJECT_ROOT / "scripts" / "generate_mock_data.py"
SPEC = importlib.util.spec_from_file_location("subly_mock_generator", GENERATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
mock_generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mock_generator)


def test_daily_usage_is_derived_from_feature_events():
    occurred_at = datetime(2026, 10, 12, 10, 30, tzinfo=timezone.utc)
    events = [
        ("e1", "u1", "feature_use", occurred_at, None,
         '{"feature":"export","duration_secs":12}'),
        ("e2", "u1", "feature_use", occurred_at, None,
         '{"feature":"export","duration_secs":8}'),
        ("e3", "u1", "login", occurred_at, None, "{}"),
        ("e4", "u2", "feature_use", occurred_at, None,
         '{"feature":"report","duration_secs":5}'),
    ]

    assert mock_generator._gen_daily_usage(events) == [
        ("u1", occurred_at.date(), "export", 2, 20),
        ("u2", occurred_at.date(), "report", 1, 5),
    ]


def test_paid_invoice_can_be_split_without_rounding_loss():
    random.seed(42)
    issued_at = datetime(2026, 10, 1, tzinfo=timezone.utc)
    invoice = (
        "invoice-1", "subscription-1", "user-1", issued_at,
        issued_at, 10_001, "USD", "paid", issued_at,
        issued_at, issued_at, None,
    )

    payments = mock_generator._gen_payments([invoice])
    captures = [p for p in payments if p[9] == "succeeded"]

    assert len(captures) >= 1
    assert sum(p[2] for p in captures) == 10_001
    assert all(p[3] == "USD" for p in captures)


def test_settlement_fx_is_recorded_separately(monkeypatch):
    monkeypatch.setattr(mock_generator.random, "random", lambda: 0.0)
    settlement_amount, settlement_currency, rate = mock_generator._payment_settlement(1_000, "USD")

    assert settlement_amount == 83_000
    assert settlement_currency == "INR"
    assert str(rate) == "83.00000000"


def test_refund_generator_creates_only_partial_refunds(monkeypatch):
    payment = (
        "payment-1", "invoice-1", 1_000, "USD", 83_000, "INR",
        mock_generator.Decimal("83.00000000"), "stripe", "charge-1",
        "succeeded", datetime(2026, 10, 1, tzinfo=timezone.utc),
        datetime(2026, 10, 1, 0, 5, tzinfo=timezone.utc), None,
    )
    monkeypatch.setattr(mock_generator.random, "random", lambda: 0.0)
    refunds = mock_generator._gen_refunds([payment])

    assert len(refunds) == 1
    assert 0 < refunds[0][2] < payment[2]
    assert refunds[0][4] == "INR"


def test_calendar_billing_interval_preserves_month_end_anchor():
    month_end = datetime(2026, 1, 31, 12, 0, tzinfo=timezone.utc)
    february_end = mock_generator._add_billing_interval(month_end, "monthly")
    march_end = mock_generator._add_billing_interval(month_end, "monthly", 2)

    assert february_end == datetime(2026, 2, 28, 12, 0, tzinfo=timezone.utc)
    assert march_end == datetime(2026, 3, 31, 12, 0, tzinfo=timezone.utc)


def test_invoice_generator_uses_plan_billing_interval():
    now = mock_generator._ts_now()
    started_at = now - mock_generator.timedelta(days=200)
    subscription = ("sub-q", "user-q", "plan-q", "active", started_at,
                    mock_generator._add_billing_interval(started_at, "quarterly", 3), None)

    invoices = mock_generator._gen_invoices(
        [subscription], {"plan-q": ("quarterly", 9_900, "USD")}
    )

    assert len(invoices) == 3
    assert all(row[5:7] == (9_900, "USD") for row in invoices)
    assert all(
        row[4] == mock_generator._add_billing_interval(row[3], "quarterly")
        for row in invoices
    )


def test_failed_attempt_has_no_settlement_values():
    attempted_at = datetime(2026, 10, 1, tzinfo=timezone.utc)
    payment = mock_generator._make_payment("invoice-failed", 2_500, "USD", attempted_at, "failed")

    assert payment[4:7] == (None, None, None)
    assert payment[11] is None
    assert payment[12] is not None


def test_deleted_user_history_stops_at_deletion_and_subscription_is_canceled():
    now = mock_generator._ts_now()
    signup_at = now - mock_generator.timedelta(days=20)
    deleted_at = now - mock_generator.timedelta(days=2)
    user = ("deleted-user", "deleted@test.example", "Deleted User", "IN",
            "deleted", signup_at, None, deleted_at)
    plan = ("plan-monthly", "pro_monthly", "monthly", 1_999, "USD")
    random.seed(3)

    subscription = mock_generator._gen_subscriptions([user], [plan])[0]
    events = mock_generator._gen_events([user], per_user=20)

    assert subscription[3] == "canceled"
    assert signup_at <= subscription[4] <= deleted_at
    assert subscription[6] == deleted_at
    assert all(event[3] <= deleted_at for event in events)
