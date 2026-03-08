# Medallion Architecture & AI Readiness

[Back to Index](README.md)

---

## Overview

Medallion architecture organizes data into progressively refined quality layers — Bronze (raw), Silver (cleaned/conformed), and Gold (business-ready) — originally popularized by Databricks for Delta Lake environments. For AI/ML workloads, the architecture solves a fundamental problem: ML models require not just clean data, but data that is complete, consistent, fresh, labeled, and point-in-time correct. Each medallion layer enforces a different set of quality guarantees, and understanding where those guarantees live determines how reliable your models will be in production.

For a senior data engineer in the US secondary mortgage market, medallion architecture maps directly to the data journey from raw servicer loan tapes and CoreLogic property feeds through to the engineered feature vectors that train prepayment, default, and credit risk models.

---

## Key Concepts

| Layer | Also Known As | Purpose | AI/ML Role |
|---|---|---|---|
| Bronze | Raw / Landing | Verbatim ingestion | Audit trail, reprocessing baseline |
| Silver | Cleaned / Conformed | Validated, standardized | Joined datasets, analytical queries |
| Gold | Business / Curated | Aggregated, feature-engineered | ML training, model scoring |
| Platinum (optional) | AI / Model Output | Model scores stored as data | Downstream risk reports, monitoring |

---

## Detailed Explanations

### AI-Ready Data Requirements

Before a dataset can train a reliable production model, it must satisfy five properties:

1. **Completeness**: Key features have acceptable null rates (typically < 5% for model inputs). Missing data is handled explicitly, not silently dropped.
2. **Consistency**: The same entity (loan, property, borrower) has consistent values across sources and time periods. LTV calculated two different ways should not both appear in feature tables.
3. **Freshness**: Training data reflects recent market conditions. A prepayment model trained only on 2010–2015 data will not generalize to a 2025 rate environment.
4. **Labeled data**: The target variable (default indicator, prepayment event, loss severity) is accurately linked to the observation period. Label timing is as important as label accuracy.
5. **Point-in-time correctness**: Features reflect only information available at the observation date. This is the hardest requirement and the most common source of production model failure.

---

### Bronze Layer: Raw Ingestion for AI

Bronze is the landing zone. Every source record lands here verbatim — bad data included.

**Design principles for Bronze:**
- Append-only: never update or delete Bronze records
- Full fidelity: store all source fields, even ones not currently used
- Source metadata: record file name, ingestion timestamp, batch ID
- Partitioned by ingestion date, not business date (you may not trust the business date in raw data)

```sql
-- SQL Server Bronze table for loan tape ingestion
-- This is a staging database pattern analogous to Delta Lake Bronze

CREATE TABLE bronze.loan_tape_raw (
    ingestion_id        BIGINT IDENTITY(1,1) PRIMARY KEY,
    source_file_name    VARCHAR(500)     NOT NULL,
    ingestion_timestamp DATETIME2        NOT NULL DEFAULT GETUTCDATE(),
    batch_id            VARCHAR(100)     NOT NULL,
    record_sequence     INT              NOT NULL,

    -- Raw fields exactly as received (all VARCHAR to preserve original values)
    loan_id_raw              VARCHAR(50),
    origination_date_raw     VARCHAR(20),
    original_loan_amount_raw VARCHAR(30),
    current_upb_raw          VARCHAR(30),
    current_ltv_raw          VARCHAR(20),
    credit_score_raw         VARCHAR(10),
    dti_ratio_raw            VARCHAR(10),
    property_type_raw        VARCHAR(50),
    loan_purpose_raw         VARCHAR(50),
    servicer_code_raw        VARCHAR(20),
    delinquency_status_raw   VARCHAR(10),

    -- Parsing outcome (did the row parse without errors?)
    parse_status             VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    parse_error_message      VARCHAR(2000)
);

-- Partition by ingestion date for efficient processing queries
CREATE INDEX ix_bronze_loan_tape_batch
    ON bronze.loan_tape_raw (batch_id, ingestion_timestamp);
```

---

### Silver Layer: Standardized Schema and Validated Fields

Silver applies type casting, validation rules, deduplication, and reference data joins. Failed rows go to a quarantine table, not into Silver.

```sql
-- Silver layer: validated, typed, joined loan records
-- Snowflake implementation

CREATE OR REPLACE TABLE silver.loan_master (
    loan_id                 VARCHAR(50)     NOT NULL,
    as_of_date              DATE            NOT NULL,
    origination_date        DATE,
    original_loan_amount    DECIMAL(18,2),
    current_upb             DECIMAL(18,2),
    current_ltv             DECIMAL(8,4),        -- Standardized: 0.0 to 2.0 range
    credit_score            SMALLINT,            -- FICO 300-850
    dti_ratio               DECIMAL(6,4),        -- Standardized: 0.0 to 1.0 range
    property_type           VARCHAR(30),         -- Mapped to standard codes: SFR, CONDO, MF
    loan_purpose            VARCHAR(30),         -- PURCHASE, REFI_RATE_TERM, REFI_CASHOUT
    servicer_code           VARCHAR(20),
    delinquency_status      TINYINT,             -- 0=current, 1=30d, 2=60d, 3=90d+, 9=REO
    state_code              CHAR(2),
    msa_code                VARCHAR(10),

    -- Silver metadata
    source_batch_id         VARCHAR(100),
    silver_load_timestamp   TIMESTAMP_NTZ,
    silver_version          INTEGER DEFAULT 1,
    is_current              BOOLEAN DEFAULT TRUE

) CLUSTER BY (as_of_date, servicer_code);

-- Silver quarantine table for failed validation
CREATE OR REPLACE TABLE silver.loan_master_quarantine (
    quarantine_id           NUMBER AUTOINCREMENT,
    source_batch_id         VARCHAR(100),
    raw_ingestion_id        BIGINT,
    loan_id_raw             VARCHAR(50),
    validation_rule_failed  VARCHAR(200),
    validation_error_detail VARCHAR(2000),
    quarantine_timestamp    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

**Silver validation rules for mortgage data:**

```sql
-- dbt test-equivalent validation logic (can be run as a Snowflake Task)
INSERT INTO silver.loan_master_quarantine (
    source_batch_id, raw_ingestion_id, loan_id_raw,
    validation_rule_failed, validation_error_detail
)
SELECT
    b.batch_id,
    b.ingestion_id,
    b.loan_id_raw,
    CASE
        WHEN b.current_ltv_raw::FLOAT > 2.0 THEN 'LTV_OUT_OF_RANGE'
        WHEN b.credit_score_raw::INT NOT BETWEEN 300 AND 850 THEN 'CREDIT_SCORE_INVALID'
        WHEN b.dti_ratio_raw::FLOAT > 1.0 THEN 'DTI_OUT_OF_RANGE'
        WHEN b.current_upb_raw::DECIMAL(18,2) < 0 THEN 'NEGATIVE_UPB'
        ELSE 'LOAN_ID_NULL'
    END AS validation_rule_failed,
    CONCAT('Field value: ', COALESCE(b.current_ltv_raw, 'NULL')) AS validation_error_detail
FROM bronze.loan_tape_raw b
WHERE b.batch_id = :batch_id
  AND b.parse_status = 'PARSED'
  AND (
      TRY_TO_DECIMAL(b.current_ltv_raw, 8, 4) > 2.0
   OR TRY_TO_NUMBER(b.credit_score_raw) NOT BETWEEN 300 AND 850
   OR TRY_TO_DECIMAL(b.dti_ratio_raw, 6, 4) > 1.0
   OR TRY_TO_DECIMAL(b.current_upb_raw, 18, 2) < 0
   OR b.loan_id_raw IS NULL
  );
```

---

### Gold Layer: Feature Tables and ML-Ready Datasets

Gold tables are designed for consumption — by BI tools, ML training jobs, and model scoring pipelines. For AI, Gold means:

- Pre-joined: no lookups needed at training time
- Pre-aggregated: trailing 3/6/12 month metrics already computed
- Point-in-time partitioned: one row per loan per observation date
- Labeled: target variables appended (when used for supervised learning)

```sql
-- Gold: ML-ready feature table for mortgage default prediction
-- Snowflake implementation

CREATE OR REPLACE TABLE gold.loan_default_features (
    -- Identity
    loan_id                 VARCHAR(50)     NOT NULL,
    observation_date        DATE            NOT NULL,

    -- Loan characteristics at observation date
    current_ltv             DECIMAL(8,4),
    original_ltv            DECIMAL(8,4),
    ltv_change              DECIMAL(8,4),    -- current_ltv - original_ltv (home value signal)
    credit_score            SMALLINT,
    dti_ratio               DECIMAL(6,4),
    current_upb             DECIMAL(18,2),
    months_since_origination SMALLINT,

    -- Delinquency history features
    delinquency_status      TINYINT,
    max_delinquency_12m     TINYINT,         -- Worst bucket in last 12 months
    times_30d_delinquent_12m TINYINT,
    times_60d_delinquent_12m TINYINT,

    -- Prepayment behavior features
    prepay_speed_3m         DECIMAL(8,4),    -- 3-month trailing CPR
    prepay_speed_12m        DECIMAL(8,4),    -- 12-month trailing CPR

    -- Property and market features
    property_type           VARCHAR(30),
    state_code              CHAR(2),
    msa_code                VARCHAR(10),
    hpa_1y                  DECIMAL(8,4),    -- House price appreciation YoY
    unemployment_rate_msa   DECIMAL(6,4),

    -- Interest rate features
    note_rate               DECIMAL(6,4),
    current_market_rate_30y DECIMAL(6,4),
    rate_incentive          DECIMAL(6,4),    -- note_rate - market_rate (refi incentive)

    -- TARGET VARIABLE (Gold layer includes labels for ML)
    default_event_90d       BOOLEAN,         -- Did loan go 90+ DPD within 90 days?
    prepay_event_90d        BOOLEAN,         -- Did loan prepay within 90 days?

    -- Metadata
    feature_version         INTEGER DEFAULT 1,
    created_at              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()

) CLUSTER BY (observation_date)
  COMMENT = 'Gold ML feature table for mortgage default/prepayment models. Point-in-time correct.';
```

---

### Bronze to Silver to Gold Pipeline: Complete SQL Example

```sql
-- ============================================================
-- STEP 1: BRONZE → SILVER (Snowflake stored procedure)
-- ============================================================
CREATE OR REPLACE PROCEDURE silver.load_loan_master_from_bronze(batch_id VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    -- Insert valid records into Silver
    INSERT INTO silver.loan_master (
        loan_id, as_of_date, origination_date,
        original_loan_amount, current_upb, current_ltv,
        credit_score, dti_ratio, property_type, loan_purpose,
        servicer_code, delinquency_status, source_batch_id, silver_load_timestamp
    )
    SELECT
        b.loan_id_raw::VARCHAR(50),
        TRY_TO_DATE(b.origination_date_raw),          -- Graceful null on parse fail
        DATEADD('month', -1, CURRENT_DATE()),          -- as_of_date = month-end of batch
        TRY_TO_DECIMAL(b.original_loan_amount_raw, 18, 2),
        TRY_TO_DECIMAL(b.current_upb_raw, 18, 2),
        TRY_TO_DECIMAL(b.current_ltv_raw, 8, 4) / 100, -- Normalize: 75 -> 0.75
        TRY_TO_NUMBER(b.credit_score_raw)::SMALLINT,
        TRY_TO_DECIMAL(b.dti_ratio_raw, 6, 4) / 100,   -- Normalize: 43 -> 0.43
        pm.standard_property_type,                     -- Join to reference data
        pm.standard_loan_purpose,
        b.servicer_code_raw,
        TRY_TO_NUMBER(b.delinquency_status_raw)::TINYINT,
        b.batch_id,
        CURRENT_TIMESTAMP()
    FROM bronze.loan_tape_raw b
    LEFT JOIN reference.property_type_map pm
        ON pm.raw_code = b.property_type_raw
    WHERE b.batch_id = :batch_id
      AND b.loan_id_raw IS NOT NULL
      AND TRY_TO_DECIMAL(b.current_ltv_raw, 8, 4) BETWEEN 0 AND 200
      AND TRY_TO_NUMBER(b.credit_score_raw) BETWEEN 300 AND 850;

    RETURN 'Loaded ' || SQLROWCOUNT || ' rows to silver.loan_master';
END;
$$;

-- ============================================================
-- STEP 2: SILVER → GOLD (Feature engineering)
-- ============================================================
CREATE OR REPLACE PROCEDURE gold.build_loan_default_features(as_of_date DATE)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO gold.loan_default_features (
        loan_id, observation_date,
        current_ltv, original_ltv, ltv_change,
        credit_score, dti_ratio, current_upb,
        months_since_origination,
        delinquency_status, max_delinquency_12m,
        times_30d_delinquent_12m, times_60d_delinquent_12m,
        hpa_1y, unemployment_rate_msa,
        note_rate, current_market_rate_30y, rate_incentive,
        default_event_90d, prepay_event_90d
    )
    WITH loan_snapshot AS (
        -- Current month state
        SELECT *
        FROM silver.loan_master
        WHERE as_of_date = :as_of_date
    ),
    delinquency_history AS (
        -- Trailing 12-month delinquency statistics
        SELECT
            loan_id,
            MAX(delinquency_status)                                AS max_delinquency_12m,
            SUM(CASE WHEN delinquency_status = 1 THEN 1 ELSE 0 END) AS times_30d_delinquent_12m,
            SUM(CASE WHEN delinquency_status = 2 THEN 1 ELSE 0 END) AS times_60d_delinquent_12m
        FROM silver.loan_master
        WHERE as_of_date BETWEEN DATEADD('month', -12, :as_of_date) AND :as_of_date
        GROUP BY loan_id
    ),
    future_events AS (
        -- LABEL GENERATION: what happened in the next 90 days?
        -- This join is ONLY valid for historical training data generation
        -- At inference time, this is the model's prediction target
        SELECT
            loan_id,
            MAX(CASE WHEN delinquency_status >= 3 THEN TRUE ELSE FALSE END) AS default_event_90d,
            MAX(CASE WHEN current_upb = 0 AND delinquency_status = 0 THEN TRUE ELSE FALSE END) AS prepay_event_90d
        FROM silver.loan_master
        WHERE as_of_date BETWEEN :as_of_date AND DATEADD('day', 90, :as_of_date)
        GROUP BY loan_id
    )
    SELECT
        ls.loan_id,
        :as_of_date,
        ls.current_ltv,
        ls.original_ltv,
        ls.current_ltv - ls.original_ltv,
        ls.credit_score,
        ls.dti_ratio,
        ls.current_upb,
        DATEDIFF('month', ls.origination_date, :as_of_date),
        ls.delinquency_status,
        dh.max_delinquency_12m,
        dh.times_30d_delinquent_12m,
        dh.times_60d_delinquent_12m,
        hpa.appreciation_rate_1y,
        eco.unemployment_rate,
        lr.note_rate,
        mr.rate_30y_conventional,
        lr.note_rate - mr.rate_30y_conventional,
        COALESCE(fe.default_event_90d, FALSE),
        COALESCE(fe.prepay_event_90d, FALSE)
    FROM loan_snapshot ls
    LEFT JOIN delinquency_history dh ON dh.loan_id = ls.loan_id
    LEFT JOIN reference.hpa_by_msa hpa
        ON hpa.msa_code = ls.msa_code AND hpa.as_of_date = :as_of_date
    LEFT JOIN reference.economic_indicators eco
        ON eco.msa_code = ls.msa_code AND eco.as_of_date = :as_of_date
    LEFT JOIN silver.loan_rates lr
        ON lr.loan_id = ls.loan_id AND lr.as_of_date = :as_of_date
    LEFT JOIN reference.market_rates mr
        ON mr.as_of_date = :as_of_date
    LEFT JOIN future_events fe ON fe.loan_id = ls.loan_id;

    RETURN 'Built features for ' || SQLROWCOUNT || ' loans as of ' || :as_of_date;
END;
$$;
```

---

### Incremental Processing: Snowflake Streams and Tasks

Snowflake Streams capture CDC (Change Data Capture) on Silver tables, enabling incremental Gold refreshes rather than full rebuilds:

```sql
-- Create a Stream on the Silver loan_master table
CREATE OR REPLACE STREAM silver.loan_master_stream
    ON TABLE silver.loan_master
    SHOW_INITIAL_ROWS = FALSE;  -- Only capture changes going forward

-- Task to process the stream incrementally into Gold
CREATE OR REPLACE TASK gold.refresh_loan_features_incremental
    WAREHOUSE = compute_wh
    SCHEDULE = 'USING CRON 0 6 * * * UTC'  -- 6 AM UTC daily
AS
MERGE INTO gold.loan_default_features AS target
USING (
    SELECT
        s.loan_id,
        s.as_of_date,
        s.current_ltv,
        s.credit_score,
        s.dti_ratio,
        s.current_upb,
        s.delinquency_status
    FROM silver.loan_master_stream s
    WHERE s.METADATA$ACTION = 'INSERT'
       OR s.METADATA$ACTION = 'UPDATE'
) AS source
ON target.loan_id = source.loan_id
   AND target.observation_date = source.as_of_date
WHEN MATCHED THEN UPDATE SET
    target.current_ltv    = source.current_ltv,
    target.credit_score   = source.credit_score,
    target.current_upb    = source.current_upb
WHEN NOT MATCHED THEN INSERT (loan_id, observation_date, current_ltv, credit_score, dti_ratio, current_upb, delinquency_status)
    VALUES (source.loan_id, source.as_of_date, source.current_ltv, source.credit_score, source.dti_ratio, source.current_upb, source.delinquency_status);

ALTER TASK gold.refresh_loan_features_incremental RESUME;
```

---

### dbt for Medallion Architecture

dbt maps naturally to medallion layers:

```
dbt project structure:
models/
  staging/           → Bronze → Silver boundary (staging models)
    stg_loan_tape.sql
    stg_corelogic.sql
  intermediate/      → Silver joins and enrichment
    int_loan_with_property.sql
    int_loan_delinquency_history.sql
  marts/             → Gold feature tables and aggregates
    ml_features/
      fct_loan_default_features.sql
      fct_prepayment_features.sql
    reporting/
      rpt_portfolio_summary.sql
```

```sql
-- models/staging/stg_loan_tape.sql
-- Staging model: Bronze to Silver transformation

WITH source AS (
    SELECT * FROM {{ source('bronze', 'loan_tape_raw') }}
    WHERE batch_id = '{{ var("batch_id") }}'
),
validated AS (
    SELECT
        loan_id_raw::VARCHAR AS loan_id,
        TRY_TO_DATE(origination_date_raw) AS origination_date,
        TRY_TO_DECIMAL(current_ltv_raw, 8, 4) / 100 AS current_ltv,
        TRY_TO_NUMBER(credit_score_raw)::INTEGER AS credit_score,
        TRY_TO_DECIMAL(dti_ratio_raw, 6, 4) / 100 AS dti_ratio,
        TRY_TO_DECIMAL(current_upb_raw, 18, 2) AS current_upb,
        delinquency_status_raw::INTEGER AS delinquency_status,
        servicer_code_raw AS servicer_code,
        ingestion_timestamp
    FROM source
    WHERE loan_id_raw IS NOT NULL
)
SELECT * FROM validated

-- dbt test in schema.yml:
-- - not_null: [loan_id, current_ltv, credit_score]
-- - accepted_range: current_ltv between 0 and 2
-- - accepted_range: credit_score between 300 and 850
```

---

### Snowflake Dynamic Tables for Automated Layer Transformations

Dynamic Tables continuously materialize the result of a SQL query, automatically refreshing when upstream data changes:

```sql
-- Dynamic Table: Silver automatically refreshes when Bronze changes
CREATE OR REPLACE DYNAMIC TABLE silver.loan_master_dynamic
    TARGET_LAG = '1 hour'   -- Maximum acceptable staleness
    WAREHOUSE = compute_wh
AS
SELECT
    loan_id_raw::VARCHAR(50) AS loan_id,
    TRY_TO_DATE(origination_date_raw) AS origination_date,
    TRY_TO_DECIMAL(current_ltv_raw, 8, 4) / 100 AS current_ltv,
    TRY_TO_NUMBER(credit_score_raw)::SMALLINT AS credit_score,
    servicer_code_raw AS servicer_code,
    ingestion_timestamp AS silver_load_timestamp
FROM bronze.loan_tape_raw
WHERE loan_id_raw IS NOT NULL
  AND TRY_TO_NUMBER(credit_score_raw) BETWEEN 300 AND 850;
```

---

### Monitoring Data Freshness and Quality Across Layers

```sql
-- Freshness monitoring query — run as a Snowflake Task or dbt test
SELECT
    'silver.loan_master'        AS table_name,
    MAX(silver_load_timestamp)  AS last_loaded_at,
    DATEDIFF('hour', MAX(silver_load_timestamp), CURRENT_TIMESTAMP()) AS hours_since_refresh,
    COUNT(*)                    AS total_rows,
    SUM(CASE WHEN current_ltv IS NULL THEN 1 ELSE 0 END) AS null_ltv_count,
    SUM(CASE WHEN credit_score IS NULL THEN 1 ELSE 0 END) AS null_credit_score_count,
    ROUND(100.0 * SUM(CASE WHEN current_ltv IS NULL THEN 1 ELSE 0 END) / COUNT(*), 2) AS null_ltv_pct
FROM silver.loan_master

UNION ALL

SELECT
    'gold.loan_default_features',
    MAX(created_at),
    DATEDIFF('hour', MAX(created_at), CURRENT_TIMESTAMP()),
    COUNT(*),
    SUM(CASE WHEN current_ltv IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN credit_score IS NULL THEN 1 ELSE 0 END),
    ROUND(100.0 * SUM(CASE WHEN current_ltv IS NULL THEN 1 ELSE 0 END) / COUNT(*), 2)
FROM gold.loan_default_features;
```

---

## Interview Q&A

**Q1: What is the Medallion architecture and why is it well-suited for AI/ML workloads in the mortgage industry?**

A: Medallion is a layered data organization pattern with three tiers of data quality: Bronze (raw ingestion, append-only), Silver (cleaned, validated, conformed), and Gold (aggregated, feature-engineered, ML-ready). It is well-suited for mortgage AI because mortgage data arrives from multiple sources in inconsistent formats — servicer loan tapes in varying MISMO schemas, CoreLogic property data with geocoding updates, Intex prepayment model outputs, Bloomberg rate curves — and each source needs different cleaning rules. Bronze preserves every raw record for debugging and reprocessing. Silver normalizes to a canonical schema so that a loan from Servicer A and Servicer B have the same field names and value ranges. Gold pre-computes features (trailing CPR, delinquency history, rate incentive) so ML training jobs scan pre-joined, pre-aggregated data rather than performing expensive on-the-fly transformations.

**Q2: How do you implement data contracts between Medallion layers, and what happens when a contract is violated?**

A: A data contract specifies the expected schema, null rates, value ranges, and referential integrity for data crossing a layer boundary. In practice, I implement them with dbt schema tests (not_null, accepted_values, accepted_range, relationships), Great Expectations suites, or Snowflake constraint checks. When a contract is violated, the correct behavior depends on severity. Structural violations — a required column is missing, a value is out of range — quarantine the affected rows to a `_quarantine` table and continue loading valid rows. The batch is flagged as partially failed and an alert fires. Catastrophic violations — 50% null rate in credit_score, which suggests a feed format change — stop the load entirely, notify the data source owner, and do not promote incomplete data to Silver where downstream models might consume it.

**Q3: Explain the concept of data leakage in the context of building the Gold feature table for a mortgage default model.**

A: Data leakage occurs when features in the training dataset include information that would not be available at the time the model makes a real prediction. In mortgage default modeling, leakage is easy to introduce accidentally. Example: if you join the observation date record to the property's updated appraisal value that was recorded after the observation date, the model learns to predict defaults using information from the future. In production, the model would not have that updated appraisal, so predictions collapse. The Gold layer prevents leakage by strictly partitioning by observation date and using only data with `as_of_date <= observation_date` in all joins. Snowflake Streams help here because they let you reconstruct table state at a point in time using time travel, ensuring feature generation joins only reach backward in time, never forward.

**Q4: How does CDC (Change Data Capture) fit into Medallion architecture for incremental processing?**

A: CDC captures row-level changes (inserts, updates, deletes) from source systems, enabling Silver and Gold layers to refresh incrementally rather than rebuilding from scratch. In the mortgage context, a servicer sends a full loan tape monthly, but within the month individual loan status updates arrive via CDC from the master servicing system. Snowflake Streams capture CDC on Silver tables — every INSERT, UPDATE, DELETE is logged with a `METADATA$ACTION` column. A Task runs on a schedule, reads only the changed rows from the Stream, and merges them into the downstream Gold feature table. This reduces daily refresh time from hours (full rebuild) to minutes (incremental CDC merge). The key risk is that CDC requires careful handling of out-of-order events and late-arriving corrections; always include a `valid_from`/`valid_to` or `is_current` flag in Silver to track the effective history.

**Q5: You have a Gold feature table with 50 million rows spanning 10 years of monthly loan observations. A data scientist needs to train a model but wants to ensure no data leakage and reproducible results. What do you provide them?**

A: I provide a versioned, point-in-time partitioned feature table with three guarantees. First, every row in the Gold table has an `observation_date` column and contains only features computed from data available on or before that date — this is enforced at build time in the Gold procedure. Second, I provide the Delta Lake or Snowflake time travel version number that corresponds to the feature table snapshot used for training. The data scientist logs this version in their MLflow experiment so anyone can reproduce the exact training dataset by querying `gold.loan_default_features AT (VERSION => 47)`. Third, I document the feature computation logic in dbt model descriptions, so the data scientist understands what trailing CPR means, how DTI was normalized, and what edge cases were excluded — preventing them from misinterpreting features.

**Q6: What is a Snowflake Dynamic Table, and how does it simplify Medallion pipeline maintenance compared to stored procedures and Tasks?**

A: A Snowflake Dynamic Table is a table that continuously materializes the result of a SQL query, automatically detecting when source data changes and re-running the query to update the result. It replaces the manual trigger-task-procedure pattern with a declarative "I want this table to look like this query, refreshed within N hours." For Medallion pipelines, you define Silver as a Dynamic Table on top of Bronze, and Gold as a Dynamic Table on top of Silver. When a new Bronze batch loads, Snowflake automatically propagates the refresh through the chain. The operational advantage is no scheduler to maintain, no stored procedure to debug, and automatic dependency tracking. The limitation is that Dynamic Tables are optimized for full or incremental SQL refreshes; complex custom CDC merge logic still requires a Stream/Task pattern.

**Q7: How would you design the Silver layer for a mortgage platform that receives loan tapes from 15 different servicers, each with a different schema?**

A: The Silver layer needs a canonical schema and a servicer-specific translation layer in between. I build a `bronze_to_silver_mapping` reference table with one row per (servicer_code, source_field_name, canonical_field_name, transformation_rule). This drives a generic ELT procedure that applies servicer-specific field mappings and transformation rules before writing to Silver. For servicer-specific validation rules (Servicer A sends LTV as a decimal, Servicer B sends it as a percentage), the transformation_rule column contains a SQL expression. dbt macros also handle this well: a `standardize_loan_tape` macro accepts a servicer-specific staging model and applies the canonical transformation. The critical principle is that Silver has exactly one schema — no per-servicer tables. Downstream Gold and ML models write against one schema, never knowing which servicer originated each loan.

**Q8: Describe the "Platinum layer" or "AI layer" extension to Medallion, and how model outputs stored as data create a feedback loop.**

A: Some architectures add a Platinum or AI layer above Gold, storing model inference outputs as first-class data assets: default probability scores, prepayment speed predictions, severity estimates, deal-level cash flow projections. These outputs are stored as tables with the same governance, lineage tracking, and version control as any other data layer. This creates two feedback loops. The first is monitoring: by joining Platinum scores against future-realized Silver outcomes (did the loan that scored 0.85 default probability actually default?), you build model performance tracking dashboards and trigger retraining when drift exceeds thresholds. The second is feature generation: model outputs become features for other models. A predicted prepayment speed from a CPR model becomes an input feature for an OAS (option-adjusted spread) model. Treating model outputs as managed data — with lineage, versioning, and SLA monitoring — prevents the "score spreadsheet" antipattern where predictions live in ad hoc files with no governance.

**Q9: How do you monitor data freshness and quality across Medallion layers in a production mortgage platform?**

A: I implement a metadata layer that tracks load timestamps, row counts, and key quality metrics for every Bronze/Silver/Gold table after each batch. A scheduled Snowflake Task queries this metadata and writes to an `ops.pipeline_health` table. I monitor: (1) Freshness — hours since last successful load, with SLA thresholds (Bronze < 2 hours, Silver < 4 hours, Gold < 6 hours). (2) Volume anomalies — row count vs. 30-day average with ±30% alert thresholds; a servicer sending 10% of normal loan count likely indicates a feed failure, not a real portfolio reduction. (3) Null rate trends — if null_credit_score_pct increases from 0.5% to 5% in Silver, a source system changed. (4) Referential integrity — Gold rows with no matching Silver record (orphan detection). All alerts route to PagerDuty with severity tiers: data older than 12 hours is P1, anomalous null rates are P2.

**Q10: A regulatory audit requires you to demonstrate exactly what data was used to train a mortgage credit risk model deployed 18 months ago. How does the Medallion architecture support this?**

A: The Medallion architecture supports this through three mechanisms that together provide complete model training lineage. First, Bronze tables are append-only and never modified — the exact raw loan tape files ingested 18 months ago are still queryable by batch_id and ingestion_timestamp. Second, Delta Lake time travel (or Snowflake time travel) on Silver and Gold tables allows reconstruction of exact table state on any historical date; if we know the Gold feature table version used for training (recorded in MLflow), we can query `gold.loan_default_features AT (VERSION => 47)` to retrieve the exact training dataset. Third, the ML experiment metadata table (stored as a Platinum/Gold asset) records training data path, version, observation date range, feature list, and model performance metrics for every training run. For SR 11-7 and OCC model validation, this provides a complete chain: source file → Bronze record → Silver canonical record → Gold feature value → model training run → deployed model version.

---

## Pro Tips

- **Never overwrite Bronze.** If a Bronze table is ever modified, you lose the ability to audit model training data. Implement a DDL trigger or Snowflake resource monitor that alerts on any `UPDATE` or `DELETE` statement against Bronze tables.

- **Build the quarantine table first.** Before writing any Silver transformation, define the quarantine table and write the validation logic. Every bad row needs a home and an explanation. A quarantine rate above 0.5% in a mature pipeline is a signal that something changed upstream.

- **Partition Gold tables by observation date, not by ingestion date.** ML training jobs query "give me all features for Q3 2023" — not "give me everything loaded on a specific ingestion date." Partition pruning on business date dramatically reduces scan cost.

- **Make feature computation deterministic.** Gold feature tables should produce identical results when rerun with the same Silver data. Avoid `CURRENT_DATE()` or `CURRENT_TIMESTAMP()` inside feature calculations; use the observation date parameter instead. Non-deterministic features break reproducibility.

- **Use dbt's `--select` tag system to selectively rebuild layers.** Tag models as `bronze`, `silver`, `gold`, `ml_features` so you can run `dbt run --select tag:gold` to rebuild only Gold without touching Silver. This is critical during model retraining when you need to rebuild Gold for a specific observation date range.

- **Document label generation separately from feature generation.** The target variable join (future_events CTE) in the Gold procedure is the most dangerous code in your ML pipeline — it is the leakage surface. Keep it in a separate, well-commented function with a warning comment that it must only be called for historical training data generation, never for inference-time feature serving.
