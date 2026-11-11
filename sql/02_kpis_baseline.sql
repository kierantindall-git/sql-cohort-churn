-- ============================================================================
-- 02_kpis_baseline.sql
-- Business question: Is the business actually growing, or is churn eating
--                    the growth? Establish baseline trends before any cohort work.
--
-- Outputs: one row per calendar month with signups, cumulative customers,
--          active customers, MRR, ARPU, and month-over-month growth.
-- Note:    The simulation window ends 2025-12; later months reflect right-censoring.
-- ============================================================================

WITH monthly_signups AS (
    -- New customers and running total, by signup month
    SELECT
        DATE_TRUNC('month', signup_date)::DATE AS month_start,
        COUNT(*)                               AS new_customers,
        SUM(COUNT(*)) OVER (ORDER BY DATE_TRUNC('month', signup_date)::DATE) AS cumulative_customers
    FROM customers
    GROUP BY 1
),

monthly_activity AS (
    -- Subscription table is monthly grain: one row = one customer active that month
    SELECT
        month_start,
        COUNT(DISTINCT customer_id)  AS active_customers,
        SUM(mrr)                     AS total_mrr,
        ROUND(SUM(mrr) / COUNT(DISTINCT customer_id), 2) AS arpu
    FROM subscription_months
    WHERE is_active = TRUE
    GROUP BY 1
)

SELECT
    s.month_start,
    s.new_customers,
    s.cumulative_customers,
    COALESCE(a.active_customers, 0)                    AS active_customers,
    COALESCE(a.total_mrr, 0)                           AS total_mrr,
    a.arpu,
    -- MoM growth: new customers vs previous month
    ROUND(100.0 * (s.new_customers - LAG(s.new_customers) OVER w)
          / NULLIF(LAG(s.new_customers) OVER w, 0), 1)  AS signup_growth_pct,
    -- MoM growth: active customer base
    ROUND(100.0 * (a.active_customers - LAG(a.active_customers) OVER w)
          / NULLIF(LAG(a.active_customers) OVER w, 0), 1) AS active_growth_pct,
    -- MoM growth: revenue
    ROUND(100.0 * (a.total_mrr - LAG(a.total_mrr) OVER w)
          / NULLIF(LAG(a.total_mrr) OVER w, 0), 1)        AS mrr_growth_pct
FROM monthly_signups s
LEFT JOIN monthly_activity a USING (month_start)
WINDOW w AS (ORDER BY s.month_start)
ORDER BY s.month_start;
