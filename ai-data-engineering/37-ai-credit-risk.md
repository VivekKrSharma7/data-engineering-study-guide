# AI for Credit Risk Assessment & Scoring

[← Back to Index](README.md)

---

## Overview

Credit risk modeling has evolved from simple rule-based FICO scoring into sophisticated machine learning systems that consume hundreds of features from traditional and alternative data sources. For a senior data engineer in the US secondary mortgage market, this means building and maintaining pipelines that feed Logistic Regression baselines, gradient-boosted trees, and neural networks — all while satisfying SR 11-7 model risk management guidelines, ECOA/FHA fair lending requirements, and the explainability demands of adverse action notices. This guide covers the full stack: feature engineering in Snowflake, XGBoost modeling in Python, SHAP explanations, model validation statistics, and champion/challenger deployment.

---

## Key Concepts

| Concept | Definition |
|---|---|
| FICO Score | Weighted composite of five factors: payment history (35%), utilization (30%), length of credit history (15%), credit mix (10%), new credit (10%) |
| DTI | Debt-to-Income ratio — monthly obligations / gross monthly income |
| LTV | Loan-to-Value — loan amount / appraised property value |
| CLTV | Combined LTV — (first + subordinate liens) / appraised value |
| AVM | Automated Valuation Model — statistical model estimating property value |
| Gini Coefficient | Measures model discrimination: 2 * AUC - 1 |
| KS Statistic | Maximum separation between cumulative good/bad distributions |
| PSI | Population Stability Index — measures how much a feature distribution has shifted |
| SR 11-7 | Federal Reserve guidance on model risk management (validation, documentation, governance) |
| CECL | Current Expected Credit Loss — FASB ASC 326, requires lifetime loss estimation |
| Champion/Challenger | Production framework where a new model scores a traffic slice alongside the incumbent |

---

## FICO Score Components — Deep Dive

### The Five Factors

```
Payment History (35%)      — On-time payments, derogatory marks, collections
Credit Utilization (30%)   — Revolving balance / revolving credit limit
Length of Credit (15%)     — Age of oldest account, average age of accounts
Credit Mix (10%)           — Installment, revolving, mortgage, auto, student
New Credit (10%)           — Hard inquiries, recently opened accounts
```

### Why FICO Alone Is Insufficient for Mortgage Risk

- FICO is a point-in-time snapshot; it does not capture cash flow patterns
- Thin-file borrowers (immigrants, young adults) are excluded or mis-scored
- FICO does not reflect rental payment history, utility payments, or bank account behavior
- VantageScore 4.0 and FHFA's FICO 10T / VantageScore 4.0 mandate (effective 2025) add trended credit data

---

## Feature Engineering for Credit Models

### Traditional Mortgage Features

| Feature | Description | Source |
|---|---|---|
| FICO_ORIGINATION | Credit score at origination | Credit bureau pull |
| DTI | Front-end and back-end ratios | Loan application (1003) |
| LTV / CLTV | Collateral coverage | Appraisal + note amount |
| LOAN_PURPOSE | Purchase, rate/term refi, cash-out refi | 1003 |
| OCCUPANCY | Primary, second home, investment | 1003 |
| LOAN_TERM | 15yr, 20yr, 30yr | Note |
| PRODUCT_TYPE | Fixed, ARM (5/1, 7/1), IO | Note |
| SELLER_ID | Originating lender identifier | FNMA/FHLMC delivery |

### Alternative Data Features

```python
alternative_features = {
    "BANK_CASH_FLOW_VOLATILITY": "Std dev of monthly net cash flow over 12 months",
    "RENT_PAYMENT_ON_TIME_PCT": "% of rental payments made on time (VoR data)",
    "EMPLOYMENT_TENURE_MONTHS": "Months at current employer",
    "GIG_INCOME_FLAG": "1 if >30% income from gig/1099 sources",
    "NSF_COUNT_12M": "Non-sufficient funds events in last 12 months",
    "SAVINGS_RATE_3M": "Avg (income - expenses) / income over 3 months",
}
```

### Property-Level Features

| Feature | Notes |
|---|---|
| AVM_CONFIDENCE_SCORE | Low confidence AVMs increase collateral risk |
| AVM_TO_APPRAISAL_RATIO | Divergence flags potential appraisal inflation |
| MSA_CODE | Metropolitan Statistical Area — drives HPI-based adjustments |
| PROPERTY_TYPE | SFR, condo, 2-4 unit, manufactured |
| HPI_1YR_CHANGE | House Price Index YoY change at ZIP/MSA level |
| FORECLOSURE_RATE_ZIP | Local market stress indicator |

---

## Model Types and Regulatory Positioning

### Logistic Regression — The Regulatory Baseline

Required by SR 11-7 as an interpretable benchmark. All challenger models must demonstrate statistically significant lift over logistic regression before approval.

```python
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler

scaler = StandardScaler()
X_scaled = scaler.fit_transform(X_train)

lr_model = LogisticRegression(
    penalty='l2',
    C=0.1,          # regularization strength
    class_weight='balanced',
    max_iter=1000,
    random_state=42
)
lr_model.fit(X_scaled, y_train)
```

### XGBoost — Primary Production Model

```python
import xgboost as xgb
import shap
import pandas as pd
import numpy as np
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score

# -------------------------------------------------------
# 1. Load Fannie Mae loan-level performance data
# -------------------------------------------------------
# Columns: loan_id, origination_fico, ltv, cltv, dti,
#          loan_purpose, occupancy, msa, orig_upb, default_flag
df = pd.read_parquet("fnma_originations_2018_2022.parquet")

FEATURES = [
    "ORIGINATION_FICO", "LTV", "CLTV", "DTI", "ORIG_UPB",
    "LOAN_PURPOSE_CD", "OCCUPANCY_CD", "PRODUCT_TYPE_CD",
    "PROP_TYPE_CD", "MSA_CODE", "HPI_1YR_CHANGE",
    "EMPLOYMENT_TENURE_MONTHS", "NSF_COUNT_12M"
]
TARGET = "DEFAULT_90DPD_24M"  # 90+ DPD within 24 months of origination

X = df[FEATURES]
y = df[TARGET]

X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, random_state=42, stratify=y
)

# -------------------------------------------------------
# 2. Train XGBoost model
# -------------------------------------------------------
scale_pos_weight = (y_train == 0).sum() / (y_train == 1).sum()

model = xgb.XGBClassifier(
    n_estimators=500,
    max_depth=5,
    learning_rate=0.05,
    subsample=0.8,
    colsample_bytree=0.8,
    scale_pos_weight=scale_pos_weight,  # handle class imbalance
    eval_metric="auc",
    early_stopping_rounds=50,
    random_state=42,
    n_jobs=-1
)

model.fit(
    X_train, y_train,
    eval_set=[(X_test, y_test)],
    verbose=50
)

# -------------------------------------------------------
# 3. Evaluate
# -------------------------------------------------------
y_pred_proba = model.predict_proba(X_test)[:, 1]
auc = roc_auc_score(y_test, y_pred_proba)
gini = 2 * auc - 1
print(f"AUC: {auc:.4f}  |  Gini: {gini:.4f}")

# KS Statistic
from scipy.stats import ks_2samp
scores_good = y_pred_proba[y_test == 0]
scores_bad  = y_pred_proba[y_test == 1]
ks_stat, _ = ks_2samp(scores_good, scores_bad)
print(f"KS Statistic: {ks_stat:.4f}")

# -------------------------------------------------------
# 4. SHAP Explanations (required for adverse action notices)
# -------------------------------------------------------
explainer = shap.TreeExplainer(model)
shap_values = explainer.shap_values(X_test)

# Global feature importance
shap.summary_plot(shap_values, X_test, plot_type="bar")

# Individual loan explanation
loan_idx = 42
shap.force_plot(
    explainer.expected_value,
    shap_values[loan_idx],
    X_test.iloc[loan_idx],
    matplotlib=True
)

# Top 4 adverse factors for a denied application
def get_adverse_factors(shap_vals, feature_names, n=4):
    """Return top N features that increased default probability."""
    pairs = list(zip(feature_names, shap_vals))
    adverse = sorted(pairs, key=lambda x: x[1], reverse=True)[:n]
    return adverse

adverse = get_adverse_factors(shap_values[loan_idx], FEATURES)
print("Adverse action factors:", adverse)
```

### PSI — Population Stability Index

```python
def compute_psi(expected, actual, buckets=10):
    """
    PSI < 0.10: No significant change
    PSI 0.10-0.25: Slight change, monitor
    PSI > 0.25: Major shift, model recalibration required
    """
    breakpoints = np.linspace(0, 1, buckets + 1)
    expected_pct = np.histogram(expected, breakpoints)[0] / len(expected)
    actual_pct   = np.histogram(actual,   breakpoints)[0] / len(actual)
    # avoid log(0)
    expected_pct = np.where(expected_pct == 0, 1e-4, expected_pct)
    actual_pct   = np.where(actual_pct   == 0, 1e-4, actual_pct)
    psi = np.sum((actual_pct - expected_pct) * np.log(actual_pct / expected_pct))
    return psi

psi = compute_psi(train_scores, production_scores_current_month)
print(f"Score PSI: {psi:.4f}")
```

---

## Snowflake for Credit Model Feature Computation

```sql
-- ============================================================
-- Credit model feature store: compute DTI, LTV, rolling stats
-- ============================================================
CREATE OR REPLACE TABLE CREDIT_FEATURES.LOAN_FEATURES AS

WITH loan_base AS (
    SELECT
        loan_id,
        origination_date,
        orig_upb,
        appraised_value,
        orig_upb / NULLIF(appraised_value, 0)                         AS ltv,
        (orig_upb + subordinate_balance) / NULLIF(appraised_value, 0) AS cltv,
        monthly_debt / NULLIF(gross_monthly_income, 0)                AS dti,
        fico_score,
        msa_code,
        loan_purpose_cd,
        occupancy_cd
    FROM LOAN_ORIGINATIONS.FACT_LOANS
    WHERE origination_date >= '2018-01-01'
),

perf_stats AS (
    -- Rolling 24-month default flag
    SELECT
        l.loan_id,
        MAX(CASE WHEN p.days_delinquent >= 90
                  AND p.reporting_period <= DATEADD(month, 24, l.origination_date)
             THEN 1 ELSE 0 END) AS default_90dpd_24m,
        MAX(p.days_delinquent)  AS max_dq_24m
    FROM loan_base l
    JOIN LOAN_PERFORMANCE.FACT_MONTHLY_PERF p ON l.loan_id = p.loan_id
    WHERE p.reporting_period BETWEEN l.origination_date
                                 AND DATEADD(month, 24, l.origination_date)
    GROUP BY l.loan_id
),

hpi_data AS (
    SELECT msa_code,
           hpi_index_value,
           LAG(hpi_index_value, 12) OVER (
               PARTITION BY msa_code ORDER BY reference_date
           ) AS hpi_12m_prior,
           reference_date
    FROM MARKET_DATA.MSA_HPI
)

SELECT
    lb.*,
    ps.default_90dpd_24m,
    ps.max_dq_24m,
    (h.hpi_index_value - h.hpi_12m_prior) / NULLIF(h.hpi_12m_prior, 0) AS hpi_1yr_change
FROM loan_base lb
LEFT JOIN perf_stats  ps ON lb.loan_id   = ps.loan_id
LEFT JOIN hpi_data    h  ON lb.msa_code  = h.msa_code
                        AND DATE_TRUNC('month', lb.origination_date) = h.reference_date;
```

---

## CECL and ML Models

CECL (ASC 326) requires financial institutions to estimate lifetime expected credit losses at origination. ML models serve as PD (Probability of Default) estimators feeding the CECL allowance calculation:

```
CECL Allowance = sum over loans of: EAD × PD_lifetime × LGD × (1 - recovery_rate)
```

- **PD**: XGBoost score calibrated to historical default rates by vintage cohort
- **LGD**: Loss Given Default — driven by LTV, property type, state foreclosure timeline
- **EAD**: Exposure at Default — remaining UPB at default, modeled with prepayment adjustments

Vintage analysis groups loans by origination quarter and tracks cumulative default rates over time, providing the historical training data for lifetime PD curves.

---

## Fannie Mae / Freddie Mac Loan-Level Data

Both agencies publish quarterly loan-level origination and performance datasets:

- **FNMA**: ~30 fields at origination, monthly performance through disposition
- **FHLMC**: Similar structure, separate schema
- Fields include: FICO, LTV, DTI, interest rate, loan purpose, occupancy, property type, state, MSA, seller/servicer IDs, MI type

These datasets are the gold standard for training mortgage credit models due to volume (millions of loans), historical depth (2000-present), and verified outcomes.

```python
# Load and merge Fannie Mae origination + performance files
orig = pd.read_csv("fnma_2020Q1_orig.csv", sep="|", header=None,
                   names=FNMA_ORIG_COLS)
perf = pd.read_csv("fnma_2020Q1_perf.csv", sep="|", header=None,
                   names=FNMA_PERF_COLS)

# Compute ever-90 within 24 months
perf["months_since_orig"] = (
    pd.to_datetime(perf["MONTHLY_REPORTING_PERIOD"]) -
    pd.to_datetime(perf["ORIGINATION_DATE"])
).dt.days // 30

ever90 = (
    perf[perf["months_since_orig"] <= 24]
    .groupby("LOAN_SEQUENCE_NUMBER")["CURRENT_LOAN_DELINQUENCY_STATUS"]
    .apply(lambda x: int((x.astype(str).str.extract(r"(\d+)")[0]
                           .astype(float) >= 3).any()))
    .reset_index()
    .rename(columns={"CURRENT_LOAN_DELINQUENCY_STATUS": "DEFAULT_FLAG"})
)
```

---

## Champion/Challenger Framework

```
Traffic Split (Snowflake Dynamic Tables or API layer)
├── Champion (80% traffic) — current production model v2.1
└── Challenger (20% traffic) — new model v3.0 candidate

Evaluation window: 90 days minimum
Promotion criteria:
  - Challenger Gini >= Champion Gini + 0.02
  - PSI < 0.10 (no distribution shift)
  - No disparate impact flags (>80% rule across protected classes)
  - SR 11-7 validation report signed off
```

---

## Regulatory Constraints

### SR 11-7 Model Risk Management

- Every model must have a Model Development Document (MDD) and a Model Validation Report (MVR)
- Validators must be independent of model developers
- Annual revalidation or triggered revalidation on PSI breach

### Fair Lending (ECOA / FHA)

- Prohibited bases: race, color, national origin, religion, sex, familial status, disability
- Disparate impact analysis required: approval rates and pricing by demographic cohort
- SHAP-based adverse action notices must not reference protected class proxies
- Features like ZIP code, MSA code require careful disparate impact testing

---

## Interview Q&A

**Q1: Why do mortgage lenders still require a Logistic Regression baseline when XGBoost performs better?**

SR 11-7 requires model explainability and a documented benchmark. Logistic Regression coefficients have direct interpretability — each coefficient quantifies the log-odds change per unit of a feature. Regulators and internal model validators use it as the conceptual anchor. XGBoost gains must be statistically significant over LR to justify the added complexity and opacity. The LR model also serves as a fallback if the complex model degrades.

**Q2: How do you generate adverse action notices from an XGBoost model?**

ECOA's Regulation B requires specific reasons for denial (up to four). With XGBoost, you compute SHAP values for each applicant's prediction. The top N features with positive SHAP values (those increasing default probability) become the adverse factors. You map feature names to human-readable reason codes (e.g., "HIGH_DTI" → "Debt-to-income ratio too high"). The key requirement: reason codes cannot reference race, gender, or protected class proxies, so you must audit your feature-to-reason-code mapping against proxy lists.

**Q3: What is the KS statistic and when would you use it versus Gini?**

KS (Kolmogorov-Smirnov) measures the maximum vertical distance between the cumulative distribution functions of good and bad accounts across score deciles. It tells you where your model separates best. Gini (= 2×AUC - 1) is a global discrimination measure across all thresholds. Use KS when you have a specific cutoff in mind and want to know the model's peak separation at that point. Gini is better for overall model comparison. In mortgage, both are reported; Gini > 0.40 is generally acceptable, > 0.55 is strong.

**Q4: How does PSI differ from feature drift detection, and what do you do when PSI exceeds 0.25?**

PSI measures the shift in score or feature distributions between development and current production populations. It's a univariate, distribution-level metric. Feature drift detection (e.g., Jensen-Shannon divergence, Wasserstein distance) can be more sensitive and works on multivariate drift. When PSI > 0.25, the standard response is: (1) investigate root cause — economic cycle change, origination channel mix shift, data pipeline change; (2) trigger a model revalidation; (3) consider recalibrating the model's probability estimates even if rank-ordering is intact; (4) evaluate whether a full redevelopment is needed.

**Q5: Walk me through how you would build a vintage analysis table in Snowflake.**

A vintage analysis tracks cohorts of loans by origination period and measures cumulative default rates at each seasoning month. In Snowflake:
```sql
SELECT
    DATE_TRUNC('quarter', origination_date)        AS vintage,
    DATEDIFF('month', origination_date, reporting_period) AS months_on_book,
    COUNT(DISTINCT loan_id)                        AS loan_count,
    SUM(default_flag)                              AS cumulative_defaults,
    SUM(default_flag) / COUNT(DISTINCT loan_id)    AS cum_default_rate
FROM CREDIT_FEATURES.LOAN_FEATURES
GROUP BY 1, 2
ORDER BY 1, 2;
```
This produces a matrix where rows are vintages and columns are MOB (months on book), revealing whether newer originations are performing better or worse than historical cohorts at the same seasoning point.

**Q6: How does CECL differ from the incurred loss model, and where does ML add value?**

Under the old incurred loss model (pre-ASC 326), institutions only reserved for losses that had already been incurred — essentially current delinquency buckets. CECL requires booking the full lifetime expected loss at origination. ML adds value by: (1) producing calibrated PD estimates that decay correctly over the loan's life (vintage-based survival curves); (2) incorporating macro scenarios (base, adverse, severely adverse) into PD multipliers; (3) capturing nonlinear interactions between LTV, FICO, and DTI that linear models miss. The data engineer's role is building the feature pipeline that serves PD inputs to the CECL reserve calculation daily or monthly.

**Q7: What is the difference between LTV and CLTV, and why does CLTV matter more for second lien risk?**

LTV = first mortgage balance / appraised value. CLTV = (first mortgage + all subordinate liens) / appraised value. For a first lien holder evaluating standalone risk, LTV is primary. For a second lien holder — or when evaluating piggyback structures (80/10/10) common before 2008 — CLTV is the relevant measure because in foreclosure, the first lien is senior; the second lien only recovers from proceeds after the first is made whole. CLTV > 100% means the borrower is underwater on a combined basis, dramatically increasing loss severity.

**Q8: How would you use Intex data in a credit risk model?**

Intex provides structured finance deal data: collateral-level loan tapes, deal structure (waterfall logic), and cash flow projections for RMBS, ABS, and CDOs. In a credit model context, Intex loan-level data is used to: (1) supplement Fannie/Freddie public data with non-agency loan performance history; (2) extract collateral attributes (LTV, FICO, product type) for non-QM and private label securities; (3) feed CPR/CDR assumptions into cash flow models. The data engineer's job is typically loading Intex monthly tape deliveries into Snowflake, normalizing field schemas across deals, and reconciling Intex collateral counts against servicer remittance reports.

**Q9: What fairness metrics would you compute on a credit model before production deployment?**

- **Approval rate disparity**: Approval rate for each protected class / approval rate for control group (>0.80 = passes 4/5ths rule under ECOA guidance)
- **Predicted probability disparity**: Mean PD score by demographic cohort
- **SHAP feature attribution by cohort**: Check that the same features drive denials across groups; disparities may indicate proxy discrimination
- **Calibration by group**: Are predicted probabilities as well-calibrated for minority borrowers as for white borrowers?
- **Counterfactual fairness**: Would the decision change if only protected class attributes were altered?

**Q10: How do you handle class imbalance in mortgage default models?**

Default rates in performing mortgage pools are typically 1-3%, creating severe imbalance. Approaches: (1) `scale_pos_weight` in XGBoost (ratio of negatives to positives); (2) SMOTE oversampling of minority class for training; (3) threshold tuning — optimize the decision threshold using F1, precision-recall, or business cost matrix rather than defaulting to 0.5; (4) cost-sensitive learning — assign misclassification costs proportional to business impact (a missed default is far more costly than a false positive in mortgage); (5) calibrated probabilities via Platt scaling to ensure score interpretability.

---

## Pro Tips

- Always version your training datasets alongside model artifacts. Fannie Mae re-releases corrected loan-level files; your model trained on v1 tape will produce different results than one trained on v2.
- In Snowflake, use Dynamic Tables for feature materialization — they auto-refresh on upstream changes and capture the lineage needed for SR 11-7 documentation.
- SHAP TreeExplainer is orders of magnitude faster than KernelExplainer for tree-based models. Always use TreeExplainer for XGBoost/LightGBM in production scoring pipelines.
- When building vintage analysis, be careful about right-censoring: loans originated recently have fewer months of performance history. Use survival analysis (Kaplan-Meier) or explicitly flag MOB < 24 months as incomplete.
- PSI should be computed on both input features and the output score. Feature PSI tells you what shifted; score PSI tells you the downstream impact. You can have stable features but a shifted score if the model is in a nonlinear region.
- The FHFA's 2025 mandate to replace Classic FICO with FICO 10T and VantageScore 4.0 at GSE delivery requires data pipeline changes: new score fields, new cutoff thresholds, and model recalibration.

---

[← Back to Index](README.md)
