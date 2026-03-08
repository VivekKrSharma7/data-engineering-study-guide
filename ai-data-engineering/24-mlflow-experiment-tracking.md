# MLflow & Experiment Tracking
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

MLflow is the de facto open-source platform for managing the ML lifecycle: tracking experiments, packaging code, versioning models, and deploying to production. For a data engineer working at the intersection of data infrastructure and model development, MLflow is the connective tissue between the data pipeline (which produces training data) and the inference pipeline (which serves trained models).

In the US secondary mortgage market, where multiple competing model versions for prepayment prediction, credit risk, and servicing analytics may run simultaneously, MLflow provides the audit trail and governance layer required by model risk management frameworks like SR 11-7.

---

## MLflow Component Overview

| Component | Purpose | Analogy |
|---|---|---|
| MLflow Tracking | Log parameters, metrics, artifacts per experiment run | Git for model runs |
| MLflow Projects | Package ML code for reproducible execution | Docker for ML code |
| MLflow Models | Standard model packaging with multiple flavors | Universal model format |
| MLflow Model Registry | Version, stage, and promote models | Artifact repository for models |
| MLflow UI | Web interface for browsing experiments | GitHub UI for experiments |

---

## MLflow Tracking: Core Concepts

### Hierarchy

```
MLflow Server
└── Experiment (e.g., "prepayment_model_v2_development")
    ├── Run 1  (e.g., GBM with lr=0.05, depth=5)
    │   ├── Parameters  {learning_rate: 0.05, max_depth: 5, ...}
    │   ├── Metrics     {roc_auc: 0.832, avg_precision: 0.421, ...}
    │   ├── Tags        {data_version: "20250301", engineer: "jsmith"}
    │   └── Artifacts   {model/, feature_importance.png, confusion_matrix.csv}
    ├── Run 2  (e.g., XGBoost with different params)
    └── Run 3  (e.g., Logistic Regression baseline)
```

### Complete Tracking Workflow — Prepayment Model

```python
import mlflow
import mlflow.sklearn
import mlflow.xgboost
import pandas as pd
import numpy as np
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import (
    roc_auc_score, average_precision_score,
    brier_score_loss, classification_report
)
from sklearn.calibration import calibration_curve
import matplotlib.pyplot as plt
import shap

# ── Setup ──────────────────────────────────────────────────────────────────
mlflow.set_tracking_uri("http://mlflow.internal:5000")
mlflow.set_experiment("prepayment_model_quarterly_retrain")

# ── Data loading ───────────────────────────────────────────────────────────
df = pd.read_parquet("s3://mortgage-ml-data/training/prepay_features_20250301.parquet")

FEATURE_COLS = [
    "coupon_spread", "current_ltv", "fico_at_origination",
    "seasoning_months", "burnout_count", "loan_purpose_encoded",
    "property_type_encoded", "ltv_band_encoded",
]
X = df[FEATURE_COLS]
y = df["prepay_label"]

X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.20, stratify=y, random_state=42
)
X_train, X_val, y_train, y_val = train_test_split(
    X_train, y_train, test_size=0.15, stratify=y_train, random_state=42
)

# ── Training run ───────────────────────────────────────────────────────────
params = {
    "n_estimators":  400,
    "max_depth":     5,
    "learning_rate": 0.04,
    "subsample":     0.80,
    "min_samples_leaf": 50,
    "random_state":  42,
}

with mlflow.start_run(run_name="GBM_v4_coupon_spread_feature") as run:
    run_id = run.info.run_id

    # ── Log parameters ──────────────────────────────────────────────────
    mlflow.log_params(params)

    # ── Log data metadata as tags ───────────────────────────────────────
    mlflow.set_tags({
        "data_version":       "20250301",
        "data_source":        "servicer_tape_v2",
        "feature_dbt_hash":   "a3f9c2d",
        "engineer":           "jsmith",
        "model_type":         "GradientBoostingClassifier",
        "mortgage_segment":   "agency_conforming",
    })

    # ── Train ───────────────────────────────────────────────────────────
    model = GradientBoostingClassifier(**params)
    model.fit(X_train, y_train)

    # ── Evaluate on validation set (used for hyperparameter decisions) ──
    val_proba  = model.predict_proba(X_val)[:, 1]
    val_auc    = roc_auc_score(y_val, val_proba)
    val_ap     = average_precision_score(y_val, val_proba)
    val_brier  = brier_score_loss(y_val, val_proba)

    mlflow.log_metrics({
        "val_roc_auc":          val_auc,
        "val_avg_precision":    val_ap,
        "val_brier_score":      val_brier,
    })

    # ── Evaluate on held-out test set (never used for tuning) ──────────
    test_proba = model.predict_proba(X_test)[:, 1]
    test_auc   = roc_auc_score(y_test, test_proba)
    test_ap    = average_precision_score(y_test, test_proba)
    test_brier = brier_score_loss(y_test, test_proba)

    mlflow.log_metrics({
        "test_roc_auc":         test_auc,
        "test_avg_precision":   test_ap,
        "test_brier_score":     test_brier,
        "test_positive_rate":   float(y_test.mean()),
        "test_n_samples":       len(y_test),
    })

    # ── Cross-validation on full training data ──────────────────────────
    cv_scores = cross_val_score(
        GradientBoostingClassifier(**params),
        pd.concat([X_train, X_val]),
        pd.concat([y_train, y_val]),
        cv=5, scoring="roc_auc", n_jobs=-1
    )
    mlflow.log_metric("cv_roc_auc_mean", cv_scores.mean())
    mlflow.log_metric("cv_roc_auc_std",  cv_scores.std())

    # ── Log artifacts ───────────────────────────────────────────────────

    # Feature importance plot
    fig, ax = plt.subplots(figsize=(10, 6))
    importances = pd.Series(model.feature_importances_, index=FEATURE_COLS)
    importances.sort_values().plot.barh(ax=ax)
    ax.set_title("Feature Importances — Prepayment Model v4")
    ax.set_xlabel("Importance Score")
    plt.tight_layout()
    mlflow.log_figure(fig, "feature_importance.png")
    plt.close()

    # Calibration plot
    prob_true, prob_pred = calibration_curve(y_test, test_proba, n_bins=20)
    fig2, ax2 = plt.subplots(figsize=(8, 6))
    ax2.plot(prob_pred, prob_true, marker='o', label='Model')
    ax2.plot([0, 1], [0, 1], 'k--', label='Perfect calibration')
    ax2.set_xlabel("Mean Predicted Probability")
    ax2.set_ylabel("Fraction of Positives")
    ax2.set_title("Calibration Curve — Prepayment Model v4")
    ax2.legend()
    mlflow.log_figure(fig2, "calibration_curve.png")
    plt.close()

    # SHAP summary (explanation artifact)
    explainer = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(X_test.sample(500, random_state=42))
    fig3, ax3 = plt.subplots(figsize=(10, 6))
    shap.summary_plot(shap_values, X_test.sample(500, random_state=42),
                      show=False)
    mlflow.log_figure(plt.gcf(), "shap_summary.png")
    plt.close()

    # Classification report as text artifact
    test_labels = (test_proba >= 0.15).astype(int)
    report = classification_report(y_test, test_labels,
                                   target_names=["No Prepay", "Prepay"])
    mlflow.log_text(report, "classification_report.txt")

    # ── Log model with signature ────────────────────────────────────────
    from mlflow.models.signature import infer_signature

    signature = infer_signature(X_train, model.predict_proba(X_train)[:, 1])
    input_example = X_train.head(5)

    mlflow.sklearn.log_model(
        sk_model=model,
        artifact_path="model",
        signature=signature,
        input_example=input_example,
        registered_model_name="PrepaymentModel",
    )

    print(f"Run ID: {run_id}")
    print(f"Test AUC: {test_auc:.4f}")
    print(f"Test Avg Precision: {test_ap:.4f}")
    print(f"Model registered: PrepaymentModel")
```

---

## MLflow Model Registry

The Model Registry provides a governance layer on top of raw run artifacts. It tracks model versions, lifecycle stages, and transition history.

### Stages

| Stage | Meaning | Who Can Promote |
|---|---|---|
| None | Just registered, no stage assigned | MLflow auto-assigns on registration |
| Staging | Validated offline; ready for shadow mode or canary testing | Data scientist / DE |
| Production | Live in production inference service | Data engineer / MLOps |
| Archived | Superseded; kept for audit trail | Automated on production promotion |

### Model Registry Operations

```python
from mlflow.tracking import MlflowClient

client = MlflowClient(tracking_uri="http://mlflow.internal:5000")

# List all registered models
for rm in client.search_registered_models():
    print(f"Model: {rm.name}")
    for mv in rm.latest_versions:
        print(f"  Version: {mv.version}  Stage: {mv.current_stage}")

# Transition a version to Staging after offline validation
client.transition_model_version_stage(
    name="PrepaymentModel",
    version="4",
    stage="Staging",
    archive_existing_versions=False,  # Keep old Staging version accessible
)

# Add a descriptive comment to the version
client.update_model_version(
    name="PrepaymentModel",
    version="4",
    description=(
        "GBM v4 retrained on 2025-03-01 servicer tape. "
        "Adds coupon_spread feature. Test AUC 0.832 (+2.1% vs v3). "
        "Validated against Q4-2024 holdout cohort."
    ),
)

# Promote to Production (archives current Production version automatically)
client.transition_model_version_stage(
    name="PrepaymentModel",
    version="4",
    stage="Production",
    archive_existing_versions=True,  # Archive v3 → Archived
)

# Load production model in inference service
production_model = mlflow.pyfunc.load_model(
    model_uri="models:/PrepaymentModel/Production"
)

# Load a specific version (useful for reproducibility audits)
v3_model = mlflow.pyfunc.load_model(
    model_uri="models:/PrepaymentModel/3"
)
```

### Model Registry with Champion/Challenger Governance

```python
def promote_challenger_if_better(
    model_name: str,
    challenger_version: str,
    min_improvement_pct: float = 1.0,
) -> bool:
    """
    Promote challenger to Production only if it improves on the champion
    by at least min_improvement_pct on the primary metric (test_roc_auc).
    """
    client = MlflowClient(tracking_uri="http://mlflow.internal:5000")

    # Get champion metrics
    champion_versions = client.get_latest_versions(
        model_name, stages=["Production"]
    )
    if not champion_versions:
        # No production model exists; auto-promote
        client.transition_model_version_stage(
            name=model_name, version=challenger_version, stage="Production"
        )
        return True

    champion_run_id = champion_versions[0].run_id
    champion_metrics = client.get_run(champion_run_id).data.metrics
    champion_auc = champion_metrics.get("test_roc_auc", 0.0)

    # Get challenger metrics
    challenger_versions = client.get_latest_versions(
        model_name, stages=["Staging"]
    )
    if not challenger_versions:
        raise ValueError(f"No model in Staging for {model_name}")
    challenger_run_id = challenger_versions[0].run_id
    challenger_metrics = client.get_run(challenger_run_id).data.metrics
    challenger_auc = challenger_metrics.get("test_roc_auc", 0.0)

    improvement_pct = (challenger_auc - champion_auc) / champion_auc * 100
    print(f"Champion AUC: {champion_auc:.4f}")
    print(f"Challenger AUC: {challenger_auc:.4f}")
    print(f"Improvement: {improvement_pct:.2f}%")

    if improvement_pct >= min_improvement_pct:
        client.transition_model_version_stage(
            name=model_name, version=challenger_version,
            stage="Production", archive_existing_versions=True
        )
        print(f"Promoted version {challenger_version} to Production")
        return True
    else:
        print(f"Challenger did not improve by {min_improvement_pct}%. Not promoted.")
        return False
```

---

## Auto-Logging

MLflow's auto-logging instruments popular frameworks with a single line, capturing parameters, metrics, and model artifacts automatically.

```python
# scikit-learn auto-logging
mlflow.sklearn.autolog(
    log_input_examples=True,
    log_model_signatures=True,
    log_models=True,
    registered_model_name="PrepaymentModel",
)

# XGBoost auto-logging — also logs training curve per boosting round
mlflow.xgboost.autolog()

# PyTorch auto-logging
mlflow.pytorch.autolog()

# Example with sklearn: all params, metrics, CV scores, and model are logged
with mlflow.start_run(run_name="autolog_gbm_v4"):
    model = GradientBoostingClassifier(n_estimators=300, max_depth=5)
    model.fit(X_train, y_train)
    # No explicit log calls needed — autolog captured everything
```

**Caveat for production use:** Auto-logging captures everything, which can be verbose. For production pipelines, prefer explicit logging — it documents exactly what the team cares about and avoids logging sensitive data inadvertently.

---

## MLflow Models: Flavors and Signatures

```python
# Model flavors allow the same artifact to be loaded by different consumers
# A GBM saved with mlflow.sklearn.log_model supports:
#   - python_function (universal pyfunc API)
#   - sklearn (native sklearn API)
#   - onnx (after conversion, added separately)

# Model signature enforces input/output schema
from mlflow.models.signature import ModelSignature
from mlflow.types.schema import Schema, ColSpec

input_schema = Schema([
    ColSpec("double", "coupon_spread"),
    ColSpec("double", "current_ltv"),
    ColSpec("integer", "fico_at_origination"),
    ColSpec("integer", "seasoning_months"),
    ColSpec("integer", "burnout_count"),
])
output_schema = Schema([ColSpec("double", "prepay_probability")])

signature = ModelSignature(inputs=input_schema, outputs=output_schema)

# Custom pyfunc model — wraps preprocessing + model in one artifact
class PrepaymentModelWrapper(mlflow.pyfunc.PythonModel):
    """
    Wraps preprocessing, the GBM model, and calibration in a single
    MLflow artifact so inference code never needs to replicate
    preprocessing logic separately.
    """

    def load_context(self, context):
        import pickle
        with open(context.artifacts["model_path"], "rb") as f:
            self.model = pickle.load(f)
        with open(context.artifacts["preprocessor_path"], "rb") as f:
            self.preprocessor = pickle.load(f)

    def predict(self, context, model_input):
        processed = self.preprocessor.transform(model_input)
        proba = self.model.predict_proba(processed)[:, 1]
        return pd.DataFrame({"prepay_probability": proba})

# Log the wrapped model
with mlflow.start_run():
    import pickle
    pickle.dump(trained_preprocessor, open("/tmp/preprocessor.pkl", "wb"))
    pickle.dump(trained_model,        open("/tmp/model.pkl", "wb"))

    mlflow.pyfunc.log_model(
        artifact_path="wrapped_model",
        python_model=PrepaymentModelWrapper(),
        artifacts={
            "model_path":        "/tmp/model.pkl",
            "preprocessor_path": "/tmp/preprocessor.pkl",
        },
        signature=signature,
        registered_model_name="PrepaymentModel",
    )
```

---

## Custom Metric Logging for Mortgage Domain

Standard ML metrics (AUC, precision, recall) do not capture business value. For mortgage, log domain-specific metrics alongside standard ones.

```python
def log_mortgage_domain_metrics(y_true, y_proba, upb_series,
                                  threshold: float = 0.15):
    """
    Compute and log mortgage-specific model performance metrics.

    Parameters
    ----------
    y_true    : actual prepayment labels (0/1)
    y_proba   : predicted prepayment probability
    upb_series: unpaid principal balance for each loan
    threshold : classification threshold for prepayment flag
    """
    y_pred = (y_proba >= threshold).astype(int)

    # Standard metrics
    mlflow.log_metrics({
        "test_roc_auc":       roc_auc_score(y_true, y_proba),
        "test_avg_precision": average_precision_score(y_true, y_proba),
        "test_brier_score":   brier_score_loss(y_true, y_proba),
    })

    # Mortgage domain metrics

    # 1. UPB coverage: what % of outstanding balance do predicted prepayers represent?
    predicted_prepay_upb = upb_series[y_pred == 1].sum()
    total_upb            = upb_series.sum()
    mlflow.log_metric("predicted_prepay_upb_pct",
                      predicted_prepay_upb / total_upb)

    # 2. Capture rate: of actual prepayments (by UPB), what % did we predict?
    actual_prepay_upb    = upb_series[y_true == 1].sum()
    caught_prepay_upb    = upb_series[(y_true == 1) & (y_pred == 1)].sum()
    capture_rate         = caught_prepay_upb / actual_prepay_upb if actual_prepay_upb > 0 else 0
    mlflow.log_metric("upb_weighted_capture_rate", capture_rate)

    # 3. Concentration: top decile of scores — what % of actual prepays fall here?
    threshold_decile     = np.percentile(y_proba, 90)
    top_decile_precision = y_true[y_proba >= threshold_decile].mean()
    mlflow.log_metric("top_decile_precision", top_decile_precision)

    # 4. Lift at top decile
    baseline_rate  = y_true.mean()
    lift_decile    = top_decile_precision / baseline_rate if baseline_rate > 0 else 0
    mlflow.log_metric("lift_at_top_decile", lift_decile)

    # 5. Gain chart data logged as a CSV artifact
    sorted_idx = np.argsort(y_proba)[::-1]
    gain_curve = []
    for pct in range(10, 110, 10):
        n = int(len(y_true) * pct / 100)
        gain = y_true.iloc[sorted_idx[:n]].sum() / y_true.sum()
        gain_curve.append({"pct_scored": pct, "pct_prepays_captured": gain})

    gain_df = pd.DataFrame(gain_curve)
    gain_df.to_csv("/tmp/gain_chart.csv", index=False)
    mlflow.log_artifact("/tmp/gain_chart.csv", artifact_path="evaluation")
```

---

## Snowflake Integration with MLflow

```python
# Log Snowpark ML model training run in MLflow
import mlflow
from snowflake.ml.modeling.ensemble import GradientBoostingClassifier as SnowGBC
from snowflake.ml.modeling.metrics import roc_auc_score as snow_roc_auc
import snowflake.snowpark as snowpark

def train_snowpark_model_with_mlflow(session: snowpark.Session):
    mlflow.set_tracking_uri("http://mlflow.internal:5000")
    mlflow.set_experiment("prepayment_snowpark")

    train_df = session.table("ML_STAGING.PREPAY_FEATURES_TRAIN")
    test_df  = session.table("ML_STAGING.PREPAY_FEATURES_TEST")

    FEATURE_COLS = [
        "COUPON_SPREAD", "CURRENT_LTV", "FICO_AT_ORIGINATION",
        "SEASONING_MONTHS", "BURNOUT_COUNT"
    ]
    LABEL_COL = "PREPAY_LABEL"

    params = {
        "n_estimators": 300,
        "max_depth": 5,
        "learning_rate": 0.05,
    }

    with mlflow.start_run(run_name="SnowparkGBM_v1"):
        mlflow.log_params(params)
        mlflow.set_tag("compute_platform", "snowflake_snowpark")

        model = SnowGBC(
            input_cols=FEATURE_COLS,
            label_cols=[LABEL_COL],
            **params
        )
        model.fit(train_df)

        test_predictions = model.predict_proba(test_df)
        auc = snow_roc_auc(
            df=test_predictions,
            y_true_col_names=LABEL_COL,
            y_score_col_names=["predict_proba_1"],
        )

        mlflow.log_metric("test_roc_auc", auc)

        # Save model to Snowflake Model Registry AND MLflow
        from snowflake.ml.registry import Registry
        reg = Registry(session=session)
        reg.log_model(
            model_name="PrepaymentModel",
            version_name="v_snowpark_1",
            model=model,
            metrics={"test_roc_auc": auc},
        )

        # Also save a sklearn-equivalent to MLflow for portability
        sklearn_equiv = model.to_sklearn()
        mlflow.sklearn.log_model(
            sklearn_equiv, "model",
            registered_model_name="PrepaymentModel_Snowpark"
        )
```

---

## CI/CD Integration with MLflow

```yaml
# .github/workflows/model_training.yml
name: Prepayment Model Training Pipeline

on:
  schedule:
    - cron: '0 2 * * 1'   # Every Monday 2 AM UTC
  workflow_dispatch:
    inputs:
      force_retrain:
        description: 'Force retrain even if data hasnt changed'
        required: false
        default: 'false'

jobs:
  train_and_evaluate:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v3

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'

      - name: Install dependencies
        run: pip install -r requirements-ml.txt

      - name: Check if new training data is available
        id: data_check
        run: |
          python scripts/check_data_freshness.py
          echo "data_updated=$(cat /tmp/data_updated.txt)" >> $GITHUB_OUTPUT

      - name: Build feature matrix (dbt run)
        if: steps.data_check.outputs.data_updated == 'true'
        env:
          SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
          SNOWFLAKE_USER:    ${{ secrets.SNOWFLAKE_USER }}
          SNOWFLAKE_PASSWORD: ${{ secrets.SNOWFLAKE_PASSWORD }}
        run: |
          dbt run --select tag:ml --target prod

      - name: Train model
        env:
          MLFLOW_TRACKING_URI: ${{ secrets.MLFLOW_URI }}
          AWS_ACCESS_KEY_ID:   ${{ secrets.AWS_KEY }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET }}
        run: |
          python training/train_prepayment_model.py \
            --experiment prepayment_model_ci \
            --output-run-id /tmp/run_id.txt

      - name: Evaluate and conditionally promote
        env:
          MLFLOW_TRACKING_URI: ${{ secrets.MLFLOW_URI }}
        run: |
          python training/promote_if_better.py \
            --run-id $(cat /tmp/run_id.txt) \
            --model-name PrepaymentModel \
            --min-improvement-pct 1.0

      - name: Notify on failure
        if: failure()
        uses: slackapi/slack-github-action@v1
        with:
          payload: '{"text": "Prepayment model training pipeline FAILED. See ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"}'
        env:
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK }}
```

---

## MLflow Alternatives Comparison

| Tool | Strengths | Weaknesses | Best For |
|---|---|---|---|
| **MLflow** | Open source, universal, integrates everywhere | UI is basic, self-hosting requires work | Any team; default choice |
| **Weights & Biases (W&B)** | Excellent UI, rich visualizations, team collaboration | Paid SaaS for teams, data leaves org | Research-heavy teams, deep learning |
| **Comet ML** | Good CI/CD integration, custom panels | Paid, fewer integrations than W&B | Mid-size teams with budget |
| **Neptune** | Very detailed logging, good for large experiments | Paid, complex API | Teams running many parallel experiments |
| **Azure ML** | First-class Azure/ADF integration | Azure lock-in, complex setup | Azure shops with Databricks |
| **Databricks MLflow** | Managed MLflow with Delta Lake integration | Databricks-only, cost | Databricks-heavy data stacks |
| **SageMaker Experiments** | Deep AWS integration | AWS-only, verbose API | AWS shops |

For a SQL Server / Snowflake shop: **Self-hosted MLflow** is the correct choice. It is vendor-neutral, integrates with both Snowflake and any cloud provider, and has a well-documented Snowflake connector.

---

## MLflow UI: Key Navigation Patterns

```
MLflow UI: http://mlflow.internal:5000

Home → Experiments list
  → Click experiment → Run table
    Columns: Run Name | Date | Duration | Parameters... | Metrics...
    Use "Columns" to add custom metrics to the table view

Comparing Runs:
  1. Select 2+ runs via checkbox
  2. Click "Compare"
  3. View side-by-side parameters and metrics
  4. Visualize metric curves over training steps (if logged with step)

Searching Runs (MLflow search syntax):
  metrics.test_roc_auc > 0.82
  params.max_depth = "5" AND tags.data_version = "20250301"
  attributes.status = "FINISHED"

Artifact Browser:
  → Click run → "Artifacts" tab
  → Navigate model directory → MLmodel file shows flavors and signature
  → Preview images (calibration_curve.png, shap_summary.png) inline
```

---

## Interview Q&A

**Q1: What are the four components of MLflow, and how do they interact in a production ML workflow?**

The four components are Tracking, Projects, Models, and Model Registry.

In a production workflow they interact as follows: MLflow Tracking is used during the experimentation and training phase to log every training run's parameters, metrics, and artifacts. Once a run produces a model artifact, that model is packaged using the MLflow Models format, which defines a standard API (the `pyfunc` flavor) and a schema (the model signature). The model artifact is stored in the Tracking server's artifact store (typically S3 or Azure Blob).

The Model Registry then provides a governance layer on top of individual run artifacts. A data engineer or MLOps engineer takes the best-performing registered model version and transitions it through stages (Staging → Production). The production inference service loads models by name and stage: `mlflow.pyfunc.load_model("models:/PrepaymentModel/Production")`. This decouples the training code (which creates new versions) from the serving code (which always loads the current Production version).

MLflow Projects adds reproducibility for the training code itself — packaging the training script with its dependencies and entry points so any engineer can reproduce a past training run on any machine.

---

**Q2: How would you use MLflow to compare two competing model architectures for prepayment prediction — a gradient boosting model and a logistic regression baseline?**

Structure both as runs within the same experiment so they appear in the same comparison view:

1. Name the experiment clearly: `prepayment_model_architecture_comparison_Q1_2025`.
2. Add a `model_type` tag to each run (`GradientBoostingClassifier`, `LogisticRegression`).
3. Log an identical set of metrics for both: `test_roc_auc`, `test_avg_precision`, `test_brier_score`, `val_roc_auc`, `upb_weighted_capture_rate`. The metrics must be the same to enable side-by-side comparison.
4. Log the same evaluation artifacts for both: calibration curve, gain chart, SHAP summary.
5. In the MLflow UI, select both runs, click Compare, and review metrics. Sort by `test_avg_precision` (AP is more informative than AUC for imbalanced prepayment data).
6. Beyond the metrics comparison, consider: inference latency (log it as a metric), model size (log the artifact size), interpretability requirements (logistic regression coefficients are more defensible to model risk committees than black-box GBM).

Log the comparison outcome as a note on the winning run: why that model was chosen over the alternative. This documentation is important for SR 11-7 model validation.

---

**Q3: What is a model signature in MLflow, and why is it important for a data engineer?**

A model signature defines the expected schema for a model's inputs and outputs: column names, data types, and optionally shape. It is stored in the `MLmodel` file alongside the model artifact.

For a data engineer, the signature serves two purposes:

1. **Deployment-time contract enforcement**: When the inference service calls `model.predict(df)`, MLflow's pyfunc wrapper validates that the input DataFrame conforms to the signature before passing it to the model. If the feature pipeline produces a column with the wrong type (e.g., `seasoning_months` arrives as a string instead of an integer), the inference call fails immediately with a clear error, rather than silently producing wrong predictions.

2. **Documentation and governance**: The signature is the machine-readable contract between the feature pipeline and the model. When a data engineer modifies the feature pipeline (e.g., renames a column, changes a type), they can immediately check the model signature to see if their change breaks compatibility. This is especially important in mortgage where multiple teams (data engineering, data science, risk) share the feature pipeline.

Infer the signature at training time from real data: `signature = infer_signature(X_train, model.predict(X_train))`. Never hand-code it — use the real training data distributions to ensure the schema captures nullable columns and actual type ranges.

---

**Q4: How would you implement a CI/CD pipeline that automatically retrains and promotes a model to production if it beats the current champion?**

The pipeline has four stages, implemented as GitHub Actions jobs (or Airflow DAGs, or Azure DevOps pipelines):

1. **Data gate**: Check that new training data has arrived. Query Snowflake for the latest servicer tape date. If no new data, skip retraining (unless forced). This prevents retraining on stale data.

2. **Training job**: Run the training script with MLflow tracking enabled. The script writes the run ID to a file or environment variable for downstream steps.

3. **Champion/challenger evaluation**: Load the current Production model's metrics from MLflow. Load the new challenger model's metrics. Compare on a pre-agreed primary metric (for prepayment, `test_roc_auc` or `test_avg_precision`). If the challenger improves by at least 1% on the primary metric AND does not regress by more than 0.5% on any secondary metric, transition the challenger to Production and archive the former champion.

4. **Notification**: Post results to Slack regardless of outcome. On successful promotion, notify the model risk team that a new version is in production and the champion/challenger evaluation report is available in MLflow. On failure to promote, notify the data science team with the gap analysis.

Critical: the test set used for champion/challenger evaluation must be a **held-out time-based cohort** (e.g., loans from the most recent quarter) that neither the champion nor the challenger was trained on. This prevents evaluation inflation.

---

**Q5: Describe how you would use MLflow to maintain the audit trail required by SR 11-7 model risk management guidelines.**

SR 11-7 requires documentation of model development, validation, and performance monitoring. MLflow supports this through:

1. **Development traceability**: Every experiment and run is timestamped and immutable. Log the data version (git commit hash of dbt models, S3 path of training dataset, Snowflake table clone name) as run tags. This makes it possible to reproduce any model from any point in time.

2. **Model validation artifacts**: Log the full model validation package as MLflow artifacts: performance metrics across segments (loan purpose, property type, origination vintage), calibration analysis, out-of-time validation results, feature importance analysis, SHAP global and local explanations, and the classification report at the operational threshold.

3. **Approval workflow via stage transitions**: Use MLflow stage transitions to document the approval chain. The transition from Staging to Production is an explicit, logged action with a timestamp and user identity. Add a required comment field policy: every stage transition must include a note referencing the validation report.

4. **Version immutability**: Model artifacts in MLflow's artifact store (S3/Azure Blob) should have versioning enabled and delete protection enabled. Once a model version is registered, it should never be overwritten — only archived.

5. **Ongoing monitoring linkage**: Log quarterly performance metrics back to the original MLflow run as additional metric steps. This creates a timeline of the model's real-world performance over its lifetime, visible in the MLflow UI without leaving the model record.

---

**Q6: What is auto-logging in MLflow, and when should you use it versus explicit logging?**

Auto-logging (`mlflow.sklearn.autolog()`, `mlflow.xgboost.autolog()`, etc.) instruments the framework at the library level and automatically captures: all model hyperparameters, training metrics (including per-epoch curves for PyTorch/Keras), the fitted model artifact, model signature, and input examples.

Use auto-logging when:
- During exploratory analysis and experimentation — you want comprehensive logging with minimal code.
- You are using standard frameworks and standard metrics are sufficient.
- The team is new to MLflow and you want to reduce the barrier to tracking.

Use explicit logging when:
- In production training pipelines where you have an agreed metric set and do not want noise.
- When logging custom domain metrics (mortgage-specific metrics like UPB capture rate) that auto-logging cannot know about.
- When logging custom artifacts (gain charts, SHAP plots, calibration curves).
- When you need to control exactly what is logged to avoid inadvertently logging sensitive data (PII in input examples, for instance).
- When logging is in a shared codebase reviewed by risk/compliance teams who need to understand what is being captured.

In practice: use auto-logging in Jupyter notebooks for exploration, use explicit logging in production DAGs.

---

**Q7: How do you handle the scenario where a model was promoted to production but its performance has degraded significantly two months later? Walk me through the MLflow-based response.**

Month 2 monitoring alert fires: prepayment model AUC on last quarter's labeled cohort has dropped from 0.832 to 0.761.

MLflow-based response:

1. **Investigate in MLflow**: Open the Production model version. Review the artifact `calibration_curve.png` and `gain_chart.csv` from the original training run. Compare against current monitoring metrics to understand where performance degraded (is it the high-coupon segment? a specific origination vintage?).

2. **Feature drift check**: Retrieve the training run's feature statistics artifact. Compare against current feature distributions computed from the Snowflake feature table. If coupon_spread has drifted significantly (rates moved 200bps), PSI > 0.25 confirms this as the root cause.

3. **Rollback assessment**: If a prior Production version (now Archived) performed better against current data, transition it back to Production immediately: `client.transition_model_version_stage("PrepaymentModel", version="3", stage="Production", archive_existing_versions=True)`. This takes 30 seconds and has zero downtime if the inference service loads by stage.

4. **Emergency retrain**: Trigger the training pipeline with a fresh data window. The new training data now includes the shifted rate environment. Log the emergency retrain as a new run with tag `trigger=performance_degradation`.

5. **Root cause documentation**: Log the degradation analysis as a new artifact on the Production version: a PDF or markdown note explaining the rate environment shift, the observed PSI values, and the remediation steps. This is required for the SR 11-7 model incident documentation.

6. **Monitor**: After promoting the retrained model, increase monitoring frequency from weekly to daily for the next month.

---

**Q8: How would you integrate MLflow with Snowflake for a team that does all their data processing in Snowflake but trains models in Python?**

The integration has three touchpoints:

1. **Training data from Snowflake, logged in MLflow**: The training script queries Snowflake via `snowflake-connector-python` or Snowpark. Before training, log the Snowflake query or dbt model hash as a run tag. After training, the MLflow artifact store is S3 or Azure Blob — separate from Snowflake. This is the standard pattern.

2. **Model serving back in Snowflake**: Export the trained model (sklearn → ONNX, or save as pickle) and upload to a Snowflake stage. Register as a Snowflake UDF or Snowpark ML model. Log the Snowflake stage path and UDF name as MLflow artifacts so the deployment location is traceable from the MLflow run.

3. **Inference results and monitoring back in MLflow**: The Snowflake Task that runs daily batch scoring can write prediction statistics (mean score, score distribution, count) back to MLflow as metric steps using the Python API. This gives you a continuous time series of production metrics visible in the MLflow UI alongside the training metrics.

```python
# Snowflake Task calls this function after each batch scoring run
def log_batch_scoring_metrics_to_mlflow(
    model_run_id: str, batch_date: str,
    prediction_stats: dict
):
    client = MlflowClient(tracking_uri="http://mlflow.internal:5000")
    # Log as additional steps on the original training run
    step = int(batch_date.replace("-", ""))  # e.g., 20250301
    for metric_name, value in prediction_stats.items():
        client.log_metric(model_run_id, f"prod_{metric_name}", value, step=step)
```

---

**Q9: Compare MLflow, Weights & Biases, and Databricks MLflow. When would you choose each for a mortgage data engineering team?**

**Self-hosted MLflow**: Choose this for a mortgage shop with existing Snowflake + SQL Server infrastructure, where data governance requires on-premises or private cloud deployment, where the modeling team uses scikit-learn and XGBoost (not deep learning), and where the team does not have budget for SaaS MLops tools. Hosting cost is minimal (a single EC2/VM instance + S3 for artifacts). No data leaves the org. Full API compatibility with all cloud providers. Integrates with Airflow, dbt, Snowflake, and SQL Server natively.

**Weights & Biases**: Choose this when the team is running many parallel deep learning experiments and needs W&B's superior visualization capabilities (interactive loss curves, confusion matrices, model architecture graphs). W&B's collaboration features (shared dashboards, team experiment views) are significantly better than MLflow's. The tradeoff is data egress to W&B's SaaS platform — problematic for MNPI-adjacent data in mortgage.

**Databricks MLflow (managed)**: Choose this if the team is already running Databricks for Spark-based feature engineering or Delta Lake. Databricks MLflow is deeply integrated: jobs automatically log to MLflow, Unity Catalog governs model access, and Delta Lake time travel syncs naturally with dataset versioning. The tradeoff is cost and Databricks lock-in. For a team that's Snowflake-primary, this adds complexity without proportional benefit.

For a 16-year SQL Server/Snowflake veteran's team: self-hosted MLflow on a private cloud VM, with artifact storage in the same S3 bucket as the training data. Simple, auditable, no vendor lock-in, no data egress concerns.

---

**Q10: What is the difference between an MLflow run's parameters, metrics, and tags? Give examples from a mortgage model context.**

**Parameters** are the inputs to a training run — the configuration choices made before training begins. They are static: set once at the start of a run, never updated. Examples: `n_estimators=300`, `max_depth=5`, `learning_rate=0.05`, `smote_sampling_strategy=0.15`, `train_data_start_date=2022-01-01`.

**Metrics** are quantitative measurements of the run's outcome. They can be logged multiple times with an optional `step` parameter (e.g., loss per training epoch). Examples: `test_roc_auc=0.832`, `val_avg_precision=0.421`, `test_brier_score=0.087`, `upb_weighted_capture_rate=0.731`, `cv_roc_auc_mean=0.819`.

**Tags** are string key-value metadata about the context of the run — who ran it, why, what data it used. Tags are free-form and not constrained to numbers. Examples: `data_version=20250301`, `engineer=jsmith`, `model_type=GradientBoostingClassifier`, `trigger=scheduled_retrain`, `data_source=servicer_tape_v2`, `mortgage_segment=agency_conforming`, `dbt_feature_hash=a3f9c2d`, `sr_11_7_validation_status=pending`.

The practical difference: parameters and metrics are indexed and searchable with numeric operators (`metrics.test_roc_auc > 0.82`), while tags support equality search (`tags.data_version = "20250301"`). Use parameters for the model's configuration, metrics for measurable outcomes, and tags for contextual metadata that aids governance and search.

---

## Pro Tips

1. **Log the data version as religiously as the model version.** An MLflow run without a data version tag is an incomplete record. In mortgage, where servicer tapes update monthly and rate data updates daily, a model trained on 2025-03-01 data behaves differently from one trained on 2024-09-01 data. Log the Snowflake query hash, the dbt model git hash, and the S3 path of the feature parquet file on every run.

2. **Use a dedicated "baseline" run per experiment.** Before running any fancy models, log a logistic regression and a naive classifier (always predict the majority class) as baseline runs in the same experiment. This gives you a floor: any model below the logistic regression baseline is not worth deploying, and it calibrates how much the complexity of GBMs is actually buying you.

3. **The Model Registry is not a deployment system — it is an approval system.** Transitioning a model to Production in MLflow does not automatically update the inference service. Your inference service must be configured to poll the registry or be updated by a deployment pipeline. Make this handoff explicit and documented; a model sitting at Production stage in MLflow but not loaded by the inference service is a false sense of security.

4. **Archive, never delete.** In a regulated industry, you will need to reproduce a model decision made 3 years ago. If you deleted the run or the model artifact, you cannot. Set an MLflow artifact retention policy of never-delete (or minimum 7 years for mortgage). Storage cost for model artifacts is negligible compared to the regulatory cost of being unable to explain a credit decision.

5. **Log inference latency as a metric.** After every training run, benchmark the model's inference latency (time to score 1,000 loans). Log this as `inference_latency_ms_p99`. A model that is 2% more accurate but 10x slower may not be deployable within the SLA. Having latency as a logged metric makes this tradeoff visible in the MLflow comparison view alongside accuracy metrics.

6. **Embed MLflow run IDs in your data warehouse.** Add a `mlflow_run_id` column to your Snowflake predictions table. This creates a direct link from every prediction row in the warehouse to the exact MLflow run (and therefore exact model version, training data version, and all logged metrics) that produced it. This is invaluable for post-hoc analysis and regulatory inquiries.
