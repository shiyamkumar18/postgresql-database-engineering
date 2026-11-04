-- 99_audit.sql
-- Audit triggers: auto-update updated_at on every mutable table.
-- One trigger function, attached to each table.

CREATE OR REPLACE FUNCTION trg_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Don't override an explicit NEW.updated_at; otherwise refresh.
    IF NEW.updated_at IS NULL OR NEW.updated_at = OLD.updated_at THEN
        NEW.updated_at := clock_timestamp();
    END IF;
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t TEXT;
    tables TEXT[] := ARRAY['plans','users','subscriptions','invoices','payments','refunds','daily_usage_metrics'];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS set_updated_at ON %I; '
            'CREATE TRIGGER set_updated_at '
            'BEFORE UPDATE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();',
            t, t
        );
    END LOOP;
END $$;
