# ETL Pipelines for Loan-Level Data

[Back to Secondary Market Index](./README.md)

---

## Table of Contents

1. [Key Concepts](#key-concepts)
2. [Data Sources in the Secondary Market](#data-sources-in-the-secondary-market)
3. [File Formats](#file-formats)
4. [ETL Architecture for Loan Data](#etl-architecture-for-loan-data)
5. [Staging-Transformation-Loading Pattern](#staging-transformation-loading-pattern)
6. [Handling Monthly Snapshots](#handling-monthly-snapshots)
7. [Incremental vs Full Loads](#incremental-vs-full-loads)
8. [Data Validation Rules](#data-validation-rules)
9. [Error Handling](#error-handling)
10. [Scheduling and Orchestration](#scheduling-and-orchestration)
11. [Tools and Technologies](#tools-and-technologies)
12. [Real-World Examples](#real-world-examples)
13. [Common Interview Questions](#common-interview-questions)
14. [Tips](#tips)

---

## Key Concepts

### What Are Loan-Level ETL Pipelines?

ETL (Extract, Transform, Load) pipelines for loan-level data are automated workflows that ingest raw residential mortgage data from multiple upstream sources, cleanse and standardize it, apply business rules, and load it into analytical data stores. In the secondary market, these pipelines handle millions of loan records monthly from agencies (Fannie Mae, Freddie Mac, Ginnie Mae), servicers, trustees, and third-party vendors.

The complexity of loan-level ETL stems from:

- **Volume**: Tens of millions of active loans across agency and non-agency universes
- **Variety**: Each source delivers data in different formats, schemas, and conventions
- **Velocity**: Monthly reporting cycles with strict deadlines tied to remittance dates
- **Veracity**: Data quality issues are endemic -- missing fields, inconsistent coding, retroactive corrections

### Why This Matters for Data Engineers

A senior data engineer in the MBS space is expected to design, build, and maintain these pipelines end to end. You must understand the domain-specific nuances -- such as why a servicer tape arrives on the 5th business day, why UPB reconciliation matters, and how a single missing loan can cascade into incorrect pool factor calculations.

---

## Data Sources in the Secondary Market

### Agency Files

| Source | Description | Frequency | Key Data |
|--------|-------------|-----------|----------|
| **Fannie Mae** | Single-Family Loan Performance Data, CAS/CRT deal files | Monthly | Loan ID, origination data, monthly performance, credit scores |
| **Freddie Mac** | Single-Family Loan-Level Dataset, STACR/DNA files | Monthly | Similar to FNMA with Freddie-specific fields |
| **Ginnie Mae** | PoolTalk, HMBS disclosures, monthly pool supplements | Monthly | FHA/VA/USDA loan data, pool-level and loan-level |
| **eMBS** | Agency pool and loan-level data aggregator | Monthly | Consolidated agency data with derived analytics |

### Vendor Feeds

- **CoreLogic / Black Knight**: Property valuation data, prepayment models, HPI indices
- **Intex / Bloomberg**: Deal structure, waterfall models, cash flow files
- **Moody's / S&P / Fitch**: Rating agency data, surveillance files
- **MISMO (Mortgage Industry Standards Maintenance Organization)**: Standardized XML schemas for loan data exchange

### Servicer Tapes

Servicer tapes (also called remittance files or investor reporting files) are the primary source of monthly loan-level performance data. Each servicer delivers tapes in their own format, making normalization a core ETL challenge.

Common servicer tape fields:
- Loan number, pool ID, investor code
- Current UPB, scheduled UPB
- Payment status (current, 30/60/90+ DPD)
- Next payment date, last payment date
- Interest rate, P&I payment amount
- Escrow balance, curtailment amounts
- Loss mitigation flags, modification indicators

---

## File Formats

### Pipe-Delimited Files

The most common format for agency disclosures. Fannie Mae's loan performance files use pipe (`|`) delimiters.

```
# Example: Fannie Mae Loan Performance file
100000001|01/2020|360|340|250000.00|3.500|0|0|N|N|SF|1|CA|900|75.5
100000001|02/2020|360|339|249500.00|3.500|0|0|N|N|SF|1|CA|900|75.5
```

**ETL consideration**: Handle trailing delimiters, empty fields between consecutive pipes, and header-less files where column positions are defined in a separate data dictionary.

### CSV (Comma-Separated Values)

Common for vendor feeds and internal data exchanges. Watch for:
- Embedded commas in address fields
- Quoted vs unquoted strings
- Different line endings (CRLF vs LF)
- BOM characters in UTF-8 files

### XML

MISMO XML is the industry standard for structured loan data exchange, particularly in due diligence and origination.

```xml
<LOAN LoanIdentifier="100000001">
  <TERMS>
    <OriginalLoanAmount>250000</OriginalLoanAmount>
    <NoteRatePercent>3.500</NoteRatePercent>
    <OriginalLoanTerm>360</OriginalLoanTerm>
  </TERMS>
  <PROPERTY>
    <State>CA</State>
    <PropertyType>SF</PropertyType>
  </PROPERTY>
</LOAN>
```

**ETL consideration**: XML parsing is CPU-intensive at scale. Consider streaming parsers (SAX) over DOM for large files. Flatten nested structures during staging.

### Fixed-Width Files

Legacy format still used by some servicers and trustees. Each field occupies a specific character position defined in a record layout.

```
# Record layout: LoanID(1-12), ReportDate(13-20), UPB(21-33), Rate(34-39)
100000001   01202020 0000250000003.500
100000001   02202020 0000249500003.500
```

**ETL consideration**: Requires a precise record layout document. Off-by-one errors in position definitions are a common source of bugs. Always validate against known values.

---

## ETL Architecture for Loan Data

### High-Level Architecture

```
+------------------+     +------------------+     +------------------+
|   DATA SOURCES   |     |   ETL PLATFORM   |     |   DATA STORES    |
+------------------+     +------------------+     +------------------+
|                  |     |                  |     |                  |
| Agency Files     |---->| Extract Layer    |---->| Staging DB       |
| Servicer Tapes   |---->| Transform Layer  |---->| Data Warehouse   |
| Vendor Feeds     |---->| Load Layer       |---->| Data Marts       |
| Rating Agencies  |---->| Orchestration    |---->| Analytics Layer  |
|                  |     | Monitoring       |     | Reporting        |
+------------------+     +------------------+     +------------------+
```

### Design Principles

1. **Idempotency**: Running the same pipeline twice for the same reporting period must produce identical results. Critical for month-end reprocessing.
2. **Auditability**: Every record must be traceable from source to destination. Maintain lineage metadata.
3. **Modularity**: Separate extract, transform, and load into independent, reusable components.
4. **Fault tolerance**: Handle partial failures gracefully. A bad record in one servicer file should not block the entire pipeline.
5. **Scalability**: Design for growth -- loan counts increase through acquisitions, new deal issuances, and expanded product coverage.

---

## Staging-Transformation-Loading Pattern

### Stage 1: Staging (Raw Ingestion)

Load source data as-is into staging tables with minimal transformation. Preserve the raw data for audit and reprocessing.

```sql
-- Staging table for Fannie Mae loan performance data
CREATE TABLE stg_fnma_loan_performance (
    load_id              BIGINT IDENTITY,
    load_timestamp       DATETIME DEFAULT GETDATE(),
    source_file_name     VARCHAR(255),
    source_row_number    INT,
    -- Raw fields as strings to preserve source fidelity
    loan_id              VARCHAR(20),
    reporting_period     VARCHAR(10),
    original_loan_term   VARCHAR(10),
    remaining_months     VARCHAR(10),
    current_upb          VARCHAR(20),
    interest_rate        VARCHAR(10),
    days_delinquent      VARCHAR(10),
    loan_age             VARCHAR(10),
    zero_balance_code    VARCHAR(5),
    zero_balance_date    VARCHAR(10),
    property_type        VARCHAR(5),
    num_units            VARCHAR(5),
    state                VARCHAR(5),
    credit_score         VARCHAR(10),
    ltv                  VARCHAR(10)
);
```

**Key practices:**
- Store all fields as VARCHAR/STRING to avoid ingestion failures from unexpected data
- Add metadata columns: `source_file_name`, `source_row_number`, `load_timestamp`
- Create a control table to track file-level metadata (row counts, file size, checksum)

```sql
-- File control table
CREATE TABLE etl_file_control (
    file_id              BIGINT IDENTITY PRIMARY KEY,
    file_name            VARCHAR(255),
    file_path            VARCHAR(500),
    file_size_bytes      BIGINT,
    file_checksum        VARCHAR(64),
    expected_row_count   INT,
    actual_row_count     INT,
    load_status          VARCHAR(20),  -- RECEIVED, STAGING, STAGED, FAILED
    load_start_time      DATETIME,
    load_end_time        DATETIME,
    reporting_period     DATE
);
```

### Stage 2: Transformation (Cleanse, Validate, Enrich)

Apply data type conversions, business rules, standardization, and enrichment.

```sql
-- Transform staged data into typed, validated records
INSERT INTO xfm_loan_performance (
    loan_id,
    reporting_period,
    original_loan_term,
    remaining_months,
    current_upb,
    interest_rate,
    delinquency_status,
    loan_age,
    zero_balance_code,
    zero_balance_date,
    property_type_code,
    property_type_desc,
    num_units,
    state_code,
    state_name,
    credit_score,
    ltv,
    validation_flags
)
SELECT
    TRIM(s.loan_id),
    TRY_CAST(
        CONCAT('20', RIGHT(s.reporting_period, 2), '-',
               LEFT(s.reporting_period, 2), '-01') AS DATE
    ),
    TRY_CAST(s.original_loan_term AS INT),
    TRY_CAST(s.remaining_months AS INT),
    TRY_CAST(s.current_upb AS DECIMAL(15,2)),
    TRY_CAST(s.interest_rate AS DECIMAL(6,3)),
    CASE
        WHEN s.days_delinquent = '0' THEN 'Current'
        WHEN s.days_delinquent = '1' THEN '30 DPD'
        WHEN s.days_delinquent = '2' THEN '60 DPD'
        WHEN s.days_delinquent = '3' THEN '90+ DPD'
        ELSE 'Unknown'
    END,
    TRY_CAST(s.loan_age AS INT),
    NULLIF(TRIM(s.zero_balance_code), ''),
    TRY_CAST(s.zero_balance_date AS DATE),
    TRIM(s.property_type),
    pt.property_type_description,
    TRY_CAST(s.num_units AS INT),
    TRIM(s.state),
    st.state_name,
    TRY_CAST(s.credit_score AS INT),
    TRY_CAST(s.ltv AS DECIMAL(6,2)),
    -- Build validation flag bitmask
    CASE WHEN TRY_CAST(s.current_upb AS DECIMAL(15,2)) IS NULL THEN 1 ELSE 0 END
    + CASE WHEN TRY_CAST(s.interest_rate AS DECIMAL(6,3)) IS NULL THEN 2 ELSE 0 END
    + CASE WHEN TRY_CAST(s.credit_score AS INT) NOT BETWEEN 300 AND 850 THEN 4 ELSE 0 END
    + CASE WHEN TRIM(s.state) NOT IN (SELECT state_code FROM ref_states) THEN 8 ELSE 0 END
FROM stg_fnma_loan_performance s
LEFT JOIN ref_property_types pt ON TRIM(s.property_type) = pt.property_type_code
LEFT JOIN ref_states st ON TRIM(s.state) = st.state_code
WHERE s.load_id > @last_processed_load_id;
```

### Stage 3: Loading (Final Target Tables)

Load validated, transformed data into the production data warehouse.

```sql
-- Merge into the production loan performance fact table
MERGE INTO dw_loan_performance_fact AS tgt
USING xfm_loan_performance AS src
ON tgt.loan_id = src.loan_id
   AND tgt.reporting_period = src.reporting_period
WHEN MATCHED THEN
    UPDATE SET
        tgt.current_upb       = src.current_upb,
        tgt.interest_rate      = src.interest_rate,
        tgt.delinquency_status = src.delinquency_status,
        tgt.remaining_months   = src.remaining_months,
        tgt.updated_timestamp  = GETDATE()
WHEN NOT MATCHED THEN
    INSERT (loan_id, reporting_period, original_loan_term, remaining_months,
            current_upb, interest_rate, delinquency_status, loan_age,
            zero_balance_code, zero_balance_date, property_type_code,
            num_units, state_code, credit_score, ltv, created_timestamp)
    VALUES (src.loan_id, src.reporting_period, src.original_loan_term,
            src.remaining_months, src.current_upb, src.interest_rate,
            src.delinquency_status, src.loan_age, src.zero_balance_code,
            src.zero_balance_date, src.property_type_code, src.num_units,
            src.state_code, src.credit_score, src.ltv, GETDATE());
```

---

## Handling Monthly Snapshots

### The Monthly Reporting Cycle

In the secondary market, loan-level data follows a monthly cadence tied to the remittance cycle:

1. **Reporting cutoff**: Usually the last business day of the month
2. **Servicer reporting**: Servicers submit tapes within the first 3-5 business days
3. **Agency publication**: Agencies publish disclosure files around the 10th-15th of the month
4. **Investor reporting**: Deal-level reports published around the 25th (for the prior month)

### Snapshot Storage Strategy

```sql
-- Each row represents one loan's status in one reporting period
CREATE TABLE loan_monthly_snapshot (
    snapshot_key         BIGINT IDENTITY PRIMARY KEY,
    loan_id              VARCHAR(20) NOT NULL,
    reporting_period     DATE NOT NULL,          -- Always first of month
    pool_id              VARCHAR(20),
    current_upb          DECIMAL(15,2),
    scheduled_upb        DECIMAL(15,2),
    interest_rate        DECIMAL(6,3),
    delinquency_status   VARCHAR(10),
    months_delinquent    INT,
    loan_age             INT,
    remaining_term       INT,
    modification_flag    CHAR(1),
    -- Partition key
    reporting_year_month AS FORMAT(reporting_period, 'yyyyMM') PERSISTED,
    CONSTRAINT uq_loan_snapshot UNIQUE (loan_id, reporting_period)
);

-- Partition by reporting period for efficient querying
CREATE PARTITION FUNCTION pf_reporting_period (DATE)
AS RANGE RIGHT FOR VALUES (
    '2020-01-01', '2020-02-01', '2020-03-01', /* ... */
    '2025-01-01', '2025-02-01', '2025-03-01'
);
```

### Late and Corrected Data

Servicers sometimes submit corrections after the initial tape delivery. Your pipeline must handle:

```sql
-- Track correction history
CREATE TABLE loan_snapshot_corrections (
    correction_id        BIGINT IDENTITY PRIMARY KEY,
    loan_id              VARCHAR(20),
    reporting_period     DATE,
    field_name           VARCHAR(100),
    original_value       VARCHAR(255),
    corrected_value      VARCHAR(255),
    correction_date      DATETIME,
    correction_source    VARCHAR(100),
    correction_reason    VARCHAR(500)
);
```

---

## Incremental vs Full Loads

### Full Load

Replaces all data for a given scope (e.g., all loans for a reporting period).

**When to use:**
- Initial historical backfill
- Monthly agency disclosure files (they publish complete snapshots)
- When data corrections affect a large portion of records
- Reference data refreshes

```sql
-- Full load: Replace entire reporting period
BEGIN TRANSACTION;

DELETE FROM loan_monthly_snapshot
WHERE reporting_period = @current_period;

INSERT INTO loan_monthly_snapshot (loan_id, reporting_period, current_upb, ...)
SELECT loan_id, reporting_period, current_upb, ...
FROM xfm_loan_performance
WHERE reporting_period = @current_period;

COMMIT;
```

### Incremental Load

Only processes new or changed records since the last successful load.

**When to use:**
- Daily vendor feeds with incremental updates
- Real-time or near-real-time data streams
- Large datasets where full reload is too expensive
- Intraday corrections from servicers

```sql
-- Incremental load using change detection
INSERT INTO loan_monthly_snapshot (loan_id, reporting_period, current_upb, ...)
SELECT src.loan_id, src.reporting_period, src.current_upb, ...
FROM xfm_loan_performance src
LEFT JOIN loan_monthly_snapshot tgt
    ON src.loan_id = tgt.loan_id
    AND src.reporting_period = tgt.reporting_period
WHERE tgt.loan_id IS NULL  -- New records only
   OR HASHBYTES('SHA2_256',
        CONCAT(src.current_upb, '|', src.interest_rate, '|', src.delinquency_status))
      <> HASHBYTES('SHA2_256',
        CONCAT(tgt.current_upb, '|', tgt.interest_rate, '|', tgt.delinquency_status));
```

### Comparison

| Aspect | Full Load | Incremental Load |
|--------|-----------|------------------|
| **Complexity** | Simple | Higher (change detection logic) |
| **Runtime** | Longer | Shorter |
| **Data consistency** | Guaranteed | Requires careful handling |
| **Recovery** | Easy (re-run) | Complex (state management) |
| **Storage I/O** | High | Low |
| **Use in MBS** | Monthly snapshots | Daily corrections, vendor updates |

---

## Data Validation Rules

### Domain-Specific Validation

```sql
-- Comprehensive validation rules for loan-level data
CREATE TABLE validation_rules (
    rule_id          INT PRIMARY KEY,
    rule_name        VARCHAR(100),
    rule_category    VARCHAR(50),
    rule_sql         NVARCHAR(MAX),
    severity         VARCHAR(10),  -- ERROR, WARNING, INFO
    description      VARCHAR(500)
);

-- Example validation rules
-- Rule 1: UPB must be positive for active loans
SELECT loan_id, reporting_period, current_upb
FROM xfm_loan_performance
WHERE current_upb <= 0
  AND zero_balance_code IS NULL;

-- Rule 2: Interest rate within reasonable bounds
SELECT loan_id, reporting_period, interest_rate
FROM xfm_loan_performance
WHERE interest_rate NOT BETWEEN 0.000 AND 15.000;

-- Rule 3: Credit score in valid FICO range
SELECT loan_id, reporting_period, credit_score
FROM xfm_loan_performance
WHERE credit_score NOT BETWEEN 300 AND 850
  AND credit_score IS NOT NULL;

-- Rule 4: Delinquency status must not decrease by more than one bucket
--         without a cure or modification event
SELECT curr.loan_id, curr.reporting_period,
       prev.delinquency_status AS prev_status,
       curr.delinquency_status AS curr_status
FROM xfm_loan_performance curr
JOIN loan_monthly_snapshot prev
    ON curr.loan_id = prev.loan_id
    AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
WHERE prev.months_delinquent - curr.months_delinquent > 1
  AND curr.modification_flag <> 'Y';

-- Rule 5: Loan age must increase by exactly 1 each month
SELECT curr.loan_id, curr.reporting_period,
       prev.loan_age AS prev_age, curr.loan_age AS curr_age
FROM xfm_loan_performance curr
JOIN loan_monthly_snapshot prev
    ON curr.loan_id = prev.loan_id
    AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
WHERE curr.loan_age <> prev.loan_age + 1;

-- Rule 6: UPB should be decreasing for amortizing loans (no negative amortization)
SELECT curr.loan_id, curr.reporting_period,
       prev.current_upb AS prev_upb, curr.current_upb AS curr_upb
FROM xfm_loan_performance curr
JOIN loan_monthly_snapshot prev
    ON curr.loan_id = prev.loan_id
    AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
WHERE curr.current_upb > prev.current_upb
  AND curr.modification_flag <> 'Y';
```

### Aggregate Validation

```sql
-- Pool-level UPB reconciliation
SELECT
    pool_id,
    reporting_period,
    SUM(current_upb) AS calculated_pool_upb,
    p.published_pool_upb,
    ABS(SUM(current_upb) - p.published_pool_upb) AS variance,
    CASE
        WHEN ABS(SUM(current_upb) - p.published_pool_upb) / p.published_pool_upb > 0.001
        THEN 'FAIL'
        ELSE 'PASS'
    END AS reconciliation_status
FROM loan_monthly_snapshot l
JOIN ref_pool_factors p
    ON l.pool_id = p.pool_id
    AND l.reporting_period = p.reporting_period
GROUP BY pool_id, reporting_period, p.published_pool_upb;
```

---

## Error Handling

### Error Classification

| Error Type | Example | Response |
|-----------|---------|----------|
| **Fatal** | Source file missing, authentication failure | Halt pipeline, alert immediately |
| **Structural** | Wrong number of columns, truncated file | Reject file, alert, request resend |
| **Data quality** | Invalid state code, out-of-range UPB | Log to error table, continue processing |
| **Referential** | Loan ID not found in master table | Quarantine record, investigate |
| **Duplicate** | Same loan/period already loaded | Skip or update based on strategy |

### Error Logging Pattern

```sql
CREATE TABLE etl_error_log (
    error_id            BIGINT IDENTITY PRIMARY KEY,
    pipeline_run_id     BIGINT,
    error_timestamp     DATETIME DEFAULT GETDATE(),
    error_severity      VARCHAR(10),
    error_category      VARCHAR(50),
    source_file         VARCHAR(255),
    source_row_number   INT,
    loan_id             VARCHAR(20),
    reporting_period    DATE,
    field_name          VARCHAR(100),
    field_value         VARCHAR(255),
    error_message       VARCHAR(1000),
    resolution_status   VARCHAR(20) DEFAULT 'OPEN',
    resolved_by         VARCHAR(100),
    resolved_date       DATETIME
);

-- Dead letter queue pattern for rejected records
CREATE TABLE etl_rejected_records (
    reject_id           BIGINT IDENTITY PRIMARY KEY,
    pipeline_run_id     BIGINT,
    reject_timestamp    DATETIME DEFAULT GETDATE(),
    source_file         VARCHAR(255),
    source_row_number   INT,
    raw_record          NVARCHAR(MAX),
    rejection_reason    VARCHAR(500),
    reprocess_flag      BIT DEFAULT 0,
    reprocessed_date    DATETIME
);
```

### Retry and Recovery Strategy

```
Pipeline Failure Recovery:
1. Check idempotency -- can we safely re-run?
2. Identify the failure point (extract, transform, load)
3. If extract failed: retry with exponential backoff
4. If transform failed: fix rule/logic, reprocess from staging
5. If load failed: check for partial loads, rollback if needed, retry
6. Log all recovery actions for audit trail
```

---

## Scheduling and Orchestration

### Monthly Pipeline Schedule (Typical)

| Business Day | Activity | Pipeline |
|-------------|----------|----------|
| BD 1-2 | Receive servicer tapes | File watcher triggers ingestion |
| BD 3-5 | Process servicer data | Transform and validate |
| BD 5-7 | Reconcile with prior month | Reconciliation pipeline |
| BD 8-12 | Agency disclosure files arrive | Agency ETL pipeline |
| BD 10-15 | Cross-reference agency vs servicer | Matching pipeline |
| BD 15-20 | Analytics refresh | Aggregate and report pipelines |
| BD 20-25 | Deal-level reporting | Trustee report pipeline |

### Apache Airflow DAG Example

```python
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.operators.sql import SQLCheckOperator
from airflow.sensors.filesystem import FileSensor
from datetime import datetime, timedelta

default_args = {
    'owner': 'mbs_data_engineering',
    'depends_on_past': True,
    'email_on_failure': True,
    'email': ['mbs-data-alerts@company.com'],
    'retries': 2,
    'retry_delay': timedelta(minutes=15),
}

with DAG(
    'monthly_fnma_loan_performance',
    default_args=default_args,
    description='Monthly Fannie Mae loan performance data pipeline',
    schedule_interval='0 6 5 * *',  # 5th of every month at 6 AM
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=['mbs', 'agency', 'fnma'],
) as dag:

    wait_for_file = FileSensor(
        task_id='wait_for_fnma_file',
        filepath='/data/incoming/fnma/loan_performance_*.txt',
        poke_interval=3600,  # Check every hour
        timeout=259200,      # Wait up to 3 days
        mode='poke',
    )

    stage_data = PythonOperator(
        task_id='stage_raw_data',
        python_callable=stage_fnma_loan_data,
        op_kwargs={'source_path': '/data/incoming/fnma/'},
    )

    validate_staging = SQLCheckOperator(
        task_id='validate_staging_row_count',
        sql="""
            SELECT CASE
                WHEN actual_row_count BETWEEN expected_row_count * 0.95
                    AND expected_row_count * 1.05
                THEN 1 ELSE 0 END
            FROM etl_file_control
            WHERE file_name LIKE 'fnma_loan_perf%'
              AND reporting_period = '{{ ds }}'
        """,
    )

    transform_data = PythonOperator(
        task_id='transform_and_validate',
        python_callable=transform_fnma_loan_data,
    )

    check_data_quality = SQLCheckOperator(
        task_id='check_data_quality',
        sql="""
            SELECT CASE
                WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
            FROM etl_error_log
            WHERE pipeline_run_id = '{{ run_id }}'
              AND error_severity = 'ERROR'
        """,
    )

    load_warehouse = PythonOperator(
        task_id='load_to_warehouse',
        python_callable=load_loan_performance_fact,
    )

    reconcile = PythonOperator(
        task_id='reconcile_upb',
        python_callable=reconcile_pool_upb,
    )

    (wait_for_file >> stage_data >> validate_staging
     >> transform_data >> check_data_quality
     >> load_warehouse >> reconcile)
```

---

## Tools and Technologies

### SSIS (SQL Server Integration Services)

- **Strengths**: Tight SQL Server integration, visual designer, established in financial institutions
- **Use case**: On-premises ETL for servicer tape processing
- **MBS consideration**: Good for fixed-width file parsing with flat file source adapters; supports data flow transformations natively

### Snowpipe (Snowflake)

- **Strengths**: Serverless, auto-ingest from cloud storage, near-real-time
- **Use case**: Continuous ingestion of vendor feeds into Snowflake
- **MBS consideration**: Ideal for agencies that publish files to S3/Azure Blob; handles semi-structured data (JSON, Parquet) well

```sql
-- Snowpipe for auto-ingesting agency files from S3
CREATE OR REPLACE PIPE mbs_db.staging.fnma_loan_pipe
AUTO_INGEST = TRUE
AS
COPY INTO mbs_db.staging.stg_fnma_loan_performance
FROM @mbs_db.staging.fnma_s3_stage
FILE_FORMAT = (
    TYPE = 'CSV'
    FIELD_DELIMITER = '|'
    SKIP_HEADER = 0
    NULL_IF = ('')
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
);
```

### Azure Data Factory (ADF)

- **Strengths**: Cloud-native, managed service, extensive connectors, integration with Azure ecosystem
- **Use case**: Hybrid cloud ETL, SFTP-to-cloud data movement
- **MBS consideration**: Mapping data flows handle complex transformations; linked services connect to on-premises servicer systems

### Apache Airflow

- **Strengths**: Python-based, highly extensible, DAG-based orchestration, strong community
- **Use case**: Orchestrating complex multi-step MBS data pipelines
- **MBS consideration**: Best for orchestration layer; pair with Spark or dbt for heavy transformations

### dbt (data build tool)

- **Strengths**: SQL-first transformations, version control, testing framework, documentation
- **Use case**: Transform layer in ELT architectures
- **MBS consideration**: Excellent for building the transformation logic with built-in data quality tests

```sql
-- dbt model: transformed loan performance
-- models/marts/mbs/fct_loan_performance.sql

{{ config(
    materialized='incremental',
    unique_key=['loan_id', 'reporting_period'],
    partition_by={'field': 'reporting_period', 'data_type': 'date'}
) }}

SELECT
    loan_id,
    reporting_period,
    CAST(current_upb AS DECIMAL(15,2)) AS current_upb,
    CAST(interest_rate AS DECIMAL(6,3)) AS interest_rate,
    {{ map_delinquency_status('days_delinquent') }} AS delinquency_status
FROM {{ ref('stg_fnma_loan_performance') }}

{% if is_incremental() %}
WHERE reporting_period > (SELECT MAX(reporting_period) FROM {{ this }})
{% endif %}
```

---

## Real-World Examples

### Example 1: Multi-Servicer Tape Consolidation

A mortgage REIT receives monthly tapes from 15 different servicers, each in a different format. The ETL pipeline must:

1. **Extract**: Pull files from 15 different SFTP servers on different schedules
2. **Normalize**: Map each servicer's field names to a canonical schema (e.g., Servicer A calls it "CURR_BAL", Servicer B calls it "unpaid_principal_balance")
3. **Transform**: Apply consistent business rules across all servicers
4. **Reconcile**: Match aggregated UPB against trustee reports
5. **Load**: Populate a unified loan performance table

```sql
-- Servicer field mapping table
CREATE TABLE servicer_field_mapping (
    servicer_id         VARCHAR(10),
    source_field_name   VARCHAR(100),
    target_field_name   VARCHAR(100),
    transformation_rule VARCHAR(500),
    data_type           VARCHAR(50)
);

-- Example mappings
INSERT INTO servicer_field_mapping VALUES
('SVC_A', 'CURR_BAL',    'current_upb',    'CAST(val AS DECIMAL(15,2))', 'DECIMAL(15,2)'),
('SVC_A', 'INT_RT',      'interest_rate',   'CAST(val AS DECIMAL(6,3))',  'DECIMAL(6,3)'),
('SVC_B', 'unpaid_principal_balance', 'current_upb', 'CAST(REPLACE(val,",","") AS DECIMAL(15,2))', 'DECIMAL(15,2)'),
('SVC_B', 'note_rate',   'interest_rate',   'CAST(val AS DECIMAL(6,3)) / 100', 'DECIMAL(6,3)');
```

### Example 2: Handling Agency Data Corrections

Fannie Mae occasionally publishes correction files that modify previously reported loan data. The pipeline must:

1. Detect correction files vs. regular monthly files
2. Identify affected loans and reporting periods
3. Apply corrections while preserving the audit trail
4. Recalculate downstream aggregates

---

## Common Interview Questions

### Q1: How would you design an ETL pipeline to process Fannie Mae's loan-level performance data?

**Answer**: I would design a three-stage pipeline:

**Extract**: Use a file sensor (Airflow FileSensor or ADF trigger) to detect new files on the agency's SFTP or S3 location. Download files to a landing zone, compute checksums, and register in a file control table.

**Stage**: Load the pipe-delimited file into a staging table with all VARCHAR columns to avoid type conversion failures. Add metadata columns for lineage (file name, row number, load timestamp). Validate structural integrity -- correct number of columns, file not truncated (check for expected trailer record or row count).

**Transform**: Cast to proper data types using TRY_CAST to catch conversion errors. Apply business rules: map coded values (e.g., zero balance codes) to descriptions, calculate derived fields (e.g., months delinquent from payment history), validate against domain rules (UPB > 0 for active loans, FICO between 300-850). Log all validation failures to an error table with severity classification.

**Load**: Use MERGE/UPSERT into the production fact table, partitioned by reporting period. After loading, run aggregate reconciliation -- compare loan counts and total UPB against published pool-level data.

**Orchestration**: Schedule with Airflow, with dependency chains ensuring staging completes before transformation. Include alerting for file arrival delays, validation failures above threshold, and reconciliation breaks.

### Q2: How do you handle a servicer that changes their tape format mid-stream?

**Answer**: This is a common real-world challenge. My approach:

1. **Schema detection layer**: Implement a pre-processing step that inspects the file header (if present) or samples the first N rows to detect the format version. Compare against registered schemas in a metadata table.
2. **Version-aware parsing**: Maintain multiple parser configurations keyed by servicer ID and format version. Use a field mapping table that maps source fields to canonical target fields, with effective dates.
3. **Backward compatibility**: Never discard the old mapping. Keep both versions active with date ranges so historical reprocessing still works.
4. **Alerting**: If the format does not match any known version, quarantine the file and alert the data engineering team rather than silently failing.
5. **Testing**: Maintain a regression test suite with sample files for each known format version to catch parsing issues before production.

### Q3: What is the difference between incremental and full loads, and when would you use each for MBS data?

**Answer**: A full load replaces all data for a given scope, while an incremental load only processes new or changed records.

For MBS data specifically:
- **Full load** is appropriate for monthly agency disclosure files because agencies publish complete snapshots of all active loans. It is simpler and guarantees consistency. Also used for initial historical backfills and when a servicer submits a corrected full tape.
- **Incremental load** is better for daily vendor feeds (e.g., property valuation updates), intraday corrections, and very large datasets where reloading millions of records monthly is too expensive. It requires change detection logic (timestamps, hash comparisons, or CDC mechanisms).

In practice, I often use a hybrid approach: full load within a reporting period partition (delete-and-reload the month), but incremental across periods (only process the current month, not all history).

### Q4: How do you ensure data quality in a loan-level ETL pipeline?

**Answer**: I implement data quality at multiple layers:

1. **Source validation**: File-level checks (row count, checksum, expected columns, file size within range)
2. **Record-level validation**: Type checks, range checks (UPB > 0, rate between 0-15%), pattern checks (loan ID format), null checks on required fields
3. **Cross-record validation**: Temporal consistency (UPB should decrease for amortizing loans, loan age should increment by 1), delinquency transition logic
4. **Aggregate validation**: Pool-level UPB reconciliation against published factors, loan count reconciliation, distribution analysis (e.g., sudden spike in delinquencies may indicate a data issue)
5. **Automated testing**: dbt tests or custom validation framework that runs after each pipeline execution and gates downstream processing

### Q5: Describe how you would handle late-arriving data in a monthly snapshot pipeline.

**Answer**: Late-arriving data is common when servicers miss reporting deadlines or submit corrections after initial processing.

1. **Design for reprocessing**: Ensure the pipeline is idempotent -- processing the same reporting period twice produces the same result. Use MERGE/UPSERT rather than INSERT to handle re-runs gracefully.
2. **Correction tracking**: Maintain a corrections table that logs what changed, when, and why. This is critical for audit and regulatory compliance.
3. **Downstream impact management**: Implement a dependency graph so that when a snapshot is corrected, all dependent aggregates, reports, and analytics are automatically flagged for refresh.
4. **SLA management**: Define a "close" date for each reporting period. Late data received before close is processed normally. Data after close triggers a correction workflow with additional approvals.
5. **Communication**: Automated notifications to downstream consumers when data is revised so they can refresh their analyses.

---

## Tips

1. **Always preserve raw data**: Never transform in place. Keep the original source data in staging so you can reprocess when business rules change or bugs are discovered.

2. **Design for reprocessing from day one**: In the MBS world, corrections and restatements are routine. If your pipeline cannot easily reprocess a prior month, you will accumulate technical debt rapidly.

3. **Use metadata-driven pipelines**: Rather than hardcoding field mappings and transformations, store them in configuration tables. This makes it far easier to onboard new servicers or adapt to format changes without code deployments.

4. **Monitor data drift**: Track statistical distributions of key fields (UPB, rate, FICO) over time. A sudden shift may indicate a data issue upstream rather than an actual market change.

5. **Understand the business calendar**: MBS data pipelines are governed by remittance cycles, payment dates, and factor publication schedules. Build your scheduling around these business events, not arbitrary cron expressions.

6. **Partition aggressively**: Loan-level data grows by millions of rows per month. Partition by reporting period at minimum. This enables efficient partition-level operations (swap, truncate, archive) and dramatically improves query performance.

7. **Invest in reconciliation**: UPB and loan count reconciliation between your system and published pool factors is the single most important data quality check in MBS. Automate it and make it a hard gate in your pipeline.

8. **Version your schemas**: Use schema evolution strategies (e.g., Avro schema registry, dbt schema tests) to catch breaking changes before they reach production.

9. **Document data lineage**: Regulators and auditors will ask where a number came from. Maintain clear lineage from source file to final report, including all transformations applied.

10. **Test with production-scale data**: Loan-level pipelines that work fine with 10,000 test records often fail at 10 million. Always test with realistic data volumes before deployment.
