#!/usr/bin/env python3
"""generate_mock_data.py

Generate realistic-volume SaaS data into the Subly PostgreSQL database:
    - 1,000 users (configurable via --users)
    - 1 current subscription per generated user in this baseline dataset
    - 50 events per user on average
    - up to 6 recent invoices per subscription using its billing interval
    - partial/split payment captures and separate refund transactions
    - daily_usage_metrics derived from generated feature_use events

Run from the project host after PostgreSQL is ready:
    python scripts/generate_mock_data.py
"""
from __future__ import annotations

import argparse
import calendar
import json
import os
import random
import sys
import uuid
from collections import defaultdict
from decimal import Decimal, ROUND_HALF_UP
from datetime import datetime, timedelta, timezone
from typing import Iterable

import psycopg

# ---------------------------------------------------------------------------
DSN = os.environ.get("DATABASE_URL", "postgresql://subly:subly@localhost:5432/subly_test")

COUNTRIES = ["US", "IN", "GB", "DE", "FR", "BR", "JP", "AU", "CA", "SG"]
FIRST_NAMES = ["Alice", "Bob", "Carol", "Diego", "Emma", "Feng", "Grace", "Haruto",
               "Ingrid", "Jana", "Karl", "Lata", "Mei", "Noah", "Olivia", "Priya",
               "Quan", "Rina", "Sven", "Tariq", "Uma", "Viktor", "Wei", "Xiomara",
               "Yuki", "Zara"]
LAST_NAMES = ["Tanaka", "Marley", "O'Neil", "Kumar", "Schmidt", "Dubois", "Silva",
              "Sato", "Brown", "Patel", "Nguyen", "Reyes", "Khan", "Ivanov", "Singh"]
FEATURES = ["export", "dashboard", "report", "integration", "ai_assistant", "audit_log"]
PROVIDERS = ["stripe", "razorpay", "paypal"]
EVENT_NAMES = ["signup", "login", "logout", "feature_use",
               "plan_change", "invoice_viewed", "payment_failed",
               "subscription_canceled"]
FAIL_REASONS = ["insufficient_funds", "card_declined", "expired_card", "network_error"]


def _ts_now() -> datetime:
    return datetime.now(timezone.utc)


def _gen_users(n: int) -> list[tuple]:
    rows = []
    now = _ts_now()
    for i in range(n):
        first = random.choice(FIRST_NAMES).lower()
        last = random.choice(LAST_NAMES).lower()
        email = f"{first}.{last}.{i}@subly.demo"
        signup_at = now - timedelta(days=random.randint(0, 365))
        deleted = random.random() < 0.05
        age_seconds = max(0, int((now - signup_at).total_seconds()))
        deleted_at = (signup_at + timedelta(seconds=random.randint(0, age_seconds))) if deleted else None
        last_login_at = min(signup_at + timedelta(hours=random.randint(1, 240)), now) if not deleted else None
        rows.append((
            str(uuid.uuid4()), email, f"{first.title()} {last.title()}",
            random.choice(COUNTRIES),
            "deleted" if deleted else ("suspended" if random.random() < 0.05 else "active"),
            signup_at, last_login_at, deleted_at,
        ))
    return rows


def _add_billing_interval(value: datetime, interval: str, periods: int = 1) -> datetime:
    """Add calendar billing periods while preserving the original day anchor."""
    months_per_period = {"monthly": 1, "quarterly": 3, "yearly": 12}
    try:
        months = months_per_period[interval] * periods
    except KeyError as exc:
        raise ValueError(f"Unsupported billing interval: {interval}") from exc
    month_index = value.month - 1 + months
    year = value.year + month_index // 12
    month = month_index % 12 + 1
    day = min(value.day, calendar.monthrange(year, month)[1])
    return value.replace(year=year, month=month, day=day)


def _gen_subscriptions(users: list[tuple], plans: list[tuple]) -> list[tuple]:
    """Generate one current/historical subscription per user in this baseline dataset."""
    rows = []
    now = _ts_now()
    for user in users:
        uid, signup_at, deleted_at = user[0], user[5], user[7]
        plan = random.choice(plans)
        interval = plan[2]
        latest_start_at = deleted_at if deleted_at is not None else now
        available_seconds = max(0, int((latest_start_at - signup_at).total_seconds()))
        started_at = signup_at + timedelta(seconds=random.randint(0, available_seconds))

        # Deleted users only receive historical canceled subscriptions.
        r = random.random()
        canceled_at = None
        if deleted_at is not None:
            status, canceled_at = "canceled", deleted_at
        elif r < 0.65:
            status = "active"
        elif r < 0.80:
            status = "trialing"
        elif r < 0.90:
            status = "past_due"
        else:
            status = "canceled"
            age_seconds = max(0, int((now - started_at).total_seconds()))
            canceled_at = started_at + timedelta(seconds=random.randint(0, age_seconds))

        if canceled_at is not None:
            current_period_end = _add_billing_interval(canceled_at, interval)
        else:
            period_number = 1
            current_period_end = _add_billing_interval(started_at, interval, period_number)
            while current_period_end <= now:
                period_number += 1
                current_period_end = _add_billing_interval(started_at, interval, period_number)

        rows.append((
            str(uuid.uuid4()), uid, plan[0], status, started_at,
            current_period_end, canceled_at,
            random.choice(["too_expensive", "missing_features", "switched_to_competitor"])
            if canceled_at else None,
        ))
    return rows


def _gen_events(users: list[tuple], per_user: int = 50) -> list[tuple]:
    rows = []
    now = _ts_now()
    for user in users:
        uid, signup_at, deleted_at = user[0], user[5], user[7]
        latest_at = deleted_at if deleted_at is not None else now
        earliest = max(signup_at, latest_at - timedelta(days=90))
        span_seconds = max(0, int((latest_at - earliest).total_seconds()))
        for _ in range(per_user):
            evt = random.choices(
                EVENT_NAMES,
                weights=[1, 30, 25, 25, 3, 5, 5, 1],
                k=1,
            )[0]
            occurred_at = earliest + timedelta(seconds=random.randint(0, span_seconds))
            props = {}
            if evt == "feature_use":
                props = {"feature": random.choice(FEATURES),
                         "duration_secs": random.randint(1, 600)}
            elif evt == "login":
                props = {"ip": f"10.0.{random.randint(0,255)}.{random.randint(0,255)}"}
            elif evt == "signup":
                props = {"utm": random.choice(["google", "twitter", "referral", "direct"])}
            rows.append((str(uuid.uuid4()), uid, evt, occurred_at,
                         str(uuid.uuid4()) if evt != "signup" else None,
                        _props_json(props)))
    return rows


def _props_json(d: dict) -> str:
    import json
    return json.dumps(d)


def _gen_invoices(subscriptions: list[tuple], plans_by_id: dict) -> list[tuple]:
    """Generate up to six recent invoices using each plan's calendar interval."""
    rows = []
    now = _ts_now()
    for (sid, uid, plan_id, status, started_at, _cpe, *_rest) in subscriptions:
        if status == "canceled":
            continue
        interval, plan_price, plan_currency = plans_by_id[plan_id]
        periods = []
        period_number = 0
        while len(periods) < 100:
            period_start = _add_billing_interval(started_at, interval, period_number)
            if period_start > now:
                break
            period_end = _add_billing_interval(started_at, interval, period_number + 1)
            periods.append((period_start, period_end))
            period_number += 1
        for period_start, period_end in periods[-6:]:
            issued_at = period_start
            due_at = issued_at + timedelta(days=7)
            if random.random() < 0.95:  # 95% are paid
                inv_status = "paid"
                paid_at = min(issued_at + timedelta(days=random.randint(1, 5)), now)
            else:
                inv_status = "open"
                paid_at = None
            rows.append((str(uuid.uuid4()), sid, uid, period_start, period_end,
                         plan_price, plan_currency, inv_status, issued_at, due_at, paid_at, None))
    return rows


def _payment_settlement(amount_cents: int, invoice_currency: str) -> tuple[int, str, Decimal]:
    """Return settlement amount/currency and rate (settlement per invoice unit)."""
    if invoice_currency == "USD" and random.random() < 0.12:
        settlement_currency, rate = "INR", Decimal("83.00000000")
    else:
        settlement_currency, rate = invoice_currency, Decimal("1.00000000")
    settlement_cents = int(
        (Decimal(amount_cents) * rate).quantize(Decimal("1"), rounding=ROUND_HALF_UP)
    )
    return settlement_cents, settlement_currency, rate


def _make_payment(invoice_id: str, amount_cents: int, currency: str,
                  attempted_at: datetime, status: str) -> tuple:
    if status == "succeeded":
        settlement_cents, settlement_currency, rate = _payment_settlement(amount_cents, currency)
        succeeded_at = min(attempted_at + timedelta(minutes=5), _ts_now())
    else:
        # Failed/pending attempts do not settle funds; never fabricate settlement data.
        settlement_cents, settlement_currency, rate = None, None, None
        succeeded_at = None
    return (
        str(uuid.uuid4()), invoice_id, amount_cents, currency,
        settlement_cents, settlement_currency, rate,
        random.choice(PROVIDERS),
        f"ch_{uuid.uuid4().hex[:24]}" if status == "succeeded" else None,
        status, attempted_at, succeeded_at,
        None if status == "succeeded" else random.choice(FAIL_REASONS),
    )


def _split_amount(total_cents: int, parts: int) -> list[int]:
    """Split an integer-cent amount into positive parts with no rounding loss."""
    parts = max(1, min(parts, total_cents))
    base, remainder = divmod(total_cents, parts)
    return [base + (1 if i < remainder else 0) for i in range(parts)]


def _gen_payments(invoices: list[tuple]) -> list[tuple]:
    """Generate retry attempts and one-or-more captures per invoice.

    Payment.amount_cents is the amount allocated in invoice currency; settlement
    fields record the processor-side currency after FX conversion.
    """
    rows = []
    for invoice in invoices:
        inv_id, amount_cents, currency, status, issued_at = (
            invoice[0], invoice[5], invoice[6], invoice[7], invoice[8]
        )
        if amount_cents <= 0:
            # Zero-value invoices (e.g. the free plan) need no payment record.
            continue

        if status == "paid":
            parts = _split_amount(amount_cents, random.randint(1, 3))
            for index, part in enumerate(parts):
                attempt_at = min(issued_at + timedelta(hours=index * 2 + 1), _ts_now())
                if index == 0 and random.random() < 0.10:
                    rows.append(_make_payment(inv_id, part, currency, attempt_at, "failed"))
                    attempt_at = min(attempt_at + timedelta(minutes=30), _ts_now())
                rows.append(_make_payment(inv_id, part, currency, attempt_at, "succeeded"))
        else:
            # Open invoices may have a partial capture, a failed attempt, or both.
            if random.random() < 0.20 and amount_cents > 1:
                partial = max(1, amount_cents // random.randint(3, 5))
                rows.append(_make_payment(inv_id, partial, currency,
                                          min(issued_at + timedelta(hours=1), _ts_now()), "succeeded"))
                remainder = amount_cents - partial
            else:
                remainder = amount_cents
            rows.append(_make_payment(inv_id, remainder, currency,
                                      min(issued_at + timedelta(hours=2), _ts_now()), "failed"))
    return rows


def _gen_refunds(payments: list[tuple]) -> list[tuple]:
    """Generate occasional partial refunds as independent financial records."""
    rows = []
    now = _ts_now()
    for payment in payments:
        (payment_id, _invoice_id, amount_cents, _invoice_currency,
         _settlement_cents, settlement_currency, exchange_rate, _provider,
         _charge_id, status, _attempted_at, succeeded_at, _failure_reason) = payment
        # Leave at least an hour between capture and the simulated completed refund.
        if (status != "succeeded" or amount_cents < 2 or succeeded_at is None
                or succeeded_at > now - timedelta(hours=1) or random.random() >= 0.06):
            continue
        # Strictly partial so the sample demonstrates a payment with remaining value.
        refund_cents = random.randint(1, amount_cents - 1)
        settlement_refund = int(
            (Decimal(refund_cents) * exchange_rate).quantize(
                Decimal("1"), rounding=ROUND_HALF_UP
            )
        )
        completed_at = min(succeeded_at + timedelta(hours=1), now)
        requested_at = completed_at - timedelta(minutes=5)
        rows.append((
            str(uuid.uuid4()), payment_id, refund_cents,
            settlement_refund, settlement_currency, exchange_rate,
            f"re_{uuid.uuid4().hex[:24]}", "succeeded",
            random.choice(["customer_request", "duplicate_charge", "service_credit"]),
            requested_at, completed_at,
        ))
    return rows


def _gen_daily_usage(events: list[tuple]) -> list[tuple]:
    """Aggregate daily feature-use counts and duration directly from events."""
    totals: dict[tuple, list[int]] = defaultdict(lambda: [0, 0])
    for event in events:
        _event_id, user_id, event_name_value, occurred_at, _session_id, properties_json = event
        if event_name_value != "feature_use":
            continue
        properties = json.loads(properties_json)
        feature = properties["feature"]
        metric_date = occurred_at.astimezone(timezone.utc).date()
        aggregate = totals[(user_id, metric_date, feature)]
        aggregate[0] += 1
        aggregate[1] += int(properties.get("duration_secs", 0))
    return [
        (user_id, metric_date, feature, count, duration_secs)
        for (user_id, metric_date, feature), (count, duration_secs)
        in sorted(totals.items(), key=lambda item: item[0])
    ]

def _bulk_insert(cur, table: str, cols: list[str], rows: Iterable[tuple]) -> int:
    # Materialize exactly once: callers may pass one-shot iterators.
    batch = list(rows)
    if not batch:
        return 0
    # Table/column identifiers are internal constants defined by this script.
    cols_sql = ", ".join(cols)
    placeholders = ", ".join(["%s"] * len(cols))
    sql = f"INSERT INTO {table} ({cols_sql}) VALUES ({placeholders})"
    cur.executemany(sql, batch)
    return len(batch)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--users", type=int, default=1000)
    ap.add_argument("--events-per-user", type=int, default=50)
    ap.add_argument("--seed", type=int, default=42, help="Random seed for reproducible data")
    args = ap.parse_args()
    if args.users < 1 or args.events_per_user < 0:
        ap.error("--users must be >= 1 and --events-per-user must be >= 0")

    random.seed(args.seed)  # reproducible
    print(f"→ Generating mock data (users={args.users})…", flush=True)

    with psycopg.connect(DSN) as conn:
        with conn.cursor() as cur:
            # Pull plan ids + prices
            cur.execute("SELECT id, code, interval, price_cents, currency FROM plans WHERE is_active")
            plans = cur.fetchall()
            plans_by_id = {p[0]: (p[2], p[3], p[4]) for p in plans}

            print("  • users…", flush=True)
            users = _gen_users(args.users)
            n = _bulk_insert(cur, "users",
                ["id","email","full_name","country_code","status",
                 "signup_at","last_login_at","deleted_at"], users)
            print(f"    inserted {n} users", flush=True)

            print("  • subscriptions…", flush=True)
            subs = _gen_subscriptions(users, plans)
            n = _bulk_insert(cur, "subscriptions",
                ["id","user_id","plan_id","status","started_at",
                 "current_period_end","canceled_at","cancellation_reason"], subs)
            print(f"    inserted {n} subscriptions", flush=True)

            print("  • events…", flush=True)
            events = _gen_events(users, per_user=args.events_per_user)
            n = _bulk_insert(cur, "events",
                ["event_id","user_id","event_name","occurred_at","session_id","properties"], events)
            print(f"    inserted {n} events", flush=True)

            print("  • invoices…", flush=True)
            invs = _gen_invoices(subs, plans_by_id)
            n = _bulk_insert(cur, "invoices",
                ["id","subscription_id","user_id","period_start","period_end",
                 "amount_cents","currency","status","issued_at","due_at","paid_at","voided_at"], invs)
            print(f"    inserted {n} invoices", flush=True)

            print("  • payments…", flush=True)
            pays = _gen_payments(invs)
            n = _bulk_insert(cur, "payments",
                ["id", "invoice_id", "amount_cents", "currency",
                 "settlement_amount_cents", "settlement_currency", "exchange_rate",
                 "provider", "provider_charge_id", "status", "attempted_at",
                 "succeeded_at", "failure_reason"], pays)
            print(f"    inserted {n} payment attempts/captures", flush=True)

            print("  • refunds…", flush=True)
            refunds = _gen_refunds(pays)
            n = _bulk_insert(cur, "refunds",
                ["id", "payment_id", "amount_cents", "settlement_amount_cents",
                 "settlement_currency", "exchange_rate", "provider_refund_id",
                 "status", "reason", "requested_at", "completed_at"], refunds)
            print(f"    inserted {n} refunds", flush=True)

            print("  • daily_usage_metrics…", flush=True)
            usage = _gen_daily_usage(events)
            n = _bulk_insert(cur, "daily_usage_metrics",
                ["user_id", "metric_date", "feature", "usage_count", "total_duration_secs"], usage)
            print(f"    inserted {n} event-derived daily_usage rows", flush=True)

        conn.commit()

    print("✓ Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
