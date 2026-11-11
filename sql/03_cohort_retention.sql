-- ============================================================================
-- 03_cohort_retention.sql
-- Business question: Of each signup cohort, how many customers are still with
--                    us 1, 3, 6, 12 months later? Which cohorts retain worst?
--
-- Method:
--   Cohort = calendar month of signup.
--   Tenure = months between cohort month and activity month (M0 = signup month).
--   Retention(M) = customers active at tenure M / cohort size.
--   Right-censoring: the simulation ends 2025-12-01, so recent cohorts only
--   have early tenures observed. Cells beyond the cutoff are blank, and the
--   `is_observed` flag lets downstream analysis exclude immature cells.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- QUERY 1: Classic retention triangle (% of cohort still active at each tenure)
-- ---------------------------------------------------------------------------
WITH cohorts AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', signup_date)::DATE AS cohort_month
    FROM customers
),

cohort_sizes AS (
    SELECT cohort_month, COUNT(*) AS cohort_size
    FROM cohorts
    GROUP BY 1
),

tenure AS (
    -- One row per (customer, active month), annotated with tenure
    SELECT
        c.cohort_month,
        sm.customer_id,
        (EXTRACT(YEAR  FROM sm.month_start) - EXTRACT(YEAR  FROM c.cohort_month)) * 12
      + (EXTRACT(MONTH FROM sm.month_start) - EXTRACT(MONTH FROM c.cohort_month)) AS tenure_months
    FROM subscription_months sm
    JOIN cohorts c USING (customer_id)
    WHERE sm.is_active = TRUE
),

retained AS (
    SELECT cohort_month, tenure_months, COUNT(DISTINCT customer_id) AS active_customers
    FROM tenure
    GROUP BY 1, 2
)

SELECT
    cs.cohort_month,
    cs.cohort_size,
    100.0                                                                  AS m0_pct,  -- everyone active at signup
    -- Maturity guard: report a cell only if the cohort had time to reach that
    -- tenure by the 2025-12 cutoff; otherwise NULL, so immature cells are blank
    -- in the output instead of a misleading 0.0.
    CASE WHEN (cs.cohort_month + INTERVAL '1 month')::DATE  <= DATE '2025-12-01'
         THEN ROUND(100.0 * COALESCE(MAX(r.active_customers) FILTER (WHERE r.tenure_months =  1), 0) / cs.cohort_size, 1) END AS m1_pct,
    CASE WHEN (cs.cohort_month + INTERVAL '2 months')::DATE <= DATE '2025-12-01'
         THEN ROUND(100.0 * COALESCE(MAX(r.active_customers) FILTER (WHERE r.tenure_months =  2), 0) / cs.cohort_size, 1) END AS m2_pct,
    CASE WHEN (cs.cohort_month + INTERVAL '3 months')::DATE <= DATE '2025-12-01'
         THEN ROUND(100.0 * COALESCE(MAX(r.active_customers) FILTER (WHERE r.tenure_months =  3), 0) / cs.cohort_size, 1) END AS m3_pct,
    CASE WHEN (cs.cohort_month + INTERVAL '6 months')::DATE <= DATE '2025-12-01'
         THEN ROUND(100.0 * COALESCE(MAX(r.active_customers) FILTER (WHERE r.tenure_months =  6), 0) / cs.cohort_size, 1) END AS m6_pct,
    CASE WHEN (cs.cohort_month + INTERVAL '12 months')::DATE <= DATE '2025-12-01'
         THEN ROUND(100.0 * COALESCE(MAX(r.active_customers) FILTER (WHERE r.tenure_months = 12), 0) / cs.cohort_size, 1) END AS m12_pct
FROM cohort_sizes cs
LEFT JOIN retained r USING (cohort_month)
GROUP BY 1, 2
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- QUERY 2: Long format (cohort × tenure) — the version you chart from
-- ---------------------------------------------------------------------------
WITH cohorts AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', signup_date)::DATE AS cohort_month
    FROM customers
),

tenure AS (
    SELECT
        c.cohort_month,
        (EXTRACT(YEAR  FROM sm.month_start) - EXTRACT(YEAR  FROM c.cohort_month)) * 12
      + (EXTRACT(MONTH FROM sm.month_start) - EXTRACT(MONTH FROM c.cohort_month)) AS tenure_months,
        sm.customer_id
    FROM subscription_months sm
    JOIN cohorts c USING (customer_id)
    WHERE sm.is_active = TRUE
),

cohort_sizes AS (
    SELECT cohort_month, COUNT(*) AS cohort_size FROM cohorts GROUP BY 1
)

SELECT
    t.cohort_month,
    cs.cohort_size,
    t.tenure_months,
    COUNT(DISTINCT t.customer_id)                                             AS active_customers,
    ROUND(100.0 * COUNT(DISTINCT t.customer_id) / cs.cohort_size, 1)          AS retention_pct,
    -- Is this cell fully observed? (cohort + tenure within the 2025-12 cutoff)
    (t.cohort_month + (t.tenure_months || ' months')::INTERVAL) <= DATE '2025-12-01' AS is_observed
FROM tenure t
JOIN cohort_sizes cs USING (cohort_month)
GROUP BY 1, 2, 3
ORDER BY 1, 3;

-- ---------------------------------------------------------------------------
-- QUERY 3: Average retention curve — only cohorts that had TIME to reach each
--          tenure are averaged (honest curve, no survivorship illusion)
-- ---------------------------------------------------------------------------
WITH cohorts AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', signup_date)::DATE AS cohort_month
    FROM customers
),

tenure AS (
    SELECT
        c.cohort_month,
        (EXTRACT(YEAR  FROM sm.month_start) - EXTRACT(YEAR  FROM c.cohort_month)) * 12
      + (EXTRACT(MONTH FROM sm.month_start) - EXTRACT(MONTH FROM c.cohort_month)) AS tenure_months,
        sm.customer_id
    FROM subscription_months sm
    JOIN cohorts c USING (customer_id)
    WHERE sm.is_active = TRUE
),

cohort_sizes AS (
    SELECT cohort_month, COUNT(*) AS cohort_size FROM cohorts GROUP BY 1
),

cell AS (
    SELECT
        t.tenure_months,
        t.cohort_month,
        COUNT(DISTINCT t.customer_id)::numeric / MAX(cs.cohort_size) AS retention
    FROM tenure t
    JOIN cohort_sizes cs USING (cohort_month)
    WHERE (t.cohort_month + (t.tenure_months || ' months')::INTERVAL) <= DATE '2025-12-01'
    -- MAX() because cs.cohort_size is from a joined table: Postgres only trusts
    -- functional dependency on the grouped table's own primary key. Since we join
    -- on the grouping key (cohort_month), MAX() is exact, not an approximation.
    GROUP BY 1, 2
)

SELECT
    tenure_months,
    COUNT(*)                                            AS cohorts_measured,
    ROUND(100.0 * AVG(retention), 1)                    AS avg_retention_pct,
    ROUND(100.0 * MIN(retention), 1)                    AS worst_cohort_pct,
    ROUND(100.0 * MAX(retention), 1)                    AS best_cohort_pct
FROM cell
GROUP BY 1
ORDER BY 1;
