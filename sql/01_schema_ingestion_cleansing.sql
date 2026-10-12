-- We first need to create the database we will be working from
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = N'FinancialRiskDB')
BEGIN 
	CREATE DATABASE FinancialRiskDB;
END 
GO

USE FinancialRiskDB
GO

--Next we will create a table that holds the raw incoming data from our chosen dataset
--In a professional environment, the ELT (Extract, Transform, Load) pipeline has a staging table that allows raw data to be ingested without making any changes to raw data
--Once the data has been ingested into the staging table, we can transform the data in any way necessary when moving it to a new table, we never change raw data in any way

IF OBJECT_ID('dbo.credit_risk_raw', 'U') IS NOT NULL 
	DROP TABLE dbo.credit_risk_raw;
GO 

CREATE TABLE dbo.credit_risk_raw (

raw_id INT IDENTITY(1,1) PRIMARY KEY,
-- IDENTITY(1,1) = auto-increment starting at 1, increasing by 1
-- PRIMARY KEY = unique identifier for each row

--Demographics of the borrower
person_age VARCHAR(50) NULL, --we are staging age as a VARCHAR in the event that there are any strings or outliers in the raw data 
person_income VARCHAR(50) NULL, --annual income
person_home_ownership VARCHAR(50) NULL, -- RENT/OWN/MORTGAGE/OTHER
person_emp_length VARCHAR(50) NULL, --employment length in year, could contain NULLs

--Loan details
loan_intent VARCHAR(50) NULL, --PERSONAL,EDUCATION, MEDICAL, VENTURE, HOMEIMPROVEMENT, DEBTCONSOLIDATION
loan_grade VARCHAR(10) NULL, -- A,B,C,D,E,F,G
loan_amnt VARCHAR(50) NULL, --Total requested loan amount
loan_int_rate VARCHAR(50) NULL, --Interest rate in percentage 
loan_status VARCHAR(50) NULL, -- 0 = Non-default, 1 = Default
loan_percent_income VARCHAR(50) NULL, --Loan amount relative to income (ratio decimal)

--Credit History 
cb_person_default_on_file VARCHAR(10) NULL, --Historical default record (Y/N)
cb_person_cred_hist_length VARCHAR(50) NULL, --Years of active credit history

--Timestamp 
created_at DATETIME DEFAULT GETDATE() --Audit timestamps for pipeline tracking
);
GO


-- In ELT pipelines, source CSV files often lack metadata fields like our auto-incrementing 'raw_id' or timestamped 'created_at'.
-- Creating this view isolates the 12 expected CSV fields so SQL Server's BULK INSERT engine maps input columns correctly without any alignment errors.
IF OBJECT_ID('dbo.vw_credit_risk_raw_load', 'V') IS NOT NULL
	DROP VIEW dbo.vw_credit_risk_raw_load;
GO

CREATE VIEW dbo.vw_credit_risk_raw_load AS 
SELECT 
	person_age,
	person_income, 
	person_home_ownership,
person_emp_length,
    loan_intent,
    loan_grade,
    loan_amnt,
    loan_int_rate,
    loan_status,
    loan_percent_income,
    cb_person_default_on_file,
    cb_person_cred_hist_length
FROM dbo.credit_risk_raw;
GO

-- We will now ingest all our data from an external CSV file into the credit_risk_raw table using SQL Server's bulk mechanism
BULK INSERT dbo.vw_credit_risk_raw_load
FROM '[YOUR_PATH]\credit_risk_dataset.csv'
WITH (
	FIRSTROW = 2, --This skips the CSV header row 
	FIELDTERMINATOR = ',', --The columns are separated by commas
	ROWTERMINATOR = '\n', --Standard line break 
	TABLOCK, --Lock the entire table during insert for faster bulk load
	KEEPNULLS -- Preserves the NULL values from the CSV rather than replace it with defaults 
);
GO 

SELECT 
    COUNT(*) AS total_rows,
    MIN(raw_id) AS min_id,
    MAX(raw_id) AS max_id,
    MIN(created_at) AS first_loaded_at
FROM dbo.credit_risk_raw;

SELECT TOP 5 
    raw_id, 
    person_age, 
    person_income, 
    loan_intent, 
    created_at
FROM dbo.credit_risk_raw;

-- In SQL Server, a View without joins, aggregations, or functions acts as an "Updatable View" that passes INSERT statements directly to its underlying table.
-- Inserting through this 12-column view explicitly maps each CSV field to its exact target column in 'dbo.credit_risk_raw' by name rather than ordinal position.
-- SQL Server automatically populates the omitted base table columns, assigning sequential values to 'raw_id' via IDENTITY(1,1) and the load timestamp to 'created_at' via DEFAULT GETDATE().

--Now we will create a new table with strict data types, non-null constraints, and tracking flags for data quality auditing 
IF OBJECT_ID('dbo.credit_risk_clean', 'U') IS NOT NULL
    DROP TABLE dbo.credit_risk_clean;
GO

CREATE TABLE dbo.credit_risk_clean (
    clean_id INT IDENTITY(1,1) PRIMARY KEY,
    raw_id INT NOT NULL,                            -- Audit link to credit_risk_raw

    -- Borrower Demographics
    person_age INT NOT NULL,                        -- Filtered to realistic range (18-100)
    person_income INT NOT NULL,                     -- Annual income in currency units
    person_home_ownership VARCHAR(20) NOT NULL,     -- RENT, OWN, MORTGAGE, OTHER
    person_emp_length DECIMAL(4,1) NULL,            -- Employment length in years (Imputed)

    -- Loan Attributes
    loan_intent VARCHAR(50) NOT NULL,               -- Personal, Education, Medical, etc.
    loan_grade CHAR(1) NOT NULL,                    -- A through G
    loan_amnt INT NOT NULL,                         -- Requested loan amount
    loan_int_rate DECIMAL(5,2) NULL,                -- Percentage (e.g., 11.25%, Imputed)
    loan_status TINYINT NOT NULL,                   -- Target variable: 0 = Non-default, 1 = Default
    loan_percent_income DECIMAL(4,2) NOT NULL,      -- Debt-to-income ratio decimal

    -- Credit Characteristics
    cb_person_default_on_file CHAR(1) NOT NULL,     -- Historical default flag ('Y'/'N')
    cb_person_cred_hist_length INT NOT NULL,        -- Credit history in years

    -- Audit Flags
    imputation_flag_int_rate BIT DEFAULT 0,         -- 1 = value was imputed, 0 = original
    imputation_flag_emp_length BIT DEFAULT 0        -- 1 = value was imputed, 0 = original
);
GO

--We will now clean, transform, filter extreme outliers, and impute missing values from our staging table
--Ages > 100 or employment years exceeding lifetime (e.g., age 22 with 123 years employment) distort credit risk assessment and loss calculations.
--Deleting records with missing interest rates or employment length reduces sample size and biases analysis. Imputing interest rates by `loan_grade` median preserves risk groups.

WITH GradeMedian AS (
    SELECT DISTINCT 
        loan_grade,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY TRY_CAST(loan_int_rate AS DECIMAL(5,2)))
            OVER (PARTITION BY loan_grade) AS median_int_rate
    FROM dbo.credit_risk_raw
    WHERE TRY_CAST(loan_int_rate AS DECIMAL(5,2)) IS NOT NULL
    ),
  
EmpLengthMedian AS (
    SELECT DISTINCT 
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY TRY_CAST(person_emp_length AS DECIMAL(4,1)))
            OVER () AS median_emp_length
    FROM dbo.credit_risk_raw
    WHERE TRY_CAST(person_emp_length AS DECIMAL(4,1)) IS NOT NULL
)

INSERT INTO dbo.credit_risk_clean (
    raw_id,
    person_age,
    person_income,
    person_home_ownership,
    person_emp_length,
    loan_intent,
    loan_grade,
    loan_amnt,
    loan_int_rate,
    loan_status,
    loan_percent_income,
    cb_person_default_on_file,
    cb_person_cred_hist_length,
    imputation_flag_int_rate,
    imputation_flag_emp_length
)
SELECT 
    r.raw_id, 
    TRY_CAST(r.person_age AS INT) AS person_age,
    TRY_CAST(r.person_income AS INT) AS person_income,
    UPPER(TRIM(r.person_home_ownership)) AS person_home_ownership,

    -- Impute missing employment length using overall median
    COALESCE(
        TRY_CAST(r.person_emp_length AS DECIMAL(4,1)),
        elm.median_emp_length
    ) AS person_emp_length,

    UPPER(TRIM(r.loan_intent)) AS loan_intent,
    UPPER(TRIM(r.loan_grade)) AS loan_grade, 
    TRY_CAST(r.loan_amnt AS INT) AS loan_amnt,

    -- Impute missing interest rate using grade specific median
    COALESCE(
        TRY_CAST(r.loan_int_rate AS DECIMAL(5,2)),
        gm.median_int_rate
    ) AS loan_int_rate,

    TRY_CAST(r.loan_status AS TINYINT) AS loan_status,
    TRY_CAST(r.loan_percent_income AS DECIMAL(4,2)) AS loan_percent_income,
    UPPER(TRIM(r.cb_person_default_on_file)) AS cb_person_default_on_file,
    TRY_CAST(r.cb_person_cred_hist_length AS INT) AS cb_person_cred_hist_length,

    -- Track all records that were imputed
    CASE WHEN TRY_CAST(r.loan_int_rate AS DECIMAL(5,2)) IS NULL THEN 1 ELSE 0 END AS imputation_flag_int_rate,
    CASE WHEN TRY_CAST(r.person_emp_length AS DECIMAL(4,1)) IS NULL THEN 1 ELSE 0 END AS imputation_flag_emp_length

FROM dbo.credit_risk_raw r
LEFT JOIN GradeMedian gm
    ON UPPER(TRIM(r.loan_grade)) = gm.loan_grade
CROSS JOIN EmpLengthMedian elm

WHERE 
    -- Remove impossible age records
    TRY_CAST(r.person_age AS INT) BETWEEN 18 AND 100

    -- Remove logically impossible employment lengths relative to age
    AND (
        TRY_CAST(r.person_emp_length AS DECIMAL(4,1)) IS NULL
        OR TRY_CAST(r.person_emp_length AS DECIMAL(4,1)) <= (TRY_CAST(r.person_age AS INT) - 14)
    )

    -- Ensure core attributes are present and valid
    AND TRY_CAST(r.person_income AS INT) IS NOT NULL
    AND TRY_CAST(r.loan_amnt AS INT) IS NOT NULL
    AND TRY_CAST(r.loan_status AS TINYINT) IN (0,1);
GO

--We will now summarize the raw vs clean record countand inspect the total imputated values
-- By doing data validation we guarentee that the pipeline is accurate before moving forward

SELECT 
    (SELECT COUNT(*) FROM dbo.credit_risk_raw) AS raw_records,
    (SELECT COUNT(*) FROM dbo.credit_risk_clean) AS clean_records,
    (SELECT COUNT(*) FROM dbo.credit_risk_raw) - (SELECT COUNT(*) FROM dbo.credit_risk_clean) AS dropped_outliers

SELECT 
    SUM(CAST(imputation_flag_int_rate AS INT)) AS total_imputed_int_rates,
    SUM(CAST(imputation_flag_emp_length AS INT)) AS total_imputed_emp_lengths
FROM dbo.credit_risk_clean;
GO


