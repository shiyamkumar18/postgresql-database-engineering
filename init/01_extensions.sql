-- 01_extensions.sql
-- PostgreSQL extensions used across the schema.
-- Run as superuser during container init (docker-entrypoint-initdb.d).

CREATE EXTENSION IF NOT EXISTS citext;        -- case-insensitive text (emails)
CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS btree_gin;     -- composite GIN/btree indexes
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;  -- query performance stats

-- Optional, useful for EXPLAIN ANALYZE writeups
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- trigram similarity / LIKE optimization
