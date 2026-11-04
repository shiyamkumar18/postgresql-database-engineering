-- 02_schema.sql
-- Subly SaaS schema: users, plans, subscriptions, events, invoices, payments,
-- refunds, and daily_usage_metrics. Domain integrity enforced at DB layer.
-- Money is stored in integer minor units; settlement FX is recorded explicitly. All PKs are UUIDs.

-- ============================================================================
-- ENUMS (domain integrity)
-- ============================================================================
CREATE TYPE user_status         AS ENUM ('active', 'suspended', 'deleted');
CREATE TYPE subscription_status AS ENUM ('trialing', 'active', 'past_due', 'canceled');
CREATE TYPE invoice_status      AS ENUM ('draft', 'open', 'paid', 'void', 'uncollectible');
CREATE TYPE payment_status      AS ENUM ('pending', 'succeeded', 'failed');
CREATE TYPE refund_status       AS ENUM ('pending', 'succeeded', 'failed');
CREATE TYPE plan_interval       AS ENUM ('monthly', 'quarterly', 'yearly');
CREATE TYPE event_name          AS ENUM (
    'signup', 'login', 'logout', 'feature_use', 'plan_change',
    'invoice_viewed', 'payment_failed', 'subscription_canceled'
);

-- ============================================================================
-- PLANS — catalogue of subscription tiers
-- ============================================================================
CREATE TABLE plans (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code            TEXT NOT NULL UNIQUE,                       -- 'pro_monthly'
    name            TEXT NOT NULL,
    interval        plan_interval NOT NULL,
    price_cents     INTEGER NOT NULL CHECK (price_cents >= 0),
    currency        CHAR(3) NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
    trial_days      SMALLINT NOT NULL DEFAULT 0 CHECK (trial_days BETWEEN 0 AND 90),
    features        JSONB NOT NULL DEFAULT '{}'::jsonb,         -- flexible feature flags
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- USERS
-- ============================================================================
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           CITEXT NOT NULL UNIQUE,
    full_name       TEXT NOT NULL,
    country_code    CHAR(2) NOT NULL DEFAULT 'IN',
    status          user_status NOT NULL DEFAULT 'active',
    signup_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_login_at   TIMESTAMPTZ,
    deleted_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT users_chk_deleted
        CHECK ((status = 'deleted') = (deleted_at IS NOT NULL))
);

-- ============================================================================
-- SUBSCRIPTIONS
-- ============================================================================
CREATE TABLE subscriptions (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                 UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    plan_id                 UUID NOT NULL REFERENCES plans(id) ON DELETE RESTRICT,
    status                  subscription_status NOT NULL DEFAULT 'trialing',
    started_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    current_period_end      TIMESTAMPTZ NOT NULL,
    canceled_at             TIMESTAMPTZ,
    cancellation_reason     TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT subscriptions_chk_canceled_after_start
        CHECK (canceled_at IS NULL OR canceled_at >= started_at),
    CONSTRAINT subscriptions_chk_period_end_after_start
        CHECK (current_period_end > started_at),
    CONSTRAINT subscriptions_chk_canceled_implies_status
        CHECK ((status = 'canceled') = (canceled_at IS NOT NULL))
);

-- ============================================================================
-- EVENTS — append-only time series of user activity
-- ============================================================================
CREATE TABLE events (
    id                  BIGSERIAL PRIMARY KEY,                       -- monotonic, sortable
    event_id            UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),  -- idempotency key
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    event_name          event_name NOT NULL,
    occurred_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    session_id          UUID,
    properties          JSONB NOT NULL DEFAULT '{}'::jsonb,
    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT events_chk_ingested_after_occurred
        CHECK (ingested_at >= occurred_at),
    CONSTRAINT events_chk_feature_use_payload
        CHECK (event_name <> 'feature_use' OR (
            jsonb_typeof(properties->'feature') IS NOT DISTINCT FROM 'string'
            AND COALESCE(properties->>'feature', '') <> ''
            AND jsonb_typeof(properties->'duration_secs') IS NOT DISTINCT FROM 'number'
            AND COALESCE((properties->>'duration_secs') ~ '^[0-9]+$', FALSE)
        ))
);

-- ============================================================================
-- INVOICES
-- ============================================================================
CREATE TABLE invoices (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subscription_id     UUID NOT NULL REFERENCES subscriptions(id) ON DELETE RESTRICT,
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    period_start        TIMESTAMPTZ NOT NULL,
    period_end          TIMESTAMPTZ NOT NULL,
    amount_cents        INTEGER NOT NULL CHECK (amount_cents >= 0),
    currency            CHAR(3) NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
    status              invoice_status NOT NULL DEFAULT 'draft',
    issued_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    due_at              TIMESTAMPTZ NOT NULL,
    paid_at             TIMESTAMPTZ,
    voided_at           TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT invoices_chk_period_end_after_start
        CHECK (period_end > period_start),
    CONSTRAINT invoices_chk_due_after_issued
        CHECK (due_at > issued_at),
    CONSTRAINT invoices_chk_paid_implies_status
        CHECK ((status = 'paid') = (paid_at IS NOT NULL))
);

-- ============================================================================
-- PAYMENTS — attempts/captures applied to one invoice.
-- amount_cents is expressed in the invoice currency and can be partial.
-- Multiple successful rows can settle one invoice in installments.
-- Settlement fields record the processor-side currency and FX conversion.
CREATE TABLE payments (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id              UUID NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT,
    amount_cents            INTEGER NOT NULL CHECK (amount_cents > 0),
    currency                CHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'), -- must match invoices.currency
    settlement_amount_cents INTEGER,
    settlement_currency     CHAR(3),
    exchange_rate           NUMERIC(20, 10), -- settlement currency units per invoice currency unit
    provider                TEXT NOT NULL,   -- 'stripe', 'razorpay'
    provider_charge_id      TEXT,
    status                  payment_status NOT NULL DEFAULT 'pending',
    attempted_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    succeeded_at            TIMESTAMPTZ,
    failure_reason          TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT payments_chk_succeeded_implies_status
        CHECK ((status = 'succeeded') = (succeeded_at IS NOT NULL)),
    CONSTRAINT payments_chk_succeeded_after_attempt
        CHECK (succeeded_at IS NULL OR succeeded_at >= attempted_at),
    CONSTRAINT payments_chk_failed_has_reason
        CHECK ((status = 'failed') = (failure_reason IS NOT NULL)),
    CONSTRAINT payments_chk_settlement_only_on_success
        CHECK (status = 'succeeded' OR
               (settlement_amount_cents IS NULL AND settlement_currency IS NULL AND exchange_rate IS NULL)),
    CONSTRAINT payments_chk_settlement_details
        CHECK (
            (settlement_amount_cents IS NULL AND settlement_currency IS NULL AND exchange_rate IS NULL)
            OR
            (settlement_amount_cents IS NOT NULL AND settlement_amount_cents > 0
             AND settlement_currency IS NOT NULL
             AND settlement_currency ~ '^[A-Z]{3}$' AND exchange_rate IS NOT NULL AND exchange_rate > 0)
        )
);

CREATE UNIQUE INDEX payments_provider_charge_uniq
    ON payments (provider, provider_charge_id)
    WHERE provider_charge_id IS NOT NULL;

-- REFUNDS — refunds are separate transactions, not a payment status.
-- amount_cents is in the invoice currency; settlement fields capture processor FX.
CREATE TABLE refunds (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_id              UUID NOT NULL REFERENCES payments(id) ON DELETE RESTRICT,
    amount_cents            INTEGER NOT NULL CHECK (amount_cents > 0),
    settlement_amount_cents INTEGER,
    settlement_currency     CHAR(3),
    exchange_rate           NUMERIC(20, 10), -- settlement currency units per invoice currency unit
    provider_refund_id      TEXT,
    status                  refund_status NOT NULL DEFAULT 'pending',
    reason                  TEXT,
    requested_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at            TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT refunds_chk_resolution_timestamp
        CHECK ((status IN ('succeeded', 'failed')) = (completed_at IS NOT NULL)),
    CONSTRAINT refunds_chk_completed_after_request
        CHECK (completed_at IS NULL OR completed_at >= requested_at),
    CONSTRAINT refunds_chk_settlement_only_on_success
        CHECK (status = 'succeeded' OR
               (settlement_amount_cents IS NULL AND settlement_currency IS NULL AND exchange_rate IS NULL)),
    CONSTRAINT refunds_chk_settlement_details
        CHECK (
            (settlement_amount_cents IS NULL AND settlement_currency IS NULL AND exchange_rate IS NULL)
            OR
            (settlement_amount_cents IS NOT NULL AND settlement_amount_cents > 0
             AND settlement_currency IS NOT NULL
             AND settlement_currency ~ '^[A-Z]{3}$' AND exchange_rate IS NOT NULL AND exchange_rate > 0)
        )
);

CREATE UNIQUE INDEX refunds_provider_refund_uniq
    ON refunds (provider_refund_id)
    WHERE provider_refund_id IS NOT NULL;

-- Invoice amount/currency become immutable as soon as a payment attempt exists.
-- Issue an adjustment or credit note instead of rewriting a financial document.
CREATE OR REPLACE FUNCTION trg_validate_invoice_financial_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (NEW.amount_cents IS DISTINCT FROM OLD.amount_cents
        OR NEW.currency IS DISTINCT FROM OLD.currency)
       AND EXISTS (SELECT 1 FROM payments WHERE invoice_id = OLD.id) THEN
        RAISE EXCEPTION 'Invoice amount/currency cannot change after a payment attempt exists'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER invoices_financial_terms_immutable
BEFORE UPDATE OF amount_cents, currency ON invoices
FOR EACH ROW EXECUTE FUNCTION trg_validate_invoice_financial_change();

-- Serialize captures for an invoice so concurrent partial payments cannot
-- collect more than the invoice balance. Also enforce invoice-currency units.
CREATE OR REPLACE FUNCTION trg_validate_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    invoice_amount INTEGER;
    invoice_currency CHAR(3);
    already_captured BIGINT;
    already_refunded BIGINT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.invoice_id IS DISTINCT FROM OLD.invoice_id
           OR NEW.amount_cents IS DISTINCT FROM OLD.amount_cents
           OR NEW.currency IS DISTINCT FROM OLD.currency
           OR NEW.provider IS DISTINCT FROM OLD.provider THEN
            RAISE EXCEPTION 'Payment allocation and provider are immutable after creation'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.provider_charge_id IS DISTINCT FROM OLD.provider_charge_id
           AND NOT (OLD.provider_charge_id IS NULL
                    AND NEW.status IN ('succeeded', 'failed')) THEN
            RAISE EXCEPTION 'Provider charge id may be assigned once when an attempt resolves'
                USING ERRCODE = '23514';
        END IF;
        IF (NEW.settlement_amount_cents IS DISTINCT FROM OLD.settlement_amount_cents
            OR NEW.settlement_currency IS DISTINCT FROM OLD.settlement_currency
            OR NEW.exchange_rate IS DISTINCT FROM OLD.exchange_rate)
           AND NOT (OLD.settlement_amount_cents IS NULL
                    AND OLD.settlement_currency IS NULL
                    AND OLD.exchange_rate IS NULL
                    AND NEW.status = 'succeeded') THEN
            RAISE EXCEPTION 'Settlement metadata may be populated once, only for a successful capture'
                USING ERRCODE = '23514';
        END IF;
        IF OLD.status <> 'pending' AND NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'Terminal payment status cannot be changed; create a new attempt'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    SELECT amount_cents, currency
      INTO invoice_amount, invoice_currency
      FROM invoices
     WHERE id = NEW.invoice_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice % does not exist', NEW.invoice_id
            USING ERRCODE = '23503';
    END IF;

    IF NEW.currency <> invoice_currency THEN
        RAISE EXCEPTION 'Payment currency % must match invoice currency %', NEW.currency, invoice_currency
            USING ERRCODE = '23514';
    END IF;

    IF NEW.status = 'succeeded' THEN
        SELECT COALESCE(SUM(amount_cents), 0)
          INTO already_captured
          FROM payments
         WHERE invoice_id = NEW.invoice_id
           AND status = 'succeeded'
           AND id <> NEW.id;

        IF already_captured + NEW.amount_cents > invoice_amount THEN
            RAISE EXCEPTION 'Successful payments would exceed invoice % amount', NEW.invoice_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT COALESCE(SUM(amount_cents), 0)
          INTO already_refunded
          FROM refunds
         WHERE payment_id = NEW.id AND status = 'succeeded';
        IF already_refunded > NEW.amount_cents OR
           (already_refunded > 0 AND NEW.status <> 'succeeded') THEN
            RAISE EXCEPTION 'Payment % cannot be reduced or reversed below its refunds', NEW.id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER payments_validate_before_write
BEFORE INSERT OR UPDATE OF invoice_id, amount_cents, currency,
    settlement_amount_cents, settlement_currency, exchange_rate,
    provider, provider_charge_id, status
ON payments
FOR EACH ROW EXECUTE FUNCTION trg_validate_payment();

-- Lock the parent payment to make the cumulative-refund limit safe under
-- concurrent requests. Only a successfully captured payment can be refunded.
CREATE OR REPLACE FUNCTION trg_validate_refund()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    payment_amount INTEGER;
    payment_status_value payment_status;
    refunded_so_far BIGINT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.payment_id IS DISTINCT FROM OLD.payment_id
           OR NEW.amount_cents IS DISTINCT FROM OLD.amount_cents THEN
            RAISE EXCEPTION 'Refund allocation is immutable after creation'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.provider_refund_id IS DISTINCT FROM OLD.provider_refund_id
           AND NOT (OLD.provider_refund_id IS NULL
                    AND NEW.status IN ('succeeded', 'failed')) THEN
            RAISE EXCEPTION 'Provider refund id may be assigned once when the refund resolves'
                USING ERRCODE = '23514';
        END IF;
        IF (NEW.settlement_amount_cents IS DISTINCT FROM OLD.settlement_amount_cents
            OR NEW.settlement_currency IS DISTINCT FROM OLD.settlement_currency
            OR NEW.exchange_rate IS DISTINCT FROM OLD.exchange_rate)
           AND NOT (OLD.settlement_amount_cents IS NULL
                    AND OLD.settlement_currency IS NULL
                    AND OLD.exchange_rate IS NULL
                    AND NEW.status = 'succeeded') THEN
            RAISE EXCEPTION 'Refund settlement metadata may be populated once, only when successful'
                USING ERRCODE = '23514';
        END IF;
        IF OLD.status <> 'pending' AND NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'Terminal refund status cannot be changed'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    SELECT amount_cents, status
      INTO payment_amount, payment_status_value
      FROM payments
     WHERE id = NEW.payment_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment % does not exist', NEW.payment_id
            USING ERRCODE = '23503';
    END IF;

    IF payment_status_value <> 'succeeded' THEN
        RAISE EXCEPTION 'Only successful payments can be refunded'
            USING ERRCODE = '23514';
    END IF;

    SELECT COALESCE(SUM(amount_cents), 0)
      INTO refunded_so_far
      FROM refunds
     WHERE payment_id = NEW.payment_id
       AND status = 'succeeded'
       AND id <> NEW.id;

    IF NEW.status = 'succeeded' AND refunded_so_far + NEW.amount_cents > payment_amount THEN
        RAISE EXCEPTION 'Successful refunds cannot exceed payment % amount', NEW.payment_id
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER refunds_validate_before_write
BEFORE INSERT OR UPDATE OF payment_id, amount_cents,
    settlement_amount_cents, settlement_currency, exchange_rate,
    provider_refund_id, status
ON refunds
FOR EACH ROW EXECUTE FUNCTION trg_validate_refund();

-- Financial rows are ledger records: correct mistakes with compensating entries,
-- never by deleting captures or refunds.
CREATE OR REPLACE FUNCTION trg_reject_financial_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Rows in % are immutable and cannot be deleted', TG_TABLE_NAME
        USING ERRCODE = '23514';
    RETURN OLD;
END;
$$;

CREATE TRIGGER payments_no_delete
BEFORE DELETE ON payments
FOR EACH ROW EXECUTE FUNCTION trg_reject_financial_delete();

CREATE TRIGGER refunds_no_delete
BEFORE DELETE ON refunds
FOR EACH ROW EXECUTE FUNCTION trg_reject_financial_delete();

-- DAILY_USAGE_METRICS — pre-aggregated analytics table
-- ============================================================================
CREATE TABLE daily_usage_metrics (
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    metric_date         DATE NOT NULL,
    feature             TEXT NOT NULL,
    usage_count         INTEGER NOT NULL DEFAULT 0 CHECK (usage_count >= 0),
    total_duration_secs INTEGER NOT NULL DEFAULT 0 CHECK (total_duration_secs >= 0),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, metric_date, feature)
);
