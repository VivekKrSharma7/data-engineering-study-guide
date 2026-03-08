# Databricks, MLflow & AutoML for Data Engineers

[Back to Index](README.md)

---

## Overview

Databricks is the commercial platform built on Apache Spark, Delta Lake, and MLflow. It introduced the "Lakehouse" paradigm — combining the schema enforcement and ACID transactions of a data warehouse with the scalability and openness of a data lake. For a senior data engineer in the US secondary mortgage market, Databricks is the most capable single platform for processing billions of rows of loan-level data and training ML models on that same data without moving it to a separate system. This module covers the full Databricks ML stack, MLflow for experiment tracking, AutoML for rapid model development, and Databricks' growing LLM capabilities via Mosaic AI.

---

## Key Concepts at a Glance

| Component | What It Does | Mortgage Use Case |
|---|---|---|
| Databricks Runtime ML | Pre-built ML cluster image | Skip library setup; run XGBoost day one |
| Delta Lake | ACID table format on cloud storage | Versioned loan tape with time travel |
| Feature Store | Centralized feature definitions | FICO, LTV, DTI computed once, used everywhere |
| MLflow (managed) | Experiment tracking + model registry | Track 500 AutoML trials, register winner |
| AutoML | Glass-box automated model selection | Baseline prepayment model in hours |
| Model Serving | Real-time REST endpoint for models | Score lock requests against credit model |
| Databricks Workflows | Orchestrate ML pipelines | Monthly retrain triggered by schedule |
| Foundation Model APIs | Serverless LLM / embedding APIs | Embed loan conditions, call Llama 3 |
| Vector Search | Managed vector database | Semantic search over servicing notes |
| Unity Catalog | Governance for data + ML assets | Restrict PII loan columns to underwriting only |
| Mosaic AI | Fine-tune LLMs on proprietary data | Domain-adapted model on mortgage text |

---

## 1. Databricks Platform and Lakehouse Paradigm

### Architecture Layers

```
Control Plane (Databricks-managed)
  ├── Web UI, REST API, Cluster Manager, Workflows scheduler
  └── MLflow Tracking Server, Model Registry, Feature Store metadata

Data Plane (Customer-managed cloud account)
  ├── Cloud VMs (cluster nodes) — EC2 on AWS, VMs on Azure, GCE on GCP
  ├── Cloud Object Storage — S3 / ADLS Gen2 / GCS
  └── Delta Lake tables (Parquet + _delta_log transaction log)
```

The key architectural principle: **compute is ephemeral; data is durable.** Clusters start and stop; Delta Lake tables persist on your storage account. This is different from traditional SQL Server where data lives on the database server.

### Delta Lake for ML Workflows

Delta Lake adds critical ML-friendly capabilities on top of Parquet:

| Feature | ML Relevance |
|---|---|
| ACID Transactions | Safe concurrent writes to feature tables during online ingestion |
| Time Travel | `VERSION AS OF 142` — reproduce exact training dataset |
| Schema Evolution | Add new features to loan table without breaking existing readers |
| Z-Order Clustering | Co-locate rows by loan_id / as_of_date for fast feature lookups |
| Change Data Feed | Stream only changed records to online Feature Store |

```python
# Time travel for reproducible training data
df = spark.read.format("delta") \
    .option("versionAsOf", 142) \
    .table("mortgage.loan_features_gold")

# Or by timestamp
df = spark.read.format("delta") \
    .option("timestampAsOf", "2026-01-01T00:00:00.000Z") \
    .table("mortgage.loan_features_gold")

# View Delta table history
spark.sql("DESCRIBE HISTORY mortgage.loan_features_gold LIMIT 20").show(truncate=False)
```

---

## 2. Databricks Runtime for ML

Databricks ML Runtime (DBR ML) is a cluster image pre-installed with:

```
ML Framework        Version (DBR 15.4 ML LTS)
XGBoost             2.0.x
LightGBM            4.x
Scikit-learn        1.4.x
PyTorch             2.3.x
TensorFlow          2.16.x
Hugging Face        4.40.x (transformers, datasets, peft)
MLflow              2.13.x
SHAP                0.45.x
Optuna              3.x (hyperparameter optimization)
```

**Why this matters:** Cluster startup is ~3 minutes rather than 10+ minutes with manual library installation. On a `g4dn.xlarge` GPU cluster, you can immediately run Hugging Face fine-tuning without managing CUDA drivers.

---

## 3. Databricks Feature Store

The Databricks Feature Store stores feature computation logic alongside the feature values, enabling:
- Point-in-time correct training dataset assembly (no feature leakage)
- Automatic feature lookup at scoring time (online serving)
- Feature lineage tracking via Unity Catalog

### Creating and Publishing Features

```python
from databricks.feature_engineering import FeatureEngineeringClient
import pyspark.sql.functions as F

fe = FeatureEngineeringClient()

# Define the feature table
fe.create_table(
    name="mortgage.loan_credit_features",
    primary_keys=["loan_id", "as_of_date"],
    timestamp_keys=["as_of_date"],
    description="Credit-relevant features per loan per month",
    schema=spark.createDataFrame([], schema).schema
)

# Compute and write features from Silver layer loan data
@F.udf("double")
def clamp_ltv(ltv): return min(max(float(ltv), 0.0), 2.0)  # cap at 200% LTV

features_df = (
    spark.table("mortgage.silver_loans")
    .withColumn("ltv_clamped", clamp_ltv(F.col("ltv")))
    .withColumn("dti_bucket", F.when(F.col("dti") < 0.36, "LOW")
                                .when(F.col("dti") < 0.43, "MID").otherwise("HIGH"))
    .select("loan_id", "as_of_date", "fico", "ltv_clamped", "dti", "dti_bucket",
            "loan_age_months", "product_type_enc")
)

fe.write_table(
    name="mortgage.loan_credit_features",
    df=features_df,
    mode="merge"   # Upsert — update existing records, insert new ones
)
```

### Training with Feature Store (Point-in-Time Join)

```python
from databricks.feature_engineering import FeatureLookup
from databricks.feature_engineering import TrainingSet

# Labels table — loan outcomes with as_of_date
labels = spark.table("mortgage.loan_outcomes").select("loan_id", "as_of_date", "default_flag")

feature_lookups = [
    FeatureLookup(
        table_name="mortgage.loan_credit_features",
        feature_names=["fico", "ltv_clamped", "dti", "dti_bucket", "loan_age_months", "product_type_enc"],
        lookup_key=["loan_id"],
        timestamp_lookup_key="as_of_date"  # Point-in-time — gets features as of label date
    )
]

training_set = fe.create_training_set(
    df=labels,
    feature_lookups=feature_lookups,
    label="default_flag",
    exclude_columns=["as_of_date"]
)
training_df = training_set.load_df().toPandas()
```

---

## 4. MLflow on Databricks (Managed)

Databricks hosts a fully managed MLflow tracking server — no setup required. Auto-logging captures parameters, metrics, and artifacts automatically for most frameworks.

### Auto-Logging Example

```python
import mlflow
import mlflow.xgboost
import xgboost as xgb
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score

mlflow.set_experiment("/Shared/Mortgage/credit-scoring")

X = training_df.drop(columns=["loan_id","default_flag"])
y = training_df["default_flag"]
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

mlflow.xgboost.autolog(log_models=True, log_input_examples=True)

with mlflow.start_run(run_name="xgb-credit-v5-Q1-2026") as run:
    model = xgb.XGBClassifier(
        n_estimators=500, max_depth=6, learning_rate=0.05,
        subsample=0.8, colsample_bytree=0.8,
        use_label_encoder=False, eval_metric="auc",
        early_stopping_rounds=20
    )
    model.fit(X_train, y_train, eval_set=[(X_test, y_test)], verbose=50)

    # Additional custom metrics
    y_pred = model.predict_proba(X_test)[:,1]
    auc = roc_auc_score(y_test, y_pred)
    gini = 2 * auc - 1
    mlflow.log_metrics({"test_auc": auc, "test_gini": gini})
    mlflow.log_param("training_delta_version", 142)
    mlflow.set_tags({
        "regulatory": "FHFA-compliant",
        "model_risk_reviewed": "False",
        "vintage": "2026Q1"
    })

    print(f"Run ID: {run.info.run_id}")
    print(f"AUC: {auc:.4f} | Gini: {gini:.4f}")
```

### Model Registry Lifecycle

```python
from mlflow.tracking import MlflowClient

client = MlflowClient()

# Register model from run
model_uri = f"runs:/{run.info.run_id}/model"
registered = mlflow.register_model(model_uri=model_uri, name="MortgageCreditScore")

# Transition to Staging
client.transition_model_version_stage(
    name="MortgageCreditScore",
    version=registered.version,
    stage="Staging",
    archive_existing_versions=False
)

# After model risk approval, promote to Production
client.transition_model_version_stage(
    name="MortgageCreditScore",
    version=registered.version,
    stage="Production",
    archive_existing_versions=True   # Demote previous production version
)

# Add approval annotation
client.update_model_version(
    name="MortgageCreditScore",
    version=registered.version,
    description="Approved by Model Risk 2026-03-05. AUC=0.823, Gini=0.646. FHFA fair lending review passed."
)
```

---

## 5. Databricks AutoML

Databricks AutoML is "glass-box" — it generates Python notebooks for the best models it finds, making the logic fully auditable. This distinguishes it from black-box AutoML tools.

### What AutoML Does

1. Analyzes input data: missing values, feature types, cardinality, class imbalance
2. Runs trials across algorithm families: LightGBM, XGBoost, sklearn (Random Forest, Linear)
3. Evaluates each trial with cross-validation
4. Produces a ranked summary notebook + individual trial notebooks + a data exploration notebook
5. Logs all trials to MLflow automatically

### AutoML via Python API

```python
from databricks import automl as db_automl

summary = db_automl.classify(
    dataset=spark.table("mortgage.loan_features_gold"),
    target_col="default_flag",
    primary_metric="roc_auc",
    timeout_minutes=60,
    max_trials=50,
    exclude_columns=["loan_id", "origination_date"],
    exclude_frameworks=["sklearn"],           # Focus on boosted trees
    pos_label=1,
    data_dir="dbfs:/automl/mortgage-credit/",
    experiment_dir="/Shared/Mortgage/AutoML/credit-scoring"
)

print(f"Best trial run ID: {summary.best_trial.mlflow_run_id}")
print(f"Best AUC: {summary.best_trial.metrics['val_roc_auc_score']:.4f}")

# The best model notebook path — open and inspect the generated code
print(f"Best model notebook: {summary.best_trial.notebook_path}")
```

### AutoML Output Artifacts

```
AutoML run produces:
  ├── /Shared/Mortgage/AutoML/credit-scoring/
  │     ├── DataExploration.ipynb    (EDA: distributions, correlations, missing data)
  │     ├── BestTrial.ipynb          (Full training code for best model — EDITABLE)
  │     └── trials/
  │           ├── Trial-01-LightGBM.ipynb
  │           ├── Trial-02-XGBoost.ipynb
  │           └── ...
  └── MLflow Experiment (all 50 trials logged with full parameters + metrics)
```

The generated `BestTrial.ipynb` is the starting point for customization — a data engineer can open it, add domain-specific feature engineering, and re-run to build on the AutoML baseline.

---

## 6. Databricks Model Serving

Model Serving deploys MLflow models as scalable REST endpoints running on Databricks-managed infrastructure.

```python
import requests, json

# Deploy via REST API (or use UI)
token = dbutils.notebook.entry_point.getDbutils().notebook().getContext().apiToken().get()
workspace_url = "https://<workspace>.azuredatabricks.net"

endpoint_config = {
    "name": "mortgage-credit-score",
    "config": {
        "served_models": [{
            "name": "credit-v5",
            "model_name": "MortgageCreditScore",
            "model_version": "7",
            "workload_size": "Small",     # Small=4 RPS, Medium=16 RPS, Large=32 RPS
            "scale_to_zero_enabled": True
        }]
    }
}

response = requests.post(
    f"{workspace_url}/api/2.0/serving-endpoints",
    headers={"Authorization": f"Bearer {token}"},
    json=endpoint_config
)

# Invoke endpoint
def score_loan(features: dict) -> float:
    payload = {"inputs": [features]}
    resp = requests.post(
        f"{workspace_url}/serving-endpoints/mortgage-credit-score/invocations",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload
    )
    return resp.json()["predictions"][0]

score = score_loan({"fico": 740, "ltv_clamped": 0.80, "dti": 0.38,
                    "loan_age_months": 12, "product_type_enc": 1})
print(f"Default probability: {score:.4f}")
```

**Scale-to-zero** is critical for cost management: endpoints with no traffic for 30 minutes scale down to 0 replicas. Cold start is ~30-60 seconds. Use this for non-production or off-hours endpoints.

---

## 7. Databricks Workflows for ML Pipelines

Databricks Workflows is the native orchestrator — preferred over ADF/Airflow for Databricks-only pipelines.

```python
# Define a multi-task workflow via SDK (databricks-sdk)
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.jobs import (
    Task, NotebookTask, PythonWheelTask, RunNow,
    JobCluster, ClusterSpec, AutoScale, JobsHealthRule
)

w = WorkspaceClient()

job = w.jobs.create(
    name="monthly-credit-model-retrain",
    tasks=[
        Task(
            task_key="feature_engineering",
            notebook_task=NotebookTask(
                notebook_path="/Shared/Mortgage/Pipelines/01_FeatureEngineering",
                base_parameters={"as_of_date": "2026-03-01"}
            ),
            existing_cluster_id="0301-120000-abc12345"
        ),
        Task(
            task_key="automl_training",
            depends_on=[{"task_key": "feature_engineering"}],
            notebook_task=NotebookTask(
                notebook_path="/Shared/Mortgage/Pipelines/02_AutoMLTrain"
            ),
            existing_cluster_id="0301-120000-abc12345"
        ),
        Task(
            task_key="model_validation",
            depends_on=[{"task_key": "automl_training"}],
            notebook_task=NotebookTask(
                notebook_path="/Shared/Mortgage/Pipelines/03_Validation"
            ),
            existing_cluster_id="0301-120000-abc12345"
        ),
        Task(
            task_key="deploy_if_approved",
            depends_on=[{"task_key": "model_validation"}],
            python_wheel_task=PythonWheelTask(
                package_name="mortgage_mlops",
                entry_point="deploy_model",
                parameters=["--endpoint", "mortgage-credit-score"]
            ),
            existing_cluster_id="0301-120000-abc12345"
        )
    ],
    health={"rules": [JobsHealthRule(metric="RUN_DURATION_SECONDS", op="GREATER_THAN", value=14400)]},
    email_notifications={"on_failure": ["ml-ops-team@company.com"]}
)
```

---

## 8. LLM Features: Foundation Model APIs, DBRX, and Vector Search

### Foundation Model APIs (Serverless LLMs)

Databricks Foundation Model APIs provide serverless access to open-source models hosted by Databricks — pay-per-token, no endpoint management.

```python
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.serving import ChatMessage, ChatMessageRole

w = WorkspaceClient()

# Use Llama 3.1 70B for mortgage document summarization
response = w.serving_endpoints.query(
    name="databricks-meta-llama-3-1-70b-instruct",
    messages=[
        ChatMessage(role=ChatMessageRole.SYSTEM,
                    content="You are a mortgage underwriting assistant. Be concise and precise."),
        ChatMessage(role=ChatMessageRole.USER,
                    content=f"Summarize this loan condition and identify any compliance flags:\n{condition_text}")
    ],
    max_tokens=300,
    temperature=0.0
)
print(response.choices[0].message.content)

# BGE embeddings for vector search
embed_response = w.serving_endpoints.query(
    name="databricks-bge-large-en",
    input=["borrower income documentation missing", "appraisal value below purchase price"]
)
vectors = [item.embedding for item in embed_response.data]
```

### Databricks Vector Search

```python
from databricks.vector_search.client import VectorSearchClient

vsc = VectorSearchClient()

# Create vector search index on a Delta table with embeddings
index = vsc.create_delta_sync_index(
    endpoint_name="mortgage-vs-endpoint",
    source_table_name="mortgage.loan_conditions_with_embeddings",
    index_name="mortgage.loan_conditions_index",
    primary_key="condition_id",
    embedding_dimension=1024,
    embedding_vector_column="condition_embedding",
    pipeline_type="TRIGGERED"   # or CONTINUOUS for streaming updates
)

# Semantic search over loan conditions
results = index.similarity_search(
    query_vector=vectors[0],      # Embed query text first
    columns=["condition_id", "loan_id", "condition_text", "assigned_team"],
    num_results=10,
    filters={"loan_status": "Active", "condition_category": "Income"}
)
```

---

## 9. Mosaic AI: Fine-Tuning LLMs on Mortgage Data

Mosaic AI (acquired by Databricks in 2023) enables fine-tuning large language models on proprietary data at scale.

### When to Fine-Tune vs. Prompt Engineering

| Approach | When to Use | Example |
|---|---|---|
| Prompt engineering | General task, GPT-4 class model | Summarize any loan condition |
| RAG (retrieval-augmented) | Domain knowledge lookup | Retrieve relevant guidelines before generating |
| Fine-tuning | Domain-specific terminology, format, or style | Extract specific MISMO fields from 1003s |
| Full pre-training (Mosaic MPT) | Entirely new domain vocabulary | Build mortgage-specific base model (rare, expensive) |

### Fine-Tuning Workflow on Databricks

```python
# Fine-tune Llama 3.1 8B on mortgage condition classification
# Using Databricks Mosaic AI Training (via UI or API)

import json

# Prepare training data in chat format
training_examples = [
    {
        "messages": [
            {"role": "system", "content": "Classify mortgage conditions into categories."},
            {"role": "user", "content": "Provide 2 years tax returns signed and dated"},
            {"role": "assistant", "content": '{"category": "Income Documentation", "urgency": "High", "responsible_party": "Borrower"}'}
        ]
    },
    # ... thousands of labeled examples
]

# Write to Delta table for fine-tuning job
train_df = spark.createDataFrame(training_examples)
train_df.write.format("delta").mode("overwrite").saveAsTable("mortgage.llm_finetuning_train")
```

---

## 10. Databricks vs. Snowflake for ML Workloads

This is a frequently asked interview comparison for mortgage data engineers who operate both platforms:

| Dimension | Databricks | Snowflake |
|---|---|---|
| Primary strength | Large-scale ML training, streaming, unstructured data | SQL analytics, governed data sharing, ELT |
| ML native tools | MLflow, AutoML, Feature Store, Model Serving | Snowpark ML, Cortex (serverless LLMs), Partner Connect |
| Language | Python/Scala/SQL via Spark | SQL + Snowpark (Python/Java/Scala) |
| Data format | Delta Lake (open) | Proprietary columnar (FDN) |
| Training data scale | Billions of rows natively | Large SQL datasets; limited for iterative ML training |
| Deployment | Model Serving endpoints | Cortex inference functions (in-database) |
| Governance | Unity Catalog | Snowflake native access controls |
| Cost model | DBUs (per-second cluster cost) | Credits (per-second warehouse cost) |
| Best for mortgage ML | MBS pool analytics, LLM fine-tuning, real-time feature pipelines | HMDA reporting, loan-level SQL analytics, data sharing with GSEs |

**Typical enterprise pattern:** Snowflake owns the governed data warehouse (loan tapes, agency data, HMDA). Databricks reads from Snowflake via the Snowflake connector, trains models on large-scale Spark clusters, and serves predictions back to Snowflake for reporting.

---

## 11. Unity Catalog for ML Governance

Unity Catalog extends data governance to ML assets: Feature Store tables, Models, and Volumes.

```sql
-- Grant Feature Store table access to model training role
GRANT SELECT ON TABLE mortgage.loan_credit_features TO ROLE ml_training_role;

-- Restrict PII columns — only underwriting can see borrower SSN
CREATE ROW FILTER policy.mask_pii ON mortgage.loan_origination_data
    AS (role) RETURNS BOOLEAN
    RETURN is_member('underwriting_team');

-- Tag sensitive columns for data lineage tracking
ALTER TABLE mortgage.loan_credit_features
    ALTER COLUMN fico SET TAGS ('pii' = 'false', 'regulatory' = 'FCRA');

-- Model lineage — Unity Catalog tracks which feature table versions trained which models
DESCRIBE HISTORY mlflow.models.MortgageCreditScore;
```

---

## 12. Complete Databricks ML Workflow (End-to-End)

```python
# Full pipeline: Delta Lake -> Feature Store -> AutoML -> Registry -> Serving
# Notebook: /Shared/Mortgage/Pipelines/EndToEnd_CreditModel

# ============================================================
# STEP 1: Load and validate training data from Delta Lake
# ============================================================
from pyspark.sql import SparkSession
import pyspark.sql.functions as F

spark = SparkSession.builder.getOrCreate()

# Use Delta time travel for reproducible training set
as_of_version = 142
raw_df = (
    spark.read.format("delta")
    .option("versionAsOf", as_of_version)
    .table("mortgage.loan_features_gold")
    .filter(F.col("data_split").isin(["TRAIN", "VALIDATE"]))
    .filter(F.col("loan_age_months").between(3, 120))
    .filter(F.col("fico").between(300, 850))
)
print(f"Training rows: {raw_df.count():,}")

# ============================================================
# STEP 2: Run AutoML classification
# ============================================================
from databricks import automl as db_automl

summary = db_automl.classify(
    dataset=raw_df,
    target_col="default_flag",
    primary_metric="roc_auc",
    timeout_minutes=45,
    experiment_dir="/Shared/Mortgage/AutoML/credit-scoring-2026Q1"
)

best_run_id = summary.best_trial.mlflow_run_id
best_auc    = summary.best_trial.metrics.get("val_roc_auc_score", 0)
print(f"Best AUC: {best_auc:.4f}")

# ============================================================
# STEP 3: Register best model with Feature Store lineage
# ============================================================
import mlflow
from databricks.feature_engineering import FeatureEngineeringClient

fe = FeatureEngineeringClient()

with mlflow.start_run(run_id=best_run_id):
    # Package model with feature lookups so scoring is self-contained
    fe.log_model(
        model=mlflow.sklearn.load_model(f"runs:/{best_run_id}/model"),
        artifact_path="feature_store_model",
        flavor=mlflow.sklearn,
        training_set=training_set,   # From Feature Store training set defined earlier
        registered_model_name="MortgageCreditScore"
    )

# ============================================================
# STEP 4: Evaluate against holdout test set
# ============================================================
from sklearn.metrics import roc_auc_score, classification_report
import numpy as np

test_df = (
    spark.read.format("delta")
    .option("versionAsOf", as_of_version)
    .table("mortgage.loan_features_gold")
    .filter(F.col("data_split") == "TEST")
    .toPandas()
)

loaded_model = mlflow.sklearn.load_model(f"runs:/{best_run_id}/model")
X_test = test_df.drop(columns=["loan_id", "default_flag", "data_split", "as_of_date"])
y_test = test_df["default_flag"]
y_pred = loaded_model.predict_proba(X_test)[:,1]

test_auc  = roc_auc_score(y_test, y_pred)
test_gini = 2 * test_auc - 1
print(f"Test AUC: {test_auc:.4f} | Gini: {test_gini:.4f}")

if test_auc >= 0.78:
    client = mlflow.tracking.MlflowClient()
    latest = client.get_latest_versions("MortgageCreditScore", stages=["None"])[0]
    client.transition_model_version_stage(
        name="MortgageCreditScore",
        version=latest.version,
        stage="Staging"
    )
    print(f"Model v{latest.version} promoted to Staging")
else:
    raise ValueError(f"Test AUC {test_auc:.4f} below threshold 0.78 — model not registered")
```

---

## Interview Q&A

**Q1: What is the Lakehouse paradigm and how does it differ from the Lambda architecture commonly used in earlier big data systems?**

Lambda architecture separates batch and streaming into two distinct paths: a batch layer (Hadoop/Hive) for high-latency accurate views and a speed layer (Storm/Kafka) for low-latency approximate views. This creates operational complexity — two codebases, two consistency models, reconciliation logic. The Lakehouse replaces this with a single storage layer (Delta Lake / Iceberg / Hudi) that supports both batch and streaming writes with ACID guarantees, schema enforcement, and time travel. For a mortgage data engineer, this means one Delta table for loan-level data that is updated by nightly batch loads AND real-time lock events, queryable with SQL, and usable directly for ML training without moving data to a separate store.

**Q2: How does Delta Lake time travel enable reproducible ML training for regulatory purposes?**

Delta Lake's transaction log (`_delta_log`) records every write operation with a version number and timestamp. You can re-read a table at any past version using `.option("versionAsOf", N)` or `.option("timestampAsOf", "YYYY-MM-DD")`. For regulatory ML model validation, this is critical: an examiner asks "what data did you train the March 2026 credit model on?" The answer is "Delta table `mortgage.loan_features_gold` version 142, timestamp 2026-03-01." That is reproducible by anyone with access to the workspace. Without time travel, you would need to save training data snapshots separately — an operational burden and a consistency risk if the snapshot process has bugs.

**Q3: What makes Databricks AutoML "glass-box" and why does this matter for a regulated mortgage lender?**

Databricks AutoML generates readable Python notebooks for every trial it runs. The best trial notebook contains the full training code: data preprocessing, feature engineering, model hyperparameters, cross-validation logic, and evaluation metrics. A data scientist can open the notebook, understand every step, and modify it. This contrasts with black-box AutoML (e.g., early H2O or Google AutoML Tables) where the model is produced but the code is opaque. For FHFA/OCC model risk requirements, a mortgage lender must be able to document how a model was built, validate the logic, and have a qualified person attest to it. A generated, auditable notebook satisfies this; an opaque API call does not.

**Q4: Explain MLflow's model registry stages and how you would use them in a mortgage model governance workflow.**

MLflow Model Registry has four stages: None (newly registered), Staging, Production, Archived. In a governed mortgage workflow: (1) AutoML or manual training registers a new version in `None`. (2) Automated validation (test AUC, fairness metrics, data drift tests) passes → promote to `Staging`. (3) Model Risk Management team reviews documentation, backtesting results, and Clarify fairness report → approves → promote to `Production`. (4) Old Production version is moved to `Archived`. The promotion steps are API calls that can be gated behind an approval workflow (JIRA ticket, email approval, Slack approval bot). MLflow records who made each stage transition and when, providing the audit trail required by FFIEC SR 11-7 model risk guidance.

**Q5: How does Databricks Feature Store prevent feature leakage in point-in-time training datasets?**

Feature leakage occurs when a model is trained on feature values that would not have been available at the time of the historical prediction. Example: using the final LTV at payoff to predict early default — that LTV was not known at origination. Databricks Feature Store prevents this via the `timestamp_lookup_key` parameter in `FeatureLookup`. When assembling a training set, each label row has an `as_of_date`. The Feature Store performs a point-in-time join: for each loan and label date, it retrieves the feature values that were recorded on or before that date. This requires features to be written with accurate `event_time` values representing when the feature was valid — a data engineering responsibility, not automatically enforced.

**Q6: What is Databricks Model Serving's scale-to-zero capability and what are the latency implications?**

Scale-to-zero means a Model Serving endpoint with no incoming traffic for ~30 minutes scales down to 0 replicas, incurring zero cost. When a request arrives, Databricks provisions a container, loads the model from MLflow, and serves the request — with a cold-start latency of 30-90 seconds depending on model size. This is appropriate for development endpoints, low-traffic internal tools, or batch scoring triggers where the first request is a warm-up. For production lock desk endpoints requiring sub-second SLAs, configure `scale_to_zero_enabled=False` with a minimum of 1-2 always-warm replicas. The cost of 2 Small replicas is approximately $0.07/hour on Azure Databricks — a trivial spend relative to the SLA value.

**Q7: How does Databricks integrate with Snowflake for a mixed-platform mortgage data architecture?**

Databricks can read from and write to Snowflake using the Spark Snowflake connector: `spark.read.format("snowflake").options(**sf_options).option("dbtable", "LOAN_FEATURES").load()`. For high-performance bulk reads, Databricks uses Snowflake's `COPY INTO` to stage Parquet files to S3/ADLS, then reads the Parquet files directly — bypassing Snowflake's row-oriented query engine for large scans. For writes back to Snowflake, Databricks stages Parquet to cloud storage and uses Snowflake's `COPY INTO <table>` for fast bulk load. Unity Catalog can federate Snowflake tables as external tables, making them visible in the Databricks catalog alongside Delta tables — enabling SQL joins across both systems. The governance boundary: Snowflake owns the governed production layer; Databricks owns the ML compute layer.

**Q8: What is Mosaic AI and when would a mortgage company invest in fine-tuning an LLM on proprietary data?**

Mosaic AI (formerly MosaicML) is Databricks' platform for LLM training and fine-tuning at scale. It provides: (1) Efficient fine-tuning via LoRA/QLoRA (Low-Rank Adaptation — updates small adapter weights, not the full model). (2) Distributed training across multi-GPU clusters. (3) The DBRX open-source base model. A mortgage company would invest in fine-tuning when: (a) The task involves highly domain-specific terminology (MISMO schema fields, GSE guideline language, FNMA/FHLMC selling guides) that general LLMs mishandle. (b) The output format must be structured and consistent (e.g., always return JSON with specific MISMO field names). (c) Prompting alone produces too many errors (>5% hallucination rate on structured extraction). Fine-tuning is not warranted for summarization tasks where general GPT-4 class models already perform well.

**Q9: How would you set up a complete DataOps + MLOps pipeline for monthly credit model retraining on Databricks?**

Architecture: (1) **Data pipeline (Databricks DLT):** Streaming and batch tables in Bronze/Silver/Gold tiers. Gold tier `loan_features_gold` is the ML-ready feature table. (2) **Feature Store sync:** Databricks Workflow writes updated features to Feature Store after each Gold refresh. (3) **Drift detection:** Monthly job computes Population Stability Index (PSI) on production scoring inputs vs. training baseline. PSI > 0.2 triggers retraining. (4) **Retraining pipeline:** Databricks Workflow runs: feature validation -> AutoML -> holdout evaluation -> conditional model registration. (5) **Approval gate:** Model registered to Staging; notification sent to Model Risk team via email/Slack. Approval via API call or UI transitions to Production. (6) **Deployment:** Model Serving endpoint updated via REST API to point to new Production model version. (7) **Monitoring:** Post-deployment PSI and AUC monitoring via scheduled notebook. Full audit trail in MLflow and Unity Catalog.

**Q10: How does Databricks Vector Search differ from a standalone vector database like Pinecone or pgvector, and when would you choose it for mortgage use cases?**

Databricks Vector Search is an integrated vector database that auto-syncs from a Delta source table — no separate ETL to maintain. When new loan conditions are added to `mortgage.loan_conditions_with_embeddings` (a Delta table), a sync pipeline automatically indexes the new embeddings into Vector Search. Pinecone and pgvector require a separate upsert process to stay in sync. The integrated approach eliminates a consistency risk: if the ETL to the vector database fails silently, searches return stale results. For a mortgage company already on Databricks, Vector Search is the low-friction choice for semantic search over loan conditions, servicing notes, or guideline text — no new vendor, no separate billing, governed by Unity Catalog. Choose an external vector database (Pinecone, Weaviate) when the application serving the vectors is external to Databricks and requires sub-10ms SLAs that Databricks Vector Search cannot guarantee.

---

## Pro Tips

- **Register Delta table versions alongside model versions in MLflow.** Add `mlflow.log_param("training_delta_version", N)` to every training run. This is the most important practice for regulatory reproducibility.
- **Use DLT (Delta Live Tables) for the feature engineering layer.** DLT adds data quality expectations (`EXPECT`) that fail or quarantine records when business rules are violated. A FICO of 900 or DTI of 2.0 is a data quality issue, not a valid feature value.
- **AutoML timeout is wall-clock time, not compute time.** A 60-minute timeout on a cluster with 8 workers runs ~60 minutes of real time — each trial may only take 2-5 minutes. Increase max_trials and let the timeout control duration rather than manually limiting trials.
- **MLflow model signatures prevent silent scoring errors.** Always log models with an `input_example` and let MLflow infer the signature. A signature mismatch (wrong column order, wrong dtype) raises an error at serving time rather than producing silently wrong scores.
- **Unity Catalog lineage is automatic for SQL operations but requires annotation for Python.** When writing features from Python Spark code, tag the output table with source table references using `ALTER TABLE ... SET TAGS` to ensure lineage is visible in the Data Lineage UI.
- **Scale-to-zero endpoints need a warm-up call in the deployment workflow.** After updating a Model Serving endpoint to a new model version, immediately invoke it with a dummy payload to trigger model loading before real traffic arrives.
- **Databricks Workflows retry policies are not the same as idempotency.** If a retraining notebook is retried after a partial failure, it may register a duplicate model version. Design notebooks to check for existing registered versions at the same Delta version before registering.
- **Use cluster policies for cost governance.** A cluster policy can enforce auto-termination after 30 minutes idle, restrict instance types to approved SKUs, and set maximum DBU budgets per user. Without policies, a single analyst spinning up a GPU cluster and leaving it idle overnight can cost thousands of dollars.
