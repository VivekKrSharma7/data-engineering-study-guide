# AI for MBS Valuation & Pricing Analytics

[Back to Index](README.md)

---

## Overview

Mortgage-Backed Securities (MBS) pricing has historically depended on complex mathematical models — OAS, Z-spread, duration, and convexity — computed using Monte Carlo simulations and term structure models. These approaches are theoretically rigorous but computationally expensive, slow to reprice at scale, and brittle when market regimes shift unexpectedly.

Machine learning changes this calculus. For a senior data engineer in the US secondary mortgage market, the opportunity is to build data pipelines that feed ML models capable of predicting OAS, Z-spread, and price with sub-second latency at pool or even loan level — something no traditional model can do without hours of simulation.

This file covers the architecture, features, models, and code patterns needed to build and operate AI-driven MBS pricing and valuation systems.

---

## Key Concepts

| Concept | Description |
|---|---|
| OAS (Option-Adjusted Spread) | Spread over risk-free curve after removing embedded prepayment optionality |
| Z-Spread | Constant spread added to zero-coupon curve to match market price |
| Duration / Convexity | Price sensitivity to rate changes (first / second order) |
| WAC / WAM / WALA | Weighted Avg Coupon, Maturity, Loan Age — core pool descriptors |
| PSA / CPR | Prepayment speed benchmarks (Public Securities Association / Conditional Prepayment Rate) |
| AVM | Automated Valuation Model — ML-based property valuation |
| Intex CDI | Industry-standard cashflow engine for structured products |
| MBS Basis | Spread between MBS yield and equivalent Treasury yield |
| Current Coupon | Coupon on a par-priced MBS — key market reference |

---

## Traditional MBS Pricing: A Recap

Understanding what ML is replacing (or augmenting) is essential.

**Z-Spread** is the simplest: find the constant spread `s` such that:

```
Price = Σ [ CF_t / (1 + z_t + s)^t ]
```

**OAS** strips out the prepayment option. It uses a model (typically Hull-White or CIR) to simulate thousands of interest rate paths, apply a prepayment model on each path, compute cashflows, discount them, and find the spread that equates present value to market price:

```
Price = (1/N) * Σ_paths [ Σ_t CF_t(path) / discount_factor_t(path, OAS) ]
```

This is expensive. Pricing a single pool takes seconds; pricing an entire portfolio of 50,000 pools takes hours.

**Duration** (modified) measures price sensitivity:
```
Duration = -(1/P) * dP/dy
```

**Convexity** captures the nonlinearity:
```
Convexity = (1/P) * d²P/dy²
```

MBS exhibit negative convexity in certain rate environments due to prepayment optionality — this is a critical risk characteristic.

---

## ML for MBS Pricing

### Why ML Works Here

MBS pricing via OAS is itself a function — a deterministic (if noisy) mapping from features to a price. ML learns this function from historical data. Given enough labeled examples (pool characteristics + market conditions + computed OAS), a gradient-boosted tree or neural network can approximate OAS pricing with high fidelity at microsecond latency.

### Modeling Approaches

| Approach | Use Case | Pros | Cons |
|---|---|---|---|
| XGBoost / LightGBM | OAS / Z-spread prediction | Fast, interpretable, handles missing data | Extrapolation risk |
| Random Forest | Price range estimation | Uncertainty via tree variance | Slower inference |
| Feed-forward Neural Net | Complex nonlinear OAS surfaces | High capacity | Needs more data, less interpretable |
| LSTM / Transformer | Time-series prepayment forecasting | Captures temporal patterns | Complex to train |
| Gaussian Process | Price with uncertainty bands | Native confidence intervals | Doesn't scale to large feature sets |

---

## Feature Engineering for MBS Pricing Models

### Pool Characteristics

```python
pool_features = [
    "wac",              # Weighted Average Coupon
    "wam",              # Weighted Average Maturity (months remaining)
    "wala",             # Weighted Average Loan Age
    "pool_size",        # UPB (Unpaid Principal Balance)
    "loan_count",
    "avg_fico",         # Average borrower credit score
    "avg_ltv",          # Average loan-to-value ratio
    "avg_dti",          # Average debt-to-income ratio
    "dq_30",            # 30-day delinquency rate
    "dq_60",            # 60-day delinquency rate
    "geo_concentration", # HHI of state concentration
    "property_type_sfr_pct",  # % single-family
    "occupancy_primary_pct",  # % primary residence
    "refi_pct",         # % refinance loans
    "cash_out_pct",     # % cash-out refi
]
```

### Prepayment History Features

```python
prepay_features = [
    "cpr_1m",           # CPR last 1 month
    "cpr_3m",           # CPR 3-month rolling avg
    "cpr_6m",           # CPR 6-month rolling avg
    "cpr_12m",          # CPR 12-month rolling avg
    "cpr_vol_3m",       # CPR volatility (std dev 3m)
    "burnout_ratio",    # Refi incentive exhaustion proxy
    "smm_current",      # Single Monthly Mortality rate
]
```

### Market / Macro Features

```python
market_features = [
    "current_coupon",       # Par MBS coupon
    "mbs_basis",            # MBS vs Treasury spread
    "swap_2y",              # 2yr swap rate
    "swap_5y",              # 5yr swap rate
    "swap_10y",             # 10yr swap rate
    "swap_30y",             # 30yr swap rate
    "yield_curve_slope",    # 10y - 2y spread
    "yield_curve_curvature",# 2s5s10s butterfly
    "swaption_vol_1y10y",   # Implied vol (1yr option on 10yr swap)
    "swaption_vol_3m10y",   # Short-dated vol
    "move_index",           # Bond market volatility index
    "vix",                  # Equity vol (risk appetite proxy)
    "refi_index",           # MBA Refinance Application Index
    "homebuilder_sentiment",
]
```

### Derived / Interaction Features

```python
derived_features = [
    "refi_incentive",       # current_coupon - wac (positive = in-the-money)
    "duration_bucket",      # categorical bucketing of estimated duration
    "wac_minus_cc",         # pool coupon vs current coupon
    "age_season_interaction", # wala * month_of_year (seasonality)
    "ltv_fico_score",       # combined credit risk signal
]
```

---

## Interest Rate Model Integration

Hull-White and CIR models require calibration to current market data (swaption vol surface). ML can accelerate this:

- **Surrogate calibration**: Train a neural net to map swaption vol surface inputs to calibrated model parameters (mean reversion speed, vol of vol). This replaces iterative optimization.
- **Direct path generation**: Use a generative model (VAE or normalizing flow) to produce interest rate scenarios that match the vol surface, bypassing the analytic model entirely.

Example calibration mapping:
```
Input:  swaption vol surface (10 x 10 grid of expiry x tenor) → 100 features
Output: Hull-White (a, σ) parameters
Model:  MLP with 3 hidden layers (256-128-64)
```

---

## Neural Network Architecture for OAS Prediction

```python
import torch
import torch.nn as nn

class OASPredictionNet(nn.Module):
    """
    Feed-forward network for OAS prediction from pool + market features.
    Designed for MBS pools; outputs OAS in basis points.
    """
    def __init__(self, input_dim: int, dropout_rate: float = 0.15):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(input_dim, 256),
            nn.BatchNorm1d(256),
            nn.ReLU(),
            nn.Dropout(dropout_rate),

            nn.Linear(256, 128),
            nn.BatchNorm1d(128),
            nn.ReLU(),
            nn.Dropout(dropout_rate),

            nn.Linear(128, 64),
            nn.ReLU(),

            nn.Linear(64, 1)   # OAS output in bps
        )

    def forward(self, x):
        return self.net(x).squeeze(-1)
```

---

## XGBoost OAS Prediction: End-to-End Pipeline

```python
import pandas as pd
import numpy as np
from xgboost import XGBRegressor
from sklearn.model_selection import TimeSeriesSplit
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import mean_absolute_error, r2_score
from sklearn.pipeline import Pipeline
import shap
import joblib

# ── 1. Load data from Snowflake ──────────────────────────────────────────────
# Assumes you have a Snowflake connector returning a DataFrame
# query pulls labeled OAS observations: pool features + market features + OAS
def load_mbs_training_data(conn) -> pd.DataFrame:
    query = """
        SELECT
            p.pool_id,
            p.as_of_date,
            -- Pool characteristics
            p.wac, p.wam, p.wala, p.pool_upb,
            p.avg_fico, p.avg_ltv, p.avg_dti,
            p.dq_30_pct, p.dq_60_pct,
            p.refi_pct, p.cash_out_pct,
            p.geo_hhi,
            -- Prepayment history
            p.cpr_1m, p.cpr_3m, p.cpr_6m, p.cpr_12m,
            p.cpr_vol_3m, p.smm_current,
            -- Market features (joined by date)
            m.current_coupon, m.mbs_basis,
            m.swap_2y, m.swap_5y, m.swap_10y, m.swap_30y,
            m.yield_curve_slope, m.swaption_vol_1y10y,
            m.move_index, m.refi_index,
            -- Derived
            (m.current_coupon - p.wac) AS refi_incentive,
            -- Label
            p.oas_bps AS target_oas
        FROM mbs_pool_daily p
        JOIN market_rates_daily m ON p.as_of_date = m.rate_date
        WHERE p.as_of_date >= '2018-01-01'
          AND p.oas_bps IS NOT NULL
          AND p.pool_upb > 1000000   -- filter tiny pools
        ORDER BY p.as_of_date
    """
    return pd.read_sql(query, conn)

# ── 2. Feature preparation ────────────────────────────────────────────────────
FEATURE_COLS = [
    "wac", "wam", "wala", "pool_upb",
    "avg_fico", "avg_ltv", "avg_dti",
    "dq_30_pct", "dq_60_pct", "refi_pct", "cash_out_pct", "geo_hhi",
    "cpr_1m", "cpr_3m", "cpr_6m", "cpr_12m", "cpr_vol_3m", "smm_current",
    "current_coupon", "mbs_basis",
    "swap_2y", "swap_5y", "swap_10y", "swap_30y",
    "yield_curve_slope", "swaption_vol_1y10y",
    "move_index", "refi_index", "refi_incentive",
]
TARGET_COL = "target_oas"

def prepare_features(df: pd.DataFrame):
    df = df.copy()
    df["as_of_date"] = pd.to_datetime(df["as_of_date"])
    df = df.sort_values("as_of_date")

    # Log-transform skewed features
    for col in ["pool_upb", "cpr_vol_3m"]:
        df[col] = np.log1p(df[col].clip(lower=0))

    # Clip outliers at 1/99 percentile per feature
    for col in FEATURE_COLS:
        lo, hi = df[col].quantile(0.01), df[col].quantile(0.99)
        df[col] = df[col].clip(lo, hi)

    X = df[FEATURE_COLS].fillna(df[FEATURE_COLS].median())
    y = df[TARGET_COL]
    dates = df["as_of_date"]
    return X, y, dates

# ── 3. Train with time-series cross-validation ───────────────────────────────
def train_oas_model(df: pd.DataFrame):
    X, y, dates = prepare_features(df)

    model = XGBRegressor(
        n_estimators=800,
        learning_rate=0.05,
        max_depth=6,
        subsample=0.8,
        colsample_bytree=0.8,
        min_child_weight=5,
        reg_alpha=0.1,
        reg_lambda=1.0,
        tree_method="hist",    # fast histogram method
        random_state=42,
        n_jobs=-1,
    )

    tscv = TimeSeriesSplit(n_splits=5, gap=30)  # 30-day gap prevents leakage
    fold_metrics = []

    for fold, (train_idx, val_idx) in enumerate(tscv.split(X)):
        X_train, X_val = X.iloc[train_idx], X.iloc[val_idx]
        y_train, y_val = y.iloc[train_idx], y.iloc[val_idx]

        model.fit(
            X_train, y_train,
            eval_set=[(X_val, y_val)],
            verbose=False,
        )

        preds = model.predict(X_val)
        mae = mean_absolute_error(y_val, preds)
        r2 = r2_score(y_val, preds)
        fold_metrics.append({"fold": fold + 1, "mae_bps": mae, "r2": r2})
        print(f"  Fold {fold+1}: MAE={mae:.1f} bps, R2={r2:.4f}")

    # Final fit on all data
    model.fit(X, y)
    return model, fold_metrics

# ── 4. SHAP Explainability ────────────────────────────────────────────────────
def explain_predictions(model, X_sample: pd.DataFrame):
    explainer = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(X_sample)

    # Summary plot (run in notebook)
    shap.summary_plot(shap_values, X_sample, feature_names=FEATURE_COLS)

    # Per-prediction explanation
    shap.waterfall_plot(
        shap.Explanation(
            values=shap_values[0],
            base_values=explainer.expected_value,
            data=X_sample.iloc[0],
            feature_names=FEATURE_COLS,
        )
    )
    return shap_values

# ── 5. Uncertainty quantification via quantile regression ────────────────────
def train_quantile_models(df: pd.DataFrame, quantiles=(0.10, 0.50, 0.90)):
    """Train separate XGBoost models for lower/median/upper OAS bounds."""
    X, y, _ = prepare_features(df)
    models = {}
    for q in quantiles:
        m = XGBRegressor(
            objective="reg:quantileerror",
            quantile_alpha=q,
            n_estimators=600,
            learning_rate=0.05,
            max_depth=5,
            random_state=42,
        )
        m.fit(X, y)
        models[q] = m
        print(f"  Trained q={q} model")
    return models

def predict_with_intervals(models: dict, X_new: pd.DataFrame) -> pd.DataFrame:
    results = pd.DataFrame()
    results["oas_p10"] = models[0.10].predict(X_new)
    results["oas_median"] = models[0.50].predict(X_new)
    results["oas_p90"] = models[0.90].predict(X_new)
    results["oas_interval_width"] = results["oas_p90"] - results["oas_p10"]
    return results
```

---

## Collateral Valuation: Automated Valuation Models (AVM)

AVM models estimate property value without a full appraisal. They are critical for:
- Pricing new MBS pools (estimating current LTV)
- Monitoring existing collateral (mark-to-market LTV)
- Identifying properties at default risk with underwater LTVs

**Key AVM feature categories:**

| Category | Examples |
|---|---|
| Property characteristics | Sq footage, beds/baths, year built, lot size, garage |
| Location | ZIP, census tract, school district rating, walkability |
| Comparable sales | Median sale price (1/3/6/12m), $/sqft comps |
| Market conditions | Days on market, list-to-sale ratio, inventory levels |
| Macro | Interest rates, unemployment rate, local HPI |
| Alternative data | Permit activity, satellite property condition scores |

**Snowflake query for AVM feature assembly:**

```sql
-- Assemble AVM features for active collateral pool
SELECT
    l.loan_id,
    l.property_zip,
    l.original_appraisal_value,
    l.original_appraisal_date,
    -- Current property characteristics
    p.sq_footage,
    p.bedrooms,
    p.bathrooms,
    p.year_built,
    p.lot_size_sqft,
    -- Recent comparable sales (last 6 months, same ZIP)
    c.median_sale_price_6m,
    c.median_price_per_sqft_6m,
    c.comp_count_6m,
    c.median_dom_6m,        -- days on market
    -- Local HPI
    h.hpi_current,
    h.hpi_yoy_pct,
    h.hpi_at_origination,
    -- Estimated current value from HPI indexing (baseline)
    l.original_appraisal_value * (h.hpi_current / NULLIF(h.hpi_at_origination, 0))
        AS hpi_indexed_value,
    -- Current estimated LTV
    l.current_upb / NULLIF(
        l.original_appraisal_value * (h.hpi_current / NULLIF(h.hpi_at_origination, 0)),
        0
    ) AS estimated_current_ltv
FROM active_loans l
JOIN property_attributes p ON l.property_id = p.property_id
JOIN zip_comp_sales_summary c ON l.property_zip = c.zip_code
    AND c.summary_month = DATE_TRUNC('month', CURRENT_DATE)
JOIN hpi_index h ON l.property_zip = h.zip_code
    AND h.hpi_date = DATE_TRUNC('month', CURRENT_DATE)
```

---

## Alternative Data for MBS Analytics

| Data Source | Application | Vendor Examples |
|---|---|---|
| Satellite imagery | Property condition scoring, vacancy detection | Orbital Insight, Ursa |
| Mobile device data | Neighborhood activity, foot traffic trends | SafeGraph, Veraset |
| Web scraping / Zillow | Listing prices, rental rates | Zillow API, Redfin |
| Permit data | Renovation activity, new construction pressure | BuildZoom, CoreLogic |
| Social media sentiment | Local market sentiment | Various NLP pipelines |
| Climate / flood data | Property risk scoring | First Street Foundation, FEMA |

These signals augment traditional collateral valuation and help detect emerging credit risk in geographic concentrations before it shows up in delinquency data.

---

## Intex CDI Integration

Intex is the industry standard cashflow engine for agency and non-agency MBS. For ML pipelines:

- **Use Intex cashflows as labels**: Run Intex at multiple prepayment / default speed scenarios to generate OAS training data at scale.
- **Use Intex cashflow profiles as features**: The shape of the cashflow waterfall (prepay-weighted duration, cashflow timing vector) is a rich feature for pricing models.
- **Hybrid approach**: ML predicts an adjustment to the Intex-computed OAS rather than predicting OAS directly — this keeps the model anchored to analytic truth and corrects for regime shifts.

---

## Building a Pricing Model in Snowflake

```sql
-- Store pool features + market features in Snowflake
-- Use Snowpark ML for in-database model serving

-- 1. Feature store table
CREATE OR REPLACE TABLE mbs_pricing_features (
    pool_id         VARCHAR(20),
    as_of_date      DATE,
    wac             FLOAT,
    wam             FLOAT,
    wala            FLOAT,
    avg_fico        FLOAT,
    avg_ltv         FLOAT,
    cpr_3m          FLOAT,
    refi_incentive  FLOAT,
    current_coupon  FLOAT,
    swap_10y        FLOAT,
    yield_curve_slope FLOAT,
    swaption_vol_1y10y FLOAT,
    -- Predicted values (populated by ML pipeline)
    ml_oas_pred     FLOAT,
    ml_oas_p10      FLOAT,
    ml_oas_p90      FLOAT,
    model_version   VARCHAR(20),
    scored_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 2. Snowpark Python UDF for model scoring (deployed separately)
-- Once model is registered in Snowflake Model Registry:
SELECT
    pool_id,
    as_of_date,
    mbs_pricing_model!PREDICT(
        wac, wam, wala, avg_fico, avg_ltv,
        cpr_3m, refi_incentive, current_coupon,
        swap_10y, yield_curve_slope, swaption_vol_1y10y
    ) AS oas_prediction
FROM mbs_pricing_features
WHERE as_of_date = CURRENT_DATE;
```

---

## Real-Time Repricing with Streaming Data

For intraday MBS pricing as swap rates and MBS basis move:

```
Market Rate Feed (Bloomberg/LSEG)
    → Kafka topic: market_rates_tick
    → Flink / Spark Structured Streaming
    → Feature update: recompute refi_incentive, yield_curve_slope
    → Model inference (ONNX runtime or Snowflake UDF)
    → Output: updated OAS / price estimates
    → Snowflake real-time ingest (Snowpipe Streaming)
    → Dashboard / risk system refresh
```

Latency target: under 500ms from rate tick to updated pool OAS in dashboard.

---

## Interview Q&A

**Q1: What is OAS and why is it preferred over Z-spread for MBS analysis?**

A: Z-spread is a static measure — it finds the constant spread over the spot curve that equates cashflows to price, but it treats prepayment cashflows as fixed. OAS goes further: it simulates thousands of interest rate paths using a term structure model (Hull-White, etc.), applies a prepayment model to each path to generate path-specific cashflows, then finds the spread that equates the average discounted value across all paths to market price. OAS "removes" the value of the prepayment option, leaving you with pure credit/liquidity spread. For agency MBS (no credit risk), OAS is primarily a relative value measure — a high OAS means cheapness versus the rate model; a low or negative OAS means richness. Z-spread is useful for quick screening but misleading for comparing securities with different embedded optionality.

**Q2: How would you construct a training dataset for an ML OAS predictor?**

A: The label is the OAS computed by a traditional pricing model (Intex, Bloomberg, or your internal model) on historical dates. For each pool-date observation, I'd join pool-level characteristics (WAC, WAM, WALA, FICO, LTV, CPR history) with market conditions on that date (swap rates, vol surface, MBS basis, current coupon). Critical considerations: (1) temporal ordering — always use TimeSeriesSplit, never random split, to prevent future data leakage; (2) regime coverage — ensure training data spans at least one full rate cycle, including rising and falling rate environments; (3) label quality — OAS from different models may differ; document which model generated labels; (4) survivorship bias — include pools that were subsequently called/prepaid, not just survivors.

**Q3: What features drive OAS prediction the most and why?**

A: Based on SHAP analysis in production models: (1) **Refi incentive** (WAC minus current coupon) — this is the primary driver of prepayment risk, which is the largest component of OAS; (2) **WALA** — loan age determines burnout and peak prepayment windows; (3) **Swaption volatility** — higher vol means the embedded prepayment option is worth more, depressing OAS; (4) **MBS basis** — overall supply/demand for MBS vs Treasuries; (5) **CPR history** — a pool that has already prepaid heavily (burnout) has lower future prepayment risk. Pool credit characteristics (FICO, LTV) matter more for non-agency MBS where credit risk contributes to OAS.

**Q4: How do you handle the negative convexity problem in an ML pricing model?**

A: Negative convexity means price sensitivity is asymmetric — MBS underperform in both rising and falling rate environments due to prepayment optionality. ML models can capture this if (1) the training data includes observations across different rate regimes so the model sees both extension and prepayment scenarios, (2) you include swaption volatility as a feature (the market's price for optionality), and (3) you add interaction features between refi incentive and rate volatility. Additionally, quantile regression or conformal prediction generates wider uncertainty bands in high-vol environments, which implicitly reflects the convexity risk.

**Q5: How would you integrate Bloomberg data as features in a Snowflake pipeline?**

A: Bloomberg provides a B-PIPE or BLPAPI feed. For a Snowflake pipeline: (1) Use a Python process (AWS Lambda or ADF activity) to pull daily market data via BLPAPI for key tickers (swap rates, MBS current coupon, swaption vols, MBS basis); (2) Load raw data into a Snowflake staging table via Snowpipe; (3) Transform via dbt models into a `market_rates_daily` dimension table with clean column names; (4) Join to pool feature table by date. For real-time use, Bloomberg's streaming API feeds Kafka which feeds Snowpipe Streaming. Key fields: USSW10 (10yr swap), MTGEFNCL Index (current coupon), MOVE Index, swaption vol matrix.

**Q6: What is an AVM and how accurate are they for MBS collateral monitoring?**

A: An Automated Valuation Model is an ML model that estimates property market value from property characteristics, location features, comparable sales data, and macroeconomic inputs — without a physical appraisal. For MBS collateral monitoring, AVM accuracy is typically reported as (1) median absolute percentage error (MAPE) against subsequent actual sales, typically 5-8% for well-covered markets; (2) "hit rate within 10%" — what percent of estimates are within 10% of actual sale price, typically 70-80%. AVMs are less accurate for unique properties, rural areas with few comps, and rapidly shifting markets. For MBS risk management, AVM-estimated LTVs flag pools where collateral values have deteriorated, informing credit reserve calculations and loss severities.

**Q7: How would you build real-time MBS repricing in Snowflake?**

A: Architecture: Bloomberg rate tick → Kafka → Spark Structured Streaming consumer → recompute features (refi incentive, yield curve slope) → ONNX model inference (model exported from XGBoost) → Snowpipe Streaming load into `mbs_realtime_pricing` table → Snowflake Dynamic Table refreshes risk aggregates. The ML model runs outside Snowflake for latency reasons (ONNX runtime in the Spark job); results are pushed into Snowflake. For less latency-sensitive use cases, Snowflake UDFs (Snowpark Python) can host the model directly. Key design decision: ONNX lets you train in Python, export once, and serve in any environment with sub-millisecond inference.

**Q8: How do you quantify uncertainty in ML price predictions and why does it matter for traders?**

A: Traders need to know not just the predicted OAS but how much to trust it. Methods: (1) **Quantile regression** — train separate models for 10th, 50th, 90th percentile OAS; the interval width signals model uncertainty; (2) **Conformal prediction** — a distribution-free method that guarantees coverage; valid uncertainty sets regardless of model type; (3) **Dropout-based uncertainty** (MC Dropout) — run inference N times with dropout active; use variance as uncertainty; (4) **Bootstrap ensembles** — train N models on bootstrap samples; prediction variance is uncertainty. For a trader, a pool with OAS pred = 45 bps ± 3 bps is actionable; one with OAS pred = 45 bps ± 25 bps should be priced with a manual review flag. In a Snowflake pipeline, store p10/p50/p90 alongside point predictions.

**Q9: What is the MBS basis and how do you use it as a feature?**

A: The MBS basis is the spread between the MBS current coupon yield and an equivalent Treasury (or swap) yield. It reflects supply/demand dynamics for MBS as an asset class — when the Fed is buying MBS (QE), basis tightens; when the Fed is rolling off MBS (QT), basis widens. In a pricing model, MBS basis is a market-level input that shifts the entire OAS surface. A wider basis environment means higher OAS for all pools. Including it as a feature allows the model to distinguish between an OAS change driven by pool-specific prepayment behavior versus a market-wide repricing event. It is one of the most important market-level features for OAS prediction accuracy.

**Q10: How do you prevent leakage when training a time-series MBS pricing model?**

A: Several leakage vectors exist: (1) **Temporal leakage** — using future OAS or future prepayment data as features; prevented by strict TimeSeriesSplit with a gap period between train and validation; (2) **Feature construction leakage** — computing rolling averages or normalizations on the full dataset before splitting; prevented by computing statistics only on training data and applying to validation/test using fit-transform pattern; (3) **Label leakage** — using the OAS from the Bloomberg pricing function that already incorporates the "current" market price which itself encodes the OAS; prevented by ensuring training labels are computed at market close T and features are sourced from T-1 close where real-time features would introduce look-ahead; (4) **Pool survivorship leakage** — excluding pools that prepaid or were called; prevented by including terminal pool observations.

---

## Pro Tips

- **Hybrid ML + analytic model**: Never replace the analytic OAS model entirely. Use ML as a fast approximation, flag predictions that diverge materially from the analytic model for manual review.
- **Regime tagging**: Add a market regime indicator (low vol / high vol / stress) as a categorical feature. Models trained on one regime can extrapolate poorly to another; the regime tag helps.
- **Intex as ground truth**: Use Intex-computed OAS as labels rather than Bloomberg. Intex is the industry standard for structured products and your trading desk likely marks to Intex.
- **Log-transform CPR features**: CPR volatility and pool size are right-skewed. Log-transform before training improves XGBoost performance measurably.
- **Monitor feature drift, not just model error**: If swap rates move outside the training range, flag the predictions automatically — the model has no data to interpolate from.
- **Version your models alongside market regimes**: A model trained through 2022 (rate hikes) will behave differently in a 2025 rate-cutting cycle. Keep models tagged with the rate regime of their training window.
