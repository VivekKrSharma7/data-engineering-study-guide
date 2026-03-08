# Data Lakehouse Architecture for AI/ML

[Back to Index](README.md)

---

## Overview

The data lakehouse is a modern data architecture that merges the low-cost, flexible storage of a data lake with the ACID reliability, schema enforcement, and query performance of a data warehouse. For AI/ML workloads, the lakehouse pattern is transformative: it allows training data, feature stores, model artifacts, and inference outputs to coexist in a single governed platform — eliminating the fragile ETL pipelines that historically shuttled data between separate lake and warehouse systems.

For a senior data engineer in the US secondary mortgage market, this means that loan tape ingestion (raw MISMO XML or flat files), CoreLogic property data, Intex cash flow outputs, and ML-ready feature tables can all live in one architecture with consistent versioning, lineage, and access control.

---

## Key Concepts

| Concept | Definition |
|---|---|
| Data Lake | Object storage (S3, ADLS, GCS) with schema-on-read; flexible but unreliable |
| Data Warehouse | Columnar RDBMS with schema-on-write; reliable but inflexible and expensive |
| Data Lakehouse | Open table format on object storage with warehouse-grade reliability |
| Open Table Format | Metadata layer over Parquet files enabling ACID, time travel, schema evolution |
| Delta Lake | Linux Foundation open table format, originated at Databricks |
| Apache Iceberg | Netflix-originated open table format with hidden partitioning |
| Apache Hudi | Uber-originated open table format with upsert/CDC focus |
| Medallion Architecture | Bronze / Silver / Gold layered data quality pattern |
| Feature Store | Centralized repository for ML features with point-in-time retrieval |
| Unity Catalog | Databricks unified governance layer for Delta Lake |

---

## Detailed Explanations

### Lakehouse vs Data Warehouse vs Data Lake

```
                    Data Lake       Data Warehouse      Data Lakehouse
Storage Cost        Low (S3/ADLS)   High (proprietary)  Low (S3/ADLS)
ACID Transactions   No              Yes                 Yes
Schema Enforcement  Schema-on-read  Schema-on-write     Both supported
ML/AI Support       Excellent       Poor                Excellent
SQL Analytics       Poor-Moderate   Excellent           Excellent
Streaming           Yes             Limited             Yes
Data Formats        Open (Parquet)  Proprietary         Open (Parquet)
Time Travel         No              Snowflake only      Yes (all formats)
```

For the mortgage market: your legacy SQL Server DW handles regulatory reporting with high reliability. A lakehouse sits beside it, ingesting raw loan tapes, running ML feature pipelines, and feeding model training — without duplicating the reporting layer.

---

### Open Table Formats Deep Dive

#### Delta Lake

Delta Lake stores a transaction log (`_delta_log/`) alongside Parquet data files. Every operation (insert, update, delete, schema change) appends a JSON commit entry to this log. This enables:

- **ACID transactions**: Multiple writers can commit without corruption
- **Schema enforcement**: Writes with mismatched columns are rejected
- **Schema evolution**: Columns can be added, renamed with `MERGE SCHEMA`
- **Time travel**: Query any historical version by timestamp or version number
- **Vacuum**: Remove stale Parquet files to reclaim storage

```python
from delta import DeltaTable
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension") \
    .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog") \
    .getOrCreate()

# Write loan tape data to Delta Lake
loan_df = spark.read.parquet("s3://raw-bucket/loan-tapes/2024-Q4/*.parquet")

loan_df.write \
    .format("delta") \
    .mode("overwrite") \
    .option("mergeSchema", "true") \
    .save("s3://lakehouse/silver/loan_tapes/")

# Time travel: retrieve data as of a specific date for ML reproducibility
historical_df = spark.read \
    .format("delta") \
    .option("timestampAsOf", "2024-10-01") \
    .load("s3://lakehouse/silver/loan_tapes/")

# Upsert (MERGE) for incremental updates — critical for loan status changes
delta_table = DeltaTable.forPath(spark, "s3://lakehouse/silver/loan_tapes/")

delta_table.alias("target").merge(
    loan_df.alias("source"),
    "target.loan_id = source.loan_id"
).whenMatchedUpdateAll() \
 .whenNotMatchedInsertAll() \
 .execute()
```

#### Apache Iceberg

Iceberg solves several Delta Lake limitations at very large scale:

- **Hidden partitioning**: Partition transforms (year, month, bucket) are transparent to queries; no partition pruning mistakes
- **Row-level deletes**: Delete rows without rewriting entire Parquet files (important for GDPR compliance on borrower PII)
- **Schema evolution**: Add, drop, rename, reorder columns — even change types safely
- **Partition evolution**: Change partitioning strategy without rewriting historical data

```python
# Snowflake Iceberg table creation — integrates lakehouse with Snowflake
# This is a key bridge pattern for Snowflake shops adding lakehouse capabilities

CREATE OR REPLACE ICEBERG TABLE loan_features_iceberg
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 's3_lakehouse_volume'
  BASE_LOCATION = 'gold/loan_features/'
  AS
  SELECT
      loan_id,
      current_ltv,
      dti_ratio,
      credit_score,
      months_since_origination,
      current_upb,
      prepay_speed_3m,
      default_probability_score
  FROM silver.loan_master
  WHERE active_flag = TRUE;
```

#### Apache Hudi

Hudi (Hadoop Upserts Deletes and Incrementals) is optimized for:
- **Upserts at scale**: Efficient handling of loan status updates (delinquency, payoff, modification)
- **Incremental queries**: Pull only records changed since last checkpoint — reduces compute cost
- **Copy-on-Write (CoW)**: Rewrites Parquet on write, fast reads
- **Merge-on-Read (MoR)**: Writes delta logs, merges on read — fast writes, slightly slower reads

---

### Medallion Architecture for ML

The medallion pattern structures data quality progression in layers. For AI/ML, each layer serves a distinct purpose:

```
Bronze (Raw)     → Silver (Cleaned/Conformed)  → Gold (ML-Ready Features)
Loan tape CSV      Validated loan records          Engineered feature vectors
CoreLogic XML      Standardized property data      Property value features
Intex reports      Normalized cash flows           Prepayment/default features
Market data        Deduplicated rate curves        Interest rate features
```

**Bronze**: Append-only, never modified. Source of truth for reprocessing. Retain all fields including bad data — you need it for debugging model degradation.

**Silver**: Applied schema validation, null handling, deduplication, type casting, reference data joins. A failed loan tape row lands in a quarantine table, not in Silver.

**Gold**: Aggregated, joined, feature-engineered tables optimized for ML training. Point-in-time correct. Each row represents an observation at a specific date with no future information leakage.

---

### Feature Store on Lakehouse

A feature store provides:
1. **Offline store**: Historical features for training (Delta Lake / Iceberg tables)
2. **Online store**: Low-latency features for real-time inference (Redis, DynamoDB, Feast)
3. **Point-in-time joins**: Retrieve feature values as they existed at the label date

```python
# Feast feature store on Delta Lake — offline store configuration
from feast import FeatureStore, Entity, FeatureView, Field
from feast.types import Float32, Int64
from feast.infra.offline_stores.contrib.spark_offline_store.spark_source import SparkSource

loan_source = SparkSource(
    path="s3://lakehouse/gold/loan_features/",
    file_format="delta",
    timestamp_field="feature_timestamp",
    created_timestamp_column="created_at"
)

loan_entity = Entity(name="loan_id", join_keys=["loan_id"])

loan_feature_view = FeatureView(
    name="loan_risk_features",
    entities=[loan_entity],
    schema=[
        Field(name="current_ltv", dtype=Float32),
        Field(name="dti_ratio", dtype=Float32),
        Field(name="credit_score", dtype=Int64),
        Field(name="months_delinquent", dtype=Int64),
        Field(name="prepay_speed_3m", dtype=Float32),
    ],
    source=loan_source,
    ttl=None  # No expiry — historical features always needed
)
```

---

### Unity Catalog for Lakehouse Governance

Unity Catalog (Databricks) provides a three-level namespace: `catalog.schema.table`. For the mortgage market:

```
mortgage_catalog.bronze.raw_loan_tapes
mortgage_catalog.bronze.raw_corelogic_feeds
mortgage_catalog.silver.loan_master
mortgage_catalog.silver.property_master
mortgage_catalog.gold.loan_risk_features
mortgage_catalog.gold.prepayment_features
mortgage_catalog.ml_outputs.default_model_scores
```

Key governance features for ML:
- Column-level access control: mask SSN/borrower PII from data scientists
- Row-level security: limit analysts to their assigned portfolio segments
- Data lineage: trace Gold feature columns back to Bronze source fields
- Audit logs: who accessed what training data, when

---

### Query Engines on Lakehouse

| Engine | Best For | Latency | Scale |
|---|---|---|---|
| Apache Spark | Large-scale ETL, ML training | Minutes | Petabyte |
| Trino/Presto | Interactive SQL analytics | Seconds | Terabyte |
| DuckDB | Local development, small datasets | Milliseconds | Gigabyte |
| Snowflake (external tables) | BI reporting on lakehouse data | Seconds | Terabyte |
| Databricks SQL | Governed SQL on Delta Lake | Seconds | Petabyte |

```python
# DuckDB — fast local development against lakehouse Parquet files
import duckdb

conn = duckdb.connect()

# Install Delta extension for local Delta Lake reads
conn.execute("INSTALL delta; LOAD delta;")

result = conn.execute("""
    SELECT
        loan_purpose,
        AVG(current_ltv) AS avg_ltv,
        AVG(credit_score) AS avg_fico,
        COUNT(*) AS loan_count
    FROM delta_scan('s3://lakehouse/silver/loan_master/')
    WHERE as_of_date = '2024-12-31'
    GROUP BY loan_purpose
    ORDER BY loan_count DESC
""").fetchdf()

print(result)
```

---

### Snowflake External Tables on Lakehouse Data

```sql
-- Create external stage pointing to lakehouse storage
CREATE OR REPLACE STAGE lakehouse_stage
  URL = 's3://lakehouse/silver/loan_master/'
  STORAGE_INTEGRATION = s3_lakehouse_integration
  FILE_FORMAT = (TYPE = PARQUET);

-- External table: query lakehouse Parquet from Snowflake without data movement
CREATE OR REPLACE EXTERNAL TABLE ext_loan_master (
    loan_id         VARCHAR   AS ($1:loan_id::VARCHAR),
    current_ltv     FLOAT     AS ($1:current_ltv::FLOAT),
    credit_score    INTEGER   AS ($1:credit_score::INTEGER),
    upb             DECIMAL(18,2) AS ($1:upb::DECIMAL(18,2)),
    as_of_date      DATE      AS ($1:as_of_date::DATE)
)
  WITH LOCATION = @lakehouse_stage
  AUTO_REFRESH = TRUE
  FILE_FORMAT = (TYPE = PARQUET);

-- Now Snowflake users can query the lakehouse as if it were a native table
SELECT
    DATE_TRUNC('month', as_of_date) AS month,
    AVG(current_ltv) AS avg_ltv,
    COUNT(*) AS loan_count
FROM ext_loan_master
WHERE as_of_date >= '2024-01-01'
GROUP BY 1
ORDER BY 1;
```

---

### ML Metadata on Lakehouse: Lineage and Versioning

Tracking ML metadata alongside data is a key advantage of the lakehouse approach:

```python
# Store ML experiment metadata as a Delta table — queryable alongside feature data
from pyspark.sql import Row
from datetime import datetime

experiment_record = Row(
    experiment_id="exp_default_model_2024Q4",
    model_type="XGBoost",
    training_data_path="s3://lakehouse/gold/loan_risk_features/",
    training_data_version=47,          # Delta table version number
    training_data_timestamp="2024-10-01T00:00:00",
    features_used=["current_ltv", "dti_ratio", "credit_score", "months_delinquent"],
    train_auc=0.847,
    val_auc=0.831,
    trained_at=datetime.now().isoformat(),
    trained_by="pipeline_svc_account"
)

spark.createDataFrame([experiment_record]) \
    .write \
    .format("delta") \
    .mode("append") \
    .save("s3://lakehouse/ml_metadata/experiments/")
```

---

## Interview Q&A

**Q1: What is the core architectural difference between a data lakehouse and a traditional data warehouse + data lake combination?**

A: The traditional two-tier architecture stores data twice: raw in the lake (S3/ADLS) and transformed in the warehouse (Snowflake, Redshift). This doubles storage cost, creates synchronization lag, and multiplies ETL complexity. The lakehouse eliminates this by placing an open table format (Delta Lake, Iceberg) directly on the object storage, so the same physical Parquet files serve both the data warehouse SQL engine and the ML training platform. There is one copy of truth. For mortgage analytics, this means the same loan tape data that feeds prepayment model training also serves regulatory reporting queries — without a nightly reload.

**Q2: How does Delta Lake's transaction log enable ACID guarantees on object storage, which was designed for eventual consistency?**

A: The `_delta_log/` directory holds a sequential series of JSON commit files (0000000001.json, 0000000002.json…). When a writer commits, it atomically writes a new JSON file listing the Parquet files added and removed in that transaction. Object storage `PUT` operations are atomic for single objects, so the commit file either exists completely or not at all. Readers reconstruct the current table state by replaying the log. Concurrent writers use optimistic concurrency control — if two writers try to commit conflicting changes, one succeeds and the other retries. This gives snapshot isolation without a distributed lock manager.

**Q3: For a mortgage prepayment model, why is point-in-time correctness in feature generation so critical, and how does the lakehouse support it?**

A: Prepayment models predict borrower behavior (refinance, curtailment, payoff) using loan characteristics and market conditions at a given observation date. If you accidentally include future information — say, credit scores updated after the observation date — the model learns a pattern that cannot exist at inference time, producing inflated backtest performance that collapses in production. This is data leakage. The lakehouse supports point-in-time correctness through Delta Lake time travel: you can reconstruct exactly what your loan_master table contained on any historical date using `VERSION AS OF` or `TIMESTAMP AS OF`, ensuring training features reflect only information available at the observation date.

**Q4: Compare Delta Lake, Apache Iceberg, and Apache Hudi. When would you choose each for a mortgage data platform?**

A: Choose **Delta Lake** when your primary compute is Databricks or Spark and you need tight integration with Unity Catalog for governance. It has the most mature ecosystem for ML workflows and the simplest operational model. Choose **Iceberg** when you need true multi-engine support (Snowflake, Flink, Trino, Spark all first-class) or row-level deletes for GDPR/CCPA borrower data removal without full partition rewrites. Choose **Hudi** when your dominant workload is high-volume upserts — e.g., daily loan status updates from the servicer where millions of loans change state and you need efficient CDC. In practice, many shops standardize on Delta Lake or Iceberg; Hudi is less common in new architectures.

**Q5: How would you implement a feature store for a mortgage default model on a lakehouse?**

A: I would build a two-tier feature store. The offline store is Delta Lake Gold tables partitioned by `observation_date`, containing pre-computed features (LTV, DTI, FICO, months delinquent, property value change) for each loan on each monthly observation date. Training jobs use point-in-time joins: for each labeled loan (default/non-default event), retrieve the feature row where `observation_date` is the most recent date before the label date. The online store (Redis or DynamoDB) holds current feature values for real-time scoring on new originations. Feast or Tecton manages the feature registry, consistency checks, and the online/offline sync. The key governance requirement is that every model training run records which Delta table version was used, so you can reproduce it exactly later.

**Q6: A data scientist reports that their mortgage default model performs well in backtesting but poorly in production. What lakehouse-related issues would you investigate?**

A: First, check for data leakage: were features generated with point-in-time queries or did they accidentally include data not available at the observation date? Second, check training data freshness: is the Gold feature table being updated on the expected schedule? A stale feature table means the model never sees recent market conditions. Third, investigate schema drift: has an upstream schema change in Bronze silently introduced nulls or changed value ranges in Gold features? Delta Lake schema enforcement should catch this, but check the audit logs. Fourth, check the training/serving skew: are online features computed with the same logic as offline features? A mismatch in how DTI is calculated between the feature store and the inference pipeline is a common source of degradation.

**Q7: How does Unity Catalog address governance requirements for a regulated mortgage data platform?**

A: Unity Catalog provides column-level masking and row-level security that are critical for mortgage data. Borrower PII (SSN, date of birth, income) can be masked so data scientists see `****-**-1234` while retaining the ability to join on loan_id. Row-level security lets you restrict portfolio analysts to their assigned servicer or geography without maintaining separate table copies. For AI governance, Unity Catalog's lineage graph traces every Gold feature column back through Silver transformations to the Bronze source file, which is essential for Model Risk Management (MRM) documentation required under SR 11-7 and OCC guidance. Tag-based governance lets you label tables as `pii`, `model_input`, or `regulatory_capital`, and policies automatically apply.

**Q8: Explain how Snowflake Iceberg tables bridge the gap between a lakehouse and an existing Snowflake data warehouse.**

A: Snowflake Iceberg tables allow Snowflake to read and write Parquet data stored in your own S3/ADLS under Iceberg metadata — the data never moves into Snowflake's internal storage. This means Snowflake SQL queries can join native Snowflake tables (regulatory reports, reference data) with lakehouse data (ML features, model outputs) in a single query without ETL. It also means Databricks Spark can write to the same Iceberg table that Snowflake reads, enabling a true multi-engine lakehouse. For the mortgage market, this pattern lets your existing Snowflake BI dashboards incorporate ML model scores computed by Spark, without reloading data through Snowflake's storage layer.

**Q9: What is the Medallion architecture and how does each layer serve ML needs differently?**

A: Medallion is a three-layer data organization pattern. Bronze is append-only raw ingestion — every loan tape file, every CoreLogic property record exactly as received. It is the disaster recovery source; if a Silver transformation has a bug, you reprocess from Bronze. Silver is cleaned, validated, conformed data: standardized field names (e.g., MISMO field codes mapped to business names), null imputation rules applied, duplicates removed, reference data joined. Gold is ML-ready: pre-aggregated, feature-engineered, partitioned by observation date for point-in-time retrieval. Some teams add a Platinum layer for model outputs stored as data (default scores, prepayment predictions) which then feed downstream analytics and risk reports.

**Q10: How would you use DuckDB in a lakehouse-based ML workflow?**

A: DuckDB is the right tool for the first 80% of data exploration and feature prototyping. A data scientist can run DuckDB locally against Delta Lake Parquet files in S3 — with the Delta extension — without spinning up a Spark cluster. Queries that take 30 seconds in DuckDB on a sample dataset take 30 minutes in Spark on the full dataset; you want to validate logic cheaply first. DuckDB also excels at reading multiple Parquet files with glob patterns, which is typical for partitioned lakehouse tables. Once feature logic is validated in DuckDB, it gets promoted to a PySpark/dbt job that runs on the full historical dataset. The key limitation is scale: DuckDB is single-node, so it handles gigabytes, not terabytes. It cannot replace Spark for full production feature pipelines.

---

## Pro Tips

- **Never modify Bronze.** Treat Bronze tables as append-only, immutable records. Any transformation error in Silver or Gold can be reprocessed from Bronze. If you allow modifications to Bronze, you lose your authoritative source.

- **Partition Gold feature tables by observation date, not by loan_id.** ML training jobs scan all loans for a given date range; partition pruning on date outperforms partition pruning on loan_id by orders of magnitude for this access pattern.

- **Use Delta Lake's `OPTIMIZE ZORDER BY`** on columns used in WHERE clauses (credit_score, current_ltv) to enable data skipping on non-partition columns — critical for interactive feature exploration queries.

- **Record Delta table versions in MLflow.** Every MLflow run should log the Delta table path and version number used for training. This costs nothing and makes model reproducibility trivial: `spark.read.format("delta").option("versionAsOf", mlflow.get_run(run_id).data.params["data_version"])`.

- **In Snowflake shops, start with Iceberg over Delta Lake** for new lakehouse tables to avoid vendor lock-in. Snowflake has first-class Iceberg support; Delta Lake requires the Delta Kernel library, which is less mature in Snowflake as of 2025.

- **Schema evolution is not free.** Adding a nullable column to a Silver table is safe. Renaming a column, changing a type, or removing a column will break downstream Gold queries silently if you do not have data contracts (Great Expectations, dbt tests) between layers.

- **For MRM (Model Risk Management) documentation**, the lakehouse lineage graph is your evidence. Unity Catalog or Iceberg REST catalog lineage gives you a DAG from raw source file to training feature to model output — auditors and validators want this for SR 11-7 compliance.
