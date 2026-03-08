# AI Governance & Responsible AI

[Back to Index](README.md)

---

## Overview

AI governance is the set of policies, processes, roles, and technical controls that ensure AI systems behave safely, fairly, and in compliance with regulations. For financial institutions operating in the US secondary mortgage market, responsible AI is not optional — it is increasingly mandated by federal regulators (CFPB, OCC, FRB) and shaped by emerging frameworks like the EU AI Act and NIST AI RMF.

A senior data engineer owns the data pipelines that feed AI models, the feature stores that drive decisions, and the audit logs that regulators examine. Understanding AI governance is therefore a core engineering competency — not just a compliance concern.

---

## Key Concepts

| Concept | Description |
|---|---|
| Model Risk Management (MRM) | Framework for identifying, measuring, and controlling risks from model use |
| SR 11-7 | Federal Reserve guidance on model risk management (2011, still authoritative) |
| NIST AI RMF | NIST AI Risk Management Framework — Govern, Map, Measure, Manage |
| EU AI Act | EU regulation classifying AI systems by risk tier with compliance obligations |
| CFPB | Consumer Financial Protection Bureau — regulates AI in consumer lending decisions |
| SHAP | SHapley Additive exPlanations — game-theoretic feature attribution method |
| LIME | Local Interpretable Model-agnostic Explanations — local linear approximations |
| Model Card | Structured documentation artifact describing a model's purpose, performance, and limitations |
| Data Sheet | Documentation artifact for a dataset (provenance, collection, known biases) |
| Fairness | Statistical measures ensuring model outputs do not discriminate against protected classes |
| Adverse Action Notice | Required FCRA/ECOA notification explaining why credit was denied |

---

## Responsible AI Principles

Most leading frameworks (Google, Microsoft, NIST) converge on six principles:

| Principle | Description | Mortgage Market Relevance |
|---|---|---|
| Fairness | Model outputs are equitable across demographic groups | Fair lending compliance (ECOA, FHA) |
| Transparency | Stakeholders can understand how decisions are made | Adverse action notices, examiner reviews |
| Accountability | Clear ownership of model outcomes | MRM validation, audit trails |
| Safety | Models behave reliably, within intended operating boundaries | No flash-crash pricing, no system failures |
| Reliability | Consistent performance across data distributions | Drift detection, monitoring |
| Privacy | Personal data is protected and minimized | GLBA, state privacy laws |

---

## AI Risk Management: NIST AI RMF

The NIST AI Risk Management Framework (2023) organizes AI risk management into four core functions:

```
GOVERN → MAP → MEASURE → MANAGE
```

### GOVERN
Establish policies, roles, culture, and accountability for AI risk.
- AI ethics policy approved by board
- AI Steering Committee with cross-functional representation
- Defined roles: Model Owner, Model Validator, Model Risk Officer
- Training requirements for model developers and users

### MAP
Identify and categorize AI risks in context.
- Use case inventory: list all AI/ML models in production
- Risk classification: low / medium / high based on impact and reversibility
- Stakeholder identification: who is affected by model decisions?
- Data provenance: where does training data come from?

### MEASURE
Quantify AI risks using metrics and testing.
- Bias and fairness metrics across protected classes
- Performance metrics: AUC, RMSE, calibration
- Robustness testing: adversarial inputs, out-of-distribution behavior
- Uncertainty quantification

### MANAGE
Prioritize and treat identified risks.
- Mitigation plans for high-risk findings
- Incident response playbooks for model failures
- Retraining and retirement processes
- Escalation workflows

---

## Regulatory Landscape

### SR 11-7: Model Risk Management (Federal Reserve, 2011)

Still the foundational document for model risk management in US banks. Key requirements:

- **Model definition**: A model is "a quantitative method, system, or approach that applies statistical, economic, financial, or mathematical theories, techniques, and assumptions to process input data into quantitative estimates." This explicitly includes ML models.
- **Three lines of defense**: (1) Model developers/owners, (2) Independent model validation, (3) Internal audit.
- **Model inventory**: Institutions must maintain a complete inventory of models with risk ratings.
- **Ongoing monitoring**: Models must be monitored for performance degradation and significant changes.
- **Documentation standards**: Comprehensive documentation required for methodology, data, assumptions, limitations.

For a data engineer: every ML model in production at a regulated institution needs to be in the model inventory. You are responsible for the data lineage documentation.

### CFPB Guidance on AI in Credit Decisions

The CFPB has issued guidance (2022 circular) clarifying that:
- AI/ML models used in credit decisions are subject to ECOA and FCRA adverse action notice requirements.
- "Complex algorithms" are **not** a valid excuse for failing to provide specific reasons for adverse action.
- Creditors must be able to identify and explain the principal reasons for denial, even from black-box models.

**Implication**: Every credit model needs explainability infrastructure. SHAP or similar is not optional.

### EU AI Act: Risk Tiers

| Tier | Examples | Requirements |
|---|---|---|
| Unacceptable | Social scoring, real-time biometric surveillance in public | Prohibited entirely |
| High Risk | Credit scoring, employment decisions, critical infrastructure | Conformity assessment, human oversight, bias testing, registration |
| Limited Risk | Chatbots, deepfakes | Transparency obligations |
| Minimal Risk | Spam filters, AI in games | No mandatory requirements |

Mortgage credit scoring models qualify as **high risk** under the EU AI Act. Even US-headquartered institutions with EU operations or EU customers must comply.

---

## Model Documentation: Model Cards

A model card is a short document (typically 1-3 pages) that describes a model for non-technical stakeholders and future validators.

### Model Card Template: Mortgage Credit Scoring Model

```markdown
## Model Card: Mortgage Default Probability (MDP) Model v2.3

**Model Owner**: Credit Risk Analytics
**Last Updated**: 2025-10-01
**Status**: Production
**SR 11-7 Risk Rating**: High

### Intended Use
- **Primary use**: Predicting 90-day default probability for conventional conforming mortgage applications
- **Intended users**: Underwriting system, loan officers (advisory), secondary market pricing desk
- **Out-of-scope uses**: Jumbo loans >$2M, non-QM, commercial real estate

### Model Description
XGBoost gradient boosted tree. Input: 42 borrower and property features. Output: P(default in 90 days), range [0, 1].

### Training Data
- Source: Fannie Mae Single Family Loan Performance dataset + internal servicing history
- Time period: 2005-01-01 to 2024-06-30
- Observations: 4.2M loan-months
- Known limitations: Underrepresentation of loans originated 2022-2024 (short performance history)

### Performance Metrics
| Segment | AUC | KS Statistic | Gini |
|---|---|---|---|
| Overall | 0.812 | 0.521 | 0.624 |
| First-time homebuyers | 0.798 | 0.506 | 0.596 |
| FICO < 680 | 0.779 | 0.488 | 0.558 |
| LTV > 90% | 0.801 | 0.513 | 0.602 |

### Fairness Assessment
Disparate impact ratio (approval rate minority / approval rate majority):
- Black applicants: 0.84 (flagged for review — below 0.80 is threshold)
- Hispanic applicants: 0.91
- Female applicants: 0.97

### Explainability
Top 5 features by mean |SHAP| value:
1. credit_score_at_application (0.142)
2. ltv_at_origination (0.098)
3. dti_ratio (0.087)
4. months_employed (0.071)
5. reserves_months (0.063)

### Limitations and Risks
- Performance degrades in rapid HPI decline scenarios (training data limited post-2008 to mild corrections)
- Not validated for loans in disaster-affected areas (use manual underwrite)
- Requires retraining if unemployment rate exceeds 8% (outside training distribution)

### Monitoring
- Monthly AUC review against holdout; alert threshold: AUC drop > 0.02
- PSI monitored weekly on top 10 features; alert threshold: PSI > 0.20
```

---

## Explainability Methods

### SHAP (SHapley Additive exPlanations)

SHAP values are grounded in cooperative game theory. The SHAP value for feature `i` is its average marginal contribution across all possible feature coalitions:

```
φᵢ = Σ [|S|!(|F|-|S|-1)!/|F|!] * [f(S∪{i}) - f(S)]
      S⊆F\{i}
```

Where:
- `F` = full feature set
- `S` = subset of features
- `f(S)` = model prediction with only features in S

SHAP values sum to the difference between the prediction and the model's expected output:
```
f(x) = E[f(x)] + Σ φᵢ
```

### LIME (Local Interpretable Model-agnostic Explanations)

LIME generates a locally faithful linear approximation around a specific prediction:
1. Sample perturbations of the input instance
2. Get model predictions for each perturbation
3. Weight perturbations by proximity to original instance
4. Fit a weighted linear model
5. Use linear model coefficients as explanation

LIME is model-agnostic but less theoretically principled than SHAP. It can be unstable for similar inputs.

### Comparison

| Method | Consistency | Speed | Global / Local | Model-agnostic |
|---|---|---|---|---|
| SHAP TreeExplainer | High | Fast for trees | Both | Tree models only |
| SHAP KernelExplainer | Medium | Slow | Local | Yes |
| LIME | Low-Medium | Medium | Local | Yes |
| Feature Importance (built-in) | Medium | Very fast | Global only | No |
| Attention weights | Medium | Fast | Both | Transformers only |

---

## Python: SHAP Explanation for a Mortgage Credit Model

```python
import pandas as pd
import numpy as np
from xgboost import XGBClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score
import shap
import matplotlib.pyplot as plt
import warnings
warnings.filterwarnings("ignore")

# ── 1. Feature definitions ────────────────────────────────────────────────────
FEATURE_COLS = [
    "credit_score", "ltv", "dti", "loan_amount",
    "months_employed", "reserves_months", "property_type_code",
    "occupancy_code", "loan_purpose_code", "num_units",
    "first_time_homebuyer", "coborrower_present",
    "zip_unemployment_rate", "zip_hpi_yoy",
]
TARGET_COL = "default_90d"

# ── 2. Train model ────────────────────────────────────────────────────────────
def train_credit_model(df: pd.DataFrame):
    X = df[FEATURE_COLS].fillna(df[FEATURE_COLS].median())
    y = df[TARGET_COL]

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )

    model = XGBClassifier(
        n_estimators=500,
        learning_rate=0.05,
        max_depth=5,
        subsample=0.8,
        colsample_bytree=0.75,
        scale_pos_weight=(y_train == 0).sum() / (y_train == 1).sum(),
        eval_metric="auc",
        random_state=42,
        n_jobs=-1,
    )
    model.fit(X_train, y_train, verbose=False)

    auc = roc_auc_score(y_test, model.predict_proba(X_test)[:, 1])
    print(f"Test AUC: {auc:.4f}")
    return model, X_test, y_test

# ── 3. Global SHAP analysis ───────────────────────────────────────────────────
def global_shap_analysis(model, X_test: pd.DataFrame):
    """
    Compute SHAP values and produce summary + bar charts.
    Call in a Jupyter notebook for plots.
    """
    explainer = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(X_test)

    # Summary plot: feature importance + direction
    print("=== Global Feature Importance (SHAP Summary) ===")
    shap.summary_plot(
        shap_values, X_test,
        feature_names=FEATURE_COLS,
        plot_type="bar",
        show=False,
    )
    plt.tight_layout()
    plt.savefig("shap_global_importance.png", dpi=150)
    plt.close()

    # Beeswarm: shows direction of effect
    shap.summary_plot(shap_values, X_test, feature_names=FEATURE_COLS, show=False)
    plt.tight_layout()
    plt.savefig("shap_beeswarm.png", dpi=150)
    plt.close()

    # Return mean absolute SHAP values as a ranked DataFrame
    mean_abs_shap = pd.DataFrame({
        "feature": FEATURE_COLS,
        "mean_abs_shap": np.abs(shap_values).mean(axis=0),
    }).sort_values("mean_abs_shap", ascending=False)

    return explainer, shap_values, mean_abs_shap

# ── 4. Local explanation for a single application ────────────────────────────
def explain_single_application(
    explainer, model, application: pd.Series
) -> pd.DataFrame:
    """
    Produce SHAP-based adverse action reasons for a single loan application.
    Returns top 5 negative contributors (denial reasons).
    """
    app_df = pd.DataFrame([application[FEATURE_COLS]])
    shap_vals = explainer.shap_values(app_df)[0]
    pred_prob = model.predict_proba(app_df)[0, 1]

    explanation = pd.DataFrame({
        "feature": FEATURE_COLS,
        "value": application[FEATURE_COLS].values,
        "shap_contribution": shap_vals,
    }).sort_values("shap_contribution", ascending=False)

    print(f"\nPredicted default probability: {pred_prob:.3f}")
    print(f"Base rate (model average): {explainer.expected_value:.3f}")
    print("\nTop risk factors increasing default probability:")
    print(explanation[explanation["shap_contribution"] > 0].head(5).to_string(index=False))
    print("\nTop protective factors decreasing default probability:")
    print(explanation[explanation["shap_contribution"] < 0].head(5).to_string(index=False))

    return explanation

# ── 5. Generate adverse action notice reasons ─────────────────────────────────
def generate_adverse_action_reasons(
    explainer, model, application: pd.Series, n_reasons: int = 4
) -> list[str]:
    """
    CFPB-compliant adverse action reason generation.
    Returns human-readable top N denial reasons.
    """
    REASON_MAP = {
        "credit_score": "Insufficient credit history or low credit score",
        "ltv": "Loan-to-value ratio too high relative to guidelines",
        "dti": "Debt-to-income ratio exceeds program limits",
        "months_employed": "Insufficient employment history",
        "reserves_months": "Insufficient financial reserves",
        "zip_unemployment_rate": "Elevated unemployment in subject property location",
        "zip_hpi_yoy": "Declining home values in subject property area",
    }

    app_df = pd.DataFrame([application[FEATURE_COLS]])
    shap_vals = explainer.shap_values(app_df)[0]

    reasons_df = pd.DataFrame({
        "feature": FEATURE_COLS,
        "shap_contribution": shap_vals,
    }).sort_values("shap_contribution", ascending=False)

    # Only positive SHAP contributions increase default risk
    top_reasons = reasons_df[reasons_df["shap_contribution"] > 0].head(n_reasons)
    reasons = [
        REASON_MAP.get(row["feature"], f"Feature: {row['feature']}")
        for _, row in top_reasons.iterrows()
    ]
    return reasons

# ── 6. Fairness analysis ──────────────────────────────────────────────────────
def compute_fairness_metrics(
    model, X_test: pd.DataFrame, y_test: pd.Series, df_test: pd.DataFrame
) -> pd.DataFrame:
    """
    Compute disparate impact and approval rate by race/ethnicity.
    Threshold: 0.15 default probability → approve.
    """
    threshold = 0.15
    probs = model.predict_proba(X_test)[:, 1]
    approvals = (probs < threshold).astype(int)

    results = []
    for group in df_test["race_ethnicity"].unique():
        mask = (df_test["race_ethnicity"] == group).values
        group_approval_rate = approvals[mask].mean()
        group_auc = roc_auc_score(y_test.values[mask], probs[mask]) if mask.sum() > 50 else None
        results.append({
            "group": group,
            "n": mask.sum(),
            "approval_rate": group_approval_rate,
            "auc": group_auc,
        })

    results_df = pd.DataFrame(results)
    majority_rate = results_df[results_df["group"] == "White"]["approval_rate"].values[0]
    results_df["disparate_impact_ratio"] = results_df["approval_rate"] / majority_rate
    results_df["flag_below_80pct"] = results_df["disparate_impact_ratio"] < 0.80

    return results_df.sort_values("disparate_impact_ratio")
```

---

## Snowflake AI Governance

### Data Classification and Access Policies

```sql
-- Tag sensitive columns with governance metadata
ALTER TABLE loan_applications
    ALTER COLUMN ssn SET TAG governance.sensitivity = 'PII_HIGH';

ALTER TABLE loan_applications
    ALTER COLUMN credit_score SET TAG governance.sensitivity = 'PII_MEDIUM';

-- Column-level masking policy: only MRM team sees raw credit scores
CREATE OR REPLACE MASKING POLICY credit_score_mask AS (val NUMBER)
    RETURNS NUMBER ->
    CASE
        WHEN CURRENT_ROLE() IN ('MRM_ANALYST', 'DATA_SCIENTIST', 'SYSADMIN') THEN val
        ELSE 999   -- masked sentinel value
    END;

ALTER TABLE loan_applications
    ALTER COLUMN credit_score SET MASKING POLICY credit_score_mask;

-- Row access policy: restrict loan data to originating region
CREATE OR REPLACE ROW ACCESS POLICY region_access AS (region_code VARCHAR)
    RETURNS BOOLEAN ->
    region_code = CURRENT_USER_ATTRIBUTE('region')
    OR CURRENT_ROLE() IN ('MRM_ANALYST', 'SYSADMIN');

ALTER TABLE loan_applications
    ADD ROW ACCESS POLICY region_access ON (region_code);
```

### Audit Logging for Model Scoring

```sql
-- Log every model scoring event for audit trail
CREATE OR REPLACE TABLE model_audit_log (
    log_id          VARCHAR DEFAULT UUID_STRING(),
    log_ts          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    model_name      VARCHAR(100),
    model_version   VARCHAR(20),
    application_id  VARCHAR(50),
    requesting_user VARCHAR(100),
    requesting_role VARCHAR(100),
    input_features  VARIANT,      -- JSON snapshot of features used
    output_score    FLOAT,
    output_decision VARCHAR(20),  -- APPROVE / DENY / REFER
    adverse_reasons ARRAY,        -- SHAP-based denial reasons
    session_id      VARCHAR(100)
);

-- Insert logging in scoring stored procedure
CREATE OR REPLACE PROCEDURE score_loan_application(app_id VARCHAR)
    RETURNS OBJECT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'xgboost', 'shap')
    HANDLER = 'score_and_log'
AS
$$
def score_and_log(session, app_id):
    # Fetch features
    features_df = session.sql(f"""
        SELECT * FROM loan_application_features WHERE application_id = '{app_id}'
    """).to_pandas()

    # Score (model loaded from Snowflake Model Registry)
    score = run_model(features_df)
    decision = "APPROVE" if score < 0.15 else "DENY" if score > 0.35 else "REFER"

    # Log to audit table
    session.sql(f"""
        INSERT INTO model_audit_log
            (model_name, model_version, application_id,
             requesting_user, requesting_role,
             output_score, output_decision)
        VALUES ('MDP_MODEL', '2.3', '{app_id}',
                CURRENT_USER(), CURRENT_ROLE(),
                {score}, '{decision}')
    """).collect()

    return {"application_id": app_id, "score": score, "decision": decision}
$$;
```

---

## Azure AI Responsible AI Dashboard

Microsoft's Responsible AI Dashboard (available in Azure Machine Learning) provides an integrated UI for:

| Component | Function |
|---|---|
| Error Analysis | Identifies cohorts where model error is highest |
| Data Explorer | Visualizes feature distributions and correlations |
| Model Interpretability | Global and local SHAP explanations |
| Fairness Assessment | Disparate impact, equalized odds across sensitive groups |
| Causal Analysis | Estimates causal effects (not just correlations) |
| Counterfactual What-If | Shows minimum changes to flip a decision |

For a mortgage credit model deployed in Azure ML, the RAI dashboard can be generated with:

```python
from raiwidgets import ResponsibleAIDashboard
from responsibleai import RAIInsights

rai_insights = RAIInsights(
    model=xgb_model,
    train=X_train_df,
    test=X_test_df,
    target_column=TARGET_COL,
    task_type="classification",
    sensitive_features=["race_ethnicity", "gender"],
)

# Add components
rai_insights.explainer.add()
rai_insights.error_analysis.add()
rai_insights.fairness.add(
    sensitive_features=["race_ethnicity"],
    fairness_metrics=["disparate_impact", "equalized_odds_difference"],
)
rai_insights.counterfactual.add(total_CFs=5, desired_class="opposite")

rai_insights.compute()
ResponsibleAIDashboard(rai_insights)
```

---

## Human-in-the-Loop Workflows

For high-stakes decisions (loan denials, large balance pricing), full automation is inappropriate. Human-in-the-loop (HITL) patterns:

```
Application Received
    → ML model scores application
    → Score < 0.10: Auto-approve (no human review)
    → Score 0.10–0.25: Express review (underwriter reviews SHAP explanation, 4-hour SLA)
    → Score 0.25–0.35: Full underwrite (underwriter reviews full file, 2-day SLA)
    → Score > 0.35: Auto-decline with adverse action notice (SHAP reasons logged)
    → Edge cases flagged: (1) score near threshold ± 0.02, (2) model uncertainty > 0.05
```

The HITL workflow must be documented in the model card and validated by MRM.

---

## Interview Q&A

**Q1: What is SR 11-7 and why does it matter for ML models?**

A: SR 11-7 is the Federal Reserve's 2011 supervisory guidance on model risk management. It defines a model as any quantitative method that processes inputs into quantitative estimates — a definition that clearly encompasses ML models. The guidance requires: (1) comprehensive documentation of model development, assumptions, and limitations; (2) independent model validation by a team separate from developers; (3) ongoing monitoring for performance degradation and material changes; (4) a complete model inventory with risk ratings. For a data engineer, SR 11-7 means every ML model in production at a bank must be documented to a high standard, the data lineage must be defensible to an examiner, and feature drift must be monitored and logged. The guidance explicitly warns against over-reliance on models and requires human judgment to override model outputs when warranted.

**Q2: How do SHAP values satisfy the CFPB's adverse action notice requirement?**

A: The CFPB's 2022 circular clarified that ECOA requires creditors to provide specific, accurate reasons for adverse action even when using complex ML models. SHAP values directly address this: they decompose each model prediction into additive contributions from each feature, identifying the top factors that increased the predicted default probability for a specific applicant. These SHAP-derived reasons (e.g., "insufficient credit history," "high debt-to-income ratio") can be mapped to the CFPB's standard adverse action reason codes. The key requirements for CFPB compliance: (1) reasons must accurately reflect the actual model drivers, not generic boilerplate; (2) they must be specific to the individual applicant; (3) they must be the principal reasons, meaning highest magnitude contributors. SHAP TreeExplainer satisfies all three for tree-based models.

**Q3: What is the EU AI Act and which risk tier do mortgage credit models fall into?**

A: The EU AI Act (fully in force by 2026) is the world's first comprehensive AI regulation. It classifies AI systems into four risk tiers: unacceptable (prohibited), high risk (strict obligations), limited risk (transparency obligations), and minimal risk (no mandatory requirements). Mortgage credit scoring models fall under Annex III as high-risk AI systems used in creditworthiness assessments. High-risk obligations include: (1) conformity assessment before deployment; (2) human oversight mechanisms; (3) bias testing and fairness documentation; (4) registration in the EU AI Act database; (5) detailed technical documentation; (6) logging of system operations; (7) post-market monitoring. For a US institution with EU customers or EU operations, this applies even to US-built models.

**Q4: What is a model card and what should it contain?**

A: A model card is a short structured document — typically 1-3 pages — that transparently describes a model for validators, auditors, compliance officers, and downstream users. Key sections: (1) intended use: what problem the model solves, who uses it, what populations it was designed for; (2) out-of-scope uses: explicitly what the model should NOT be used for; (3) model description: algorithm, input features, output interpretation; (4) training data: source, time period, known limitations; (5) performance metrics: broken out by key subgroups, not just overall; (6) fairness assessment: disparate impact ratios across protected classes; (7) explainability: top features and their direction of effect; (8) limitations and risks: documented failure modes; (9) monitoring: what metrics are tracked and alert thresholds. The model card is a living document — it updates with each retraining.

**Q5: How do you detect and measure bias in a mortgage credit model?**

A: Several approaches, used in combination: (1) **Disparate impact ratio**: approval rate for a protected class divided by approval rate for the most favored group. The CFPB and ECOA use 80% (four-fifths rule) as a flag — ratios below 0.80 warrant investigation; (2) **Equalized odds**: does the model's true positive rate (correctly identifying good borrowers) and false positive rate vary by demographic group? Ideally, error rates should be similar across groups; (3) **Counterfactual fairness**: would the decision change if only protected characteristics (race, gender) changed and all else remained equal? (4) **SHAP demographic analysis**: are protected class proxies (zip code with racial composition, surname) driving decisions? (5) **Calibration by group**: is the predicted default probability calibrated (accurate) for minority borrowers who do default? Note: perfect fairness across all metrics simultaneously is mathematically impossible (Impossibility Theorem), so institutions must document the fairness metric chosen and the justification.

**Q6: What is the difference between global and local explainability?**

A: Global explainability describes the model's overall behavior — which features drive predictions in general across the entire population. Examples: mean absolute SHAP values, Gini feature importance, partial dependence plots. Local explainability describes the model's behavior for a single prediction — which features drove this specific outcome for this specific applicant. Examples: SHAP waterfall plot for one record, LIME local explanation, counterfactual ("what would need to change for this applicant to be approved?"). For adverse action notices, local explainability is required — you need to explain the specific denial, not the model in general. For MRM validation and bias testing, global explainability is the starting point. Production systems typically need both.

**Q7: How do you build an audit trail for ML scoring in Snowflake?**

A: The audit trail must capture: (1) which model version scored the record; (2) the input features at the time of scoring (snapshot — features can change over time); (3) the output score and decision; (4) who requested the score (user, role, system); (5) timestamp; (6) for adverse actions, the SHAP-derived reasons. Implementation in Snowflake: store inputs as VARIANT (JSON) in the audit log table to handle schema evolution; use a stored procedure or Snowpark UDF to atomically score and log; enable Snowflake Access History for additional query-level audit; set retention policies to meet regulatory requirements (typically 7 years for lending records). Never allow scores to be made outside the logged procedure — this is an architectural enforcement point.

**Q8: What is the NIST AI RMF and how does it compare to the EU AI Act?**

A: The NIST AI RMF (2023) is a voluntary framework for managing AI risk. It's organized around four functions: Govern (culture, policies, roles), Map (identify and categorize AI risks), Measure (quantify risks with metrics), Manage (treat, prioritize, monitor risks). It is principles-based and non-prescriptive — organizations adapt it to their context. The EU AI Act is a legally binding regulation with mandatory requirements, fines for non-compliance (up to 3% of global turnover for high-risk violations), and specific technical requirements. The two are complementary: NIST AI RMF provides the governance architecture; EU AI Act mandates specific outputs (documentation, testing, human oversight) for high-risk systems. For a US financial institution, NIST AI RMF aligns well with existing SR 11-7 model risk management frameworks.

**Q9: How do you handle the trade-off between model accuracy and interpretability in mortgage credit models?**

A: The perceived trade-off is less severe than it appears. Modern tree-based ensemble methods (XGBoost, LightGBM) combined with post-hoc SHAP explanation provide high accuracy AND interpretability. The real challenge is the audience: SHAP values satisfy regulators and validators, but loan officers need simpler explanations. Strategy: (1) develop the most accurate model you can (XGBoost, light neural net); (2) instrument it with SHAP for regulatory/validation purposes; (3) build a human-readable explanation layer for adverse action notices that maps SHAP values to standardized reason codes; (4) maintain a simpler logistic regression "shadow model" for sanity checking — if the complex model and the simple model agree directionally, you have confidence; if they diverge, investigate. The key principle from SR 11-7: you must be able to explain why the model produces its outputs, not just that it works.

**Q10: What is a data sheet and how does it differ from a model card?**

A: A data sheet (or "Datasheet for Datasets," from Gebru et al. 2018) documents a training or evaluation dataset rather than a model. Key sections: motivation (why was the dataset created?), composition (what data types, what population), collection process (how was data gathered, who consented?), preprocessing (cleaning steps, imputation decisions), uses (intended and prohibited uses), distribution (how is it shared, any licenses?), maintenance (who owns it, how is it updated?), and known biases (documented limitations). A model card documents the model; a data sheet documents the data that trained it. Both are required for a complete AI governance artifact set. For a Fannie Mae loan performance training dataset, the data sheet would document: the population (conventional conforming originations), time period, known selection effects (only originated loans, not declined applications), and any preprocessing steps that might introduce bias.

---

## Pro Tips

- **Documentation is a first-class engineering deliverable**: Every ML pipeline you build should have a data sheet for the training data and a model card for the model. Keep them in the same git repo as the model code.
- **Log inputs, not just outputs**: Regulators want to see not only what the model decided but exactly what data it saw at decision time. Store a feature snapshot in the audit log — field values can change after the fact.
- **Four-fifths rule is a floor, not a ceiling**: The 80% disparate impact ratio is a legal threshold, not an ethical target. Aim higher.
- **SHAP TreeExplainer is fast enough for production**: For XGBoost models with up to 100 features, SHAP TreeExplainer runs in milliseconds per record. There is no performance excuse for not logging explanations.
- **Independent validation is not adversarial**: MRM validators are your quality control. Engage them early in model development — they will catch issues before regulators do.
- **Snowflake Access History is your friend**: Enable it. Every query against sensitive tables is logged automatically. This satisfies a large portion of the audit trail requirement with no custom code.
- **Human-in-the-loop thresholds should be calibrated**: Set HITL thresholds using cost-benefit analysis. Sending too many files to human review creates bottlenecks; too few creates regulatory risk. Calibrate quarterly.
