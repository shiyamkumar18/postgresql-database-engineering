-- 05_analytics_views.sql
-- Weekly signup cohort retention. Signup events are excluded from activity so
-- week-0 retention measures post-signup product engagement, not acquisition.
-- UTC is explicit so cohort boundaries do not depend on the session timezone.
CREATE OR REPLACE VIEW v_user_cohort_week AS
WITH cohort AS (
    SELECT
        u.id AS user_id,
        DATE_TRUNC('week', u.signup_at AT TIME ZONE 'UTC')::date AS cohort_week
    FROM users u
    WHERE u.status <> 'deleted'
      AND u.signup_at >= (DATE_TRUNC('week', NOW() AT TIME ZONE 'UTC') - INTERVAL '11 weeks')
), active_weeks AS (
    SELECT DISTINCT
        e.user_id,
        DATE_TRUNC('week', e.occurred_at AT TIME ZONE 'UTC')::date AS activity_week
    FROM events e
    JOIN users u ON u.id = e.user_id
    WHERE e.event_name <> 'signup'
      AND e.occurred_at >= u.signup_at
)
SELECT
    c.cohort_week,
    w.week_n,
    COUNT(DISTINCT c.user_id) AS cohort_size,
    COUNT(DISTINCT a.user_id) AS retained_users,
    ROUND(
        100.0 * COUNT(DISTINCT a.user_id) / NULLIF(COUNT(DISTINCT c.user_id), 0),
        2
    ) AS retention_pct
FROM cohort c
CROSS JOIN GENERATE_SERIES(0, 11) AS w(week_n)
LEFT JOIN active_weeks a
       ON a.user_id = c.user_id
      AND a.activity_week = c.cohort_week + (w.week_n * 7)
WHERE c.cohort_week + (w.week_n * 7)
      <= DATE_TRUNC('week', NOW() AT TIME ZONE 'UTC')::date
GROUP BY c.cohort_week, w.week_n;
