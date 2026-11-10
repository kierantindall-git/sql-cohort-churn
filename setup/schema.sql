-- ============================================================================
-- Streamline SaaS: Database Schema & Synthetic Data Generation
-- Dialect: PostgreSQL 15+ (tested on PostgreSQL 18)
-- Reproducibility: Seed is fixed (0.42) for deterministic results
-- ============================================================================

-- 1. CLEANUP & SCHEMA CREATION
DROP TABLE IF EXISTS subscription_months CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

CREATE TABLE customers (
    customer_id         SERIAL PRIMARY KEY,
    signup_date         DATE NOT NULL,
    acquisition_channel VARCHAR(50) NOT NULL,
    plan_tier           VARCHAR(50) NOT NULL,
    monthly_price       NUMERIC(10, 2) NOT NULL,
    region              VARCHAR(50) NOT NULL
);

CREATE TABLE subscription_months (
    customer_id  INT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    month_start  DATE NOT NULL,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    mrr          NUMERIC(10, 2) NOT NULL,
    PRIMARY KEY (customer_id, month_start)
);

CREATE INDEX idx_sub_months_cust_date ON subscription_months(customer_id, month_start);
CREATE INDEX idx_customers_signup ON customers(signup_date);

-- 2. REPRODUCIBLE PSEUDO-RANDOM SEED
SELECT setseed(0.42);

-- 3. POPULATE CUSTOMERS (~3,200 customers across 2024-01-01 to 2025-11-30)
-- Skewed so signups accelerate over time (mimicking business growth)
INSERT INTO customers (signup_date, acquisition_channel, plan_tier, monthly_price, region)
WITH raw_cohorts AS (
    SELECT
        id,
        -- Quadratic distribution to accelerate signups over 700 days
        DATE '2024-01-01' + (ROUND(POWER(random(), 0.72) * 699))::INT AS raw_signup,
        random() AS r_chan,
        random() AS r_plan,
        random() AS r_reg
    FROM generate_series(1, 3200) AS s(id)
)
SELECT
    raw_signup AS signup_date,
    CASE 
        WHEN r_chan < 0.38 THEN 'Paid Search'
        WHEN r_chan < 0.68 THEN 'Organic Search'
        WHEN r_chan < 0.86 THEN 'Referral'
        ELSE 'Outbound Sales'
    END AS acquisition_channel,
    CASE 
        WHEN r_plan < 0.52 THEN 'Basic'
        WHEN r_plan < 0.86 THEN 'Pro'
        ELSE 'Enterprise'
    END AS plan_tier,
    CASE 
        WHEN r_plan < 0.52 THEN 29.00
        WHEN r_plan < 0.86 THEN 79.00
        ELSE 249.00
    END AS monthly_price,
    CASE 
        WHEN r_reg < 0.45 THEN 'North America'
        WHEN r_reg < 0.75 THEN 'Europe'
        WHEN r_reg < 0.90 THEN 'Asia-Pacific'
        ELSE 'Latin America'
    END AS region
FROM raw_cohorts
ORDER BY raw_signup;

-- 4. SIMULATE SUBSCRIPTION MONTHS & REALISTIC CHURN
-- Logic:
-- - Every customer is active in Month 0 (month of signup)
-- - Month 1 has an initial "onboarding drop" (highest hazard)
-- - Paid Search churns faster; Enterprise & Referral retain much better
-- - Customers remain active until their simulated churn month, or until 2025-12-01 (study cutoff)
INSERT INTO subscription_months (customer_id, month_start, is_active, mrr)
WITH customer_lifespans AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', signup_date)::DATE AS signup_month,
        monthly_price,
        -- Calculate customer-specific expected lifetime based on plan & channel
        -- Geometric distribution simulation for tenure months
        GREATEST(1, ROUND(
            -LN(GREATEST(0.001, random())) / (
                -- Base hazard rate by plan tier
                CASE plan_tier
                    WHEN 'Basic' THEN 0.095
                    WHEN 'Pro' THEN 0.052
                    WHEN 'Enterprise' THEN 0.021
                END
                +
                -- Channel modifier
                CASE acquisition_channel
                    WHEN 'Paid Search' THEN 0.045
                    WHEN 'Organic Search' THEN 0.015
                    WHEN 'Referral' THEN -0.012
                    WHEN 'Outbound Sales' THEN -0.018
                END
            )
        ))::INT AS lifetime_months
    FROM customers
),
active_months_grid AS (
    SELECT
        cl.customer_id,
        (cl.signup_month + (m.month_num * INTERVAL '1 month'))::DATE AS month_start,
        cl.monthly_price AS mrr
    FROM customer_lifespans cl
    CROSS JOIN LATERAL generate_series(0, cl.lifetime_months - 1) AS m(month_num)
    WHERE (cl.signup_month + (m.month_num * INTERVAL '1 month'))::DATE <= DATE '2025-12-01'
)
SELECT
    customer_id,
    month_start,
    TRUE AS is_active,
    mrr
FROM active_months_grid;
