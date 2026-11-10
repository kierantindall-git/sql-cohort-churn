-- ============================================================================
-- 01_data_quality_checks.sql12
-- Business question: Can we trust this data before we analyze it?
-- Expected result: Every check returns 0 issues. Any non-zero = investigate.
-- ============================================================================
WITH checks AS (
    -- 1. Duplicate customer records (PK should prevent, verified anyway)
    SELECT 'Duplicate customer_ids' AS check_name, COUNT(*) AS issue_count
    FROM (SELECT customer_id FROM customers GROUP BY customer_id HAVING COUNT(*) > 1) d

    UNION ALL
    -- 2. NULLs in critical customer columns
    SELECT 'NULLs in customers (id/date/channel/plan/price/region)', COUNT(*)
    FROM customers
    WHERE customer_id IS NULL OR signup_date IS NULL
       OR acquisition_channel IS NULL OR plan_tier IS NULL
       OR monthly_price IS NULL OR region IS NULL

    UNION ALL
    -- 3. Orphaned subscription rows pointing to no customer
    SELECT 'Orphaned subscription_months (no matching customer)', COUNT(*)
    FROM subscription_months sm
    LEFT JOIN customers c ON c.customer_id = sm.customer_id
    WHERE c.customer_id IS NULL

    UNION ALL
    -- 4. Duplicate monthly snapshots per customer
    SELECT 'Duplicate (customer_id, month_start) rows', COUNT(*)
    FROM (SELECT customer_id, month_start
          FROM subscription_months
          GROUP BY customer_id, month_start HAVING COUNT(*) > 1) d

    UNION ALL
    -- 5. Activity recorded BEFORE the customer's signup month
    --    (compare to signup MONTH, not raw date: month_start is always the 1st)
    SELECT 'Subscription months predating signup month', COUNT(*)
    FROM subscription_months sm
    JOIN customers c ON c.customer_id = sm.customer_id
    WHERE sm.month_start < DATE_TRUNC('month', c.signup_date)::DATE

    UNION ALL
    -- 6. Activity recorded AFTER the study cutoff (2025-12-01)
    SELECT 'Subscription months beyond study cutoff', COUNT(*)
    FROM subscription_months
    WHERE month_start > DATE '2025-12-01'

    UNION ALL
    -- 7. MRR out of sane bounds (<= 0, or above max plan price + buffer)
    SELECT 'MRR values <= 0 or absurdly high', COUNT(*)
    FROM subscription_months
    WHERE mrr <= 0 OR mrr > 10000

    UNION ALL
    -- 8. MRR does not match the customer's plan price
    SELECT 'MRR inconsistent with plan monthly_price', COUNT(*)
    FROM subscription_months sm
    JOIN customers c ON c.customer_id = sm.customer_id
    WHERE sm.mrr <> c.monthly_price

    UNION ALL
    -- 9. Gaps in a customer's monthly grid (active months must be contiguous)
    --    count of distinct months < span between first and last month + 1
    SELECT 'Gaps in monthly activity grid', COUNT(*)
    FROM (SELECT customer_id,
                 COUNT(*) AS n_months,
                 (EXTRACT(YEAR FROM MAX(month_start)) - EXTRACT(YEAR FROM MIN(month_start))) * 12
                   + (EXTRACT(MONTH FROM MAX(month_start)) - EXTRACT(MONTH FROM MIN(month_start))) + 1
                   AS expected_span
          FROM subscription_months
          GROUP BY customer_id
          HAVING COUNT(*) < (EXTRACT(YEAR FROM MAX(month_start)) - EXTRACT(YEAR FROM MIN(month_start))) * 12
                            + (EXTRACT(MONTH FROM MAX(month_start)) - EXTRACT(MONTH FROM MIN(month_start))) + 1) g

    UNION ALL
    -- 10. Customers with zero subscription rows (signed up but never active)
    SELECT 'Customers with no subscription months', COUNT(*)
    FROM customers c
    LEFT JOIN subscription_months sm ON sm.customer_id = c.customer_id
    WHERE sm.customer_id IS NULL

    UNION ALL
    -- 11. Inactive rows present (our model represents churn by ABSENCE of a row,
    --     so is_active should never be FALSE)
    SELECT 'Rows where is_active = FALSE', COUNT(*)
    FROM subscription_months
    WHERE is_active = FALSE
)
SELECT
    check_name,
    issue_count,
    CASE WHEN issue_count = 0 THEN '✅ PASS' ELSE '❌ FAIL' END AS status
FROM checks
ORDER BY check_name;

-- ============================================================================
-- SANITY PROFILES (eyeball, not pass/fail)
-- ============================================================================

-- A. Signups per month: should accelerate toward recent months (growth story)
SELECT DATE_TRUNC('month', signup_date)::DATE AS signup_month,
       COUNT(*) AS new_customers
FROM customers
GROUP BY 1
ORDER BY 1;

-- B. Mix by channel and plan: proportions should match generator design
SELECT acquisition_channel, plan_tier, COUNT(*) AS customers,
       ROUND(AVG(monthly_price), 2) AS avg_price
FROM customers
GROUP BY 1, 2
ORDER BY 1, 2;

-- C. Lifetime distribution: median/avg tenure, share churning within 3 months
WITH tenure AS (
    SELECT sm.customer_id, COUNT(*) AS active_months
    FROM subscription_months sm
    GROUP BY sm.customer_id
)
SELECT COUNT(*) AS customers,
       ROUND(AVG(active_months), 1) AS avg_tenure_months,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY active_months) AS median_tenure,
       ROUND(100.0 * SUM(CASE WHEN active_months <= 3 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_churned_by_m3
FROM tenure;
