USE FinancialRiskdb;
GO 

-- This step is the data prep stage where raw loan values are transformed into standardized features (ratios, tiers, normalized bands).
-- These engineered signals make borrower behavior clearer and provide model-ready inputs for credit scoring and default risk prediction.

IF OBJECT_ID('dbo.credit_risk_features', 'U') IS NOT NULL
	DROP TABLE dbo.credit_risk_features;
GO

SELECT 
	raw_id,

	--Demographics and Baselines Attributes 
	person_age,
	person_income,
	person_home_ownership,
	person_emp_length,
	imputation_flag_emp_length,

	--Loan characteristics 
	loan_intent,
	loan_grade,
	loan_amnt,
	loan_int_rate,
	imputation_flag_int_rate,
	loan_percent_income,
	loan_status,
	cb_person_default_on_file,
	cb_person_cred_hist_length, 

	--This will be our first engineered feature, Income-to-Loan Ratio
	--It measures how many times larger a borrower's income is compared to the loan
    --Higher values indicate safer, lower-leverage borrowers
	CAST(person_income AS NUMERIC(12,2)) / NULLIF(CAST(loan_amnt AS NUMERIC(12,2)), 0) AS income_to_loan_ratio,

	--Our second engineered feature will be age cohorts
	--This groups borrowers into generational life-stages to capture risk patterns associated with career maturity and financial stability.

	CASE 
		WHEN person_age < 25 THEN '1. Young Adult (<25)'
		WHEN person_age BETWEEN 25 AND 34 THEN '2. Early Career (25-34)'
		WHEN person_age BETWEEN 35 AND 44 THEN '3. Established (35-44)'
		WHEN person_age BETWEEN 45 and 54 THEN '4. Late Career (45-54)'
		ELSE '5. Mature (55+)'
	END AS borrower_age_cohort,

	--Our third engineered feature is Employment Stability Tier
	--This categorizes job tenure to evaluate income security

	CASE 
		WHEN person_emp_length < 2.0 THEN '1. New/Junior (<2 years)'
		WHEN person_emp_length BETWEEN 2.0 AND 5.0 THEN '2. Stable (2-5 years)'
		WHEN person_emp_length BETWEEN 5.0 AND 10.0 THEN '3. Tenured (5-10 years)'
		ELSE '4. Highly Tenured (10+ years)'
	END AS employment_stability_tier,

	--Our fourth engineered feature is a Comprehensive DTI Risk Tier
	--This encodes debt-to-income percentages into distinct credit risk thresholds

	CASE 
		WHEN loan_percent_income < 0.10 THEN 'Low Risk (<10%)'
		WHEN loan_percent_income BETWEEN 0.10 AND 0.1999 THEN 'Moderate Risk (10-20%)'
		WHEN loan_percent_income BETWEEN 0.20 AND 0.2999 THEN 'Elevated Risk (20-30%)'
		ELSE 'High Risk (30%+)'
	END AS dti_risk_tier

INTO dbo.credit_risk_features 
FROM dbo.credit_risk_clean;
GO

-- We will add a Primary Key to ensure each record in the feature table has a unique identifier, prevents duplicates, and enforces data integrity.
-- It makes joins and queries more efficient and reliable.
ALTER TABLE dbo.credit_risk_features
ADD CONSTRAINT PK_credit_risk_features PRIMARY KEY CLUSTERED(raw_id);
GO

-- This step checks whether the new features actually separate borrowers into groups with clear differences in default rates.
-- If a feature doesn’t show a logical trend, it may need to be re-bucketed before being used in a scoring model.

-- Validation Query for Default Rate by Borrower Age Cohort 
SELECT 
	borrower_age_cohort,
	COUNT(raw_id) AS total_loans,
	SUM(loan_amnt) AS total_volume,
	ROUND(AVG(loan_percent_income) * 100, 2) AS avg_dti_percent,
	SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS default_count,
	ROUND((CAST(SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS NUMERIC(12,4)) / COUNT(raw_id)) * 100, 2) AS default_rate_percent
FROM dbo.credit_risk_features
GROUP BY borrower_age_cohort
ORDER BY borrower_age_cohort ASC;

--Validation Query for Default Rate by Employment Stability Tier
SELECT	
	employment_stability_tier,
	COUNT(raw_id) AS total_loans,
	SUM(loan_amnt) AS total_volume,
	ROUND( AVG( income_to_loan_ratio ), 2 ) AS avg_income_to_loan_ratio,
	SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS default_count,
	ROUND( ( CAST( SUM( CASE WHEN loan_status = 1 THEN 1 ELSE 0 END ) AS NUMERIC(12,4) ) / COUNT(raw_id) ) * 100, 2) AS default_rate_percent
FROM dbo.credit_risk_features
GROUP BY employment_stability_tier
ORDER BY employment_stability_tier ASC;
GO