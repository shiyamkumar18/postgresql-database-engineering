# Schema Design — Subly SaaS

This document captures the **why** behind every schema decision in [`init/02_schema.sql`](../init/02_schema.sql). The schema is intentionally opinionated; every choice has a reason that a reviewer (or future me) can audit.

## Design principles

1. **Integrity at the database layer first.** Constraints, enums, triggers, and partial unique indexes enforce business rules that would otherwise leak into every application that touches the DB. Code can have bugs; the database cannot silently lose integrity.
2. **Money uses integer minor units.** Amounts are never stored as floating-point values. Each payment's `amount_cents` is the portion applied in the invoice currency; optional settlement amount/currency plus a fixed-precision FX rate preserve what the processor settled. This separates invoice accounting from payment-processor settlement. The examples use two-decimal currencies (USD, EUR, GBP, INR); production support for currencies with zero or three minor-unit decimals (for example JPY or KWD) requires a currency-exponent reference table and exponent-aware conversion rather than assuming every currency has cents.
3. **UUIDs for public IDs.** Distributed-safe, un-enumerable, ideal for sharding later. We use `gen_random_uuid()` from `pgcrypto` so inserts don't block on a central sequence.
4. **Append-only time-series (`events`) uses `BIGSERIAL`.** A monotonic integer PK is friendlier to BRIN indexes and cheaper to insert than UUIDs at high volume. The UUID `event_id` is the idempotency key.
5. **Soft-delete with check constraint.** `users.deleted_at IS NOT NULL` iff `status='deleted'` — a single source of truth.
6. **Timestamps are `TIMESTAMPTZ`.** Always. UTC storage; presentation is the application's concern.

## Entity overview

```
plans ─┐
       │
users ─┼─< subscriptions ──< invoices ──< payments ──< refunds
       │
       └─< events ─────── (UTC daily aggregate) ── daily_usage_metrics
```

## Notable decisions

### Why `CITEXT` for emails?
`alice@x.com` and `Alice@X.com` are the same email. With `TEXT`, you must remember to `LOWER()` everywhere — including all unique indexes and joins. `CITEXT` makes equality case-insensitive at the type level. Cost: a tiny storage overhead. Worth it.

### Why enums and not lookup tables?
For closed, small, low-churn domains (`user_status`, `payment_status`, …) enums are:
- Cheaper than a join
- Self-documenting in `\d` and `pg_enum`
- Enforced at parse time (you cannot insert `'foo'` into a `payment_status` column)

For open or frequently-changing domains (e.g. the catalogue of plans), use a real table — which is exactly what `plans` is.

### Why `CHECK ((status='deleted') = (deleted_at IS NOT NULL))`?
Two facts that must always agree. Without the constraint, an application bug could leave a user with `status='active'` and `deleted_at` populated, leading to ghost "deleted but active" users. This constraint makes the inconsistency impossible.

### Why a **partial unique index** for "one active subscription per user"?
A plain `UNIQUE(user_id)` would prevent a user from ever re-subscribing after canceling. A partial unique index `WHERE status IN ('trialing','active','past_due')` allows multiple historical subscriptions but enforces at most one *current* subscription — exactly the business rule.

### Why `BIGSERIAL` for `events.id`?
At SaaS scale, `events` is the largest table by far. UUID PKs hurt:
- Index fragmentation (random inserts → page splits)
- 16 bytes vs 8 bytes per row, multiplied by every index
- BRIN indexes don't work as well on random distributions

`BIGSERIAL` is monotonic, sortable by insertion order, fits in 8 bytes, and is friendly to BRIN. The UUID `event_id` column carries the externally-visible idempotency key.

### Why store `properties` as `JSONB` on events?
Event schemas evolve constantly. A fixed-column approach forces migrations on a multi-billion-row table. `JSONB` with a GIN index lets us:
- Add new properties without migrations
- Query properties via `@>` containment (index-backed)
- Project known properties via `->>'key'` when we need them as columns

The trade-off: don't use JSONB for fields that always appear in WHERE clauses or that you'd join on. For those, promote to a real column.

### Why `daily_usage_metrics`?
The `events` table answers "what happened". `daily_usage_metrics` answers "how much was feature X used by user Y on date Z" — orders of magnitude faster than re-aggregating events every time, because the table is `(user, date, feature)`-keyed and 100× smaller than events.

This is the **first taste of dimensional modeling** — the foundation for the warehouse project in [repo 03](https://github.com/shiyamkumar18/data-modeling-data-warehouse).

## What this schema deliberately does NOT do

- **No multi-tenant column.** The platform is single-tenant for the portfolio. A `tenant_id` on every table is straightforward to add — see the warehouse repo for a multi-schema approach.
- **No soft-delete on `events`.** Events are immutable history; "deleting" an event is a different operation (GDPR redaction) and would go through a separate `event_redactions` table.
- **No `updated_at` on `events`.** Events are append-only. `daily_usage_metrics` is mutable and therefore carries `updated_at`, refreshed by the audit trigger when an aggregate row is updated.

## Migration path

Future changes go through numbered migration files (e.g. `init/05_add_orgs.sql`) rather than editing `02_schema.sql` in place. For a real production setup, swap `init/` for [Flyway](https://flywaydb.org/) or [Sqitch](https://sqitch.org/).


### Why are payments and refunds separate ledgers?
A payment row is one processor attempt/capture and can cover only part of its invoice. Multiple successful captures can settle one invoice in installments. `payments.amount_cents` is expressed in the invoice currency, so settlement in another currency is recorded separately in `settlement_amount_cents`, `settlement_currency`, and `exchange_rate` (settlement-currency units per invoice-currency unit). Failed and pending attempts never contain settlement values; settlement metadata can be populated once when a capture resolves successfully. This avoids comparing unlike currencies.

Refunds are separate rows because a capture can be refunded partially or through multiple refund transactions. `refunds.amount_cents` uses the same invoice-currency basis as the originating payment; optional settlement fields record the actual processor refund only when it succeeds. A locking trigger serializes refunds per payment and rejects cumulative successful refunds above the captured amount. A second locking trigger serializes successful captures per invoice and rejects over-collection. Once a payment attempt exists, invoice amount and currency are immutable; payment and refund ledger rows cannot be deleted. Corrections should use compensating transactions and explicit reversal/chargeback workflows rather than rewriting financial history.

### Why are daily usage metrics derived from events?
The generator now groups `feature_use` events by user, UTC calendar date, and feature, deriving both event count and total duration. The reconciliation check uses a full outer join, so it catches missing metric rows as well as incorrect counts or durations. This is a reproducible batch aggregation example; an incremental production pipeline would use idempotent upserts and a late-arriving-event policy.

### How is retention defined?
`v_user_cohort_week` assigns users to UTC signup weeks and counts distinct users with at least one non-signup event in each subsequent week. Signup events are excluded so acquisition itself does not make week-0 engagement look like retention. The view emits long-form rows (`cohort_week`, `week_n`, `cohort_size`, `retained_users`, `retention_pct`) for BI use; `queries/06_retention_cohort.sql` pivots selected weeks for a compact matrix.
