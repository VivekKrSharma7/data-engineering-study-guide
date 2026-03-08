# Snowflake ML Functions — Classification, Anomaly Detection & Forecasting

[Back to Index](../index.md)

---

## Overview

Snowflake ML Functions bring classical machine learning directly into the Snowflake SQL layer, enabling data engineers to build, train, and score models without writing Python or managing MLOps infrastructure. For a senior data engineer in the secondary mortgage market, this means MBS pool balance forecasting, prepayment speed prediction, anomaly detection on loan performance data, and default/delinquency classification — all in SQL, running inside Snowflake's compute. This guide covers every production-ready ML Function, Snowpark ML for Python-based workflows, the Model Registry, and Feature Store integration.

---

## Key Concepts at a Glance

| ML Function | Type | Use Case in Mortgage Context |
|---|---|---|
| `SNOWFLAKE.ML.FORECAST` | Time-series | Pool UPB forecasting, CPR prediction |
| `SNOWFLAKE.ML.ANOMALY_DETECTION` | Unsupervised | Detecting unusual loan payment patterns |
| `SNOWFLAKE.ML.CLASSIFICATION` | Supervised | Loan default prediction, delinquency classification |
| `SNOWFLAKE.ML.TOP_INSIGHTS` | Explainability | Explaining metric changes between periods |
| `SNOWFLAKE.ML.CONTRIBUTION_EXPLORER` | Explainability | Attributing metric change to dimensions |
| `Snowpark ML` | Python | Custom models, preprocessing, feature engineering |
| Model Registry | MLOps | Model versioning, promotion, lineage |
| Feature Store | MLOps | Feature reuse, point-in-time correctness |

---

## SNOWFLAKE.ML.FORECAST

`FORECAST` trains a time-series model and generates future predictions with confidence intervals. It uses an ensemble of statistical and ML models internally (similar to Prophet + gradient boosting) and handles seasonality, holidays, and exogenous variables automatically.

### Creating and Running a Forecast Model

```sql
-- Step 1: Create a training view with required columns
-- FORECAST requires: timestamp column, target column, optional series identifier
CREATE OR REPLACE VIEW mortgage_db.analytics.pool_upb_training AS
SELECT
    DATE_TRUNC('month', report_date)        AS report_month,    -- timestamp
    pool_id,                                                      -- series identifier
    SUM(current_unpaid_principal_balance)   AS total_upb,        -- target
    -- Optional exogenous variables (improve accuracy)
    AVG(current_coupon_rate)                AS avg_coupon,
    AVG(conditional_prepayment_rate)        AS avg_cpr,
    AVG(wac_net)                            AS avg_wac
FROM mortgage_db.analytics.loan_performance_monthly
WHERE report_date BETWEEN '2019-01-01' AND '2024-12-31'
  AND pool_type = 'FN_30YR'
GROUP BY 1, 2;

-- Step 2: Create (train) the forecast model
CREATE OR REPLACE SNOWFLAKE.ML.FORECAST mortgage_db.ml.pool_upb_forecast_model (
    INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'mortgage_db.analytics.pool_upb_training'),
    SERIES_COLNAME => 'pool_id',
    TIMESTAMP_COLNAME => 'report_month',
    TARGET_COLNAME => 'total_upb',
    CONFIG_OBJECT => {
        'ON_ERROR': 'SKIP',           -- skip pools with insufficient history
        'EVALUATE': TRUE,             -- compute holdout evaluation metrics
        'EVALUATE_CONFIG': {
            'PREDICTION_INTERVAL': 0.95,
            'TEST_SIZE': 0.15          -- 15% of history used for validation
        }
    }
);

-- Step 3: Check model training results
CALL mortgage_db.ml.pool_upb_forecast_model!SHOW_EVALUATION_METRICS();
-- Returns MAPE, SMAPE, RMSE, etc. per series (pool)

-- Step 4: Generate 6-month forward forecast
CALL mortgage_db.ml.pool_upb_forecast_model!FORECAST(
    FORECASTING_PERIODS => 6,
    CONFIG_OBJECT => {'PREDICTION_INTERVAL': 0.90}
);
-- Returns: series (pool_id), ts (future month), forecast (predicted UPB),
--          lower_bound, upper_bound

-- Step 5: Store forecast results
CREATE OR REPLACE TABLE mortgage_db.analytics.pool_upb_forecast_results AS
SELECT
    f.series                     AS pool_id,
    f.ts                         AS forecast_month,
    f.forecast                   AS predicted_upb,
    f.lower_bound                AS lower_bound_90pct,
    f.upper_bound                AS upper_bound_90pct,
    CURRENT_TIMESTAMP()          AS model_run_at,
    'pool_upb_forecast_model_v1' AS model_name
FROM TABLE(
    RESULT_SCAN(LAST_QUERY_ID())
) AS f;
```

### Forecast with Exogenous Variables (Future Values Required)

```sql
-- When using exogenous variables, you must supply future values
-- Create future exogenous data (e.g., from rate curves)
CREATE OR REPLACE TABLE mortgage_db.analytics.pool_upb_future_exog AS
SELECT
    pool_id,
    ADD_MONTHS(DATE_TRUNC('month', CURRENT_DATE()), seq4() + 1) AS report_month,
    -- Feed in rate assumptions from a rate scenario table
    s.coupon_rate_assumption                                     AS avg_coupon,
    s.cpr_assumption                                             AS avg_cpr,
    s.wac_assumption                                             AS avg_wac
FROM (SELECT DISTINCT pool_id FROM mortgage_db.analytics.pool_upb_training) AS p
CROSS JOIN mortgage_db.scenarios.base_rate_scenario_6m AS s;

CALL mortgage_db.ml.pool_upb_forecast_model!FORECAST(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE',
        'mortgage_db.analytics.pool_upb_future_exog'),
    TIMESTAMP_COLNAME => 'report_month',
    SERIES_COLNAME => 'pool_id'
);
```

### Evaluate Model Performance

```sql
-- Retrieve model evaluation metrics
CALL mortgage_db.ml.pool_upb_forecast_model!SHOW_EVALUATION_METRICS();

-- Inspect what the model learned (feature importances, seasonality)
CALL mortgage_db.ml.pool_upb_forecast_model!EXPLAIN_FEATURE_IMPORTANCE();
```

---

## SNOWFLAKE.ML.ANOMALY_DETECTION

`ANOMALY_DETECTION` trains an unsupervised (or supervised with labeled anomaly data) model to identify statistical outliers in time-series data.

### Training an Anomaly Detection Model

```sql
-- Prepare training data: loan-level payment history
-- Model learns "normal" patterns from labeled normal data
CREATE OR REPLACE VIEW mortgage_db.analytics.loan_payment_normal AS
SELECT
    loan_id,
    report_date        AS payment_date,
    days_past_due      AS dpd,
    payment_amount,
    scheduled_payment,
    payment_shortfall  AS shortfall
FROM mortgage_db.analytics.loan_performance_monthly
WHERE report_date BETWEEN '2021-01-01' AND '2023-12-31'
  AND is_anomaly = FALSE   -- use only confirmed normal periods for training
  AND days_past_due <= 30; -- exclude already-known delinquencies from normal baseline

-- Create anomaly detection model
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION mortgage_db.ml.loan_payment_anomaly_model (
    INPUT_DATA => SYSTEM$REFERENCE('VIEW',
        'mortgage_db.analytics.loan_payment_normal'),
    SERIES_COLNAME => 'loan_id',
    TIMESTAMP_COLNAME => 'payment_date',
    TARGET_COLNAME => 'dpd',
    LABEL_COLNAME => NULL   -- NULL = unsupervised; set to label column for supervised
);
```

### Detecting Anomalies on New Data

```sql
-- Score current month's data for anomalies
CALL mortgage_db.ml.loan_payment_anomaly_model!DETECT_ANOMALIES(
    INPUT_DATA => SYSTEM$REFERENCE('VIEW',
        'mortgage_db.analytics.loan_performance_current_month'),
    SERIES_COLNAME => 'loan_id',
    TIMESTAMP_COLNAME => 'payment_date',
    TARGET_COLNAME => 'dpd',
    CONFIG_OBJECT => {'PREDICTION_INTERVAL': 0.99}  -- flag only extreme outliers
);

-- Store and analyze anomalies
CREATE OR REPLACE TABLE mortgage_db.analytics.loan_anomalies_current AS
SELECT
    a.series                                   AS loan_id,
    a.ts                                       AS detection_date,
    a.y                                        AS actual_dpd,
    a.forecast                                 AS expected_dpd,
    a.lower_bound,
    a.upper_bound,
    a.is_anomaly,
    a.percentile,
    -- Enrich with loan attributes for triage
    l.servicer_id,
    l.pool_id,
    l.property_state,
    l.current_unpaid_principal_balance         AS current_upb,
    l.original_loan_amount
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))          AS a
JOIN mortgage_db.servicing.loan_master            AS l ON a.series = l.loan_id
WHERE a.is_anomaly = TRUE
ORDER BY l.current_unpaid_principal_balance DESC;  -- triage by balance

-- Pool-level anomaly rollup: identify pools with unusual delinquency spikes
SELECT
    pool_id,
    COUNT(*) AS anomaly_count,
    SUM(current_upb) AS anomaly_upb_exposure,
    AVG(actual_dpd - expected_dpd) AS avg_dpd_deviation
FROM mortgage_db.analytics.loan_anomalies_current
GROUP BY pool_id
HAVING COUNT(*) > 5
ORDER BY anomaly_upb_exposure DESC;
```

---

## SNOWFLAKE.ML.CLASSIFICATION

`CLASSIFICATION` trains a supervised binary or multi-class classifier using gradient boosting internally. Handles class imbalance automatically.

### Binary Classification: Loan Default Prediction

```sql
-- Prepare training data with features and labels
CREATE OR REPLACE VIEW mortgage_db.ml.default_training_data AS
SELECT
    -- Features
    original_loan_amount,
    original_ltv_ratio,
    original_cltv_ratio,
    original_dti_ratio,
    borrower_credit_score,
    loan_purpose,                    -- PURCHASE, REFI_RATE_TERM, REFI_CASHOUT
    occupancy_type,                  -- OWNER, INVESTOR, SECOND_HOME
    property_type,                   -- SFR, CONDO, MF_2_4, MF_5PLUS
    loan_age_at_origination,
    channel,                         -- RETAIL, BROKER, CORRESPONDENT
    property_state,
    orig_interest_rate,
    num_units,
    -- Derived features
    orig_interest_rate - benchmark_rate_at_orig AS rate_spread,
    CASE WHEN coborrower_credit_score IS NOT NULL THEN 1 ELSE 0 END AS has_coborrower,
    -- Label: 1 = defaulted within 24 months of origination
    CASE WHEN status_at_24mo IN ('REO', 'FORECLOSURE', 'SERIOUS_DELINQUENT') THEN 1
         ELSE 0 END AS defaulted_within_24m
FROM mortgage_db.analytics.loan_origination_cohorts
WHERE origination_year BETWEEN 2015 AND 2021  -- exclude recent vintages (right-censored)
  AND data_quality_flag = 'CLEAN';

-- Create (train) the classification model
CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION mortgage_db.ml.loan_default_classifier (
    INPUT_DATA => SYSTEM$REFERENCE('VIEW',
        'mortgage_db.ml.default_training_data'),
    TARGET_COLNAME => 'defaulted_within_24m',
    CONFIG_OBJECT => {
        'ON_ERROR': 'ABORT',
        'EVALUATE': TRUE
    }
);

-- Evaluate model performance
CALL mortgage_db.ml.loan_default_classifier!SHOW_EVALUATION_METRICS();
-- Returns: AUC-ROC, F1, precision, recall, confusion matrix

-- Feature importance
CALL mortgage_db.ml.loan_default_classifier!SHOW_FEATURE_IMPORTANCE();
```

### Scoring New Loans

```sql
-- Score new originations
SELECT
    l.loan_id,
    l.origination_date,
    l.borrower_credit_score,
    l.original_ltv_ratio,
    l.original_dti_ratio,
    l.property_state,
    -- CLASSIFICATION returns a variant with probabilities for each class
    r.predicted_class::INT                           AS predicted_default,
    r.probability::VARIANT:1::FLOAT                  AS default_probability,
    CASE
        WHEN r.probability::VARIANT:1::FLOAT >= 0.20 THEN 'HIGH_RISK'
        WHEN r.probability::VARIANT:1::FLOAT >= 0.08 THEN 'MEDIUM_RISK'
        ELSE 'LOW_RISK'
    END                                              AS risk_tier
FROM mortgage_db.analytics.new_originations_staging AS l,
     TABLE(mortgage_db.ml.loan_default_classifier!PREDICT(
         INPUT_DATA => TABLE(
             SELECT
                 original_loan_amount, original_ltv_ratio, original_cltv_ratio,
                 original_dti_ratio, borrower_credit_score, loan_purpose,
                 occupancy_type, property_type, loan_age_at_origination,
                 channel, property_state, orig_interest_rate, num_units,
                 orig_interest_rate - benchmark_rate_at_orig AS rate_spread,
                 CASE WHEN coborrower_credit_score IS NOT NULL THEN 1 ELSE 0 END AS has_coborrower
             FROM mortgage_db.analytics.new_originations_staging
         )
     )) AS r;
```

### Multi-Class Classification: Delinquency Status

```sql
-- Predict delinquency bucket at next reporting period
CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION mortgage_db.ml.delinquency_classifier (
    INPUT_DATA => SYSTEM$REFERENCE('VIEW',
        'mortgage_db.ml.delinquency_training_data'),
    TARGET_COLNAME => 'next_month_dpd_bucket',  -- CURRENT, 30DPD, 60DPD, 90PLUS, DEFAULT
    CONFIG_OBJECT => {'EVALUATE': TRUE}
);

CALL mortgage_db.ml.delinquency_classifier!SHOW_EVALUATION_METRICS();
-- For multi-class: weighted F1, per-class precision/recall
```

---

## SNOWFLAKE.ML.TOP_INSIGHTS

`TOP_INSIGHTS` explains why a metric changed between two time periods by identifying the dimensions (segments) that contributed most to the change.

```sql
-- Explain why total portfolio delinquency rate changed from Q3 to Q4
CALL SNOWFLAKE.ML.TOP_INSIGHTS(
    INPUT_DATA => SYSTEM$REFERENCE('VIEW',
        'mortgage_db.analytics.delinquency_by_segment'),
    METRIC_COLNAME => 'delinquency_rate',
    LABEL_COLNAME  => 'report_period',           -- 'Q3_2024' or 'Q4_2024'
    METRIC_TYPE    => 'RATIO',
    NUM_COLNAME    => 'delinquent_loan_count',    -- numerator for ratio
    DENOM_COLNAME  => 'total_loan_count',         -- denominator for ratio
    DIMENSION_COLNAMES => ['property_state', 'loan_purpose',
                           'occupancy_type', 'servicer_id',
                           'origination_year_bucket'],
    CONTROL_VALUE  => 'Q3_2024',
    TEST_VALUE     => 'Q4_2024'
);

-- Output: each row is a dimension combination with:
--   - metric_value_control (Q3 rate)
--   - metric_value_test (Q4 rate)
--   - change (absolute delta)
--   - contribution (how much this segment explains total portfolio change)
--   - category: 'INCREASING', 'DECREASING', 'MIXED'
```

---

## SNOWFLAKE.ML.CONTRIBUTION_EXPLORER

`CONTRIBUTION_EXPLORER` identifies which dimensions drive the most variance in a metric — useful for root cause analysis in pool performance reviews.

```sql
-- Identify which servicer/state combinations explain CPR variance
CALL SNOWFLAKE.ML.CONTRIBUTION_EXPLORER(
    INPUT_DATA => SYSTEM$REFERENCE('VIEW',
        'mortgage_db.analytics.pool_cpr_by_segment'),
    METRIC_COLNAME     => 'conditional_prepayment_rate',
    DIMENSION_COLNAMES => ['servicer_id', 'property_state',
                           'loan_purpose', 'origination_year_bucket'],
    TIMESTAMP_COLNAME  => 'report_month',
    SERIES_COLNAME     => 'pool_id'
);
```

---

## Snowpark ML: Python-Based ML in Snowflake

Snowpark ML is the Python library for building, training, and deploying models using Snowflake's compute — data stays in Snowflake throughout.

```python
# Snowpark ML: train a custom prepayment speed model
from snowflake.snowpark import Session
from snowflake.ml.modeling.preprocessing import StandardScaler, OrdinalEncoder
from snowflake.ml.modeling.pipeline import Pipeline
from snowflake.ml.modeling.ensemble import GradientBoostingRegressor
from snowflake.ml.modeling.model_selection import cross_validate
import snowflake.ml.modeling.metrics as metrics

# Create Snowpark session
session = Session.builder.configs({
    "account":   "your_account",
    "user":      "svc_ml",
    "password":  "...",
    "database":  "mortgage_db",
    "schema":    "ml",
    "warehouse": "ML_WH"
}).create()

# Load training data as Snowpark DataFrame (stays in Snowflake)
df = session.table("mortgage_db.ml.prepayment_training_data")

FEATURE_COLS = [
    "LOAN_AGE_MONTHS", "CURRENT_LTV", "CURRENT_COUPON_MINUS_MARKET_RATE",
    "FICO_SCORE", "ORIG_LOAN_SIZE", "PROPERTY_STATE_ENCODED",
    "BURNOUT_INDICATOR", "SEASONALITY_MONTH"
]
LABEL_COL = "ACTUAL_3M_CPR"

# Build pipeline
pipeline = Pipeline(steps=[
    ("scaler",    StandardScaler(input_cols=FEATURE_COLS,
                                  output_cols=[f + "_SCALED" for f in FEATURE_COLS])),
    ("regressor", GradientBoostingRegressor(
        input_cols   = [f + "_SCALED" for f in FEATURE_COLS],
        label_cols   = [LABEL_COL],
        output_cols  = ["PREDICTED_CPR"],
        n_estimators = 300,
        max_depth    = 5,
        learning_rate = 0.05
    ))
])

# Train — computation runs in Snowflake warehouse, not local machine
pipeline.fit(df)

# Evaluate on holdout set
holdout_df = session.table("mortgage_db.ml.prepayment_holdout_data")
predictions = pipeline.predict(holdout_df)
rmse = metrics.mean_squared_error(
    df=predictions,
    y_true_col_names=[LABEL_COL],
    y_pred_col_names=["PREDICTED_CPR"],
    squared=False
)
print(f"Holdout RMSE: {rmse:.4f}")
```

---

## Snowpark ML Model Registry

The Model Registry stores versioned models, metadata, and lineage — enabling safe promotion from dev to prod without re-training.

```python
from snowflake.ml.registry import Registry

# Connect to the Model Registry
reg = Registry(session=session, database_name="mortgage_db", schema_name="ml")

# Log the trained model
model_version = reg.log_model(
    model           = pipeline,
    model_name      = "prepayment_speed_model",
    version_name    = "v3_2025Q1",
    comment         = "Retrained on 2019-2024 originations; added burnout feature",
    tags            = {
        "trained_by": "svc_ml_pipeline",
        "training_date": "2025-01-15",
        "data_vintage_end": "2024-12-31",
        "business_owner": "portfolio_analytics"
    },
    metrics         = {"rmse": rmse, "r2": r2_score},
    conda_dependencies = ["scikit-learn", "xgboost"]
)

# List available model versions
for mv in reg.get_model("prepayment_speed_model").versions():
    print(mv.version_name, mv.comment, mv.metrics)

# Load a specific version for inference
model_v3 = reg.get_model("prepayment_speed_model").version("v3_2025Q1")

# Score using registry model — runs inside Snowflake
scoring_df = session.table("mortgage_db.analytics.active_loans")
result_df = model_v3.run(scoring_df, function_name="predict")
result_df.write.save_as_table("mortgage_db.analytics.cpr_predictions_current",
                               mode="overwrite")
```

---

## MLflow Integration

Snowflake integrates with MLflow for experiment tracking, enabling use of standard MLOps tooling.

```python
import mlflow
from snowflake.ml.mlflow import MlflowClient

# Set MLflow tracking to Snowflake backend
mlflow.set_tracking_uri("snowflake://mortgage_db.ml.mlflow_experiments")

with mlflow.start_run(run_name="prepayment_gbm_v3"):
    mlflow.log_param("n_estimators", 300)
    mlflow.log_param("max_depth", 5)
    mlflow.log_param("learning_rate", 0.05)
    mlflow.log_param("training_data_vintage", "2019-2024")

    # Train model
    pipeline.fit(df)

    # Log metrics
    mlflow.log_metric("train_rmse", train_rmse)
    mlflow.log_metric("holdout_rmse", holdout_rmse)
    mlflow.log_metric("holdout_r2", r2_score)

    # Log model to MLflow (backed by Snowflake Model Registry)
    mlflow.sklearn.log_model(
        pipeline,
        artifact_path="prepayment_model",
        registered_model_name="prepayment_speed_model"
    )
```

---

## Feature Store in Snowflake

The Snowflake Feature Store manages feature pipelines with point-in-time correctness — critical for preventing data leakage in mortgage default models.

```python
from snowflake.ml.feature_store import FeatureStore, FeatureView, Entity
import snowflake.snowpark.functions as F

# Initialize Feature Store
fs = FeatureStore(
    session=session,
    database="mortgage_db",
    name="mortgage_feature_store",
    default_warehouse="FEATURE_WH"
)

# Define entity: a loan
loan_entity = Entity(name="LOAN", join_keys=["LOAN_ID"])
fs.register_entity(loan_entity)

# Define a feature view from a Snowpark DataFrame
loan_performance_df = session.table("mortgage_db.analytics.loan_performance_monthly")

loan_features = FeatureView(
    name        = "loan_performance_features",
    entities    = [loan_entity],
    feature_df  = loan_performance_df.select(
        "LOAN_ID",
        "REPORT_DATE",
        "DAYS_PAST_DUE",
        "CURRENT_LTV",
        "CURRENT_COUPON_RATE",
        "PAYMENT_SHORTFALL_3M_AVG",
        "MONTHS_IN_FORBEARANCE",
        "BORROWER_CALL_COUNT_90D"
    ),
    timestamp_col = "REPORT_DATE",
    refresh_freq  = "1 day",
    desc          = "Loan-level performance features for default/prepayment models"
)

registered_fv = fs.register_feature_view(
    feature_view  = loan_features,
    version       = "V1",
    block         = True  # wait for initial materialization
)

# Retrieve training dataset with point-in-time correctness
# This prevents leakage: only features known BEFORE the label event are used
spine_df = session.table("mortgage_db.ml.default_label_spine")
# spine has: LOAN_ID, EVENT_DATE (label observation date), DEFAULTED (label)

training_dataset = fs.retrieve_feature_values(
    spine_df      = spine_df,
    features      = [registered_fv],
    spine_timestamp_col = "EVENT_DATE"
)

training_dataset.to_snowpark_dataframe().write.save_as_table(
    "mortgage_db.ml.default_model_training_features_v1",
    mode="overwrite"
)
```

---

## Complete End-to-End Pipeline: Pool Balance Forecasting

```sql
-- Orchestration via Snowflake Tasks

-- Task 1: Refresh training data monthly
CREATE OR REPLACE TASK mortgage_db.ml.refresh_forecast_training_data
    WAREHOUSE = ML_WH
    SCHEDULE  = 'USING CRON 0 2 1 * * America/New_York'  -- 2am on 1st of month
AS
CREATE OR REPLACE VIEW mortgage_db.analytics.pool_upb_training AS
SELECT
    DATE_TRUNC('month', report_date) AS report_month,
    pool_id,
    SUM(current_unpaid_principal_balance) AS total_upb
FROM mortgage_db.analytics.loan_performance_monthly
WHERE report_date >= '2019-01-01'
GROUP BY 1, 2;

-- Task 2: Retrain forecast model (depends on Task 1)
CREATE OR REPLACE TASK mortgage_db.ml.retrain_upb_forecast_model
    WAREHOUSE     = ML_WH
    AFTER         = mortgage_db.ml.refresh_forecast_training_data
AS
CREATE OR REPLACE SNOWFLAKE.ML.FORECAST mortgage_db.ml.pool_upb_forecast_model (
    INPUT_DATA        => SYSTEM$REFERENCE('VIEW',
        'mortgage_db.analytics.pool_upb_training'),
    SERIES_COLNAME    => 'pool_id',
    TIMESTAMP_COLNAME => 'report_month',
    TARGET_COLNAME    => 'total_upb',
    CONFIG_OBJECT     => {'ON_ERROR': 'SKIP', 'EVALUATE': TRUE}
);

-- Task 3: Generate forecasts and store results (depends on Task 2)
CREATE OR REPLACE TASK mortgage_db.ml.generate_pool_forecasts
    WAREHOUSE = ML_WH
    AFTER     = mortgage_db.ml.retrain_upb_forecast_model
AS
BEGIN
    -- Generate 12-month forecast
    CALL mortgage_db.ml.pool_upb_forecast_model!FORECAST(
        FORECASTING_PERIODS => 12,
        CONFIG_OBJECT => {'PREDICTION_INTERVAL': 0.90}
    );

    -- Persist results with version tracking
    INSERT INTO mortgage_db.analytics.pool_upb_forecast_history
    SELECT
        series                                        AS pool_id,
        ts                                            AS forecast_month,
        forecast                                      AS predicted_upb,
        lower_bound,
        upper_bound,
        CURRENT_TIMESTAMP()                           AS model_run_at,
        CURRENT_DATE()                                AS forecast_vintage
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
END;

-- Activate task graph
ALTER TASK mortgage_db.ml.generate_pool_forecasts RESUME;
ALTER TASK mortgage_db.ml.retrain_upb_forecast_model RESUME;
ALTER TASK mortgage_db.ml.refresh_forecast_training_data RESUME;
```

---

## Interview Q&A

**Q1: How does SNOWFLAKE.ML.FORECAST handle seasonality and trend automatically, and when would you need to override it?**

A: Snowflake's `FORECAST` function uses an automated model selection process that fits multiple candidate models (including trend-adjusted exponential smoothing and gradient-boosted tree models that encode time features) and selects the best-performing one via internal cross-validation. Seasonality is detected automatically through Fourier decomposition of the training series — the model identifies weekly, monthly, and annual cycles without configuration. You would override defaults when: (1) your series has domain-specific seasonality the model can't detect from limited history (e.g., MBS pool runoff accelerates in spring/summer due to home sale seasonality — if your training history spans fewer than 2 years, the model may underfit this cycle; provide exogenous variables encoding month-of-year as a fix); (2) you have known structural breaks in the series (COVID-era forbearance created a non-natural break in 2020 that degrades forecast accuracy — consider training on post-2022 data only or using the `EXOGENOUS_COLNAMES` to include a forbearance indicator); (3) you need a specific confidence interval width not supported by the default `PREDICTION_INTERVAL` of 0.95.

**Q2: What is the difference between supervised and unsupervised mode in SNOWFLAKE.ML.ANOMALY_DETECTION?**

A: In unsupervised mode (the default, `LABEL_COLNAME = NULL`), the model trains on all provided data and identifies points that deviate significantly from the learned distribution — it assumes the training data is mostly "normal." In supervised mode, you provide a label column where `TRUE` marks known anomalies in the training set. Supervised mode is superior when you have historical examples of confirmed anomalies, because the model learns the specific characteristics of your anomaly type rather than just statistical rarity. For mortgage data, unsupervised mode works well for detecting unusual payment patterns in a new servicer portfolio where you have no labeled history. Supervised mode is preferred when you have loan-level performance history with confirmed labels from a credit team (e.g., loans that were flagged as fraud during underwriting review). The tradeoff is that supervised mode requires careful label quality — mislabeled "normal" loans as anomalies (or vice versa) degrades the model more than in unsupervised mode.

**Q3: Walk through how you would use SNOWFLAKE.ML.CLASSIFICATION to predict 90-day delinquency on an MBS pool, including handling class imbalance.**

A: Class imbalance is the first challenge: in a performing pool, only 1-3% of loans may become seriously delinquent in any given quarter, meaning a naive classifier that predicts "not delinquent" for every loan achieves 97%+ accuracy while being useless. Snowflake's `CLASSIFICATION` function handles class imbalance internally via sample weighting during training — you do not need to manually oversample or undersample. The workflow: (1) Build training data with a clear label definition — I use "ever 90+ DPD within the next 6 monthly reporting periods" as the label, joining origination features to future performance data. (2) Include time-aware features: current DPD, payment shortfall trend over 3 and 6 months, months in forbearance, number of missed payments, and macro context (HPI change, unemployment rate for the property MSA). (3) Create the model with `EVALUATE: TRUE` and review `SHOW_EVALUATION_METRICS()` — focus on AUC-ROC and PR-AUC (precision-recall AUC), not overall accuracy. (4) Score monthly using the PREDICT method. (5) For fair lending compliance, run `SHOW_FEATURE_IMPORTANCE()` to confirm the model is not relying on protected class proxies. Monitor model performance monthly — Snowflake does not automatically detect model drift, so schedule a monthly AUC calculation on scored loans whose 6-month outcomes are now observable.

**Q4: How does the Snowflake Model Registry support model governance in a regulated financial environment?**

A: The Model Registry provides: (1) Immutable versioning — each model version is a distinct object with a unique version name, creation timestamp, and training metadata. You cannot overwrite a version, only deprecate it, which satisfies audit requirements. (2) Tagging — attach key-value tags like `{"business_owner": "risk_mgmt", "regulatory_review": "ECOA_2025Q1", "approved_by": "model_risk"}` to each version, enabling filtered queries. (3) Metrics logging — store evaluation metrics (AUC, RMSE, MAPE) alongside the model so validation reports are self-contained. (4) Comment/lineage — the `comment` field stores free-text lineage notes (training data source, feature version, any data exclusions). (5) RBAC — the registry schema is governed by Snowflake role privileges; only the `MODEL_RISK` role can promote a model from STAGING to PRODUCTION status (implemented via tag). For SR 11-7 compliance (Fed guidance on model risk management), the Registry enables full documentation of model development, validation, and production deployment — each step as a queryable artifact rather than a document in a SharePoint folder.

**Q5: What is point-in-time correctness in the Snowflake Feature Store and why is it critical for mortgage default models?**

A: Point-in-time correctness means that when you retrieve features for a training example, you only use feature values that were known at or before the label's observation timestamp — not values that became available later. In mortgage modeling, this is critical because loan performance features are reported monthly and there is often a 30-60 day lag between events (a payment being missed) and that data appearing in your analytical tables. Without point-in-time correctness, your training dataset for a default label observed on 2023-06-30 might include features computed from data reported on 2023-09-30 — features that include information about the default itself, causing severe target leakage. The Feature Store's `retrieve_feature_values()` function with a `spine_timestamp_col` parameter handles this automatically: it performs an as-of join between the label spine (loan + event date) and the feature history table, using the most recent feature snapshot for each loan that is strictly before the event date. Without a Feature Store, you would implement this manually using a `MAX(report_date) WHERE report_date <= event_date` type join — correct but error-prone and not reusable across models.

**Q6: How would you use TOP_INSIGHTS to explain a sudden increase in 60-day delinquency rates to a portfolio manager?**

A: In a monthly portfolio review scenario where the 60-day DPD rate jumped from 2.1% to 3.4% month-over-month, `TOP_INSIGHTS` would decompose that 1.3 percentage point increase into contributions from specific dimension combinations. The setup: create a view with delinquency counts and totals by dimensions (servicer, state, origination year, loan purpose, property type) for both the control and test periods, then call `TOP_INSIGHTS` with those dimensions. The output ranks segments by their contribution to the aggregate change. For example, you might find: "Investor loans originated in 2022 via the broker channel in FL, TX, and GA account for 0.6pp of the 1.3pp increase — primarily driven by a higher delinquency rate in that segment (7.2% vs 4.1% prior month), not by mix shift." This is far more actionable than a pivot table. The function uses Bayesian surprise scoring, so it surfaces segments that are genuinely anomalous relative to the broader portfolio composition, filtering out segments that increased simply because they grew in volume.

**Q7: What are the limitations of Snowflake ML Functions compared to custom Snowpark ML models, and when do you choose each?**

A: Snowflake ML Functions (FORECAST, ANOMALY_DETECTION, CLASSIFICATION) are black-box models with fixed algorithms — you cannot specify the model type, tune hyperparameters beyond basic configuration, or access model internals beyond feature importance and evaluation metrics. They are best for: rapid prototyping, use cases where the default algorithm is well-matched (FORECAST for univariate time series, CLASSIFICATION for tabular gradient boosting), and teams without dedicated data scientists who need ML in SQL. Snowpark ML custom models are appropriate when: (1) You need algorithm flexibility — XGBoost with custom objective functions, neural networks for sequence data (LSTM for loan payment sequences), or survival models for time-to-default. (2) You need hyperparameter optimization — Optuna or Hyperopt integration via Snowpark Python. (3) You need custom feature engineering logic that cannot be expressed in SQL alone. (4) You require interpretability tools beyond feature importance — SHAP values for ECOA/Reg B compliance documentation. (5) Your model update frequency requires a full MLOps pipeline with MLflow experiment tracking and staged promotion. In a mature secondary mortgage analytics team, the pattern is: start with ML Functions for quick wins and baseline models, graduate to Snowpark ML when accuracy requirements or regulatory explainability demands exceed what ML Functions can provide.

**Q8: How do you detect model drift for a Snowflake ML CLASSIFICATION model in production?**

A: Snowflake does not automatically monitor deployed ML Function models for drift. Implement a scheduled monitoring pipeline: (1) Monthly, compute the AUC-ROC on the cohort of loans scored 6 months ago whose labels are now observable (6-month default window has closed). Store AUC in a monitoring table with `model_version`, `monitoring_date`, `cohort_period`, and `auc_value`. (2) Compare feature distributions between the current scoring population and the training population using Population Stability Index (PSI) — compute PSI in SQL for each continuous feature using decile-based bucketing. Flag features with PSI > 0.2 (significant drift). (3) Set up a Snowflake Alert on the monitoring table: if AUC drops more than 5 percentage points from the baseline validation AUC, trigger a notification to the model risk team. (4) Maintain a `model_performance_sla` table with thresholds per model, enabling rule-driven retraining triggers. Automated retraining via a Task that re-runs `CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION` is straightforward — just ensure the new model version is logged in the Registry before the scoring task switches to using it.

**Q9: Describe how SNOWFLAKE.ML.CONTRIBUTION_EXPLORER differs from TOP_INSIGHTS and when you would use each.**

A: `TOP_INSIGHTS` answers a retrospective question: "Why did metric X change between period A and period B?" It computes the decomposition of a specific change event. `CONTRIBUTION_EXPLORER` answers a structural question: "Which dimension combinations explain the most variance in metric X over time?" It analyzes the ongoing contribution of dimensions to a metric without requiring a control/test period comparison. For mortgage analytics: use `TOP_INSIGHTS` for incident response — when the monthly delinquency report shows an unexpected spike, TOP_INSIGHTS identifies the responsible segments. Use `CONTRIBUTION_EXPLORER` for ongoing portfolio attribution — understanding which servicers, states, and origination vintages are the persistent drivers of CPR variance across the past 12 months. `CONTRIBUTION_EXPLORER` also outputs dimension interactions — it can reveal that the combination of "broker channel AND California AND 2022 vintage" drives 18% of total CPR variance, which no single-dimension analysis would surface. Both functions require the data to be pre-aggregated by the relevant dimensions in the input view.

**Q10: How would you architect a full ML pipeline for MBS prepayment forecasting using Snowflake ML capabilities end-to-end?**

A: The architecture has five layers. (1) Feature engineering: a set of Snowflake Feature Store feature views computing loan-level and pool-level features: loan age, incentive (current coupon vs. market rate), burnout indicator (how many prior refinance opportunities the borrower did not take), LTV change (estimated from HPI indices), and seasonal adjusters. The Feature Store provides point-in-time correct snapshots for training and real-time feature serving for inference. (2) Training: a Snowpark ML pipeline running monthly using a `GradientBoostingRegressor` targeting 3-month CPR (conditional prepayment rate). The pipeline reads from the Feature Store, trains on a rolling 5-year window, and logs to the Model Registry with full metrics and a tag marking the model as "VALIDATED" only after automated backtesting on the hold-out pool passes MAPE < 15% per pool. (3) Scoring: a Snowflake Task runs on the 5th business day of each month (after GSE pool factor data is available), loads the PRODUCTION-tagged model from the Registry, scores all active pools, and writes to `analytics.pool_cpr_predictions`. (4) Monitoring: a monthly monitoring Task computes realized vs. predicted CPR for the prior 3-month forecast and stores in the drift monitoring table; alerts fire when pool-level MAPE exceeds the SLA threshold. (5) Downstream consumption: forecast results feed into a Snowflake dynamic table used by the duration and convexity calculation model, closing the loop between ML predictions and portfolio risk analytics.

---

## Pro Tips

- **Always check SHOW_EVALUATION_METRICS() before using a model in production.** ML Functions train without error even on low-quality data; the evaluation metrics are the only gate between a working model and a useless one. For CLASSIFICATION, AUC-ROC below 0.65 indicates the model has little predictive power.
- **Use SYSTEM$REFERENCE() correctly.** ML Functions require `SYSTEM$REFERENCE('VIEW', 'db.schema.view_name')` or `SYSTEM$REFERENCE('TABLE', ...)`. Passing a subquery directly is not supported — always materialize training data as a view or table.
- **The FORECAST model must have at least 12 data points per series.** For monthly pool data, this means 12 months of history minimum. Pools with fewer observations are silently skipped when `ON_ERROR = 'SKIP'`. Always check the count of series in your forecast results against the expected pool count.
- **Feature Store retrieve_feature_values() can be slow at large scale.** The as-of join is expensive; for training datasets exceeding 10M rows, pre-materialize the point-in-time features into a training table using a manual as-of join pattern and document it. Use the Feature Store for serving and for smaller training runs.
- **Model Registry tags are queryable.** Use `reg.show_models()` filtered by tag in Snowpark Python, or query `INFORMATION_SCHEMA.MODEL_VERSIONS` directly in SQL to build automated model promotion workflows.
- **Task-based ML pipelines need error handling.** Wrap ML Function `CREATE OR REPLACE` calls in `BEGIN ... EXCEPTION WHEN ... END` blocks inside Snowflake Scripting tasks so that a failed model retrain does not silently leave the scoring task pointing at a stale model. Always write to a staging table first, validate row counts and metric thresholds, then swap the production table using `ALTER TABLE SWAP WITH`.
