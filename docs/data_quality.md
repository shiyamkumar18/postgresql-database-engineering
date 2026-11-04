# Data Quality — Defense in Depth

Data quality is not a single layer; it's a layered defense. Each layer catches what the one above missed.

## The four layers

```
┌────────────────────────────────────────────────────────┐
│  Layer 4: Cross-system reconciliation                  │
│  (compare source → warehouse counts; separate repo)    │
├────────────────────────────────────────────────────────┤
│  Layer 3: Application tests  (pytest, see tests/)      │
├────────────────────────────────────────────────────────┤
│  Layer 2: Triggers & audit        (99_audit.sql)       │
├────────────────────────────────────────────────────────┤
│  Layer 1: Database constraints    (02_schema.sql)      │
└────────────────────────────────────────────────────────┘
```

### Layer 1: Database constraints (always-on, free)

- **PRIMARY KEY**: identity, prevents duplicate rows.
- **FOREIGN KEY**: referential integrity. `payments.invoice_id` and `refunds.payment_id` cannot point at missing financial records.
- **UNIQUE**: business uniqueness (e.g. `users.email`, `plans.code`).
- **CHECK**: business rules (`amount_cents >= 0`, `canceled_at >= started_at`).
- **ENUM**: closed domains (`payment_status`).
- **Partial unique index**: complex rules (`one active subscription per user`).

Run `data_quality/01_constraints.sql` to enumerate every constraint in the schema.

### Layer 2: Triggers (always-on, slightly expensive)

The `trg_set_updated_at` trigger on mutable tables ensures `updated_at` is refreshed without relying on application code. The payment/refund integrity triggers in `02_schema.sql` also enforce cross-row billing invariants, freeze invoice financial terms once a payment attempt exists, and reject deletion of payment/refund ledger rows.

Triggers can do more: audit tables, soft-delete enforcement, derived columns. Use them sparingly: they're invisible to application code and can confuse newcomers.

### Layer 3: Application tests (run on every commit)

The pytest suite in [`tests/`](../tests/) verifies:
- Constraints actually fire (try to insert bad data, expect an error)
- Triggers fire (`updated_at` is refreshed on UPDATE)
- Business invariants hold across the dataset (paid invoices have successful payments, etc.)

Run them: `make test`.

### Layer 4: Cross-system reconciliation (warehouse scope)

In the data warehouse repo, we run daily checks that OLTP counts match warehouse counts. Example: reconcile successful invoice-currency captures and successful refunds separately between Postgres and the warehouse; reconcile processor settlement amounts by settlement currency rather than summing unlike currencies. Diffs trigger alerts.

## The SQL data tests

`data_quality/02_data_tests.sql` contains ten standalone assertion queries — each returns only violations, so an empty result means pass. The pytest suite mirrors these as Python tests for CI.

| Test | What it catches |
|---|---|
| T1: active subscription's period in future | Stale active subscriptions that should have been canceled |
| T2: paid invoice is covered by successful captures | "Paid" invoice with an unpaid balance — billing bug |
| T3: at most one active sub per user | Concurrent subscription creation race |
| T4–T6: captures do not over-collect, currencies match, refunds do not exceed captures | Overcharge, FX-unit confusion, or excessive refund |
| T7: events do not precede signup | Backdated events — clock skew or ingestion bug |
| T8: feature-use payload is valid | Missing feature/duration attributes |
| T9: daily_usage_metrics reconcile with events for both count and duration | Missing rows or aggregation job drift |
| T10: settlement fields only exist on successful payments/refunds | False settlement data on failed or pending attempts |

The payment/refund limits are implemented with parent-row locking triggers. Locking the invoice before summing successful captures serializes concurrent captures; locking the payment before summing successful refunds serializes concurrent refunds. The SQL reconciliation checks remain useful as operational audits even when the write path enforces the invariant.

## When to put a check at which layer?

| Rule of thumb | Layer |
|---|---|
| Must hold under all access paths (any app, any tool, raw SQL) | Layer 1 (constraint) |
| Trivially expressible as a column property | Layer 1 (constraint) |
| Touches multiple rows or tables | Layer 3 (test) |
| Requires business context (e.g. "open invoices due in 7 days shouldn't be older than 14 days") | Layer 3 (test) |
| Crosses systems (OLTP vs warehouse) | Layer 4 (reconciliation) |

## Suggested cadence

- **Every commit**: Layer 3 pytest suite against a small seed dataset (200 users).
- **Every night**: Layer 3 + Layer 4 (full reconciliation report).
- **Every quarter**: review `pg_stat_user_indexes` to drop unused indexes that grew out of relevance.

## What "good data quality" looks like

You should be able to answer "is the data correct?" **without running a query**. The fact that constraints exist, tests pass, and reconciliations are green *is* the answer. If you have to query to find out, you've already lost.
