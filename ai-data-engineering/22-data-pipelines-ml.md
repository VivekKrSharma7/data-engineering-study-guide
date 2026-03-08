# Data Pipelines for ML Training & Inference
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

Machine learning pipelines extend traditional ETL by adding concerns unique to model development: reproducible data splits, feature versioning, training dataset construction, and inference serving. For a senior data engineer in the US secondary mortgage market — where prepayment models, credit risk scoring, and loan-level analytics drive business decisions — understanding how to build, orchestrate, and maintain these pipelines is increasingly central to the role.

This guide covers the full lifecycle from raw data ingestion through batch and real-time inference, with specific attention to Snowflake, SQL Server, dbt, and Apache Airflow tooling already common in mortgage data stacks.

---

## ML Pipeline vs. Traditional ETL Pipeline

| Dimension | Traditional ETL | ML Pipeline |
|---|---|---|
| Output | Dimensional tables, reports | Trained model artifact, feature dataset |
| Reproducibility | Row-level lineage | Dataset version + code version + model version |
| Failure semantics | Idempotent load | Re-training may produce different results |
| Data contract | Schema-enforced at load | Schema must match training distribution at inference |
| Monitoring | Row counts, nulls, latency | Data drift, feature drift, label drift |
| Cadence | Daily/hourly loads | Training (weekly/monthly) + inference (daily/real-time) |
| Tooling | SSIS, dbt, Informatica | Airflow + MLflow + Snowpark ML |

The critical difference: **in ML pipelines, the data itself is part of the model**. A stale or drifted feature breaks inference silently — the pipeline succeeds but the model produces garbage predictions.

---

## Key Concepts

### Training Data Pipeline

The training pipeline transforms raw operational data into a labeled, versioned dataset ready for model fitting.

```
Raw Data Sources
  → Data Lake / Snowflake Raw Layer
  → Cleaning & Validation
  → Feature Engineering
  → Train/Validation/Test Split
  → Feature Store (or versioned parquet)
  → Model Training
  → Model Registry (MLflow)
```

**Stages in detail:**

1. **Raw ingestion** — Loan origination data, servicer tapes, agency MBS data, rate sheets land in the raw layer. No transformations; exact copy of source.
2. **Cleaning** — Null imputation, outlier capping, type coercion. Critical: document every imputation rule as it affects feature distributions.
3. **Feature engineering** — Domain-specific transformations: LTV bands, coupon-to-market-rate spreads, seasoning buckets, burnout indicators.
4. **Label construction** — For prepayment: was loan prepaid in next 3 months? Binary label from servicer tape history.
5. **Dataset versioning** — Snapshot the feature matrix with a version tag tied to the training run.

### Inference Pipeline

```
New Loan Data (trigger: daily batch or API call)
  → Feature Computation (same logic as training)
  → Feature Validation (schema + range checks)
  → Model Load (from registry)
  → Prediction Generation
  → Prediction Storage (Snowflake scoring table)
  → Downstream consumers (risk dashboards, hedging systems)
```

**The inference pipeline must be a strict subset of the training pipeline's feature logic.** Any deviation creates training-serving skew.

### Batch Inference vs. Real-Time Inference

| Attribute | Batch | Real-Time |
|---|---|---|
| Trigger | Schedule (cron/Airflow) | API call / Kafka event |
| Latency tolerance | Minutes to hours | < 100ms |
| Throughput | Millions of rows | Hundreds to thousands RPS |
| Feature source | Data warehouse tables | Online feature store |
| Use case (mortgage) | Daily portfolio prepayment scoring | Instant fraud check on new application |
| Infrastructure | Snowflake Tasks, Spark, SQL | FastAPI, Triton, Snowflake Snowpark |

---

## Data Versioning for ML

### DVC (Data Version Control)

DVC tracks large data files in Git-compatible fashion, storing pointers in the repo and actual data in remote storage (S3, Azure Blob, GCS).

```bash
# Initialize DVC in a project
dvc init
dvc remote add -d mortgage_data s3://mortgage-ml-data/dvc-cache

# Track a training dataset
dvc add data/training/loan_features_v20250301.parquet
git add data/training/loan_features_v20250301.parquet.dvc .gitignore
git commit -m "Add training dataset v20250301"

# Reproduce a past training run with exact data
git checkout v1.3.0
dvc pull
python train.py
```

### Delta Lake Time Travel

```python
# PySpark / Databricks: read training data as of a specific date
df = spark.read.format("delta") \
    .option("timestampAsOf", "2025-03-01 00:00:00") \
    .load("s3://mortgage-data/silver/loan_features")

# Or by version number
df = spark.read.format("delta") \
    .option("versionAsOf", 42) \
    .load("s3://mortgage-data/silver/loan_features")
```

### Snowflake Time Travel

```sql
-- Reconstruct training dataset as it existed on a past date
CREATE OR REPLACE TABLE ml_training.loan_features_v20250301 AS
SELECT *
FROM    analytics.loan_features
AT      (TIMESTAMP => '2025-03-01 00:00:00'::TIMESTAMP_TZ);

-- Query using offset in seconds (max 90 days on Enterprise tier)
SELECT * FROM analytics.loan_features
AT (OFFSET => -3600 * 24 * 7);  -- 7 days ago
```

---

## Schema Management for ML Features

Schema evolution is dangerous in ML because adding, removing, or renaming features silently breaks inference.

```python
# Use Pandera for schema validation at pipeline entry/exit
import pandera as pa
from pandera import Column, DataFrameSchema, Check

loan_feature_schema = DataFrameSchema({
    "loan_id":          Column(str,   nullable=False),
    "current_ltv":      Column(float, Check.between(0, 200)),
    "coupon_spread":    Column(float, Check.between(-5, 15)),
    "seasoning_months": Column(int,   Check.ge(0)),
    "fico_at_orig":     Column(int,   Check.between(300, 850)),
    "prepay_label":     Column(int,   Check.isin([0, 1]), nullable=True),
})

# Validate at training time
validated_df = loan_feature_schema.validate(df, lazy=True)
```

**Schema governance rules for ML features:**
- New optional features: add with a default value; do not break existing inference runs.
- Renamed features: maintain both old and new columns for one release cycle.
- Removed features: deprecate for two training cycles before dropping.
- Track schema changes in your model registry (MLflow) alongside model versions.

---

## Handling Class Imbalance in Pipelines

Prepayment and default events are rare relative to the performing loan population. A portfolio of 100,000 loans may have 2,000 prepayments in a quarter — a 2% positive rate.

```python
from sklearn.utils import resample
from imblearn.over_sampling import SMOTE
import pandas as pd

# Option 1: Undersampling majority class
df_majority = df[df.prepay_label == 0]
df_minority = df[df.prepay_label == 1]

df_majority_downsampled = resample(
    df_majority,
    replace=False,
    n_samples=len(df_minority) * 5,  # 5:1 ratio
    random_state=42
)
df_balanced = pd.concat([df_majority_downsampled, df_minority])

# Option 2: SMOTE oversampling (only on training set, never test set)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)

smote = SMOTE(sampling_strategy=0.2, random_state=42)
X_train_resampled, y_train_resampled = smote.fit_resample(X_train, y_train)

# Option 3: Class weights in the model (often preferred — no synthetic data)
from sklearn.ensemble import GradientBoostingClassifier
model = GradientBoostingClassifier(
    class_weight={0: 1, 1: 10}  # Penalize missing prepayment events more
)
```

**Pipeline rule:** Apply resampling only to the training split. Test and validation sets must reflect the true population distribution to give honest performance estimates.

---

## Orchestrating ML Pipelines

### Apache Airflow DAG — ML Training Pipeline

```python
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.snowflake.operators.snowflake import SnowflakeOperator

default_args = {
    "owner": "data-engineering",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=10),
    "email_on_failure": True,
    "email": ["de-alerts@company.com"],
}

with DAG(
    dag_id="prepayment_model_training",
    default_args=default_args,
    start_date=datetime(2025, 1, 1),
    schedule_interval="0 2 * * 1",  # Every Monday at 2 AM
    catchup=False,
    tags=["ml", "prepayment", "training"],
) as dag:

    # Step 1: Extract and validate raw servicer tape data
    validate_source_data = SnowflakeOperator(
        task_id="validate_source_data",
        snowflake_conn_id="snowflake_prod",
        sql="""
            SELECT  COUNT(*) AS row_count,
                    COUNT(DISTINCT loan_id) AS unique_loans,
                    MAX(report_date) AS latest_tape
            FROM    raw.servicer_tapes
            WHERE   report_date >= DATEADD('month', -3, CURRENT_DATE)
            HAVING  COUNT(*) > 0
        """,
    )

    # Step 2: Build feature matrix in Snowflake
    build_feature_matrix = SnowflakeOperator(
        task_id="build_feature_matrix",
        snowflake_conn_id="snowflake_prod",
        sql="""
            CREATE OR REPLACE TABLE ml_staging.prepay_features AS
            SELECT
                l.loan_id,
                l.original_balance,
                l.current_upb,
                l.coupon_rate,
                l.coupon_rate - r.current_30yr_rate   AS coupon_spread,
                DATEDIFF('month', l.origination_date,
                         CURRENT_DATE)                AS seasoning_months,
                l.current_ltv,
                l.fico_at_origination,
                l.loan_purpose,
                l.property_type,
                l.occupancy_type,
                -- Burnout proxy: how many refi opportunities passed?
                s.prior_refi_opportunities,
                -- Label: prepaid in next 90 days
                CASE WHEN p.prepay_date IS NOT NULL THEN 1 ELSE 0 END
                    AS prepay_label
            FROM    analytics.active_loans l
            JOIN    analytics.rate_history r
                ON  r.rate_date = CURRENT_DATE
            LEFT JOIN analytics.loan_prepay_events p
                ON  p.loan_id = l.loan_id
                AND p.prepay_date BETWEEN CURRENT_DATE
                    AND DATEADD('day', 90, CURRENT_DATE)
            LEFT JOIN analytics.loan_seasoning_stats s
                ON  s.loan_id = l.loan_id
        """,
    )

    # Step 3: Export features to S3 for Python training job
    def export_features_to_s3(**context):
        import snowflake.connector
        import pandas as pd
        import boto3
        import io

        conn = snowflake.connector.connect(
            user=context["var"]["value"]["sf_user"],
            password=context["var"]["value"]["sf_password"],
            account="myorg-myaccount",
            warehouse="ML_WH",
            database="MORTGAGE_DB",
            schema="ML_STAGING",
        )
        df = pd.read_sql("SELECT * FROM prepay_features", conn)
        conn.close()

        parquet_buffer = io.BytesIO()
        df.to_parquet(parquet_buffer, index=False, engine="pyarrow")
        parquet_buffer.seek(0)

        s3 = boto3.client("s3")
        run_date = context["ds_nodash"]
        s3.put_object(
            Bucket="mortgage-ml-data",
            Key=f"training/prepay_features_{run_date}.parquet",
            Body=parquet_buffer.getvalue(),
        )
        context["ti"].xcom_push(key="feature_s3_key",
                                value=f"training/prepay_features_{run_date}.parquet")

    export_features = PythonOperator(
        task_id="export_features_to_s3",
        python_callable=export_features_to_s3,
    )

    # Step 4: Train model
    def train_model(**context):
        import boto3
        import pandas as pd
        import mlflow
        import mlflow.sklearn
        from sklearn.ensemble import GradientBoostingClassifier
        from sklearn.model_selection import train_test_split
        from sklearn.metrics import roc_auc_score, average_precision_score
        from imblearn.over_sampling import SMOTE

        s3_key = context["ti"].xcom_pull(
            task_ids="export_features_to_s3", key="feature_s3_key"
        )
        s3 = boto3.client("s3")
        obj = s3.get_object(Bucket="mortgage-ml-data", Key=s3_key)
        df = pd.read_parquet(obj["Body"])

        feature_cols = [
            "original_balance", "current_upb", "coupon_spread",
            "seasoning_months", "current_ltv", "fico_at_origination",
            "prior_refi_opportunities",
        ]
        X = df[feature_cols].fillna(0)
        y = df["prepay_label"]

        X_train, X_test, y_train, y_test = train_test_split(
            X, y, test_size=0.2, stratify=y, random_state=42
        )
        smote = SMOTE(sampling_strategy=0.15, random_state=42)
        X_train_res, y_train_res = smote.fit_resample(X_train, y_train)

        mlflow.set_tracking_uri("http://mlflow.internal:5000")
        mlflow.set_experiment("prepayment_model")

        with mlflow.start_run(run_name=f"training_{context['ds_nodash']}"):
            params = {"n_estimators": 300, "max_depth": 5,
                      "learning_rate": 0.05, "subsample": 0.8}
            model = GradientBoostingClassifier(**params)
            model.fit(X_train_res, y_train_res)

            y_proba = model.predict_proba(X_test)[:, 1]
            auc = roc_auc_score(y_test, y_proba)
            ap  = average_precision_score(y_test, y_proba)

            mlflow.log_params(params)
            mlflow.log_metric("roc_auc", auc)
            mlflow.log_metric("average_precision", ap)
            mlflow.sklearn.log_model(
                model, "model",
                registered_model_name="PrepaymentModel"
            )

    train_model_task = PythonOperator(
        task_id="train_model",
        python_callable=train_model,
    )

    # DAG dependency chain
    validate_source_data >> build_feature_matrix >> export_features >> train_model_task
```

---

## ML Pipelines in Snowflake: Tasks + Snowpark ML + Streams

```sql
-- Stream captures new loans added to the staging table
CREATE OR REPLACE STREAM ml_staging.new_loans_stream
ON TABLE analytics.active_loans
    APPEND_ONLY = TRUE;

-- Snowflake Task: compute features for new loans, trigger inference
CREATE OR REPLACE TASK ml_tasks.score_new_loans
    WAREHOUSE     = COMPUTE_WH
    SCHEDULE      = 'USING CRON 0 6 * * * America/New_York'
    WHEN          SYSTEM$STREAM_HAS_DATA('ml_staging.new_loans_stream')
AS
CALL ml_inference.score_loans_sp();  -- Snowpark stored procedure
```

```python
# Snowpark ML inference stored procedure
import snowflake.snowpark as snowpark
from snowflake.ml.modeling.pipeline import Pipeline
from snowflake.snowpark.functions import col

def score_loans_sp(session: snowpark.Session) -> str:
    # Read new loans from stream
    new_loans = session.table("ML_STAGING.NEW_LOANS_STREAM")

    # Apply feature transformations
    features = new_loans.select(
        col("LOAN_ID"),
        (col("COUPON_RATE") - col("CURRENT_30YR_RATE")).alias("COUPON_SPREAD"),
        col("CURRENT_LTV"),
        col("FICO_AT_ORIGINATION"),
        col("SEASONING_MONTHS"),
    )

    # Load model from Snowflake Model Registry
    from snowflake.ml.registry import Registry
    reg = Registry(session=session)
    model = reg.get_model("PrepaymentModel").version("v3")

    # Score
    predictions = model.run(features, function_name="predict_proba")

    # Write predictions
    predictions.write.mode("append").save_as_table(
        "ML_OUTPUTS.PREPAYMENT_SCORES"
    )
    return f"Scored {predictions.count()} loans"
```

---

## dbt + Snowflake for Feature Computation

```sql
-- models/ml_features/prepay_feature_matrix.sql
{{
  config(
    materialized='table',
    post_hook=[
      "ALTER TABLE {{ this }} CLUSTER BY (report_month)",
    ],
    tags=['ml', 'prepayment']
  )
}}

WITH base_loans AS (
    SELECT * FROM {{ ref('int_active_loans') }}
    WHERE report_date = (SELECT MAX(report_date) FROM {{ ref('int_active_loans') }})
),

rate_env AS (
    SELECT current_30yr_rate
    FROM   {{ ref('stg_rate_environment') }}
    WHERE  rate_date = CURRENT_DATE
),

burnout AS (
    SELECT
        loan_id,
        COUNT(*) AS prior_refi_opportunities
    FROM   {{ ref('int_refi_windows') }}
    WHERE  loan_was_in_the_money = TRUE
    GROUP BY loan_id
)

SELECT
    l.loan_id,
    l.coupon_rate - r.current_30yr_rate   AS coupon_spread,
    l.current_ltv,
    l.fico_at_origination,
    DATEDIFF('month', l.origination_date,
             CURRENT_DATE)                AS seasoning_months,
    COALESCE(b.prior_refi_opportunities, 0) AS burnout_count,
    DATE_TRUNC('month', CURRENT_DATE)     AS report_month

FROM   base_loans l
CROSS  JOIN rate_env r
LEFT   JOIN burnout b ON b.loan_id = l.loan_id
```

```yaml
# schema.yml — contract enforcement for ML features
models:
  - name: prepay_feature_matrix
    config:
      contract:
        enforced: true
    columns:
      - name: loan_id
        data_type: varchar
        constraints:
          - type: not_null
      - name: coupon_spread
        data_type: float
        constraints:
          - type: not_null
      - name: current_ltv
        data_type: float
        tests:
          - accepted_range:
              min_value: 0
              max_value: 200
```

---

## Data Quality Checks in ML Pipelines

```python
# Great Expectations checkpoint for ML feature validation
import great_expectations as gx

context = gx.get_context()

validator = context.sources.pandas_default.read_parquet(
    "s3://mortgage-ml-data/training/prepay_features_20250301.parquet"
)

# Completeness
validator.expect_column_values_to_not_be_null("loan_id")
validator.expect_column_values_to_not_be_null("coupon_spread")

# Range checks (domain knowledge for mortgage features)
validator.expect_column_values_to_be_between("current_ltv", 0, 200)
validator.expect_column_values_to_be_between("fico_at_origination", 300, 850)
validator.expect_column_values_to_be_between("seasoning_months", 0, 600)

# Label distribution — alert if positive rate falls outside expected range
validator.expect_column_mean_to_be_between("prepay_label", 0.01, 0.15)

# No future data leakage
validator.expect_column_max_to_be_between(
    "report_date", max_value="2025-03-01"
)

results = validator.validate()
if not results["success"]:
    raise ValueError(f"Feature validation failed: {results}")
```

---

## SSIS for ML Data Prep (SQL Server)

For organizations still on SQL Server, SSIS remains a practical entry point for ML data prep before handing off to Python.

```
SSIS Package: PrepareMLTrainingData.dtsx

Control Flow:
  [Execute SQL: Validate source freshness]
  → [Data Flow: Extract loan features]
      Source: OLE DB (SQL Server)
      Transforms:
        - Derived Column: compute coupon_spread, seasoning
        - Conditional Split: train/test split (hash on loan_id)
        - Data Conversion: cast to correct types
      Destination: Flat File (CSV) → S3 upload via Script Task
  → [Script Task: Invoke Python training script]
  → [Execute SQL: Log run metadata to audit table]
```

SQL for the SSIS source query:
```sql
SELECT
    loan_id,
    coupon_rate - (SELECT TOP 1 rate_30yr
                   FROM   dbo.rate_environment
                   ORDER  BY rate_date DESC)            AS coupon_spread,
    current_ltv,
    fico_at_origination,
    DATEDIFF(MONTH, origination_date, GETDATE())        AS seasoning_months,
    CASE WHEN ABS(CHECKSUM(NEWID())) % 10 < 8
         THEN 'TRAIN' ELSE 'TEST' END                  AS split_flag
FROM   dbo.active_loans
WHERE  loan_status = 'CURRENT'
  AND  report_date = CAST(GETDATE() AS DATE)
```

---

## Monitoring Training Data Freshness

```python
# Airflow sensor: wait for servicer tape to land before training
from airflow.sensors.sql import SqlSensor

wait_for_servicer_tape = SqlSensor(
    task_id="wait_for_servicer_tape",
    conn_id="snowflake_prod",
    sql="""
        SELECT COUNT(*)
        FROM   raw.servicer_tapes
        WHERE  report_date = CURRENT_DATE
          AND  row_count   > 10000
    """,
    poke_interval=300,    # Check every 5 minutes
    timeout=3600 * 6,     # Fail after 6 hours
    mode="reschedule",
)
```

---

## Interview Q&A

**Q1: How does an ML pipeline differ from a traditional ETL pipeline, and what new failure modes does it introduce?**

Traditional ETL produces deterministic, schema-conforming output: given the same input, you get the same rows in the destination. Failure modes are operational — connectivity, constraint violations, row count drops.

ML pipelines introduce statistical failure modes. The pipeline can execute successfully (no errors, no null constraint violations) while producing a useless model or wrong predictions. Specific new failure modes include:

- **Training-serving skew**: feature computation logic diverges between training and inference, so the model sees different distributions at serve time.
- **Label leakage**: future information bleeds into features (e.g., including post-origination servicer data when training a model that must score at origination).
- **Distribution shift**: the population changes after training (rate environment shift, underwriting guideline change) but the model is not retrained.
- **Silent imputation drift**: a null-fill rule that was applied differently between training and scoring.

The answer is observability: log feature distributions at both training and inference time and compare them with statistical tests (KS test, PSI).

---

**Q2: Describe how you would implement data versioning for an ML pipeline in Snowflake.**

Snowflake Time Travel is the primary mechanism. For training datasets:

1. After building the feature matrix, tag it with a snapshot timestamp and record that timestamp in the MLflow run's parameters.
2. Use `CREATE TABLE AS SELECT ... AT (TIMESTAMP => ...)` to reconstruct exact training data for any past run.
3. Supplement with Zero-Copy Cloning to create cheap named snapshots: `CREATE TABLE ml_training.features_v20250301 CLONE analytics.loan_features;`
4. For long-term retention beyond the 90-day Time Travel window, persist training datasets as Parquet files in cloud storage tracked by DVC, with the S3 path logged as an MLflow artifact.

This gives you: exact reproducibility within 90 days via Time Travel, long-term reproducibility via DVC + Parquet, and auditability via MLflow run parameters.

---

**Q3: A data scientist reports that the prepayment model's AUC dropped from 0.82 to 0.71 between last quarter and this quarter. How do you diagnose whether it's a data problem or a model problem?**

Step 1 — Isolate the time dimension: Run the old model against new data. If AUC is still low, the issue is data drift or distribution shift, not the model. If AUC recovers, it may be a training data quality issue in the new run.

Step 2 — Feature distribution analysis: Compare feature distributions between the training period and the current scoring period using Population Stability Index (PSI). PSI > 0.25 on any feature indicates severe drift. Look specifically at coupon_spread (rate environment change), current_ltv (home price movement), and fico_at_origination (guideline changes).

Step 3 — Label rate check: Has the actual prepayment rate changed significantly? A sudden rate drop (or spike) changes the base rate and can distort AUC even if features are stable.

Step 4 — Pipeline audit: Check whether any upstream transformation changed — new source system, modified SQL, changed null handling.

Step 5 — Segment analysis: Break AUC down by loan purpose (refi vs. purchase), property type, origination vintage. A drop in one segment narrows root cause quickly.

---

**Q4: How do you prevent training-serving skew in a Snowflake-based ML pipeline?**

The root cause of training-serving skew is maintaining two separate codebases for feature computation — one in the training pipeline and one in the inference pipeline.

The solution is a single source of truth for feature logic:

1. Define all features as dbt models. The dbt model is the authoritative feature definition.
2. At training time, run the dbt model against historical data to build the training set.
3. At inference time, run the same dbt model against current data to build the scoring input.
4. Never reimplement feature logic in Python for inference if it can be expressed in SQL and run in Snowflake.

For features that must be computed in Python (e.g., rolling statistics requiring pandas), package the computation in a versioned Python function, use that same function in both the training DAG and the inference DAG, and pin the function version in the model's MLflow metadata.

---

**Q5: Walk me through handling class imbalance for a prepayment model with a 2% positive rate.**

First, understand the business objective. For prepayment prediction, precision-recall tradeoff matters more than accuracy. We care about correctly identifying the loans that will prepay (recall) while not flooding the hedging desk with false positives (precision). AUC-PR (average precision) is therefore a better metric than ROC-AUC for tuning.

Handling options in order of preference:

1. **Class weights** (preferred): Set `class_weight='balanced'` or manually set `{0:1, 1:50}` in sklearn/XGBoost. No synthetic data, no risk of SMOTE artifacts, works natively with gradient boosting.
2. **Threshold tuning**: Train on natural distribution, then tune the classification threshold on a validation set to hit a target precision or recall.
3. **Undersampling**: Randomly drop majority class loans. Faster training. Risk: discards real signal in the majority.
4. **SMOTE**: Synthesize minority class samples by interpolating between nearest neighbors. Apply only to the training split. Never apply to the test set.

In the pipeline, enforce the rule: resampling happens after the train/test split, inside the training job, never at the dataset construction stage. This ensures the test set remains representative of the true population.

---

**Q6: How would you orchestrate a monthly model retraining pipeline using Airflow with proper dependency management?**

Key design decisions:

1. **Sensor-first pattern**: The DAG starts with a `SqlSensor` waiting for the servicer tape to land before any processing begins.
2. **Idempotency**: Every task should be idempotent. SQL tasks use `CREATE OR REPLACE TABLE`. Python tasks write to date-partitioned S3 keys.
3. **XCom for lightweight handoffs**: Pass S3 keys and MLflow run IDs between tasks via XCom, not file paths on local disk.
4. **Conditional promotion**: After training, a `BranchPythonOperator` checks whether the new model beats the champion model on a holdout set. Only if AUC improves by at least 1% does the pipeline promote the model to Production in MLflow.
5. **Alerting**: `on_failure_callback` sends Slack/PagerDuty alerts for any task failure. The training task also sends a summary email with key metrics on success.
6. **Data quality gate**: A `GreatExpectationsOperator` runs schema and range validation on the feature matrix before training begins. Failure here stops the pipeline before wasting compute.

---

**Q7: How does Snowflake Stream + Task architecture compare to Airflow for ML pipeline orchestration?**

| Concern | Snowflake Stream + Task | Apache Airflow |
|---|---|---|
| Trigger | Data-driven (stream has data) | Time-driven or sensor |
| Complexity | Low (SQL + stored procedures) | High (Python DAGs) |
| Cross-system coordination | Poor (Snowflake-only) | Excellent |
| Visibility | Snowflake query history | Full DAG UI, logs, XCom |
| Retry logic | Limited | Sophisticated |
| Cost | Snowflake compute credits | Airflow infra + compute |

Recommendation: Use Snowflake Tasks for lightweight, in-database feature computation and scoring where the entire pipeline lives in Snowflake. Use Airflow when the pipeline spans multiple systems (S3, Python training, MLflow, notification systems). In practice, a hybrid is common: Airflow orchestrates the macro flow, calling Snowflake stored procedures for SQL-heavy steps and Python operators for training.

---

**Q8: What data quality checks should you implement specifically for ML training data that you would not implement in a standard ETL pipeline?**

Beyond standard completeness and referential integrity checks:

1. **Feature distribution range checks**: Validate that each feature falls within the historically observed range. A coupon_spread of 15% should trigger an alert — it could be a data issue or a genuine market anomaly worth investigating.
2. **Label rate check**: Assert that the positive rate (prepay_label = 1) falls within an expected historical range, e.g., 1%–10%. A label rate of 50% usually means a join gone wrong.
3. **Feature correlation stability**: For critical feature pairs, compute Pearson correlation and alert if it deviates significantly from the historical baseline. A sudden decorrelation between coupon_spread and prepayment_rate suggests a feature pipeline bug.
4. **No future leakage**: Validate that features computed from event data (e.g., actual disposition dates) are not present for loans whose as-of date predates the event.
5. **Train/test leakage**: Verify that no loan_id appears in both training and test splits.
6. **Minimum sample size per class**: Assert that the minority class (prepayments) has at least 1,000 observations. Below this, the model is likely to be unstable.

---

**Q9: How would you use dbt to compute ML features and ensure those features are consistent between training and inference?**

Structure the dbt project with a dedicated `ml_features` layer that sits between the analytics/mart layer and the ML consumers:

```
staging → intermediate → analytics → ml_features → [training job / inference job]
```

The `ml_features` models:
- Are materialized as tables with `contract: enforced: true` to catch schema changes.
- Include `dbt test` assertions for all business-logic constraints (range checks, null checks).
- Are tagged `ml` and run on the same schedule as both training and inference pipelines.
- Include an `as_of_date` parameter via `dbt vars` so you can backfill historical training data: `dbt run --select tag:ml --vars '{"as_of_date": "2024-01-01"}'`

For inference, the Airflow DAG runs `dbt run --select tag:ml` before invoking the scoring job. For training, it runs `dbt run --select tag:ml --vars '{"as_of_date": "..."}'` for each historical month. Same SQL, same tests, same output schema — skew is structurally prevented.

---

## Pro Tips

1. **Log feature statistics, not just model metrics.** For every training run, compute and log mean, stddev, min, max for every feature. Store these in MLflow as artifacts. At inference time, compare the current scoring batch's feature stats against the training stats and alert if PSI exceeds threshold.

2. **Treat your feature SQL as a first-class artifact.** Hash the dbt model SQL and log that hash as an MLflow parameter. If you retrain and the feature SQL hasn't changed, you can skip rebuilding the feature matrix and reuse the cached version.

3. **Separate the retraining trigger from the scoring trigger.** Scoring runs daily. Retraining runs monthly (or when data drift is detected). Conflating these creates a fragile pipeline that retrains every day unnecessarily.

4. **Time Travel is not a substitute for versioning.** Snowflake Time Travel has a 90-day maximum. For model auditability in a regulated industry (mortgage), you need training datasets persisted for 3–7 years. Always archive training datasets to cold storage (S3 Glacier) on every training run.

5. **The holdout set is sacred.** Never use the test set to make any modeling decisions (hyperparameters, feature selection, threshold). Use a validation set for those decisions. Keep the test set locked until final evaluation. In mortgage modeling, a time-based holdout (most recent 6 months as test) is more realistic than random split.

6. **In Snowflake, use Zero-Copy Cloning for training dataset snapshots.** It costs nothing in storage until you modify the clone. It's instant. And it gives you a named, queryable snapshot with full SQL access — far more useful than a Parquet file when you need to investigate anomalies in a past training run.
