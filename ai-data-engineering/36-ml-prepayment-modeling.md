# ML for Prepayment Modeling & Prediction

[Back to Index](README.md)

---

## Overview

Prepayment modeling is one of the most consequential analytical challenges in the secondary mortgage market. Every basis point of CPR error translates directly into mispriced mortgage-backed securities, incorrect hedge ratios, and misallocated capital. Traditional models (PSA, CPR curves) served the market well when rates were stable and borrower behavior was predictable. Post-2008, post-COVID rate volatility has exposed the brittleness of static model assumptions. Machine learning — particularly gradient boosting and survival analysis — captures nonlinear borrower behavior, burnout dynamics, and regime changes that rule-based models miss. This guide covers the full ML prepayment pipeline: features, models, validation, and production scoring in Snowflake and SQL Server.

---

## Key Concepts

| Concept | Description |
|---|---|
| CPR | Conditional Prepayment Rate — annualized prepayment speed as % of beginning balance |
| SMM | Single Monthly Mortality — monthly prepayment rate; CPR = 1 - (1-SMM)^12 |
| PSA | Public Securities Association standard prepayment curve (100 PSA = ramp to 6% CPR) |
| Rate Incentive | Note rate minus current refinance rate — primary driver of refinancing |
| Burnout | Reduction in refinancing propensity after prolonged low-rate exposure |
| Seasoning | Loan age effect — prepayments ramp up over first ~30 months |
| WALA | Weighted Average Loan Age — pool-level seasoning metric |
| Competing Risks | Prepayment, default, and curtailment as simultaneous hazard events |
| Survival Analysis | Time-to-event modeling framework for mortgage termination |
| PSI | Population Stability Index — monitor input distribution shifts |

---

## Traditional Prepayment Models — Limitations

### PSA (Public Securities Association)

The PSA benchmark assumes prepayment rates ramp linearly from 0% CPR at origination to 6% CPR at month 30, then remain flat. 100 PSA = this base curve; 200 PSA = twice the speed.

```
Month    CPR (100 PSA)     CPR (200 PSA)
1        0.20%             0.40%
12       2.40%             4.80%
30+      6.00%             12.00%
```

**Limitations**: No rate sensitivity, no borrower characteristics, no burnout, no economic conditions. Used for settlement conventions and historical comparison, not for pricing.

### CPR Model Limitations

Traditional CPR regression models regress monthly prepayment rates on rate incentive and a few static factors. They fail because:

- They assume linear responses to rate incentive (actual response is S-curve shaped)
- They cannot capture interaction effects (high FICO + high rate incentive = very different behavior than low FICO + same incentive)
- They do not model burnout dynamically
- They fail in extreme rate regimes (2020-2021 refi wave; 2022-2023 lock-in effect)

---

## Feature Engineering for ML Prepayment Models

### Core Feature Categories

| Category | Features | Source |
|---|---|---|
| Rate Incentive | note_rate - current_refi_rate, spread_to_market, refi_incentive_flag | Freddie Primary Mortgage Market Survey |
| Borrower Credit | fico_score, dti_ratio, credit_flag (A/B/C) | Origination data |
| Loan Characteristics | original_ltv, current_ltv, loan_size_bucket, loan_purpose, amortization_type | Fannie/Freddie loan-level data |
| Seasoning | loan_age_months, wala, seasoning_bucket | Calculated |
| Burnout | months_in_the_money, prior_refi_opportunity_count, burnout_factor | Calculated |
| Housing Market | hpa_12m, hpa_3m, msa_hpi_level, equity_extracted | CoreLogic, FHFA |
| Economic | unemployment_rate, consumer_confidence, 10yr_treasury, libor_ois_spread | FRED, Bloomberg |
| Seasonality | month_of_year, spring_indicator, q4_indicator | Calendar |
| Pool/Servicer | servicer_id, pool_age, pool_concentration | Agency disclosures |

### Computing Burnout Factor

Burnout captures the exhaustion of refinancing-eligible borrowers from a pool. After prolonged low rates, the remaining borrowers are either rate-insensitive or credit-constrained.

```sql
-- Snowflake: Compute burnout factor from loan-level performance history
WITH monthly_incentive AS (
    SELECT
        lp.loan_id,
        lp.report_month,
        lp.current_upb,
        lm.note_rate,
        mr.primary_rate_30yr          AS current_market_rate,
        lm.note_rate - mr.primary_rate_30yr AS rate_incentive
    FROM loan_performance lp
    JOIN loan_master lm ON lp.loan_id = lm.loan_id
    JOIN market_rates mr ON lp.report_month = mr.rate_month
),

burnout_calc AS (
    SELECT
        loan_id,
        report_month,
        rate_incentive,
        -- Count months loan was "in the money" (rate incentive > 50 bps threshold)
        SUM(CASE WHEN rate_incentive > 0.50 THEN 1 ELSE 0 END)
            OVER (PARTITION BY loan_id ORDER BY report_month
                  ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS months_in_the_money,
        -- Maximum rate incentive ever seen (peak opportunity)
        MAX(rate_incentive)
            OVER (PARTITION BY loan_id ORDER BY report_month
                  ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS max_prior_incentive
    FROM monthly_incentive
)

SELECT
    loan_id,
    report_month,
    rate_incentive,
    months_in_the_money,
    max_prior_incentive,
    -- Burnout factor: 0 = fresh borrower, 1 = fully burned out
    CASE
        WHEN months_in_the_money = 0 THEN 0.0
        WHEN months_in_the_money >= 24 THEN 1.0
        ELSE ROUND(months_in_the_money / 24.0, 4)
    END AS burnout_factor
FROM burnout_calc
WHERE report_month = '2026-02-01';
```

### Computing CPR from Loan Performance Data

```sql
-- SQL Server: Monthly CPR calculation from Fannie Mae loan-level data
WITH performance_lagged AS (
    SELECT
        loan_id,
        report_month,
        current_upb,
        scheduled_principal,
        delinquency_status,
        LAG(current_upb) OVER (PARTITION BY loan_id ORDER BY report_month) AS prior_upb,
        LAG(delinquency_status) OVER (PARTITION BY loan_id ORDER BY report_month) AS prior_status
    FROM dbo.loan_monthly_performance
    WHERE report_month BETWEEN '2020-01-01' AND '2026-02-01'
),

smm_calc AS (
    SELECT
        loan_id,
        report_month,
        prior_upb,
        current_upb,
        scheduled_principal,
        CASE
            WHEN prior_upb IS NULL OR prior_upb = 0           THEN NULL
            WHEN delinquency_status IN (6, 7, 8, 9)           THEN NULL  -- exclude delinquent
            WHEN prior_upb - scheduled_principal <= 0          THEN NULL  -- near payoff
            ELSE (prior_upb - current_upb - scheduled_principal)
                 / NULLIF(prior_upb - scheduled_principal, 0)
        END AS smm
    FROM performance_lagged
    WHERE prior_upb IS NOT NULL
)

SELECT
    loan_id,
    report_month,
    smm,
    CASE
        WHEN smm IS NULL OR smm > 1  THEN NULL
        WHEN smm <= 0                THEN 0.0
        ELSE ROUND(1.0 - POWER(1.0 - smm, 12), 6)
    END AS cpr,
    CASE WHEN smm >= 1.0 THEN 1 ELSE 0 END AS full_prepayment_flag
INTO #loan_cpr_monthly
FROM smm_calc;
```

---

## Model Architecture: XGBoost for Prepayment

XGBoost and LightGBM dominate production prepayment models for their accuracy on tabular financial data, interpretability via SHAP, and inference speed.

```python
import pandas as pd
import numpy as np
import xgboost as xgb
from sklearn.model_selection import TimeSeriesSplit
from sklearn.metrics import mean_absolute_error
import shap
import mlflow
import mlflow.xgboost

# Feature set for XGBoost prepayment model
FEATURE_COLS = [
    # Rate & incentive
    'rate_incentive',
    'rate_incentive_sq',          # Quadratic — captures S-curve tails
    'refi_incentive_flag',        # Binary: incentive > 50bps
    # Burnout
    'burnout_factor',
    'months_in_the_money',
    'max_prior_incentive',
    # Loan characteristics
    'loan_age_months',
    'log_loan_size',              # Log transform for right-skewed distribution
    'current_ltv',
    'original_ltv',
    'ltv_change',                 # current_ltv - original_ltv (equity buildup)
    'fico_score',
    'dti_ratio',
    'loan_purpose_refi',          # One-hot: refinance loans prepay differently
    'loan_purpose_cashout',
    # Housing market
    'hpa_12m',
    'hpa_3m',
    'msa_hpi_percentile',         # Relative housing strength in MSA
    # Economic
    'unemployment_rate',
    '10yr_treasury_rate',
    # Seasonality
    'month_sin',                  # sin(2*pi*month/12) — cyclical encoding
    'month_cos',                  # cos(2*pi*month/12)
    'spring_flag',                # March-June
    # Pool/servicer
    'servicer_id_encoded',
]

TARGET_COL = 'cpr_next_month'  # Predict next month's CPR

def engineer_features(df: pd.DataFrame) -> pd.DataFrame:
    """Apply feature transformations to raw loan data."""
    df = df.copy()
    df['rate_incentive_sq'] = df['rate_incentive'] ** 2
    df['refi_incentive_flag'] = (df['rate_incentive'] > 0.50).astype(int)
    df['log_loan_size'] = np.log1p(df['current_upb'])
    df['ltv_change'] = df['current_ltv'] - df['original_ltv']
    df['loan_purpose_refi'] = (df['loan_purpose'] == 'R').astype(int)
    df['loan_purpose_cashout'] = (df['loan_purpose'] == 'C').astype(int)
    df['month_sin'] = np.sin(2 * np.pi * df['report_month'].dt.month / 12)
    df['month_cos'] = np.cos(2 * np.pi * df['report_month'].dt.month / 12)
    df['spring_flag'] = df['report_month'].dt.month.isin([3,4,5,6]).astype(int)
    return df

def train_prepayment_model(df_train: pd.DataFrame) -> xgb.XGBRegressor:
    """Train XGBoost prepayment model with time-series cross-validation."""

    df_train = engineer_features(df_train)
    df_train = df_train.sort_values('report_month')

    X = df_train[FEATURE_COLS]
    y = df_train[TARGET_COL]

    # Time-series split — never train on future data
    tscv = TimeSeriesSplit(n_splits=5, gap=1)

    params = {
        'n_estimators': 800,
        'max_depth': 6,
        'learning_rate': 0.05,
        'subsample': 0.8,
        'colsample_bytree': 0.8,
        'reg_alpha': 0.1,
        'reg_lambda': 1.0,
        'min_child_weight': 10,    # Prevents overfitting on thin data slices
        'objective': 'reg:squarederror',
        'eval_metric': 'mae',
        'random_state': 42,
        'n_jobs': -1
    }

    cv_maes = []
    with mlflow.start_run(run_name='xgb_prepayment_v3'):
        mlflow.log_params(params)

        for fold, (train_idx, val_idx) in enumerate(tscv.split(X)):
            X_fold_train, X_fold_val = X.iloc[train_idx], X.iloc[val_idx]
            y_fold_train, y_fold_val = y.iloc[train_idx], y.iloc[val_idx]

            model = xgb.XGBRegressor(**params)
            model.fit(
                X_fold_train, y_fold_train,
                eval_set=[(X_fold_val, y_fold_val)],
                early_stopping_rounds=50,
                verbose=False
            )
            fold_mae = mean_absolute_error(y_fold_val, model.predict(X_fold_val))
            cv_maes.append(fold_mae)
            print(f"Fold {fold+1} MAE: {fold_mae:.4f} CPR")

        mean_mae = np.mean(cv_maes)
        mlflow.log_metric('cv_mae_mean', mean_mae)
        mlflow.log_metric('cv_mae_std', np.std(cv_maes))
        print(f"\nMean CV MAE: {mean_mae:.4f} CPR ({mean_mae * 100:.2f} CPR points)")

        # Final model on all training data
        final_model = xgb.XGBRegressor(**params)
        final_model.fit(X, y, verbose=False)
        mlflow.xgboost.log_model(final_model, 'prepayment_model')

    return final_model

def compute_shap_analysis(model: xgb.XGBRegressor, X_sample: pd.DataFrame):
    """SHAP analysis for model interpretability — required for MRM documentation."""
    explainer = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(X_sample)

    # Global feature importance via mean absolute SHAP
    feature_importance = pd.DataFrame({
        'feature': FEATURE_COLS,
        'mean_abs_shap': np.abs(shap_values).mean(axis=0)
    }).sort_values('mean_abs_shap', ascending=False)

    print("\nTop 10 Prepayment Drivers (SHAP):")
    print(feature_importance.head(10).to_string(index=False))

    # SHAP dependence plot for rate incentive (primary driver)
    shap.dependence_plot('rate_incentive', shap_values, X_sample, show=False)
    return feature_importance
```

---

## Survival Analysis for Prepayment

Survival models treat prepayment as a time-to-event problem — more theoretically sound than monthly CPR regression because they model the full termination curve and handle competing risks (prepayment vs default vs curtailment).

### Cox Proportional Hazards

```python
from lifelines import CoxPHFitter
from lifelines.utils import concordance_index
import pandas as pd

def fit_cox_prepayment_model(df: pd.DataFrame) -> CoxPHFitter:
    """
    Cox PH model for prepayment hazard.
    Duration = months since origination.
    Event = 1 if prepayment, 0 if censored (still active or defaulted).
    """

    # Prepare survival format
    survival_df = df.groupby('loan_id').agg(
        duration=('loan_age_months', 'max'),        # time observed
        event_prepayment=('full_prepayment_flag', 'max'),  # 1 = prepaid
        rate_incentive=('rate_incentive', 'mean'),  # average incentive
        burnout_factor=('burnout_factor', 'last'),
        fico_score=('fico_score', 'first'),
        original_ltv=('original_ltv', 'first'),
        hpa_12m=('hpa_12m', 'mean'),
        unemployment_rate=('unemployment_rate', 'mean'),
        spring_flag=('spring_flag', 'mean'),
        log_loan_size=('log_loan_size', 'first')
    ).reset_index()

    cox_features = [
        'rate_incentive', 'burnout_factor', 'fico_score',
        'original_ltv', 'hpa_12m', 'unemployment_rate',
        'spring_flag', 'log_loan_size'
    ]

    cph = CoxPHFitter(penalizer=0.1, l1_ratio=0.1)
    cph.fit(
        survival_df[cox_features + ['duration', 'event_prepayment']],
        duration_col='duration',
        event_col='event_prepayment',
        show_progress=True
    )

    cph.print_summary()

    # Concordance index (C-index) — survival model AUC equivalent
    c_index = concordance_index(
        survival_df['duration'],
        -cph.predict_partial_hazard(survival_df[cox_features]),
        survival_df['event_prepayment']
    )
    print(f"\nC-index: {c_index:.4f}")

    return cph
```

### Competing Risks (Fine-Gray Model)

```python
from lifelines import AalenJohansenFitter
import matplotlib.pyplot as plt

def plot_competing_risks(df_loan: pd.DataFrame, loan_id_sample: list):
    """
    Plot cumulative incidence functions for prepayment vs default (competing risks).
    A loan that defaults is censored for prepayment analysis and vice versa.
    """
    # Event codes: 0=censored, 1=prepayment, 2=default
    df_sample = df_loan[df_loan['loan_id'].isin(loan_id_sample)].copy()

    ajf_prepay = AalenJohansenFitter(calculate_variance=True)
    ajf_default = AalenJohansenFitter(calculate_variance=True)

    ajf_prepay.fit(
        df_sample['duration'],
        df_sample['competing_event'],  # 0, 1, or 2
        event_of_interest=1            # prepayment
    )

    ajf_default.fit(
        df_sample['duration'],
        df_sample['competing_event'],
        event_of_interest=2            # default
    )

    fig, ax = plt.subplots(figsize=(10, 6))
    ajf_prepay.plot_cumulative_density(ax=ax, label='Prepayment CIF')
    ajf_default.plot_cumulative_density(ax=ax, label='Default CIF')
    ax.set_xlabel('Loan Age (Months)')
    ax.set_ylabel('Cumulative Incidence')
    ax.set_title('Competing Risks: Prepayment vs Default')
    ax.legend()
    return fig
```

---

## Model Validation

### Back-Testing Framework

```python
def backtest_prepayment_model(
    model,
    df_historical: pd.DataFrame,
    start_date: str,
    end_date: str
) -> pd.DataFrame:
    """
    Out-of-time back-test: train on data before start_date,
    predict monthly, compare to actuals.
    """
    results = []
    periods = pd.date_range(start=start_date, end=end_date, freq='MS')

    for period in periods:
        df_period = df_historical[df_historical['report_month'] == period].copy()
        df_period = engineer_features(df_period)

        if len(df_period) == 0:
            continue

        y_actual = df_period[TARGET_COL]
        y_pred = model.predict(df_period[FEATURE_COLS])
        y_pred = np.clip(y_pred, 0, 1)  # CPR must be in [0, 1]

        mae = mean_absolute_error(y_actual, y_pred)
        # Pool-level MAE (weighted by UPB) — what investors care about
        weights = df_period['current_upb'] / df_period['current_upb'].sum()
        wmae = np.sum(weights * np.abs(y_actual - y_pred))

        results.append({
            'period': period,
            'n_loans': len(df_period),
            'actual_cpr_mean': y_actual.mean(),
            'predicted_cpr_mean': y_pred.mean(),
            'mae_loan_level': mae,
            'wmae_upb_weighted': wmae,
            'bias': y_pred.mean() - y_actual.mean()
        })

    return pd.DataFrame(results)
```

### Snowflake SQL for Pool-Level Validation

```sql
-- Compare model predictions to actuals at pool level
-- Used for weekly model monitoring dashboard
WITH predictions AS (
    SELECT
        pool_id,
        report_month,
        AVG(predicted_cpr)                                              AS model_cpr,
        SUM(predicted_cpr * current_upb) / NULLIF(SUM(current_upb), 0) AS model_cpr_wgt
    FROM loan_model_scores
    WHERE score_date = CURRENT_DATE
    GROUP BY pool_id, report_month
),

actuals AS (
    SELECT
        pool_id,
        report_month,
        AVG(actual_cpr)                                             AS actual_cpr,
        SUM(actual_cpr * current_upb) / NULLIF(SUM(current_upb), 0) AS actual_cpr_wgt
    FROM loan_cpr_monthly
    GROUP BY pool_id, report_month
),

validation AS (
    SELECT
        p.pool_id,
        p.report_month,
        a.actual_cpr_wgt,
        p.model_cpr_wgt,
        ABS(p.model_cpr_wgt - a.actual_cpr_wgt)            AS abs_error,
        p.model_cpr_wgt - a.actual_cpr_wgt                 AS signed_error,
        (p.model_cpr_wgt - a.actual_cpr_wgt)
            / NULLIF(a.actual_cpr_wgt, 0)                  AS pct_error
    FROM predictions p
    JOIN actuals a ON p.pool_id = a.pool_id AND p.report_month = a.report_month
)

SELECT
    report_month,
    COUNT(*)                        AS pool_count,
    ROUND(AVG(actual_cpr_wgt), 4)  AS avg_actual_cpr,
    ROUND(AVG(model_cpr_wgt), 4)   AS avg_model_cpr,
    ROUND(AVG(abs_error), 4)       AS mean_abs_error,
    ROUND(AVG(signed_error), 4)    AS mean_bias,
    ROUND(STDDEV(signed_error), 4) AS error_std,
    -- Flag months with unacceptable error
    CASE WHEN AVG(abs_error) > 0.02 THEN 'ALERT' ELSE 'OK' END AS model_status
FROM validation
GROUP BY report_month
ORDER BY report_month DESC
LIMIT 12;
```

---

## SQL Server Stored Procedure for Model Scoring

```sql
CREATE OR ALTER PROCEDURE dbo.usp_ScorePrepaymentModel
    @AsOfDate      DATE,
    @ModelVersion  VARCHAR(20) = 'v3',
    @MinUPB        DECIMAL(18,2) = 10000.00
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- Validate inputs
        IF @AsOfDate > CAST(GETDATE() AS DATE)
            THROW 50001, 'AsOfDate cannot be in the future.', 1;

        -- Build feature set for scoring
        WITH loan_features AS (
            SELECT
                lp.loan_id,
                @AsOfDate                                       AS score_date,
                lm.note_rate - mr.primary_rate_30yr             AS rate_incentive,
                lm.note_rate - mr.primary_rate_30yr
                    - COALESCE(b.burnout_factor, 0) * 0.5       AS adj_rate_incentive,
                COALESCE(b.burnout_factor, 0)                   AS burnout_factor,
                COALESCE(b.months_in_the_money, 0)              AS months_in_the_money,
                lm.fico_score,
                lm.dti_ratio,
                lm.original_ltv,
                lp.current_upb / lm.original_upb * lm.original_ltv AS current_ltv,
                lp.loan_age_months,
                LOG(lp.current_upb)                             AS log_loan_size,
                CASE lm.loan_purpose WHEN 'R' THEN 1 ELSE 0 END AS loan_purpose_refi,
                h.hpa_12m,
                e.unemployment_rate,
                MONTH(@AsOfDate)                                AS score_month,
                CASE WHEN MONTH(@AsOfDate) BETWEEN 3 AND 6
                     THEN 1 ELSE 0 END                          AS spring_flag
            FROM dbo.loan_monthly_performance lp
            JOIN dbo.loan_master lm ON lp.loan_id = lm.loan_id
            JOIN dbo.market_rates mr ON mr.rate_month = @AsOfDate
            LEFT JOIN dbo.loan_burnout_factors b
                ON b.loan_id = lp.loan_id AND b.as_of_date = @AsOfDate
            LEFT JOIN dbo.msa_hpa h
                ON h.msa_code = lm.msa_code AND h.data_month = @AsOfDate
            LEFT JOIN dbo.economic_indicators e
                ON e.data_month = @AsOfDate
            WHERE lp.report_month = @AsOfDate
              AND lp.current_upb >= @MinUPB
              AND lp.delinquency_status NOT IN (6,7,8,9)  -- exclude delinquent
        )

        -- Insert scores (model scoring runs via Python/ONNX called from CLR or external call)
        -- This proc stages the features; scoring engine reads this table
        SELECT
            loan_id,
            score_date,
            @ModelVersion   AS model_version,
            rate_incentive,
            adj_rate_incentive,
            burnout_factor,
            months_in_the_money,
            fico_score,
            dti_ratio,
            original_ltv,
            current_ltv,
            loan_age_months,
            log_loan_size,
            loan_purpose_refi,
            hpa_12m,
            unemployment_rate,
            score_month,
            spring_flag,
            GETDATE()       AS staged_at
        INTO dbo.prepayment_scoring_features_staging
        FROM loan_features;

        SELECT @@ROWCOUNT AS loans_staged;

    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber  INT = ERROR_NUMBER();
        RAISERROR('usp_ScorePrepaymentModel failed. Error %d: %s', 16, 1, @ErrorNumber, @ErrorMessage);
        THROW;
    END CATCH;
END;
GO
```

---

## Integrating with Intex Cash Flow Engine

Intex is the industry standard for MBS cash flow modeling. ML prepayment model outputs integrate via CPR vectors.

```python
import pandas as pd
import pyodbc
from datetime import date
from typing import Optional

def export_cpr_vectors_for_intex(
    as_of_date: date,
    pool_ids: Optional[list] = None,
    output_path: str = '/data/intex/cpr_vectors.csv'
) -> pd.DataFrame:
    """
    Export ML model CPR forecasts as monthly vectors for Intex input.
    Intex expects: CUSIP, Month1_CPR, Month2_CPR, ..., Month360_CPR
    """
    conn = pyodbc.connect('DSN=MortgageDB;TrustedConnection=yes;')

    query = """
    SELECT
        lm.cusip,
        f.forecast_month_offset,
        f.predicted_cpr
    FROM dbo.prepayment_model_forecast f
    JOIN dbo.loan_master lm ON f.loan_id = lm.loan_id
    JOIN dbo.pool_loan_map plm ON lm.loan_id = plm.loan_id
    JOIN dbo.pool_master pm ON plm.pool_id = pm.pool_id
    WHERE f.score_date = ?
      AND f.forecast_month_offset BETWEEN 1 AND 360
    ORDER BY lm.cusip, f.forecast_month_offset
    """

    params = [as_of_date]
    if pool_ids:
        query = query.replace('WHERE f.score_date = ?',
                              f"WHERE f.score_date = ? AND pm.pool_id IN ({','.join(['?']*len(pool_ids))})")
        params.extend(pool_ids)

    df = pd.read_sql(query, conn, params=params)

    # Pivot to wide format: one row per CUSIP, one column per forecast month
    cpr_wide = df.pivot_table(
        index='cusip',
        columns='forecast_month_offset',
        values='predicted_cpr',
        aggfunc='mean'  # pool-level weighted average
    )

    cpr_wide.columns = [f'Month{int(c)}_CPR' for c in cpr_wide.columns]
    cpr_wide = cpr_wide.reset_index()

    # Convert to percentage (Intex expects 0-100 scale, not 0-1)
    month_cols = [c for c in cpr_wide.columns if c.startswith('Month')]
    cpr_wide[month_cols] = (cpr_wide[month_cols] * 100).round(4)

    cpr_wide.to_csv(output_path, index=False)
    print(f"Exported {len(cpr_wide)} CUSIP CPR vectors to {output_path}")
    return cpr_wide
```

---

## Interview Q&A

**Q1: Why do ML models outperform traditional CPR models in the current rate environment?**

Traditional CPR models assume a stationary, linear relationship between rate incentive and prepayment speed. This fails in three ways: (1) Rate regime breaks — the 2020-2021 refi wave and 2022-2023 lock-in effect both represent regime changes that linear models could not anticipate. XGBoost captures nonlinear thresholds: the relationship between rate incentive and CPR is an S-curve, not a line. (2) Interaction effects — a 50bps refi incentive for a 780 FICO, 65% LTV borrower produces very different behavior than the same incentive for a 620 FICO, 95% LTV borrower. Gradient boosting naturally models these interactions through tree splits. (3) Burnout — traditional models apply a static burnout adjustment; ML models compute burnout dynamically from each loan's actual rate history. These three factors together typically produce a 30-50% reduction in MAE vs traditional CPR regression on out-of-time validation.

**Q2: How do you handle the look-ahead bias problem when building prepayment models?**

Look-ahead bias occurs when the model is trained on features that would not have been available at prediction time. For prepayment models, the specific risks are: (1) using current-month CPR as a feature when predicting next-month CPR — this is only available after the period closes; (2) using HPA or economic data that is published with a lag (e.g., CoreLogic HPI is published 2 months after the reference period); (3) including loan modifications or delinquency cures that were announced after the prediction date. The solution is strict feature vintage controls: for a model that scores on the first business day of month M, every feature must have a vintage of month M-1 or earlier, with explicit lag adjustments for known publication delays. In the data pipeline, I enforce this by tagging every feature with its effective vintage date and the lag of its source data publication, and filtering feature joins to `feature_vintage <= score_date - publication_lag`.

**Q3: Walk me through the SHAP interpretation of a prepayment model for a model risk review.**

SHAP (SHapley Additive exPlanations) decomposes each individual prediction into contributions from each feature, summing to the difference between the prediction and the population mean. For the MRM presentation, I show three things: (1) Global importance — a bar chart of mean absolute SHAP values across the validation set. For a well-specified prepayment model, rate incentive should be the top driver (typically 30-40% of total SHAP magnitude), followed by burnout factor, loan age, FICO, and LTV. If a feature like servicer ID is in the top 5, that's a model risk flag. (2) Dependence plots — SHAP value vs feature value for the top 5 features. The rate incentive plot should show an S-curve shape with SHAP values near zero at negative incentive, rising steeply around 25-75bps, and flattening above 150bps — this matches economic intuition. (3) Individual loan explanation — for any loan being priced, show its waterfall chart: base rate + rate incentive contribution + burnout contribution + etc. = predicted CPR. This enables the business to trace any unexpected score back to its drivers.

**Q4: What is the competing risks problem in prepayment modeling and how do you address it?**

Every active mortgage loan faces three possible termination events: prepayment (voluntary), default (involuntary), and curtailment (partial payment). These are competing risks — once a loan terminates by one event, the others are precluded. Standard regression models treating CPR as the target variable ignore this structure: if a loan defaults, it is typically removed from the prepayment denominator, which can bias CPR estimates upward in stressed portfolios. The correct framework is the Fine-Gray sub-distribution hazard model (or the Aalen-Johansen estimator for cumulative incidence), which jointly models all competing events. In practice, most production models use a two-model approach: a separate XGBoost model for prepayment and for default, with a combined termination probability that prevents overlapping predictions. The survival model approach is theoretically superior but computationally heavier and requires loan-level monthly panel data in the correct survival format.

**Q5: How would you compute pool-level WAC and WAM from Fannie Mae loan-level data in Snowflake?**

```sql
SELECT
    pool_id,
    report_month,
    SUM(current_upb * note_rate) / NULLIF(SUM(current_upb), 0) AS wac,
    SUM(current_upb * remaining_term) / NULLIF(SUM(current_upb), 0) AS wam,
    SUM(current_upb * loan_age_months) / NULLIF(SUM(current_upb), 0) AS wala,
    SUM(current_upb * fico_score) / NULLIF(SUM(current_upb), 0) AS wafico,
    SUM(current_upb * current_ltv) / NULLIF(SUM(current_upb), 0) AS walt,
    COUNT(*) AS loan_count,
    SUM(current_upb) AS pool_upb
FROM loan_performance lp
JOIN loan_master lm ON lp.loan_id = lm.loan_id
WHERE report_month = '2026-02-01'
GROUP BY pool_id, report_month
```

WAC is the primary pricing metric used in Agency MBS markets — it drives the coupon strip valuation. WALA and WAM are the key inputs to any seasoning-based prepayment ramp adjustment. I always validate computed WAC against the Bloomberg pooled factor page for a sample of CUSIPs to catch data quality issues.

**Q6: Describe your approach to validating a new ML prepayment model against the incumbent model.**

Five-step validation: (1) Out-of-time test — hold out the most recent 12 months of data completely from training. Compute loan-level MAE, pool-level weighted MAE, and bias (systematic over- or under-prediction) for both models. (2) Stress period performance — specifically test performance during the 2020-2021 refi wave and 2022-2023 rate spike. A model that fails during extreme regimes is dangerous even if it performs well on average. (3) Segment analysis — break out performance by coupon, vintage year, LTV bucket, FICO bucket, loan purpose. A model that wins on aggregate but badly underperforms on high-coupon 2021 originations has a hidden risk. (4) Directional accuracy — beyond level accuracy, test whether the model correctly ranks pools by prepayment speed. Spearman correlation of predicted vs actual pool CPR rank is a key metric. (5) Economic scenario testing — shock rate incentive by +/-100bps and verify model response is directionally and magnitudinally reasonable relative to historical analogues.

**Q7: How do you handle the sparse data problem for newly originated loans?**

New loans have minimal performance history — no burnout data, limited seasonality observation, unknown servicer behavior for that originator-servicer combination. Three approaches: (1) Cold start rules — for loans with age < 6 months, blend the ML prediction with the PSA ramp (e.g., 70% ML, 30% PSA ramp) weighted by loan age; this prevents the model from making overconfident predictions on thin data. (2) Cohort features — substitute loan-level history features with cohort-level features (vintage year, state, FICO bucket cohort historical CPR as a prior); (3) Transfer learning — train the base model on deep history (10+ year panel), then fine-tune on recent vintages where the new loan's cohort is represented. In practice, approach 1 is most common in production — it's transparent, auditable, and predictable in extreme cases.

**Q8: How do rate lock-in effects (2022-2023) and refi waves (2020-2021) affect ML model training data?**

Both are structural breaks that create distribution shift problems. Training a model on 2010-2019 data produces a model that has never seen near-zero rates or the subsequent rapid rate normalization. Including 2020-2023 data in training helps but requires careful handling: (1) Sample weighting — upweight recent years in training loss to reflect current market dynamics; (2) Regime detection — add a feature for rate regime (rising/falling/stable, defined by 6-month treasury direction) so the model can learn regime-specific behavior; (3) Recency-aware validation — use expanding window cross-validation with a recency bias so the validation metric emphasizes recent period performance. The lock-in effect specifically creates a new population of borrowers who will likely never prepay while rates remain elevated — this population barely exists in pre-2022 training data. Feature engineering to capture this (e.g., negative rate incentive magnitude, months underwater) is essential.

**Q9: How would you deploy a prepayment scoring model at scale in Snowflake?**

Two deployment patterns: (1) Snowpark ML — register the XGBoost model as a Snowpark Python UDF. Training happens in Python, the serialized model (ONNX or pickle) is uploaded to a Snowflake stage, and a Python UDF calls the model at scoring time. Pros: model stays in Snowflake, no data movement. Cons: UDF cold start latency, limited Python dependencies. (2) External function — score in Python/AWS Lambda/Azure Functions and call from Snowflake via external function. Pros: full Python ecosystem, GPU support if needed. Cons: data leaves Snowflake boundary, latency. For daily batch scoring of 2-10 million loans, Snowpark UDF is preferred: `SELECT loan_id, predict_cpr(rate_incentive, burnout_factor, fico_score, ...) AS predicted_cpr FROM loan_scoring_features`. For real-time pricing of individual bonds, external function with a cached scoring service is better. The scoring features are always staged in Snowflake regardless of which pattern is used, ensuring full lineage.

**Q10: What is the PSI threshold for triggering prepayment model retraining, and how do you compute it?**

PSI = sum[(Actual% - Expected%) * ln(Actual% / Expected%)] computed over score buckets (typically deciles of predicted CPR). I compute it on the predicted score distribution, not just input features, because score drift is the leading indicator of model degradation. Thresholds: PSI < 0.10 = stable, 0.10-0.25 = moderate shift (investigate), > 0.25 = significant shift (retrain or recalibrate). For prepayment models specifically, I compute PSI separately for three rate regimes (rising, flat, falling) because regime-conditional distribution shifts are more actionable than unconditional PSI. In Snowflake, PSI runs as a scheduled task every month using the model training period as the reference distribution. If PSI triggers, the first diagnostic is feature-level PSI to identify which features drifted — often it's the rate incentive distribution shifting as the market moves, which is expected and doesn't require retraining. What requires retraining is when SHAP value distributions shift (the relationship between features and predictions has changed) rather than just input distributions.

---

## Pro Tips

- **S-curve for rate incentive**: Always plot predicted CPR vs rate incentive for your model. It should be an S-curve. If it's linear, you're missing the saturation effects at high incentive and the threshold at low incentive. Adding a polynomial or piecewise transformation of rate incentive before feeding to XGBoost usually helps.
- **Burnout is the hardest feature**: Most model errors on seasoned collateral come from incorrect burnout. Build burnout from the actual loan-level rate history, not a pool-level approximation. The difference between a loan that has been in-the-money for 6 months vs 24 months is enormous and cannot be captured with pool-level WALA.
- **Never use R-squared for CPR models**: R-squared is misleading for CPR because the distribution is bounded (0-1) and highly skewed. Use MAE (mean absolute CPR error) in CPR points, WMAE (weighted by UPB), and bias. Report separately for high-coupon vs low-coupon collateral.
- **Intex integration**: Intex's CIRS (Custom Interest Rate Scenario) API accepts monthly CPR vectors programmatically. Automate the export-to-Intex workflow so portfolio managers get updated pricing within 30 minutes of the daily model score run.
- **SR 11-7 documentation**: Model risk managers will ask for: (1) the training data description and vintage range, (2) feature definitions and computation methodology, (3) out-of-time validation results by time period and collateral segment, (4) sensitivity analysis (what happens to model output if rate incentive moves 100bps?), (5) known limitations and compensating controls. Prepare these as artifacts at model build time, not during the review.
- **Negative rate incentive**: Post-2022, many borrowers have 3% mortgages with no refinancing incentive. The model must correctly predict near-zero prepayment for these borrowers. Validate specifically on the negative-incentive segment — this is where traditional models have the largest errors.
- **Data vintage discipline**: Fannie Mae and Freddie Mac single-family loan-level performance files are published monthly with a 2-month lag. Build your pipeline to enforce this lag explicitly. Using November data when it's only available after January 15th is a look-ahead violation that will inflate back-test performance.
