# Data Versioning & DVC for ML
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

Reproducing an ML model trained six months ago is surprisingly hard. You need the exact training data (which may have been overwritten by updates), the exact code (which may have changed), the exact hyperparameters (which may only exist in someone's notebook), and the exact library versions (which may have been upgraded). Without systematic versioning, every model is a snowflake — impossible to reproduce, impossible to audit, and impossible to validate under SR 11-7.

This guide covers the full data versioning stack: DVC for file-level versioning of datasets and models, Snowflake Time Travel for table-level snapshots, Delta Lake for lakehouse time travel, SQL Server temporal tables for operational data lineage, and MLflow for model registry versioning. For a data engineer in the secondary mortgage market who regularly needs to reproduce training runs for model validation, these tools are not optional — they are infrastructure.

---

## Key Concepts

| Term | Definition |
|---|---|
| Data versioning | Tracking specific versions of datasets so they can be retrieved exactly as they were at a point in time |
| Reproducibility | Given the same code + same data + same environment, you get the same model |
| DVC | Data Version Control — Git extension for versioning large files (datasets, models) |
| Time Travel | Querying a table as it existed at a past timestamp (Snowflake, Delta Lake) |
| Temporal tables | SQL Server system-versioned tables that automatically track row history |
| Data lineage | The documented path from raw source data to model input features |
| MLflow Model Registry | Central repository for versioned, staged ML models |
| OpenLineage | Open standard for capturing data lineage metadata across pipelines |

---

## Why Data Versioning Is Critical for ML Reproducibility

### The Reproducibility Problem

```
Scenario: January 2026 model validation review

Validator: "Can you retrain the prepayment model as of August 2025
            to verify the validation report findings?"

Data Engineer without versioning:
  ├── Training data: overwritten by monthly refresh — GONE
  ├── Feature engineering code: refactored in October — CHANGED
  ├── Library versions: scikit-learn upgraded from 1.3 to 1.4 — DIFFERENT
  └── Answer: "We can't reproduce it exactly."

Data Engineer with versioning:
  ├── Training data: DVC tag 'prepay-model-v3-train' → S3 snapshot — EXACT
  ├── Code: Git commit hash abc1234 → exact state of repo — EXACT
  ├── Dependencies: requirements.txt at that commit — EXACT
  └── Answer: "dvc repro --rev prepay-model-v3-train"
```

### Regulatory Requirement

Under SR 11-7, model validators must be able to replicate model development findings. If a validator cannot reproduce the training run, the model's validation is incomplete. Data versioning is the infrastructure that makes reproducibility possible.

---

## Data Versioning Strategies

### Decision Framework

```
What are you versioning?
  │
  ├── Files/blobs (Parquet, CSV, model artifacts)
  │     └── Use DVC → tracked in Git, stored in S3/Azure Blob/GCS
  │
  ├── Tables in Snowflake
  │     ├── Need to query past state    → Snowflake Time Travel
  │     └── Need permanent snapshot     → CLONE with timestamp
  │
  ├── Tables in Delta Lake / Databricks
  │     └── Delta Time Travel (VERSION AS OF / TIMESTAMP AS OF)
  │
  ├── Operational/transactional data (SQL Server)
  │     └── SQL Server Temporal Tables (system-versioned)
  │
  └── Trained models
        └── MLflow Model Registry (versions + stage transitions)
```

---

## DVC — Data Version Control

### Architecture

DVC separates code from data. Git tracks code and tiny `.dvc` pointer files. The actual data (which can be gigabytes) is stored in a remote (S3, Azure Blob, GCS, SFTP). Anyone with access to both the Git repo and the DVC remote can reproduce any historical state.

```
Git Repository
  ├── src/
  │     ├── train.py
  │     └── features.py
  ├── dvc.yaml                ← pipeline definition
  ├── dvc.lock                ← locked hashes of all pipeline outputs
  ├── data/
  │     └── mortgage_train.dvc   ← pointer: {md5: abc123, size: 2.1GB}
  └── models/
        └── prepay_model.pkl.dvc ← pointer: {md5: def456, size: 45MB}

DVC Remote (S3)
  └── s3://bucket/dvc-cache/
        ├── ab/c123...   ← actual mortgage_train.parquet
        └── de/f456...   ← actual prepay_model.pkl
```

### DVC Setup and Basic Workflow

```bash
# Install DVC with S3 support
pip install "dvc[s3]"

# Initialize DVC in an existing Git repo
cd /path/to/mortgage-model-repo
dvc init
git commit -m "Initialize DVC"

# Configure S3 remote storage
dvc remote add -d prod-s3 s3://my-bucket/dvc-store
dvc remote modify prod-s3 region us-east-1
git commit .dvc/config -m "Configure S3 DVC remote"

# Track a large training dataset
dvc add data/mortgage_train_2024q3.parquet
# DVC creates data/mortgage_train_2024q3.parquet.dvc
git add data/mortgage_train_2024q3.parquet.dvc .gitignore
git commit -m "Add Q3 2024 mortgage training dataset"

# Push data to S3 remote
dvc push

# Later: pull data on another machine or in CI/CD
git clone <repo-url>
dvc pull   # downloads the exact dataset referenced by current Git commit
```

### DVC Pipelines

DVC pipelines define ML workflows as dependency graphs. Each stage specifies its inputs (`deps`), outputs (`outs`), and command. DVC tracks which stages are stale and only reruns what has changed.

```yaml
# dvc.yaml — ML pipeline for mortgage prepayment model
stages:
  extract_features:
    cmd: python src/extract_features.py
      --start-date 2022-01-01
      --end-date   2024-09-30
      --output     data/features/mortgage_features.parquet
    deps:
      - src/extract_features.py
      - src/feature_definitions.py
    outs:
      - data/features/mortgage_features.parquet
    params:
      - params.yaml:
          - feature_extraction.start_date
          - feature_extraction.end_date

  train_model:
    cmd: python src/train.py
      --features data/features/mortgage_features.parquet
      --output   models/prepay_model_v4.pkl
    deps:
      - src/train.py
      - data/features/mortgage_features.parquet
    outs:
      - models/prepay_model_v4.pkl
    metrics:
      - metrics/train_metrics.json:
          cache: false
    params:
      - params.yaml:
          - model.n_estimators
          - model.max_depth
          - model.learning_rate

  evaluate_model:
    cmd: python src/evaluate.py
      --model   models/prepay_model_v4.pkl
      --holdout data/features/holdout_2024q4.parquet
      --output  metrics/eval_metrics.json
    deps:
      - src/evaluate.py
      - models/prepay_model_v4.pkl
      - data/features/holdout_2024q4.parquet
    metrics:
      - metrics/eval_metrics.json:
          cache: false
```

```bash
# Run the full pipeline (only reruns stale stages)
dvc repro

# Reproduce the pipeline at a specific Git tag
git checkout prepay-model-v3-release
dvc repro

# Compare metrics between two experiments
dvc metrics diff main prepay-model-v3-release
```

### DVC Experiments

DVC experiments are lightweight branches for hyperparameter exploration without creating Git commits for each run.

```bash
# Run an experiment with modified params
dvc exp run --set-param model.n_estimators=200 --set-param model.learning_rate=0.05

# List all experiments
dvc exp show

# Compare experiments in a table
dvc exp show --md   # Markdown table output

# Promote the best experiment to a Git branch
dvc exp branch best-experiment-id prepay-v4-candidate
```

---

## Snowflake Time Travel

Snowflake retains historical data for up to 90 days (default 1 day, configurable up to 90 for Enterprise edition). This enables querying any table as it existed at a past point in time — essential for reproducing training datasets.

### Querying Historical Data

```sql
-- Query the feature table as it existed at a specific timestamp
-- Use case: reproduce the exact training dataset used for a model in August 2025
SELECT *
FROM ml_features.mortgage_scoring_features
AT (TIMESTAMP => '2025-08-15 06:00:00'::TIMESTAMP_NTZ);

-- Query using a time offset (e.g., 7 days ago)
SELECT *
FROM ml_features.mortgage_scoring_features
AT (OFFSET => -7 * 24 * 60 * 60);  -- offset in seconds

-- Query using a statement ID (most precise: exact state after a specific DML)
SELECT *
FROM ml_features.mortgage_scoring_features
AT (STATEMENT => '01a2b3c4-0000-0001-0000-00000001');
```

### Creating a Permanent Training Snapshot

Snowflake Time Travel is temporary (up to 90 days). For permanent dataset preservation, clone the table at a timestamp:

```sql
-- Create a permanent clone of the training dataset at a specific point in time
-- Zero-copy clone: no data duplication, instant, only stores changes going forward
CREATE OR REPLACE TABLE ml_features.mortgage_train_2025q3_snapshot
    CLONE ml_features.mortgage_scoring_features
    AT (TIMESTAMP => '2025-09-30 23:59:59'::TIMESTAMP_NTZ);

-- Tag the snapshot with metadata
ALTER TABLE ml_features.mortgage_train_2025q3_snapshot
    SET COMMENT = 'Training snapshot for prepayment_model_v4.
                   Created for SR 11-7 validation.
                   Git ref: abc1234.
                   Row count: 4,821,063.
                   Date range: 2022-01-01 to 2025-09-30.';

-- Query the snapshot for reproducibility verification
SELECT
    COUNT(*)                           AS row_count,
    MIN(origination_date)              AS min_date,
    MAX(origination_date)              AS max_date,
    AVG(fico_score)                    AS avg_fico,
    AVG(ltv_ratio)                     AS avg_ltv
FROM ml_features.mortgage_train_2025q3_snapshot;
```

### Managing Training Dataset Inventory in Snowflake

```sql
-- Dataset registry table: every training run references a registered dataset
CREATE TABLE ml_ops.training_dataset_registry (
    dataset_id          VARCHAR(50) PRIMARY KEY,
    dataset_name        VARCHAR(200),
    source_table        VARCHAR(500),
    snapshot_table      VARCHAR(500),
    snapshot_timestamp  TIMESTAMP_NTZ,
    row_count           INTEGER,
    feature_count       INTEGER,
    date_range_start    DATE,
    date_range_end      DATE,
    created_by          VARCHAR(100),
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    model_version       VARCHAR(50),
    git_commit_hash     VARCHAR(40),
    notes               VARCHAR(2000)
);

-- Register a new training dataset snapshot
INSERT INTO ml_ops.training_dataset_registry VALUES (
    'MPPV4-TRAIN-2025Q3',
    'Mortgage Prepayment Model v4 Training Set',
    'ml_features.mortgage_scoring_features',
    'ml_features.mortgage_train_2025q3_snapshot',
    '2025-09-30 23:59:59',
    4821063,
    47,
    '2022-01-01',
    '2025-09-30',
    'data_engineering_team',
    CURRENT_TIMESTAMP(),
    'prepayment_v4',
    'abc1234def5678',
    'Q3 2025 training dataset. Excludes COVID forbearance loans (2020-03 to 2021-06).'
);
```

---

## Delta Lake Time Travel

Delta Lake stores transaction logs (the `_delta_log` directory) that record every write operation. This enables time travel by replaying the log to any past version.

```sql
-- PySpark / Databricks SQL syntax

-- Query by version number
SELECT * FROM mortgage_features VERSION AS OF 42;

-- Query by timestamp
SELECT * FROM mortgage_features TIMESTAMP AS OF '2025-08-15 06:00:00';

-- View the transaction history
DESCRIBE HISTORY mortgage_features;
-- Returns: version, timestamp, operation, operationParameters, readVersion

-- Restore a table to a previous version
RESTORE TABLE mortgage_features TO VERSION AS OF 42;
RESTORE TABLE mortgage_features TO TIMESTAMP AS OF '2025-08-15 06:00:00';
```

```python
# PySpark: read a specific Delta version for training
from delta.tables import DeltaTable
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("MortgageModel").getOrCreate()

# Read the exact version used for the August 2025 training run
training_df = (
    spark.read.format("delta")
    .option("versionAsOf", 42)
    .load("abfss://datalake@storage.dfs.core.windows.net/mortgage_features")
)

# Or by timestamp
training_df = (
    spark.read.format("delta")
    .option("timestampAsOf", "2025-08-15T06:00:00.000Z")
    .load("abfss://datalake@storage.dfs.core.windows.net/mortgage_features")
)
```

---

## SQL Server Temporal Tables

System-versioned temporal tables in SQL Server (2016+) automatically maintain a full row history in a paired history table. Every UPDATE or DELETE creates a record in the history table with `ValidFrom` and `ValidTo` timestamps.

```sql
-- Create a system-versioned temporal table for loan feature snapshots
CREATE TABLE dbo.LoanFeatureSnapshots (
    LoanID              VARCHAR(20)     NOT NULL,
    FicoScore           SMALLINT,
    LtvRatio            DECIMAL(5,2),
    DtiRatio            DECIMAL(5,2),
    CurrentBalance      MONEY,
    DelinquencyStatus   TINYINT,
    LastUpdatedBy       VARCHAR(100),
    -- System-period columns (populated and maintained by SQL Server)
    ValidFrom           DATETIME2       GENERATED ALWAYS AS ROW START  NOT NULL,
    ValidTo             DATETIME2       GENERATED ALWAYS AS ROW END    NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo),
    PRIMARY KEY (LoanID)
)
WITH (SYSTEM_VERSIONING = ON (
    HISTORY_TABLE = dbo.LoanFeatureSnapshotsHistory,
    DATA_CONSISTENCY_CHECK = ON
));

-- Query the table as it appeared at a specific point in time
-- Use case: reconstruct features as of model training date
SELECT
    LoanID,
    FicoScore,
    LtvRatio,
    DtiRatio,
    CurrentBalance,
    DelinquencyStatus
FROM dbo.LoanFeatureSnapshots
FOR SYSTEM_TIME AS OF '2025-08-15T06:00:00.000'
WHERE LoanID IN (SELECT LoanID FROM dbo.ModelTrainingCohort_2025Q3);

-- View the full history for a specific loan
SELECT
    LoanID,
    FicoScore,
    LtvRatio,
    ValidFrom,
    ValidTo
FROM dbo.LoanFeatureSnapshotsHistory
WHERE LoanID = 'LOAN-12345'
ORDER BY ValidFrom;
```

---

## Model Versioning with MLflow Model Registry

DVC handles data and pipeline versioning; MLflow handles model artifact versioning and promotion workflows.

```python
import mlflow
import mlflow.sklearn
from mlflow.tracking import MlflowClient

mlflow.set_tracking_uri("https://mlflow.internal.company.com")
mlflow.set_experiment("mortgage-prepayment-model")

# Training run with full versioning metadata
with mlflow.start_run(run_name="prepay_v4_q3_2025") as run:
    # Log dataset provenance
    mlflow.log_param("training_dataset_id", "MPPV4-TRAIN-2025Q3")
    mlflow.log_param("git_commit",           "abc1234def5678")
    mlflow.log_param("snowflake_snapshot",   "ml_features.mortgage_train_2025q3_snapshot")
    mlflow.log_param("n_estimators",         200)
    mlflow.log_param("max_depth",            6)
    mlflow.log_param("learning_rate",        0.05)

    # Train model (abbreviated)
    model = train_prepayment_model(training_df, params)

    # Log metrics
    mlflow.log_metric("train_auc",    0.8821)
    mlflow.log_metric("oot_auc",      0.8743)
    mlflow.log_metric("train_gini",   0.7642)
    mlflow.log_metric("oot_gini",     0.7486)

    # Log model artifact
    mlflow.sklearn.log_model(
        sk_model=model,
        artifact_path="prepay_model",
        registered_model_name="mortgage-prepayment-model",
        input_example=training_df.sample(5),
        signature=mlflow.models.infer_signature(training_df, model.predict(training_df))
    )

    run_id = run.info.run_id
    print(f"Run ID: {run_id}")

# Promote model through staging workflow
client = MlflowClient()

# Find the latest version
latest_version = client.get_latest_versions(
    "mortgage-prepayment-model", stages=["None"]
)[0].version

# Transition to Staging (pending validation)
client.transition_model_version_stage(
    name="mortgage-prepayment-model",
    version=latest_version,
    stage="Staging",
    archive_existing_versions=False
)

# After MRM sign-off: transition to Production
client.transition_model_version_stage(
    name="mortgage-prepayment-model",
    version=latest_version,
    stage="Production",
    archive_existing_versions=True  # archives current production version
)
```

---

## Data Lineage Tracking with OpenLineage

OpenLineage is an open standard for capturing lineage metadata. Marquez is the open-source catalog that implements it.

```python
from openlineage.client import OpenLineageClient
from openlineage.client.run import RunEvent, RunState, Run, Job
from openlineage.client.facet import (
    SchemaDatasetFacet, SchemaField,
    DataSourceDatasetFacet, SQLJobFacet
)
import uuid
from datetime import datetime, timezone

client = OpenLineageClient.from_environment()

# Emit lineage event for the feature extraction job
run_id    = str(uuid.uuid4())
job_name  = "mortgage_feature_extraction"
namespace = "mortgage-ml"

# START event
client.emit(RunEvent(
    eventType=RunState.START,
    eventTime=datetime.now(timezone.utc).isoformat(),
    run=Run(runId=run_id),
    job=Job(namespace=namespace, name=job_name),
    inputs=[
        Dataset(
            namespace="snowflake://account.snowflakecomputing.com",
            name="PROD.ORIGINATIONS.LOAN_MASTER",
        )
    ],
    outputs=[
        Dataset(
            namespace="snowflake://account.snowflakecomputing.com",
            name="ML_FEATURES.MORTGAGE_SCORING_FEATURES",
        )
    ]
))
```

---

## Practical: Reproducing a Month-Old Mortgage Model Training Run

```bash
# Scenario: It's November 2025. You need to reproduce the August 2025 training
# run to support an SR 11-7 model validation review.

# Step 1: Find the Git commit used for the August run
git log --oneline | grep "prepay-model-v4"
# → abc1234 feat: prepayment model v4 training run (2025-08-18)

# Step 2: Check out that commit
git checkout abc1234

# Step 3: Pull the exact training data from DVC remote
dvc pull data/features/mortgage_features_2025q3.parquet
# → DVC reads the .dvc file at this commit (md5 hash)
# → Downloads the exact file from S3

# Step 4: Restore the Python environment
pip install -r requirements.txt
# → requirements.txt at this commit has pinned versions

# Step 5: Reproduce the pipeline
dvc repro
# → DVC checks dvc.lock at this commit
# → All stages are stale (fresh checkout), so all stages run
# → Output: models/prepay_model_v4.pkl

# Step 6: Verify the output model matches the registered MLflow version
python src/verify_model_hash.py \
    --local-model models/prepay_model_v4.pkl \
    --mlflow-run-id abc-run-123456
```

```python
# src/verify_model_hash.py — ensure reproduced model matches production artifact
import hashlib
import mlflow
import tempfile
import os

def compute_file_md5(filepath: str) -> str:
    h = hashlib.md5()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()

def verify_model_reproduction(local_model_path: str, mlflow_run_id: str) -> bool:
    client = mlflow.tracking.MlflowClient()

    with tempfile.TemporaryDirectory() as tmpdir:
        # Download the registered model artifact
        client.download_artifacts(mlflow_run_id, "prepay_model/model.pkl", tmpdir)
        registered_path = os.path.join(tmpdir, "prepay_model", "model.pkl")

        local_hash      = compute_file_md5(local_model_path)
        registered_hash = compute_file_md5(registered_path)

        print(f"Local hash:      {local_hash}")
        print(f"Registered hash: {registered_hash}")
        print(f"Match: {local_hash == registered_hash}")

        return local_hash == registered_hash
```

---

## Snowflake + DVC Integration Pattern

```python
# Pattern: extract training data from Snowflake, version it with DVC
import snowflake.connector
import pandas as pd
import subprocess
import os
from pathlib import Path

def extract_and_version_training_data(
    dataset_id: str,
    snapshot_table: str,
    output_path: str,
    snowflake_cfg: dict
) -> str:
    """
    Extract a versioned training dataset from a Snowflake snapshot table
    and register it in DVC. Returns the DVC file path.
    """
    conn = snowflake.connector.connect(**snowflake_cfg)

    # Pull from the permanent snapshot (not the live table)
    query = f"SELECT * FROM {snapshot_table} ORDER BY loan_id"
    df    = pd.read_sql(query, conn)
    conn.close()

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_parquet(output_path, index=False)

    print(f"Extracted {len(df):,} rows to {output_path}")

    # Add to DVC tracking
    subprocess.run(["dvc", "add", str(output_path)], check=True)

    # Stage the .dvc pointer file in Git
    subprocess.run(["git", "add", f"{output_path}.dvc"], check=True)

    print(f"DVC tracking file: {output_path}.dvc")
    return str(output_path) + ".dvc"
```

---

## Interview Q&A

**Q1: Why is data versioning necessary for ML, and how is it different from database backups?**

Database backups are for disaster recovery — they restore the entire database to a point in time, which is operationally invasive and not designed for selective dataset retrieval. Data versioning for ML is about granular, reproducible access to specific dataset states: the exact training set used for a specific model version, queryable by dataset ID without impacting any other tables. It is also about connecting dataset state to code state: the DVC `.dvc` pointer file is committed to Git alongside the training code, so checking out a Git tag gives you both the code and the data pointer. Backups do not provide that traceability.

**Q2: Explain DVC's architecture. How does it avoid storing large files in Git?**

DVC follows the same mental model as Git LFS but with more flexibility. When you run `dvc add data/mortgage_train.parquet`, DVC computes an MD5 hash of the file, moves the file to the DVC cache (`~/.dvc/cache`), creates a `.dvc` file containing the hash and file size, and adds the actual file to `.gitignore`. You commit the `.dvc` pointer file to Git — it's tiny (a few hundred bytes). The actual data is pushed to a DVC remote (S3, Azure Blob, etc.) separately with `dvc push`. When anyone clones the repo and runs `dvc pull`, DVC reads the `.dvc` file, looks up the hash in the remote, and downloads exactly the right version of the data.

**Q3: How do Snowflake Time Travel and DVC complement each other in a mortgage ML pipeline?**

They operate at different layers. Snowflake Time Travel handles table-level temporal queries — I can query the feature table as it existed on any date in the retention window. DVC handles file-level versioning of the extracted Parquet files that were fed into training. Together: I use Snowflake Time Travel to create a permanent CLONE snapshot of the feature table at training time, register that snapshot in a dataset registry, extract it to Parquet, and version the Parquet file with DVC. The DVC `.dvc` file is committed to Git alongside the model training code, so the entire training run is reproducible: `git checkout <tag>` + `dvc pull` gives you the exact code and data.

**Q4: What is SQL Server temporal table and when would you use it over Snowflake Time Travel?**

SQL Server system-versioned temporal tables automatically track every row change with `ValidFrom`/`ValidTo` timestamps, storing history in a parallel history table. You use them when: (1) your data lives in SQL Server (not Snowflake) and you need row-level history, (2) you need history retention beyond Snowflake's 90-day limit, (3) you need to audit individual field changes at a granular level (e.g., which servicer last modified a loan's delinquency status). For a secondary mortgage shop with SQL Server as the servicing data store, temporal tables on the `LoanFeatureSnapshots` table give you an always-on change log that feeds historical feature reconstruction for any model training date.

**Q5: How do you reproduce a model training run from 6 months ago?**

My standard runbook: (1) Find the Git commit tag or hash associated with that model version — from the MLflow run metadata or the model registry. (2) `git checkout <hash>` to restore the exact code state. (3) `dvc pull` to download the exact training data that was versioned at that commit. (4) Restore the Python environment from `requirements.txt` at that commit — I'd use a new virtual environment to avoid dependency conflicts. (5) `dvc repro` to run the full pipeline. (6) Compare the output model artifact's MD5 hash against the MLflow-registered artifact to confirm exact reproduction. This entire sequence should work without any manual intervention if the pipeline was properly versioned when originally run.

**Q6: What is Delta Lake time travel and how does it differ from Snowflake time travel?**

Both allow `SELECT * FROM table AT (TIMESTAMP => ...)` style queries, but the mechanics differ. Delta Lake stores a transaction log in `_delta_log` as JSON files — every write operation is recorded, and time travel works by replaying the log to reconstruct a past state. Snowflake Time Travel uses Snowflake's internal storage system to maintain historical data; the implementation is opaque to the user. Key differences: Delta Lake time travel is storage-platform-agnostic (works on S3, ADLS, GCS) and integrates with Spark/Databricks; Snowflake Time Travel is a managed service. Both have a retention limit (Delta: configurable, typically 30 days; Snowflake: up to 90 days). For permanent retention of training snapshots, use `CREATE TABLE ... CLONE` in Snowflake or explicitly checkpoint a Delta version to a separate table.

**Q7: How does MLflow Model Registry fit into the overall versioning story?**

MLflow Model Registry is the final link in the chain. DVC versions data and pipeline artifacts; Git versions code; MLflow versions trained model artifacts and manages their promotion lifecycle. A registered model version in MLflow should always link back to the Git commit hash and DVC dataset ID used to produce it — I log these as MLflow parameters at training time. When a model is promoted from Staging to Production, that transition is logged in MLflow with a timestamp and the user who approved it. This gives the model validation team a complete audit trail: what data, what code, what parameters produced this model, when was it validated, who approved it.

**Q8: What are DVC experiments and how do you use them for hyperparameter search?**

DVC experiments are lightweight experiment branches that let you run variants of your pipeline without creating Git commits for each run. You define parameters in a `params.yaml` file and modify them with `dvc exp run --set-param model.n_estimators=300`. DVC runs the pipeline, caches the outputs, and stores the result alongside the baseline. After running multiple experiments, `dvc exp show` displays a comparison table with all parameter values and metrics. You can then `dvc exp branch <exp-id> <branch-name>` to promote a winning experiment to a Git branch. This is useful for hyperparameter tuning while maintaining clean Git history — the experiment metadata is stored in `.dvc/tmp/exps/`.

**Q9: How do you handle data lineage requirements in a Snowflake + Python ML pipeline?**

I use a multi-layer approach: (1) At the pipeline level, DVC's `dvc.yaml` explicitly declares input/output dependencies for every stage, giving structural lineage. (2) At the table level, every ML feature table in Snowflake has a `SOURCE_TABLE` tag and `COMMENT` documenting its origin queries. (3) At the run level, MLflow parameters log the specific dataset IDs, snapshot tables, and Git commits. (4) For more sophisticated lineage, I instrument pipelines with OpenLineage events that feed into a Marquez catalog, where you can trace any model back to its source tables through a graph visualization. For compliance teams that need to answer "where does the FICO score in this model come from?" the answer flows from MLflow (dataset ID) → dataset registry (snapshot table) → Snowflake COMMENT (source table and query) → column-level lineage in Marquez.

**Q10: A model validator asks you to prove that the training dataset you used excluded loans in COVID forbearance. How do you do that?**

First, I'd retrieve the dataset registry record for the training run, which shows the snapshot table name and its creation timestamp. Then I'd query the snapshot table directly: `SELECT COUNT(*) FROM ml_features.mortgage_train_2025q3_snapshot WHERE forbearance_flag = 1` to confirm zero rows. I'd also show the feature extraction code at the relevant Git commit, which contains the explicit WHERE clause filtering out forbearance loans. If the code was run through DVC, the `dvc.lock` file at that commit records the exact hash of the input and output files, proving the output dataset matches what the registered code would produce. This three-way corroboration — snapshot query, code review, DVC hash — satisfies an SR 11-7 validator's evidence standard.

---

## Pro Tips

- **Version your reference datasets the same day you start training.** The most common failure mode is running a training job, getting good results, and then realizing the training data was a live table that has since been updated. Create the snapshot first, then train from the snapshot.
- **Store the Git commit hash in every MLflow run and every Snowflake snapshot table COMMENT.** This single field makes the difference between "we can reproduce this" and "we'll have to reconstruct it."
- **DVC `dvc.lock` is the reproducibility contract.** It locks the MD5 hashes of all pipeline inputs and outputs at the time of a successful run. Commit `dvc.lock` to Git — it is the cryptographic proof that a specific code commit produced a specific model from a specific dataset.
- **Use Snowflake Zero-Copy Clone for training snapshots.** It's instantaneous, costs nothing in storage until you modify the clone, and gives you a persistent, queryable snapshot. It's the cheapest permanent training dataset archive available.
- **Build a training dataset registry table.** Ad hoc snapshots are not enough — you need a catalog. A simple Snowflake table with `dataset_id`, `snapshot_table`, `row_count`, `date_range`, `model_version`, and `git_commit` turns scattered snapshots into a searchable audit trail.
- **Test your reproducibility pipeline before you need it.** Reproduce a recent model training run on a clean machine quarterly. If it fails, you'll discover the gap in your versioning before a model validator asks for it under a deadline.
- **For regulated workloads, version your feature definitions separately from your code.** Feature logic embedded in Python code is hard for non-engineers to review. A feature specification document (even a markdown file versioned in Git) that defines each feature in business language satisfies the "conceptual soundness" documentation requirement for model validators who are not programmers.

---

[← Back to Index](README.md)
