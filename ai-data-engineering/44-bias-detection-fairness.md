# Bias Detection & Fairness in ML for Financial Services

[← Back to Index](README.md)

---

## Overview

Bias in mortgage lending has one of the most consequential histories of any industry in the United States. Redlining, discriminatory underwriting, and predatory lending in subprime products all left documented patterns of harm along racial and geographic lines — patterns that machine learning models trained on historical data will faithfully reproduce and potentially amplify if fairness is not explicitly engineered in. For a senior data engineer in the secondary mortgage market, understanding bias is not academic. The CFPB, DOJ, and OCC have all brought AI-related fair lending enforcement actions, and the secondary market (Fannie Mae, Freddie Mac, private label MBS) requires seller/servicer representations that their credit decisioning complies with fair lending laws.

This file covers the taxonomy of bias, the legal framework governing fair lending, practical methods for detecting and measuring bias in mortgage ML models, mitigation techniques, and the infrastructure (Snowflake, Python) that supports a defensible fairness analysis program.

---

## Key Concepts at a Glance

| Term | Definition |
|---|---|
| Disparate Treatment | Intentional discrimination based on a protected class — illegal |
| Disparate Impact | Neutral policy that disproportionately harms a protected class — can be illegal |
| 4/5ths Rule | EEOC disparate impact threshold: selection rate of protected class < 80% of highest group |
| Demographic Parity | Model approval rates are equal across groups |
| Equalized Odds | Model TPR and FPR are equal across groups |
| Counterfactual Fairness | Model would give same output if borrower were of a different protected class |
| HMDA | Home Mortgage Disclosure Act — public loan-level data used for bias analysis |
| ECOA | Equal Credit Opportunity Act — prohibits discrimination in credit |
| FHA | Fair Housing Act — prohibits discrimination in residential property transactions |
| Fairlearn | Microsoft Python library for fairness assessment and mitigation |
| AI Fairness 360 | IBM Python toolkit for bias detection across the ML lifecycle |
| SHAP | SHapley Additive exPlanations — used to detect when proxy variables drive decisions |

---

## Types of Bias in ML

### Historical / Societal Bias

The data reflects past discriminatory patterns. If a model is trained on 30 years of approved mortgage applications, it will learn that certain zip codes, income patterns, and credit profiles correlate with approval — but those correlations were themselves produced by discriminatory policies (redlining, steering, predatory lending targeting minority communities).

**Mortgage example:** A credit default model trained on pre-2010 data will have learned from a period when subprime products were disproportionately marketed to Black and Hispanic borrowers regardless of creditworthiness — making those borrowers look riskier in the historical record not because of credit behavior, but because of the product they were sold.

### Measurement Bias

The features used to measure creditworthiness systematically capture different things for different groups.

**Example:** Credit score models underweight positive financial behavior that is more common in immigrant or unbanked populations (rent payments, utility payments, informal lending) and overweight tradeline history that requires prior access to the formal credit system. This is measurement bias — the score does not measure "creditworthiness" equivalently across groups.

### Sampling Bias

The training sample does not represent the population on which the model will be deployed.

**Mortgage example:** A model trained on conventional conforming loans is deployed to evaluate FHA loans. The conventional loan applicant pool is wealthier and less demographically diverse than the FHA pool. The model's learned relationships may not transfer appropriately.

### Algorithmic / Model Bias

The model architecture or optimization objective introduces bias. A model optimizing accuracy will under-serve minority groups if they are a small fraction of the training data. Over-represented groups' patterns dominate gradient updates in standard empirical risk minimization.

### Feedback Loop Bias

A deployed model's decisions create the next round of training data. If the model denies loans to residents of certain neighborhoods (proxy for protected class), those neighborhoods see less credit extended, reinforcing the historical pattern that caused the model to flag them in the first place.

---

## Legal Framework: Fair Lending in Mortgage

### ECOA — Equal Credit Opportunity Act (Regulation B)

Prohibits discrimination in any aspect of a credit transaction on the basis of:
race, color, religion, national origin, sex, marital status, age (40+), receipt of public assistance, or exercise of rights under the Consumer Credit Protection Act.

**AI implications:**
- Adverse action notices must identify the principal reasons credit was denied — black-box models must produce explainable adverse action codes
- The CFPB has published guidance that ECOA applies to algorithmic models and that "complex models" do not excuse the adverse action notice requirement
- If a proxy variable (zip code, census tract) serves as a substitute for race in a model, it may constitute disparate treatment even if race is not an explicit input

### Fair Housing Act (FHA)

Prohibits discrimination in residential real estate transactions including mortgage lending based on race, color, national origin, religion, sex, familial status, or disability.

**Both disparate treatment and disparate impact are actionable under FHA** (reaffirmed by Inclusive Communities Project v. Texas, SCOTUS 2015). This means even a facially neutral ML model can violate FHA if it produces statistically significant disparities in outcomes for protected classes, unless the model serves a legitimate business necessity and is the least discriminatory alternative.

### HMDA — Home Mortgage Disclosure Act

Requires covered institutions to collect and report loan-level data including:
- Applicant and co-applicant race, ethnicity, sex
- Income, loan amount, loan purpose, property location (census tract)
- Action taken (originated, denied, withdrawn, etc.)
- Credit score range (as of 2018 HMDA modernization)
- DTI ratio, combined LTV

**HMDA public data is the primary tool for regulators and researchers to detect disparate impact in mortgage lending.** As a data engineer at a secondary market firm, you should be familiar with HMDA data structure because:
1. Fair lending analysis at your firm uses HMDA-structure data
2. Your firm's loans appear in public HMDA data and are subject to external scrutiny
3. HMDA data is used to benchmark your denial rates against peer institutions

---

## Fairness Definitions

Different fairness criteria make different trade-offs, and no single definition satisfies all simultaneously (Impossibility Theorems — Chouldechova 2017, Kleinberg et al. 2016).

### Demographic Parity (Statistical Parity)

The probability of a positive outcome (loan approval) is equal across protected groups.

```
P(Ŷ = 1 | A = 0) = P(Ŷ = 1 | A = 1)
```

**Limitation for mortgage lending:** This ignores actual creditworthiness differences caused by systemic inequality. Enforcing demographic parity may require approving objectively less creditworthy applicants in one group, which raises safety and soundness concerns for regulated institutions.

### Equalized Odds (Hardt et al. 2016)

Both the True Positive Rate (TPR) and False Positive Rate (FPR) are equal across groups.

```
P(Ŷ = 1 | Y = 1, A = 0) = P(Ŷ = 1 | Y = 1, A = 1)  -- equal TPR
P(Ŷ = 1 | Y = 0, A = 0) = P(Ŷ = 1 | Y = 0, A = 1)  -- equal FPR
```

**Mortgage interpretation:** Qualified applicants of all races have an equal chance of being approved (equal TPR), and unqualified applicants of all races have an equal chance of being denied (equal FPR). This is the most legally defensible fairness criterion for credit models.

### Equal Opportunity

A relaxed version of equalized odds: only require equal TPR (qualified borrowers of all groups get approved at equal rates). Does not require equal FPR.

### Counterfactual Fairness

A model is counterfactually fair if, for an individual borrower, changing only their protected class attribute (race, sex) while holding all causally independent features constant would not change the model's output.

**This is the most legally meaningful definition for disparate treatment** but also the hardest to operationalize because it requires a causal model of the feature generation process.

### Individual Fairness

Similar individuals (in terms of creditworthiness-relevant features) should receive similar outcomes, regardless of protected class membership.

---

## Disparate Impact Analysis

### The 4/5ths (80%) Rule

Originally from EEOC employment guidance, widely applied in credit disparate impact analysis:

```
Disparate Impact Ratio = (Approval Rate for Protected Group) / (Approval Rate for Highest Group)

If ratio < 0.80 → disparate impact prima facie established
```

**Example:**
- White applicant approval rate: 72%
- Black applicant approval rate: 51%
- DI ratio = 51/72 = 0.708 → Below 0.80 → Disparate impact present

The 4/5ths rule is a screening threshold, not a legal standard. A ratio below 0.80 triggers investigation; the institution must then demonstrate business necessity and evaluate less discriminatory alternatives.

### Statistical Tests for Disparate Impact

Beyond the 4/5ths rule, proper disparate impact analysis uses:

- **Z-test / Chi-square test for proportions**: Tests whether approval rate differences are statistically significant
- **Logistic regression analysis**: Controls for legitimate credit factors; tests whether protected class membership is a significant predictor of outcome after controlling for creditworthiness
- **Matched pair testing (mystery shopping)**: Sends matched applicant profiles (identical credit profiles, different protected class signals) through the model to test for different outputs

---

## Proxy Variables and Redlining

A variable is a **proxy** for a protected class if it is highly correlated with that class. Using a proxy in a model may constitute disparate treatment even if the actual protected class is not an explicit input.

**Common proxies in mortgage ML:**

| Proxy Variable | Protected Class Correlation | Mechanism |
|---|---|---|
| Census tract / zip code | Race (due to residential segregation) | Redlining replicated digitally |
| Property value | Race, national origin | Historical undervaluation of minority-neighborhood properties |
| Credit score | Race (due to measurement bias in credit scoring) | Using the proxy of a proxy |
| Surname (for NLP models) | Race, national origin, sex | Direct proxy signal |
| Language preference | National origin | Explicit proxy |
| Income type (W-2 vs. 1099) | National origin (gig economy over-representation) | Indirect proxy |

**In practice:** Nearly every potentially predictive feature in mortgage data has some correlation with a protected class. The question is whether the correlation serves a legitimate credit risk function or merely reproduces historical discrimination. A SHAP analysis that shows geographic or neighborhood features dominating model decisions is a red flag requiring investigation.

---

## Snowflake: HMDA-Based Disparate Impact Analysis

```sql
-- Build a disparate impact report from loan application data
-- structured similarly to HMDA LAR (Loan Application Register)

CREATE OR REPLACE TABLE FAIR_LENDING.ANALYSIS.DI_ANALYSIS AS
WITH application_summary AS (
    SELECT
        applicant_race_category,
        applicant_ethnicity_category,
        applicant_sex,
        loan_purpose,
        loan_type,
        COUNT(*)                                          AS total_applications,
        SUM(CASE WHEN action_taken = 1 THEN 1 ELSE 0 END) AS approvals,
        SUM(CASE WHEN action_taken = 3 THEN 1 ELSE 0 END) AS denials,
        AVG(applicant_income)                             AS avg_income,
        AVG(combined_loan_to_value_ratio)                 AS avg_cltv,
        AVG(debt_to_income_ratio)                         AS avg_dti
    FROM FAIR_LENDING.SOURCE.LOAN_APPLICATIONS
    WHERE action_taken IN (1, 2, 3)  -- originated, approved not accepted, denied
      AND derived_loan_product_type = 'Conventional:First Lien'
      AND applicant_race_category IS NOT NULL
      AND calendar_year = 2024
    GROUP BY 1, 2, 3, 4, 5
),
approval_rates AS (
    SELECT
        *,
        ROUND(approvals / NULLIF(total_applications, 0) * 100, 2) AS approval_rate_pct
    FROM application_summary
),
control_group AS (
    -- White non-Hispanic as the reference group (highest approval rate group)
    SELECT approval_rate_pct AS reference_rate
    FROM approval_rates
    WHERE applicant_race_category = 'White'
      AND applicant_ethnicity_category = 'Not Hispanic or Latino'
      AND loan_purpose = '1'  -- home purchase
    LIMIT 1
)
SELECT
    ar.*,
    cg.reference_rate,
    ROUND(ar.approval_rate_pct / NULLIF(cg.reference_rate, 0), 4) AS di_ratio,
    CASE
        WHEN ar.approval_rate_pct / NULLIF(cg.reference_rate, 0) < 0.80 THEN 'DISPARATE IMPACT'
        WHEN ar.approval_rate_pct / NULLIF(cg.reference_rate, 0) < 0.90 THEN 'MONITOR'
        ELSE 'ACCEPTABLE'
    END AS di_flag
FROM approval_rates ar
CROSS JOIN control_group cg
ORDER BY di_ratio ASC;


-- Logistic regression control analysis setup
-- Export this dataset for Python regression analysis
CREATE OR REPLACE VIEW FAIR_LENDING.ANALYSIS.REGRESSION_INPUT AS
SELECT
    action_taken_binary,                   -- 1 = approved, 0 = denied
    applicant_race_category,
    applicant_ethnicity_category,
    applicant_sex,
    ROUND(applicant_income / 10000) * 10000 AS income_bucket,  -- generalized income
    combined_loan_to_value_ratio,
    debt_to_income_ratio,
    credit_score_applicant,
    loan_amount,
    loan_purpose,
    property_state,
    -- census_tract excluded from regression input to avoid geographic proxy confounding
FROM FAIR_LENDING.SOURCE.LOAN_APPLICATIONS
WHERE action_taken IN (1, 2, 3)
  AND applicant_race_category IS NOT NULL
  AND calendar_year = 2024;


-- Geographic concentration analysis (redlining proxy detection)
SELECT
    census_tract,
    majority_minority_tract_flag,  -- flag from ACS census data join
    COUNT(*) AS total_applications,
    AVG(CASE WHEN action_taken = 1 THEN 1.0 ELSE 0.0 END) AS approval_rate,
    AVG(combined_loan_to_value_ratio) AS avg_cltv,
    AVG(debt_to_income_ratio) AS avg_dti,
    AVG(credit_score_applicant) AS avg_credit_score
FROM FAIR_LENDING.SOURCE.LOAN_APPLICATIONS la
JOIN FAIR_LENDING.REFERENCE.CENSUS_TRACT_DEMOGRAPHICS ct
    ON la.census_tract = ct.tract_id
WHERE calendar_year = 2024
GROUP BY 1, 2
HAVING COUNT(*) >= 10  -- minimum count for statistical meaningfulness
ORDER BY approval_rate ASC;
```

---

## Python: Fairlearn for Bias Analysis

```python
"""
Fairness analysis on a mortgage credit model using Microsoft Fairlearn.
Assesses equalized odds and demographic parity across racial groups.
"""

import pandas as pd
import numpy as np
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import LabelEncoder
from lightgbm import LGBMClassifier
from fairlearn.metrics import (
    MetricFrame,
    demographic_parity_difference,
    demographic_parity_ratio,
    equalized_odds_difference,
    false_positive_rate,
    true_positive_rate,
    selection_rate,
)
from fairlearn.postprocessing import ThresholdOptimizer
from fairlearn.reductions import ExponentiatedGradient, EqualizedOdds
import matplotlib.pyplot as plt
import warnings
warnings.filterwarnings("ignore")


def load_mortgage_data(snowflake_conn) -> pd.DataFrame:
    """Load HMDA-structured loan application data from Snowflake."""
    query = """
        SELECT
            action_taken_binary,
            applicant_race_simplified,
            credit_score_applicant,
            combined_loan_to_value_ratio,
            debt_to_income_ratio,
            applicant_income_000s,
            loan_amount_000s,
            loan_purpose,
            lien_status
        FROM FAIR_LENDING.ANALYSIS.REGRESSION_INPUT
        WHERE credit_score_applicant IS NOT NULL
          AND debt_to_income_ratio IS NOT NULL
    """
    return pd.read_sql(query, snowflake_conn)


def preprocess_data(df: pd.DataFrame):
    """
    Prepare features and sensitive attribute.
    Returns X (features), y (labels), sensitive_features.
    """
    # Sensitive attribute: race (used for fairness analysis, NOT as a model feature)
    sensitive_features = df["applicant_race_simplified"]

    # Model features (no race, no obvious proxies for initial baseline)
    feature_cols = [
        "credit_score_applicant",
        "combined_loan_to_value_ratio",
        "debt_to_income_ratio",
        "applicant_income_000s",
        "loan_amount_000s",
    ]

    # Encode categorical features
    for col in ["loan_purpose", "lien_status"]:
        if col in df.columns:
            le = LabelEncoder()
            df[col + "_encoded"] = le.fit_transform(df[col].astype(str))
            feature_cols.append(col + "_encoded")

    X = df[feature_cols].fillna(df[feature_cols].median())
    y = df["action_taken_binary"]

    return X, y, sensitive_features


def baseline_fairness_report(y_true, y_pred, sensitive_features) -> pd.DataFrame:
    """
    Generate a MetricFrame fairness report across all racial groups.
    """
    metrics = {
        "approval_rate": selection_rate,
        "true_positive_rate": true_positive_rate,
        "false_positive_rate": false_positive_rate,
    }

    mf = MetricFrame(
        metrics=metrics,
        y_true=y_true,
        y_pred=y_pred,
        sensitive_features=sensitive_features,
    )

    print("=== Fairness Report by Race ===")
    print(mf.by_group.round(4))
    print()

    # 4/5ths rule
    approval_rates = mf.by_group["approval_rate"]
    reference_rate = approval_rates.max()
    print("=== Disparate Impact Analysis (4/5ths Rule) ===")
    di_results = []
    for group, rate in approval_rates.items():
        di_ratio = rate / reference_rate
        status = "DISPARATE IMPACT" if di_ratio < 0.80 else ("MONITOR" if di_ratio < 0.90 else "OK")
        di_results.append({
            "race_group": group,
            "approval_rate": round(rate, 4),
            "di_ratio": round(di_ratio, 4),
            "status": status,
        })
        print(f"  {group}: approval={rate:.3f}, DI ratio={di_ratio:.3f} [{status}]")

    print()
    print(f"Demographic Parity Difference: {demographic_parity_difference(y_true, y_pred, sensitive_features=sensitive_features):.4f}")
    print(f"Demographic Parity Ratio:      {demographic_parity_ratio(y_true, y_pred, sensitive_features=sensitive_features):.4f}")
    print(f"Equalized Odds Difference:     {equalized_odds_difference(y_true, y_pred, sensitive_features=sensitive_features):.4f}")

    return pd.DataFrame(di_results)


def train_fair_model_in_processing(X_train, y_train, sensitive_train):
    """
    In-processing mitigation: ExponentiatedGradient with EqualizedOdds constraint.
    Trains a model that explicitly minimizes equalized odds disparity.
    """
    base_estimator = LGBMClassifier(
        n_estimators=200, max_depth=5, learning_rate=0.05,
        random_state=42, verbose=-1
    )

    fair_model = ExponentiatedGradient(
        estimator=base_estimator,
        constraints=EqualizedOdds(),
        eps=0.01,   # tolerance on fairness constraint
    )

    fair_model.fit(X_train, y_train, sensitive_features=sensitive_train)
    return fair_model


def postprocess_with_threshold_optimizer(base_model, X_train, y_train, sensitive_train):
    """
    Post-processing mitigation: ThresholdOptimizer.
    Finds different decision thresholds per group to equalize odds.
    This is the most auditable approach for regulatory review.
    """
    optimizer = ThresholdOptimizer(
        estimator=base_model,
        constraints="equalized_odds",
        objective="accuracy_score",
        predict_method="predict_proba",
    )
    optimizer.fit(X_train, y_train, sensitive_features=sensitive_train)
    return optimizer


def compute_disparate_impact_ratio(approval_rates: dict, reference_group: str) -> pd.DataFrame:
    """
    Manual disparate impact calculation for regulatory documentation.
    Returns a DataFrame suitable for compliance reporting.
    """
    reference_rate = approval_rates.get(reference_group, 0)
    rows = []
    for group, rate in approval_rates.items():
        di_ratio = rate / reference_rate if reference_rate > 0 else 0
        rows.append({
            "group": group,
            "approval_rate": round(rate, 4),
            "reference_group": reference_group,
            "reference_rate": round(reference_rate, 4),
            "di_ratio": round(di_ratio, 4),
            "four_fifths_flag": di_ratio < 0.80,
        })
    return pd.DataFrame(rows).sort_values("di_ratio")


# Full pipeline
if __name__ == "__main__":
    # Using sample data to demonstrate structure
    np.random.seed(42)
    n = 10000

    # Simulate HMDA-style data with embedded disparity
    race_groups = np.random.choice(
        ["White", "Black or African American", "Hispanic", "Asian", "Other"],
        p=[0.62, 0.13, 0.11, 0.06, 0.08], size=n
    )

    credit_scores = np.where(
        race_groups == "White", np.random.normal(710, 60, n),
        np.random.normal(680, 70, n)  # artificial disparity for demo
    ).clip(300, 850)

    dti = np.random.normal(36, 10, n).clip(0, 65)
    ltv = np.random.normal(80, 15, n).clip(20, 105)
    income = np.random.normal(90, 40, n).clip(20, 500)

    # Approval: credit_score + dti + ltv driven, with some group disparity
    approval_prob = (
        0.3 * (credit_scores - 300) / 550
        - 0.3 * (dti / 65)
        - 0.2 * (ltv / 105)
        + 0.2 * (income / 500)
    )
    y = (approval_prob + np.random.normal(0, 0.1, n) > 0.1).astype(int)

    df = pd.DataFrame({
        "credit_score_applicant": credit_scores,
        "debt_to_income_ratio": dti,
        "combined_loan_to_value_ratio": ltv,
        "applicant_income_000s": income,
        "loan_amount_000s": np.random.normal(350, 150, n).clip(50, 1500),
        "applicant_race_simplified": race_groups,
        "action_taken_binary": y,
    })

    X, y_labels, sensitive = preprocess_data(df)
    X_train, X_test, y_train, y_test, s_train, s_test = train_test_split(
        X, y_labels, sensitive, test_size=0.2, random_state=42
    )

    # Train baseline model
    baseline_model = LGBMClassifier(n_estimators=200, max_depth=5, random_state=42, verbose=-1)
    baseline_model.fit(X_train, y_train)
    y_pred_baseline = baseline_model.predict(X_test)

    print("=== BASELINE MODEL ===")
    di_report = baseline_fairness_report(y_test, y_pred_baseline, s_test)

    # Train fair model with in-processing
    print("\n=== FAIR MODEL (ExponentiatedGradient + EqualizedOdds) ===")
    fair_model = train_fair_model_in_processing(X_train, y_train, s_train)
    y_pred_fair = fair_model.predict(X_test, sensitive_features=s_test)
    _ = baseline_fairness_report(y_test, y_pred_fair, s_test)
```

---

## SHAP for Proxy Variable Detection

```python
"""
Use SHAP to detect whether proxy variables (zip code, census tract)
are driving model decisions — a potential fair lending violation.
"""

import shap
import pandas as pd
import matplotlib.pyplot as plt
from lightgbm import LGBMClassifier


def detect_proxy_variables(model, X: pd.DataFrame,
                           protected_proxies: list[str]) -> pd.DataFrame:
    """
    Compute SHAP values and report the contribution of potential proxy variables.
    A proxy variable with high mean |SHAP| warrants legal review.
    """
    explainer = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(X)

    # For binary classification, shap_values may be a list [class0, class1]
    if isinstance(shap_values, list):
        shap_vals = shap_values[1]  # use positive class
    else:
        shap_vals = shap_values

    shap_df = pd.DataFrame(
        np.abs(shap_vals),
        columns=X.columns
    )

    mean_shap = shap_df.mean().sort_values(ascending=False)
    total_shap = mean_shap.sum()

    proxy_report = []
    for col in mean_shap.index:
        proxy_report.append({
            "feature": col,
            "mean_abs_shap": round(mean_shap[col], 4),
            "pct_of_total": round(mean_shap[col] / total_shap * 100, 2),
            "is_proxy_variable": col in protected_proxies,
            "flag": "REVIEW REQUIRED" if col in protected_proxies and
                    mean_shap[col] / total_shap > 0.05 else "OK"
        })

    report = pd.DataFrame(proxy_report)
    print(report[report["is_proxy_variable"]].to_string())
    return report


# Define known proxy variables for mortgage model
PROXY_VARIABLES = [
    "census_tract",
    "zip_code",
    "neighborhood_median_income",  # proxy for race due to residential segregation
    "school_district_rating",       # proxy for neighborhood demographics
    "distance_to_cbsa_center",      # correlates with minority suburban areas
]
```

---

## Bias Mitigation Techniques

### Pre-Processing: Resampling and Re-Weighting

Modify the training data before model training to correct imbalances.

**Resampling strategies:**
- Oversample under-represented protected groups
- Undersample the majority group
- SMOTE (Synthetic Minority Oversampling) to generate synthetic examples for under-represented groups

**Re-weighting:**
- Assign higher sample weights to under-represented groups during training
- Useful when resampling would create too many duplicates in small groups

**Regulatory note:** Pre-processing techniques are the most auditable and explainable to regulators. You can point to the training data composition as evidence of intentional fairness engineering.

### In-Processing: Fairness Constraints During Training

Modify the learning algorithm to include a fairness constraint in the objective function.

- **ExponentiatedGradient (Fairlearn)**: Reduces fair classification to a sequence of cost-sensitive classification problems
- **Adversarial Debiasing**: Add an adversary network that tries to predict the protected class from the model's output — train the model to minimize prediction loss while maximizing the adversary's error
- **Prejudice Remover (Kamishima)**: Adds a fairness-aware regularization term to logistic regression

### Post-Processing: Threshold Adjustment

After training a standard model, adjust the decision threshold differently for different groups to achieve a fairness objective.

**ThresholdOptimizer (Fairlearn)** finds the optimal per-group thresholds that:
- Satisfy an equalized odds or demographic parity constraint
- Maximize accuracy subject to the constraint

**This is the most commonly used approach in production mortgage models** because:
1. The base model can be trained and validated normally
2. The threshold adjustment is transparent, auditable, and easily explained to regulators
3. Adverse action codes can be calibrated to the adjusted thresholds

---

## Adverse Action Codes and Model Explainability

Under ECOA (Regulation B), when credit is denied or terms are offered less favorably, the institution must provide specific reasons. For ML models, this requires mapping model outputs to adverse action codes.

**Standard adverse action reasons (Reg B):**
- Debt-to-income ratio too high
- Insufficient collateral
- Too many accounts with adverse payment history
- Insufficient credit history
- Employment record/income insufficient

**For ML models:** SHAP values provide the per-applicant feature contributions needed to generate adverse action codes. The top 4 negative SHAP contributors map to the 4 required adverse action reasons.

```python
def generate_adverse_action_codes(
    shap_values_row: np.ndarray,
    feature_names: list[str],
    code_mapping: dict[str, str]
) -> list[str]:
    """
    Map SHAP values to Reg B adverse action reason codes.
    Returns top 4 negative factors (features that reduced approval probability).
    """
    feature_shap = dict(zip(feature_names, shap_values_row))

    # Negative SHAP values hurt the approval decision
    negative_factors = {k: v for k, v in feature_shap.items() if v < 0}
    top_4 = sorted(negative_factors.items(), key=lambda x: x[1])[:4]

    codes = []
    for feature, shap_val in top_4:
        if feature in code_mapping:
            codes.append(code_mapping[feature])
        else:
            codes.append(f"UNMAPPED: {feature}")  # flag for compliance review

    return codes


# Mapping from feature names to standard adverse action codes
ADVERSE_ACTION_CODE_MAP = {
    "debt_to_income_ratio":             "AA-01: Debt-to-income ratio",
    "combined_loan_to_value_ratio":     "AA-02: Insufficient collateral/LTV",
    "credit_score_applicant":           "AA-03: Credit score insufficient",
    "derogatory_count":                 "AA-04: Derogatory credit history",
    "applicant_income_000s":            "AA-05: Insufficient income",
    "months_employed":                  "AA-06: Insufficient employment history",
    "available_credit_utilization":     "AA-07: Excessive obligations",
}
```

---

## Model Validation for Fair Lending

The OCC and Federal Reserve expect institutions to validate models for fair lending as part of SR 11-7 model risk management. A fair lending validation includes:

| Validation Element | What to Test |
|---|---|
| Disparate Impact Analysis | 4/5ths rule, regression-based analysis by all protected classes |
| Proxy Variable Screen | SHAP-based identification of geographic/demographic proxies |
| Adverse Action Code Validation | Confirm SHAP-based codes are correct and explainable |
| Population Stability by Group | Confirm model performs equally well across groups in production |
| Through-the-Cycle Testing | Confirm disparity does not worsen under economic stress scenarios |
| Least Discriminatory Alternative | Document that no equally accurate model produces lower disparities |

---

## Interview Q&A

**Q1: What is disparate impact and how would you detect it in a mortgage approval model?**

A: Disparate impact refers to a neutral policy or practice that disproportionately disadvantages members of a protected class, even without discriminatory intent. In mortgage lending, it is actionable under both the Fair Housing Act (confirmed by SCOTUS in Inclusive Communities, 2015) and ECOA. To detect it, I start with the 4/5ths rule: compute approval rates for each protected racial and ethnic group, then divide each group's approval rate by the highest group's rate. Any group below 80% triggers further investigation. But the 4/5ths rule is just a screening tool. The proper analysis is a regression-based approach: run a logistic regression of loan approval on legitimate credit factors (credit score, DTI, LTV, income), then test whether the protected class variables add statistically significant explanatory power after controlling for those factors. If the coefficient on race is significant, that suggests the model is producing outcomes that cannot be explained by credit factors alone. I would run this in Python (statsmodels logit or sklearn) on data pulled from Snowflake and report the odds ratios with confidence intervals.

**Q2: A product manager says adding census tract as a feature will improve model accuracy by 3%. How do you respond?**

A: I raise it as a potential fair lending violation before it gets anywhere near production. Census tract is the classic redlining proxy: because of decades of residential segregation, census tract is highly correlated with race. If the model uses census tract as a feature, it is making credit decisions based on a variable that proxies for race — which is disparate treatment under ECOA and the FHA regardless of intent. The 3% accuracy improvement likely reflects the model learning the historically discriminatory pattern in the data, not a legitimate credit risk signal. I would ask: does census tract capture something about property value risk or economic conditions that isn't already captured by LTV, appraisal value, or MSA-level economic indicators? If the answer is yes, I would want to see a SHAP analysis proving the feature is not simply functioning as a race proxy. If it cannot be distinguished, it does not go in the model. I would escalate to legal and compliance and document the decision, because this is exactly the scenario that leads to a CFPB examination finding.

**Q3: What is the difference between equalized odds and demographic parity, and which is more appropriate for a mortgage credit model?**

A: Demographic parity requires that approval rates are equal across groups regardless of actual creditworthiness. Equalized odds requires that both the true positive rate (qualified applicants who are approved) and the false positive rate (unqualified applicants who are approved) are equal across groups. For mortgage credit decisioning, equalized odds is the more appropriate and legally defensible standard. Demographic parity effectively requires approving applicants from some groups who would otherwise be denied on credit grounds, which creates fair lending risk in the opposite direction (reverse discrimination claims) and safety-and-soundness concerns. Equalized odds says: given that an applicant is truly creditworthy, they have the same chance of being approved regardless of race — and given that an applicant is truly not creditworthy, they have the same chance of being denied regardless of race. This maps directly to the ECOA principle that credit decisions must be based on creditworthiness, not protected class. The ThresholdOptimizer in Fairlearn implements post-processing equalized odds mitigation, which is the most practical approach for a production mortgage model.

**Q4: Your audit team is asking for documentation of the fairness analysis you performed on a new default prediction model. What does that documentation include?**

A: The fairness analysis documentation for a model risk management review covers: (1) Data representation analysis — what is the demographic composition of the training, validation, and test sets by race, ethnicity, sex, and age band? Were any groups excluded or severely under-represented? (2) Disparate impact analysis — 4/5ths rule results for all protected classes, with sample sizes and statistical significance tests; regression-based analysis controlling for credit factors; (3) Proxy variable screen — SHAP-based analysis of geographic and demographic proxies; documentation of features that were considered and excluded due to proxy concerns; (4) Adverse action code validation — confirmation that SHAP-based adverse action codes map to legitimate, explainable credit factors and do not include protected class signals; (5) Fairness metric report — demographic parity difference, equalized odds difference, true/false positive rates by group using MetricFrame; (6) Mitigation actions — if disparity was found, what mitigation was applied (resampling, threshold adjustment) and what was the effect on disparity and accuracy; (7) Least discriminatory alternative analysis — documentation that no reasonably accurate alternative model produces materially lower disparities; (8) Ongoing monitoring plan — how will disparate impact be monitored in production, at what frequency, and what triggers a model review.

**Q5: What is HMDA data and how do you use it for bias analysis?**

A: HMDA stands for Home Mortgage Disclosure Act. It requires covered lenders to collect and publicly report loan-level data on every mortgage application they receive. The public HMDA LAR (Loan Application Register) includes loan amount, property location (census tract), applicant race, ethnicity, and sex, income, action taken (approved, denied, withdrawn), credit score range, DTI, and LTV (since 2018 modernization). As a data engineer in the secondary market, I use HMDA data in several ways: First, as the base dataset for fair lending analysis on my own institution's lending — the HMDA data I file is the same structure I use for internal disparate impact analysis. Second, to benchmark my institution's denial rates against peer institutions — if my approval rate for Black applicants is 15 points below peers with similar portfolios, that warrants investigation. Third, in Snowflake, I join HMDA LAR data with Census Bureau ACS data (median income, racial composition by tract) to create the geographic context needed for redlining analysis. The FFIEC makes HMDA data publicly available annually; I typically load it to a Snowflake stage, parse the fixed-width or CSV format, and join it to our internal loan data by institution respondent ID.

**Q6: What is the Least Discriminatory Alternative doctrine and how does it apply to AI models?**

A: The Least Discriminatory Alternative (LDA) doctrine, established in Griggs v. Duke Power and applied to lending by the CFPB and DOJ, holds that even when a policy has a legitimate business justification, an institution must use the least discriminatory means available to achieve that business purpose. Applied to AI/ML models, this means: if your model produces disparate impact, you must demonstrate that you could not have achieved equivalent predictive accuracy with a model that produces materially lower disparities. This is a significant obligation because it means fair lending compliance is not just about passing the 4/5ths rule — you must actively compare your model to alternatives. In practice, I document this by: (1) training candidate models with different feature sets (with and without proxy variables), (2) applying fairness mitigation (ExponentiatedGradient, ThresholdOptimizer) and comparing accuracy vs. baseline, (3) documenting the accuracy-fairness tradeoff for each candidate, (4) selecting the model that minimizes disparate impact subject to meeting the business's minimum accuracy requirement, and (5) storing all of this analysis in the model documentation for regulatory review.

**Q7: How would you monitor a credit model for fair lending drift in production?**

A: Fair lending monitoring in production requires tracking the same metrics used in validation, at regular intervals, with defined alert thresholds. Specifically: (1) Monthly disparate impact reports — approval rates by race/ethnicity/sex with 4/5ths rule flagging, using the same Snowflake query structure as the pre-deployment analysis; (2) Population stability index (PSI) by group — detect if the demographic composition of applicants or the score distribution within groups is shifting; (3) SHAP-based monitoring — periodically recompute SHAP values on a recent sample to confirm no feature is gaining unexpected importance; (4) Adverse action code distribution by group — confirm that the distribution of denial reasons is similar across groups (a sudden concentration of one reason in one group can signal a model shift); (5) Outcome analysis — as loans season, compare default rates by group to confirm the model's risk ranking is equally valid across groups (a group with equal approval rates but higher actual defaults signals the model is either approving too many from that group or the features are calibrated differently). I would build this monitoring into a Snowflake scheduled task with output to a compliance dashboard, with alerts triggering when the DI ratio drops below 0.85 (a warning before the 0.80 threshold is breached).

**Q8: A borrower appeals a denial from your AI credit model, claiming discrimination. Walk me through the investigation.**

A: This is an adverse action appeal process. The first step is to pull the applicant's full loan application record and run it through the SHAP explainer to get the per-applicant feature contributions. This gives us the adverse action reasons — the top factors that reduced the approval probability — and confirms the model's decision was driven by legitimate credit factors. Second, we check whether the adverse action notice sent to the borrower correctly reflected those factors, as required by Reg B. Third, if the borrower alleges racial discrimination specifically, we run a counterfactual test: holding all credit factors constant, change only the race/ethnicity attribute (or its proxy signals) and observe whether the model output changes. If it does, we have a potential disparate treatment finding. Fourth, we pull a matched pair from the loan database — similar credit profile, different race — and compare model scores. Fifth, if any of these tests suggest the model behaved differently based on protected class, we escalate to legal and compliance immediately, suspend the model from making new decisions, and initiate a model review. The investigation is documented in a formal complaint file as required by the CFPB complaint management guidance. The model may require mitigation or replacement depending on findings.

**Q9: What is the CFPB's current position on AI/ML models in lending?**

A: The CFPB has been increasingly active on AI in lending. Key positions as of 2025-2026: (1) ECOA and Regulation B apply fully to AI models — no "black box" exception; adverse action notices must provide specific, accurate reasons even when the model is complex; (2) The CFPB has explicitly stated that model complexity does not excuse compliance failures — you cannot claim you cannot explain a model's decision to a borrower; (3) The CFPB's 2022 circular on adverse action notices for AI models confirmed that SHAP or similar explainability tools are acceptable methods for generating adverse action codes, but the codes must be accurate and not misleading; (4) The CFPB has signaled that it will use disparate impact theory aggressively against AI models that produce racially disparate outcomes, even without evidence of intent; (5) The Bureau has also focused on "digital redlining" — AI models that use app usage patterns, browsing behavior, or marketing algorithms to steer protected classes away from prime products toward subprime. For a secondary market firm, the practical implication is that your model validation must include fair lending analysis, your adverse action code generation must be auditable, and your ongoing monitoring must catch disparate impact before a regulatory examination does.

**Q10: How do you document a fairness analysis for a model governance committee?**

A: The model governance committee presentation for fair lending should be structured around three questions regulators will ask. First, "Is there disparate impact?" — present the 4/5ths rule results and regression-based analysis in a table with confidence intervals. Be direct about findings. If there is disparate impact, say so and explain it. Second, "Why does it exist?" — present the SHAP-based proxy variable analysis. Identify whether the disparity is driven by legitimate credit factors (the borrower pool genuinely has different risk profiles) or by proxy variables that may be capturing protected class information. Third, "What did you do about it?" — document the mitigation steps taken, the accuracy-fairness tradeoff, and the Least Discriminatory Alternative analysis. Also present the ongoing monitoring plan with defined trigger thresholds. I format this as a formal model risk management memo following SR 11-7 documentation standards, signed by the model owner, with independent validation sign-off. The committee should be approving not just the model's accuracy but its compliance profile, so the presentation must give them sufficient information to make that judgment.

---

## Pro Tips for Senior Data Engineers

1. **HMDA data is your best external benchmark — load it annually.** Pull the public HMDA LAR for your state and your institution's peer group and build a permanent Snowflake table. Your internal fair lending team will thank you, and you will have a head start when regulators ask how your denial rates compare to peers.

2. **Never use zip code or census tract directly in a credit model feature.** If you need geographic risk factors, use legitimate alternatives: MSA-level unemployment rates, county-level economic data from BLS, or property-specific appraisal data. Document why you chose these over geographic identifiers.

3. **Build SHAP computation into your model deployment pipeline.** If generating SHAP explanations is an afterthought, it will be wrong or missing when you need it most. The adverse action code generation should be tested as part of model validation, not figured out after a regulatory inquiry.

4. **The 4/5ths rule is a floor, not a ceiling.** The CFPB and DOJ have challenged models with DI ratios above 0.80 when disparities are statistically significant. Run significance tests alongside the 4/5ths calculation.

5. **Document every feature you considered and rejected.** If regulators see that you evaluated a proxy variable, considered it, and consciously excluded it with documentation of why, that is evidence of good faith. If they find a proxy you never thought to check, that is a much worse conversation.

6. **Fairness mitigation has accuracy costs — make them explicit.** The ThresholdOptimizer will reduce overall accuracy slightly to equalize outcomes across groups. This is a business decision that must be made explicitly and documented. Do not hide the accuracy cost; it is the price of compliance.

---

*Last updated: March 2026 | Part of AI in Data Engineering Interview Prep series*
