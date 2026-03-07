# Snowflake Cortex & AI/ML Features

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Snowflake Cortex Overview](#snowflake-cortex-overview)
2. [Cortex LLM Functions](#cortex-llm-functions)
3. [Cortex ML Functions](#cortex-ml-functions)
4. [Cortex Search](#cortex-search)
5. [Cortex Fine-Tuning](#cortex-fine-tuning)
6. [ML Model Deployment in Snowflake](#ml-model-deployment-in-snowflake)
7. [Snowpark ML](#snowpark-ml)
8. [Model Registry](#model-registry)
9. [Integration with External ML Tools](#integration-with-external-ml-tools)
10. [Use Cases for AI/ML in Data Engineering](#use-cases-for-aiml-in-data-engineering)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips](#tips)

---

## Snowflake Cortex Overview

Snowflake Cortex is a suite of AI and ML capabilities built directly into the Snowflake platform. It allows users to leverage large language models (LLMs), machine learning functions, and advanced search capabilities without moving data outside of Snowflake or managing infrastructure.

### Key Principles

- **No data movement**: AI/ML runs where the data lives, inside Snowflake's secure perimeter.
- **SQL-first interface**: Most Cortex features are invoked via SQL functions, making them accessible to data engineers and analysts without deep ML expertise.
- **Serverless execution**: Snowflake manages the compute for Cortex functions; no warehouse sizing or GPU provisioning is required for most features.
- **Governance built-in**: All Cortex operations respect Snowflake's RBAC, data masking, and governance policies.

### Architecture

```
+--------------------------------------------------+
|              Snowflake Data Cloud                 |
|                                                   |
|  +---------------------------------------------+ |
|  |            Snowflake Cortex                  | |
|  |                                              | |
|  |  +----------+  +-----------+  +----------+  | |
|  |  | LLM      |  | ML        |  | Cortex   |  | |
|  |  | Functions |  | Functions |  | Search   |  | |
|  |  +----------+  +-----------+  +----------+  | |
|  |                                              | |
|  |  +----------+  +-----------+                 | |
|  |  | Fine-    |  | Snowpark  |                 | |
|  |  | Tuning   |  | ML        |                 | |
|  |  +----------+  +-----------+                 | |
|  +---------------------------------------------+ |
|                                                   |
|  +---------------------------------------------+ |
|  |  Data Layer (Tables, Stages, Streams)        | |
|  +---------------------------------------------+ |
+--------------------------------------------------+
```

---

## Cortex LLM Functions

Cortex LLM functions provide access to large language models directly through SQL. These are serverless functions that process text data stored in Snowflake.

### COMPLETE

The `SNOWFLAKE.CORTEX.COMPLETE` function sends a prompt to an LLM and returns the generated response. It is the most flexible LLM function, supporting arbitrary prompts.

```sql
-- Basic usage with a string prompt
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'snowflake-arctic',          -- model name
    'Explain what a surrogate key is in data warehousing.'
) AS response;

-- Using column data as context
SELECT
    ticket_id,
    SNOWFLAKE.CORTEX.COMPLETE(
        'mistral-large2',
        CONCAT(
            'Classify the following support ticket into one of these categories: ',
            'billing, technical, account, general. Ticket text: ',
            ticket_text
        )
    ) AS category
FROM support_tickets
WHERE created_date = CURRENT_DATE();

-- Using structured prompt with system and user messages
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'llama3.1-70b',
    [
        {'role': 'system', 'content': 'You are a data quality analyst. Respond with JSON only.'},
        {'role': 'user', 'content': 'Analyze this error message and return root cause: ' || error_msg}
    ]::ARRAY(OBJECT(role STRING, content STRING)),
    {
        'temperature': 0.1,
        'max_tokens': 500
    }
) AS analysis
FROM pipeline_errors;
```

**Supported Models** (availability varies by region):
- `snowflake-arctic` -- Snowflake's own model
- `mistral-large2`
- `llama3.1-8b`, `llama3.1-70b`, `llama3.1-405b`
- `mixtral-8x7b`
- `gemma-7b`

### SUMMARIZE

The `SNOWFLAKE.CORTEX.SUMMARIZE` function condenses long text into a shorter summary.

```sql
-- Summarize customer feedback
SELECT
    feedback_id,
    SNOWFLAKE.CORTEX.SUMMARIZE(feedback_text) AS summary
FROM customer_feedback
WHERE LENGTH(feedback_text) > 500;

-- Summarize pipeline run logs
SELECT
    run_id,
    run_date,
    SNOWFLAKE.CORTEX.SUMMARIZE(log_output) AS log_summary
FROM etl_run_logs
WHERE status = 'FAILED';
```

### TRANSLATE

The `SNOWFLAKE.CORTEX.TRANSLATE` function translates text between languages.

```sql
-- Translate product descriptions from French to English
SELECT
    product_id,
    description_fr,
    SNOWFLAKE.CORTEX.TRANSLATE(
        description_fr,
        'fr',    -- source language
        'en'     -- target language
    ) AS description_en
FROM international_products
WHERE region = 'EMEA';
```

**Supported language codes**: `en`, `fr`, `de`, `es`, `it`, `pt`, `ja`, `ko`, `pl`, `ru`, `sv`, and more.

### SENTIMENT

The `SNOWFLAKE.CORTEX.SENTIMENT` function returns a sentiment score between -1 (negative) and 1 (positive).

```sql
-- Analyze sentiment of customer reviews
SELECT
    review_id,
    review_text,
    SNOWFLAKE.CORTEX.SENTIMENT(review_text) AS sentiment_score,
    CASE
        WHEN SNOWFLAKE.CORTEX.SENTIMENT(review_text) > 0.3 THEN 'Positive'
        WHEN SNOWFLAKE.CORTEX.SENTIMENT(review_text) < -0.3 THEN 'Negative'
        ELSE 'Neutral'
    END AS sentiment_label
FROM product_reviews;

-- Track sentiment trends over time
SELECT
    DATE_TRUNC('week', review_date) AS week,
    AVG(SNOWFLAKE.CORTEX.SENTIMENT(review_text)) AS avg_sentiment,
    COUNT(*) AS review_count
FROM product_reviews
GROUP BY 1
ORDER BY 1;
```

### EXTRACT_ANSWER

The `SNOWFLAKE.CORTEX.EXTRACT_ANSWER` function extracts an answer to a specific question from a given text passage.

```sql
-- Extract specific information from contract documents
SELECT
    contract_id,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        contract_text,
        'What is the contract termination date?'
    ) AS termination_date_info
FROM contracts;

-- Extract data points from unstructured incident reports
SELECT
    incident_id,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        report_text,
        'What was the root cause of the outage?'
    )[0]['answer']::STRING AS root_cause
FROM incident_reports;
```

The function returns a JSON array of answer objects, each containing an `answer` string and a `score` confidence value.

### Cost Considerations for LLM Functions

- LLM functions consume **Cortex AI credits**, billed per token processed.
- Larger models (e.g., `llama3.1-405b`) cost more per token than smaller models.
- Use smaller models for simple tasks (classification, sentiment) and larger models for complex reasoning.
- Batch processing via table scans is more cost-efficient than row-by-row calls.

---

## Cortex ML Functions

Cortex ML functions provide built-in machine learning models that can be trained and used entirely through SQL, requiring no Python or external tools.

### Forecasting

Time-series forecasting predicts future values based on historical data.

```sql
-- Step 1: Create a forecasting model
CREATE OR REPLACE SNOWFLAKE.ML.FORECAST sales_forecast_model(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'daily_sales'),
    TIMESTAMP_COLNAME => 'sale_date',
    TARGET_COLNAME => 'revenue'
);

-- Step 2: Generate forecasts
CALL sales_forecast_model!FORECAST(
    FORECASTING_PERIODS => 30,       -- predict 30 days ahead
    CONFIG_OBJECT => {'prediction_interval': 0.95}
);

-- Multi-series forecasting (e.g., forecast per product)
CREATE OR REPLACE SNOWFLAKE.ML.FORECAST product_forecast(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'daily_product_sales'),
    SERIES_COLNAME => 'product_id',
    TIMESTAMP_COLNAME => 'sale_date',
    TARGET_COLNAME => 'units_sold'
);

CALL product_forecast!FORECAST(FORECASTING_PERIODS => 14);

-- Inspect model evaluation metrics
CALL sales_forecast_model!SHOW_EVALUATION_METRICS();
```

### Anomaly Detection

Identifies unusual patterns or outliers in time-series data.

```sql
-- Create an anomaly detection model
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION pipeline_anomaly_model(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'pipeline_metrics_history'),
    TIMESTAMP_COLNAME => 'metric_timestamp',
    TARGET_COLNAME => 'row_count',
    LABEL_COLNAME => ''  -- unsupervised; leave empty
);

-- Detect anomalies in new data
CALL pipeline_anomaly_model!DETECT_ANOMALIES(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'pipeline_metrics_today'),
    TIMESTAMP_COLNAME => 'metric_timestamp',
    TARGET_COLNAME => 'row_count',
    CONFIG_OBJECT => {'prediction_interval': 0.99}
);

-- Result columns include:
--   IS_ANOMALY (BOOLEAN), PERCENTILE, DISTANCE, FORECAST, LOWER_BOUND, UPPER_BOUND

-- Multi-series anomaly detection (e.g., per pipeline)
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION multi_pipeline_anomaly(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'all_pipeline_metrics'),
    SERIES_COLNAME => 'pipeline_name',
    TIMESTAMP_COLNAME => 'metric_timestamp',
    TARGET_COLNAME => 'row_count',
    LABEL_COLNAME => ''
);
```

### Classification

Automatically classifies data into categories based on labeled training data.

```sql
-- Create a classification model
CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION ticket_classifier(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'labeled_tickets'),
    TARGET_COLNAME => 'category'
);

-- Predict categories for new tickets
SELECT
    ticket_id,
    ticket_text,
    ticket_classifier!PREDICT(
        INPUT_DATA => OBJECT_CONSTRUCT(*)
    ) AS prediction
FROM new_tickets;

-- Access prediction details
SELECT
    ticket_id,
    prediction['class']::STRING AS predicted_category,
    prediction['probability'][prediction['class']]::FLOAT AS confidence
FROM (
    SELECT
        ticket_id,
        ticket_classifier!PREDICT(
            INPUT_DATA => OBJECT_CONSTRUCT(*)
        ) AS prediction
    FROM new_tickets
);

-- View feature importance
CALL ticket_classifier!SHOW_FEATURE_IMPORTANCE();
```

### Top Insights

Automatically identifies the most significant contributors to changes in a metric.

```sql
-- Find top drivers of revenue change between two periods
CALL SNOWFLAKE.ML.TOP_INSIGHTS(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'sales_data'),
    METRIC_COLNAME => 'revenue',
    TIMESTAMP_COLNAME => 'order_date',
    LABEL_COLNAME => 'period_label',  -- column with 'baseline' or 'comparison'
    CONFIG_OBJECT => {'max_results': 10}
);

-- Example: Why did pipeline failure rate increase?
-- Prepare a view with labeled periods
CREATE OR REPLACE VIEW pipeline_comparison AS
SELECT
    *,
    CASE
        WHEN run_date BETWEEN '2026-01-01' AND '2026-01-31' THEN 'baseline'
        WHEN run_date BETWEEN '2026-02-01' AND '2026-02-28' THEN 'comparison'
    END AS period_label
FROM pipeline_runs
WHERE period_label IS NOT NULL;

CALL SNOWFLAKE.ML.TOP_INSIGHTS(
    INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'pipeline_comparison'),
    METRIC_COLNAME => 'failure_flag',
    LABEL_COLNAME => 'period_label',
    CONFIG_OBJECT => {'max_results': 5}
);
```

---

## Cortex Search

Cortex Search enables hybrid search (semantic + keyword) over text data stored in Snowflake. It creates and maintains a search index that updates automatically as the underlying data changes.

### Creating a Search Service

```sql
-- Create a Cortex Search service on product documentation
CREATE OR REPLACE CORTEX SEARCH SERVICE product_docs_search
  ON product_documentation
  WAREHOUSE = my_warehouse
  TARGET_LAG = '1 hour'           -- how fresh the index should be
  ATTRIBUTES product_category, doc_type  -- filterable attributes
  AS (
    SELECT
        doc_id,
        doc_title,
        doc_content,                -- text column to search
        product_category,
        doc_type,
        last_updated
    FROM product_documentation
  );
```

### Querying the Search Service

Cortex Search is typically consumed via the Python SDK or REST API:

```python
# Python SDK usage
from snowflake.core import Root

root = Root(session)

search_service = (
    root
    .databases["MY_DB"]
    .schemas["MY_SCHEMA"]
    .cortex_search_services["PRODUCT_DOCS_SEARCH"]
)

results = search_service.search(
    query="How to configure incremental refresh?",
    columns=["doc_id", "doc_title", "doc_content"],
    filter={
        "@and": [
            {"@eq": {"product_category": "dynamic_tables"}},
            {"@eq": {"doc_type": "how-to"}}
        ]
    },
    limit=5
)

for r in results.results:
    print(r["doc_title"], r["doc_content"][:200])
```

### Key Features

- **Hybrid search**: Combines semantic (vector) search with keyword (BM25) search for best results.
- **Automatic index refresh**: Index stays current based on the `TARGET_LAG` setting.
- **Attribute filtering**: Filter results by categorical attributes without affecting relevance scoring.
- **Built-in security**: Respects RBAC; users only see results they have access to.

---

## Cortex Fine-Tuning

Cortex Fine-Tuning allows you to customize LLM behavior by training on your own data, directly within Snowflake.

### When to Fine-Tune

- The base model does not follow your desired output format.
- Domain-specific terminology or reasoning is needed.
- You want consistent structured output for a specific task.
- Prompt engineering alone does not achieve the required quality.

### Fine-Tuning Workflow

```sql
-- Step 1: Prepare training data as a table with 'prompt' and 'completion' columns
CREATE OR REPLACE TABLE fine_tune_training AS
SELECT
    prompt,
    completion
FROM raw_training_data
WHERE quality_score >= 0.9;

-- Step 2: Launch a fine-tuning job
SELECT SNOWFLAKE.CORTEX.FINETUNE(
    'CREATE',
    'my_custom_model',              -- name for the fine-tuned model
    'mistral-7b',                   -- base model
    'SELECT prompt, completion FROM fine_tune_training',  -- training data query
    'SELECT prompt, completion FROM fine_tune_validation' -- optional validation data
);

-- Step 3: Check job status
SELECT SNOWFLAKE.CORTEX.FINETUNE('SHOW', 'my_custom_model');

-- Step 4: Use the fine-tuned model
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'my_custom_model',
    'Parse the following raw log entry into structured JSON: ' || log_text
) AS parsed_log
FROM raw_logs;
```

### Best Practices

- Provide at least a few hundred high-quality training examples.
- Include diverse examples that cover edge cases.
- Use a validation set to monitor for overfitting.
- Fine-tune the smallest model that meets your quality requirements to reduce cost.

---

## ML Model Deployment in Snowflake

Snowflake supports multiple paths for deploying ML models, depending on the framework and use case.

### User-Defined Functions (UDFs)

```sql
-- Deploy a Python ML model as a UDF
CREATE OR REPLACE FUNCTION predict_churn(
    tenure INT,
    monthly_charges FLOAT,
    total_charges FLOAT,
    contract_type STRING
)
RETURNS FLOAT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('scikit-learn==1.3.0', 'pandas', 'joblib')
IMPORTS = ('@ml_models_stage/churn_model.joblib')
HANDLER = 'predict'
AS
$$
import joblib
import pandas as pd
import sys
import os

model = None

def predict(tenure, monthly_charges, total_charges, contract_type):
    global model
    if model is None:
        model = joblib.load(
            os.path.join(sys._xoptions["snowflake_import_directory"], "churn_model.joblib")
        )
    input_df = pd.DataFrame([{
        'tenure': tenure,
        'monthly_charges': monthly_charges,
        'total_charges': total_charges,
        'contract_type': contract_type
    }])
    return float(model.predict_proba(input_df)[0][1])
$$;

-- Use the model in SQL
SELECT
    customer_id,
    predict_churn(tenure, monthly_charges, total_charges, contract_type) AS churn_probability
FROM customers
WHERE churn_probability > 0.7;
```

### Vectorized UDFs (for batch performance)

```sql
CREATE OR REPLACE FUNCTION predict_churn_batch(
    tenure INT,
    monthly_charges FLOAT,
    total_charges FLOAT,
    contract_type STRING
)
RETURNS FLOAT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('scikit-learn==1.3.0', 'pandas', 'joblib')
IMPORTS = ('@ml_models_stage/churn_model.joblib')
HANDLER = 'predict_batch'
AS
$$
import joblib
import pandas as pd
import sys, os

model = None

def predict_batch(tenure_series, monthly_series, total_series, contract_series):
    global model
    if model is None:
        model = joblib.load(
            os.path.join(sys._xoptions["snowflake_import_directory"], "churn_model.joblib")
        )
    df = pd.DataFrame({
        'tenure': tenure_series,
        'monthly_charges': monthly_series,
        'total_charges': total_series,
        'contract_type': contract_series
    })
    return pd.Series(model.predict_proba(df)[:, 1])
$$;
```

### Stored Procedures for Training

```sql
CREATE OR REPLACE PROCEDURE train_churn_model()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python', 'scikit-learn', 'joblib')
HANDLER = 'main'
AS
$$
def main(session):
    from sklearn.ensemble import GradientBoostingClassifier
    from sklearn.model_selection import train_test_split
    import joblib, os

    df = session.table("TRAINING_DATA").to_pandas()
    X = df[['tenure', 'monthly_charges', 'total_charges', 'contract_type_encoded']]
    y = df['churned']

    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)

    model = GradientBoostingClassifier(n_estimators=200, max_depth=5)
    model.fit(X_train, y_train)

    accuracy = model.score(X_test, y_test)

    model_path = '/tmp/churn_model.joblib'
    joblib.dump(model, model_path)
    session.file.put(model_path, '@ml_models_stage', auto_compress=False, overwrite=True)

    return f"Model trained. Test accuracy: {accuracy:.4f}"
$$;

CALL train_churn_model();
```

---

## Snowpark ML

Snowpark ML is Snowflake's Python library for end-to-end machine learning workflows. It includes modeling tools, a feature store, and a model registry.

### Snowpark ML Modeling

```python
from snowflake.ml.modeling.preprocessing import OneHotEncoder, StandardScaler
from snowflake.ml.modeling.pipeline import Pipeline
from snowflake.ml.modeling.ensemble import GradientBoostingClassifier
from snowflake.ml.modeling.metrics import accuracy_score

# Load data as a Snowpark DataFrame (computation stays in Snowflake)
train_df = session.table("TRAINING_DATA")
test_df = session.table("TEST_DATA")

# Define features and target
CATEGORICAL_COLS = ["contract_type", "payment_method"]
NUMERIC_COLS = ["tenure", "monthly_charges", "total_charges"]
TARGET_COL = "churned"

# Build a pipeline
pipeline = Pipeline(steps=[
    ("ohe", OneHotEncoder(input_cols=CATEGORICAL_COLS, output_cols=CATEGORICAL_COLS)),
    ("scaler", StandardScaler(input_cols=NUMERIC_COLS, output_cols=NUMERIC_COLS)),
    ("model", GradientBoostingClassifier(
        input_cols=CATEGORICAL_COLS + NUMERIC_COLS,
        label_cols=[TARGET_COL],
        output_cols=["PREDICTION"]
    ))
])

# Train -- this executes in Snowflake's compute
pipeline.fit(train_df)

# Predict
predictions = pipeline.predict(test_df)

# Evaluate
accuracy = accuracy_score(
    df=predictions,
    y_true_col_names=[TARGET_COL],
    y_pred_col_names=["PREDICTION"]
)
print(f"Accuracy: {accuracy:.4f}")
```

### Feature Store

The Snowpark Feature Store provides a centralized repository for feature definitions, enabling feature reuse and consistency across ML projects.

```python
from snowflake.ml.feature_store import FeatureStore, FeatureView, Entity

# Initialize Feature Store
fs = FeatureStore(session, database="ML_DB", name="FEATURE_STORE", default_warehouse="ML_WH")

# Define an entity (the primary key for features)
customer_entity = Entity(name="CUSTOMER", join_keys=["CUSTOMER_ID"])
fs.register_entity(customer_entity)

# Create a feature view from a SQL query
customer_features_df = session.sql("""
    SELECT
        customer_id,
        AVG(order_total) AS avg_order_value,
        COUNT(*) AS total_orders,
        DATEDIFF('day', MAX(order_date), CURRENT_DATE()) AS days_since_last_order,
        SUM(order_total) AS lifetime_value
    FROM orders
    GROUP BY customer_id
""")

customer_fv = FeatureView(
    name="CUSTOMER_ORDER_FEATURES",
    entities=[customer_entity],
    feature_df=customer_features_df,
    refresh_freq="1 day",           # auto-refresh daily
    description="Customer order aggregation features"
)

# Register the feature view
customer_fv = fs.register_feature_view(
    feature_view=customer_fv,
    version="v1"
)

# Retrieve features for training
spine_df = session.table("TRAINING_CUSTOMERS")  # just customer_id + label
training_df = fs.retrieve_feature_values(
    spine_df=spine_df,
    features=[customer_fv],
    spine_timestamp_col="AS_OF_DATE"  # point-in-time correct features
)
```

---

## Model Registry

The Snowflake Model Registry provides a centralized catalog for managing ML model versions, metadata, and deployment.

```python
from snowflake.ml.registry import Registry

# Initialize the registry
registry = Registry(session, database_name="ML_DB", schema_name="MODEL_REGISTRY")

# Log a model
model_version = registry.log_model(
    model_name="churn_predictor",
    version_name="v3",
    model=pipeline,                  # the trained Snowpark ML pipeline
    metrics={
        "accuracy": 0.92,
        "f1_score": 0.87,
        "auc_roc": 0.95
    },
    comment="GBM with new payment features, trained on 2025 data"
)

# List all models
registry.show_models()

# Get a specific model version
mv = registry.get_model("churn_predictor").version("v3")

# Run inference from the registry
predictions = mv.run(test_df, function_name="predict")

# Set the default version for production
model = registry.get_model("churn_predictor")
model.default = registry.get_model("churn_predictor").version("v3")

# Delete old versions
registry.get_model("churn_predictor").version("v1").delete()
```

### Model Registry Metadata

```python
# Add tags for governance
mv.set_tag("team", "data-science")
mv.set_tag("use_case", "customer_churn")
mv.set_tag("data_sensitivity", "internal")

# Retrieve metrics
print(mv.get_metrics())
# {'accuracy': 0.92, 'f1_score': 0.87, 'auc_roc': 0.95}
```

---

## Integration with External ML Tools

Snowflake integrates with a wide ecosystem of ML platforms and tools.

### External Functions (API Gateway)

```sql
-- Call an external ML API (e.g., a SageMaker endpoint) via API integration
CREATE OR REPLACE EXTERNAL FUNCTION score_with_sagemaker(input_json VARIANT)
RETURNS VARIANT
API_INTEGRATION = aws_api_integration
AS 'https://abc123.execute-api.us-east-1.amazonaws.com/prod/score';

SELECT
    customer_id,
    score_with_sagemaker(
        OBJECT_CONSTRUCT(
            'tenure', tenure,
            'charges', monthly_charges
        )
    ) AS sagemaker_prediction
FROM customers;
```

### Common Integration Patterns

| Tool / Platform   | Integration Method                            | Use Case                                |
|--------------------|-----------------------------------------------|-----------------------------------------|
| **Amazon SageMaker** | External functions, Snowpark                 | Training at scale, hosted endpoints     |
| **Azure ML**       | External functions, Snowpark                   | Enterprise ML workflows on Azure        |
| **Vertex AI**      | External functions                             | Google Cloud ML integration             |
| **MLflow**         | Snowpark ML model registry (MLflow-compatible) | Experiment tracking, model versioning   |
| **dbt**            | dbt + Snowpark Python models                   | ML in transformation pipelines          |
| **Airflow**        | Snowflake provider, Snowpark operator          | ML pipeline orchestration               |
| **Dataiku / DataRobot** | Native Snowflake connectors              | AutoML with Snowflake data              |
| **Hugging Face**   | Snowpark Container Services                    | Custom model hosting inside Snowflake   |

### Snowpark Container Services (for advanced models)

```sql
-- Run custom Docker containers inside Snowflake for GPU-accelerated inference
CREATE SERVICE my_llm_service
  IN COMPUTE POOL gpu_pool
  FROM SPECIFICATION $$
  spec:
    containers:
    - name: llm-inference
      image: /my_db/my_schema/my_repo/custom-llm:latest
      resources:
        requests:
          nvidia.com/gpu: 1
    endpoints:
    - name: predict
      port: 8080
      public: false
  $$;
```

---

## Use Cases for AI/ML in Data Engineering

### 1. Data Quality Monitoring

```sql
-- Use anomaly detection to monitor pipeline row counts
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION row_count_monitor(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'pipeline_row_counts_history'),
    TIMESTAMP_COLNAME => 'load_timestamp',
    TARGET_COLNAME => 'row_count',
    LABEL_COLNAME => ''
);

-- Run daily as part of your pipeline
CALL row_count_monitor!DETECT_ANOMALIES(
    INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'todays_row_counts'),
    TIMESTAMP_COLNAME => 'load_timestamp',
    TARGET_COLNAME => 'row_count'
);
```

### 2. Schema Change Detection with LLMs

```sql
-- Use COMPLETE to analyze schema drift impact
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'mistral-large2',
    CONCAT(
        'Given the following schema change in a source system, ',
        'describe the potential impact on downstream data pipelines and reports. ',
        'Schema change: ', change_description,
        ' Affected table: ', table_name
    )
) AS impact_analysis
FROM schema_change_log
WHERE change_date = CURRENT_DATE();
```

### 3. Demand Forecasting for Resource Planning

```sql
-- Forecast warehouse credit consumption
CREATE OR REPLACE SNOWFLAKE.ML.FORECAST credit_forecast(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'daily_credit_usage'),
    TIMESTAMP_COLNAME => 'usage_date',
    TARGET_COLNAME => 'credits_used'
);

CALL credit_forecast!FORECAST(FORECASTING_PERIODS => 30);
```

### 4. Automated Data Enrichment

```sql
-- Enrich customer records with sentiment and translations
CREATE OR REPLACE TABLE enriched_feedback AS
SELECT
    *,
    SNOWFLAKE.CORTEX.SENTIMENT(feedback_text) AS sentiment_score,
    SNOWFLAKE.CORTEX.SUMMARIZE(feedback_text) AS summary,
    SNOWFLAKE.CORTEX.TRANSLATE(feedback_text, 'auto', 'en') AS english_text
FROM raw_feedback;
```

### 5. Intelligent Log Parsing

```sql
-- Parse unstructured logs into structured data
SELECT
    log_id,
    SNOWFLAKE.CORTEX.COMPLETE(
        'mistral-large2',
        'Parse this log entry into JSON with keys: timestamp, severity, component, message, error_code. Log: ' || raw_log
    )::VARIANT AS parsed_log
FROM raw_application_logs;
```

---

## Common Interview Questions

### Q1: What is Snowflake Cortex and how does it differ from running ML externally?

**A:** Snowflake Cortex is a suite of AI/ML services built into the Snowflake platform. Unlike external ML tools (SageMaker, Vertex AI, etc.), Cortex runs within Snowflake's secure perimeter, so data never leaves the platform. Key differences:

- **No data movement**: Models operate on data in-place, eliminating ETL to external ML platforms.
- **SQL interface**: Most Cortex functions are callable from SQL, lowering the barrier for data engineers.
- **Serverless**: No infrastructure to manage; Snowflake handles compute scaling.
- **Governance**: All operations inherit Snowflake's RBAC, masking policies, and audit trails.

The tradeoff is that Cortex offers less flexibility than a full ML platform -- you cannot bring arbitrary custom architectures or do deep hyperparameter tuning with Cortex ML functions. For those needs, Snowpark ML or Snowpark Container Services provide more control.

### Q2: When would you use Cortex ML functions vs. Snowpark ML?

**A:** Use **Cortex ML functions** when:
- The task is one of the supported types (forecasting, anomaly detection, classification, top insights).
- You want a SQL-only workflow with no Python required.
- Quick time-to-value is more important than model customization.

Use **Snowpark ML** when:
- You need custom feature engineering or preprocessing pipelines.
- You want to use specific algorithms or hyperparameter tuning.
- The project requires a feature store or model registry for governance.
- You need to integrate with existing ML libraries (scikit-learn, XGBoost, LightGBM) but want to keep compute in Snowflake.

### Q3: How would you build a data quality anomaly detection pipeline using Cortex?

**A:** The approach:
1. **Historical baseline**: Maintain a table of daily metrics (row counts, null rates, value distributions) for each pipeline.
2. **Train the model**: Create a `SNOWFLAKE.ML.ANOMALY_DETECTION` model on the historical metrics table.
3. **Schedule detection**: Use a Snowflake Task to run `DETECT_ANOMALIES` daily on the latest metrics.
4. **Alert on anomalies**: Write results to an anomalies table; use an alert or notification integration to send Slack/email notifications when `IS_ANOMALY = TRUE`.
5. **Retrain periodically**: Schedule model recreation (e.g., monthly) to adapt to seasonal changes.

### Q4: Explain how Cortex Search differs from traditional LIKE/CONTAINS queries.

**A:** Traditional `LIKE` or `CONTAINS` in SQL performs exact keyword matching -- it will miss synonyms, paraphrases, or conceptually related content. Cortex Search uses **hybrid search** that combines:
- **Semantic search**: Converts text into vector embeddings to find conceptually similar content even without exact keyword matches.
- **Keyword search (BM25)**: Traditional relevance-ranked keyword matching.
- **Automatic ranking**: Combines both signals to surface the most relevant results.

Additionally, Cortex Search maintains an auto-refreshing index, supports attribute-based filtering, and respects Snowflake's access controls -- none of which are possible with `LIKE` queries.

### Q5: What is the Snowflake Model Registry and why is it important?

**A:** The Model Registry is a centralized catalog within Snowflake for managing ML models. It stores:
- **Model artifacts**: The trained model object itself.
- **Versions**: Multiple versions of the same model with full history.
- **Metrics**: Performance metrics (accuracy, F1, AUC) attached to each version.
- **Metadata and tags**: Team ownership, use case, data sensitivity labels.
- **Default version**: Which version is "production-ready."

It is important because it solves the common MLOps challenges of model versioning, reproducibility, lineage tracking, and governance -- all within the same platform where the data and inference happen.

### Q6: How does Cortex Fine-Tuning work and when would you use it?

**A:** Cortex Fine-Tuning takes a base LLM (like Mistral-7B) and adapts it using your own prompt/completion pairs. The process:
1. Prepare training data as a table with `prompt` and `completion` columns.
2. Call `SNOWFLAKE.CORTEX.FINETUNE('CREATE', ...)` to start a fine-tuning job.
3. Once complete, use the custom model name in `SNOWFLAKE.CORTEX.COMPLETE()`.

You would use it when:
- Prompt engineering alone cannot produce the desired output quality or format.
- The task requires domain-specific terminology (medical, legal, financial).
- You need consistent structured output (e.g., always returning valid JSON with specific fields).
- Cost optimization: a smaller fine-tuned model can often outperform a larger general model on specific tasks.

---

## Tips

1. **Start with Cortex LLM functions for quick wins**: Sentiment analysis, summarization, and text classification can be added to existing pipelines with a single SQL function call.

2. **Use the smallest model that works**: For simple tasks like sentiment or classification, smaller models (`mistral-7b`, `llama3.1-8b`) are faster and cheaper than large models while often producing equivalent results.

3. **Cortex ML functions are SQL-native**: They are ideal for data engineers who need ML capabilities without adopting a Python workflow. Forecasting and anomaly detection are the most commonly used.

4. **Watch credit consumption**: LLM functions bill per token. When processing large tables, test on a sample first, estimate total token count, and calculate expected cost before running on the full dataset.

5. **Feature Store enables consistency**: If multiple models use the same features (e.g., customer lifetime value), define them once in the Feature Store rather than recalculating in each model's training pipeline.

6. **Model Registry is essential for production ML**: Always version your models, attach metrics, and use default versions to manage promotion from staging to production.

7. **Cortex Search replaces custom vector DB setups**: If you were considering an external vector database for RAG (Retrieval-Augmented Generation), Cortex Search can provide similar functionality without leaving Snowflake.

8. **Point-in-time correctness matters**: When using the Feature Store, always use `spine_timestamp_col` to ensure your training data uses features as they existed at the time of the label event, preventing data leakage.

9. **Combine Cortex with Tasks and Streams**: Build automated AI/ML pipelines by triggering Cortex functions via Snowflake Tasks on new data detected by Streams.

10. **Know the limitations**: Cortex ML functions support specific algorithms chosen by Snowflake -- you cannot swap in your own. If you need custom architectures, use Snowpark ML or Container Services instead.
