# Transactions & Isolation Levels

Practical reference for transactional correctness in PostgreSQL, with demos from Subly. Companion to [`transactions/01_acid_demo.sql`](../transactions/01_acid_demo.sql) and [`transactions/02_isolation_levels.sql`](../transactions/02_isolation_levels.sql).

## ACID, in one paragraph each

- **Atomicity**: every statement in a transaction succeeds or fails as a unit. If the payment fails after the invoice was issued, both roll back. The Subly renewal flow (`01_acid_demo.sql`) shows this.
- **Consistency**: constraints, triggers, and enums prevent the database from ever entering an invalid state. A transaction that violates a CHECK constraint is rolled back automatically.
- **Isolation**: concurrent transactions behave *as if* they executed serially, to varying degrees (see below).
- **Durability**: once `COMMIT` returns, the data is on disk (modulo WAL fsync policy) and survives a crash.

## Transaction basics

```sql
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
COMMIT;   -- or ROLLBACK;
```

If either UPDATE fails, the connection is in an aborted state; the application must call `ROLLBACK` before issuing any other statement.

In Python (psycopg3), use the connection as a context manager — it rolls back on exception automatically:

```python
with conn.transaction():  # BEGIN … COMMIT (or ROLLBACK on exception)
    cur.execute("UPDATE accounts SET balance = balance - 100 WHERE id = 1")
    cur.execute("UPDATE accounts SET balance = balance + 100 WHERE id = 2")
```

## Row locks

The Subly renewal flow uses `SELECT … FOR UPDATE`:

```sql
BEGIN;
SELECT id FROM subscriptions WHERE id = $1 FOR UPDATE;  -- locks the row
-- ... do renewal work ...
COMMIT;   -- lock released
```

This prevents two concurrent renewal jobs from both picking up the same subscription. Other transactions trying to `UPDATE` or `SELECT FOR UPDATE` on the same row block until commit.

## Isolation levels in PostgreSQL

PostgreSQL implements three meaningful isolation levels (READ UNCOMMITTED is treated as READ COMMITTED):

| Level | Phenomena prevented | Cost |
|---|---|---|
| READ COMMITTED (default) | Dirty reads | None — default behavior |
| REPEATABLE READ | Dirty reads, **non-repeatable reads**, **phantom reads** | Snapshot per transaction; first SELECT defines the snapshot |
| SERIALIZABLE | All of the above + **write skew** | Snapshot Isolation + Serializable Snapshot Isolation (SSI); possible serialization failures you must retry |

### What "non-repeatable read" looks like

Run [`02_isolation_levels.sql`](../transactions/02_isolation_levels.sql) in two terminals:

**Session A** (writer):
```sql
BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;  -- try REPEATABLE READ next
UPDATE users SET full_name = full_name || ' (edited)' WHERE email = 'alice@subly.demo';
-- DO NOT COMMIT YET
```

**Session B** (reader):
```sql
BEGIN;
SELECT full_name FROM users WHERE email = 'alice@subly.demo';  -- original name
-- (A commits now)
SELECT full_name FROM users WHERE email = 'alice@subly.demo';  -- edited name (READ COMMITTED)
                                                                  -- or original name (REPEATABLE READ)
COMMIT;
```

Under READ COMMITTED, the two SELECTs return different values — a non-repeatable read. Under REPEATABLE READ, the second SELECT returns the original value because the snapshot was taken at the first SELECT.

### When to use REPEATABLE READ

- Long-running reports that need a consistent view across many SELECTs.
- ETL extract phases that scan multiple tables and must see them at the same point in time.
- Caveat: you'll get `ERROR: could not serialize access due to concurrent update` if you try to UPDATE a row that was changed by another transaction after your snapshot. Handle by retrying the whole transaction.

### When to use SERIALIZABLE

- Anything where correctness depends on cross-row invariants ("no two users can book the same seat at the same time" without an explicit unique constraint).
- Be prepared to catch `40001 serialization_failure` and retry the whole transaction with jitter.

## Deadlocks and how to avoid them

A deadlock is two transactions each holding a lock the other needs. Postgres detects this and kills one of them with `ERROR: deadlock detected`.

The simplest rule for avoiding deadlocks: **always lock rows in the same order across transactions**. In Subly, every transaction that touches multiple subscriptions locks them in `id` order:

```python
subscription_ids = sorted(subscription_ids)
cur.execute("SELECT id FROM subscriptions WHERE id = ANY(%s) FOR UPDATE", (subscription_ids,))
```

If every transaction acquires locks in ascending id order, no cycle can form.

## Distributed-style "exactly-once" with idempotency keys

The `event_id UUID UNIQUE` column on `events` is the idempotency key. Producers retry on transient failures; the unique constraint guarantees duplicate retries don't create duplicate events — they get a `unique_violation` (23505) which the consumer can swallow.

```sql
INSERT INTO events (event_id, user_id, event_name) VALUES ($1, $2, $3)
ON CONFLICT (event_id) DO NOTHING;
```

This pattern carries through to the Kafka pipeline in [repo 08](https://github.com/shiyamkumar18/kafka-realtime-pipeline).
