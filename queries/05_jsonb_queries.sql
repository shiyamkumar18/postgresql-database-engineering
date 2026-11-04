-- 05_jsonb_queries.sql
-- JSONB patterns for flexible feature flags + event properties.
-- GIN index events_properties_gin_idx is used by some of these.

\echo '=== Q1: Extract plan feature — users with analytics=true ==='
SELECT u.id, u.email, p.code, p.features->>'analytics' AS analytics_enabled
FROM users u
JOIN subscriptions s ON s.user_id = u.id AND s.status IN ('trialing','active','past_due')
JOIN plans p         ON p.id = s.plan_id
WHERE (p.features->>'analytics')::boolean = true;

\echo '=== Q2: Containment — events where properties include {"feature":"export"} ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM events
WHERE properties @> '{"feature":"export"}'::jsonb;

\echo '=== Q3: Expand properties keys (per-event keys present) ==='
SELECT
    event_name,
    COUNT(DISTINCT e.id) AS event_count,
    ARRAY_AGG(DISTINCT k) AS property_keys
FROM events e
CROSS JOIN LATERAL jsonb_object_keys(e.properties) AS k
GROUP BY event_name
ORDER BY event_count DESC;

\echo '=== Q4: Aggregate — most common feature value in feature_use events ==='
SELECT
    properties->>'feature' AS feature,
    COUNT(*) AS uses,
    AVG((properties->>'duration_secs')::numeric) AS avg_duration_secs
FROM events
WHERE event_name = 'feature_use'
GROUP BY properties->>'feature'
ORDER BY uses DESC;

\echo '=== Q5: jsonb_path_query — find events with duration > 60s ==='
SELECT e.id, e.user_id, e.occurred_at,
       e.properties->>'feature'      AS feature,
       (e.properties->>'duration_secs')::int AS duration_secs
FROM events e
WHERE e.event_name = 'feature_use'
  AND (e.properties ? 'duration_secs')
  AND (e.properties->>'duration_secs')::int > 60
ORDER BY duration_secs DESC
LIMIT 20;

\echo '=== Q6: Update — merge new feature flag into a plan without overwriting ==='
UPDATE plans
SET features = features || '{"priority_support":true}'::jsonb
WHERE code = 'enterprise'
RETURNING code, features;
