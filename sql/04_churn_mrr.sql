-- ============================================================================
-- 04_churn_mrr.sql
-- Business question: How much churn do we have each month — in customers AND
--                    revenue — and which plans, channels, and tenures drive it?
--
-- Method:
--   Churn event = a customer active in month N who is absent in month N+1.
--   (Valid because data quality check #9 proved activity grids are contiguous,
--    so absence of a row genuinely means "churned", not "missing".)
--   Logo churn % = churned customers / customers at risk (active in N).
--   MRR churn %  = MRR lost / MRR at risk.
--
-- Right-censoring: the final month in the data has no "next month", so it is
--   excluded from at-risk exposure — otherwise it would be scored as 100% churn.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- QUERY 1: Monthly logo churn & MRR churn over time
-- ---------------------------------------------------------------------------
WITH active AS (
    SELECT customer_id, month_start, mrr
    FROM subscription_months
    WHERE is_active = TRUE
),

events AS (
    SELECT
        a.month_start AS as_of_month,
        a.mrr,
        (b.customer_id IS NULL) AS churned
    FROM active a
    LEFT JOIN active b
           ON b.customer_id = a.customer_id
          AND b.month_start = (a.month_start + INTERVAL '1 month')::DATE
    WHERE a.month_start < (SELECT MAX(month_start) FROM subscription_months)
)

SELECT
    as_of_month,
    COUNT(*)                                                              AS customers_at_risk,
    SUM(CASE WHEN churned THEN 1 ELSE 0 END)                              AS churned_customers,
    ROUND(100.0 * SUM(CASE WHEN churned THEN 1 ELSE 0 END) / COUNT(*), 2) AS logo_churn_pct,
    ROUND(SUM(mrr), 2)                                                    AS mrr_at_risk,
    ROUND(SUM(CASE WHEN churned THEN mrr ELSE 0 END), 2)                  AS mrr_churned,
    ROUND(100.0 * SUM(CASE WHEN churned THEN mrr ELSE 0 END) / SUM(mrr), 2) AS mrr_churn_pct
FROM events
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------------
-- QUERY 2: Churn by plan tier × acquisition channel (all months combined)
--          Exposure-weighted monthly churn: each customer-month counts once.
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
)

SELECT
    plan_tier,
    acquisition_channel,
    COUNT(*)                                                              AS customer_months_at_risk,
    SUM(CASE WHEN churned THEN 1 ELSE 0 END)                              AS churned_customer_months,
    ROUND(100.0 * SUM(CASE WHEN churned THEN 1 ELSE 0 END) / COUNT(*), 2) AS monthly_logo_churn_pct,
    ROUND(SUM(mrr), 2)                                                    AS mrr_at_risk,
    ROUND(SUM(CASE WHEN churned THEN mrr ELSE 0 END), 2)                  AS mrr_lost,
    ROUND(100.0 * SUM(CASE WHEN churned THEN mrr ELSE 0 END) / SUM(mrr), 2) AS monthly_mrr_churn_pct
FROM events
GROUP BY 1, 2
ORDER BY 1, 2;


-- -- ---------------------------------------------------------------------------
-- -- QUERY 3: Churn hazard by tenure — WHEN in the customer lifecycle do they leave?
-- -- ---------------------------------------------------------------------------
WITH cohorts AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', signup_date)::DATE AS cohort_month
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
)

SELECT
    CASE
        WHEN tenure_months = 0              THEN '0 (signup month)'
        WHEN tenure_months BETWEEN 1 AND 2  THEN '1-2'
        WHEN tenure_months BETWEEN 3 AND 5  THEN '3-5'
        WHEN tenure_months BETWEEN 6 AND 11 THEN '6-11'
        ELSE                                     '12+'
    END                                                                   AS tenure_bucket,
    COUNT(*)                                                              AS customer_months_at_risk,
    SUM(CASE WHEN churned THEN 1 ELSE 0 END)                              AS churned_customer_months,
    ROUND(100.0 * SUM(CASE WHEN churned THEN 1 ELSE 0 END) / COUNT(*), 2) AS monthly_logo_churn_pct,
    ROUND(SUM(mrr), 2)                                                    AS mrr_at_risk,
    ROUND(100.0 * SUM(CASE WHEN churned THEN mrr ELSE 0 END) / SUM(mrr), 2) AS monthly_mrr_churn_pct
FROM events
GROUP BY 1
ORDER BY MIN(tenure_months);
