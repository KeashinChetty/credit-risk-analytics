USE FinancialRiskDB; 
GO 

-- The following will give us a high-level snapshot of the loan portfolio.
-- It shows total lending exposure, default rates, average loan size, and potential losses from non-performing loans.
-- The goal is to help risk managers quickly see overall capital at risk and profitability before going into detailed categories in later.

WITH PortfolioSummary AS (
	SELECT 
		COUNT(raw_id) AS total_borrowers,
		SUM(loan_amnt) AS total_principal_exposure,
		AVG(CAST(loan_amnt AS NUMERIC(12,2))) AS avg_loan_amount,

		SUM(loan_amnt * loan_int_rate) / SUM(loan_amnt) AS weighted_avg_interest_rate,

		AVG(CAST(person_income AS NUMERIC(12,2))) AS avg_borrower_income,
		AVG(CAST(loan_percent_income AS NUMERIC(8,4))) AS avg_dti_ratio,

		--Defaults count and exposure
		SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS total_default_count,
		SUM(CASE WHEN loan_status = 1 THEN loan_amnt ELSE 0.00 END) AS total_default_exposure,

		--Imputation Audit Verification 
		SUM(CASE WHEN imputation_flag_int_rate = 1 THEN 1 ELSE 0 END) AS imputed_rate_count,
		SUM(CASE WHEN imputation_flag_emp_length = 1 THEN 1 ELSE 0 END) AS imputed_emp_count
	FROM dbo.credit_risk_clean
)
SELECT 
	total_borrowers,
	total_principal_exposure,
	avg_loan_amount, 
	ROUND(weighted_avg_interest_rate, 2) as weighted_avg_interest_rate_percent,
	avg_borrower_income,
	ROUND(avg_dti_ratio * 100, 2) AS avg_dti_percent,
	total_default_count,
	ROUND((CAST(total_default_count AS NUMERIC(12,4)) / total_borrowers) * 100, 2) AS portfolio_default_rate_percent,
	total_default_exposure,
	ROUND((total_default_exposure / total_principal_exposure) * 100, 2) AS capital_at_risk_percent,
	imputed_rate_count,
	imputed_emp_count
FROM PortfolioSummary;
GO

-- The following will break down loan risk by credit grade (A–G) and loan purpose (e.g., Personal, Education, Medical).
-- It calculates loan volumes, principal amounts, default rates, and interest spreads.
-- The aim is to confirm that higher-risk grades carry higher interest margins to offset their greater default likelihood.

--Risk matrix for credit grade
SELECT 
	loan_grade,
	COUNT(raw_id) AS total_loans,
	SUM(loan_amnt) AS total_volume,
	ROUND(AVG(CAST(loan_amnt AS NUMERIC(12,2))), 2) AS avg_loan_size,
	ROUND(AVG(loan_int_rate), 2) AS avg_interest_rate,
	SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS default_count,
	ROUND((CAST(SUM(CASE WHEN loan_status =1 THEN 1 ELSE 0 END) AS NUMERIC(12,4)) / COUNT(raw_id)) * 100, 2) AS default_rate_percent,
	SUM(CASE WHEN loan_status = 1 THEN loan_amnt ELSE 0 END) AS defaulted_volume,
	ROUND((SUM(CASE WHEN loan_status = 1 THEN loan_amnt ELSE 0 END) / SUM(loan_amnt)) * 100, 2) AS volume_loss_rate_percent
FROM dbo.credit_risk_clean
GROUP BY loan_grade
ORDER BY loan_grade ASC;

-- Cross Tabulation to compare Loan Grade and Loan Intent 
WITH GradeIntentMetrics AS (
	SELECT
		loan_grade,
		loan_intent,
		COUNT(raw_id) AS loan_count,
		SUM(loan_amnt) AS intent_volume,
		ROUND(AVG(loan_int_rate), 2) AS avg_int_rate,
		SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS default_count,
		ROUND((CAST(SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS NUMERIC(12,4)) / COUNT(raw_id)) * 100, 2) AS int_default_rate_percent
	FROM dbo.credit_risk_clean
	GROUP BY loan_grade, loan_intent
)
SELECT
	loan_grade,
	loan_intent,
	loan_count,
	--Calculate the percentage of intent volume within the specific credit grade
	ROUND((intent_volume / SUM(intent_volume) OVER(PARTITION BY loan_grade)) * 100, 2) AS percent_grade_volume,
	avg_int_rate,
	default_count,
	int_default_rate_percent,
	--Rank the loan intent within grade by the highest default risk
	DENSE_RANK() OVER(PARTITION BY loan_grade ORDER BY int_default_rate_percent DESC) AS risk_rank_within_grade
FROM GradeIntentMetrics
ORDER BY loan_grade ASC, risk_rank_within_grade ASC;
GO

-- The following will segment borrowers into income and debt-to-income deciles using NTILE to create 10 equal-sized buckets.
-- It will help detect tipping points where default risk accelerates, such as when loan payments exceed 30% of income.
-- The goal is to uncover non-linear risk patterns that simple averages might miss, highlighting leverage thresholds that drive defaults.

WITH IncomeDecile AS (
	SELECT
		raw_id,
		person_income,
		loan_amnt,
		loan_percent_income,
		loan_status,
		NTILE(10) OVER (ORDER BY person_income ASC) AS income_decile
	FROM dbo.credit_risk_clean
)
SELECT
	income_decile,
	MIN(person_income) AS min_income,
	MAX(person_income) AS max_income,
	COUNT(raw_id) AS total_borrowers,
	ROUND(AVG(CAST(loan_amnt AS NUMERIC(12,2))), 2) AS avg_loan_amount,
	ROUND(AVG(loan_percent_income) * 100, 2) AS avg_dti_percent,
	SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS default_count,
	ROUND((CAST(SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS NUMERIC(12,4)) / COUNT(raw_id)) * 100, 2) AS default_rate_percent
FROM IncomeDecile
GROUP BY income_decile
ORDER BY income_decile ASC;

--Debt-to-Income (Loan Percentage Income) Bucket Analysis
WITH DTIBuckets AS (
	SELECT
		raw_id,
		loan_amnt,
		person_income,
		loan_percent_income,
		loan_status,
		CASE 
			WHEN loan_percent_income < 0.10 THEN '1. Low(< 10%)'
			WHEN loan_percent_income BETWEEN 0.10 AND 0.1999 THEN '2. Moderate (10% - 19%)'
			WHEN loan_percent_income BETWEEN 0.20 AND 0.2999 THEN '3. Elevated (20% - 29%)'
			WHEN loan_percent_income BETWEEN 0.30 AND 0.3999 THEN '4. High (30% - 39%)'
			ELSE '5. Severe (>= 40%)'
		END AS dti_tier
	FROM dbo.credit_risk_clean
)
SELECT 
	dti_tier,
	COUNT(raw_id) AS total_loans,
	SUM(loan_amnt) AS total_volume,
	ROUND(AVG(CAST(person_income AS NUMERIC(12,2))), 2) AS avg_income,
	SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS default_count,
	ROUND( ( CAST( SUM(CASE WHEN loan_status = 1 THEN 1 ELSE 0 END) AS NUMERIC(12,4)) / COUNT(raw_id ) ) * 100, 2) AS default_rate_percent
FROM DTIBuckets
GROUP BY dti_tier
ORDER BY dti_tier ASC;
GO