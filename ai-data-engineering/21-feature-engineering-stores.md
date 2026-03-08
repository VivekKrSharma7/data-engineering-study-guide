# Feature Engineering & Feature Stores

[← Back to Index](README.md)

---

## Overview

Feature engineering is the process of transforming raw data into representations that machine learning models can learn from effectively. For a senior data engineer in the secondary mortgage market, feature engineering is the bridge between your loan-level Snowflake data — origination records, payment histories, pool characteristics — and the ML models that predict prepayment risk, delinquency probability, and loan valuation.

Feature stores are the infrastructure layer that makes features reusable, consistent, and available for both model training (offline) and real-time scoring (online) without data leakage.

---

## What Is Feature Engineering

Raw data is rarely in the right form for ML:

- Categorical variables (state, loan purpose) must be encoded numerically
- Continuous variables may span orders of magnitude and need normalization
- Time-series data requires lag features, rolling statistics, and trend indicators
- Domain-specific transformations (LTV, DTI, prepayment incentive) must be computed correctly and consistently

**The gap between raw data and model-ready features is where most of the value — and most of the bugs — in ML systems lives.**

---

## Common Transformations

### Normalization and Standardization

```python
import pandas as pd
import numpy as np
from sklearn.preprocessing import StandardScaler, MinMaxScaler, RobustScaler

df = pd.read_parquet("s3://mortgage-data/loans/sample.parquet")

# StandardScaler: zero mean, unit variance — good for normally distributed features
scaler = StandardScaler()
df["note_rate_scaled"] = scaler.fit_transform(df[["note_rate"]])

# MinMaxScaler: rescale to [0, 1] — good for bounded features like LTV
minmax = MinMaxScaler()
df["ltv_scaled"] = minmax.fit_transform(df[["ltv"]])

# RobustScaler: uses median and IQR — resistant to outliers (good for income)
robust = RobustScaler()
df["income_scaled"] = robust.fit_transform(df[["borrower_income"]])
```

### Categorical Encoding

```python
import pandas as pd
from category_encoders import TargetEncoder

# One-hot encoding — use for low-cardinality categoricals (loan purpose: purchase/refi/cashout)
purpose_dummies = pd.get_dummies(df["loan_purpose"], prefix="purpose", drop_first=True)
df = pd.concat([df, purpose_dummies], axis=1)

# Target encoding — use for high-cardinality categoricals (servicer ID, ZIP code)
# Replaces category with mean of target variable — avoids high-dimensional sparse matrices
encoder = TargetEncoder(cols=["servicer_id", "zip_code"], smoothing=10)
df[["servicer_id_enc", "zip_code_enc"]] = encoder.fit_transform(
    df[["servicer_id", "zip_code"]], df["is_delinquent"]
)

# Ordinal encoding — for ordered categories (credit tier: Excellent/Good/Fair/Poor)
credit_tier_map = {"Poor": 0, "Fair": 1, "Good": 2, "Excellent": 3}
df["credit_tier_ord"] = df["credit_tier"].map(credit_tier_map)
```

### Binning

```python
# Equal-width bins — use for uniform distributions
df["fico_bucket"] = pd.cut(
    df["fico_score"],
    bins=[300, 580, 620, 660, 700, 740, 780, 850],
    labels=["<580", "580-619", "620-659", "660-699", "700-739", "740-779", "780+"],
)

# Equal-frequency (quantile) bins — use for skewed distributions like loan balance
df["balance_quartile"] = pd.qcut(
    df["current_balance"], q=4, labels=["Q1", "Q2", "Q3", "Q4"]
)
```

---

## Time-Series Features for MBS Data

Time-series features are among the most predictive for mortgage prepayment and delinquency models. Loan payment history is a sequence; capturing trends and patterns in that sequence is critical.

### Lag Features

```python
# Sort by loan and date before computing lags
df = df.sort_values(["loan_id", "report_date"])

# Lag features: value N periods ago
for lag in [1, 3, 6, 12]:
    df[f"balance_lag_{lag}m"] = df.groupby("loan_id")["current_balance"].shift(lag)
    df[f"cpr_lag_{lag}m"] = df.groupby("loan_id")["monthly_cpr"].shift(lag)

# Month-over-month change
df["balance_mom_chg"] = df["current_balance"] - df["balance_lag_1m"]
df["balance_mom_pct"] = df["balance_mom_chg"] / df["balance_lag_1m"].replace(0, np.nan)
```

### Rolling Window Statistics

```python
# Rolling window features: stats over trailing N months
for window in [3, 6, 12]:
    df[f"cpr_avg_{window}m"] = (
        df.groupby("loan_id")["monthly_cpr"]
        .transform(lambda x: x.rolling(window, min_periods=1).mean())
    )
    df[f"cpr_std_{window}m"] = (
        df.groupby("loan_id")["monthly_cpr"]
        .transform(lambda x: x.rolling(window, min_periods=2).std())
    )
    df[f"delinq_count_{window}m"] = (
        df.groupby("loan_id")["is_delinquent"]
        .transform(lambda x: x.rolling(window).sum())
    )

# Expanding window (cumulative features)
df["lifetime_max_delinquency"] = (
    df.groupby("loan_id")["delinquency_status"]
    .transform(lambda x: x.expanding().max())
)
```

### Trend Features

```python
from scipy import stats

def linear_trend(series: pd.Series) -> float:
    """Compute slope of linear regression over the series."""
    if len(series) < 3 or series.isna().all():
        return np.nan
    x = np.arange(len(series))
    slope, _, _, _, _ = stats.linregress(x, series.fillna(series.mean()))
    return slope

# 12-month trend in prepayment speed (positive = accelerating prepayment)
df["cpr_trend_12m"] = (
    df.groupby("loan_id")["monthly_cpr"]
    .transform(lambda x: x.rolling(12).apply(linear_trend, raw=False))
)
```

---

## Mortgage-Specific Feature Engineering

### LTV and CLTV Computation

```python
def compute_ltv_features(df: pd.DataFrame) -> pd.DataFrame:
    """Compute current LTV and CLTV using HPI-adjusted property values."""
    # Current LTV: accounts for principal paydown and property value change
    df["current_ltv"] = (df["current_upb"] / df["current_property_value"]) * 100

    # CLTV: includes subordinate liens
    df["cltv"] = ((df["current_upb"] + df["subordinate_balance"])
                  / df["current_property_value"]) * 100

    # LTV buckets used in agency guidelines
    df["ltv_bucket"] = pd.cut(
        df["current_ltv"],
        bins=[0, 60, 70, 80, 90, 95, 97, 105, np.inf],
        labels=["<=60", "60-70", "70-80", "80-90", "90-95", "95-97", "97-105", ">105"]
    )

    # Underwater flag (negative equity)
    df["is_underwater"] = (df["current_ltv"] > 100).astype(int)

    # Equity amount
    df["equity_usd"] = df["current_property_value"] - df["current_upb"]

    return df
```

### Debt-to-Income Ratio (DTI)

```python
def compute_dti_features(df: pd.DataFrame) -> pd.DataFrame:
    """Compute front-end and back-end DTI with risk tiers."""
    # Front-end DTI: housing expense / gross monthly income
    df["front_end_dti"] = (df["monthly_piti"] / df["gross_monthly_income"]) * 100

    # Back-end DTI: all debt obligations / gross monthly income
    df["back_end_dti"] = (df["total_monthly_obligations"] / df["gross_monthly_income"]) * 100

    # DTI risk tier (aligned with agency guidelines)
    dti_conditions = [
        df["back_end_dti"] <= 36,
        df["back_end_dti"] <= 43,
        df["back_end_dti"] <= 50,
    ]
    df["dti_tier"] = np.select(
        dti_conditions, ["low", "moderate", "elevated"], default="high"
    )

    # DTI headroom: distance from 43% threshold (negative = exceeds threshold)
    df["dti_headroom"] = 43.0 - df["back_end_dti"]

    return df
```

### Months Since Origination and Seasoning

```python
def compute_seasoning_features(df: pd.DataFrame, as_of_date: pd.Timestamp) -> pd.DataFrame:
    """Compute loan seasoning features critical for prepayment modeling."""
    df["months_since_origination"] = (
        (as_of_date.year - df["orig_date"].dt.year) * 12
        + (as_of_date.month - df["orig_date"].dt.month)
    )

    # Seasoning buckets (PSA model uses seasoning ramp for first 30 months)
    df["seasoning_bucket"] = pd.cut(
        df["months_since_origination"],
        bins=[0, 6, 12, 24, 36, 60, 120, np.inf],
        labels=["0-6m", "6-12m", "12-24m", "24-36m", "36-60m", "60-120m", "120m+"]
    )

    # Age factor for PSA (ramps from 0% to 100% PSA over first 30 months)
    df["psa_age_factor"] = df["months_since_origination"].clip(upper=30) / 30.0

    # Months remaining
    df["months_remaining"] = df["original_term"] - df["months_since_origination"]

    return df
```

### Payment History Features

```python
def compute_payment_history_features(payment_df: pd.DataFrame) -> pd.DataFrame:
    """
    Compute payment streak and history features from monthly payment records.
    payment_df: one row per (loan_id, month), with columns: loan_id, report_date, paid_on_time
    """
    payment_df = payment_df.sort_values(["loan_id", "report_date"])

    # Current on-time payment streak (consecutive months paid on time)
    def on_time_streak(series: pd.Series) -> pd.Series:
        """Compute running streak of consecutive True values, reset on False."""
        streak = pd.Series(0, index=series.index)
        for i in range(len(series)):
            if series.iloc[i]:
                streak.iloc[i] = (streak.iloc[i-1] + 1) if i > 0 else 1
            else:
                streak.iloc[i] = 0
        return streak

    payment_df["on_time_streak"] = (
        payment_df.groupby("loan_id")["paid_on_time"]
        .transform(on_time_streak)
    )

    # 12-month delinquency count
    payment_df["delinq_count_12m"] = (
        payment_df.groupby("loan_id")["paid_on_time"]
        .transform(lambda x: (~x).rolling(12, min_periods=1).sum())
    )

    # Ever 60+ days delinquent (lifetime flag)
    payment_df["ever_60_plus_delinq"] = (
        payment_df.groupby("loan_id")["delinquency_status"]
        .transform(lambda x: (x >= 2).expanding().max())
    )

    return payment_df
```

### Prepayment Incentive

```python
def compute_prepayment_incentive(df: pd.DataFrame) -> pd.DataFrame:
    """
    Compute refinance incentive — the key driver of voluntary prepayment.
    Incentive = current market rate minus loan note rate.
    Negative values mean borrower has incentive to refinance (in-the-money).
    """
    # Raw rate incentive (basis points)
    df["rate_incentive_bps"] = (df["current_market_rate"] - df["note_rate"]) * 100

    # In-the-money flag: borrower can save >= 50 bps by refinancing
    df["is_refi_itm"] = (df["rate_incentive_bps"] <= -50).astype(int)

    # Strong incentive: >= 75 bps savings
    df["is_refi_strong_itm"] = (df["rate_incentive_bps"] <= -75).astype(int)

    # Burnout factor: loans that have been in-the-money for many months
    # but haven't prepaid are "burned out" — model their prepayment as slower
    df["itm_months_count"] = (
        df.groupby("loan_id")["is_refi_itm"]
        .transform(lambda x: x.rolling(24, min_periods=1).sum())
    )
    df["burnout_factor"] = 1.0 - (df["itm_months_count"] / 24).clip(upper=1.0) * 0.5

    return df
```

---

## SQL: Computing Mortgage ML Features with Window Functions

```sql
-- ============================================================
-- Compute ML-ready features for prepayment and delinquency
-- modeling directly in Snowflake
-- ============================================================

WITH loan_monthly AS (
    SELECT
        loan_id,
        report_date,
        current_upb,
        monthly_payment,
        delinquency_days,
        market_rate_30yr,
        note_rate,
        current_property_value,
        orig_date,
        original_term,
        fico_score,
        dti,
        ltv AS orig_ltv
    FROM MORTGAGE_DW.ANALYTICS.LOAN_MONTHLY_SNAPSHOT
    WHERE report_date BETWEEN DATEADD('month', -24, CURRENT_DATE) AND CURRENT_DATE
),

seasoning AS (
    SELECT
        loan_id,
        report_date,
        current_upb,
        note_rate,
        market_rate_30yr,
        fico_score,
        dti,

        -- Months since origination
        DATEDIFF('month', orig_date, report_date)                   AS months_since_orig,

        -- Current LTV (using HPI-adjusted property value)
        ROUND(current_upb / NULLIF(current_property_value, 0) * 100, 2) AS current_ltv,

        -- Prepayment incentive (negative = in-the-money)
        ROUND((market_rate_30yr - note_rate) * 100, 1)             AS rate_incentive_bps,

        -- Delinquency flag
        CASE WHEN delinquency_days >= 30 THEN 1 ELSE 0 END         AS is_delinquent_flag,
        CASE WHEN delinquency_days >= 60 THEN 1 ELSE 0 END         AS is_60_plus_delinq
    FROM loan_monthly
),

payment_history AS (
    SELECT
        loan_id,
        report_date,
        is_delinquent_flag,

        -- Rolling delinquency counts (trailing windows)
        SUM(is_delinquent_flag)
            OVER (PARTITION BY loan_id ORDER BY report_date
                  ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)       AS delinq_count_12m,

        SUM(is_delinquent_flag)
            OVER (PARTITION BY loan_id ORDER BY report_date
                  ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)        AS delinq_count_6m,

        -- Ever delinquent (expanding window)
        MAX(is_delinquent_flag)
            OVER (PARTITION BY loan_id ORDER BY report_date
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ever_delinquent,

        -- On-time payment streak (current)
        -- Note: Snowflake does not have native streak function; use Python UDF for this
        -- Approximation: months since last delinquency
        DATEDIFF('month',
            LAST_VALUE(CASE WHEN is_delinquent_flag = 1 THEN report_date END IGNORE NULLS)
                OVER (PARTITION BY loan_id ORDER BY report_date
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
            report_date
        )                                                           AS months_since_last_delinq

    FROM seasoning
),

prepay_features AS (
    SELECT
        s.loan_id,
        s.report_date,
        s.current_upb,
        s.months_since_orig,
        s.current_ltv,
        s.rate_incentive_bps,
        s.fico_score,
        s.dti,
        p.delinq_count_12m,
        p.delinq_count_6m,
        p.ever_delinquent,
        p.months_since_last_delinq,

        -- Lagged balance (principal paydown rate)
        LAG(s.current_upb, 1) OVER (PARTITION BY s.loan_id ORDER BY s.report_date)  AS upb_lag_1m,
        LAG(s.current_upb, 3) OVER (PARTITION BY s.loan_id ORDER BY s.report_date)  AS upb_lag_3m,
        LAG(s.current_upb, 12) OVER (PARTITION BY s.loan_id ORDER BY s.report_date) AS upb_lag_12m,

        -- Rolling average of rate incentive (captures burnout)
        AVG(s.rate_incentive_bps)
            OVER (PARTITION BY s.loan_id ORDER BY s.report_date
                  ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)       AS avg_incentive_12m,

        -- Count of months in-the-money (burnout proxy)
        SUM(CASE WHEN s.rate_incentive_bps <= -50 THEN 1 ELSE 0 END)
            OVER (PARTITION BY s.loan_id ORDER BY s.report_date
                  ROWS BETWEEN 23 PRECEDING AND CURRENT ROW)       AS itm_count_24m,

        -- Seasoning bucket
        CASE
            WHEN s.months_since_orig <= 6   THEN '0-6m'
            WHEN s.months_since_orig <= 12  THEN '6-12m'
            WHEN s.months_since_orig <= 24  THEN '12-24m'
            WHEN s.months_since_orig <= 36  THEN '24-36m'
            WHEN s.months_since_orig <= 60  THEN '36-60m'
            ELSE '60m+'
        END                                                         AS seasoning_bucket

    FROM seasoning s
    JOIN payment_history p
        ON s.loan_id = p.loan_id AND s.report_date = p.report_date
)

SELECT *
FROM prepay_features
WHERE report_date = DATEADD('month', -1, DATE_TRUNC('month', CURRENT_DATE))  -- Last month snapshot
ORDER BY loan_id;
```

---

## Feature Stores

### What Is a Feature Store and Why Is It Needed

A feature store is a centralized system that manages the creation, storage, versioning, and serving of ML features. Without a feature store:

- Feature logic is duplicated between the training pipeline and the scoring pipeline, causing **training-serving skew** — the model trains on one version of a feature but scores on a slightly different computation
- Features are recomputed redundantly by every team that needs them
- There is no guarantee of **point-in-time correctness** — using data that was not actually available at the time a prediction would have been made in production

| Problem | Feature Store Solution |
|---|---|
| Training-serving skew | Single feature definition used for both |
| Data leakage | Point-in-time joins prevent future data from leaking into training |
| Duplicated computation | Shared feature registry with reuse |
| Slow online serving | Precomputed features in low-latency online store (Redis, DynamoDB) |
| Reproducibility | Feature versioning and time-travel |

### Online vs. Offline Features

**Offline store** (batch): Used for model training and batch scoring. Backed by a data warehouse or data lake (Snowflake, S3 + Parquet, Delta Lake). Supports time-travel and historical queries. Latency in seconds to minutes is acceptable.

**Online store** (real-time): Used for real-time model inference. Backed by a low-latency key-value store (Redis, DynamoDB, Cassandra). Contains only the latest feature values. Latency must be <10ms.

For mortgage origination, you need online features for real-time loan decisioning (fraud score, instant pricing) and offline features for portfolio risk modeling, capital planning, and regulatory reporting.

### Point-in-Time Correctness

Point-in-time correctness prevents data leakage in training datasets by ensuring that for each training example, only features that were available *at or before* the label timestamp are included.

**Example of leakage without point-in-time joins:**

A loan goes delinquent in March 2024. Without point-in-time correctness, your training dataset might include the March delinquency as a feature when training a model to predict delinquency as of January 2024 — the model sees the future.

```python
# WRONG: simple join — uses features regardless of when they were computed
train_df = loans.merge(features, on="loan_id")  # Features may be from AFTER the label date

# CORRECT: point-in-time join — only use features available at label_date
def point_in_time_join(
    entity_df: pd.DataFrame,       # loan_id, label_date, target
    feature_df: pd.DataFrame,      # loan_id, feature_date, feature_values
) -> pd.DataFrame:
    """
    For each row in entity_df, join the most recent feature row
    where feature_date <= label_date.
    """
    merged = entity_df.merge(feature_df, on="loan_id", how="left")
    # Keep only feature rows that were available at label time
    merged = merged[merged["feature_date"] <= merged["label_date"]]
    # Take the most recent available feature per entity
    merged = merged.sort_values("feature_date").groupby(
        ["loan_id", "label_date"]
    ).last().reset_index()
    return merged
```

---

## Feature Store Tools

### Feast (Open Source)

```python
from feast import FeatureStore, Entity, FeatureView, Field, FileSource
from feast.types import Float64, Int64, String
from datetime import timedelta

# Define entity
loan_entity = Entity(name="loan_id", join_keys=["loan_id"])

# Define data source (Snowflake or Parquet)
loan_source = FileSource(
    path="s3://mortgage-features/loan_monthly/*.parquet",
    timestamp_field="feature_date",
)

# Define feature view
loan_feature_view = FeatureView(
    name="loan_monthly_features",
    entities=[loan_entity],
    ttl=timedelta(days=90),
    schema=[
        Field(name="current_ltv", dtype=Float64),
        Field(name="rate_incentive_bps", dtype=Float64),
        Field(name="months_since_orig", dtype=Int64),
        Field(name="delinq_count_12m", dtype=Int64),
        Field(name="on_time_streak", dtype=Int64),
        Field(name="dti", dtype=Float64),
        Field(name="fico_score", dtype=Int64),
    ],
    source=loan_source,
    online=True,
)

# Materialize to online store and retrieve training data
store = FeatureStore(repo_path="./feature_repo")
store.materialize_incremental(end_date=datetime.utcnow())

# Get training features (point-in-time correct)
entity_df = pd.DataFrame({
    "loan_id": ["L001", "L002", "L003"],
    "event_timestamp": pd.to_datetime(["2024-01-31", "2024-02-29", "2024-03-31"]),
})
training_features = store.get_historical_features(
    entity_df=entity_df,
    features=["loan_monthly_features:current_ltv", "loan_monthly_features:rate_incentive_bps"],
).to_df()
```

### Snowflake Feature Store (Snowpark ML)

Snowflake's native feature store uses dynamic tables for incremental computation and integrates with Snowpark ML model registry.

```python
from snowflake.ml.feature_store import FeatureStore, Entity, FeatureView
from snowflake.snowpark import Session
import snowflake.snowpark.functions as F

session = Session.builder.configs({...}).create()

# Initialize feature store
fs = FeatureStore(
    session=session,
    database="MORTGAGE_DW",
    name="MORTGAGE_FEATURES",
    default_warehouse="COMPUTE_WH",
    creation_mode="CREATE_IF_NOT_EXIST",
)

# Define entity
loan_entity = Entity(name="LOAN", join_keys=["LOAN_ID"])
fs.register_entity(loan_entity)

# Define feature view backed by a Snowpark DataFrame
loan_df = session.table("MORTGAGE_DW.ANALYTICS.LOAN_MONTHLY_SNAPSHOT")

feature_df = loan_df.select(
    F.col("LOAN_ID"),
    F.col("REPORT_DATE"),
    (F.col("CURRENT_UPB") / F.col("CURRENT_PROPERTY_VALUE") * 100).alias("CURRENT_LTV"),
    ((F.col("MARKET_RATE_30YR") - F.col("NOTE_RATE")) * 100).alias("RATE_INCENTIVE_BPS"),
    F.col("DTI"),
    F.col("FICO_SCORE"),
)

fv = FeatureView(
    name="LOAN_MONTHLY_FV",
    entities=[loan_entity],
    feature_df=feature_df,
    timestamp_col="REPORT_DATE",
    refresh_freq="1 day",             # Backs a dynamic table
    desc="Monthly loan-level features for prepayment/delinquency models",
)

fv = fs.register_feature_view(feature_view=fv, version="1.0")

# Retrieve training dataset (point-in-time correct)
spine_df = session.createDataFrame(
    pd.DataFrame({"LOAN_ID": ["L001", "L002"], "LABEL_DATE": ["2024-01-31", "2024-02-29"]})
)

training_data = fs.retrieve_feature_values(
    spine_df=spine_df,
    features=[fv],
    spine_timestamp_col="LABEL_DATE",
    exclude_columns=["REPORT_DATE"],
)
training_data.to_pandas().head()
```

### Implementing Feature Store Logic with Snowflake Dynamic Tables

```sql
-- Dynamic table auto-refreshes when upstream tables change
-- Perfect for feature computation in Snowflake

CREATE OR REPLACE DYNAMIC TABLE MORTGAGE_DW.FEATURES.LOAN_MONTHLY_FEATURES
    TARGET_LAG = '1 day'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    loan_id,
    report_date                                                     AS feature_date,

    -- Core features
    ROUND(current_upb / NULLIF(current_property_value, 0) * 100, 2) AS current_ltv,
    ROUND((market_rate_30yr - note_rate) * 100, 1)                 AS rate_incentive_bps,
    DATEDIFF('month', orig_date, report_date)                      AS months_since_orig,
    fico_score,
    dti,

    -- Window function features
    SUM(CASE WHEN delinquency_days >= 30 THEN 1 ELSE 0 END)
        OVER (PARTITION BY loan_id ORDER BY report_date
              ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)           AS delinq_count_12m,

    AVG(current_upb)
        OVER (PARTITION BY loan_id ORDER BY report_date
              ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)            AS avg_upb_6m,

    LAG(current_upb, 1)
        OVER (PARTITION BY loan_id ORDER BY report_date)           AS upb_lag_1m,

    LAG(current_upb, 12)
        OVER (PARTITION BY loan_id ORDER BY report_date)           AS upb_lag_12m

FROM MORTGAGE_DW.ANALYTICS.LOAN_MONTHLY_SNAPSHOT;

-- Query the dynamic table like any regular table
SELECT *
FROM MORTGAGE_DW.FEATURES.LOAN_MONTHLY_FEATURES
WHERE feature_date = DATEADD('month', -1, DATE_TRUNC('month', CURRENT_DATE));
```

---

## Data Leakage: Common Mistakes and How to Avoid Them

| Leakage Type | Example | Prevention |
|---|---|---|
| **Temporal leakage** | Including March delinquency in a February prediction | Point-in-time join; filter `feature_date <= label_date` |
| **Target leakage** | Including "delinquency_resolved_date" in delinquency prediction | Remove any feature derived from the target variable |
| **Preprocessing leakage** | Fitting `StandardScaler` on full dataset before train/test split | Always fit scalers on training data only |
| **Group leakage** | Loan appears in both train and test (same borrower, different loan) | Split by borrower ID, not loan ID |
| **Look-ahead in rolling features** | Using `df.rolling(12).mean()` without excluding future rows | Use `shift(1)` before rolling; features at time T use data up to T-1 |

```python
# WRONG: scaler fit on full dataset leaks test distribution into training
from sklearn.preprocessing import StandardScaler

scaler = StandardScaler()
X_scaled = scaler.fit_transform(X)  # Leaks test statistics into training
X_train, X_test = train_test_split(X_scaled)

# CORRECT: fit only on training data
X_train, X_test = train_test_split(X)
scaler = StandardScaler()
X_train_scaled = scaler.fit_transform(X_train)   # Fit on train only
X_test_scaled = scaler.transform(X_test)          # Transform (not fit) test

# WRONG: rolling feature without shift — uses current period's data
df["delinq_rate_12m"] = df.groupby("loan_id")["is_delinquent"].transform(
    lambda x: x.rolling(12).mean()  # At time T, includes T itself
)

# CORRECT: shift by 1 period first so feature at T uses T-1 through T-12
df["delinq_rate_12m"] = df.groupby("loan_id")["is_delinquent"].transform(
    lambda x: x.shift(1).rolling(12).mean()  # At time T, uses T-1 through T-12
)
```

---

## Feature Selection

```python
import pandas as pd
import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.feature_selection import mutual_info_classif
import matplotlib.pyplot as plt

# 1. Correlation filter — remove highly correlated features
def remove_correlated_features(df: pd.DataFrame, threshold: float = 0.95) -> list:
    corr_matrix = df.corr().abs()
    upper = corr_matrix.where(np.triu(np.ones(corr_matrix.shape), k=1).astype(bool))
    to_drop = [col for col in upper.columns if any(upper[col] > threshold)]
    return to_drop

correlated = remove_correlated_features(feature_df, threshold=0.95)
print(f"Dropping {len(correlated)} correlated features: {correlated}")

# 2. Mutual information — captures non-linear relationships
mi_scores = mutual_info_classif(X_train, y_train, random_state=42)
mi_df = pd.DataFrame({"feature": feature_names, "mi_score": mi_scores})
mi_df = mi_df.sort_values("mi_score", ascending=False)

# 3. Tree-based feature importance (most reliable for tabular mortgage data)
model = GradientBoostingClassifier(n_estimators=200, random_state=42)
model.fit(X_train, y_train)

importance_df = pd.DataFrame({
    "feature": feature_names,
    "importance": model.feature_importances_,
}).sort_values("importance", ascending=False)

print(importance_df.head(20))
```

---

## Interview Q&A

**Q1: What is data leakage and why is it so dangerous in mortgage ML models?**

Data leakage occurs when information from outside the training time window is used as a feature, causing the model to appear more accurate during validation than it will be in production. In mortgage modeling, leakage is particularly dangerous because it produces models that perform brilliantly in backtesting but fail in live deployment — regulators and business stakeholders trust these inflated metrics. Common examples: including a loan's ultimate disposition (paid-in-full date) in a prepayment model, using post-origination FICO scores to predict origination-time delinquency risk, or fitting a StandardScaler on the full dataset before the train/test split (leaking test set statistics into training). The most insidious leakage is temporal: using December 2023 payment data in a model trained to make January 2023 predictions. A feature store with proper point-in-time joins is the systematic solution.

**Q2: Explain point-in-time correctness in feature stores and how you would implement it in Snowflake.**

Point-in-time correctness means that for each training example, the feature values used are exactly those that would have been available in production at the time the prediction was made — no future data is allowed to seep in. In Snowflake, I implement this as an AS-OF join pattern: given a spine table of (loan_id, label_date), join to the feature table using `WHERE feature_date <= label_date` and then take the most recent available feature row using `QUALIFY ROW_NUMBER() OVER (PARTITION BY loan_id, label_date ORDER BY feature_date DESC) = 1`. In production, I store all feature snapshots as immutable append-only records in a Snowflake table partitioned by `feature_date`. Dynamic tables make this easier — they maintain the full history of computed feature values, which can then be queried with AS-OF joins for training data generation.

**Q3: What are the most predictive features for prepayment modeling in an MBS context?**

The three dominant drivers of voluntary prepayment (refinancing) are: (1) **Refinance incentive** — the spread between the borrower's note rate and current market rates; loans that are 50+ basis points in-the-money have dramatically higher CPRs; (2) **Burnout** — pools of loans that have been in-the-money for 12+ months but haven't prepaid exhibit lower future prepayment rates, possibly due to credit impairment, property value issues, or borrower inertia; this is captured as the count of prior months the loan was in-the-money; (3) **Seasonality** — prepayment speeds peak in summer (home purchase activity) and trough in winter. Beyond these, **loan age/seasoning** (PSA ramp), **LTV** (high-LTV borrowers can't refi easily), **FICO** (credit access), and **geography** (home price appreciation rate affects equity buildup) are important. All of these can be computed directly in Snowflake using the window function SQL patterns I'd implement as dynamic tables.

**Q4: Compare Feast, Tecton, Databricks Feature Store, and Snowflake Feature Store. How do you choose?**

| | Feast | Tecton | Databricks Feature Store | Snowflake Feature Store |
|---|---|---|---|---|
| Cost | Open source | Enterprise SaaS | Included with Databricks | Included with Snowflake |
| Complexity | Medium | Low | Low | Low |
| Online store | Redis, DynamoDB, BigTable | Managed | Azure Cache, DynamoDB | Snowflake (latency higher) |
| Best for | Flexible, self-hosted | Real-time ML at scale | Spark-heavy shops | Snowflake-centric shops |

For a secondary mortgage market shop running on Snowflake with primarily batch ML (monthly model runs, daily scoring), Snowflake Feature Store is the natural fit — no additional infrastructure, data governance is inherited from Snowflake RBAC, and dynamic tables handle incremental computation elegantly. If the shop also runs real-time origination fraud scoring needing sub-10ms feature lookups, I'd add a Redis layer or evaluate Tecton for its managed online store.

**Q5: How do you handle high-cardinality categorical features like ZIP code (42,000+ values) in mortgage modeling?**

Several strategies: (1) **Target encoding** — replace each ZIP with the mean of the target variable (e.g., mean delinquency rate) computed from training data only, with smoothing to handle rare ZIPs: `(count * category_mean + global_count * global_mean) / (count + global_count)`. (2) **Embedding** — for deep learning models, learn a low-dimensional dense representation of ZIP through an embedding layer. (3) **Geographic aggregation** — roll ZIP up to MSA (Metropolitan Statistical Area) or state, which reduces cardinality from 42K to ~400 MSAs or 50 states, then use the aggregated level. (4) **Feature hashing** — hash ZIP codes into a fixed-size vector (e.g., 256 buckets); fast but loses interpretability. For a tree-based model like XGBoost predicting delinquency, target encoding of ZIP with cross-validation smoothing is the standard approach. Always compute encoding statistics from training data only, applied to test/production data separately.

**Q6: How would you design a feature pipeline for a real-time mortgage origination pricing model that needs sub-100ms latency?**

The architecture separates offline and online components: (1) **Offline pipeline** (nightly): Snowflake dynamic tables compute all batch features — borrower credit history, loan-to-value trends, servicer performance statistics, geographic home price indices. These are materialized to the offline feature store and also pushed to Redis (online store) keyed by loan_id or borrower_id. (2) **Online pipeline** (request-time): When a new loan application arrives, request-time features are computed in-process (note rate, requested LTV, DTI from the application) while pre-computed features (credit score, estimated property value) are fetched from Redis in <5ms. The feature vector is assembled and passed to the pricing model. (3) **Feature logging**: Every feature vector used for a real-time prediction is logged to Snowflake for training data accumulation and model monitoring. This logging must be async (fire-and-forget) to not add latency to the prediction path.

**Q7: Explain the PSA prepayment model and how you would compute a PSA speed feature in Snowflake.**

PSA (Public Securities Association) is a benchmark prepayment model that assumes CPR ramps linearly from 0% to 6% over the first 30 months of a loan's life, then remains constant at 6% CPR. A pool trading at "150 PSA" is prepaying at 1.5× the PSA schedule — so in month 30+, it's running at 9% CPR. The "PSA speed" feature captures how fast a pool is prepaying relative to this benchmark. In Snowflake, I compute it as: `(actual_1m_cpr / psa_benchmark_cpr) * 100` where `psa_benchmark_cpr = MIN(months_since_orig / 30.0, 1.0) * 6.0`. This feature is critical for MBS relative value analysis — a pool at 80 PSA when the model expects 120 PSA is potentially undervalued (slower prepayment = longer duration = higher price sensitivity to rates). I store this as a dynamic table feature updated daily.

**Q8: How do you detect and fix training-serving skew in a deployed mortgage model?**

Training-serving skew occurs when the feature computation at training time differs from the computation at serving time — even subtly. Detection: (1) Log all feature vectors at serving time alongside model predictions and entity IDs. (2) Periodically join serving-time features back to the offline feature store and compare distributions using PSI (Population Stability Index) and KL divergence. A PSI > 0.2 signals significant skew for any feature. (3) Monitor model score distributions — if the model's predicted delinquency probability distribution shifts without a corresponding shift in actual delinquency rates, skew is likely. Fixing it: the root cause is almost always duplicate feature logic (SQL in the training pipeline, Python in the serving pipeline). The fix is to use the feature store as the single source of truth — the same feature definition is used for both training data generation and serving, eliminating divergence by design.

**Q9: What rolling window size would you use for prepayment and delinquency features, and why?**

It depends on the prediction horizon and the economic signal: for **prepayment features**, a 3-month rolling CPR captures recent velocity changes (the model needs to react to rate movements quickly), while a 12-month average captures structural pool behavior and burnout. I'd include both as separate features and let the model learn their relative importance. For **delinquency features**, 6-month delinquency count captures recent stress better than 12-month for short-term models, but 12-month (covering a full economic cycle of seasonal effects) is better for 12-month-ahead predictions. For **market rate features** (prepayment incentive), I'd use 1-month spot, 3-month average, and a 24-month count of in-the-money months to capture burnout. In general, for mortgage data I always include multiple window sizes as separate features rather than selecting one — the model typically benefits from seeing both short-term and long-term signals.

**Q10: How would you use Snowflake Dynamic Tables to implement a feature store for a mortgage portfolio risk model?**

Dynamic tables are perfect for feature stores because they: (1) automatically refresh when upstream source tables change, (2) support incremental processing (only recompute rows that changed), (3) maintain the full history needed for point-in-time training data generation, and (4) inherit Snowflake's RBAC, time-travel, and governance. My implementation: create a base dynamic table at `TARGET_LAG = '1 hour'` computing raw features (LTV, DTI, rate incentive) from source tables. Create a second-tier dynamic table computing window function features (rolling delinquency counts, lagged balances) from the first-tier table at `TARGET_LAG = '1 day'`. Use a third-tier dynamic table for the serving layer that materializes the latest feature vector per loan, optimized for key-value lookups. For training data generation, query the second-tier history table with a point-in-time join. For model monitoring, compare the feature distribution in the serving layer against the training data distribution using Snowflake's built-in `APPROX_PERCENTILE` and statistical functions scheduled as a Snowflake task.

---

## Pro Tips

- Store feature computation SQL as Snowflake dynamic tables or views with version numbers (`LOAN_FEATURES_V3`). When you change a feature definition, create a new version rather than modifying in place — this preserves reproducibility for previously trained models.
- Always compute LTV using HPI-adjusted property values, not the original appraised value. A loan originated in 2021 at 80% LTV may now be at 65% LTV due to home price appreciation — or 95% LTV in a declining market. Static LTV is nearly useless for current risk assessment.
- For target encoding of high-cardinality features, use cross-fold encoding during training (compute target stats from out-of-fold data) to prevent overfitting. `category_encoders.TargetEncoder` supports this natively.
- When computing rolling window features in Snowflake, add `MIN_PERIODS` logic explicitly: `CASE WHEN COUNT(*) OVER (...) >= 3 THEN AVG(...) OVER (...) ELSE NULL END`. Without it, rolling averages over 1-2 observations are noisy and mislead the model.
- The `months_since_last_delinquency` feature consistently ranks in the top 5 features for 90-day delinquency prediction models. Loans that were delinquent 6-18 months ago but cured are significantly more likely to re-delinquent than loans with no delinquency history.
- Document every feature with its economic rationale, computation logic, expected range, and known data quality issues in your feature store's metadata catalog. A feature named `delinq_count_12m` without documentation is a liability — future engineers will recompute it differently.
- For Snowflake Feature Store, set `REFRESH_FREQ` on dynamic tables to align with your data SLA, not just "1 day" by default. A loan that goes delinquent on the 1st of the month should be reflected in risk scores by the 2nd — not 24 hours later.
