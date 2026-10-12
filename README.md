# Credit Risk Analytics: SQL Server Pipeline & Power BI Dashboard

An end-to-end, production-style credit risk analytics pipeline built with **Microsoft SQL Server (T-SQL)** and **Power BI**.

The pipeline ingests approximately **32.6K loan records**, cleanses logical anomalies, engineers behavioral risk features, performs advanced window-based risk analytics, and provides a semantic layer for an interactive executive dashboard.

---

## Executive Summary

| Metric | Value | Business Context |
|---|---:|---|
| **Total Exposure** | **$312M** | Total principal capital deployed across the active portfolio |
| **Total Loans** | **32.6K** | Total individual borrower accounts processed |
| **Portfolio Default Rate** | **21.8%** | Overall portfolio non-performing loan rate |
| **Weighted Average Interest Rate** | **11.32%** | Exposure-weighted yield across credit grades |

### Key Business Insights

- **Default risk rises sharply across lower credit grades.** Default rates increase from approximately **10.0% for Grade A** to **16.3% (B)**, **20.7% (C)**, **59.0% (D)**, and **98.4% for Grade G**.
- **Capital is concentrated in safer tiers.** Grades A and B account for approximately **63% of total exposure**, with $92M and $104M in exposure, respectively.
- **Debt-to-income (DTI) is a key risk indicator.** Borrowers with DTI ratios of **30% or more** have default rates between **49.5% and 75.2%**, compared with **9.9%–15.0%** for borrowers below 10% DTI.
- **Employment stability is associated with lower default rates.** Borrowers with less than two years of employment tenure have a **27.8%** default rate, compared with **16.2%** for those with 10 or more years.

---

## Project Highlights

- **Five-stage ELT pipeline:** Moves from raw CSV staging through cleansing, feature engineering, advanced analytics, and a Power BI semantic layer.
- **Advanced T-SQL analytics:** Uses CTEs, `PERCENT_RANK()`, `NTILE()`, cumulative window functions, conditional aggregation, and database views.
- **Data quality controls:** Includes an isolated staging layer, explicit data types, primary key constraints, audit flags (`imputation_flag`), and loan-grade-specific median imputation.
- **Peer-based risk benchmarking:** Compares borrowers with peers in the same loan-grade and loan-intent groups using `PARTITION BY`.
- **Portfolio concentration analysis:** Uses cumulative exposure and default curves informed by Pareto/Lorenz principles.

---

## Technical Architecture

```text
Raw CSV Dataset
      |
      v
01. Staging & Data Quality
    Raw ingestion, cleansing,
    validation and audit flags
      |
      v
02. Exploratory Analysis
    Portfolio KPIs and segments;
    grade and DTI analysis
      |
      v
03. Feature Engineering
    Risk tiers, cohorts and
    behavioral features
      |
      v
04. Advanced Risk Analytics
    Window functions, peer ranking
    and concentration analysis
      |
      v
05. BI Semantic Layer
    Read-optimized SQL views
      |
      v
Power BI Executive Dashboard
```

## Repository Structure

```text
.
├── README.md
├── sql/
│   ├── 01_schema_ingestion_cleansing.sql
│   ├── 02_exploratory_data_analysis.sql
│   ├── 03_feature_engineering.sql
│   ├── 04_advanced_portfolio_analytics.sql
│   └── 05_power_bi_semantic_layer.sql
├── dashboard/
│   └── credit_risk_report.pbix
└── images/
    ├── dashboard_overview.png
    └── dashboard_risk_heatmap.png
```

> The source dataset contains approximately 32,500 records and is excluded from the repository using `.gitignore`.

---

## Technology Stack

| Area | Tools and Techniques |
|---|---|
| Database | Microsoft SQL Server, T-SQL |
| SQL Analytics | CTEs, window functions (`PERCENT_RANK`, `NTILE`, `SUM() OVER`), conditional aggregation, views |
| BI and Analytics | Microsoft Power BI Desktop, Power Query, DAX |
| Data Quality | Staging isolation, validation rules, median imputation, audit flags |
| Dataset Source | Kaggle Credit Risk Dataset (~32,500 records) |
| Domain | Credit Risk and Portfolio Management |

---

## Pipeline Breakdown

### Stage 1 — Ingestion and Audited Data Cleansing

**Script:** `sql/01_schema_ingestion_cleansing.sql`

- **Staging layer (`dbo.credit_risk_raw`):** Loads source data into a landing table using flexible `VARCHAR` fields and an auto-incrementing `raw_id` primary key. The staging layer preserves the source structure and isolates malformed records.
- **Production table (`dbo.credit_risk_clean`):** Applies explicit production data types, nullability rules, and primary key constraints.
- **Data quality and imputation:** Flags logically impossible records, such as ages above 100. Missing interest rates are imputed using medians specific to each loan grade with `PERCENTILE_CONT`, rather than a single portfolio-wide average.
- **Auditability:** An `imputation_flag` identifies records where imputation was applied.

### Stage 2 — Exploratory Data Analysis

**Script:** `sql/02_exploratory_data_analysis.sql`

- Calculates baseline KPIs, including loan counts, total exposure, and default rates.
- Examines capital distribution across loan grade, loan intent, and income brackets.
- Uses `NTILE(10)` to create income deciles and custom DTI brackets to investigate non-linear changes in default rates.

### Stage 3 — Feature Engineering

**Script:** `sql/03_feature_engineering.sql`

- Builds behavioral risk cohorts using DTI bands, loan intent, and employment tenure.
- Creates financial leverage metrics, including loan-to-income ratios and disposable financial buffer flags.
- Uses `CASE WHEN` logic to create categorical tiers and simplify downstream analysis in Power BI.

### Stage 4 — Advanced Portfolio Analytics

**Script:** `sql/04_advanced_portfolio_analytics.sql`

- Uses `PERCENT_RANK()` with `PARTITION BY` to rank borrowers relative to peers in the same loan-grade and loan-intent groups.
- Uses running totals such as `SUM() OVER (ORDER BY risk_rank)` to examine the concentration of portfolio exposure and default losses.
- Applies Pareto-style analysis to investigate whether a relatively small share of borrowers accounts for a large share of risk or losses.

### Stage 5 — Power BI Semantic Layer

**Script:** `sql/05_power_bi_semantic_layer.sql`

The reporting layer exposes three read-optimized SQL views:

- **`vw_borrower_risk_detail`:** Row-level borrower data for scatter plots and report filters.
- **`vw_risk_matrix_segmentation`:** Aggregated metrics by grade, DTI tier, and employment tier for conditional-formatting heatmaps.
- **`vw_executive_portfolio_summary`:** High-level KPIs grouped by grade, loan intent, and homeownership.

---

## Power BI Dashboard

The report contains two pages.

### 1. Executive Overview

- Four central KPI cards.
- Capital exposure by loan grade.
- Exposure and default rates across loan purposes.
- Slicers for loan grade and loan intent.

### 2. Risk Heatmap

- A matrix of default rates across DTI tiers and employment-stability tiers.
- Conditional formatting from white to dark red to highlight higher-risk segments.
- A chart comparing default rates by loan grade.

### Key DAX Measures

```dax
-- Total Capital Exposure
Total Exposure =
    SUM(vw_borrower_risk_detail[loan_amnt])

-- Account Count
Loan Count =
    COUNTROWS(vw_borrower_risk_detail)

-- Defaulted Loan Count
Default Count =
    CALCULATE(
        COUNTROWS(vw_borrower_risk_detail),
        vw_borrower_risk_detail[loan_status] = 1
    )

-- Portfolio Default Rate
Portfolio Default Rate =
    DIVIDE([Default Count], [Loan Count], 0)

-- Exposure-Weighted Average Interest Rate
Wtd Avg Interest Rate =
    DIVIDE(
        SUMX(
            vw_borrower_risk_detail,
            vw_borrower_risk_detail[loan_int_rate]
                * vw_borrower_risk_detail[loan_amnt]
        ),
        [Total Exposure],
        0
    )
```

**DAX best practice:** Calculate default rates from aggregate counts (`Default Count / Loan Count`). Averaging pre-calculated segment-level percentages can distort the overall portfolio default rate.

---

## Architecture Evaluation and Future Improvements

### Current Limitation

The current dashboard uses three separate SQL views that are not linked through a shared dimensional model. As a result, filter context does not automatically flow between separate flat views, which can limit cross-filtering across report pages and visuals.

### Planned Improvement: Dimensional Star Schema

A future iteration will move to a dimensional star schema with a central `Fact_Loans` table connected through one-to-many relationships to dimensions such as:

- `Dim_Borrower`
- `Dim_Grade`
- `Dim_Intent`
- `Dim_DTI_Tier`

This would provide a more scalable semantic model and support more consistent cross-filtering between visuals.

---

## AI Methodology and Engineering Process

- **Guided learning:** Generative AI was used as a collaborative tutor to explore enterprise data architecture, credit-risk concepts, and DAX debugging.
- **Hands-on implementation:** The project description states that the T-SQL schemas, cleansing queries, window functions, views, DAX measures, and Power BI layout were written, configured, and executed manually.
- **Practical debugging:** Development involved resolving issues such as flat portfolio totals caused by unlinked tables, inflated default rates caused by averaging pre-calculated percentages, and circular dependencies during category sorting.

---

## How to Run the Project

### Prerequisites

- Microsoft SQL Server
- SQL Server Management Studio (SSMS)
- Microsoft Power BI Desktop
- The source credit-risk CSV dataset

### 1. Deploy the SQL Pipeline

1. Open the SQL scripts in SSMS.
2. Run scripts **01 through 05 in order** to create `FinancialRiskDB`, prepare the data, perform the analysis, and generate the reporting views.
3. In `01_schema_ingestion_cleansing.sql`, update the `BULK INSERT` file path so it points to the CSV file on your computer.
4. Check that the data loads and the reporting views are created successfully.

### 2. Open the Power BI Dashboard

1. Open `dashboard/credit_risk_report.pbix` in Power BI Desktop.
2. Select **Transform Data → Data source settings**.
3. Update the SQL Server instance name and connection details to match your local environment.
4. Refresh the data.

---

## Author

**Keashin Dhenem Chetty**
