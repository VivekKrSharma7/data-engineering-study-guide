# AutoML & Automated Data Pipelines

[Back to Index](README.md)

---

## Overview

AutoML (Automated Machine Learning) removes the need for manual algorithm selection, hyperparameter tuning, and feature engineering by automating the end-to-end ML workflow. For a senior data engineer in the secondary mortgage market, AutoML accelerates model delivery for credit risk, prepayment prediction, and anomaly detection — without requiring deep data science expertise for every model iteration. Combined with automated data pipelines and self-healing orchestration, AutoML enables production ML workflows that run reliably at scale.

---

## Key Concepts

| Concept | Description |
|---|---|
| Algorithm Selection | AutoML tests multiple model families and selects the best performer |
| Hyperparameter Tuning | Automated search over parameter space (grid, random, Bayesian) |
| Feature Engineering | Automated creation and selection of predictive features |
| Neural Architecture Search (NAS) | Automated design of neural network architectures |
| Self-Healing Pipelines | Pipelines that detect and recover from failures automatically |
| Automated Retraining | Triggered retraining based on data drift, schedule, or performance degradation |
| CI/CD for ML | Version-controlled pipelines with automated testing and deployment |
| Model Registry | Centralized store for trained models with versioning and lineage |

---

## AutoML Frameworks

### Open Source

| Framework | Strengths | Best For |
|---|---|---|
| H2O AutoML | Stacked ensembles, interpretability | Tabular, financial models |
| Auto-sklearn | scikit-learn compatible, Bayesian optimization | General tabular tasks |
| TPOT | Genetic programming, pipeline optimization | Feature engineering focus |
| PyCaret | Low-code, rapid prototyping, many algorithms | Exploratory modeling |
| AutoGluon | AutoML + deep learning, tabular/text/image | Production-ready ensembles |

### Cloud AutoML

| Platform | Product | Notes |
|---|---|---|
| Azure | Azure AutoML (ML Studio) | Deep Azure/SQL Server integration |
| AWS | AutoGluon on SageMaker | Strong distributed training |
| Google | Vertex AI AutoML | Best for structured/unstructured hybrid |
| Databricks | Databricks AutoML | Spark native, MLflow integration |
| Snowflake | ML Functions (FORECAST, ANOMALY_DETECTION) | SQL-native, no infra management |

---

## Snowflake ML Functions (AutoML-Like)

Snowflake's built-in ML functions deliver AutoML capabilities directly in SQL — critical for data engineers who need model outputs without managing Python infrastructure.

```sql
-- Automated time-series forecast for monthly prepayment rates
CREATE OR REPLACE SNOWFLAKE.ML.FORECAST prepay_forecast (
    INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'loan_monthly_cpr'),
    SERIES_COLNAME => 'pool_id',
    TIMESTAMP_COLNAME => 'report_month',
    TARGET_COLNAME => 'cpr_actual'
);

-- Generate 3-month forward CPR forecast
CALL prepay_forecast!FORECAST(
    SERIES_VALUE => TO_TIMESTAMP('2026-04-01'),
    FORECASTING_PERIODS => 3
);

-- Anomaly detection on daily loan performance
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION delinquency_anomaly (
    INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'daily_delinquency_rates'),
    SERIES_COLNAME => 'servicer_id',
    TIMESTAMP_COLNAME => 'report_date',
    TARGET_COLNAME => 'delinquency_rate',
    LABEL_COLNAME => 'is_anomaly'
);
```

---

## Hyperparameter Tuning Deep Dive

### Grid Search vs Random Search vs Bayesian

```
Method          | Coverage | Efficiency | Best When
----------------|----------|------------|---------------------------
Grid Search     | Exhaustive | Low       | Small parameter space
Random Search   | Sampled  | Medium     | Medium parameter space
Bayesian (Optuna)| Guided  | High       | Large/expensive search space
Hyperband       | Adaptive | Very High  | Deep learning, long training
```

### Bayesian Optimization with Optuna

```python
import optuna
import lightgbm as lgb
from sklearn.model_selection import cross_val_score
import numpy as np

def objective(trial):
    params = {
        'n_estimators': trial.suggest_int('n_estimators', 100, 1000),
        'max_depth': trial.suggest_int('max_depth', 3, 12),
        'learning_rate': trial.suggest_float('learning_rate', 1e-4, 0.3, log=True),
        'num_leaves': trial.suggest_int('num_leaves', 20, 300),
        'min_child_samples': trial.suggest_int('min_child_samples', 5, 100),
        'subsample': trial.suggest_float('subsample', 0.5, 1.0),
        'colsample_bytree': trial.suggest_float('colsample_bytree', 0.5, 1.0),
        'reg_alpha': trial.suggest_float('reg_alpha', 1e-8, 10.0, log=True),
        'reg_lambda': trial.suggest_float('reg_lambda', 1e-8, 10.0, log=True),
    }
    model = lgb.LGBMClassifier(**params, random_state=42)
    score = cross_val_score(model, X_train, y_train, cv=5, scoring='roc_auc').mean()
    return score

study = optuna.create_study(direction='maximize')
study.optimize(objective, n_trials=100, timeout=600)
print(f"Best AUC: {study.best_value:.4f}")
print(f"Best params: {study.best_params}")
```

---

## PyCaret for Mortgage Default Prediction

PyCaret automates model comparison, selection, and tuning in a few lines of code — ideal for benchmarking prepayment and default models against each other.

```python
from pycaret.classification import *
import pandas as pd

# Load loan performance data
df = pd.read_parquet('fannie_mae_loan_performance.parquet')

# Feature set for mortgage default prediction
features = [
    'fico_score', 'original_ltv', 'current_ltv', 'dti_ratio',
    'loan_age_months', 'original_upb', 'current_upb',
    'rate_incentive',        # current_rate - note_rate (refi incentive)
    'hpa_12m',               # 12-month house price appreciation
    'unemployment_rate',
    'loan_purpose',          # Purchase / Refi / Cash-out
    'property_type',
    'occupancy_status',
    'num_units',
    'servicer_id',
    'msa_code'
]

target = 'default_60_plus_dq'  # 60+ days delinquent within 12 months

df_model = df[features + [target]].dropna()

# Initialize PyCaret experiment
clf = setup(
    data=df_model,
    target=target,
    session_id=42,
    train_size=0.8,
    normalize=True,
    transformation=True,
    remove_multicollinearity=True,
    multicollinearity_threshold=0.85,
    fix_imbalance=True,           # mortgage defaults are rare events
    fix_imbalance_method='smote',
    fold=5,
    fold_strategy='stratifiedkfold',
    log_experiment=True,
    experiment_name='mortgage_default_automl'
)

# Compare all models — AutoML selects best
best_models = compare_models(
    include=['xgboost', 'lightgbm', 'rf', 'lr', 'et', 'gbr'],
    sort='AUC',
    n_select=3
)

# Tune best model
tuned_model = tune_model(best_models[0], optimize='AUC', n_iter=50)

# Finalize and save
final_model = finalize_model(tuned_model)
save_model(final_model, 'mortgage_default_model_v2')

# Predict on new loans
predictions = predict_model(final_model, data=df_new_loans)
```

---

## AutoGluon for Production-Grade AutoML

```python
from autogluon.tabular import TabularDataset, TabularPredictor

train_data = TabularDataset('mortgage_train.csv')
test_data  = TabularDataset('mortgage_test.csv')

# AutoGluon handles feature engineering, stacking, and ensembling automatically
predictor = TabularPredictor(
    label='default_flag',
    eval_metric='roc_auc',
    path='autogluon_mortgage_model/',
    problem_type='binary'
).fit(
    train_data=train_data,
    time_limit=3600,              # 1-hour training budget
    presets='best_quality',       # or 'medium_quality' for faster iteration
    excluded_model_types=['KNN'], # exclude slow models
    num_stack_levels=2,
    num_bag_folds=8
)

# Leaderboard of all trained models
leaderboard = predictor.leaderboard(test_data, silent=True)
print(leaderboard[['model', 'score_test', 'pred_time_test', 'fit_time']].head(10))

# Feature importance
importance = predictor.feature_importance(test_data)
```

---

## Automated Feature Engineering

### FeatureTools for Relational Data

```python
import featuretools as ft

# Define entity set from loan performance relational data
es = ft.EntitySet(id='mortgage_data')

es = es.add_dataframe(
    dataframe_name='loans',
    dataframe=loans_df,
    index='loan_id',
    time_index='origination_date'
)

es = es.add_dataframe(
    dataframe_name='monthly_performance',
    dataframe=perf_df,
    index='record_id',
    time_index='report_month'
)

es = es.add_relationship('loans', 'loan_id', 'monthly_performance', 'loan_id')

# Deep Feature Synthesis — automatically creates hundreds of features
feature_matrix, feature_defs = ft.dfs(
    entityset=es,
    target_dataframe_name='loans',
    agg_primitives=['mean', 'max', 'min', 'std', 'count', 'trend'],
    trans_primitives=['divide_numeric', 'subtract_numeric', 'month', 'year'],
    max_depth=2
)
```

---

## Self-Healing Pipelines with Airflow

```python
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.utils.dates import days_ago
from datetime import timedelta
import logging

def validate_loan_data(**context):
    """Data quality check — auto-quarantine bad records."""
    import pandas as pd
    from great_expectations.data_context import DataContext

    df = pd.read_parquet('/data/loans/daily_feed.parquet')
    context_ge = DataContext('/opt/ge_configs')
    results = context_ge.run_checkpoint(checkpoint_name='loan_data_checkpoint')

    if not results['success']:
        # Self-healing: route bad records to quarantine, continue with clean data
        bad_idx = [r['result']['unexpected_index_list'] for r in results['results'] if not r['success']]
        df_clean = df.drop(index=[i for sublist in bad_idx for i in sublist])
        df_clean.to_parquet('/data/loans/daily_feed_clean.parquet')
        logging.warning(f"Quarantined {len(df) - len(df_clean)} records")
    else:
        df.to_parquet('/data/loans/daily_feed_clean.parquet')

def detect_drift_and_retrain(**context):
    """Check model drift; trigger retraining if threshold exceeded."""
    from evidently.report import Report
    from evidently.metrics import DataDriftTable
    import mlflow

    report = Report(metrics=[DataDriftTable()])
    report.run(reference_data=reference_df, current_data=current_df)
    drift_result = report.as_dict()

    drift_share = drift_result['metrics'][0]['result']['share_of_drifted_columns']
    if drift_share > 0.2:
        logging.info(f"Drift detected ({drift_share:.1%}). Triggering retraining.")
        mlflow.projects.run(
            uri='/opt/ml_projects/mortgage_default',
            entry_point='retrain',
            parameters={'data_version': context['ds']}
        )

default_args = {
    'owner': 'data-engineering',
    'retries': 3,
    'retry_delay': timedelta(minutes=5),
    'retry_exponential_backoff': True,
    'on_failure_callback': alert_slack_on_failure
}

with DAG(
    dag_id='mortgage_model_daily_refresh',
    default_args=default_args,
    schedule_interval='0 6 * * *',
    start_date=days_ago(1),
    catchup=False,
    tags=['ml', 'mortgage', 'automl']
) as dag:

    validate = PythonOperator(task_id='validate_data', python_callable=validate_loan_data)
    drift_check = PythonOperator(task_id='detect_drift', python_callable=detect_drift_and_retrain)

    validate >> drift_check
```

---

## Automated Schema Evolution

```python
def handle_schema_evolution(new_df, schema_registry_table, conn_str):
    """
    Detect new columns in incoming data and auto-alter target table.
    Critical for loan servicer data feeds that add fields without notice.
    """
    import pandas as pd
    import sqlalchemy as sa

    engine = sa.create_engine(conn_str)

    with engine.connect() as conn:
        existing_cols = pd.read_sql(
            f"SELECT column_name, data_type FROM information_schema.columns "
            f"WHERE table_name = '{schema_registry_table}'", conn
        )

    existing_col_names = set(existing_cols['column_name'].str.lower())
    new_col_names = set(new_df.columns.str.lower())
    added_cols = new_col_names - existing_col_names

    if added_cols:
        with engine.begin() as conn:
            for col in added_cols:
                dtype = new_df[col].dtype
                sql_type = 'FLOAT' if dtype in ['float64', 'float32'] else \
                           'BIGINT' if dtype in ['int64', 'int32'] else 'NVARCHAR(500)'
                conn.execute(sa.text(
                    f"ALTER TABLE {schema_registry_table} ADD [{col}] {sql_type} NULL"
                ))
                print(f"Auto-added column: {col} ({sql_type})")
```

---

## When to Use AutoML vs Manual ML

| Scenario | Recommendation |
|---|---|
| Rapid benchmarking of model types | AutoML |
| Explainability required (regulatory) | Manual + SHAP/LIME |
| Novel domain-specific features | Manual feature engineering |
| Daily model refresh (stable features) | AutoML with drift monitoring |
| Production < 1 day turnaround | AutoML |
| Complex sequential/temporal patterns | Manual (RNN, survival models) |
| Compliance/audit trail required | MLflow + manual with full logging |

---

## Neural Architecture Search (NAS) Overview

NAS automates the design of neural network architectures using reinforcement learning, evolutionary algorithms, or gradient-based methods. In the secondary mortgage market, NAS is rarely used directly but appears in cloud AutoML products (Google AutoML Tables uses NAS under the hood). Key concepts:

- **DARTS**: Differentiable Architecture Search — gradient-based, efficient
- **ENAS**: Efficient NAS — parameter sharing across child networks
- **ProxylessNAS**: Hardware-aware NAS for latency constraints
- Practical relevance: AutoGluon's `best_quality` preset includes NAS-derived architectures for tabular data

---

## Interview Q&A

**Q1: A credit model needs daily retraining on updated loan performance data. How would you design an automated pipeline?**

The pipeline consists of four layers: ingestion, validation, training, and deployment. Airflow (or Prefect) orchestrates daily runs. On ingest, Great Expectations validates the loan data feed — bad records go to a quarantine table, not a pipeline failure. If data quality passes, the pipeline checks for feature drift using Evidently; if drift exceeds a threshold (e.g., 20% of features drifted), retraining is triggered automatically. The retraining job uses PyCaret or AutoGluon to benchmark models against the prior champion. MLflow logs all runs; if the challenger beats the champion on AUC by a set margin (e.g., +0.005), the challenger promotes automatically. The winning model is registered in MLflow Model Registry and pushed to the serving layer. Rollback is automatic if champion performance degrades on the next day's production predictions vs actual outcomes.

**Q2: What is the difference between grid search, random search, and Bayesian optimization for hyperparameter tuning?**

Grid search exhaustively evaluates every combination in a defined parameter grid — guaranteed to find the best in the grid but computationally expensive and scales poorly with parameter count. Random search samples random combinations from the parameter distributions; empirically it finds good solutions faster than grid search when only a few parameters matter significantly. Bayesian optimization (Optuna, Hyperopt) builds a probabilistic surrogate model of the objective function and uses it to guide the next trial toward promising regions — it converges faster than random search on expensive-to-evaluate models. For mortgage default models with LightGBM, Bayesian optimization typically finds near-optimal parameters in 50-100 trials vs 500+ for grid search.

**Q3: How do Snowflake's FORECAST and ANOMALY_DETECTION functions relate to AutoML?**

They are SQL-native AutoML functions. FORECAST uses a proprietary time-series algorithm (similar to Prophet) that automatically handles seasonality, trend, and holiday effects without exposing hyperparameters to the user — the "auto" is in the algorithm selection and configuration. ANOMALY_DETECTION fits a model on labeled or unlabeled data and scores new observations for statistical anomalies. For a data engineer, they are transformational because they eliminate the Python infrastructure requirement: no Spark cluster, no model serving endpoint, no feature store — just SQL. The tradeoff is limited model interpretability and no ability to customize the underlying algorithm.

**Q4: What is self-healing in the context of automated data pipelines?**

Self-healing means a pipeline detects a failure condition and takes corrective action without human intervention, rather than simply failing and alerting. Examples in the mortgage context: (1) Schema evolution — a servicer adds a new field to their daily feed; the pipeline detects the new column, alters the target table, and continues processing rather than erroring out. (2) Data quality failures — instead of halting, the pipeline quarantines bad records, logs them for review, and processes the clean subset. (3) Missing partitions — if an upstream table partition is missing, the pipeline retries with exponential backoff and falls back to the prior day's partition after N retries. (4) Model degradation — if scoring latency spikes, the pipeline automatically routes traffic to a simpler model. The key design principle is fail gracefully and continue, not fail hard and block.

**Q5: How does automated feature engineering (FeatureTools) differ from manual feature engineering?**

FeatureTools uses Deep Feature Synthesis (DFS) to automatically create features by applying aggregation (mean, max, count, trend) and transformation primitives across related tables. For relational mortgage data (loans + monthly performance + property), it can generate hundreds of features like "mean monthly delinquency rate over loan lifetime" or "trend in LTV over last 6 months" without explicit coding. The advantage is coverage — it finds feature combinations a human might overlook. The disadvantage is interpretability and volume: you may get 500 features, many of which are noise, requiring subsequent feature selection. Manual feature engineering applies domain knowledge — a mortgage analyst knows that rate incentive (note rate minus current market rate) is the primary prepayment driver, so that feature gets crafted precisely. Best practice is to use FeatureTools for discovery, then refine with domain knowledge.

**Q6: Describe a CI/CD pipeline for an ML model in a regulated environment.**

In a secondary mortgage market context with regulatory constraints (SR 11-7 model risk management guidelines): the pipeline has four gates. (1) Development: data scientists commit model code and config to Git; automated unit tests run on feature transformations and model outputs. (2) Validation: automated model validation runs on a holdout dataset — checks AUC, KS statistic, PSI (population stability index) against the prior champion; results are logged to MLflow and posted to a model risk review queue. (3) Staging: the model is deployed to a staging environment where it scores a recent sample of production loans; predicted vs actual comparisons run against business logic rules. (4) Production: promotion requires automated gate checks (AUC > threshold, PSI < 0.2, no new data dependencies without documentation). Model artifacts, training data version, and feature definitions are all versioned. Any production model can be rolled back by promoting the prior registry version.

**Q7: When would you NOT use AutoML for a mortgage market model?**

Three primary cases: (1) Regulatory explainability — if the model is used in adverse action notices (ECOA/Reg B), you need full feature-level explanations. AutoML ensembles (stacked models) are difficult to explain to regulators. SHAP values help but complex AutoML stacks add model risk management overhead. (2) Survival/competing risks — prepayment modeling with prepayment/default/curtailment as competing events requires survival models (Cox PH, Fine-Gray); AutoML frameworks do not natively support competing risks. (3) Novel data types — if your alpha is in engineering custom NLP features from servicer notes or satellite imagery for property valuation, AutoML's generic primitives won't capture the signal. Use AutoML for algorithm selection once features are engineered manually.

**Q8: How does Prefect differ from Airflow for automated ML pipelines?**

Airflow uses a DAG-first model where workflows are statically defined in Python files that Airflow polls; the scheduler requires a metadata database and is operationally heavier. Prefect uses a flow-first model where Python functions become tasks with minimal decoration; the control plane is cloud-hosted (Prefect Cloud) or self-managed, and local development/testing is simpler. For ML pipelines specifically: Prefect's dynamic task mapping is cleaner for variable-length work (e.g., score each active loan pool separately — the number of pools changes daily). Prefect's native result caching reduces redundant computation across retries. Airflow has broader ecosystem adoption and more community plugins for data engineering (S3, Snowflake, dbt operators). In practice, many mortgage shops use Airflow for ELT orchestration and add Prefect or Metaflow specifically for ML workflows where dynamic parallelism matters.

**Q9: What is population stability index (PSI) and why does it trigger automated retraining?**

PSI measures how much a variable's distribution has shifted between a reference period and a current period. It's calculated as: PSI = sum[(Actual% - Expected%) * ln(Actual% / Expected%)]. Thresholds: PSI < 0.1 = no change, 0.1-0.2 = moderate shift, > 0.2 = significant shift requiring investigation. In automated retraining pipelines, PSI is computed on the model's input feature distributions and on predicted score distributions before each scoring run. A PSI > 0.2 on the score distribution indicates the population being scored has changed materially from the training population — the model's discriminative power may have degraded and retraining is warranted. PSI is preferred over statistical tests like KS in regulated environments because it has established industry thresholds and is referenced explicitly in SR 11-7 guidance.

**Q10: Describe how you would benchmark AutoML frameworks against each other for a new mortgage model.**

Define a fixed benchmark dataset (Fannie Mae loan-level data, defined train/validation/test split, same feature set). Define evaluation metrics upfront: AUC-ROC, KS statistic, Brier score, inference latency, and training time. Run each framework (PyCaret, AutoGluon, H2O AutoML, Azure AutoML) with a fixed time budget (e.g., 2 hours each) and identical compute. Log all results to MLflow with framework name, version, hyperparameters found, and metrics. The comparison should include not just accuracy but: (1) ease of deployment — can the model be exported to ONNX or PMML for SQL Server scoring? (2) explainability — does it produce SHAP values natively? (3) retraining speed — how long does incremental retraining take on 1 month of new data? (4) Snowflake/Azure compatibility — can it run in the cloud environment without custom infra? AutoGluon typically wins on accuracy; PyCaret wins on iteration speed and interpretability; Azure AutoML wins on integration with the Azure ecosystem.

---

## Pro Tips

- **Optuna pruning**: Use `optuna.pruners.HyperbandPruner` to terminate unpromising trials early — reduces hyperparameter search time by 50-70% on LightGBM models.
- **AutoGluon presets**: `medium_quality` trains in ~10% of the time of `best_quality` with ~95% of the performance for initial benchmarking. Use it for daily iteration, `best_quality` only for quarterly model refresh.
- **Snowflake ML Functions + dbt**: Wrap Snowflake FORECAST calls in dbt models using `{{ config(materialized='table') }}` — this integrates AutoML outputs directly into your dbt lineage graph.
- **PSI before retraining**: Always compute PSI before AutoML retraining. If the current population is an outlier (market dislocation, COVID), retraining on it may hurt performance on the normalized future population.
- **MLflow autolog**: Call `mlflow.lightgbm.autolog()` or `mlflow.sklearn.autolog()` before any AutoML run — it automatically captures parameters, metrics, and artifacts without code changes.
- **SR 11-7 compliance**: AutoML models in regulated environments need a Model Risk Management (MRM) submission. Document the algorithm search space, selection criteria, and validation methodology explicitly — "AutoML selected the best model" is not sufficient for regulators.
- **Self-healing vs alerting**: Implement both. Self-healing handles recoverable conditions (bad rows, missing partitions); alerting handles conditions requiring human judgment (unexpected data type change, 40%+ data volume drop, model AUC drop > 0.05).
