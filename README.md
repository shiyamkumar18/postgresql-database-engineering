# PostgreSQL Database Engineering

> Production-style PostgreSQL & SQL engineering project covering **relational design, schema design, advanced SQL, indexing, transactions, query optimization, EXPLAIN ANALYZE, performance analysis, and data quality**.

This is **Portfolio #01** in my Data Engineering portfolio — a SaaS/Subscription domain database designed and engineered the way you would build it for a real product: enforced integrity, sensible indexes, audited changes, transactional demos, and a measurable optimization section.

---

## 📊 Domain — SaaS Subscription Platform

A fictional B2C SaaS product (call it **"Subly"**) where users subscribe to plans, generate feature events, and get billed monthly. The schema models the canonical entities of a subscription business and is the **shared foundation** for every other portfolio repo (ETL, warehouse, Airflow, PySpark, AWS, dbt, Kafka).

```
users ─┬─< subscriptions >── plans
       ├─< invoices ──< payments ──< refunds
       └─< events ──(daily aggregation)── daily_usage_metrics
```

**Core tables**

| Table | Grain | Purpose |
|---|---|---|
| `plans` | one row per plan | Catalogue of subscription plans (free / pro / enterprise) |
| `users` | one row per user | Account records with status & soft-delete |
| `subscriptions` | one row per active/canceled subscription | Links users to plans with lifecycle timestamps |
| `events` | one row per event | Append-only time-series of user activity (login, feature use) |
| `invoices` | one row per invoice | Billing documents issued against a subscription |
| `payments` | one row per capture/attempt | Partial or split captures, invoice-currency allocation and processor settlement FX |
| `refunds` | one row per refund transaction | Partial or multiple refunds linked to a successful capture |
| `daily_usage_metrics` | one row per (user, feature, date) | Aggregated feature usage for analytics |

---

## 🗂️ Repository layout

```
postgresql-database-engineering/
├── init/                       # SQL migrations run by docker-entrypoint
│   ├── 01_extensions.sql       # citext, pgcrypto, btree_gin
│   ├── 02_schema.sql           # DDL — tables, constraints, enums
│   ├── 03_seed_data.sql        # Reference data (plans) + small demo rows
│   ├── 04_indexes.sql          # B-tree, GIN, partial, composite indexes
│   ├── 05_analytics_views.sql  # UTC weekly cohort retention view
│   └── 99_audit.sql            # Audit trigger for soft updates
├── scripts/
│   └── generate_mock_data.py   # Realistic volume generator (10k+ rows)
├── queries/                    # Advanced SQL examples
│   ├── 01_window_functions.sql
│   ├── 02_ctes.sql
│   ├── 03_aggregations.sql
│   ├── 04_advanced_joins.sql
│   ├── 05_jsonb_queries.sql
│   └── 06_retention_cohort.sql
├── explain/                    # EXPLAIN (ANALYZE, BUFFERS) writeups
│   └── 01_explain_analyze.sql
├── transactions/               # ACID + isolation level demos
│   ├── 01_acid_demo.sql
│   └── 02_isolation_levels.sql
├── data_quality/               # Constraint & data tests
│   ├── 01_constraints.sql
│   └── 02_data_tests.sql
├── tests/                      # pytest test harness
│   ├── conftest.py
│   ├── test_schema.py
│   ├── test_business_semantics.py
│   ├── test_data_quality.py
│   └── test_generator.py
├── docs/                       # Markdown writeups
│   ├── schema_design.md
│   ├── indexing.md
│   ├── optimization.md
│   ├── transactions.md
│   └── data_quality.md
├── docker-compose.yml
├── Makefile
├── migrations/                 # Migration policy and future runner notes
├── requirements.txt
├── .env.example
├── .gitignore
└── LICENSE
```

---

## 🚀 Quick start

```bash
# 1. Clone into your empty repo
git clone https://github.com/shiyamkumar18/postgresql-database-engineering.git
cd postgresql-database-engineering

# 2. Copy env and start PostgreSQL 16
cp .env.example .env
docker compose up -d db

# 3. Apply schema + seed reference data (auto-run on first start)
docker compose exec db psql -U subly -d subly_test -c '\dt'

# 4. Install the local generator dependency and create realistic mock data
python -m pip install -r requirements.txt
python scripts/generate_mock_data.py --users 1000 --events-per-user 50 --seed 42

# 5. Run the SQL labs
docker compose exec db psql -U subly -d subly_test -f /queries/01_window_functions.sql

# 6. Run the Python test harness (tests run in a separate Python container)
make test
```

> The mock-data generator runs either on the host (after installing `requirements.txt`) or through `make mock`, which uses the Python tools container. PostgreSQL itself remains a database-only container.
>
> 💡 No Docker? Use `make local-setup` against a local PostgreSQL 16 instance.

---

## 🧱 Engineering highlights

### Schema
- **UUID primary keys** (`gen_random_uuid()`) for distributed-safe identifiers.
- **`citext`** for case-insensitive emails (no app-side lowercasing).
- **Enums** for status fields (`user_status`, `subscription_status`, `payment_status`, `refund_status`) — domain integrity at the DB layer.
- **CHECK constraints and locking triggers** for billing rules (positive capture/refund amounts, matching invoice currency, no over-collection, refund caps, and immutable invoice terms after payment attempts begin).
- **Partial unique indexes** to enforce "one active subscription per user" at the DB level (see `04_indexes.sql`).
- **Money as integer minor units**, with currency recorded explicitly. Payment allocations are denominated in invoice currency; optional settlement amount/currency and an explicit FX rate preserve processor-side settlement values for successful captures; failed attempts carry no settlement values. The sample supports two-decimal currencies; a production extension for JPY/KWD-style exponents needs currency-exponent metadata.
- **Audit timestamps** (`created_at`, `updated_at`, and `deleted_at` where soft deletion applies) on mutable entities, with `updated_at` maintained by triggers (`99_audit.sql`).
- **`jsonb` event properties** for evolving event payloads, with a database check for required feature-use attributes and a GIN index for ad-hoc queries.
- **Partial captures and refunds:** multiple successful payment rows can settle one invoice; a separate `refunds` ledger supports partial/multiple refunds. Financial ledger rows cannot be deleted; corrections use compensating transactions. The payment row tracks invoice-currency value plus optional settlement-currency/FX details.
- **Reconciled daily usage:** `daily_usage_metrics` is aggregated from generated `feature_use` events (count and duration), not independently sampled; full-outer-join checks detect both missing and mismatched aggregate rows.
- **Validated cohorts:** `v_user_cohort_week` uses UTC week boundaries, excludes signup events from activity, and exposes both counts and retention percentages.

### Indexing strategy
See [`docs/indexing.md`](docs/indexing.md) for the full writeup. Summary:

| Index | Type | Why |
|---|---|---|
| `users_email_key` | unique btree | Login lookups + uniqueness |
| `events_user_occurred_idx` | composite btree | "events for user X ordered by time" (most common query) |
| `events_type_occurred_idx` | composite btree | "logins in last 7 days" |
| `events_properties_idx` | GIN | Filter events by JSON property |
| `subscriptions_active_uniq` | partial unique | Enforce one active subscription per user |
| `invoices_status_issued_idx` | partial btree | "open invoices due soon" |
| `daily_usage_user_date_idx` | composite btree | Time-range analytics per user |

### Query optimization
`explain/01_explain_analyze.sql` runs repeatable `EXPLAIN (ANALYZE, BUFFERS)` experiments. Plans depend on data volume, statistics, cache state, and PostgreSQL version; do not assume a particular scan type. Capture the output from your own run and record row counts, execution time, buffer hits/reads, PostgreSQL version, and the exact query/index state before claiming a speedup. This repository does not ship fabricated benchmark numbers.

### Transactions
`transactions/01_acid_demo.sql` shows a real subscription-renewal transaction (invoice + payment + subscription bump in one atomic unit). `02_isolation_levels.sql` demonstrates READ COMMITTED vs REPEATABLE READ with two concurrent sessions.

### Data quality
- Database-level: constraints, enums, triggers, partial unique indexes.
- Application-level: pytest checks billing balance rules, partial refunds, invoice/payment currency consistency, event-to-metric reconciliation, generator transformations, and expected cohort results.

---

## 🧪 Tests

```bash
make test            # pytest suite (requires DB up)
make test-coverage   # with coverage report
```

Tests cover:
- Schema presence & correct types
- Partial/split captures, cross-currency settlement metadata, and partial-refund limits
- Known expected results for weekly retention cohorts
- Constraint enforcement (insert invalid row, expect error)
- Trigger behavior (`updated_at` auto-touch)
- Data quality rules (capture/refund balances, event timestamps, event-to-metric reconciliation)
- Mock-data transformations (daily aggregation, split-cent totals, settlement FX, partial refunds)

---

## 🔧 Tech stack

- **PostgreSQL 16** (CI target; version compatibility outside 16 is not yet certified)
- **Extensions**: `citext`, `pgcrypto`, `btree_gin`, `pg_stat_statements`
- **Python 3.11** for the test harness & mock data generator
- **Docker Compose** for one-command reproducible environment

---

## 📚 Documentation

| Doc | What it covers |
|---|---|
| [docs/schema_design.md](docs/schema_design.md) | Why each table/column/type, normalisation choices, denormalisation tradeoffs |
| [docs/indexing.md](docs/indexing.md) | Index strategy, when to use which type, common pitfalls |
| [docs/optimization.md](docs/optimization.md) | Reading EXPLAIN, slow query workflow, pg_stat_statements |
| [docs/transactions.md](docs/transactions.md) | ACID in practice, isolation levels, deadlock avoidance |
| [docs/data_quality.md](docs/data_quality.md) | Defense-in-depth: constraints → triggers → app tests |

---

## 👤 Author

**Shiyam Kumar** — [GitHub](https://github.com/shiyamkumar18) · [LinkedIn](https://www.linkedin.com/in/shiyam-kumar-v) · shiyamk032@gmail.com

Part of my [Data Engineering Portfolio](https://github.com/shiyamkumar18). See the [end-to-end platform repo](https://github.com/shiyamkumar18/end-to-end-data-platform) for the flagship project that ties all eight portfolio repos together.

## 📄 License

MIT — see [LICENSE](LICENSE).


## Verification and scope

- GitHub Actions runs against a fresh PostgreSQL 16 service and executes the Python test suite.
- `init/` is a fresh-database bootstrap, not a production migration runner. See [`migrations/README.md`](migrations/README.md).
- Query plans and performance vary with data volume and environment. Save actual `EXPLAIN (ANALYZE, BUFFERS)` output before publishing benchmark claims.
- Run `make test` after the database is initialized. Generating mock data first gives the dataset-level reconciliation tests realistic volume to inspect.
