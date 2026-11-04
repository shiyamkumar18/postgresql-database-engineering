# Database migration policy

The `init/` scripts define the bootstrap schema for a fresh database. They are
not a safe upgrade mechanism for an existing database because PostgreSQL
initialization scripts only run automatically when the data directory is empty.

For schema changes after the initial release, add ordered, immutable migration
files here using the naming convention `NNNN_description.sql` (for example,
`0001_add_customer_external_id.sql`). Each migration must be reviewed, tested
against a disposable PostgreSQL database, and applied exactly once by the
migration runner. Do not edit a migration after it has been applied in a shared
environment; create a follow-up migration instead.

A migration runner and migration-history table are intentionally not claimed as
implemented yet. Until they are added, use `init/` only for fresh local/CI
databases and do not treat this repository as providing automated production
migrations.
