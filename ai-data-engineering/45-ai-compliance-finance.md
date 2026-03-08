# AI Compliance in Financial Services

[← Back to Index](README.md)

---

## Overview

Financial services is the most heavily regulated environment for AI and machine learning in the United States. A model that predicts mortgage default is simultaneously a credit decision tool, a capital calculation input, a fair lending risk, and a source of potential consumer harm. The regulatory stack is layered: federal banking regulators (Federal Reserve, OCC, FDIC) set model risk management expectations through guidance like SR 11-7; consumer protection regulators (CFPB) set explainability requirements; and emerging frameworks like the NIST AI RMF and EU AI Act add further structure.

For a data engineer building and operating ML systems in the secondary mortgage market, compliance is not the legal team's problem — it is embedded in every data pipeline, feature store, scoring job, and model deployment decision you make.

---

## Key Regulations & Guidance

### SR 11-7 — The Foundation of U.S. Model Risk Management

Issued April 2011 by the Federal Reserve Board and the OCC (as OCC Bulletin 2011-12), SR 11-7 ("Guidance on Model Risk Management") is the most operationally significant document for ML practitioners in banking. It applies to all models used in decision-making at federally supervised institutions and their holding companies.

**Three core requirements:**

| Pillar | What It Requires | Data Engineering Implication |
|---|---|---|
| Conceptual soundness | Model design is theoretically justified and well-documented | Feature engineering decisions must be documented with rationale |
| Ongoing monitoring | Models are tracked in production; performance is measured | Automated monitoring pipelines, drift detection, logging |
| Outcomes analysis | Model outputs are compared against actual outcomes | Ground truth joins, performance backtests, results stored |

**Definition of "model" under SR 11-7:**
> A quantitative method, system, or approach that applies statistical, economic, financial, or mathematical theories, techniques, and assumptions to process input data into quantitative estimates.

This definition is deliberately broad. Rule-based systems, scorecards, and increasingly LLM-based decision tools fall under its scope if they are used in a material decision.

### OCC 2011-12

The OCC's parallel issuance of SR 11-7 for nationally chartered banks. Substantively identical; the key difference is the enforcement authority: OCC examines national banks directly and can issue MRAs (Matters Requiring Attention) and MRIAs (Matters Requiring Immediate Attention) for model risk management deficiencies.

### CFPB AI Guidelines for Consumer Lending

The CFPB has published guidance and issued enforcement actions focused on:

- **Adverse action notices (ECOA / Regulation B):** Any denial or adverse action based on a credit model must include specific, accurate reasons. "Black box" models that cannot produce interpretable reason codes are legally non-compliant for consumer lending decisions.
- **Fair lending / disparate impact:** Models that produce discriminatory outcomes, even without discriminatory intent, violate the Fair Housing Act and Equal Credit Opportunity Act. CFPB examiners use statistical testing (e.g., matched-pair analysis) to detect this.
- **Explainability for AI:** CFPB has explicitly stated that a lender cannot rely on a third-party vendor's proprietary model as justification for an adverse action. The lender must be able to explain the decision.

### FINRA AI Guidance

For investment firms, FINRA has issued guidance (Regulatory Notice 20-17 and subsequent communications) requiring:
- Documentation of AI model governance processes
- Supervision of algorithmic trading and recommendation systems
- Disclosure obligations when AI is used in customer-facing recommendations

### Basel III/IV — Model Use in Capital Calculations

Under Basel III's Internal Ratings-Based (IRB) approach, banks use internal models to calculate credit risk capital requirements. These models must be validated by an independent function, approved by regulators, and subject to ongoing monitoring. Basel IV has tightened the output floor, reducing but not eliminating the role of internal models.

**Key implication:** Models used in regulatory capital calculations face a higher validation bar than internal management models. Data quality, lineage, and auditability requirements are more stringent.

---

## Model Risk Management (MRM) Framework

A compliant MRM framework follows a four-phase lifecycle:

```
  ┌─────────────────────────────────────────────────────────────────┐
  │  1. IDENTIFICATION     2. MEASUREMENT    3. MONITORING           │
  │  ─────────────────     ─────────────     ─────────────           │
  │  Model inventory       Validation        Production monitoring   │
  │  Risk tiering          Backtesting       Drift detection         │
  │  Ownership assignment  Sensitivity       Performance reporting   │
  │                        analysis          Ongoing validation      │
  │                                                                   │
  │  4. CONTROL                                                       │
  │  ─────────                                                        │
  │  Limits on model use   Approval workflow   Escalation procedures │
  │  Compensating controls  Documentation      Model retirement      │
  └─────────────────────────────────────────────────────────────────┘
```

### Model Inventory and Risk Tiering

Every model must be registered in a model inventory. Risk tiers determine validation rigor and monitoring frequency:

| Tier | Risk Level | Examples | Validation Requirement |
|---|---|---|---|
| Tier 1 | High | Regulatory capital models, loan origination scoring, AML | Full independent validation, annual review |
| Tier 2 | Medium | Portfolio analytics, pricing models, operational forecasts | Targeted validation, annual or biennial review |
| Tier 3 | Low | Internal dashboards, non-decision support tools | Self-assessment, triennial review |

In practice, nearly all ML models used in mortgage origination, pricing, or servicing decisions are Tier 1 or Tier 2.

---

## Model Validation

Independent model validation is a core SR 11-7 requirement. "Independent" means the validators did not build the model and have no reporting relationship to the model developers.

### Validation Components

```
Model Validation
  ├── Conceptual review
  │     ├── Is the modeling approach appropriate for the use case?
  │     ├── Are feature selections justified with theory and data analysis?
  │     └── Is the training data representative of the intended application?
  │
  ├── Data quality review
  │     ├── Source data lineage and completeness
  │     ├── Feature engineering reproducibility
  │     └── Train/test split appropriateness
  │
  ├── Performance testing
  │     ├── Out-of-time validation (most critical for time-series data)
  │     ├── Out-of-sample validation
  │     └── Stress testing (recessionary scenarios)
  │
  ├── Sensitivity analysis
  │     ├── Feature importance and direction of effect
  │     ├── Partial dependence plots
  │     └── Boundary condition testing
  │
  └── Outcomes analysis (ongoing)
        ├── Periodic backtesting against actual outcomes
        ├── Subpopulation performance analysis (fair lending)
        └── Model use constraint compliance
```

### Out-of-Time Validation in Mortgage Context

```python
import pandas as pd
from sklearn.metrics import roc_auc_score

def out_of_time_validation(
    df: pd.DataFrame,
    date_col: str,
    target_col: str,
    score_col: str,
    train_cutoff: str,
    validation_windows: list[tuple]  # [(start, end), ...]
) -> pd.DataFrame:
    """
    Validate model performance across sequential time windows.
    Mirrors the out-of-time validation required by SR 11-7 model validators.

    validation_windows example: [('2022-01-01', '2022-06-30'),
                                  ('2022-07-01', '2022-12-31')]
    """
    results = []
    df[date_col] = pd.to_datetime(df[date_col])

    for window_start, window_end in validation_windows:
        window = df[
            (df[date_col] >= window_start) &
            (df[date_col] <= window_end) &
            (df[target_col].notna())
        ]
        if len(window) < 500:
            continue  # insufficient volume for stable AUC estimate

        auc = roc_auc_score(window[target_col], window[score_col])
        results.append({
            "window_start": window_start,
            "window_end":   window_end,
            "n":            len(window),
            "auc":          round(auc, 4),
            "gini":         round(2 * auc - 1, 4)
        })

    return pd.DataFrame(results)
```

---

## Explainability Requirements

### Adverse Action Notices Under ECOA / Regulation B

When a consumer credit application is denied or receives less-favorable terms, Regulation B requires:
- Written notice of the action
- Specific principal reasons (typically 2-5)
- These reasons must be accurate and meaningful

For a mortgage lending model, this means your ML model pipeline must produce interpretable reason codes per applicant. Gradient boosted trees and neural networks require post-hoc explainability methods.

```python
import shap
import xgboost as xgb
import pandas as pd

def generate_adverse_action_reasons(
    model: xgb.XGBClassifier,
    applicant_features: pd.DataFrame,
    feature_names: list[str],
    n_reasons: int = 4
) -> list[dict]:
    """
    Generate per-applicant SHAP-based adverse action reason codes.
    Required for Regulation B compliance in consumer lending.
    """
    explainer   = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(applicant_features)

    # Higher SHAP value = more contribution to high-risk score
    # Adverse action reasons = features most increasing the risk score
    reason_codes = []
    for i, row_shap in enumerate(shap_values):
        # Sort features by SHAP contribution descending (most harmful first)
        sorted_features = sorted(
            zip(feature_names, row_shap),
            key=lambda x: x[1], reverse=True
        )
        reasons = [
            {
                "rank":          rank + 1,
                "feature":       feat,
                "shap_value":    round(val, 4),
                "reason_text":   map_feature_to_reason_code(feat)
            }
            for rank, (feat, val) in enumerate(sorted_features[:n_reasons])
            if val > 0  # only include risk-increasing factors
        ]
        reason_codes.append({"applicant_index": i, "reasons": reasons})

    return reason_codes


def map_feature_to_reason_code(feature_name: str) -> str:
    """Map model feature names to Regulation B reason code language."""
    REASON_CODE_MAP = {
        "fico_score":            "Credit score insufficient based on credit history",
        "dti_ratio":             "Debt-to-income ratio too high",
        "ltv_ratio":             "Loan-to-value ratio too high",
        "delinquency_count":     "Derogatory credit history",
        "employment_months":     "Insufficient employment history",
        "liquid_reserves":       "Insufficient reserves after closing",
    }
    return REASON_CODE_MAP.get(feature_name, f"Model factor: {feature_name}")
```

---

## AI Governance Committee Structure

A mature financial institution operates an AI governance structure with the following layers:

```
Board / Risk Committee
    └── Chief Risk Officer
          └── AI Governance Committee
                ├── Model Risk Management (MRM) Team — independent validation
                ├── Data Science / AI Center of Excellence — model development
                ├── Compliance / Legal — regulatory mapping, fair lending
                ├── Internal Audit — third line of defense
                ├── IT / Data Engineering — infrastructure, data lineage
                └── Business Line Representatives — use case owners
```

**Data Engineering's role at each layer:**
- Build and maintain model training pipelines with full lineage
- Implement production monitoring infrastructure
- Provide data for model validation (out-of-time test sets, feature stores)
- Maintain audit logs for all scoring events
- Support Internal Audit with data extracts and pipeline documentation

---

## NIST AI Risk Management Framework (AI RMF)

Released January 2023. Voluntary framework organized into four core functions:

| Function | Description | Practical Action |
|---|---|---|
| GOVERN | Organizational policies, roles, accountability | Establish AI governance committee; define model ownership |
| MAP | Identify AI risks in context | Classify models by risk tier; map to regulatory requirements |
| MEASURE | Analyze and assess AI risks | Drift monitoring, bias testing, performance backtests |
| MANAGE | Prioritize and treat risks | Retraining workflows, model retirement, compensating controls |

The AI RMF aligns well with SR 11-7 and can serve as the organizing framework for institutions building out their MRM infrastructure.

---

## EU AI Act Impact on Financial Services

Effective 2024–2026 (phased implementation). Financial services AI is largely classified as **high-risk AI** under Annex III, which includes:

- AI used for creditworthiness assessment
- AI used to evaluate and classify natural persons based on social behavior or personal characteristics (scoring)
- AI used in employment and worker management

**High-risk AI requirements relevant to data engineers:**

```
Technical documentation requirements:
  ├── System architecture and data flow diagrams
  ├── Training and validation dataset descriptions
  ├── Performance metrics and accuracy thresholds
  ├── Risk management measures implemented
  └── Logging and audit trail specifications

Ongoing obligations:
  ├── Automatic logging of events for the lifetime of the system
  ├── Human oversight mechanisms
  ├── Accuracy, robustness, and cybersecurity measures
  └── Conformity assessment before deployment
```

US secondary mortgage market firms with EU operations or EU-person applicants will need to comply. Even for US-only operations, the EU AI Act is influencing emerging US state-level AI regulation.

---

## Vendor Model Risk

Third-party models (Intex for prepayment/OAS analytics, CoreLogic for AVM property valuation, FICO for credit scoring) are subject to SR 11-7's vendor model requirements.

### Vendor Model Due Diligence Checklist

| Assessment Area | What to Request | Red Flags |
|---|---|---|
| Conceptual soundness | Model documentation package, methodology whitepapers | "Proprietary" as the only answer |
| Performance evidence | Backtesting reports, out-of-time validation results | Only in-sample performance reported |
| Data provenance | Training data description, vintage, geographic coverage | Training data older than 5 years without recalibration |
| Ongoing monitoring | Vendor monitoring reports, recalibration schedule | No published monitoring cadence |
| Explainability | Feature importance, sensitivity analysis | Cannot provide any input-output analysis |
| Regulatory standing | History of regulatory review, any enforcement actions | Cannot confirm regulatory reviews have occurred |

```sql
-- Snowflake: Vendor model inventory table
CREATE TABLE governance.vendor_model_inventory (
    vendor_model_id     VARCHAR(50) PRIMARY KEY,
    vendor_name         VARCHAR(100),
    model_name          VARCHAR(200),
    model_version       VARCHAR(50),
    use_case            VARCHAR(500),
    risk_tier           VARCHAR(10),
    last_validated_date DATE,
    next_review_date    DATE,
    validation_owner    VARCHAR(100),
    regulatory_scope    ARRAY,          -- ['SR_11_7', 'ECOA', 'BASEL_IRB']
    active_flag         BOOLEAN DEFAULT TRUE,
    notes               VARCHAR(2000)
);

-- Query: models overdue for review
SELECT
    vendor_model_id,
    vendor_name,
    model_name,
    risk_tier,
    next_review_date,
    DATEDIFF(day, next_review_date, CURRENT_DATE()) AS days_overdue,
    validation_owner
FROM governance.vendor_model_inventory
WHERE active_flag = TRUE
  AND next_review_date < CURRENT_DATE()
ORDER BY days_overdue DESC;
```

---

## Snowflake Audit Logs and Compliance Features

```sql
-- Query Snowflake account usage for complete ML scoring audit trail
SELECT
    query_id,
    query_text,
    user_name,
    role_name,
    warehouse_name,
    start_time,
    end_time,
    execution_status,
    rows_produced
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD(day, -90, CURRENT_TIMESTAMP())
  AND query_text ILIKE '%scoring%'      -- ML scoring queries
  AND execution_status = 'SUCCESS'
ORDER BY start_time DESC;

-- Column-level access audit: who accessed PII features in ML pipelines
SELECT
    query_id,
    user_name,
    object_name,
    column_name,
    query_start_time
FROM snowflake.account_usage.access_history,
     LATERAL FLATTEN(input => base_objects_accessed) obj,
     LATERAL FLATTEN(input => obj.value:columns)     col
WHERE query_start_time >= DATEADD(month, -3, CURRENT_TIMESTAMP())
  AND col.value:columnName::string IN (
      'ssn_masked', 'date_of_birth', 'annual_income', 'fico_score'
  )
ORDER BY query_start_time DESC;
```

**Snowflake compliance features for ML workloads:**

| Feature | Compliance Use |
|---|---|
| `ACCESS_HISTORY` view | Column-level audit for PII in ML feature sets |
| Query history retention | 365-day default, configurable to meet examination requirements |
| Dynamic data masking | Mask SSN/DOB in feature tables accessed by scoring pipelines |
| Row access policies | Restrict geographic data access for state-specific fair lending analysis |
| Data classification | Tag sensitive columns; enforce governance policies automatically |
| Time Travel (90 days) | Reproduce any historical training dataset for validation |

---

## Building a Compliant ML Model Workflow

```
Step 1: Model Concept Approval
  ├── Business case documented
  ├── Use case mapped to regulatory requirements
  ├── Initial risk tier assessment
  └── AI governance committee pre-approval

Step 2: Data Preparation (Data Engineering Ownership)
  ├── Data lineage documented (source → feature → model input)
  ├── Training dataset snapshot versioned (DVC / Snowflake time travel)
  ├── Feature definitions documented with business logic
  ├── Bias testing on training data (demographic representation)
  └── Data quality thresholds validated and logged

Step 3: Model Development
  ├── Experiment tracking (MLflow) with full reproducibility
  ├── Model card drafted during development
  └── Explainability analysis completed (SHAP / LIME)

Step 4: Independent Validation (MRM Team)
  ├── Conceptual soundness review
  ├── Out-of-time backtesting
  ├── Fair lending analysis (disparate impact testing)
  ├── Sensitivity and stress testing
  └── Validation report issued with findings

Step 5: Deployment Gate (Data Engineering + MLOps)
  ├── Monitoring infrastructure confirmed live
  ├── Logging of all scoring decisions enabled
  ├── Adverse action reason code generation tested
  ├── Champion/challenger framework established
  └── Rollback procedure documented and tested

Step 6: Ongoing Monitoring
  ├── Daily drift monitoring (PSI, KS)
  ├── Performance backtesting on rolling vintage windows
  ├── Quarterly fair lending analysis
  ├── Annual model review cycle
  └── Issues escalated through governance committee
```

---

## Interview Q&A

**Q1: What is SR 11-7 and why does it matter for a data engineer building ML pipelines?**

SR 11-7 is the Federal Reserve's 2011 guidance on model risk management, adopted by the OCC as Bulletin 2011-12. It defines "model," establishes requirements for conceptual soundness, ongoing monitoring, and outcomes analysis, and mandates independent validation. For a data engineer, it means every ML pipeline must produce auditable artifacts: training dataset snapshots, feature definitions, scoring logs, and performance reports. If a model examiner asks "show me what data this model was trained on in Q3 2022," you need to be able to answer that question from your data infrastructure.

**Q2: A CFPB examiner asks why a mortgage applicant was denied based on your ML model. How do you respond as a data engineer?**

I'd pull the scoring log record for that applicant's loan application, retrieve the feature values that were fed to the model at score time, run SHAP values against those features using the model version that made the decision, and produce a ranked list of the top adverse factors. Those factors would be translated into Regulation B reason code language and presented to compliance. The ability to do this depends on: (1) logging all scoring inputs with a loan ID and timestamp, (2) versioning models so you know which model version scored that applicant, and (3) having the SHAP computation pipeline available retrospectively.

**Q3: How do you handle model validation requirements for a Snowflake ML Cortex model versus a custom Python XGBoost model?**

Both face the same SR 11-7 obligations, but the artifacts differ. For a custom XGBoost model: I provide the training code in version control, the training dataset snapshot (Snowflake time travel or DVC), MLflow experiment logs, feature importance outputs, and SHAP explainability analysis. For a Snowflake Cortex model (e.g., ML Functions like anomaly detection or forecasting): Snowflake is a vendor, so their model falls under vendor model risk requirements. I'd need Snowflake's documentation on their methodology, evidence of their internal validation, and I'd need to conduct my own outcomes analysis. The documentation package is different but the governance obligation is the same.

**Q4: What is disparate impact testing and how do you implement it in a data pipeline?**

Disparate impact testing checks whether a model's adverse decisions fall disproportionately on a protected class (race, sex, national origin, etc.) relative to a reference group. Under the 80% rule (the EEOC's four-fifths rule applied to lending), the adverse action rate for a protected class should be at least 80% of the adverse action rate for the most-favored group. Implementation: join model outputs to applicant demographic data (available from HMDA reporting), compute approval/denial rates by demographic group, calculate the ratio, and flag if below 0.80. I'd run this in a Snowflake scheduled task and pipe results to the fair lending compliance dashboard quarterly, with flagging for any cohort that falls below 0.80 so it can be investigated before it becomes an examination finding.

**Q5: How do you manage vendor model risk for a third-party model like Intex or CoreLogic?**

Vendor models under SR 11-7 must be treated like internal models: assessed for conceptual soundness, validated for your specific use case, and monitored in production. For Intex (which I treat as a black-box OAS/prepayment analytics engine): I request their methodology documentation annually, run parallel testing against a simpler benchmark model to identify periods of unexpected divergence, monitor the spread between Intex-generated prices and actual trade prices as a proxy performance metric, and log all uses in the model inventory with review dates. For CoreLogic AVMs: I benchmark against actual sales data in our footprint and run disparate impact testing on the AVM's accuracy by geography and property type.

**Q6: Explain the EU AI Act's high-risk classification and its implications for a US mortgage company.**

The EU AI Act classifies AI systems used for creditworthiness assessment as high-risk, triggering requirements for conformity assessments, technical documentation, logging, human oversight mechanisms, and accuracy/robustness guarantees. A US secondary mortgage market firm is affected if it has EU operations, services EU-person loans (RMBS with EU investor disclosure obligations), or employs the covered AI systems. Even without direct EU nexus, the EU AI Act is the harbinger of US state-level AI regulation — New York, California, and Colorado have already moved in this direction. Firms building compliant documentation infrastructure for EU AI Act will have a head start when US equivalents arrive.

**Q7: What documentation must a data engineer produce as part of a model development package?**

At minimum under SR 11-7 and good practice: (1) Data specification: sources, extraction queries, date ranges, applied filters, record counts, and known data quality issues. (2) Feature engineering specification: every transformation applied to raw data with business rationale. (3) Training run artifacts: the exact training dataset (or reference to its versioned snapshot), hyperparameters, library versions, hardware configuration, and seed values for reproducibility. (4) Performance metrics: in-sample, out-of-sample, and out-of-time AUC/Gini/KS with population sizes. (5) Explainability analysis: SHAP values, partial dependence plots, feature importance rankings. (6) Model card: intended use, out-of-scope uses, known limitations, and performance by subpopulation. For high-risk models this package may run 50–100 pages.

**Q8: How does Snowflake's access history feature support compliance auditing for ML workloads?**

Snowflake's `ACCESS_HISTORY` view in `ACCOUNT_USAGE` logs every query down to the column level — which user, which role, which columns were accessed, when. For an ML pipeline that pulls sensitive features (FICO, income, SSN masked fields) from a feature store, this provides a complete chain of custody: who ran the training job, which columns were included in the feature set, when the scoring job ran, and which service account executed it. This directly supports several audit requirements: (a) confirming that PII was handled only by authorized roles, (b) reconstructing the exact feature set used in a production scoring run months later, and (c) demonstrating to examiners that data access controls were in place and enforced.

**Q9: What is the difference between model validation and model monitoring, and who is responsible for each?**

Model validation is a point-in-time pre-deployment assessment performed by an independent team (MRM) that evaluates conceptual soundness, data quality, performance on holdout sets, and explainability. It produces a validation report with findings and approvals or conditions for use. Model monitoring is continuous post-deployment measurement of model behavior in production — drift detection, performance tracking, and outcomes analysis. It is the responsibility of the model owner and the data engineering team. Both are required by SR 11-7: validation without monitoring is a common examination finding. In practice, MRM consumes the output of monitoring infrastructure to conduct their annual model reviews.

**Q10: How would you build a model inventory system in Snowflake that satisfies SR 11-7 requirements?**

I'd create a `governance.model_inventory` table with fields for model ID, name, version, use case, risk tier, business owner, MRM validator, regulatory scope (array of applicable regulations), deployment date, last validation date, next scheduled review, current status (active/retired/under review), and a link to the documentation repository. I'd build a Snowflake Task that runs weekly to identify models overdue for review and sends a Slack/email alert to the MRM team. I'd also join the inventory to the `scoring_log` to verify that every model actively scoring in production has a current validation. Models scoring without a current validation appear on an exceptions report that goes to the CRO weekly. This gives examiners a single source of truth for the model population and demonstrates that the governance committee has active oversight.

---

## Pro Tips

- **Get a copy of SR 11-7 and read it yourself.** It is 22 pages and written in clear language. Most data engineers have never read it; the ones who have stand out dramatically in compliance-focused interviews.
- **Every ML pipeline should have an owner.** SR 11-7 requires that models have an identified owner responsible for monitoring and escalation. When building a model deployment system, make ownership a required field in the model registry.
- **Log everything at scoring time: inputs, outputs, model version, timestamp, requestor.** You cannot produce adverse action reason codes retroactively if you did not log the feature values. Regulators may ask you to reproduce a specific decision from 18 months ago.
- **The four-fifths rule is a starting point, not a safe harbor.** CFPB examiners use regression-based methods (e.g., the BISG proxy for race in lending) that can detect disparate impact even in populations with low self-reported demographic data. Build your fair lending analysis to exceed the minimum.
- **Treat your data pipelines as part of the model.** Under SR 11-7, a broken upstream data pipeline that feeds garbage into a model is a model risk event, not just an operational issue. Document your data sources and build data quality checks into your ETL that are as rigorous as your model validation.
- **In a compliance-focused interview, speak the language.** Use "conceptual soundness," "outcomes analysis," "independent validation," "risk tier," and "model inventory." These terms signal that you understand the regulatory environment, not just the technology.

---

[← Back to Index](README.md)
