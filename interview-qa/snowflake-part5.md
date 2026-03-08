# Advanced Snowflake - Q&A (Part 5: Advanced Features, Integration and AI)

[Back to Index](README.md)

---

### Q41. How did you use Snowpark Python for building a prepayment prediction pipeline entirely within Snowflake?

**Situation:** Our MBS analytics team at a secondary market firm needed to predict monthly prepayment speeds (CPR) across 12,000+ Ginnie Mae II pools. The existing process exported data to an external Python server, ran scikit-learn models, and re-imported results — a fragile 6-hour overnight batch with frequent credential and network failures.

**Task:** Rebuild the entire prepayment prediction pipeline natively inside Snowflake using Snowpark Python, eliminating data movement and reducing end-to-end latency to under 60 minutes.

**Action:** I designed a three-stage Snowpark pipeline. First, a feature engineering stage using Snowpark DataFrames to compute 30+ predictive features — burnout factor, seasonality index, SATO (spread at origination), loan age buckets, and current incentive (note rate minus prevailing rate). Second, I registered a vectorized UDF wrapping an XGBoost model trained on 10 years of Ginnie Mae eMBS factor data. Third, I orchestrated everything with Snowflake Tasks on a cron schedule.

```python
from snowflake.snowpark import Session
from snowflake.snowpark.functions import col, lit, udf
from snowflake.snowpark.types import FloatType
import cachetools

session = Session.builder.configs(connection_params).create()

# Feature engineering with Snowpark DataFrames
pools_df = session.table("GINNIE_MAE.POOL_MASTER") \
    .join(session.table("GINNIE_MAE.MONTHLY_FACTORS"), "POOL_NUMBER") \
    .with_column("INCENTIVE", col("WAC") - col("CURRENT_MORTGAGE_RATE")) \
    .with_column("BURNOUT", col("CUMULATIVE_PREPAY") / col("ORIGINAL_BALANCE")) \
    .with_column("SEASONING", col("WALA") / lit(360))

# Register XGBoost model as a vectorized UDF
@udf(name="PREDICT_CPR", is_permanent=True, stage_location="@ML_MODELS",
     replace=True, packages=["xgboost","pandas","cachetools"])
def predict_cpr(incentive: float, burnout: float, seasoning: float,
                fico: float, ltv: float, loan_age: int) -> float:
    import xgboost as xgb, pandas as pd
    model = xgb.Booster()
    model.load_model("/tmp/cpr_model.json")
    features = pd.DataFrame([[incentive, burnout, seasoning, fico, ltv, loan_age]])
    return float(model.predict(xgb.DMatrix(features))[0])

# Score all pools
scored_df = pools_df.with_column("PREDICTED_CPR",
    predict_cpr(col("INCENTIVE"), col("BURNOUT"), col("SEASONING"),
                col("AVG_FICO"), col("AVG_LTV"), col("WALA")))
scored_df.write.mode("overwrite").save_as_table("ANALYTICS.CPR_PREDICTIONS")
```

**Result:** Pipeline execution dropped from 6 hours to 38 minutes. Zero data egress eliminated \$1,800/month in cloud transfer costs. Model accuracy improved 4% because we could now include 12 additional features that were previously too expensive to export. The trading desk received CPR forecasts by 6:15 AM instead of noon, enabling pre-market positioning.

**AI Vision:** Migrate from the registered UDF approach to **Snowflake ML Model Registry** for full model versioning and A/B testing. Use **Snowpark ML** `modeling.XGBRegressor` to train directly inside Snowflake warehouses, and add **Cortex COMPLETE** to generate natural-language explanations of why specific pools show elevated prepay risk — feeding those narratives directly into trader morning reports.

---

### Q42. Describe your implementation of Iceberg Tables for creating an open data lakehouse for mortgage analytics.

**Situation:** A large mortgage aggregator maintained loan-level data across three systems: Snowflake for analytics, Spark on EMR for data science, and Trino for ad-hoc queries by the capital markets desk. Each system had its own copy of the 2.8 billion row loan performance dataset sourced from Fannie Mae and Freddie Mac CRT disclosures. Storage redundancy cost \$45K/month, and data freshness varied by up to 48 hours across platforms.

**Task:** Consolidate onto a single open-format storage layer using Apache Iceberg managed by Snowflake, while preserving read access for Spark and Trino without any data duplication.

**Action:** I created Snowflake-managed Iceberg Tables backed by an external S3 volume, partitioned by `vintage_year` and `reporting_month`. I configured the Iceberg catalog integration so Spark and Trino could read the same Parquet/Iceberg metadata directly. I then migrated the existing Snowflake native tables using CTAS with careful data type mapping to preserve NUMERIC(18,6) precision critical for UPB calculations.

```sql
-- Create external volume for Iceberg storage
CREATE OR REPLACE EXTERNAL VOLUME mortgage_iceberg_vol
  STORAGE_LOCATIONS = (
    (NAME = 'primary' STORAGE_BASE_URL = 's3://mortgage-lakehouse/iceberg/'
     STORAGE_PROVIDER = 'S3'
     STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::012345678901:role/iceberg-access')
  );

-- Create Iceberg catalog integration for external engines
CREATE OR REPLACE CATALOG INTEGRATION iceberg_catalog
  CATALOG_SOURCE = OBJECT_STORE
  TABLE_FORMAT = ICEBERG
  ENABLED = TRUE;

-- Create Iceberg table with mortgage-optimized partitioning
CREATE OR REPLACE ICEBERG TABLE LAKEHOUSE.LOAN_PERFORMANCE (
    LOAN_ID             VARCHAR(20),
    VINTAGE_YEAR        INT,
    REPORTING_MONTH     DATE,
    CURRENT_UPB         NUMBER(18,6),
    DELINQUENCY_STATUS  VARCHAR(3),
    MODIFICATION_FLAG   BOOLEAN,
    FICO_ORIGINATION    INT,
    LTV_ORIGINATION     NUMBER(6,2),
    DTI                 NUMBER(6,2),
    PROPERTY_STATE      VARCHAR(2),
    OCCUPANCY_TYPE      VARCHAR(1),
    SERVICER_NAME       VARCHAR(100)
)
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'mortgage_iceberg_vol'
  BASE_LOCATION = 'loan_performance/'
  CATALOG_SYNC = 'iceberg_catalog';

-- Migrate data with partition pruning validation
INSERT INTO LAKEHOUSE.LOAN_PERFORMANCE
SELECT * FROM RAW.FANNIE_LOAN_PERFORMANCE
WHERE REPORTING_MONTH >= '2015-01-01';

-- Verify Iceberg metadata is accessible
SELECT * FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_METADATA(
    TABLE_NAME => 'LOAN_PERFORMANCE'));
```

**Result:** Eliminated \$45K/month in redundant storage. All three engines (Snowflake, Spark, Trino) now read from a single Iceberg dataset with sub-second metadata sync via catalog integration. Data freshness gap collapsed from 48 hours to zero — Spark jobs immediately see Snowflake-written data. Query performance on the Snowflake side remained within 8% of native tables thanks to Iceberg's Parquet column pruning and predicate pushdown.

**AI Vision:** Layer **Snowpark ML** pipelines on top of Iceberg Tables to train credit default models that Spark users can also invoke. Use **Cortex COMPLETE** to auto-generate data quality summaries after each monthly load, and implement **Snowflake Dynamic Tables** on Iceberg sources to create self-maintaining aggregation layers that both Snowflake dashboards and Trino queries consume.

---

### Q43. How would you use Snowflake Cortex AI functions (COMPLETE, SUMMARIZE, SENTIMENT) to enrich loan servicer data?

**Situation:** Our servicing oversight team monitored 18 mortgage servicers managing \$380B in UPB across Fannie Mae and Freddie Mac portfolios. Servicer performance reviews relied on manually reading hundreds of pages of monthly narrative reports, complaint transcripts, and CFPB filings. Analysts spent 3 weeks per quarter synthesizing this information into scorecards, consistently missing the reporting deadline.

**Task:** Automate the extraction of actionable intelligence from unstructured servicer documents using Snowflake Cortex AI functions, reducing the quarterly review cycle from 3 weeks to 3 days.

**Action:** I built a three-layer enrichment pipeline. First, I loaded all servicer narratives and complaint text into a `SERVICER_DOCUMENTS` table with a VARCHAR column for raw text. Then I applied Cortex functions: `SENTIMENT` on borrower complaint transcripts to flag servicers with deteriorating sentiment trends, `SUMMARIZE` on monthly performance narratives to produce 3-sentence executive summaries, and `COMPLETE` with a mortgage-domain prompt to extract structured risk indicators (loss mitigation delays, escrow mismanagement flags, forbearance backlogs).

```sql
-- Sentiment analysis on borrower complaints per servicer
CREATE OR REPLACE TABLE ANALYTICS.SERVICER_COMPLAINT_SENTIMENT AS
SELECT
    SERVICER_ID,
    SERVICER_NAME,
    COMPLAINT_DATE,
    COMPLAINT_TEXT,
    SNOWFLAKE.CORTEX.SENTIMENT(COMPLAINT_TEXT) AS SENTIMENT_SCORE,
    CASE
        WHEN SNOWFLAKE.CORTEX.SENTIMENT(COMPLAINT_TEXT) < -0.5 THEN 'CRITICAL'
        WHEN SNOWFLAKE.CORTEX.SENTIMENT(COMPLAINT_TEXT) < -0.2 THEN 'NEGATIVE'
        WHEN SNOWFLAKE.CORTEX.SENTIMENT(COMPLAINT_TEXT) <  0.2 THEN 'NEUTRAL'
        ELSE 'POSITIVE'
    END AS SENTIMENT_CATEGORY
FROM RAW.SERVICER_COMPLAINTS
WHERE COMPLAINT_DATE >= DATEADD(QUARTER, -1, CURRENT_DATE());

-- Summarize lengthy servicer performance narratives
CREATE OR REPLACE TABLE ANALYTICS.SERVICER_NARRATIVE_SUMMARIES AS
SELECT
    SERVICER_ID,
    REPORT_MONTH,
    SNOWFLAKE.CORTEX.SUMMARIZE(NARRATIVE_TEXT) AS EXECUTIVE_SUMMARY
FROM RAW.SERVICER_MONTHLY_NARRATIVES
WHERE REPORT_MONTH >= '2025-10-01';

-- Extract structured risk signals using LLM with domain prompt
CREATE OR REPLACE TABLE ANALYTICS.SERVICER_RISK_SIGNALS AS
SELECT
    SERVICER_ID,
    REPORT_MONTH,
    SNOWFLAKE.CORTEX.COMPLETE('mistral-large2',
        'You are a mortgage servicing risk analyst. From the following servicer report, '
        || 'extract JSON with keys: loss_mit_delay_flag (boolean), escrow_issue_flag (boolean), '
        || 'forbearance_backlog_pct (number), key_risk (one sentence). '
        || 'Report text: ' || NARRATIVE_TEXT
    ) AS RISK_SIGNALS_JSON,
    PARSE_JSON(SNOWFLAKE.CORTEX.COMPLETE('mistral-large2',
        'Extract JSON: ' || NARRATIVE_TEXT)):loss_mit_delay_flag::BOOLEAN AS LOSS_MIT_DELAY,
    PARSE_JSON(SNOWFLAKE.CORTEX.COMPLETE('mistral-large2',
        'Extract JSON: ' || NARRATIVE_TEXT)):forbearance_backlog_pct::NUMBER(5,2) AS FORBEARANCE_BACKLOG
FROM RAW.SERVICER_MONTHLY_NARRATIVES;

-- Aggregate servicer scorecard
SELECT
    s.SERVICER_NAME,
    AVG(c.SENTIMENT_SCORE) AS AVG_COMPLAINT_SENTIMENT,
    COUNT_IF(c.SENTIMENT_CATEGORY = 'CRITICAL') AS CRITICAL_COMPLAINTS,
    ANY_VALUE(n.EXECUTIVE_SUMMARY) AS LATEST_SUMMARY,
    ANY_VALUE(r.LOSS_MIT_DELAY) AS LOSS_MIT_DELAY_FLAG
FROM DIM.SERVICERS s
JOIN ANALYTICS.SERVICER_COMPLAINT_SENTIMENT c USING (SERVICER_ID)
JOIN ANALYTICS.SERVICER_NARRATIVE_SUMMARIES n USING (SERVICER_ID)
JOIN ANALYTICS.SERVICER_RISK_SIGNALS r USING (SERVICER_ID)
GROUP BY s.SERVICER_NAME
ORDER BY AVG_COMPLAINT_SENTIMENT ASC;
```

**Result:** Quarterly servicer review cycle dropped from 3 weeks to 2.5 days. The Cortex-powered pipeline processed 4,200 documents per quarter, correctly flagging 2 servicers with loss mitigation delays that manual review had missed. Sentiment trending identified one servicer whose complaint scores degraded 40% quarter-over-quarter — leading to a proactive watchlist addition 6 weeks before a formal CFPB action was announced.

**AI Vision:** Implement **Cortex Search** to build a semantic retrieval layer over the full historical corpus of servicer documents, enabling analysts to ask natural-language questions like "Which servicers had escrow issues in the Southeast in Q3?" Deploy **Cortex Fine-Tuning** on a domain-specific model trained on GSE servicing guides to improve extraction accuracy for mortgage-specific terminology. Integrate **Streamlit in Snowflake** for an interactive servicer risk dashboard with conversational AI drill-down.

---

### Q44. Explain your approach to building a dbt-based transformation framework for a mortgage data warehouse in Snowflake.

**Situation:** A mid-size mortgage REIT had 380+ stored procedures in Snowflake implementing loan-level transformations — from raw Fannie/Freddie loan tape ingestion through to investor reporting aggregations. There was no lineage tracking, no testing, and a single developer's departure caused a 2-week outage because nobody understood the dependency chain among procedures.

**Task:** Replace the procedural spaghetti with a dbt (data build tool) transformation framework providing full lineage, automated testing, incremental processing, and documentation — while maintaining the existing reporting layer's contract.

**Action:** I structured the dbt project into four layers: `staging` (1:1 source mappings with light cleansing), `intermediate` (business logic joins like loan-to-borrower-to-property), `marts` (investor-facing aggregations), and `reporting` (final views matching existing report signatures). I implemented incremental models for the massive loan performance table, configured dbt tests for mortgage-specific data quality rules, and used dbt exposures to document downstream Tableau dashboards.

```yaml
# dbt_project.yml
name: mortgage_data_warehouse
version: '2.0.0'
profile: snowflake_prod

models:
  mortgage_data_warehouse:
    staging:
      +materialized: view
      +schema: staging
    intermediate:
      +materialized: incremental
      +schema: intermediate
      +incremental_strategy: merge
      +unique_key: loan_id || '-' || reporting_month
    marts:
      +materialized: table
      +schema: marts
      +post-hook: "GRANT SELECT ON {{ this }} TO ROLE ANALYST_ROLE"
    reporting:
      +materialized: view
      +schema: reporting
```

```sql
-- models/intermediate/int_loan_performance.sql
{{
  config(
    materialized='incremental',
    unique_key='loan_id || reporting_month',
    cluster_by=['vintage_year', 'reporting_month'],
    snowflake_warehouse='TRANSFORM_WH_LARGE'
  )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_fannie_loan_performance') }}
    {% if is_incremental() %}
    WHERE reporting_month > (SELECT MAX(reporting_month) FROM {{ this }})
    {% endif %}
),

enriched AS (
    SELECT
        s.*,
        d.delinquency_bucket,
        p.msa_name,
        p.state_name,
        -- Calculate months-to-liquidation for defaulted loans
        DATEDIFF(MONTH, s.default_date, s.liquidation_date) AS months_to_liquidation,
        -- Net loss severity
        COALESCE(s.net_loss_amount / NULLIF(s.original_upb, 0), 0) AS loss_severity
    FROM source s
    LEFT JOIN {{ ref('stg_delinquency_mapping') }} d
        ON s.delinquency_status = d.raw_status
    LEFT JOIN {{ ref('stg_property_geo') }} p
        ON s.property_zip = p.zip_code
)

SELECT * FROM enriched
```

```yaml
# models/intermediate/int_loan_performance.yml
models:
  - name: int_loan_performance
    description: "Enriched loan-level performance with geography and delinquency mapping"
    columns:
      - name: loan_id
        tests:
          - not_null
      - name: current_upb
        tests:
          - not_null
          - dbt_utils.accepted_range:
              min_value: 0
              max_value: 5000000
      - name: loss_severity
        tests:
          - dbt_utils.accepted_range:
              min_value: 0
              max_value: 1.5
    tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns: ['loan_id', 'reporting_month']
```

**Result:** Full `dbt run` for incremental monthly loads completed in 22 minutes (vs. 3.5 hours with the old stored procedure chain). dbt's DAG visualization gave every analyst instant lineage from raw source to report column. Automated testing caught 14 data quality issues in the first month that had silently corrupted reports for months. Developer onboarding time dropped from 4 weeks to 4 days because `dbt docs serve` provided a fully searchable data dictionary.

**AI Vision:** Integrate **dbt Semantic Layer** with **Snowflake Cortex Search** so business users can ask "What was the average loss severity for 2023 vintage Florida loans?" in natural language and get correct SQL generated against dbt metrics. Use **Snowpark Python models in dbt** to embed ML scoring (e.g., probability of default) directly in the transformation DAG. Add **dbt exposures** pointing to Cortex-powered Streamlit apps.

---

### Q45. How did you implement Snowflake ML FORECAST for predicting monthly pool balance trends on MBS portfolios?

**Situation:** The portfolio management team at an MBS fund needed 12-month forward projections of remaining pool balances for 8,500 Freddie Mac PC pools to plan reinvestment strategies. The existing approach was a spreadsheet-based PSA curve assumption applied uniformly, which consistently overestimated balances by 8-15% because it ignored pool-specific characteristics like FICO distribution, geographic concentration, and rate incentive.

**Task:** Implement Snowflake's native ML FORECAST function to generate pool-level balance projections that capture individual pool behavior patterns, outperforming the blanket PSA assumption by at least 50% in MAPE reduction.

**Action:** I prepared a time-series training dataset with 60 months of historical monthly factor data per pool, enriched with macro features (10Y Treasury yield, HPI index, unemployment rate). I trained a FORECAST model per pool cohort (grouped by coupon band and vintage year — roughly 85 cohorts) rather than per individual pool, giving each model sufficient training volume. I then generated 12-month forward forecasts and compared against the PSA baseline.

```sql
-- Prepare time series with macro features joined
CREATE OR REPLACE VIEW ML.POOL_BALANCE_TIMESERIES AS
SELECT
    p.POOL_NUMBER,
    p.COUPON_BAND || '_' || p.VINTAGE_YEAR AS COHORT_ID,
    f.REPORTING_DATE AS DS,
    f.REMAINING_BALANCE AS Y,
    m.TREASURY_10Y,
    m.NATIONAL_HPI,
    m.UNEMPLOYMENT_RATE
FROM DIM.FREDDIE_POOLS p
JOIN FACT.MONTHLY_FACTORS f ON p.POOL_NUMBER = f.POOL_NUMBER
JOIN DIM.MACRO_INDICATORS m ON f.REPORTING_DATE = m.AS_OF_DATE
WHERE f.REPORTING_DATE >= DATEADD(YEAR, -5, CURRENT_DATE());

-- Train forecast model per cohort (example for one cohort)
CREATE OR REPLACE SNOWFLAKE.ML.FORECAST pool_balance_model(
    INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'ML.POOL_BALANCE_TIMESERIES'),
    SERIES_COLNAME => 'POOL_NUMBER',
    TIMESTAMP_COLNAME => 'DS',
    TARGET_COLNAME => 'Y',
    CONFIG_OBJECT => {
        'ON_ERROR': 'SKIP'
    }
);

-- Generate 12-month forward forecast
CALL pool_balance_model!FORECAST(
    FORECASTING_PERIODS => 12,
    CONFIG_OBJECT => {'prediction_interval': 0.95}
);

-- Store predictions and compute accuracy vs PSA baseline
CREATE OR REPLACE TABLE ANALYTICS.BALANCE_PROJECTIONS AS
SELECT
    series AS POOL_NUMBER,
    ts AS FORECAST_DATE,
    forecast AS ML_PROJECTED_BALANCE,
    lower_bound AS ML_LOWER_95,
    upper_bound AS ML_UPPER_95
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Compare ML forecast vs PSA assumption on holdout period
SELECT
    ROUND(AVG(ABS(a.ACTUAL_BALANCE - a.PSA_PROJECTED) /
        NULLIF(a.ACTUAL_BALANCE, 0)) * 100, 2) AS PSA_MAPE,
    ROUND(AVG(ABS(a.ACTUAL_BALANCE - p.ML_PROJECTED_BALANCE) /
        NULLIF(a.ACTUAL_BALANCE, 0)) * 100, 2) AS ML_MAPE
FROM ANALYTICS.HOLDOUT_ACTUALS a
JOIN ANALYTICS.BALANCE_PROJECTIONS p
    ON a.POOL_NUMBER = p.POOL_NUMBER
    AND a.REPORTING_DATE = p.FORECAST_DATE;
-- Result: PSA_MAPE = 12.3%, ML_MAPE = 3.8%
```

**Result:** ML FORECAST reduced balance projection MAPE from 12.3% to 3.8% — a 69% improvement over the PSA baseline. The 95% prediction intervals provided the risk team with a range for stress testing. Portfolio managers used the tighter projections to optimize \$2.1B in reinvestment timing, capturing an estimated 8 bps of incremental yield. The entire monthly forecast refresh runs in 14 minutes on a MEDIUM warehouse.

**AI Vision:** Evolve to **Snowflake ML ANOMALY_DETECTION** to automatically flag pools whose actual paydowns deviate significantly from forecast — an early warning for servicer issues or prepayment wave onset. Feed forecast outputs into **Cortex COMPLETE** to generate natural-language portfolio commentary: "Cohort 3.5_2021 is projected to pay down 18% faster than baseline due to elevated refinance incentive." Combine with **Snowpark ML** to train ensemble models that blend the time-series forecast with a gradient-boosted credit model.

---

### Q46. Describe your CI/CD pipeline for Snowflake using Schemachange/Terraform for a mortgage analytics platform.

**Situation:** A mortgage analytics firm had 6 developers deploying Snowflake changes manually — running DDL scripts from their laptops via SnowSQL. This led to a production outage when a developer accidentally dropped a table with 4 years of CoreLogic property valuation data (recoverable only because Time Travel was still within the 90-day window). There was no version control, no environment promotion path, and no audit trail.

**Task:** Implement a full CI/CD pipeline with infrastructure-as-code for Snowflake, providing automated testing in dev/staging, peer-reviewed deployments to production, and complete auditability — all while supporting the team's weekly release cadence.

**Action:** I implemented a two-layer approach: Terraform for infrastructure (warehouses, databases, roles, integrations) and Schemachange for database object migrations (tables, views, stored procedures). GitHub Actions orchestrated the pipeline with branch-based environment targeting. I added a pre-deployment validation stage that ran schemachange in dry-run mode against a cloned environment.

```yaml
# .github/workflows/snowflake-deploy.yml
name: Snowflake CI/CD Pipeline
on:
  push:
    branches: [develop, staging, main]
  pull_request:
    branches: [main]

jobs:
  validate:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    steps:
      - uses: actions/checkout@v4

      - name: Clone prod to validation environment
        run: |
          snow sql -q "CREATE DATABASE IF NOT EXISTS MORTGAGE_DW_VALIDATION
                       CLONE MORTGAGE_DW_PROD;"

      - name: Dry-run Schemachange against clone
        run: |
          schemachange deploy \
            --config-folder . \
            --root-folder migrations/ \
            --snowflake-account ${{ secrets.SF_ACCOUNT }} \
            --snowflake-database MORTGAGE_DW_VALIDATION \
            --dry-run

      - name: Run dbt tests on clone
        run: |
          dbt test --target validation --profiles-dir .

  deploy-staging:
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/staging'
    steps:
      - uses: actions/checkout@v4
      - name: Terraform Apply - Staging Infra
        run: |
          cd terraform/
          terraform init
          terraform workspace select staging
          terraform apply -auto-approve

      - name: Schemachange Deploy - Staging
        run: |
          schemachange deploy \
            --config-folder . \
            --root-folder migrations/ \
            --snowflake-database MORTGAGE_DW_STAGING \
            --change-history-table METADATA.SCHEMACHANGE.CHANGE_HISTORY

  deploy-prod:
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    environment: production  # Requires manual approval
    steps:
      - uses: actions/checkout@v4
      - name: Terraform Apply - Prod
        run: |
          cd terraform/
          terraform workspace select production
          terraform apply -auto-approve

      - name: Schemachange Deploy - Prod
        run: |
          schemachange deploy \
            --root-folder migrations/ \
            --snowflake-database MORTGAGE_DW_PROD \
            --change-history-table METADATA.SCHEMACHANGE.CHANGE_HISTORY
```

```hcl
# terraform/warehouses.tf
resource "snowflake_warehouse" "transform_wh" {
  name                = "TRANSFORM_WH_${upper(var.environment)}"
  warehouse_size      = var.environment == "production" ? "XLARGE" : "MEDIUM"
  auto_suspend        = 120
  auto_resume         = true
  min_cluster_count   = 1
  max_cluster_count   = var.environment == "production" ? 4 : 1
  scaling_policy      = "ECONOMY"
  resource_monitor    = snowflake_resource_monitor.transform_monitor.name
}

resource "snowflake_database" "mortgage_dw" {
  name                        = "MORTGAGE_DW_${upper(var.environment)}"
  data_retention_time_in_days = var.environment == "production" ? 90 : 1
}
```

**Result:** Zero unplanned production incidents in the 14 months since implementation. Average deployment time dropped from 2 hours (manual) to 8 minutes (automated). Every schema change is peer-reviewed via PR, and the `CHANGE_HISTORY` table provides a complete audit trail satisfying SOC 2 requirements. The cloned validation environment catches an average of 3 breaking changes per month before they reach staging.

**AI Vision:** Add **Snowflake Cortex COMPLETE** to the PR review step — automatically generate a plain-English summary of what each migration will change and its potential impact on downstream objects. Integrate **Snowflake's QUERY_HISTORY** with an ML anomaly detector to automatically roll back deployments that cause query performance regressions exceeding 2 standard deviations. Use **Terraform + Snowpark** to auto-provision ML model endpoints as part of the infrastructure pipeline.

---

### Q47. How would you design a real-time loan pricing engine using Snowflake Streams, Tasks, and External Functions?

**Situation:** A wholesale mortgage lender processed 3,000+ lock requests daily. Loan officers submitted rate lock requests that required real-time pricing based on current MBS market prices (from a Bloomberg feed), loan-level risk adjustments (LLPA matrices from Fannie/Freddie), and the lender's margin grid. The existing process queried a SQL Server OLTP system and returned prices in 15-30 seconds — too slow for the competitive wholesale market where 2-second response was the norm.

**Task:** Design a near-real-time pricing engine in Snowflake that returns a rate sheet price within 3 seconds of a lock request, incorporating live MBS TBA prices, LLPA adjustments, and margin calculations.

**Action:** I designed a three-component architecture. First, Snowpipe Streaming ingested Bloomberg TBA prices and lock requests into append-only tables. Second, a Stream on the lock request table detected new rows, and a serverless Task triggered within seconds to compute the price. Third, an External Function called the lender's existing margin API for final mark-up, and the result was written to a response table consumed by the lock desk UI.

```sql
-- Streaming ingestion for TBA market prices (updated every 5 seconds)
CREATE OR REPLACE TABLE MKT.TBA_PRICES (
    COUPON          NUMBER(4,2),
    SETTLE_MONTH    VARCHAR(7),
    BID_PRICE       NUMBER(8,5),
    ASK_PRICE       NUMBER(8,5),
    UPDATED_AT      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Lock request landing table with stream
CREATE OR REPLACE TABLE OPS.LOCK_REQUESTS (
    REQUEST_ID      VARCHAR(36) DEFAULT UUID_STRING(),
    LOAN_AMOUNT     NUMBER(12,2),
    NOTE_RATE       NUMBER(5,3),
    LOCK_DAYS       INT,
    FICO            INT,
    LTV             NUMBER(5,2),
    PROPERTY_TYPE   VARCHAR(20),
    OCCUPANCY       VARCHAR(10),
    STATE           VARCHAR(2),
    SUBMITTED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE STREAM OPS.LOCK_REQUEST_STREAM ON TABLE OPS.LOCK_REQUESTS
    APPEND_ONLY = TRUE;

-- External function for lender margin lookup
CREATE OR REPLACE EXTERNAL FUNCTION OPS.GET_LENDER_MARGIN(
    lock_days INT, channel VARCHAR, loan_amount NUMBER)
RETURNS VARIANT
API_INTEGRATION = pricing_api_integration
AS 'https://pricing-api.lender.com/v2/margin';

-- Serverless task triggered by new lock requests
CREATE OR REPLACE TASK OPS.PRICE_LOCK_REQUESTS
    WAREHOUSE = PRICING_WH_SERVERLESS
    SCHEDULE = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('OPS.LOCK_REQUEST_STREAM')
AS
INSERT INTO OPS.LOCK_RESPONSES (REQUEST_ID, BASE_PRICE, LLPA_ADJ, MARGIN, FINAL_PRICE, PRICED_AT)
SELECT
    lr.REQUEST_ID,
    -- Base price from TBA market
    tba.BID_PRICE AS BASE_PRICE,
    -- LLPA adjustments (Fannie Mae grid lookup)
    COALESCE(llpa_fico.ADJUSTMENT, 0)
      + COALESCE(llpa_ltv.ADJUSTMENT, 0)
      + COALESCE(llpa_prop.ADJUSTMENT, 0) AS LLPA_ADJ,
    -- Lender margin via external function
    OPS.GET_LENDER_MARGIN(lr.LOCK_DAYS, 'WHOLESALE', lr.LOAN_AMOUNT):margin::NUMBER(6,4) AS MARGIN,
    -- Final price
    tba.BID_PRICE + COALESCE(llpa_fico.ADJUSTMENT, 0) + COALESCE(llpa_ltv.ADJUSTMENT, 0)
      + COALESCE(llpa_prop.ADJUSTMENT, 0)
      - OPS.GET_LENDER_MARGIN(lr.LOCK_DAYS, 'WHOLESALE', lr.LOAN_AMOUNT):margin::NUMBER(6,4)
      AS FINAL_PRICE,
    CURRENT_TIMESTAMP() AS PRICED_AT
FROM OPS.LOCK_REQUEST_STREAM lr
-- Get current TBA price for matching coupon
JOIN MKT.TBA_PRICES tba
    ON tba.COUPON = ROUND(lr.NOTE_RATE * 2, 0) / 2  -- Round to nearest 0.5 coupon
    AND tba.SETTLE_MONTH = TO_CHAR(CURRENT_DATE(), 'YYYY-MM')
    AND tba.UPDATED_AT = (SELECT MAX(UPDATED_AT) FROM MKT.TBA_PRICES WHERE COUPON = tba.COUPON)
-- LLPA lookups
LEFT JOIN REF.LLPA_FICO_GRID llpa_fico
    ON lr.FICO BETWEEN llpa_fico.FICO_LOW AND llpa_fico.FICO_HIGH
    AND lr.LTV BETWEEN llpa_fico.LTV_LOW AND llpa_fico.LTV_HIGH
LEFT JOIN REF.LLPA_LTV_GRID llpa_ltv ON lr.LTV BETWEEN llpa_ltv.LTV_LOW AND llpa_ltv.LTV_HIGH
LEFT JOIN REF.LLPA_PROPERTY_GRID llpa_prop ON lr.PROPERTY_TYPE = llpa_prop.PROPERTY_TYPE;

ALTER TASK OPS.PRICE_LOCK_REQUESTS RESUME;
```

**Result:** Lock pricing latency dropped from 15-30 seconds to an average of 2.1 seconds (measured from `SUBMITTED_AT` to `PRICED_AT`). The system handled peak volume of 450 locks/hour without degradation using a serverless warehouse. The lender's pull-through rate improved 12% because loan officers could quote competitive prices immediately instead of waiting. Monthly pricing compute cost was \$380 on the serverless model — 70% less than the always-on SQL Server instance it replaced.

**AI Vision:** Add a **Snowpark ML** model as an inline UDF that predicts lock fallout probability at the moment of pricing — enabling dynamic margin adjustment for locks likely to fall through. Use **Cortex COMPLETE** to generate automated pricing exception narratives when a lock price deviates more than 25 bps from the rate sheet. Implement **Snowflake Cortex Search** over historical pricing data so traders can ask "What was our average margin on 7.0 coupon jumbo locks in Texas last month?"

---

### Q48. Explain your strategy for migrating a SQL Server-based mortgage data warehouse to Snowflake with zero data loss.

**Situation:** A government-sponsored enterprise (GSE) oversight division maintained a 14TB mortgage data warehouse on SQL Server 2016 Enterprise — 280 tables, 600+ stored procedures, 45 SSIS packages, and 12 years of historical loan performance data from Fannie Mae, Freddie Mac, and Ginnie Mae. The SQL Server infrastructure required \$1.2M/year in licensing and hardware, with a 3-person DBA team spending 60% of their time on maintenance rather than analytics.

**Task:** Migrate the entire data warehouse to Snowflake with zero data loss, zero business downtime, and full functional parity — within a 6-month timeline and while the source system continued to serve daily production workloads.

**Action:** I executed a five-phase migration methodology: (1) Assessment and schema conversion, (2) Historical data migration, (3) Stored procedure and ETL conversion, (4) Parallel run with reconciliation, and (5) Cutover. I used a custom reconciliation framework that validated row counts, checksum aggregates, and business-metric equivalence across both systems simultaneously.

```sql
-- Phase 1: Automated schema conversion with data type mapping
-- SQL Server -> Snowflake type mapping (handled via migration script)
-- DATETIME2    -> TIMESTAMP_NTZ
-- DECIMAL(p,s) -> NUMBER(p,s)
-- NVARCHAR(n)  -> VARCHAR(n)
-- BIT          -> BOOLEAN
-- UNIQUEID     -> VARCHAR(36)

-- Phase 2: Historical data load via Azure Blob staging
CREATE OR REPLACE STAGE MIGRATION.AZURE_STAGE
    URL = 'azure://mortgagemigration.blob.core.windows.net/export/'
    CREDENTIALS = (AZURE_SAS_TOKEN = '...')
    FILE_FORMAT = (TYPE = PARQUET);

-- Bulk load each table (example: 2.8B row loan performance)
COPY INTO RAW.LOAN_PERFORMANCE
FROM @MIGRATION.AZURE_STAGE/loan_performance/
    FILE_FORMAT = (TYPE = PARQUET)
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = ABORT_STATEMENT;

-- Phase 4: Reconciliation framework
CREATE OR REPLACE PROCEDURE MIGRATION.RECONCILE_TABLE(
    TABLE_NAME VARCHAR, KEY_COLUMNS VARCHAR, MEASURE_COLUMNS VARCHAR)
RETURNS TABLE(CHECK_NAME VARCHAR, SQL_SERVER_VAL VARCHAR, SNOWFLAKE_VAL VARCHAR, MATCH BOOLEAN)
LANGUAGE SQL AS
$$
DECLARE
    result RESULTSET;
BEGIN
    -- Row count check
    result := (
        SELECT
            'ROW_COUNT' AS CHECK_NAME,
            ss.CNT::VARCHAR AS SQL_SERVER_VAL,
            sf.CNT::VARCHAR AS SNOWFLAKE_VAL,
            ss.CNT = sf.CNT AS MATCH
        FROM MIGRATION.SQLSERVER_COUNTS ss
        JOIN (SELECT COUNT(*) AS CNT FROM IDENTIFIER(:TABLE_NAME)) sf
        ON TRUE
        WHERE ss.TABLE_NAME = :TABLE_NAME
        UNION ALL
        -- Aggregate measure checks
        SELECT
            'SUM_UPB' AS CHECK_NAME,
            ss.TOTAL_UPB::VARCHAR,
            sf.TOTAL_UPB::VARCHAR,
            ABS(ss.TOTAL_UPB - sf.TOTAL_UPB) < 0.01 AS MATCH
        FROM MIGRATION.SQLSERVER_AGGREGATES ss
        JOIN (SELECT SUM(CURRENT_UPB) AS TOTAL_UPB FROM IDENTIFIER(:TABLE_NAME)) sf
        ON TRUE
        WHERE ss.TABLE_NAME = :TABLE_NAME
    );
    RETURN TABLE(result);
END;
$$;

-- Run reconciliation across all migrated tables
CALL MIGRATION.RECONCILE_TABLE('RAW.LOAN_PERFORMANCE', 'LOAN_ID,REPORTING_MONTH', 'CURRENT_UPB');

-- Phase 3: Convert SSIS to Snowflake Tasks + Streams
-- Example: Daily CDC from operational system (replaces SSIS incremental package)
CREATE OR REPLACE STREAM RAW.LOAN_MASTER_CDC ON TABLE RAW.LOAN_MASTER;

CREATE OR REPLACE TASK ETL.PROCESS_LOAN_MASTER_CDC
    WAREHOUSE = ETL_WH
    SCHEDULE = 'USING CRON 0 6 * * * America/New_York'
    WHEN SYSTEM$STREAM_HAS_DATA('RAW.LOAN_MASTER_CDC')
AS
MERGE INTO DW.DIM_LOAN tgt
USING RAW.LOAN_MASTER_CDC src ON tgt.LOAN_ID = src.LOAN_ID
WHEN MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
    UPDATE SET tgt.CURRENT_UPB = src.CURRENT_UPB,
              tgt.DELINQUENCY_STATUS = src.DELINQUENCY_STATUS,
              tgt.UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
    INSERT (LOAN_ID, CURRENT_UPB, DELINQUENCY_STATUS, CREATED_AT)
    VALUES (src.LOAN_ID, src.CURRENT_UPB, src.DELINQUENCY_STATUS, CURRENT_TIMESTAMP());
```

**Result:** All 280 tables migrated with 100% reconciliation pass — zero row discrepancies, aggregate UPB differences under \$0.01 (floating-point rounding). The parallel run phase lasted 4 weeks with daily automated reconciliation reports. Cutover completed in a single weekend with 2 hours of planned downtime (DNS switch). Annual infrastructure cost dropped from \$1.2M to \$340K. Query performance improved 3-8x on average due to columnar storage and automatic micro-partition pruning. The 3 DBAs were retrained as data engineers focused on analytics.

**AI Vision:** Use **Cortex COMPLETE** to auto-convert the remaining complex stored procedures by feeding SQL Server T-SQL into an LLM with Snowflake SQL dialect instructions — reducing manual conversion effort by 60%. Implement **Snowflake Cortex Search** over the migrated historical data to enable natural-language querying for business users who previously relied on stored procedure reports. Deploy **Snowpark ML** pipelines that were impossible on SQL Server, immediately adding predictive analytics capabilities.

---

### Q49. How did you use Zero-Copy Cloning for building isolated testing environments for loan data pipeline development?

**Situation:** Our data engineering team of 8 developers at a mortgage servicer needed isolated environments to develop and test pipeline changes against realistic data — the production database contained 6TB of sensitive loan-level data across 180 tables including borrower PII, FICO scores, and income documentation from CoreLogic and Fannie Mae datasets. Previously, creating a dev copy took 4 hours via CTAS statements and consumed \$12K/month in storage for 3 persistent dev environments that were perpetually stale.

**Task:** Implement on-demand, isolated development environments using zero-copy cloning that spin up in seconds, contain production-realistic data with PII masked, and auto-expire to prevent cost creep.

**Action:** I built an automated environment provisioning system using a stored procedure that clones the production database, applies dynamic data masking policies to the clone, configures appropriate RBAC, and sets a Time Travel retention of 1 day (vs. 90 days in prod) to minimize storage delta costs. A cleanup Task destroys clones older than 72 hours.

```sql
-- Master procedure to provision developer environment
CREATE OR REPLACE PROCEDURE DEVOPS.PROVISION_DEV_ENV(
    DEVELOPER_NAME VARCHAR,
    FEATURE_BRANCH VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    db_name VARCHAR;
    clone_ts TIMESTAMP_LTZ;
BEGIN
    db_name := 'DEV_' || UPPER(:DEVELOPER_NAME) || '_' || REPLACE(:FEATURE_BRANCH, '-', '_');
    clone_ts := CURRENT_TIMESTAMP();

    -- Zero-copy clone of production (instantaneous, zero additional storage)
    EXECUTE IMMEDIATE 'CREATE OR REPLACE DATABASE ' || :db_name ||
        ' CLONE MORTGAGE_DW_PROD';

    -- Reduce Time Travel to minimize storage delta
    EXECUTE IMMEDIATE 'ALTER DATABASE ' || :db_name ||
        ' SET DATA_RETENTION_TIME_IN_DAYS = 1';

    -- Apply PII masking policies to cloned environment
    EXECUTE IMMEDIATE 'ALTER TABLE ' || :db_name ||
        '.DW.DIM_BORROWER MODIFY COLUMN SSN SET MASKING POLICY SECURITY.SSN_MASK';
    EXECUTE IMMEDIATE 'ALTER TABLE ' || :db_name ||
        '.DW.DIM_BORROWER MODIFY COLUMN BORROWER_NAME SET MASKING POLICY SECURITY.NAME_MASK';
    EXECUTE IMMEDIATE 'ALTER TABLE ' || :db_name ||
        '.DW.DIM_BORROWER MODIFY COLUMN INCOME SET MASKING POLICY SECURITY.INCOME_MASK';

    -- Grant access only to the requesting developer
    EXECUTE IMMEDIATE 'GRANT USAGE ON DATABASE ' || :db_name ||
        ' TO ROLE DEV_' || UPPER(:DEVELOPER_NAME);
    EXECUTE IMMEDIATE 'GRANT ALL ON ALL SCHEMAS IN DATABASE ' || :db_name ||
        ' TO ROLE DEV_' || UPPER(:DEVELOPER_NAME);
    EXECUTE IMMEDIATE 'GRANT ALL ON ALL TABLES IN DATABASE ' || :db_name ||
        ' TO ROLE DEV_' || UPPER(:DEVELOPER_NAME);

    -- Tag for automated cleanup
    EXECUTE IMMEDIATE 'ALTER DATABASE ' || :db_name ||
        ' SET TAG DEVOPS.CLONE_METADATA = \'{"developer":"' || :DEVELOPER_NAME ||
        '","branch":"' || :FEATURE_BRANCH ||
        '","created":"' || :clone_ts::VARCHAR ||
        '","expires":"' || DATEADD(HOUR, 72, :clone_ts)::VARCHAR || '"}\'';

    RETURN 'Environment ' || :db_name || ' provisioned. Expires in 72 hours.';
END;
$$;

-- Developer self-service: provision environment for their feature branch
CALL DEVOPS.PROVISION_DEV_ENV('jsmith', 'feat-ginnie-dynamic-tables');
-- Returns: "Environment DEV_JSMITH_FEAT_GINNIE_DYNAMIC_TABLES provisioned. Expires in 72 hours."

-- Automated cleanup Task — runs every 6 hours
CREATE OR REPLACE TASK DEVOPS.CLEANUP_EXPIRED_CLONES
    WAREHOUSE = ADMIN_WH_XS
    SCHEDULE = 'USING CRON 0 */6 * * * America/New_York'
AS
DECLARE
    c CURSOR FOR
        SELECT DATABASE_NAME, SYSTEM$GET_TAG('DEVOPS.CLONE_METADATA', DATABASE_NAME, 'DATABASE') AS META
        FROM INFORMATION_SCHEMA.DATABASES
        WHERE DATABASE_NAME LIKE 'DEV_%';
BEGIN
    FOR rec IN c DO
        IF (PARSE_JSON(rec.META):expires::TIMESTAMP_LTZ < CURRENT_TIMESTAMP()) THEN
            EXECUTE IMMEDIATE 'DROP DATABASE IF EXISTS ' || rec.DATABASE_NAME;
        END IF;
    END FOR;
END;

-- Monitor clone storage overhead
SELECT
    DATABASE_NAME,
    ROUND(SUM(ACTIVE_BYTES) / POWER(1024, 3), 2) AS ACTIVE_GB,
    ROUND(SUM(FAILSAFE_BYTES) / POWER(1024, 3), 2) AS FAILSAFE_GB
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_CATALOG LIKE 'DEV_%'
GROUP BY DATABASE_NAME
ORDER BY ACTIVE_GB DESC;
```

**Result:** Environment provisioning dropped from 4 hours to 8 seconds. Storage cost for development environments dropped from \$12K/month to \$800/month (only delta changes incur storage). Each developer could spin up and tear down 3-5 environments per week for different feature branches. PII masking on clones ensured GLBA compliance without requiring separate synthetic data generation. The 72-hour auto-expiry eliminated orphaned environments that previously accumulated indefinitely.

**AI Vision:** Integrate with **GitHub Actions** to automatically provision a clone when a PR is opened and run dbt tests against it, posting results as PR comments. Use **Snowflake Cortex COMPLETE** to generate synthetic but realistic borrower PII (names, addresses) that replaces masked values for more realistic UI testing. Add **Snowpark Python** hooks that automatically profile the clone's data distribution and flag any drift from production patterns that might invalidate test results.

---

### Q50. Describe your vision for a next-generation AI-powered mortgage data platform built on Snowflake.

**Situation:** Looking across the US secondary mortgage market — an industry processing \$13 trillion in outstanding residential MBS — the data landscape remains fragmented. Loan originators, servicers, GSEs, rating agencies, and investors each maintain siloed systems. Critical decisions around pricing, risk assessment, and portfolio management still rely heavily on manual analysis of structured tapes supplemented by unstructured documents (appraisals, title reports, servicing comments). The industry loses an estimated \$4B annually to inefficiencies in data reconciliation, delayed risk detection, and suboptimal portfolio allocation.

**Task:** Architect a comprehensive, AI-native mortgage data platform on Snowflake that unifies structured and unstructured data, enables real-time intelligence, and delivers predictive capabilities across the entire secondary market lifecycle — from origination through securitization to servicing and liquidation.

**Action:** I designed a five-layer platform architecture, each leveraging Snowflake's latest capabilities.

```
LAYER 1: UNIFIED DATA FABRIC (Ingestion & Storage)
├── Snowpipe Streaming: Real-time loan events, market prices, servicer feeds
├── Iceberg Tables: Open format for cross-engine access (Snowflake + Spark + Trino)
├── External Tables: CoreLogic property data, Intex deal structures, Bloomberg pricing
├── Secure Data Sharing: Bi-directional with GSEs, rating agencies, servicers
└── Hybrid Tables: Sub-second OLTP for lock desk and trade capture

LAYER 2: TRANSFORMATION ENGINE (Processing)
├── dbt Core: Modular SQL transformations with full lineage and testing
├── Dynamic Tables: Self-maintaining aggregation layers for pool/deal/portfolio
├── Snowpark Python: Complex transformations (cashflow waterfalls, Intex models)
└── Streams + Tasks: Event-driven CDC processing for operational feeds

LAYER 3: AI/ML INTELLIGENCE (Analytics & Prediction)
├── Cortex COMPLETE: Document understanding (appraisals, title, servicing notes)
├── Cortex Search: Semantic search across all unstructured mortgage documents
├── Cortex SENTIMENT: Servicer complaint monitoring and early warning
├── ML FORECAST: Pool balance projections, delinquency trend prediction
├── ML ANOMALY_DETECTION: Fraud detection, servicer performance outliers
├── Snowpark ML Registry: Versioned models for CPR, CDR, severity, HPA
└── Cortex Fine-Tuning: Domain-specific LLM for mortgage terminology

LAYER 4: CONSUMPTION & EXPERIENCE (Delivery)
├── Streamlit in Snowflake: Interactive dashboards with AI chat interface
├── Snowflake Marketplace: Publish curated datasets for counterparties
├── Cortex Analyst: Natural-language SQL for business users
├── Native App Framework: Packageable analytics for servicer/investor distribution
└── Notebooks: Collaborative analysis for quants and data scientists

LAYER 5: GOVERNANCE & OPERATIONS (Trust)
├── Horizon: Unified data discovery, classification, lineage
├── Dynamic Data Masking: PII protection (GLBA, CCPA compliance)
├── Row Access Policies: Investor-level data segregation
├── Terraform + Schemachange CI/CD: Infrastructure and schema versioning
└── Trust Center: Continuous compliance monitoring
```

```sql
-- Example: Cortex Analyst semantic model for natural-language mortgage queries
-- File: semantic_models/mbs_portfolio.yaml
-- name: mbs_portfolio
-- tables:
--   - name: FACT_POOL_MONTHLY
--     base_table: MARTS.FACT_POOL_MONTHLY
--     dimensions:
--       - name: pool_number
--       - name: issuer_name
--       - name: coupon_band
--       - name: vintage_year
--     measures:
--       - name: remaining_balance
--         expr: SUM(CURRENT_UPB)
--       - name: avg_cpr
--         expr: AVG(SINGLE_MONTH_CPR)
--     time_dimensions:
--       - name: reporting_month
--         expr: REPORTING_DATE
-- Enables queries like: "What is the total remaining balance of 2023 vintage
-- Freddie Mac pools with CPR above 15?"

-- Cortex Search for unstructured document intelligence
CREATE OR REPLACE CORTEX SEARCH SERVICE MORTGAGE_DOC_SEARCH
    ON SEARCH_COLUMN
    WAREHOUSE = AI_WH
    TARGET_LAG = '1 hour'
AS (
    SELECT
        DOC_ID,
        DOC_TYPE,
        LOAN_ID,
        SERVICER_ID,
        DOC_TEXT AS SEARCH_COLUMN,
        DOC_DATE
    FROM UNIFIED.DOCUMENT_CORPUS
    WHERE DOC_TYPE IN ('APPRAISAL','TITLE','SERVICING_NOTE','MODIFICATION_LETTER')
);

-- AI-powered portfolio summary generation
CREATE OR REPLACE TASK AI.GENERATE_DAILY_PORTFOLIO_BRIEF
    WAREHOUSE = AI_WH
    SCHEDULE = 'USING CRON 0 7 * * 1-5 America/New_York'
AS
INSERT INTO ANALYTICS.PORTFOLIO_BRIEFS (BRIEF_DATE, BRIEF_TEXT)
SELECT
    CURRENT_DATE(),
    SNOWFLAKE.CORTEX.COMPLETE('mistral-large2',
        'You are a senior MBS portfolio analyst. Generate a concise morning brief based on: '
        || '1. Portfolio balance: ' || (SELECT TO_CHAR(SUM(CURRENT_UPB),'$999,999,999,999') FROM MARTS.PORTFOLIO_SUMMARY) || '. '
        || '2. Pools with CPR > 20: ' || (SELECT COUNT(*) FROM MARTS.POOL_METRICS WHERE SMM_CPR > 20)::VARCHAR || '. '
        || '3. New 60+ day delinquencies: ' || (SELECT COUNT(*) FROM MARTS.DQ_TRANSITIONS WHERE NEW_DQ_STATUS >= 2)::VARCHAR || '. '
        || '4. Top prepaying cohort: ' || (SELECT COHORT_ID FROM MARTS.COHORT_CPR ORDER BY AVG_CPR DESC LIMIT 1) || '. '
        || 'Include risk flags and recommended actions.'
    );
```

**Result:** This architecture consolidates what traditionally requires 8-12 separate systems into a single platform. Projected outcomes based on pilot implementations: data reconciliation effort reduced by 85%, risk detection latency from weeks to hours, portfolio analysts enabled with self-service AI queries replacing 70% of ad-hoc SQL requests, and an estimated \$15-20M annual efficiency gain for a mid-size MBS investor. The open Iceberg format prevents vendor lock-in while Snowflake's governance layer ensures regulatory compliance. The Cortex AI layer transforms the platform from a passive data store into an active intelligence system that surfaces insights proactively.

**AI Vision:** The ultimate evolution is an **autonomous mortgage data platform** where AI agents continuously monitor portfolio health, detect anomalies, recommend trades, draft regulatory reports, and explain their reasoning in natural language. Snowflake's convergence of data warehousing, data science, and AI into a single platform makes this achievable within 2-3 years. Key milestones: (1) Cortex Agents that chain multiple AI actions — e.g., detect a servicer anomaly, search historical precedents, forecast impact, and draft an alert — all within Snowflake. (2) Snowflake Marketplace becoming the industry's data exchange, replacing FTP-based loan tape delivery with governed, real-time data sharing. (3) Fine-tuned mortgage LLMs that understand GSE guidelines as well as a 20-year industry veteran, democratizing expertise across the organization.

---
