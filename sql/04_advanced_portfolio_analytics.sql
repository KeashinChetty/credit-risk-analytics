USE FinancialRiskDB;
GO 

--This step ranks borrowers by relative risk within their loan grade and employment stability tier. 
--It assigns percentiles and quartiles so we can benchmark each borrower against peers. 
--A DTI of 35% may be fine for stable A-grade borrowers but risky for lower grades, so segmentation highlights context-specific risk differences.

SELECT 
    raw_id, 
    person_age,
    loan_amnt,
    loan_intent,
    loan_grade,
    loan_int_rate, 
    loan_status,
    loan_percent_income,
    dti_risk_tier,

    --Rank borrowers by interest rate within their loan grade 
    PERCENT_RANK() OVER ( PARTITION BY loan_grade ORDER BY loan_int_rate ASC) AS grade_int_rate_percentile, 
    -- PERCENT_RANK assigns each borrower a percentile (0–1) within their loan grade.
    -- Useful for benchmarking interest rates relative to peers in the same grade.

    --Segment borrowers into risk quartiles based on loan-to-income within employment tiers
    NTILE(4) OVER ( PARTITION BY employment_stability_tier ORDER BY loan_percent_income DESC) AS income_risk_quartile,
    -- NTILE(4) splits borrowers into 4 equal-sized groups (quartiles).
    -- Higher quartile = relatively riskier debt-to-income within that stability tier.

    --Moving average of loan amount by loan grade to benchmark exposure
    AVG(CAST(loan_amnt AS FLOAT)) OVER ( PARTITION BY loan_grade ) AS avg_grade_loan_exposure
    -- Windowed AVG calculates the average loan size per grade without collapsing rows.
    -- Lets you compare each borrower’s loan against their grade’s average exposure.
FROM dbo.credit_risk_features
WHERE loan_int_rate IS NOT NULL;
GO

-- This step builds a multi-dimensional risk matrix by combining loan grade, debt-to-income tier, and homeownership status. 
-- It shows how default rates vary across these overlapping segments, helping executives spot pockets of vulnerability where losses spike disproportionately.

SELECT 
    loan_grade,
    dti_risk_tier,
    person_home_ownership,
    COUNT(*) AS total_borrowers,
    SUM( CAST(loan_status AS INT) ) AS total_defaults,

    -- Calculate segment default rate (Probability of Default)
    CAST( SUM( CAST(loan_status AS FLOAT) ) / COUNT(*) * 100 AS DECIMAL(5,2)) AS segment_default_rate_percent,
    -- Divides defaults by total borrowers in the segment to get % default rate.
    -- Casting ensures numeric division instead of integer truncation.

    -- Portfolio volume and exposure metrics
    SUM( CAST(loan_amnt AS BIGINT) ) AS total_exposure_amount,
    CAST( AVG(loan_amnt) AS DECIMAL(10,2) ) AS avg_loan_amount,
    CAST( AVG(loan_int_rate) AS DECIMAL(5,2) ) AS avg_interest_rate,
    CAST( AVG(person_income) AS DECIMAL(12,2) ) AS avg_borrower_income
FROM dbo.credit_risk_features
GROUP BY 
    loan_grade,
    dti_risk_tier,
    person_home_ownership
HAVING COUNT(*) >= 20
ORDER BY 
    segment_default_rate_percent DESC,
    total_exposure_amount DESC;
GO

-- This step measures how much of the portfolio is tied to different loan intents and homeownership categories, along with their exposure and default rates.
-- It highlights whether heavy concentration in certain loan types could create solvency risks during economic downturns.

SELECT 
    loan_intent,
    COUNT(*) AS total_loans,
    SUM( CAST(loan_status AS INT) ) AS defaulted_loans,

    --Default rate by intent
    CAST( SUM( CAST( loan_status AS FLOAT ) ) / COUNT(*) * 100 AS DECIMAL(5,2) ) AS default_rate_percent,

    --Total capital exposed and portfolio share
    SUM( CAST( loan_amnt AS BIGINT ) ) AS total_portfolio_exposure,
    CAST( 
        SUM( CAST(loan_amnt AS FLOAT))
        /(
            SELECT SUM(CAST(loan_amnt AS FLOAT))
            FROM dbo.credit_risk_features
        ) * 100
    AS DECIMAL(5,2)) AS portfolio_share_percent,
    -- Subquery calculates total portfolio loan amount.
    -- Outer SUM compares each intent’s exposure against the total to get % share.
    -- Formatting makes it clear this is a subquery denominator.

    --Average credit score / interest rate metrics
    CAST( AVG( loan_int_rate ) AS DECIMAL(5,2)) AS avg_interest_rate,
    CAST( AVG(person_emp_length) AS DECIMAL(4,1)) AS avg_employment_length_years

FROM dbo.credit_risk_features
GROUP BY loan_intent
ORDER BY total_portfolio_exposure DESC;
GO

-- This step builds a cumulative risk profile by ordering borrowers by interest rate and debt-to-income ratio, then calculating running totals of exposure and defaults. 
-- It helps reveal whether the portfolio follows a Pareto pattern (e.g., 20% of high-risk borrowers driving 80% of losses).
WITH RankedExposure AS (
    SELECT
        raw_id,
        loan_amnt,
        loan_status,
        loan_int_rate,
        loan_percent_income,
        ROW_NUMBER() OVER (ORDER BY loan_int_rate DESC, loan_percent_income DESC) AS risk_rank
        -- Assigns a sequential rank to borrowers ordered by highest interest rate
        -- and highest debt-to-income. Used to build cumulative risk distribution.
    FROM dbo.credit_risk_features
)
SELECT
    risk_rank,
    loan_amnt,
    loan_status,
    loan_int_rate,
    loan_percent_income,

    --Running total of default exposure
    SUM( CAST(loan_amnt AS BIGINT) ) OVER (ORDER BY risk_rank ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_exposure,
    -- Running total of exposure. UNBOUNDED PRECEDING starts at the first row,
    -- CURRENT ROW stops at the borrower in focus → cumulative sum.

    --Running total of defaults
    SUM( CAST(loan_status AS INT) ) OVER (ORDER BY risk_rank ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW ) AS cumulative_defaults,
    --  Running total of defaults across ranked borrowers.
    --  Shows how defaults accumulate as you move down the risk spectrum.

    --Portfolio-wide total exposure percentage reached
    CAST( SUM( CAST(loan_amnt AS FLOAT) ) OVER (ORDER BY risk_rank ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) 
    / (SELECT SUM( CAST(loan_amnt AS FLOAT) ) FROM dbo.credit_risk_features) * 100 AS DECIMAL(5,2)) AS cumulative_exposure_percent
    --  Expresses cumulative exposure as % of total portfolio.
    --  Reveals Pareto-style concentration (e.g., top 20% borrowers = 80% exposure).

-- A Pareto-style concentration means a small portion of borrowers (e.g., the riskiest 20%) account for a large share of losses (around 80%). 
-- This highlights whether portfolio risk is heavily concentrated in a minority segment.
FROM RankedExposure;
GO
