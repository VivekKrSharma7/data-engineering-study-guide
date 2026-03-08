# AI/ML Lifecycle & MLOps

[Back to Index](README.md)

---

## Overview

MLOps is the application of DevOps principles — automation, versioning, continuous integration, monitoring — to the machine learning lifecycle. For a senior data engineer, MLOps is where your existing expertise in data pipelines, orchestration, and data quality is directly applicable. The data engineering team owns the most critical and most overlooked part of the ML lifecycle: reliable, governed training data.

This module covers every phase of the ML lifecycle, the tools that operationalize it, and the specific responsibilities data engineers carry in a mature MLOps organization.

---

## Key Concepts

| Term | Definition |
|---|---|
| ML lifecycle | The end-to-end process from data collection to a model in production |
| MLOps | DevOps practices applied to ML: CI/CD, versioning, monitoring |
| Experiment tracking | Logging hyperparameters, metrics, and artifacts for each training run |
| Model registry | Versioned catalog of trained models with promotion workflows |
| Feature store | Centralized repository of computed, reusable ML features |
| Data drift | Change in the statistical distribution of input features over time |
| Concept drift | Change in the relationship between features and the target variable |
| Model decay | Degradation in model performance as data distributions shift |
| Serving | Deploying a trained model to accept requests and return predictions |
| Canary deployment | Routing a small % of traffic to a new model version before full rollout |

---

## ML Lifecycle Phases

```
Data Collection
     |
     v
Data Preprocessing & Validation
     |
     v
Feature Engineering
     |
     v
Model Training & Evaluation
     |
     v
Model Registry / Versioning
     |
     v
Deployment (batch / real-time)
     |
     v
Monitoring (drift, performance, data quality)
     |
     v
Re-training trigger  ----> back to Data Collection
```

### Phase 1: Data Collection
Source systems → data lake / warehouse. The data engineering team owns this entirely: ingestion pipelines, schema contracts, SLA monitoring. Quality problems here corrupt every downstream phase.

### Phase 2: Preprocessing & Validation
Clean, impute, de-duplicate, validate distributions. Tools: Great Expectations, dbt tests, Soda Core. The output is a versioned, validated training dataset.

### Phase 3: Feature Engineering
Transform raw data into features the model can consume. The single most impactful phase in practice — better features beat better algorithms.

### Phase 4: Training & Evaluation
Model selection, hyperparameter tuning, cross-validation. Logged via experiment tracking tools. Key metrics: accuracy, AUC, RMSE, and business KPIs.

### Phase 5: Model Registry
Promote the best experiment run to "Staging", then to "Production". Requires sign-off workflows and reproducibility guarantees.

### Phase 6: Deployment
Batch scoring (overnight prediction tables), real-time REST APIs, or embedded scoring (SQL Server ML Services, Snowflake Cortex ML).

### Phase 7: Monitoring
Track model performance against ground truth as labels arrive. Alert on data drift (inputs changed) and model decay (performance degraded).

---

## Experiment Tracking

### MLflow

MLflow is the de-facto open-source experiment tracking standard. Integrates natively with Databricks, Azure ML, and Snowflake ML.

```python
import mlflow
import mlflow.sklearn
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score, precision_score, recall_score
import pandas as pd
import numpy as np

# ── Load training data from Snowflake via Snowpark or SQLAlchemy ──────────────
# Assume df is a pandas DataFrame of loan features
df = pd.read_parquet("s3://ml-data/loans/training/v20260301.parquet")

FEATURES = [
    "credit_score", "dti_ratio", "ltv_ratio",
    "loan_age_months", "rate_spread", "unemployment_rate"
]
TARGET = "prepayment_flag"

X = df[FEATURES]
y = df[TARGET]
X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, random_state=42, stratify=y
)

# ── MLflow experiment tracking ────────────────────────────────────────────────
mlflow.set_tracking_uri("databricks")          # or "http://mlflow-server:5000"
mlflow.set_experiment("/loans/prepayment_model")

params = {
    "n_estimators":    300,
    "max_depth":       5,
    "learning_rate":   0.05,
    "subsample":       0.8,
    "min_samples_leaf": 20
}

with mlflow.start_run(run_name="gbm_v3_full_features") as run:
    # Log parameters
    mlflow.log_params(params)
    mlflow.log_param("training_dataset", "v20260301")
    mlflow.log_param("feature_count", len(FEATURES))

    # Train
    model = GradientBoostingClassifier(**params, random_state=42)
    model.fit(X_train, y_train)

    # Evaluate
    y_pred_proba = model.predict_proba(X_test)[:, 1]
    y_pred       = (y_pred_proba >= 0.5).astype(int)

    metrics = {
        "auc":       roc_auc_score(y_test, y_pred_proba),
        "precision": precision_score(y_test, y_pred),
        "recall":    recall_score(y_test, y_pred)
    }
    mlflow.log_metrics(metrics)

    # Log feature importance as artifact
    importance_df = pd.DataFrame({
        "feature":   FEATURES,
        "importance": model.feature_importances_
    }).sort_values("importance", ascending=False)
    importance_df.to_csv("/tmp/feature_importance.csv", index=False)
    mlflow.log_artifact("/tmp/feature_importance.csv")

    # Log model with input schema
    signature = mlflow.models.infer_signature(X_train, y_pred_proba)
    mlflow.sklearn.log_model(
        model,
        artifact_path="model",
        signature=signature,
        registered_model_name="loans_prepayment_gbm"
    )

    print(f"Run ID: {run.info.run_id}")
    print(f"AUC: {metrics['auc']:.4f}")
```

### Comparing Experiment Tracking Tools

| Tool | Hosting | Strength | Weakness |
|---|---|---|---|
| MLflow | Self-hosted or Databricks | Open source, wide adoption | UI is basic |
| Weights & Biases (W&B) | SaaS | Rich visualizations, collaboration | External service |
| Neptune.ai | SaaS | Excellent metadata search | Cost at scale |
| Azure ML Experiments | Azure managed | Native Azure integration | Vendor lock-in |
| Comet ML | SaaS / self-hosted | Good NLP/CV tooling | Less common in data eng |

---

## Model Registry and Versioning

### MLflow Model Registry Workflow

```python
import mlflow
from mlflow.tracking import MlflowClient

client = MlflowClient()
MODEL_NAME = "loans_prepayment_gbm"

# Transition model version to Staging after review
client.transition_model_version_stage(
    name=MODEL_NAME,
    version="3",
    stage="Staging",
    archive_existing_versions=False
)

# After validation in staging, promote to Production
client.transition_model_version_stage(
    name=MODEL_NAME,
    version="3",
    stage="Production",
    archive_existing_versions=True   # archive old production version
)

# Load the production model for batch scoring
prod_model = mlflow.sklearn.load_model(f"models:/{MODEL_NAME}/Production")

# Add annotation
client.update_model_version(
    name=MODEL_NAME,
    version="3",
    description="GBM v3 trained on 36 months data. AUC=0.847. Approved by Risk Analytics 2026-03-01."
)
```

---

## Feature Stores

Feature stores solve the training-serving skew problem: features computed in Python during training must be computed identically in production at serving time.

### Feature Store Landscape

| Tool | Backing Store | Strength |
|---|---|---|
| Feast (open source) | Redis / BigQuery / Snowflake | Flexible, vendor-neutral |
| Tecton | Managed SaaS | Point-in-time correct joins |
| Databricks Feature Store | Delta Lake | Tight MLflow integration |
| Snowflake Feature Store (Preview) | Snowflake tables | SQL-native, no new infra |
| Vertex AI Feature Store | BigTable / BigQuery | GCP-native |

### Key Feature Store Concepts

**Point-in-time correctness:** When building training data, features must be retrieved as they were at the time of the event, not as they are today. A loan's credit score in March 2024 is not the same as today's credit score. Feature stores with time-travel support (backed by Delta Lake or Snowflake time travel) enforce this automatically.

**Online vs. offline store:** The offline store (data warehouse/lake) serves training jobs. The online store (Redis/DynamoDB) serves real-time inference with sub-10ms latency. Feature values are synchronized between them.

---

## CI/CD for ML Pipelines

```yaml
# .github/workflows/ml_pipeline.yml — simplified example
name: ML Pipeline CI/CD

on:
  push:
    paths: ["src/features/**", "src/training/**", "tests/**"]

jobs:
  data_validation:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate training data expectations
        run: |
          pip install great_expectations
          great_expectations checkpoint run training_data_checkpoint

  unit_tests:
    runs-on: ubuntu-latest
    needs: data_validation
    steps:
      - name: Run feature engineering unit tests
        run: pytest tests/test_features.py -v

  train_and_evaluate:
    runs-on: [self-hosted, gpu]
    needs: unit_tests
    steps:
      - name: Train model and log to MLflow
        run: python src/training/train.py --experiment ci_run_${{ github.sha }}
      - name: Gate on AUC threshold
        run: |
          python scripts/check_metrics.py \
            --run-id $MLFLOW_RUN_ID \
            --min-auc 0.82

  deploy_to_staging:
    needs: train_and_evaluate
    steps:
      - name: Register and transition to Staging
        run: python scripts/promote_model.py --stage Staging
```

---

## Model Monitoring: Drift Detection

### Data Drift Detection with Evidently

```python
from evidently.report import Report
from evidently.metric_preset import DataDriftPreset, DataQualityPreset
from evidently.metrics import ColumnDriftMetric
import pandas as pd

# Reference = training data distribution
reference_df = pd.read_parquet("s3://ml-data/loans/training/v20260101.parquet")
# Current = last 30 days of production inference requests
current_df   = pd.read_parquet("s3://ml-data/loans/inference/2026-02.parquet")

FEATURES = ["credit_score", "dti_ratio", "ltv_ratio", "loan_age_months", "rate_spread"]

report = Report(metrics=[
    DataDriftPreset(),
    DataQualityPreset(),
    ColumnDriftMetric(column_name="credit_score"),
    ColumnDriftMetric(column_name="dti_ratio"),
])

report.run(reference_data=reference_df[FEATURES], current_data=current_df[FEATURES])

# Save HTML report as artifact
report.save_html("/tmp/drift_report_2026-02.html")

# Check drift programmatically for alerting
result = report.as_dict()
drift_detected = result["metrics"][0]["result"]["dataset_drift"]

if drift_detected:
    print("ALERT: Data drift detected — consider re-training")
    # trigger Airflow DAG, PagerDuty, etc.
```

### Monitoring Metrics Table

| Metric Type | What It Measures | Detection Method |
|---|---|---|
| Input drift | Distribution shift in features | KS test, PSI, Jensen-Shannon divergence |
| Concept drift | P(y|X) changed | Track accuracy against arriving ground truth |
| Prediction drift | Distribution of model outputs changed | Chi-squared test on prediction histogram |
| Data quality | Null rates, out-of-range values | Great Expectations rules |
| Business KPI | Downstream business metric change | Alert when KPI deviates from baseline |

---

## Deployment Patterns

### Batch Scoring with Airflow

```python
# dags/batch_score_prepayment.py
from airflow import DAG
from airflow.providers.snowflake.operators.snowflake import SnowflakeOperator
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
import mlflow
import pandas as pd

def score_loans(**context):
    """Load production model and score active loans."""
    model = mlflow.sklearn.load_model("models:/loans_prepayment_gbm/Production")

    from snowflake.connector import connect
    conn = connect(
        account=..., user=..., private_key_file=...,
        warehouse="ML_SCORING_WH", database="LENDING", schema="FEATURES"
    )

    df = pd.read_sql("""
        SELECT loan_id, credit_score, dti_ratio, ltv_ratio,
               loan_age_months, rate_spread, unemployment_rate
        FROM active_loan_features
        WHERE as_of_date = CURRENT_DATE
    """, conn)

    features = ["credit_score", "dti_ratio", "ltv_ratio",
                "loan_age_months", "rate_spread", "unemployment_rate"]

    df["prepayment_prob"] = model.predict_proba(df[features])[:, 1]
    df["score_date"]      = context["ds"]
    df["model_version"]   = "3"

    # Write scores back to Snowflake
    df[["loan_id", "prepayment_prob", "score_date", "model_version"]].to_sql(
        "prepayment_scores", conn, schema="PREDICTIONS",
        if_exists="append", index=False, method="multi"
    )
    conn.close()


with DAG(
    dag_id="batch_score_prepayment",
    schedule_interval="0 3 * * *",       # 3 AM daily
    start_date=datetime(2026, 1, 1),
    default_args={"retries": 2, "retry_delay": timedelta(minutes=5)},
    catchup=False
) as dag:

    run_scoring = PythonOperator(
        task_id="score_active_loans",
        python_callable=score_loans
    )

    update_downstream = SnowflakeOperator(
        task_id="refresh_risk_summary",
        sql="CALL risk.refresh_prepayment_dashboard()",
        snowflake_conn_id="snowflake_prod"
    )

    run_scoring >> update_downstream
```

---

## Snowflake ML Integration with MLflow

Snowflake provides a managed MLflow tracking server accessible via Snowpark ML:

```python
from snowflake.ml.utils.connection_params import SnowflakeLoginOptions
from snowflake.snowpark import Session
import mlflow

session = Session.builder.configs(SnowflakeLoginOptions()).create()

# Use Snowflake-managed MLflow
mlflow.set_tracking_uri("snowflake")
mlflow.set_experiment("LENDING.ML.PREPAYMENT_EXPERIMENT")

with mlflow.start_run():
    mlflow.log_param("model_type", "gradient_boosting")
    mlflow.log_metric("auc", 0.847)
    # Model artifacts stored in Snowflake stage automatically
```

---

## Data Engineering Role in MLOps

As a senior data engineer, your responsibilities in a mature MLOps organization:

| Responsibility | Description |
|---|---|
| Training data pipelines | Build and maintain the dbt models, Airflow DAGs, and Snowflake objects that produce clean, versioned training datasets |
| Feature engineering | Own the feature computation logic in SQL or PySpark; register features in the feature store |
| Data validation | Write Great Expectations suites that gate pipeline runs on data quality |
| Point-in-time joins | Implement the temporal join logic that creates unbiased training data |
| Scoring data pipelines | Produce the same features at inference time that were used during training (no skew) |
| Prediction storage | Design the prediction tables, partitioning strategy, and retention policies |
| Ground truth collection | Build pipelines that join predictions back to eventual outcomes (loan defaulted? prepaid?) for model evaluation |

---

## Interview Q&A

### Q1: What is MLOps and why is it a data engineering problem as much as a data science problem?

**Answer:** MLOps is the set of practices that make ML systems reproducible, deployable, and maintainable in production. It is at least as much a data engineering problem as a data science problem because:

1. **Training data quality is the highest-leverage intervention.** A better model trained on bad data is worse than a simpler model on good data. Data engineers own the pipelines that produce training data.
2. **Training-serving skew** — where features are computed differently during training vs. production — is an engineering bug, not a modeling bug. It is the most common silent failure in ML systems.
3. **Orchestration, scheduling, and monitoring** of ML pipelines is identical to data pipeline engineering. Airflow DAGs for ML retraining are structurally identical to ETL DAGs.
4. **Storage and retrieval** of features, models, predictions, and ground truth is a data modeling and warehousing challenge.

In organizations with mature MLOps, data engineers own roughly 60-70% of the work by engineering effort.

### Q2: Explain the difference between data drift and concept drift. How do you detect each?

**Answer:**

**Data drift (covariate shift):** The distribution of input features X changes between training and production. Example: average credit score in the loan portfolio drops from 720 to 690 over 12 months as underwriting standards loosen. The model was never trained on this distribution.

**Concept drift:** The relationship P(y|X) changes — the same feature values now predict a different outcome. Example: a model trained on pre-pandemic prepayment behavior fails post-pandemic because low rates drove refinancing waves the model never saw.

Detection:
- Data drift: statistical tests (Kolmogorov-Smirnov, PSI — Population Stability Index) comparing reference distribution to current window. PSI > 0.2 is the industry standard threshold for "significant drift."
- Concept drift: requires ground truth labels, which often arrive with a lag (a loan prepayment is only known months later). Track performance metrics (AUC, Gini) as labels trickle in. Proxy signals: monitor the distribution of model predictions — if output scores shift dramatically without an obvious business reason, concept drift may be occurring.

### Q3: What is a feature store, and what problem does it solve?

**Answer:** A feature store is a centralized data system that stores, serves, and governs ML features. It solves three specific problems:

1. **Training-serving skew:** Feature computation logic is defined once in the feature store and used for both training (offline) and serving (online). Without a feature store, teams reimplement features in Python for training and in Java/Go for serving — subtle bugs cause score divergence.
2. **Feature reuse:** If the fraud team and the credit team both need a "customer 90-day transaction velocity" feature, they should compute it once, not twice. A feature store catalogs features so teams discover and reuse them.
3. **Point-in-time correctness:** For historical training data, features must reflect what was known at the time of the event, not today's values. Feature stores with time-travel support (Tecton, Databricks Feature Store on Delta) enforce this automatically.

A feature store has two halves: the offline store (data warehouse/lake, slow, used for training) and the online store (Redis/DynamoDB, fast, used for real-time serving). Feature pipelines keep both in sync.

### Q4: Walk me through a complete MLOps pipeline for a fraud detection model.

**Answer:** End-to-end:

1. **Data ingestion:** Transaction events stream into Kafka → land in S3/Snowflake via a Flink or Kafka Connect job (data engineering owns this).
2. **Feature engineering:** Daily Airflow DAG runs dbt models to compute features: transaction velocity (7-day, 30-day), average ticket size, geolocation deviation, device fingerprint frequency. Features registered in Databricks Feature Store.
3. **Training pipeline:** Weekly retraining DAG pulls point-in-time feature snapshots for labeled transactions (fraud confirmed by disputes team). Trains LightGBM with MLflow tracking. Auto-gates on AUC >= 0.92 before registration.
4. **Model registry:** Promoted through Dev → Staging → Production stages in MLflow. Staging requires a 48-hour shadow evaluation on live traffic.
5. **Deployment:** REST API on Kubernetes (FastAPI + mlflow.pyfunc.serve). Online feature retrieval from Redis (<10ms). Model returns fraud probability + top 3 feature contributions (SHAP).
6. **Monitoring:** Evidently monitors daily input feature distributions. Grafana dashboard tracks precision, recall, and F1 on confirmed labels (lag ~7 days). Alert at PSI > 0.2 or F1 drop > 5%.
7. **Retraining trigger:** Either schedule-based (weekly) or drift-triggered (PSI alert fires Airflow DAG). New model enters the pipeline at step 3.

### Q5: What is the difference between batch scoring and real-time inference? When do you choose each?

**Answer:**

| | Batch Scoring | Real-time Inference |
|---|---|---|
| Latency | Minutes to hours | <100ms |
| Trigger | Schedule (nightly, hourly) | User request or event |
| Use case | Pre-compute scores for all loans/customers | Fraud check at transaction time |
| Infrastructure | Airflow + Spark/Snowflake | REST API + feature store (Redis) |
| Feature freshness | As of last ETL run | Real-time feature computation |
| Cost | Low (warehouse compute) | Higher (always-on API servers) |

Choose batch when: decisions are not time-critical (credit limit recommendations, churn propensity for next week's marketing campaign, prepayment risk scores for portfolio management). The score is pre-computed and stored in a table that downstream applications query.

Choose real-time when: the decision must be made in the moment (fraud at checkout, loan offer during application, recommendation at page load). Requires an online feature store, model serving infrastructure, and strict SLA management.

Most mature ML platforms have both: batch for operational efficiency and real-time for the subset of use cases that genuinely need it.

### Q6: How do you manage model versioning and prevent regression when deploying a new model?

**Answer:** A structured promotion workflow:

1. **Semantic versioning in model registry:** major.minor.patch. Major = re-architecture; minor = retrain on new data; patch = bug fix in preprocessing.
2. **Shadow deployment:** New model receives copies of all production traffic and logs predictions but does not serve responses. Compare distributions for 48-72 hours before cutover.
3. **Canary deployment:** Route 5% of traffic to new model. Monitor business KPIs and technical metrics. Ramp to 25%, 50%, 100% if no regression.
4. **Automated regression gate:** Before promoting to Production in MLflow, a CI job runs the new model on a held-out evaluation set and fails if any metric degrades by more than a defined threshold vs. the current Production version.
5. **Rollback capability:** The previous Production version is archived, not deleted. If a regression is detected post-deployment, `transition_model_version_stage(version=prev_version, stage="Production")` restores it within minutes.
6. **Prediction logging:** Every production prediction is logged with the model version that produced it. This enables post-hoc analysis of which version was responsible for an outcome.

### Q7: How does Airflow differ from Kubeflow Pipelines for ML orchestration?

**Answer:** Both are DAG-based orchestrators, but they optimize for different audiences and infrastructure:

| Dimension | Airflow | Kubeflow Pipelines |
|---|---|---|
| Primary audience | Data engineers | ML engineers / data scientists |
| Infrastructure | Any (cloud, on-prem, managed) | Kubernetes-native |
| Abstraction level | Python tasks, SQL operators | ML-specific steps (training, evaluation, serving) |
| UI | General pipeline monitoring | ML-specific: lineage, artifact tracking |
| Integration | 700+ provider packages | Native with TFX, Vertex AI, KFServing |
| Learning curve | Lower for data engineers | Higher (requires Kubernetes knowledge) |
| Trigger model | Schedule + sensors | Event-driven + manual |

In practice, many organizations use Airflow for data pipeline orchestration (ingestion, feature engineering) and Kubeflow or SageMaker Pipelines for the training-evaluation-deployment loop, with Airflow triggering the ML pipeline as a downstream step. This plays to each tool's strengths.

### Q8: What is training-serving skew, and how do you prevent it?

**Answer:** Training-serving skew occurs when the features used to train a model are computed differently than the features computed at prediction time. The model's performance measured offline is not reproduced in production.

Common causes:
- Training features computed in pandas; serving features computed in Java/Go with different null handling
- Training uses a date windowed historical average; serving recomputes the window incorrectly
- Training applies a log transform; the serving pipeline omits it

Prevention strategies:
1. **Single feature definition:** Define features in one place (feature store, dbt model, or SQL function) and use the same definition for both training data generation and real-time feature retrieval.
2. **Integration tests:** At model promotion time, run a test that generates features two ways (training pipeline vs. serving pipeline) for the same set of records and asserts they are equal within floating-point tolerance.
3. **Prediction logging + replay:** Log raw inputs (pre-feature-engineering) and recompute features offline. If offline features diverge from what the model saw at serving time, skew is present.
4. **Typed feature contracts:** Use Python type hints and Pydantic models to define feature schemas. Any pipeline that produces training data or serving data must conform to the same schema.

### Q9: How do you monitor a model in production when ground truth labels arrive with a significant delay?

**Answer:** This is a common problem in lending (prepayment/default known only after months), insurance (claims take months to resolve), and fraud (disputes take 30-60 days).

Strategies:

1. **Proxy metrics:** Monitor metrics that correlate with model quality but are available immediately. For a fraud model: approval rate, chargeback rate (available faster than dispute resolution), population stability index of scores.
2. **Cohort tracking:** Tag each prediction with the origination date. When labels arrive (even 90 days later), join them back to the prediction cohort and compute accuracy. Track Gini/AUC by origination month.
3. **Input drift as leading indicator:** If input features drift, performance will likely drift before labels confirm it. Treat significant input drift as a proactive re-training trigger.
4. **Early label sampling:** For some domains, a sample of labels is available faster (expedited fraud reviews, early repayments). Use this sample for early performance estimates with appropriate confidence intervals.
5. **Champion-challenger framework:** Continuously run a retrained challenger model in shadow mode. When labels arrive, you have a direct comparison of champion vs. challenger accuracy on the same cohort, enabling data-driven promotion decisions.

### Q10: Describe how you would build a Snowflake-native MLOps pipeline without leaving the Snowflake platform.

**Answer:** Snowflake provides a complete set of ML building blocks:

1. **Feature engineering:** dbt models or Snowpark Python compute features as materialized Snowflake tables with time-travel enabled. The Snowflake Feature Store (GA 2025) manages feature registration and retrieval.
2. **Training:** Snowpark ML `snowflake.ml.modeling` wraps scikit-learn and XGBoost to run training compute on Snowflake virtual warehouses. No data leaves Snowflake.
3. **Experiment tracking:** Snowflake-managed MLflow (via Snowpark ML) stores runs, metrics, and artifacts in the Snowflake account.
4. **Model registry:** Snowflake Model Registry (GA 2025) stores models as versioned objects directly in Snowflake. Models are deployed as Snowflake Model objects.
5. **Batch inference:** `model.run(test_df)` or `SELECT my_model!PREDICT(features)` in SQL — scoring runs on Snowflake compute.
6. **Monitoring:** Snowpark Python functions compute PSI/KS drift statistics on schedule. Results stored in monitoring tables. Alerting via Snowflake Alerts and notification integrations.
7. **Orchestration:** Snowflake Tasks and DAG syntax (AFTER clause) orchestrate the full pipeline: feature refresh → drift check → conditional retraining → model promotion.

The advantage: zero data movement, unified governance, single billing. The limitation: less flexibility than open-source tooling and harder to integrate with non-Snowflake serving infrastructure.

---

## Pro Tips

- **Version your training datasets, not just your models.** A model is only reproducible if you can recreate the exact training data. Store dataset snapshots in S3 with a hash, or use Snowflake time travel to tag the exact timestamp used for training.
- **The feature store is infrastructure, not a data science tool.** Data engineers should own and maintain it. Data scientists should be consumers, not operators.
- **Log everything at inference time.** Input features, raw model output, model version, request latency, and any business context. You will need this when debugging a model failure 3 months from now.
- **Set AUC gates in CI/CD, not just in notebooks.** A model that passes a human eyeball test in a notebook but fails an automated AUC gate has saved your production pipeline from a regression.
- **Re-training frequency should match the rate of drift, not a calendar.** Monthly retraining for a stable use case wastes compute. A rapidly shifting fraud pattern may need daily retraining. Use drift detection to set adaptive schedules.
- **Separate model accuracy metrics from business KPI metrics.** AUC can improve while the business outcome degrades if the cost of false positives/negatives changed. Always monitor both.
- **Test your rollback procedure before you need it.** Schedule a quarterly drill where you roll back the production model to the previous version and verify the process takes under 15 minutes.
