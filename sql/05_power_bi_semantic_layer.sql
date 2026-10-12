USE FinancialRiskDB;
GO

-- Creating semantic views (`vw_...`) for Power BI decouples raw tables from reporting.
-- This ensures cleaner governance, faster refresh times, and a structured model that feeds dashboards consistently. 
-- It standardizes the data layer so analysts and executives work off the same trusted definitions.

--Executive Summary View (Aggregated KPIs by Grade & Intent)
CREATE OR ALTER VIEW dbo.vw_executive_portfolio_summary AS
SELECT
	loan_grade,
	loan_intent,
	person_home_ownership,
	COUNT(*) AS total_loans,
	SUM(CAST(loan_status AS INT)) AS total_defaults,
	CAST( SUM( CAST(loan_status AS FLOAT) ) / COUNT(*) * 100 AS DECIMAL(5,2) ) AS default_rate_percent,
	SUM(CAST(loan_amnt AS BIGINT)) AS total_exposure,
	CAST(AVG(loan_amnt) AS DECIMAL(10,2)) AS avg_loan_amount,
	CAST(AVG(loan_int_rate) AS DECIMAL(5,2)) AS avg_interest_rate,
	CAST(AVG(person_income) AS DECIMAL(12,2)) AS avg_income
FROM dbo.credit_risk_features
GROUP BY loan_grade, loan_intent, person_home_ownership;
GO
-- The view above is designed for executives who need a high-level snapshot.
-- It aggregates key metrics (loan counts, defaults, exposure, averages) by loan grade and intent so leadership can quickly assess portfolio health without drilling into borrower-level detail.

--Risk Matrix View (Segment-level detail for heatmaps)
CREATE OR ALTER VIEW dbo.vw_risk_matrix_segmentation AS 
SELECT
	loan_grade,
	dti_risk_tier,
	employment_stability_tier,
	COUNT(*) AS borrower_count,
	SUM(CAST(loan_status AS INT)) AS default_count,
	CAST( SUM( CAST(loan_status AS FLOAT) ) / COUNT(*) * 100 AS DECIMAL(5,2) ) AS segment_default_rate,
	SUM(CAST(loan_amnt AS BIGINT)) AS segment_exposure
FROM dbo.credit_risk_features
GROUP BY loan_grade, dti_risk_tier, employment_stability_tier;
GO
-- The view above supports risk committees and analysts by showing default rates and exposure across overlapping segments (grade × DTI tier × stability).
-- This enables heatmap visualizations in Power BI to highlight systemic vulnerabilities and concentration pockets.

--Granular Borrower Profile View 
CREATE OR ALTER VIEW dbo.vw_borrower_risk_detail AS 
SELECT
	raw_id,
	person_age,
	person_income,
	person_emp_length,
	person_home_ownership,
	loan_amnt,
	loan_intent,
	loan_grade,
	loan_int_rate,
	loan_status,
	loan_percent_income,
	cb_person_default_on_file,
	cb_person_cred_hist_length,
	employment_stability_tier,
	dti_risk_tier
FROM dbo.credit_risk_features;
GO
-- The view above provides detailed borrower-level attributes for drill-through analysis.
-- It is used when analysts need to investigate specific cohorts or individuals.
