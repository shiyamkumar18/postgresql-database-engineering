-- 03_seed_data.sql
-- Reference data (plans) + a small demo dataset for quick manual testing.
-- For volume (10k+ users, 100k+ events), run from the host with dependencies
-- installed: python scripts/generate_mock_data.py (or use `make mock`).

BEGIN;

-- Plans ---------------------------------------------------------------------
INSERT INTO plans (code, name, interval, price_cents, trial_days, features) VALUES
    ('free',        'Free',        'monthly',      0,    0, '{"max_projects":3,  "support":"community"}'::jsonb),
    ('pro_monthly', 'Pro Monthly', 'monthly',    1999,   14, '{"max_projects":50, "support":"email",     "analytics":true}'::jsonb),
    ('pro_yearly',  'Pro Yearly',  'yearly',   19900,   14, '{"max_projects":50, "support":"email",     "analytics":true, "discount":"2_months_free"}'::jsonb),
    ('enterprise',  'Enterprise',  'yearly',   99000,   30, '{"max_projects":-1, "support":"dedicated", "analytics":true, "sso":true, "sla":"99.95"}'::jsonb)
ON CONFLICT (code) DO NOTHING;

-- Demo users ----------------------------------------------------------------
INSERT INTO users (id, email, full_name, country_code, status, signup_at) VALUES
    ('11111111-1111-1111-1111-111111111101', 'alice@subly.demo',   'Alice Tanaka',    'US', 'active',    '2025-01-15 09:00:00+00'),
    ('11111111-1111-1111-1111-111111111102', 'bob@subly.demo',     'Bob Marley',      'IN', 'active',    '2025-02-01 10:30:00+00'),
    ('11111111-1111-1111-1111-111111111103', 'carol@subly.demo',   'Carol O''Neil',   'GB', 'suspended', '2025-03-12 14:00:00+00')
ON CONFLICT (email) DO NOTHING;

-- Demo subscriptions --------------------------------------------------------
INSERT INTO subscriptions (id, user_id, plan_id, status, started_at, current_period_end) VALUES
    ('22222222-2222-2222-2222-222222222201', '11111111-1111-1111-1111-111111111101',
     (SELECT id FROM plans WHERE code='pro_monthly'),
     'active', '2025-01-15 09:05:00+00', NOW() + INTERVAL '12 hours'),
    ('22222222-2222-2222-2222-222222222202', '11111111-1111-1111-1111-111111111102',
     (SELECT id FROM plans WHERE code='free'),
     'active', '2025-02-01 10:35:00+00', NOW() + INTERVAL '30 days')
ON CONFLICT DO NOTHING;

-- Demo events ---------------------------------------------------------------
INSERT INTO events (event_id, user_id, event_name, occurred_at, properties) VALUES
    ('33333333-3333-3333-3333-333333333301', '11111111-1111-1111-1111-111111111101', 'signup',
     '2025-01-15 09:00:00+00', '{"utm":"google"}'::jsonb),
    ('33333333-3333-3333-3333-333333333302', '11111111-1111-1111-1111-111111111101', 'login',
     '2025-02-01 09:00:00+00', '{"ip":"1.2.3.4"}'::jsonb),
    ('33333333-3333-3333-3333-333333333303', '11111111-1111-1111-1111-111111111101', 'feature_use',
     '2025-02-01 09:30:00+00', '{"feature":"export","duration_secs":12}'::jsonb)
ON CONFLICT (event_id) DO NOTHING;

-- Keep the sample aggregate reconciled with the feature_use event above.
INSERT INTO daily_usage_metrics (user_id, metric_date, feature, usage_count, total_duration_secs)
SELECT id, DATE '2025-02-01', 'export', 1, 12
FROM users WHERE email = 'alice@subly.demo'
ON CONFLICT (user_id, metric_date, feature)
DO UPDATE SET usage_count = EXCLUDED.usage_count,
              total_duration_secs = EXCLUDED.total_duration_secs;

COMMIT;
