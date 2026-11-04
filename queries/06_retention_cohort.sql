-- 06_retention_cohort.sql
-- Weekly signup cohort retention. The canonical logic lives in
-- init/05_analytics_views.sql so CI and application queries share one definition.
-- Week 0 excludes the signup event and therefore measures post-acquisition use.
\echo '=== Weekly retention matrix (signup cohort × weeks since signup) ==='
SELECT
    cohort_week,
    MAX(cohort_size) AS cohort_size,
    MAX(retained_users) FILTER (WHERE week_n = 0) AS week_0_users,
    MAX(retention_pct) FILTER (WHERE week_n = 0) AS week_0_pct,
    MAX(retention_pct) FILTER (WHERE week_n = 1) AS week_1_pct,
    MAX(retention_pct) FILTER (WHERE week_n = 2) AS week_2_pct,
    MAX(retention_pct) FILTER (WHERE week_n = 4) AS week_4_pct,
    MAX(retention_pct) FILTER (WHERE week_n = 8) AS week_8_pct,
    MAX(retention_pct) FILTER (WHERE week_n = 11) AS week_11_pct
FROM v_user_cohort_week
GROUP BY cohort_week
ORDER BY cohort_week DESC;

\echo '=== Long-form cohort data (suitable for BI tools) ==='
SELECT cohort_week, week_n, cohort_size, retained_users, retention_pct
FROM v_user_cohort_week
ORDER BY cohort_week DESC, week_n;
