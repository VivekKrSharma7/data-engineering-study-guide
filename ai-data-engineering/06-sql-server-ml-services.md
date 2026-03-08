# SQL Server Machine Learning Services (R/Python in SQL)

[Back to Index](../README.md)

---

## Overview

SQL Server Machine Learning Services (formerly SQL Server R Services, renamed in SQL Server 2017) is Microsoft's in-database extensibility framework that allows Python and R code to execute directly inside the SQL Server process, with data passed bidirectionally between T-SQL and the external runtime. For a senior data engineer already deep in SQL Server, this is the lowest-friction path to adding machine learning to existing data pipelines: no new infrastructure, no data movement, governance stays inside SQL Server.

This module covers the architecture, configuration, practical code patterns, and production use cases — with a focus on the lending/finance domain you work in daily.

---

## Key Concepts

| Term | Definition |
|---|---|
| ML Services | SQL Server feature enabling Python/R execution inside the database engine |
| `sp_execute_external_script` | The system stored procedure that runs Python or R code |
| Extensibility framework | Satellite process architecture that isolates external runtimes from SQL Server |
| Launchpad service | Windows service that manages external runtime processes |
| `revoscalepy` | Microsoft's Python library with distributed ML algorithms for SQL Server |
| `RevoScaleR` | R equivalent of revoscalepy |
| `MicrosoftML` / `microsoftml` | Python/R libraries with fast ML algorithms (neural nets, GBM, logistic regression) |
| Native scoring | `PREDICT` T-SQL function that scores ONNX or RevoScale models without calling Python |
| `sp_rxPredict` | Real-time stored procedure scoring for RevoScale models, no Python overhead |

---

## Installation and Configuration

### Supported Versions

| SQL Server Version | Python Support | R Support | Notes |
|---|---|---|---|
| SQL Server 2016 | No | Yes | R Services (In-Database) |
| SQL Server 2017 | Yes (3.5) | Yes | ML Services introduced |
| SQL Server 2019 | Yes (3.7) | Yes | Java extensibility added; Extensibility SDK |
| SQL Server 2022 | Yes (3.10) | Yes | Extensibility improvements; ONNX PREDICT enhancements |

### Configuration Steps (SQL Server 2019/2022)

```sql
-- Step 1: Enable external scripts after installation
EXEC sp_configure 'external scripts enabled', 1;
RECONFIGURE WITH OVERRIDE;

-- Step 2: Restart SQL Server service (required)
-- net stop MSSQLSERVER && net start MSSQLSERVER

-- Step 3: Verify configuration
EXEC sp_configure 'external scripts enabled';
-- run_value should be 1

-- Step 4: Test with a minimal Python script
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'
import sys
print(sys.version)
OutputDataSet = InputDataSet
',
    @input_data_1 = N'SELECT 1 AS test_col';
-- Should return a result set with test_col = 1 and print Python version to messages
```

### SQL Server Agent and Launchpad

The **Launchpad** Windows service (`MSSQLLaunchpad$INSTANCENAME`) manages external runtime satellite processes. Each `sp_execute_external_script` call launches a satellite process in an isolated AppContainer (SQL Server 2019+). Ensure the Launchpad service account has:
- Read access to the SQL Server data directory
- Write access to the working directory (`MSSQLSERVER\ExtensibilityData`)
- `SQLRUserGroup` membership for older configurations

---

## Extensibility Framework Architecture

```
Client Application
      |
      | T-SQL call
      v
SQL Server Engine (sqlservr.exe)
      |
      | via named pipe / satellite channel
      v
Launchpad Service (MSSQLLaunchpad)
      |
      | spawns
      v
Satellite Process (python.exe / R.exe)
      |
      | runs script, returns results
      v
SQL Server Engine  -->  Result set to client
```

Key properties:
- **Resource governance:** External resource pools (Resource Governor) cap CPU and memory available to ML scripts.
- **Isolation:** The satellite process runs under a separate user account. Malicious Python code cannot access SQL Server memory directly.
- **Data transfer:** Data moves between SQL Server and the satellite via shared memory (same machine). This is much faster than a network-based API call.

---

## sp_execute_external_script — Full Syntax

```sql
EXEC sp_execute_external_script
    @language      = N'Python'              -- or N'R'
    ,@script        = N'<python code>'
    ,@input_data_1  = N'<T-SQL SELECT>'     -- feeds InputDataSet in Python
    ,@input_data_1_name  = N'InputDataSet'  -- rename if desired
    ,@output_data_1_name = N'OutputDataSet' -- the DataFrame to return
    ,@params        = N'@param1 INT, @param2 NVARCHAR(100)'
    ,@param1        = 42
    ,@param2        = N'value'
WITH RESULT SETS (
    (col1 INT, col2 FLOAT, col3 NVARCHAR(255))  -- explicit schema optional
);
```

---

## Running Python in SQL Server — Practical Examples

### Example 1: Basic Data Transformation

```sql
-- Pass loan data into Python, compute a derived feature, return result
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'
import pandas as pd
import numpy as np

# InputDataSet is automatically available as a pandas DataFrame
df = InputDataSet.copy()

# Derived feature: rate spread above current market rate
df["rate_spread_flag"]  = (df["loan_rate"] - df["market_rate"]) > 0.02
df["log_balance"]       = np.log1p(df["current_balance"])
df["dti_bucket"]        = pd.cut(
    df["dti_ratio"],
    bins=[0, 0.28, 0.36, 0.43, 1.0],
    labels=["Low", "Medium", "High", "Critical"]
).astype(str)

OutputDataSet = df[["loan_id", "rate_spread_flag", "log_balance", "dti_bucket"]]
',
    @input_data_1 = N'
        SELECT
            loan_id,
            current_balance,
            loan_rate,
            dti_ratio,
            (SELECT fed_funds_rate FROM dbo.market_rates WHERE rate_date = CAST(GETDATE() AS DATE)) AS market_rate
        FROM dbo.active_loans
        WHERE loan_status = ''ACTIVE''
    '
WITH RESULT SETS ((
    loan_id          INT,
    rate_spread_flag BIT,
    log_balance      FLOAT,
    dti_bucket       NVARCHAR(20)
));
```

### Example 2: Running scikit-learn in SQL Server

```sql
-- Train a logistic regression model on historical loan data
-- Store the serialized model in a SQL table
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'
import pandas as pd
import numpy as np
import pickle
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import Pipeline
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score

df = InputDataSet.copy()

FEATURES = ["credit_score", "dti_ratio", "ltv_ratio",
            "loan_age_months", "rate_spread", "unemployment_rate"]
TARGET   = "prepayment_flag"

df = df.dropna(subset=FEATURES + [TARGET])

X = df[FEATURES].values
y = df[TARGET].values

X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, random_state=42, stratify=y
)

pipeline = Pipeline([
    ("scaler", StandardScaler()),
    ("model",  LogisticRegression(max_iter=500, C=0.5, random_state=42))
])
pipeline.fit(X_train, y_train)

auc = roc_auc_score(y_test, pipeline.predict_proba(X_test)[:, 1])
print(f"Training AUC: {auc:.4f}")

# Serialize model to bytes
model_bytes = pickle.dumps(pipeline)

# Return metadata
import pandas as pd
OutputDataSet = pd.DataFrame({
    "model_name":    ["prepayment_logistic_v1"],
    "auc":           [round(auc, 4)],
    "model_bytes":   [model_bytes],
    "trained_rows":  [len(X_train)],
    "feature_list":  [",".join(FEATURES)]
})
',
    @input_data_1 = N'
        SELECT
            loan_id, credit_score, dti_ratio, ltv_ratio,
            loan_age_months, rate_spread, unemployment_rate,
            CAST(prepayment_flag AS INT) AS prepayment_flag
        FROM ml.training_loans_v1
        WHERE split_set = ''TRAIN''
    '
WITH RESULT SETS ((
    model_name   NVARCHAR(100),
    auc          FLOAT,
    model_bytes  VARBINARY(MAX),
    trained_rows INT,
    feature_list NVARCHAR(500)
));
```

### Store and Retrieve the Trained Model

```sql
-- Store trained model in a SQL table
CREATE TABLE ml.models (
    model_id        INT IDENTITY(1,1) PRIMARY KEY,
    model_name      NVARCHAR(100)   NOT NULL,
    model_version   NVARCHAR(20)    NOT NULL DEFAULT '1.0',
    auc             FLOAT,
    model_bytes     VARBINARY(MAX)  NOT NULL,
    feature_list    NVARCHAR(500),
    trained_rows    INT,
    created_date    DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    is_active       BIT             NOT NULL DEFAULT 1
);

-- Insert trained model from sp_execute_external_script result
INSERT INTO ml.models (model_name, auc, model_bytes, feature_list, trained_rows)
EXEC sp_execute_external_script
    @language     = N'Python',
    @script       = N'
-- ... (same training script as above) ...
',
    @input_data_1 = N'SELECT ... FROM ml.training_loans_v1 WHERE split_set = ''TRAIN''';
```

---

## Batch Scoring with a Stored Model

```sql
CREATE OR ALTER PROCEDURE ml.score_prepayment_risk
    @as_of_date DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @as_of_date IS NULL SET @as_of_date = CAST(GETDATE() AS DATE);

    -- Load the active model bytes into a variable
    DECLARE @model_bytes VARBINARY(MAX);
    SELECT TOP 1 @model_bytes = model_bytes
    FROM ml.models
    WHERE model_name = 'prepayment_logistic_v1'
      AND is_active = 1
    ORDER BY created_date DESC;

    IF @model_bytes IS NULL
        RAISERROR('No active model found for prepayment_logistic_v1', 16, 1);

    -- Score active loans
    INSERT INTO ml.prepayment_scores
        (loan_id, prepayment_prob, score_date, model_name)
    EXEC sp_execute_external_script
        @language     = N'Python',
        @script       = N'
import pandas as pd
import pickle

# Deserialize model from bytes passed via @params
model = pickle.loads(bytes(model_bytes))

df = InputDataSet.copy()

FEATURES = ["credit_score", "dti_ratio", "ltv_ratio",
            "loan_age_months", "rate_spread", "unemployment_rate"]

df = df.fillna(df[FEATURES].median())   # simple imputation

probs = model.predict_proba(df[FEATURES].values)[:, 1]

OutputDataSet = pd.DataFrame({
    "loan_id":         df["loan_id"],
    "prepayment_prob": probs,
    "score_date":      score_date,
    "model_name":      "prepayment_logistic_v1"
})
',
        @input_data_1 = N'
            SELECT
                loan_id, credit_score, dti_ratio, ltv_ratio,
                loan_age_months, rate_spread, unemployment_rate
            FROM dbo.active_loans
            WHERE loan_status = ''ACTIVE''
              AND CAST(GETDATE() AS DATE) = @as_of_date
        ',
        @params       = N'@model_bytes VARBINARY(MAX), @score_date DATE',
        @model_bytes  = @model_bytes,
        @score_date   = @as_of_date
    WITH RESULT SETS ((
        loan_id         INT,
        prepayment_prob FLOAT,
        score_date      DATE,
        model_name      NVARCHAR(100)
    ));
END;
GO

-- Execute daily via SQL Agent job
EXEC ml.score_prepayment_risk @as_of_date = NULL;
```

---

## Native Scoring with PREDICT (No Python Required)

The `PREDICT` T-SQL function scores models serialized in formats supported natively by SQL Server's C++ scoring engine — no Python or R process is started. This gives dramatically lower latency and eliminates the Launchpad overhead.

### Supported model formats
- `RevoScaleR` / `revoscalepy` models (rxLogit, rxBTrees, rxDTree, etc.)
- ONNX models (SQL Server 2022+)

### Example: Native Scoring with revoscalepy Model

```sql
-- Training step (run once): train with rx functions for native scoring compatibility
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'
import pandas as pd
from revoscalepy import rx_logit, rx_serialize_model

df = InputDataSet

model = rx_logit(
    formula = "prepayment_flag ~ credit_score + dti_ratio + ltv_ratio + loan_age_months",
    data    = df
)

# rx_serialize_model produces bytes compatible with PREDICT
serialized = rx_serialize_model(model, realtime_scoring_only=True)

import pandas as pd
OutputDataSet = pd.DataFrame({"model_bytes": [serialized]})
',
    @input_data_1 = N'
        SELECT
            CAST(prepayment_flag AS FLOAT) AS prepayment_flag,
            credit_score, dti_ratio, ltv_ratio, loan_age_months
        FROM ml.training_loans_v1
    '
WITH RESULT SETS ((model_bytes VARBINARY(MAX)));
GO

-- Store in models table ...

-- Native scoring — no Python process, pure SQL Server C++
DECLARE @model VARBINARY(MAX);
SELECT TOP 1 @model = model_bytes FROM ml.models
WHERE model_name = 'prepayment_revoscale_v1' AND is_active = 1;

SELECT
    l.loan_id,
    l.credit_score,
    p.prepayment_flag_Pred  AS prepayment_prob
FROM PREDICT(
    MODEL = @model,
    DATA  = dbo.active_loans AS l,
    RUNTIME = PYTHON
) WITH (prepayment_flag_Pred FLOAT) AS p;
```

---

## Real-Time Scoring with sp_rxPredict

`sp_rxPredict` is even faster than `PREDICT` for RevoScale models — it uses an in-process COM library with no satellite process at all:

```sql
-- sp_rxPredict requires a RevoScale model serialized with rx_serialize_model
DECLARE @model_bytes VARBINARY(MAX);
SELECT TOP 1 @model_bytes = model_bytes
FROM ml.models WHERE model_name = 'prepayment_revoscale_v1' AND is_active = 1;

EXEC sp_rxPredict
    @model    = @model_bytes,
    @inputData = N'
        SELECT loan_id, credit_score, dti_ratio, ltv_ratio, loan_age_months
        FROM dbo.active_loans WHERE loan_id = 100042
    ';
```

Latency comparison (typical):

| Method | Typical Latency | Notes |
|---|---|---|
| `sp_execute_external_script` (sklearn) | 200-500ms per call | Python process startup overhead |
| `PREDICT` (revoscalepy) | 10-50ms | No Python process; C++ scoring |
| `sp_rxPredict` | 5-20ms | In-process, fastest option |

---

## Supported Libraries

### Python (SQL Server 2019)
- `revoscalepy` — Microsoft's distributed ML (rxLogit, rxBTrees, rxNaiveBayes)
- `microsoftml` — Fast ML algorithms (featurize_text, rx_fast_trees, rx_neural_network)
- `scikit-learn` (1.x) — Full library available
- `pandas`, `numpy`, `scipy` — Standard scientific Python stack
- `matplotlib` — Plot generation (output as binary blob or file)

### Installing Additional Packages

```sql
-- SQL Server 2019+: use sqlmlutils to install packages
-- Run this from a Python client with sqlmlutils installed:

-- import sqlmlutils
-- connection = sqlmlutils.ConnectionInfo(server="your-server", database="master")
-- sqlmlutils.SQLPackageManager(connection).install("lightgbm")

-- Verify from SQL Server:
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'
import lightgbm as lgb
print(f"LightGBM version: {lgb.__version__}")
OutputDataSet = InputDataSet
',
    @input_data_1 = N'SELECT 1 AS x';
```

---

## Security Model for External Scripts

### Permission Requirements

```sql
-- Grant users permission to run external scripts
GRANT EXECUTE ANY EXTERNAL SCRIPT TO [ml_service_account];

-- Create a dedicated database user for ML scoring
CREATE LOGIN ml_scorer WITH PASSWORD = '...';
CREATE USER  ml_scorer FOR LOGIN ml_scorer;
GRANT EXECUTE ON ml.score_prepayment_risk TO ml_scorer;
-- Note: ml_scorer does NOT need EXECUTE ANY EXTERNAL SCRIPT directly
-- if calling through a signed procedure
```

### Resource Governance for ML Scripts

```sql
-- Prevent ML scripts from consuming all SQL Server memory
-- Create an external resource pool
CREATE EXTERNAL RESOURCE POOL ml_pool
WITH (
    MAX_CPU_PERCENT    = 30,
    MAX_MEMORY_PERCENT = 25
);

-- Create a workload group that uses this pool
CREATE WORKLOAD GROUP ml_workload
USING "default",
EXTERNAL "ml_pool";

-- Classifier function routes ML connections to ml_workload
CREATE FUNCTION dbo.classify_ml_connection()
RETURNS SYSNAME WITH SCHEMABINDING AS
BEGIN
    DECLARE @group SYSNAME = 'default';
    IF APP_NAME() LIKE '%MLServices%'
        SET @group = 'ml_workload';
    RETURN @group;
END;
GO

ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.classify_ml_connection);
ALTER RESOURCE GOVERNOR RECONFIGURE;
```

---

## Complete Workflow: Fraud Detection on Loan Applications

This end-to-end example covers training a fraud classifier and deploying it for real-time scoring on new loan applications.

```sql
-- ============================================================
-- Step 1: Create training data view
-- ============================================================
CREATE OR ALTER VIEW ml.vw_fraud_training AS
SELECT
    la.application_id,
    la.credit_score,
    la.stated_income,
    la.requested_amount,
    la.employer_tenure_years,
    la.address_months,
    la.phone_type,                          -- MOBILE / LANDLINE / VOIP
    DATEDIFF(DAY, c.account_open_date, la.application_date) AS customer_age_days,
    c.prior_fraud_flag,
    c.num_inquiries_12m,
    la.fraud_confirmed                      -- 0/1 label (known post-funding)
FROM dbo.loan_applications la
JOIN dbo.customers c ON la.customer_id = c.customer_id
WHERE la.application_date >= DATEADD(YEAR, -3, GETDATE())
  AND la.fraud_confirmed IS NOT NULL;       -- labeled records only
GO

-- ============================================================
-- Step 2: Train LightGBM fraud model
-- ============================================================
CREATE OR ALTER PROCEDURE ml.train_fraud_model AS
BEGIN
    DECLARE @results TABLE (
        model_name   NVARCHAR(100),
        auc          FLOAT,
        precision_at_10 FLOAT,
        model_bytes  VARBINARY(MAX),
        trained_rows INT
    );

    INSERT INTO @results
    EXEC sp_execute_external_script
        @language = N'Python',
        @script = N'
import pandas as pd
import numpy as np
import pickle
import lightgbm as lgb
from sklearn.model_selection import StratifiedKFold, cross_val_score
from sklearn.preprocessing import LabelEncoder
from sklearn.metrics import roc_auc_score, precision_score

df = InputDataSet.copy()

# Encode categoricals
df["phone_type_enc"] = LabelEncoder().fit_transform(df["phone_type"].fillna("UNKNOWN"))

FEATURES = [
    "credit_score", "stated_income", "requested_amount",
    "employer_tenure_years", "address_months", "phone_type_enc",
    "customer_age_days", "prior_fraud_flag", "num_inquiries_12m"
]
TARGET = "fraud_confirmed"

df = df.dropna(subset=FEATURES + [TARGET])
X = df[FEATURES].values
y = df[TARGET].values.astype(int)

model = lgb.LGBMClassifier(
    n_estimators=400,
    max_depth=6,
    learning_rate=0.05,
    num_leaves=31,
    scale_pos_weight=(y == 0).sum() / (y == 1).sum(),  # handle class imbalance
    random_state=42,
    n_jobs=-1
)

# 5-fold CV AUC
cv_auc = cross_val_score(model, X, y, cv=5, scoring="roc_auc").mean()

# Final fit on all data
model.fit(X, y)

# Precision at top 10% (fraud cases are rare)
scores = model.predict_proba(X)[:, 1]
threshold = np.percentile(scores, 90)
y_pred_top10 = (scores >= threshold).astype(int)
p_at_10 = precision_score(y, y_pred_top10, zero_division=0)

model_bytes = pickle.dumps(model)

OutputDataSet = pd.DataFrame({
    "model_name":      ["fraud_lgbm_v1"],
    "auc":             [round(cv_auc, 4)],
    "precision_at_10": [round(p_at_10, 4)],
    "model_bytes":     [model_bytes],
    "trained_rows":    [len(X)]
})
',
        @input_data_1 = N'SELECT * FROM ml.vw_fraud_training'
    WITH RESULT SETS ((
        model_name      NVARCHAR(100),
        auc             FLOAT,
        precision_at_10 FLOAT,
        model_bytes     VARBINARY(MAX),
        trained_rows    INT
    ));

    -- Deactivate old models
    UPDATE ml.models SET is_active = 0
    WHERE model_name = 'fraud_lgbm_v1';

    -- Insert new model
    INSERT INTO ml.models (model_name, auc, model_bytes, feature_list, trained_rows)
    SELECT
        model_name,
        auc,
        model_bytes,
        'credit_score,stated_income,requested_amount,employer_tenure_years,address_months,phone_type_enc,customer_age_days,prior_fraud_flag,num_inquiries_12m',
        trained_rows
    FROM @results;

    SELECT model_name, auc, precision_at_10, trained_rows FROM @results;
END;
GO

-- ============================================================
-- Step 3: Real-time scoring on new application
-- ============================================================
CREATE OR ALTER PROCEDURE ml.score_fraud_application
    @application_id INT,
    @fraud_prob     FLOAT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @model_bytes VARBINARY(MAX);
    SELECT TOP 1 @model_bytes = model_bytes
    FROM ml.models
    WHERE model_name = 'fraud_lgbm_v1' AND is_active = 1
    ORDER BY created_date DESC;

    DECLARE @result TABLE (application_id INT, fraud_prob FLOAT);

    INSERT INTO @result
    EXEC sp_execute_external_script
        @language = N'Python',
        @script = N'
import pandas as pd
import pickle
import numpy as np
from sklearn.preprocessing import LabelEncoder

model = pickle.loads(bytes(model_bytes))

df = InputDataSet.copy()
df["phone_type_enc"] = LabelEncoder().fit_transform(
    df["phone_type"].fillna("UNKNOWN")
)

FEATURES = [
    "credit_score", "stated_income", "requested_amount",
    "employer_tenure_years", "address_months", "phone_type_enc",
    "customer_age_days", "prior_fraud_flag", "num_inquiries_12m"
]

df = df.fillna(0)
probs = model.predict_proba(df[FEATURES].values)[:, 1]

OutputDataSet = pd.DataFrame({
    "application_id": df["application_id"],
    "fraud_prob":     probs
})
',
        @input_data_1 = N'
            SELECT
                la.application_id,
                la.credit_score,
                la.stated_income,
                la.requested_amount,
                la.employer_tenure_years,
                la.address_months,
                la.phone_type,
                DATEDIFF(DAY, c.account_open_date, la.application_date) AS customer_age_days,
                c.prior_fraud_flag,
                c.num_inquiries_12m
            FROM dbo.loan_applications la
            JOIN dbo.customers c ON la.customer_id = c.customer_id
            WHERE la.application_id = @app_id
        ',
        @params      = N'@model_bytes VARBINARY(MAX), @app_id INT',
        @model_bytes = @model_bytes,
        @app_id      = @application_id
    WITH RESULT SETS ((application_id INT, fraud_prob FLOAT));

    SELECT @fraud_prob = fraud_prob FROM @result;

    -- Log the score
    INSERT INTO ml.fraud_scores (application_id, fraud_prob, model_name, scored_at)
    SELECT application_id, fraud_prob, 'fraud_lgbm_v1', SYSUTCDATETIME()
    FROM @result;
END;
GO
```

---

## Interview Q&A

### Q1: What is SQL Server Machine Learning Services and what problem does it solve compared to running Python externally?

**Answer:** SQL Server ML Services is an in-database extensibility framework that executes Python or R code inside the SQL Server process, with data passed via shared memory. It was introduced in SQL Server 2016 (R) and 2017 (Python).

The problems it solves vs. external Python:

1. **Data movement eliminated:** Training or scoring against a 100M-row table by pulling data to a Python client requires transferring gigabytes over a network. ML Services keeps data inside SQL Server — data passes via shared memory at near-memory bandwidth.
2. **Security boundary preserved:** Data never leaves the SQL Server security boundary. No ODBC connection string in a Python script that can be stolen. No firewall hole to open.
3. **Operational simplicity:** The ML pipeline is a stored procedure call. It can be scheduled with SQL Agent, monitored like any T-SQL job, and governed by existing DBA tooling. No Kubernetes, no MLflow server, no separate Python environment to maintain.
4. **Governance and audit:** Every execution is logged in SQL Server audit trails. Data access is controlled by SQL permissions on the input query, not by whatever the Python script happens to connect to.

The tradeoff: ML Services is constrained to the compute and memory of the SQL Server box. For very large training jobs, Databricks or Snowflake ML scales horizontally. ML Services is optimal for operational scoring pipelines against data that lives in SQL Server.

### Q2: Explain the extensibility framework architecture. What happens when sp_execute_external_script is called?

**Answer:** When `sp_execute_external_script` is called:

1. SQL Server authenticates the caller and validates permissions (`EXECUTE ANY EXTERNAL SCRIPT`).
2. The request is forwarded to the **Launchpad service** (`MSSQLLaunchpad$INSTANCENAME`), a separate Windows service acting as a process manager.
3. Launchpad spawns a **satellite process** (python.exe or R.exe) in an isolated AppContainer (SQL Server 2019+ uses Windows AppContainers; earlier versions use SQLRUserGroup worker accounts).
4. The input data (`@input_data_1`) is executed as a T-SQL query and the result set is serialized into a shared-memory buffer.
5. The Python/R satellite reads the data from shared memory (zero network transfer), executes the script, and writes `OutputDataSet` back to shared memory.
6. SQL Server reads the output from shared memory and returns it as a result set to the caller.
7. The satellite process terminates (or is returned to a pool).

Key implication: the satellite process has its own memory space and cannot directly read SQL Server buffer pool memory. Resource Governor external resource pools cap CPU and memory available to satellites, protecting SQL Server OLTP workloads.

### Q3: What is the difference between PREDICT, sp_rxPredict, and sp_execute_external_script for model scoring?

**Answer:**

| Method | Model Format | Python Process | Typical Latency | Best For |
|---|---|---|---|---|
| `sp_execute_external_script` | Any (pickle, ONNX, etc.) | Yes — full satellite | 200-500ms+ | Batch scoring, any library |
| `PREDICT` | RevoScale or ONNX | No — C++ native | 10-50ms | High-throughput batch |
| `sp_rxPredict` | RevoScale only | No — in-process COM | 5-20ms | Real-time row-level scoring |

For a loan origination system scoring one application at a time in under 50ms, `sp_rxPredict` is the right choice — it uses an in-process COM library and avoids all satellite process overhead. The constraint is that only RevoScale models (rxLogit, rxBTrees) are supported.

For operational batch jobs scoring 500K loans overnight, `sp_execute_external_script` with scikit-learn or LightGBM gives you access to the full Python ML ecosystem. The per-call latency is acceptable for batch work where the parallelism is at the job level.

`PREDICT` with ONNX (SQL Server 2022) is the bridge: convert your scikit-learn model to ONNX format once, then score it natively without a Python process, using whatever framework you trained with.

### Q4: How do you pass parameters and data into a Python script in sp_execute_external_script?

**Answer:** There are two mechanisms:

**Input dataset (`@input_data_1`):** A T-SQL SELECT statement whose result set is materialized as `InputDataSet` (a pandas DataFrame) inside the Python script. This is the primary mechanism for bulk data. The `@input_data_1_name` parameter allows renaming `InputDataSet` to any valid Python variable name.

**Scalar parameters (`@params`):** A T-SQL parameter declaration string. Named parameters declared here are directly accessible as Python variables inside the script. This is how you pass control values: model bytes from a table, a date parameter, a threshold value.

```sql
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'
# InputDataSet is available as a DataFrame
# threshold and score_date are directly available as Python variables
high_risk = InputDataSet[InputDataSet["score"] > threshold].copy()
high_risk["scored_date"] = score_date
OutputDataSet = high_risk
',
    @input_data_1 = N'SELECT loan_id, score FROM ml.scores WHERE score_date = @dt',
    @input_data_1_name = N'InputDataSet',
    @params = N'@threshold FLOAT, @score_date DATE, @dt DATE',
    @threshold  = 0.75,
    @score_date = '2026-03-07',
    @dt         = '2026-03-07';
```

Important nuance: `@params` only supports scalar types (INT, FLOAT, NVARCHAR, DATE, VARBINARY(MAX) for model bytes, etc.). To pass a complex object (like a trained model), serialize it to `VARBINARY(MAX)`, store in a SQL table, load into a T-SQL variable, and pass via `@params`. The Python script then deserializes it with `pickle.loads(bytes(model_bytes))`.

### Q5: How do you handle errors and logging in sp_execute_external_script?

**Answer:** Error handling requires a multi-layer approach because errors in the Python layer and errors in the T-SQL layer surface differently.

**Python-side errors** (unhandled exceptions) propagate as SQL Server error 39004 or 39012 with the Python traceback in the message text. Wrap the entire Python script in a try/except and log to OutputDataSet or a logging table:

```python
import traceback, pandas as pd
try:
    # main logic here
    result = do_work(InputDataSet)
    OutputDataSet = result
except Exception as e:
    OutputDataSet = pd.DataFrame({
        "status": ["ERROR"],
        "message": [str(e)],
        "traceback": [traceback.format_exc()]
    })
```

**T-SQL-side:** Wrap the EXEC in a TRY/CATCH block. Log to an ML execution log table:

```sql
BEGIN TRY
    INSERT INTO ml.execution_log (proc_name, status, started_at)
    VALUES ('score_prepayment_risk', 'RUNNING', SYSUTCDATETIME());

    EXEC ml.score_prepayment_risk;

    UPDATE ml.execution_log SET status = 'SUCCESS', finished_at = SYSUTCDATETIME()
    WHERE execution_id = SCOPE_IDENTITY();
END TRY
BEGIN CATCH
    UPDATE ml.execution_log SET status = 'FAILED', error_msg = ERROR_MESSAGE(),
        finished_at = SYSUTCDATETIME()
    WHERE execution_id = SCOPE_IDENTITY();
    THROW;
END CATCH;
```

**Print output:** Python `print()` statements appear in the SQL Server Messages tab and are captured in SQL Agent job logs — useful for logging AUC metrics during training.

### Q6: What are revoscalepy and MicrosoftML and when do you use them over scikit-learn?

**Answer:**

**revoscalepy** is Microsoft's Python library that wraps optimized C++ implementations of common ML algorithms (rx_logit, rx_btrees, rx_dtree, rx_naive_bayes, rx_kmeans). Key advantage: models serialized with `rx_serialize_model(realtime_scoring_only=True)` can be scored with `PREDICT` or `sp_rxPredict` without a Python process — enabling sub-20ms real-time scoring.

**microsoftml** adds deep learning and advanced NLP algorithms: `rx_fast_trees` (fast gradient boosting), `rx_fast_linear` (SDCA linear models), `rx_neural_network`, `featurize_text` (TF-IDF feature extraction from text columns).

**Use revoscalepy/microsoftml when:**
- You need real-time scoring with `sp_rxPredict` (only supports RevoScale models)
- You are building native scoring pipelines with `PREDICT`
- You need transparent chunked processing of datasets larger than RAM (revoscalepy handles XDF/chunked data natively)

**Use scikit-learn/LightGBM/XGBoost when:**
- You need cutting-edge algorithm performance (LightGBM routinely beats rx_fast_trees)
- You want model portability (pickle to Databricks, MLflow, etc.)
- Real-time latency is not required (batch scoring only)
- You need extensive ecosystem tooling (SHAP, Optuna, etc.)

For a prepayment model scored nightly on 500K loans, scikit-learn is fine. For a fraud model called 200 times per minute from the loan origination system, use revoscalepy + sp_rxPredict.

### Q7: How do you deploy ML Services in a high-availability SQL Server environment?

**Answer:** ML Services integrates with SQL Server's existing HA features with some considerations:

**Always On Availability Groups:**
- ML Services must be installed and configured on every replica independently (the Launchpad service is local to each SQL Server instance).
- Models stored in tables replicate automatically to secondary replicas via AG synchronization.
- Ensure both primary and secondary have the same Python packages installed (use sqlmlutils with the same package list on each node).
- Scoring stored procedures that load model bytes from a table work on any replica (primary or readable secondary).

**Failover Clustering:**
- ML Services installs on the shared SQL Server installation. The Launchpad service is a cluster-aware resource — it fails over with the SQL Server resource group.
- The extensibility working directory path must be on shared or locally available storage on all nodes.

**Scale-out with Resource Governor:**
- Use Resource Governor external resource pools to allocate fixed CPU/memory percentages to ML workloads, protecting OLTP from ML batch jobs running concurrently.

**Package management:**
- Maintain a `requirements.txt` per SQL Server instance. Use sqlmlutils in a deployment pipeline to synchronize packages across all AG replicas during deployment windows.

### Q8: How do you prevent Python scripts in ML Services from becoming a security vulnerability?

**Answer:** Defense-in-depth approach:

1. **Principle of least privilege for input queries:** The T-SQL input query runs under the caller's SQL permissions. Callers should only have SELECT on the specific tables needed — not db_datareader on the whole database.
2. **Code review for all stored procedures:** Treat every `sp_execute_external_script` stored procedure as a code deployment. Python scripts should be reviewed for: shell execution (`os.system`, `subprocess`), file system access, network calls (`requests`, `urllib`), and arbitrary code execution patterns.
3. **AppContainer isolation (SQL Server 2019+):** AppContainers are Windows sandboxes that block network access by default. Verify AppContainer mode is enabled: `SELECT * FROM sys.dm_exec_external_script_execution_stats;` — if AppContainer is active, satellite processes cannot make outbound network calls.
4. **Disable ML Services on databases that don't need it:** The `EXECUTE ANY EXTERNAL SCRIPT` permission is server-level. Grant it only to service accounts and trusted developer logins — not to end users.
5. **Package allowlisting:** Use sqlmlutils to manage installed packages. Prohibit `pip install` by the Launchpad service account. Audit installed packages on a schedule.
6. **No secrets in scripts:** Never embed connection strings, API keys, or passwords in Python code inside `sp_execute_external_script`. Use SQL Server credentials, certificate-based auth, or pass via `@params` from a dedicated secrets table with strict permissions.

### Q9: Describe a complete prepayment prediction pipeline in SQL Server ML Services for a mortgage portfolio.

**Answer:** Full pipeline for a 500K-loan portfolio:

**Data preparation (T-SQL):** A nightly job materializes a feature table (`ml.loan_features_daily`) from operational tables: loan balance, current rate, market rate (from external rate table), borrower credit score (updated monthly from bureau feed), DTI, LTV, unemployment rate (from economic data table). This runs as a standard Airflow/SQL Agent job.

**Training pipeline (quarterly):** A SQL Agent job calls `ml.train_prepayment_model` (stored procedure). The procedure calls `sp_execute_external_script` with a SELECT from `ml.vw_prepayment_training` (3 years of labeled loans). A LightGBM model is trained with 5-fold CV, AUC/Gini metrics logged. The serialized model bytes are inserted into `ml.models`. If AUC drops below 0.82 vs. the current production model, training is flagged for review and the new model is not activated automatically.

**Batch scoring (nightly):** SQL Agent job calls `ml.score_prepayment_risk`. Loads model bytes, calls `sp_execute_external_script` with active loans query. Predictions written to `ml.prepayment_scores(loan_id, score_date, prepayment_prob, model_version)`. Job completes in ~4 minutes for 500K loans on a 32-core SQL Server.

**Downstream consumption:** A dbt model joins scores to the loan portfolio, computes portfolio-level CPR (Constant Prepayment Rate) estimates, and feeds a Power BI dashboard used by the Asset-Liability Management team.

**Model monitoring:** Weekly SQL Agent job queries `ml.prepayment_scores` vs. `dbo.loan_payoffs` to compute realized vs. predicted prepayment rate by origination cohort. Alert fires via Database Mail if Gini drops below 0.60 on any cohort with >500 loans.

### Q10: What are the limitations of SQL Server ML Services and when should you move to a different platform?

**Answer:** ML Services has clear limitations that should drive platform migration decisions:

1. **Single-node compute:** No horizontal scale-out. Training on 100M+ rows may take hours or exhaust RAM. Databricks or Snowflake ML scale horizontally without constraint.
2. **Python version lag:** SQL Server ships with a specific Python version; upgrading requires a SQL Server CU or full instance upgrade. You cannot use Python 3.12 features on a SQL Server 2019 instance without a service upgrade.
3. **Package isolation:** Only one Python environment per SQL Server instance (pre-2022). If two ML workloads need conflicting package versions, you cannot isolate them. SQL Server 2022 adds external language extensibility that partially addresses this.
4. **No GPU support:** SQL Server ML Services does not support GPU acceleration. Deep learning models (neural networks, transformers) are impractical here.
5. **No distributed training:** revoscalepy's remote compute context works for RevoScale algorithms only; LightGBM/XGBoost distributed training is not supported inside ML Services.
6. **Parallelism limited to SQL Server scheduler:** Parallel execution within a single `sp_execute_external_script` call is limited. For massive batch jobs, you cannot spread across 100 worker nodes.

**Move to Databricks/Snowflake ML when:** training data exceeds ~50M rows; deep learning is needed; you need GPU compute; the team needs a collaborative notebook environment; the ML lifecycle needs full MLflow + model registry integration.

**Keep ML Services when:** data is already in SQL Server; the team is SQL-heavy with limited Python ops experience; real-time scoring latency requirements are met by sp_rxPredict; regulatory requirements demand data stay inside the SQL Server security boundary.

---

## Pro Tips

- **Always test your Python script interactively before embedding it in a stored procedure.** Develop in a Jupyter notebook connected to the database via SQLAlchemy. Only embed in `sp_execute_external_script` once the logic is proven.
- **Use `WITH RESULT SETS` to enforce output schema.** Without it, SQL Server infers column types from the DataFrame, which can silently convert INT to FLOAT or truncate NVARCHAR lengths. Always be explicit.
- **Pass model bytes via `@params`, not via a SELECT inside the Python script.** Loading the model in T-SQL before calling `sp_execute_external_script` and passing the bytes as a parameter is more predictable and avoids nested connection issues inside the satellite.
- **Enable Resource Governor external pools before going to production.** A runaway batch scoring job that consumes 100% of SQL Server memory will crash your OLTP system. Cap ML workloads at 25-30% memory from day one.
- **Pre-aggregate in SQL before calling Python.** The cheapest operation is reducing the data volume before it enters the Python runtime. Group by, filter, and summarize in the `@input_data_1` query; Python handles only the result, not the full table scan.
- **Log model bytes SHA256 hash alongside the stored model.** `HASHBYTES('SHA2_256', model_bytes)` gives you a fingerprint. If a model is accidentally overwritten, you can verify whether the bytes changed.
- **Use `PRINT` for lightweight telemetry.** Python `print()` inside `sp_execute_external_script` writes to SQL Server Messages, which SQL Agent captures in job history. Print training AUC, row counts, and timing so you have an audit trail without a full MLflow setup.
- **Test rollback before you need it.** Keep the previous production model in `ml.models` with `is_active = 0`. Document the one-line SQL to flip it back to active. Practice the rollback on a dev instance so it takes under 2 minutes in a production incident.
