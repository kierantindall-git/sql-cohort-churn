-- ============================================================================
-- 05_insights_segments.sql
-- Business question: Which segments drive churn, how much revenue do they
--                    cost us, and what would fixing onboarding be worth?
--
-- These queries exist to PROVE the three headline insights for the README:
--   1. Retention differs sharply by plan & channel (the actionable segment story)
--   2. A few segments account for most of the lost MRR
--   3. Closing the signup-month churn gap has a quantifiable revenue value
--
-- All tenure-based retention uses only mature cohorts (cohort + tenure <= cutoff),
-- consistent with 03_cohort_retention.sql.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- QUERY 1: Retention scorecard by plan and by channel (M1/M3/M6/M12)
--          Only mature cohorts are counted in each tenure's denominator.
-- ---------------------------------------------------------------------------
WITH cust AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', signup_date)::DATE AS cohort_month,
        plan_tier,
        acquisition_channel
    FROM customers
),

active AS (
    SELECT
        sm.customer_id,
        (EXTRACT(YEAR  FROM sm.month_start) - EXTRACT(YEAR  FROM c.cohort_month)) * 12
      + (EXTRACT(MONTH FROM sm.month_start) - EXTRACT(MONTH FROM c.cohort_month)) AS tenure_months
    FROM subscription_months sm
    JOIN cust c USING (customer_id)
    WHERE sm.is_active = TRUE
),

flags AS (
    SELECT
        c.customer_id,
        c.cohort_month,
        c.plan_tier,
        c.acquisition_channel,
        COALESCE(BOOL_OR(a.tenure_months =  1), FALSE) AS active_m1,
        COALESCE(BOOL_OR(a.tenure_months =  3), FALSE) AS active_m3,
        COALESCE(BOOL_OR(a.tenure_months =  6), FALSE) AS active_m6,
        COALESCE(BOOL_OR(a.tenure_months = 12), FALSE) AS active_m12
    FROM cust c
    LEFT JOIN active a USING (customer_id)
    GROUP BY 1, 2, 3, 4
),

segmented AS (
    SELECT 'plan'    AS dimension, plan_tier           AS segment, * FROM flags
    UNION ALL
    SELECT 'channel' AS dimension, acquisition_channel AS segment, * FROM flags
)

SELECT
    dimension,
    segment,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*) FILTER (WHERE active_m1) /
          NULLIF(COUNT(*) FILTER (WHERE (cohort_month + INTERVAL '1 month')::DATE <= DATE '2025-12-01'), 0), 1)  AS m1_retention_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE active_m3) /
          NULLIF(COUNT(*) FILTER (WHERE (cohort_month + INTERVAL '3 months')::DATE <= DATE '2025-12-01'), 0), 1) AS m3_retention_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE active_m6) /
          NULLIF(COUNT(*) FILTER (WHERE (cohort_month + INTERVAL '6 months')::DATE <= DATE '2025-12-01'), 0), 1) AS m6_retention_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE active_m12) /
          NULLIF(COUNT(*) FILTER (WHERE (cohort_month + INTERVAL '12 months')::DATE <= DATE '2025-12-01'), 0), 1) AS m12_retention_pct
FROM segmented
GROUP BY 1, 2
ORDER BY 1, 2;


-- ---------------------------------------------------------------------------
-- QUERY 2: MRR churn contribution — which segments account for the lost money?
-- ---------------------------------------------------------------------------
WITH active AS (
    SELECT customer_id, month_start, mrr
    FROM subscription_months
    WHERE is_active = TRUE
),

events AS (
    SELECT
        c.plan_tier,
        c.acquisition_channel,
        a.mrr,
        (b.customer_id IS NULL) AS churned
    FROM active a
    JOIN customers c USING (customer_id)
    LEFT JOIN active b
           ON b.customer_id = a.customer_id
          AND b.month_start = (a.month_start + INTERVAL '1 month')::DATE
    WHERE a.month_start < (SELECT MAX(month_start) FROM subscription_months)
),

by_seg AS (
    SELECT
        plan_tier,
        acquisition_channel,
        SUM(CASE WHEN churned THEN 1 ELSE 0 END)          AS churned_customers,
        SUM(CASE WHEN churned THEN mrr ELSE 0 END)        AS mrr_lost
    FROM events
    GROUP BY 1, 2
)

SELECT
    plan_tier,
    acquisition_channel,
    churned_customers,
    ROUND(mrr_lost, 2)                                          AS mrr_lost,
    ROUND(100.0 * mrr_lost / SUM(mrr_lost) OVER (), 1)          AS pct_of_total_mrr_lost,
    ROUND(100.0 * SUM(mrr_lost) OVER (PARTITION BY plan_tier)
          / SUM(mrr_lost) OVER (), 1)                           AS pct_of_total_within_plan
FROM by_seg
ORDER BY mrr_lost DESC;


-- ---------------------------------------------------------------------------
-- QUERY 3: The onboarding scenario — what if signup-month churn matched the
--          steady state the business achieves after month 6?
--          (Quantifies the value of a first-30-days intervention.)
-- ---------------------------------------------------------------------------
WITH cohorts AS (
    SELECT customer_id, DATE_TRUNC('month', signup_date)::DATE AS cohort_month
    FROM customers
),

active AS (
    SELECT
        sm.customer_id,
        sm.month_start,
        sm.mrr,
        (EXTRACT(YEAR  FROM sm.month_start) - EXTRACT(YEAR  FROM c.cohort_month)) * 12
      + (EXTRACT(MONTH FROM sm.month_start) - EXTRACT(MONTH FROM c.cohort_month)) AS tenure_months
    FROM subscription_months sm
    JOIN cohorts c USING (customer_id)
    WHERE sm.is_active = TRUE
),

events AS (
    SELECT
        a.tenure_months,
        a.mrr,
        (b.customer_id IS NULL) AS churned
    FROM active a
    LEFT JOIN active b
           ON b.customer_id = a.customer_id
          AND b.month_start = (a.month_start + INTERVAL '1 month')::DATE
    WHERE a.month_start < (SELECT MAX(month_start) FROM subscription_months)
),

signup_bucket AS (
    SELECT
        COUNT(*)                                          AS customer_months_at_risk,
        SUM(mrr)                                          AS mrr_at_risk,
        SUM(CASE WHEN churned THEN mrr ELSE 0 END)        AS mrr_lost
    FROM events
    WHERE tenure_months = 0
),

steady_state AS (
    SELECT
        100.0 * SUM(CASE WHEN churned THEN mrr ELSE 0 END) / SUM(mrr) AS steady_mrr_churn_pct
    FROM events
    WHERE tenure_months BETWEEN 6 AND 11
)

SELECT
    s.customer_months_at_risk,
    ROUND(s.mrr_at_risk, 2)                                       AS signup_month_mrr_at_risk,
    ROUND(s.mrr_lost, 2)                                          AS signup_month_mrr_lost,
    ROUND(100.0 * s.mrr_lost / s.mrr_at_risk, 2)                  AS signup_month_mrr_churn_pct,
    ROUND(st.steady_mrr_churn_pct, 2)                             AS steady_state_mrr_churn_pct,
    ROUND(s.mrr_at_risk * (100.0 * s.mrr_lost / s.mrr_at_risk - st.steady_mrr_churn_pct) / 100.0, 2)
                                                                  AS mrr_preserved_if_matched,
    ROUND(100.0 * (100.0 * s.mrr_lost / s.mrr_at_risk - st.steady_mrr_churn_pct)
          / (100.0 * s.mrr_lost / s.mrr_at_risk), 1)              AS pct_of_signup_mrr_loss_avoidable
FROM signup_bucket s
CROSS JOIN steady_state st;
