# Anomaly Detection in Mortgage Data
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

Mortgage servicing and MBS analytics generate large volumes of time-series and tabular data where anomalies signal fraud, operational errors, market stress, or data quality failures. A sudden CPR spike in a pool, an unusual delinquency bucket jump, a servicer remittance discrepancy, or a geographic cluster of rapid defaults all require detection systems that operate faster than monthly human review cycles. This guide covers statistical and ML-based anomaly detection methods, their implementation in Snowflake and Python, integration with SQL Server alerting, and the mortgage-specific context needed to distinguish a true anomaly from expected behavior.

---

## Key Concepts

| Concept | Definition |
|---|---|
| Point Anomaly | A single data point that deviates significantly from the distribution |
| Contextual Anomaly | A point that is anomalous given its context (e.g., normal value in wrong season) |
| Collective Anomaly | A sequence of individually normal points that form an anomalous pattern together |
| CPR | Conditional Prepayment Rate — annualized rate at which loans in a pool are prepaying |
| CDR | Conditional Default Rate — annualized rate at which loans are defaulting |
| DQ Buckets | Delinquency buckets: 30DPD, 60DPD, 90DPD, FC (Foreclosure), REO |
| PSA | Public Securities Association prepayment speed benchmark |
| Isolation Forest | Ensemble of random trees that isolates anomalies requiring fewer splits |
| LOF | Local Outlier Factor — density-based, compares local density to neighbors |
| ARIMA Residuals | Residuals from a time-series model; large residuals indicate anomalies |
| RCF | Random Cut Forest — AWS SageMaker streaming anomaly detection algorithm |

---

## Types of Anomalies in Mortgage Data

### Taxonomy

```
Anomaly Types
├── Point Anomalies
│   ├── FICO score of 850+ with DTI of 85% (contradictory combination)
│   ├── Single month CPR spike to 80 PSA in a non-callable pool
│   └── Loan UPB increasing month-over-month (negative amortization flag)
│
├── Contextual Anomalies
│   ├── CPR of 25% in Q1 (abnormal; expected Q1 seasonality is lower)
│   ├── Higher delinquencies in a Prime pool than in a Subprime pool
│   └── Zero prepayments in a rising-rate environment (unexpected direction)
│
└── Collective Anomalies
    ├── Geographic cluster: 30 loans in same ZIP transitioning 30→60→90 in same quarter
    ├── Servicer reporting: 6 consecutive months of remittance < expected interest
    └── Vintage deterioration: 2023 originations defaulting faster than all prior vintages
```

### Mortgage-Specific Anomaly Scenarios

| Scenario | Data Signal | Business Impact |
|---|---|---|
| Sudden CPR spike | Pool-level CPR jumps >20 percentage points MoM | Duration/convexity shock for MBS investors |
| DQ bucket skip | Loan goes from Current to 90DPD (skips 30, 60) | Servicer reporting error or fraud |
| Remittance shortfall | Pool interest collected < coupon × UPB | Servicer advance failure or misappropriation |
| Geographic default cluster | Default rate in ZIP code > 5σ above MSA average | Local economic shock or originator fraud ring |
| AVM-to-appraisal divergence | AVM value < 80% of appraisal at origination | Appraisal inflation; increased LGD |
| Null rate spike | % null values in FICO field increases from 0.5% to 15% | Upstream data pipeline failure |
| Loan count discrepancy | Pool factor implies different loan count than servicer tape | Reconciliation failure between trustee and servicer |

---

## Statistical Methods

### Z-Score

```python
import numpy as np
import pandas as pd

def z_score_anomalies(series: pd.Series, threshold: float = 3.0) -> pd.Series:
    """Flag values more than `threshold` standard deviations from mean."""
    mean = series.mean()
    std  = series.std()
    z    = (series - mean) / std
    return z.abs() > threshold

# Example: flag pools with abnormal CPR
pool_monthly["CPR_ANOMALY"] = z_score_anomalies(pool_monthly["CPR"], threshold=3.0)
```

### IQR Method

```python
def iqr_anomalies(series: pd.Series, multiplier: float = 1.5) -> pd.Series:
    """Tukey fence method — more robust to skewed distributions."""
    q1 = series.quantile(0.25)
    q3 = series.quantile(0.75)
    iqr = q3 - q1
    lower = q1 - multiplier * iqr
    upper = q3 + multiplier * iqr
    return (series < lower) | (series > upper)
```

### When to Use Each

| Method | Best For | Limitation |
|---|---|---|
| Z-Score | Normally distributed metrics | Sensitive to outliers distorting mean/std |
| IQR | Skewed distributions (CPR, CDR) | Assumes stationarity |
| Grubbs Test | Single outlier detection in small samples | One outlier at a time |
| ARIMA Residuals | Time-series with trend/seasonality | Requires stationarity transforms |

---

## SQL: Anomaly Detection in Loan Performance Data

```sql
-- ============================================================
-- Detect DQ bucket anomalies: loans skipping delinquency stages
-- or showing implausible state transitions
-- ============================================================

-- 1. Identify loans that jumped from Current to 90DPD (skip 30 and 60)
WITH monthly_dq AS (
    SELECT
        loan_id,
        reporting_period,
        days_delinquent,
        LAG(days_delinquent, 1) OVER (
            PARTITION BY loan_id ORDER BY reporting_period
        ) AS prev_month_dq
    FROM LOAN_PERFORMANCE.FACT_MONTHLY_PERF
    WHERE reporting_period >= DATEADD(month, -6, CURRENT_DATE())
),
dq_skips AS (
    SELECT
        loan_id,
        reporting_period,
        prev_month_dq,
        days_delinquent,
        'DQ_BUCKET_SKIP' AS anomaly_type
    FROM monthly_dq
    WHERE prev_month_dq = 0
      AND days_delinquent >= 60   -- Jumped from current to 60+ DPD
)

-- 2. Pool-level CPR spike detection using Z-score within pool cohort
, pool_cpr_stats AS (
    SELECT
        pool_id,
        AVG(monthly_cpr)                           AS avg_cpr,
        STDDEV(monthly_cpr)                        AS std_cpr,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY monthly_cpr)
            - PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY monthly_cpr) AS iqr_cpr
    FROM MBS_ANALYTICS.POOL_MONTHLY_METRICS
    WHERE reporting_period BETWEEN DATEADD(year, -2, CURRENT_DATE())
                               AND DATEADD(month, -1, CURRENT_DATE())
    GROUP BY pool_id
),
pool_current AS (
    SELECT
        p.pool_id,
        p.reporting_period,
        p.monthly_cpr,
        s.avg_cpr,
        s.std_cpr,
        (p.monthly_cpr - s.avg_cpr) / NULLIF(s.std_cpr, 0) AS z_score_cpr
    FROM MBS_ANALYTICS.POOL_MONTHLY_METRICS p
    JOIN pool_cpr_stats s ON p.pool_id = s.pool_id
    WHERE p.reporting_period = (SELECT MAX(reporting_period)
                                FROM MBS_ANALYTICS.POOL_MONTHLY_METRICS)
),
cpr_anomalies AS (
    SELECT
        pool_id,
        reporting_period,
        monthly_cpr,
        avg_cpr,
        z_score_cpr,
        'CPR_SPIKE' AS anomaly_type
    FROM pool_current
    WHERE ABS(z_score_cpr) > 3.0
)

-- 3. Data quality: null rate spike per field per reporting period
, null_rate_current AS (
    SELECT
        reporting_period,
        COUNT(*) AS total_records,
        SUM(CASE WHEN fico_score IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS null_rate_fico,
        SUM(CASE WHEN current_upb IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS null_rate_upb
    FROM LOAN_PERFORMANCE.FACT_MONTHLY_PERF
    WHERE reporting_period >= DATEADD(month, -3, CURRENT_DATE())
    GROUP BY reporting_period
),
null_rate_baseline AS (
    SELECT
        AVG(null_rate_fico)    AS avg_null_fico,
        STDDEV(null_rate_fico) AS std_null_fico,
        AVG(null_rate_upb)     AS avg_null_upb,
        STDDEV(null_rate_upb)  AS std_null_upb
    FROM null_rate_current
    WHERE reporting_period < (SELECT MAX(reporting_period) FROM null_rate_current)
)

-- Union all anomaly types into a single alert table
SELECT 'DQ_BUCKET_SKIP'   AS anomaly_type,
       CAST(loan_id AS VARCHAR) AS entity_id,
       reporting_period,
       CONCAT('Loan jumped from ', prev_month_dq, ' to ', days_delinquent,
              ' DPD in one month') AS anomaly_description,
       CURRENT_TIMESTAMP() AS detected_at
FROM dq_skips

UNION ALL

SELECT 'CPR_SPIKE'        AS anomaly_type,
       CAST(pool_id AS VARCHAR),
       reporting_period,
       CONCAT('CPR=', ROUND(monthly_cpr,2), ' vs avg=', ROUND(avg_cpr,2),
              ' Z-score=', ROUND(z_score_cpr,2)) AS anomaly_description,
       CURRENT_TIMESTAMP()
FROM cpr_anomalies;
```

---

## Python: Isolation Forest on MBS Pool Data

```python
import pandas as pd
import numpy as np
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

# -------------------------------------------------------
# 1. Load MBS pool monthly metrics
# -------------------------------------------------------
df = pd.read_parquet("mbs_pool_monthly_metrics.parquet")

# Features for anomaly detection in MBS pools
POOL_FEATURES = [
    "MONTHLY_CPR",
    "MONTHLY_CDR",
    "MONTHLY_SEVERITY",   # loss severity on liquidated loans
    "DQ_30_PCT",          # % 30DPD in pool
    "DQ_60_PCT",
    "DQ_90_PLUS_PCT",
    "PREPAY_SPEED_PSA",
    "POOL_FACTOR",        # remaining balance / original balance
    "AVG_LOAN_AGE_MONTHS",
    "WEIGHTED_AVG_FICO",
    "WEIGHTED_AVG_LTV"
]

# Work with a single pool for illustration; production runs across all pools
pool_id   = "FN_MA_0001234"
pool_data = df[df["POOL_ID"] == pool_id].sort_values("REPORTING_PERIOD")

X = pool_data[POOL_FEATURES].fillna(pool_data[POOL_FEATURES].median())

# -------------------------------------------------------
# 2. Fit Isolation Forest
# -------------------------------------------------------
scaler = StandardScaler()
X_scaled = scaler.fit_transform(X)

iso_forest = IsolationForest(
    n_estimators=200,
    contamination=0.05,  # expect ~5% anomalous months
    random_state=42,
    n_jobs=-1
)
iso_forest.fit(X_scaled)

# -1 = anomaly, 1 = normal
pool_data = pool_data.copy()
pool_data["ANOMALY_LABEL"]  = iso_forest.predict(X_scaled)
pool_data["ANOMALY_SCORE"]  = iso_forest.decision_function(X_scaled)
# More negative score = more anomalous
pool_data["IS_ANOMALY"]     = pool_data["ANOMALY_LABEL"] == -1

anomalies = pool_data[pool_data["IS_ANOMALY"]]
print(f"Detected {len(anomalies)} anomalous months out of {len(pool_data)}")
print(anomalies[["REPORTING_PERIOD", "MONTHLY_CPR", "MONTHLY_CDR",
                  "ANOMALY_SCORE"]].to_string())

# -------------------------------------------------------
# 3. Visualize CPR anomalies
# -------------------------------------------------------
fig, ax = plt.subplots(figsize=(14, 5))
ax.plot(pool_data["REPORTING_PERIOD"], pool_data["MONTHLY_CPR"],
        label="Monthly CPR", color="steelblue", linewidth=1.5)
ax.scatter(
    anomalies["REPORTING_PERIOD"],
    anomalies["MONTHLY_CPR"],
    color="red", zorder=5, s=80, label="Isolation Forest Anomaly"
)
ax.set_title(f"Pool {pool_id} — CPR with Anomaly Detection")
ax.set_ylabel("CPR (%)")
ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))
ax.legend()
plt.tight_layout()
plt.savefig(f"anomaly_cpr_{pool_id}.png", dpi=150)

# -------------------------------------------------------
# 4. Multi-pool batch anomaly detection
# -------------------------------------------------------
def detect_pool_anomalies_batch(
    df: pd.DataFrame,
    features: list,
    contamination: float = 0.05,
    lookback_months: int = 24
) -> pd.DataFrame:
    """
    Run Isolation Forest for each pool independently over the lookback window.
    Returns DataFrame of anomalous records with scores.
    """
    results = []
    cutoff = pd.Timestamp.today() - pd.DateOffset(months=lookback_months)

    for pool_id, group in df.groupby("POOL_ID"):
        group = group[group["REPORTING_PERIOD"] >= cutoff].copy()
        if len(group) < 6:  # need minimum history
            continue

        X = group[features].fillna(group[features].median())
        X_scaled = StandardScaler().fit_transform(X)

        clf = IsolationForest(
            n_estimators=100,
            contamination=contamination,
            random_state=42
        )
        group["ANOMALY_LABEL"] = clf.fit_predict(X_scaled)
        group["ANOMALY_SCORE"] = clf.decision_function(X_scaled)
        group["POOL_ID"]       = pool_id

        results.append(group[group["ANOMALY_LABEL"] == -1])

    return pd.concat(results, ignore_index=True) if results else pd.DataFrame()

anomaly_report = detect_pool_anomalies_batch(df, POOL_FEATURES)
```

---

## Snowflake ML: ANOMALY_DETECTION Function

```sql
-- ============================================================
-- Snowflake built-in anomaly detection on CPR time series
-- Uses ML-based anomaly detection natively in Snowflake
-- ============================================================

-- 1. Create training dataset (supervised: label known anomaly periods)
CREATE OR REPLACE TABLE MBS_ANALYTICS.CPR_TRAINING AS
SELECT
    reporting_period::TIMESTAMP_NTZ AS ts,
    monthly_cpr                     AS value,
    -- Label historical anomalies for supervised training
    CASE WHEN reporting_period IN ('2020-03-01', '2020-04-01', '2022-06-01')
         THEN TRUE ELSE FALSE END   AS is_anomaly
FROM MBS_ANALYTICS.POOL_MONTHLY_METRICS
WHERE pool_id = 'FN_MA_0001234'
  AND reporting_period < '2024-01-01'
ORDER BY ts;

-- 2. Train anomaly detection model
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION cpr_anomaly_model (
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'MBS_ANALYTICS.CPR_TRAINING'),
    SERIES_COLNAME => NULL,         -- single time series
    TIMESTAMP_COLNAME => 'TS',
    TARGET_COLNAME => 'VALUE',
    LABEL_COLNAME => 'IS_ANOMALY'   -- supervised mode
);

-- 3. Score new data
CALL cpr_anomaly_model!DETECT_ANOMALIES(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'MBS_ANALYTICS.CPR_CURRENT'),
    SERIES_COLNAME => NULL,
    TIMESTAMP_COLNAME => 'TS',
    TARGET_COLNAME => 'VALUE'
);

-- 4. Cortex-generated narrative for detected anomalies
SELECT
    a.ts,
    a.y AS observed_cpr,
    a.forecast AS expected_cpr,
    a.is_anomaly,
    a.percentile,
    SNOWFLAKE.CORTEX.COMPLETE(
        'mistral-large',
        CONCAT(
            'A mortgage MBS pool showed a CPR anomaly. ',
            'Expected CPR: ', ROUND(a.forecast, 2), '%. ',
            'Observed CPR: ', ROUND(a.y, 2), '%. ',
            'Date: ', TO_CHAR(a.ts, 'YYYY-MM-DD'), '. ',
            'In 2-3 sentences, explain possible causes for this anomaly ',
            'and suggested investigation steps.'
        )
    ) AS anomaly_narrative
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) a
WHERE a.is_anomaly = TRUE;
```

---

## Time-Series Anomaly Detection with Prophet

```python
from prophet import Prophet
import pandas as pd
import numpy as np

def detect_timeseries_anomalies_prophet(
    series: pd.DataFrame,
    date_col: str,
    value_col: str,
    interval_width: float = 0.99
) -> pd.DataFrame:
    """
    Use Prophet to fit a trend+seasonality model.
    Points outside the prediction interval are flagged as anomalies.
    Works well for CPR/CDR series with monthly seasonality.
    """
    df_prophet = series[[date_col, value_col]].rename(
        columns={date_col: "ds", value_col: "y"}
    )

    model = Prophet(
        yearly_seasonality=True,
        weekly_seasonality=False,
        daily_seasonality=False,
        interval_width=interval_width,
        changepoint_prior_scale=0.05  # conservative; avoid overfitting
    )
    model.fit(df_prophet)

    forecast = model.predict(df_prophet[["ds"]])
    result = df_prophet.merge(
        forecast[["ds", "yhat", "yhat_lower", "yhat_upper"]], on="ds"
    )
    result["IS_ANOMALY"] = (
        (result["y"] < result["yhat_lower"]) |
        (result["y"] > result["yhat_upper"])
    )
    result["RESIDUAL"] = result["y"] - result["yhat"]
    return result

# Apply to CPR series
cpr_series = pool_data[["REPORTING_PERIOD", "MONTHLY_CPR"]].copy()
cpr_anomalies_prophet = detect_timeseries_anomalies_prophet(
    cpr_series, "REPORTING_PERIOD", "MONTHLY_CPR", interval_width=0.99
)
print(cpr_anomalies_prophet[cpr_anomalies_prophet["IS_ANOMALY"]])
```

---

## Threshold Setting and Alert Generation

```python
# Alert configuration: per-metric thresholds with severity levels
ALERT_CONFIG = {
    "MONTHLY_CPR": {
        "z_score_threshold": 3.0,
        "absolute_change_pct": 50,   # flag if CPR changes >50% MoM
        "severity_levels": {
            "CRITICAL": 5.0,
            "HIGH":     3.5,
            "MEDIUM":   3.0
        }
    },
    "DQ_90_PLUS_PCT": {
        "z_score_threshold": 2.5,
        "absolute_change_pct": 30,
        "severity_levels": {
            "CRITICAL": 4.0,
            "HIGH":     3.0,
            "MEDIUM":   2.5
        }
    },
    "NULL_RATE_FICO": {
        "z_score_threshold": 2.0,
        "absolute_threshold": 0.05,  # flag if >5% nulls regardless of Z
        "severity_levels": {
            "CRITICAL": 0.15,         # >15% nulls
            "HIGH":     0.10,
            "MEDIUM":   0.05
        }
    }
}

def generate_alert(metric: str, pool_id: str, observed_value: float,
                   z_score: float, config: dict) -> dict | None:
    thresholds = config[metric]["severity_levels"]
    severity = None
    for level in ["CRITICAL", "HIGH", "MEDIUM"]:
        if abs(z_score) >= thresholds[level]:
            severity = level
            break
    if severity is None:
        return None
    return {
        "pool_id":     pool_id,
        "metric":      metric,
        "value":       observed_value,
        "z_score":     z_score,
        "severity":    severity,
        "alert_time":  pd.Timestamp.utcnow().isoformat()
    }
```

---

## SQL Server Integration — SQL Agent Alerting

```sql
-- SQL Server: stored procedure to detect null rate spikes and send alerts
-- Runs via SQL Server Agent job daily after servicer tape load

CREATE OR ALTER PROCEDURE dbo.usp_DetectDataQualityAnomalies
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @AlertMessage NVARCHAR(MAX) = N'';
    DECLARE @RecipientEmail NVARCHAR(255) = N'data-ops@company.com';

    -- Check null rates for current reporting period vs 90-day baseline
    WITH baseline AS (
        SELECT
            field_name,
            AVG(null_rate)    AS avg_null_rate,
            STDEV(null_rate)  AS std_null_rate
        FROM dbo.DataQualityMetrics
        WHERE reporting_date >= DATEADD(day, -90, GETDATE())
          AND reporting_date <  CAST(GETDATE() AS DATE)
        GROUP BY field_name
    ),
    current_period AS (
        SELECT field_name, null_rate
        FROM dbo.DataQualityMetrics
        WHERE reporting_date = CAST(GETDATE() AS DATE)
    ),
    anomalies AS (
        SELECT
            c.field_name,
            c.null_rate,
            b.avg_null_rate,
            b.std_null_rate,
            (c.null_rate - b.avg_null_rate) / NULLIF(b.std_null_rate, 0) AS z_score
        FROM current_period c
        JOIN baseline b ON c.field_name = b.field_name
        WHERE ABS((c.null_rate - b.avg_null_rate) / NULLIF(b.std_null_rate, 0)) > 3.0
           OR c.null_rate > 0.10  -- absolute threshold: >10% nulls always alerts
    )
    SELECT @AlertMessage = STRING_AGG(
        CONCAT(field_name, ': null_rate=', FORMAT(null_rate,'P1'),
               ' (Z=', FORMAT(z_score,'F2'), ')'),
        CHAR(13) + CHAR(10)
    )
    FROM anomalies;

    IF LEN(@AlertMessage) > 0
    BEGIN
        -- Log to anomaly table
        INSERT INTO dbo.AnomalyAlerts (alert_type, alert_message, detected_at)
        VALUES ('DATA_QUALITY_NULL_RATE', @AlertMessage, GETUTCDATE());

        -- Send via Database Mail
        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = 'DataOpsMailProfile',
            @recipients   = @RecipientEmail,
            @subject      = 'DATA QUALITY ALERT: Null Rate Anomaly Detected',
            @body         = @AlertMessage;
    END
END;
```

---

## AWS SageMaker Random Cut Forest

```python
import boto3
import sagemaker
from sagemaker import RandomCutForest

session   = sagemaker.Session()
role      = sagemaker.get_execution_role()
bucket    = "your-mbs-analytics-bucket"

# -------------------------------------------------------
# Train RCF on historical pool metrics (streaming-friendly)
# -------------------------------------------------------
rcf = RandomCutForest(
    role=role,
    instance_count=1,
    instance_type="ml.m5.xlarge",
    data_location=f"s3://{bucket}/training-data/",
    output_path=f"s3://{bucket}/model-output/",
    num_samples_per_tree=512,
    num_trees=50,
    eval_metrics=["accuracy", "precision_recall_fscore"]
)

rcf.fit(rcf.record_set(training_data.values.astype("float32")))

# Deploy for real-time or batch inference
predictor = rcf.deploy(
    initial_instance_count=1,
    instance_type="ml.m5.large",
    serializer=sagemaker.serializers.CSVSerializer(),
    deserializer=sagemaker.deserializers.JSONDeserializer()
)

# Score new monthly pool data
import json
import numpy as np

def score_pool_batch(predictor, feature_matrix: np.ndarray) -> list[float]:
    """Return anomaly scores; higher = more anomalous."""
    csv_data = "\n".join([",".join(map(str, row)) for row in feature_matrix])
    result = predictor.predict(csv_data)
    scores = [r["score"] for r in result["scores"]]
    return scores

new_month_features = pool_data[POOL_FEATURES].tail(1).values.astype("float32")
scores = score_pool_batch(predictor, new_month_features)
print(f"Anomaly score: {scores[0]:.4f}")
```

---

## Building Anomaly Detection as a Monitoring Service

```
Architecture: Event-Driven Monitoring Service

[Snowflake / SQL Server]
    │  Daily/Monthly data load
    ▼
[Anomaly Detection Layer]
    ├── Statistical (Z-score, IQR) — runs in Snowflake SQL as scheduled task
    ├── ML (Isolation Forest) — Python container, triggered by Snowflake Task
    └── Time-Series (Prophet / Snowflake ANOMALY_DETECTION) — Snowflake ML
    │
    ▼
[Alert Router]
    ├── CRITICAL → PagerDuty / Teams webhook (immediate)
    ├── HIGH     → Email to data ops team (within 1 hour)
    └── MEDIUM   → Dashboard flag + daily digest email
    │
    ▼
[Investigation Workflow]
    ├── Anomaly details surfaced in Snowsight dashboard
    ├── Cortex-generated narrative (natural language explanation)
    └── Human analyst reviews and confirms/dismisses

Snowflake Task definition:
*/
CREATE OR REPLACE TASK MBS_ANALYTICS.DAILY_ANOMALY_DETECTION
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = 'USING CRON 6 0 * * * America/New_York'
AS
    CALL MBS_ANALYTICS.RUN_ANOMALY_DETECTION_PIPELINE();
/*
```

---

## Interview Q&A

**Q1: What is the difference between a point anomaly and a contextual anomaly in the context of mortgage data? Give a concrete example of each.**

A point anomaly is a value that is globally unusual regardless of context — for example, a pool reporting a CPR of 85% when the entire universe of 30-year fixed pools has never exceeded 60%. A contextual anomaly is a value that appears normal in isolation but is anomalous given its context — for example, a CPR of 25% in January is anomalous because January is historically the lowest prepayment month (post-holiday, cold weather suppresses moves and refinances). That same 25% CPR in June would be unremarkable. Contextual anomalies require time-aware or feature-conditioned baselines, which is why a simple global Z-score fails and you need time-series models like Prophet or seasonal ARIMA.

**Q2: Walk through how Isolation Forest works and why it is well-suited for MBS pool anomaly detection.**

Isolation Forest builds an ensemble of random decision trees. For each tree, it randomly selects a feature and a split value within that feature's range, recursively partitioning the data. Anomalies — being rare and different — require fewer splits to isolate than normal points. The anomaly score is the inverse of the average path length across all trees: a short average path length means the point was isolated quickly, indicating an anomaly. It is well-suited for MBS pools because: (1) it handles multi-dimensional feature spaces (CPR, CDR, DQ buckets, WAC, pool factor) without requiring normality assumptions; (2) it scales to thousands of pools; (3) it is unsupervised, requiring no labeled historical anomalies; (4) the contamination parameter can be tuned to match the expected anomaly rate in your pool universe.

**Q3: When would you use Snowflake's built-in ANOMALY_DETECTION function versus a custom Python Isolation Forest model?**

Use Snowflake ANOMALY_DETECTION when: (1) the data already lives in Snowflake and operationalizing a Python container is overhead you want to avoid; (2) the use case is univariate or low-dimensional time series (CPR per pool); (3) you want SQL-native scheduling via Snowflake Tasks without external orchestration. Use custom Python Isolation Forest when: (1) you need multi-dimensional anomaly detection across 10+ pool features simultaneously — Snowflake ANOMALY_DETECTION is primarily time-series oriented; (2) you need tight control over model parameters, feature engineering, and scoring logic; (3) the anomaly detection is part of a larger MLOps pipeline managed in SageMaker or a CI/CD framework; (4) you need interpretability at the feature level (which features drove the anomaly score).

**Q4: How would you detect servicer remittance anomalies, and what are the common root causes?**

Remittance anomalies occur when the interest or principal remitted by the servicer to the trustee does not match what is implied by the pool's UPB, coupon, and collections. Detection approach in SQL: compute expected interest = (Beginning UPB × Note Rate / 12), compare to actual remitted interest from the trustee remittance report, flag pools where the delta exceeds a threshold (e.g., >$10,000 or >0.5% of expected). Common root causes: (1) servicer advance failures — servicer is required to advance scheduled P&I even on delinquent loans, but a stressed servicer may fail to do so; (2) float earnings disputes — servicer holds remittances beyond the contractual remittance date, earning float; (3) fee calculation errors — incorrect application of servicing fee, guaranty fee, or net WAC cap; (4) data pipeline errors — misalignment between servicer reporting date and trustee posting date. All three require different remediation paths.

**Q5: How do you set anomaly detection thresholds without labeled historical anomaly data?**

Several approaches: (1) domain-driven absolute thresholds — for data quality, a null rate >10% on a required field is always an anomaly regardless of statistics; (2) percentile-based — flag the top 1st and bottom 1st percentile as anomalies; the contamination parameter in Isolation Forest formalizes this; (3) control chart limits — compute 3σ bands from a stable baseline period (typically 12-24 months); (4) business impact thresholds — in CPR, a change of >20 percentage points month-over-month is material regardless of statistical distribution; (5) retrospective validation — once you have a candidate threshold, back-test it against historical events you know were anomalous (COVID March 2020 prepayment shock, 2022 rate spike) and adjust until the known events are captured with tolerable false positive rates.

**Q6: How would you detect geographic clustering of defaults as a fraud indicator?**

Geographic clustering analysis: (1) compute default rates by ZIP code or census tract over a rolling 12-month window; (2) compare each area's default rate to the MSA-level rate using a Z-score or, better, a spatial autocorrelation measure (Moran's I) that accounts for neighboring area rates; (3) flag ZIPs where the default rate is >3σ above the MSA mean AND the loans share common characteristics (originator, appraiser, real estate agent, or loan officer); (4) use a clustering algorithm (DBSCAN) on loan origination addresses to identify geographic concentrations; (5) overlay with the timing of defaults — loans in the cluster defaulting within 12 months of origination is a strong early payment default (EPD) fraud indicator. EPD fraud typically involves straw buyers and inflated appraisals coordinated across a small geographic area and a ring of mortgage professionals.

**Q7: Describe the DQ bucket transition matrix and how you would use it for anomaly detection.**

A DQ transition matrix tracks the probability of a loan moving between delinquency states month-over-month. States: Current, 30DPD, 60DPD, 90DPD, FC (Foreclosure), REO, Paid Off, Charged Off. The expected transition rates are computed from historical pool behavior (e.g., 2% of current loans become 30DPD each month in a stable environment). Anomaly detection: compute the actual transition rates for each reporting period and compare to the historical expected matrix using a chi-square goodness-of-fit test or simple Z-score per transition cell. An anomalous period might show 30DPD → Current (cure rate) dropping from 40% to 10% — a stress signal. Or 60DPD → 90DPD (roll rate) jumping from 60% to 85% — another stress signal. Monitoring the full matrix, not just the marginal DQ rates, provides earlier warning.

**Q8: How does Random Cut Forest differ from Isolation Forest, and when would you prefer SageMaker RCF?**

Both algorithms isolate anomalies via random partitioning. Key differences: (1) RCF is designed for streaming data — it maintains a fixed-size sketch of the data distribution and updates incrementally as new points arrive, making it ideal for real-time monitoring of remittance events or intraday price moves; (2) Isolation Forest is batch-oriented — you retrain periodically; (3) RCF's anomaly score is more interpretable for time-series context — it reflects how much the point changes the model's complexity; (4) RCF integrates natively with Amazon Kinesis for streaming pipelines. For mortgage pools reporting monthly, Isolation Forest is sufficient. For fraud detection on intraday loan status changes or real-time wire transfer monitoring, SageMaker RCF streaming is the better choice.

**Q9: How would you build anomaly detection for data quality monitoring of a daily servicer tape load into Snowflake?**

A four-layer approach: (1) schema validation — check that all expected columns are present with correct data types; any schema change is an immediate alert; (2) completeness checks — null rates per field compared to prior 30-day average; Z-score >3 triggers alert; (3) referential integrity — every loan_id in the tape must exist in the loan origination table; new loans appearing without a corresponding origination record are flagged; (4) statistical distribution checks — for numeric fields (UPB, rate, FICO), compare current tape's distribution (mean, std, p5, p95) to prior month using PSI; PSI > 0.10 flags for review. Implement these as Snowflake Tasks running immediately after each tape load, writing results to a `DATA_QUALITY_AUDIT` table. A Snowflake Alert fires a webhook to the ops team when any check fails.

**Q10: After your anomaly detection system flags a CPR spike, what is the investigation workflow you would follow?**

Step 1: Confirm the data is correct — check if the spike is in the raw servicer tape or introduced by the processing pipeline. Query the prior month's tape directly and compare record counts. Step 2: Characterize the spike — is it pool-wide or concentrated in a sub-segment? Break down CPR by loan purpose, vintage, product type, geography. Cash-out refis in low-rate vintages spiking in a falling-rate environment is expected; the same spike in a rising-rate environment is anomalous. Step 3: Check for servicer changes — servicer transfers can cause a temporary CPR spike as the incoming servicer resolves a delinquency backlog. Step 4: Cross-reference with market data — did rates move significantly? Is the spike consistent with peers? Step 5: Check Intex and Bloomberg for any deal-level news. Step 6: If unexplained, escalate to the portfolio analytics team and note the anomaly in the monthly pool surveillance report with a watch flag.

---

## Pro Tips

- Mortgage data has known seasonal patterns: CPR is higher in spring/summer (moving season) and lower in winter. Always fit anomaly baselines to seasonally adjusted data or use a model that captures seasonality (Prophet, SARIMA) to avoid false positives every January.
- Isolation Forest's `contamination` parameter should match the actual anomaly rate in your data. In mortgage pools, true anomaly months are rare (<5%). Setting contamination too high will flag normal volatility.
- In Snowflake, Snowflake Tasks can be chained: the tape load task triggers a data quality check task, which triggers an anomaly scoring task, which triggers an alert task. This creates a fully automated monitoring pipeline without external orchestration.
- When detecting DQ skip anomalies, be aware that some servicers use a "MBA method" (1=30DPD, 2=60DPD) while others use "OTS method" (30=30DPD, 60=60DPD). A schema change from one convention to the other looks like a massive DQ spike and is a data quality anomaly, not a credit anomaly.
- Keep anomaly detection models retrained quarterly. Mortgage performance characteristics shift with interest rate cycles; a model trained on 2019-2022 data has never seen a sub-3% rate environment on the way in and a 5.5%+ environment on the way out.
- For fraud detection workflows, Geographic Information System (GIS) extensions or Snowflake's H3 geospatial functions can compute loan density by hexagonal grid cell, enabling efficient geographic clustering analysis without loading data into a separate spatial database.

---

[← Back to Index](README.md)
