# ML Model Monitoring & Drift Detection
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

Models are not static artifacts. A mortgage prepayment model trained on 2021 data will quietly degrade as rates rise, borrower behavior shifts, and new loan products emerge. Without systematic monitoring, you discover the failure in a quarterly review rather than in real time — and by then the damage is done.

This guide covers the full spectrum of production model monitoring: what goes wrong, how to detect it statistically, which platforms support it at scale, and how to build automated retraining pipelines on the data infrastructure you already own in Snowflake and SQL Server.

---

## Key Concepts

| Term | Definition |
|---|---|
| Data drift | The statistical distribution of input features shifts from training-time distributions |
| Concept drift | The underlying relationship between features and the target variable changes |
| Covariate shift | A subtype of data drift: P(X) changes but P(Y\|X) is assumed stable |
| Prior probability shift | P(Y) changes (e.g., default rates spike) while P(X\|Y) stays roughly the same |
| Model decay | General degradation of predictive performance over time, regardless of cause |
| PSI | Population Stability Index — a single scalar that quantifies distribution shift |
| Champion/challenger | Running two model versions in production simultaneously to compare live performance |
| Shadow mode | New model runs alongside champion but its outputs are not used in decisions |

---

## Why Models Degrade Over Time

### Data Drift (Covariate Shift)

Input feature distributions change. For a mortgage scoring model:

- **FICO score distribution** shifts as underwriting standards tighten post-recession
- **LTV ratios** change as home prices appreciate faster than loan balances
- **Loan purpose mix** shifts (more cash-out refis, fewer purchases)
- **Property type distribution** changes as condo lending is restricted

The model was trained on one distribution; it now scores a different one. Even if the relationship between features and outcomes were stable, the model's calibration drifts because it is extrapolating.

### Concept Drift

The relationship P(Y|X) changes. The feature values themselves may not shift, but their predictive meaning does:

- A FICO 720 borrower's default probability was 0.8% in 2019 and is 2.1% in 2023 given macroeconomic stress
- Prepayment speeds for a given coupon are no longer predicted by the same rate-incentive curve after the QE era ends

### Types of Drift

```
Sudden drift    ─────────────┐
                             └──────────────── (regulatory change, new product launch)

Gradual drift   ─────────────/‾‾‾‾‾‾‾‾‾‾‾‾‾   (slow demographic shift)

Seasonal drift  ───/‾\──/‾\──/‾\──/‾\──       (prepayment seasonality)

Recurring drift ───/‾‾\─────/‾‾\─────          (economic cycles)
```

Seasonal and recurring drift are expected and should be modeled explicitly (e.g., seasonal dummies), not treated as anomalies.

---

## Drift Detection Methods

### Population Stability Index (PSI)

PSI is the industry standard in financial services. It comes from the scorecard world and is widely accepted by model validators and regulators.

**Formula:**

```
PSI = Σ [ (Actual% - Expected%) × ln(Actual% / Expected%) ]
```

Where:
- **Expected** = training (reference) distribution, bucketed into bins
- **Actual** = current production distribution in the same bins

**Interpretation thresholds (industry standard):**

| PSI Value | Interpretation | Action |
|---|---|---|
| < 0.10 | Stable — no significant shift | Monitor normally |
| 0.10 – 0.25 | Moderate shift — investigate | Increase monitoring frequency |
| > 0.25 | Significant shift — model suspect | Trigger retraining review |

### Kolmogorov-Smirnov (KS) Test

Tests whether two samples come from the same continuous distribution. Useful for continuous features like LTV, DTI, loan amount.

```python
from scipy.stats import ks_2samp

stat, p_value = ks_2samp(reference_sample, production_sample)
# p_value < 0.05: reject null hypothesis of identical distributions
```

### Chi-Square Test

For categorical features (loan purpose, property type, occupancy status):

```python
from scipy.stats import chi2_contingency
import numpy as np

# Build contingency table: expected counts vs observed counts
observed = np.array([prod_counts])
expected = np.array([ref_counts])
chi2, p_value, dof, _ = chi2_contingency(np.vstack([observed, expected]))
```

### Wasserstein Distance (Earth Mover's Distance)

More sensitive than KS for detecting subtle distribution shape changes. Measures the minimum "work" to transform one distribution into another.

```python
from scipy.stats import wasserstein_distance

distance = wasserstein_distance(reference_sample, production_sample)
```

### Jensen-Shannon Divergence

Symmetric version of KL divergence. Bounded [0, 1], making thresholds intuitive. Good for comparing probability distributions directly.

---

## Model Performance Monitoring

Track these metrics on a rolling window (daily/weekly depending on volume):

| Metric | Use Case | Threshold Example |
|---|---|---|
| AUC-ROC | Classification models (default, prepayment) | Alert if drops > 0.03 from baseline |
| Gini coefficient | Scorecard models | Alert if drops > 5 points |
| KS statistic | Separation of good/bad | Alert if drops > 3 points |
| RMSE | Regression models (prepayment speed) | Alert if increases > 10% from baseline |
| Brier score | Probability calibration | Alert if increases > 0.02 |
| Lift/Capture rate | Business KPI alignment | Alert if top-decile lift drops > 10% |

**Challenge:** You cannot always compute performance metrics immediately. For mortgage default models, the outcome (actual default) may not be known for 6-24 months. This is the **label latency problem** — use proxy metrics or leading indicators while waiting for ground truth.

---

## Monitoring Platforms

### Evidently AI (Open Source)

```python
import pandas as pd
from evidently.report import Report
from evidently.metric_preset import DataDriftPreset, ModelPerformancePreset

reference_data = pd.read_parquet("reference_mortgage_features.parquet")
current_data   = pd.read_parquet("current_mortgage_features.parquet")

report = Report(metrics=[DataDriftPreset()])
report.run(reference_data=reference_data, current_data=current_data)
report.save_html("drift_report.html")
```

Evidently generates HTML reports with per-feature drift scores and visualizations. Integrates with Airflow, Prefect, and can push results to a database for trending.

### Commercial Platforms

| Platform | Strengths | Best For |
|---|---|---|
| Arize AI | Real-time monitoring, embedding drift | Production ML at scale |
| WhyLabs | Data-centric AI, whylogs profiles | Teams already using Apache Spark |
| Fiddler AI | Explainability + monitoring combined | Regulated industries, audit trails |
| AWS SageMaker Model Monitor | Native AWS integration | All-in AWS shops |
| Azure ML Model Monitor | Azure integration, dataset monitors | Azure-heavy enterprises |

### AWS SageMaker Model Monitor

```python
from sagemaker.model_monitor import DefaultModelMonitor
from sagemaker.model_monitor.dataset_format import DatasetFormat

monitor = DefaultModelMonitor(
    role=role,
    instance_count=1,
    instance_type="ml.m5.xlarge",
    volume_size_in_gb=20,
    max_runtime_in_seconds=3600,
)

monitor.suggest_baseline(
    baseline_dataset="s3://bucket/baseline/mortgage_train.csv",
    dataset_format=DatasetFormat.csv(header=True),
    output_s3_uri="s3://bucket/baseline-results/",
)

monitor.create_monitoring_schedule(
    monitor_schedule_name="mortgage-model-monitor",
    endpoint_input="mortgage-scoring-endpoint",
    output_s3_uri="s3://bucket/monitor-reports/",
    statistics=monitor.baseline_statistics(),
    constraints=monitor.suggested_constraints(),
    schedule_cron_expression="cron(0 * ? * * *)",  # hourly
)
```

---

## Monitoring in Snowflake

### Scheduled Task for PSI Computation

```sql
-- Create a table to store drift metrics
CREATE TABLE IF NOT EXISTS ml_ops.model_drift_metrics (
    run_date        DATE,
    model_name      VARCHAR(100),
    feature_name    VARCHAR(100),
    psi_value       FLOAT,
    drift_status    VARCHAR(20),  -- 'stable', 'moderate', 'significant'
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Stored procedure: compute PSI for a given feature
CREATE OR REPLACE PROCEDURE ml_ops.compute_psi(
    p_model_name    VARCHAR,
    p_feature_name  VARCHAR,
    p_ref_table     VARCHAR,
    p_current_table VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    psi_result FLOAT;
BEGIN
    -- Decile-based PSI calculation
    WITH reference_deciles AS (
        SELECT
            NTILE(10) OVER (ORDER BY IDENTIFIER(:p_feature_name)) AS bucket,
            COUNT(*) AS ref_count
        FROM IDENTIFIER(:p_ref_table)
        GROUP BY bucket
    ),
    current_deciles AS (
        SELECT
            NTILE(10) OVER (ORDER BY IDENTIFIER(:p_feature_name)) AS bucket,
            COUNT(*) AS cur_count
        FROM IDENTIFIER(:p_current_table)
        GROUP BY bucket
    ),
    ref_total  AS (SELECT SUM(ref_count) AS n FROM reference_deciles),
    cur_total  AS (SELECT SUM(cur_count) AS n FROM current_deciles),
    psi_calc AS (
        SELECT
            r.bucket,
            GREATEST(r.ref_count / rt.n, 0.0001)  AS expected_pct,
            GREATEST(c.cur_count / ct.n, 0.0001)  AS actual_pct,
            (GREATEST(c.cur_count / ct.n, 0.0001) -
             GREATEST(r.ref_count / rt.n, 0.0001)) *
             LN(GREATEST(c.cur_count / ct.n, 0.0001) /
                GREATEST(r.ref_count / rt.n, 0.0001)) AS psi_contribution
        FROM reference_deciles   r
        JOIN current_deciles     c ON r.bucket = c.bucket
        CROSS JOIN ref_total     rt
        CROSS JOIN cur_total     ct
    )
    SELECT SUM(psi_contribution) INTO :psi_result FROM psi_calc;

    INSERT INTO ml_ops.model_drift_metrics
        (run_date, model_name, feature_name, psi_value, drift_status)
    VALUES (
        CURRENT_DATE(),
        :p_model_name,
        :p_feature_name,
        :psi_result,
        CASE
            WHEN :psi_result < 0.10 THEN 'stable'
            WHEN :psi_result < 0.25 THEN 'moderate'
            ELSE 'significant'
        END
    );

    RETURN OBJECT_CONSTRUCT('psi', :psi_result, 'status',
        CASE WHEN :psi_result < 0.10 THEN 'stable'
             WHEN :psi_result < 0.25 THEN 'moderate'
             ELSE 'significant' END);
END;
$$;

-- Schedule daily drift monitoring
CREATE OR REPLACE TASK ml_ops.daily_drift_check
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = 'USING CRON 0 6 * * * America/New_York'
AS
    CALL ml_ops.compute_psi(
        'mortgage_prepayment_v3',
        'fico_score',
        'ml_ops.model_reference_features',
        'ml_ops.model_scoring_features_today'
    );
```

### Drift Dashboard Query

```sql
-- Trend PSI over rolling 90 days for all features
SELECT
    run_date,
    feature_name,
    psi_value,
    drift_status,
    AVG(psi_value) OVER (
        PARTITION BY feature_name
        ORDER BY run_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS psi_7day_avg
FROM ml_ops.model_drift_metrics
WHERE model_name = 'mortgage_prepayment_v3'
  AND run_date >= DATEADD(day, -90, CURRENT_DATE())
ORDER BY run_date DESC, feature_name;
```

---

## Python: Full PSI Monitoring Pipeline

```python
import numpy as np
import pandas as pd
import snowflake.connector
from dataclasses import dataclass
from typing import Optional
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@dataclass
class DriftResult:
    feature: str
    psi: float
    status: str
    reference_n: int
    current_n: int

def compute_psi(
    reference: pd.Series,
    current: pd.Series,
    buckets: int = 10,
    epsilon: float = 1e-4
) -> float:
    """
    Compute Population Stability Index between reference and current distributions.

    Parameters
    ----------
    reference : training-time feature values
    current   : production feature values (same feature, recent window)
    buckets   : number of quantile bins (10 = deciles, standard for scorecards)
    epsilon   : floor to avoid log(0), per SR 11-7 model documentation guidance
    """
    breakpoints = np.nanpercentile(reference, np.linspace(0, 100, buckets + 1))
    breakpoints  = np.unique(breakpoints)  # handle ties

    ref_counts, _ = np.histogram(reference, bins=breakpoints)
    cur_counts, _ = np.histogram(current,   bins=breakpoints)

    ref_pct = np.maximum(ref_counts / len(reference), epsilon)
    cur_pct = np.maximum(cur_counts / len(current),   epsilon)

    psi_components = (cur_pct - ref_pct) * np.log(cur_pct / ref_pct)
    return float(np.sum(psi_components))


def classify_psi(psi: float) -> str:
    if psi < 0.10:
        return "stable"
    elif psi < 0.25:
        return "moderate"
    return "significant"


def monitor_mortgage_model(
    reference_df: pd.DataFrame,
    current_df: pd.DataFrame,
    features: list[str],
    model_name: str = "mortgage_prepayment_v3",
    alert_threshold: float = 0.25
) -> list[DriftResult]:
    """
    Run PSI monitoring across all model features.
    Designed for a 16+ year SQL Server / Snowflake shop:
    - reference_df: pulled from your reference snapshot table
    - current_df:   pulled from last 30 days of scoring requests
    """
    results = []

    for feature in features:
        if feature not in reference_df.columns or feature not in current_df.columns:
            logger.warning(f"Feature {feature} missing from one dataset — skipping")
            continue

        ref_series = reference_df[feature].dropna()
        cur_series = current_df[feature].dropna()

        psi = compute_psi(ref_series, cur_series)
        status = classify_psi(psi)

        result = DriftResult(
            feature=feature,
            psi=round(psi, 4),
            status=status,
            reference_n=len(ref_series),
            current_n=len(cur_series)
        )
        results.append(result)

        if psi >= alert_threshold:
            logger.warning(
                f"DRIFT ALERT | Model: {model_name} | Feature: {feature} "
                f"| PSI: {psi:.4f} | Status: {status.upper()}"
            )

    return results


def write_results_to_snowflake(results: list[DriftResult], model_name: str, conn) -> None:
    rows = [
        (pd.Timestamp.today().date(), model_name, r.feature, r.psi, r.status)
        for r in results
    ]
    cursor = conn.cursor()
    cursor.executemany(
        """INSERT INTO ml_ops.model_drift_metrics
           (run_date, model_name, feature_name, psi_value, drift_status)
           VALUES (%s, %s, %s, %s, %s)""",
        rows
    )
    conn.commit()
    logger.info(f"Wrote {len(rows)} drift records to Snowflake")


# ---- Example invocation ----
if __name__ == "__main__":
    MORTGAGE_FEATURES = [
        "fico_score", "ltv_ratio", "dti_ratio", "loan_age_months",
        "original_balance", "coupon_rate", "rate_incentive",
        "property_type_encoded", "occupancy_encoded", "loan_purpose_encoded"
    ]

    reference_df = pd.read_parquet("s3://bucket/model-reference/mortgage_train_features.parquet")
    current_df   = pd.read_parquet("s3://bucket/scoring-logs/last_30_days.parquet")

    results = monitor_mortgage_model(
        reference_df=reference_df,
        current_df=current_df,
        features=MORTGAGE_FEATURES
    )

    for r in results:
        print(f"{r.feature:30s}  PSI={r.psi:.4f}  [{r.status.upper()}]")
```

---

## Champion / Challenger Framework

```
Traffic split (Snowflake dynamic table or application layer):
  ├── Champion model  (90% of scoring requests)  → primary decisions
  └── Challenger model (10% of scoring requests) → shadow evaluation

Evaluation cadence: 30/60/90 day windows
Promotion criteria:
  - Challenger AUC ≥ Champion AUC + 0.01 (statistically significant)
  - PSI of challenger outputs < 0.10 relative to champion
  - No material adverse action rate differences (ECOA compliance check)
  - Model validator sign-off (SR 11-7 requirement)
```

```sql
-- Log which model scored each loan (champion/challenger tracking)
CREATE TABLE ml_ops.scoring_log (
    loan_id         VARCHAR(20),
    score_date      TIMESTAMP_NTZ,
    model_name      VARCHAR(100),
    model_version   VARCHAR(20),
    model_role      VARCHAR(20),   -- 'champion' or 'challenger'
    score_output    FLOAT,
    PRIMARY KEY (loan_id, score_date, model_role)
);

-- Compare champion vs challenger performance over last 30 days
SELECT
    model_role,
    model_version,
    COUNT(*)              AS scored_loans,
    AVG(score_output)     AS avg_score,
    STDDEV(score_output)  AS score_stddev
FROM ml_ops.scoring_log
WHERE score_date >= DATEADD(day, -30, CURRENT_TIMESTAMP())
GROUP BY model_role, model_version
ORDER BY model_role;
```

---

## Retraining Triggers

| Trigger Type | Condition | Typical Cadence |
|---|---|---|
| Schedule-based | Calendar: monthly, quarterly | Stable, low-volume models |
| Performance-based | AUC drops below threshold | Event-driven |
| Drift-based | PSI > 0.25 on key features | Event-driven |
| Volume-based | Sufficient new labeled data | Event-driven |
| Business event | Rate shock, new regulation, product change | Ad hoc |

A mature MLOps shop in financial services uses **drift-based + schedule-based** in combination: drift triggers an investigation, schedule triggers a retrain regardless of whether drift was detected.

---

## Interview Q&A

**Q1: What is PSI and how do you calculate it for a mortgage scorecard?**

PSI (Population Stability Index) measures how much a feature's distribution has shifted between a reference period (typically model training data) and a current production window. You bucket the reference distribution into deciles, compute the percentage of records in each bucket for both reference and current, then sum `(actual% - expected%) * ln(actual% / expected%)` across all buckets. PSI < 0.10 means stable; 0.10–0.25 warrants investigation; > 0.25 signals significant drift. In a mortgage context I track PSI daily on FICO, LTV, DTI, and rate incentive — these are the features most sensitive to market regime changes.

**Q2: What is the difference between data drift and concept drift, and which is harder to detect?**

Data drift (covariate shift) means the distribution of input features P(X) has changed. Concept drift means the relationship P(Y|X) has changed — the same features now predict a different outcome. Data drift is detectable without ground truth labels using PSI or KS tests. Concept drift requires actual outcomes and is harder to detect because of label latency: in mortgage default modeling you may wait 12–24 months before observing ground truth defaults. Leading indicators like delinquency rates or payment behavior can serve as proxy signals while waiting for true labels.

**Q3: How would you implement model monitoring in Snowflake without a dedicated MLOps platform?**

I'd create a `model_drift_metrics` table, write a stored procedure that runs PSI computation using Snowflake's analytic functions (NTILE for bucketing, LN for the log ratio), and schedule it via a Snowflake Task on a daily CRON. For performance metrics, I'd join the scoring log against actual outcomes in a scheduled task and write results to a monitoring table. A simple Streamlit-in-Snowflake dashboard or a Sigma/Tableau report over those tables gives the model validator continuous visibility without any external tooling.

**Q4: What is a champion/challenger framework and why does it matter for SR 11-7 compliance?**

Champion/challenger runs two model versions in parallel — the champion handles the majority of production decisions, the challenger handles a minority in shadow or live mode. This satisfies SR 11-7's requirement for ongoing model performance monitoring and provides empirical evidence for model promotion decisions. The framework also supports the "outcomes analysis" requirement: you can directly compare model outputs against actual outcomes for both versions simultaneously, giving the model validation team the statistical basis to approve a model change.

**Q5: Your PSI is fine but AUC is degrading. What do you investigate?**

This pattern suggests concept drift without covariate shift. The feature distributions look similar to training, but the relationship between features and outcomes has changed. I'd investigate: (1) Has the macroeconomic environment changed in ways not captured by current features? (2) Are there new loan products in the portfolio not well-represented in training data? (3) Has the outcome definition changed (e.g., servicer reporting changes)? (4) Has something changed in upstream data pipelines that affects feature quality without changing distributions? I'd escalate to model validation and likely initiate a retrain with recent data.

**Q6: What is the label latency problem and how do you handle it in mortgage default modeling?**

Label latency is the delay between when a model makes a prediction and when the true outcome (default/no default) is observed. For mortgage default it can be 12–24 months. This makes real-time performance monitoring impossible. Mitigations: (1) Use proxy labels — 60-day delinquency as a leading indicator of eventual default. (2) Monitor input distributions (PSI/KS) as a leading signal for potential performance degradation. (3) Use vintages: evaluate the cohort of loans scored 18 months ago against their now-observed outcomes on a rolling basis. (4) Maintain a model performance calendar that schedules annual backtests timed to when labels are available.

**Q7: How do you set meaningful alerting thresholds to avoid alert fatigue?**

Start with industry standard thresholds (PSI 0.10/0.25) and then calibrate based on historical volatility of your specific portfolio. For features with known seasonality (prepayment incentive is highly seasonal), implement seasonal baselines — compare this January against last January rather than against a static training-time snapshot. Use statistical control chart methods: alert only when a metric crosses 2 or 3 standard deviations from its rolling mean. Layer severity: PSI 0.10 triggers a Slack notification to the data science team; PSI 0.25 triggers a Jira ticket and pages the on-call model owner; PSI 0.40 triggers the model validation team and pauses automated model updates.

**Q8: What tools have you used for production model monitoring and what are the tradeoffs?**

In large financial institutions I've seen a range: (a) **Home-built on Snowflake Tasks + SQL** — maximum control, auditable, uses existing infrastructure, but requires engineering time to build alerting and dashboards. (b) **Evidently AI** — open source, excellent for report generation and CI/CD integration, but not a managed service. (c) **Arize AI** — purpose-built for production monitoring, excellent embedding drift detection, but a new vendor relationship that requires security/procurement review. (d) **SageMaker Model Monitor** — great if you're AWS-native, less useful in a hybrid Snowflake/on-prem shop. For a heavily regulated environment like secondary mortgage market, I prefer home-built or Evidently because every calculation is inspectable and auditable, which model validators and regulators expect.

**Q9: How do you handle seasonal drift so you don't retrain the model every summer?**

Use seasonal reference baselines. Instead of comparing current production data against a fixed training snapshot, compare it against the corresponding period from the prior year. For a mortgage prepayment model, June prepayment speeds should be compared against the prior June, not against a January training baseline. In Snowflake this means maintaining a rolling reference table segmented by calendar month. Separately, model the seasonality explicitly using month-of-year features or fourier terms so the model itself captures the pattern rather than monitoring treating it as drift.

**Q10: Explain a real scenario where model drift caused a business problem you've seen or can reason through.**

A mortgage prepayment model trained in 2020 (ultra-low rate environment) was still in production in early 2022 as rates began rising sharply. The model's training data contained almost no observations of borrowers with a negative rate incentive (market rate above note rate), so its predictions for this fast-growing segment were extrapolations. PSI on the rate incentive feature began showing moderate drift (0.12) by Q3 2021, which should have triggered investigation. By Q1 2022 PSI exceeded 0.35 and modeled prepayment speeds were materially overstating actual speeds, causing MBS pricing errors. The failure was threefold: insufficient monitoring cadence, no retraining trigger connected to the PSI alert, and no champion/challenger running a newer vintage model. The fix required emergency retraining on 2021–2022 data, model validation under compressed timelines, and a post-mortem that led to implementing automated drift-triggered retraining pipelines.

---

## Pro Tips

- **Always floor PSI bins at a small epsilon (0.0001) before taking the log.** An empty bin produces log(0) = -∞ and breaks the calculation. Document this choice in your model monitoring specification — validators will ask.
- **Track PSI on model output scores, not just input features.** Output drift is often the first detectable signal and is a single metric covering all features collectively.
- **Separate scheduled monitoring from alerting.** Run drift calculations daily; alert only when a rolling 7-day average exceeds the threshold. This suppresses single-day noise.
- **Version your reference snapshots explicitly.** When a model is retrained, archive the old reference snapshot with a timestamp. You need the ability to reproduce any historical drift report — this is an audit requirement under SR 11-7.
- **For models used in adverse action notices, monitor subpopulation drift separately.** Demographic subgroups may drift at different rates, creating disparate impact that aggregate PSI would mask. This is a CFPB examination priority.
- **Integrate monitoring into your CI/CD pipeline.** Run a drift check in the deployment gate — if the new model's output distribution deviates too far from the champion on the holdout set, block the deployment automatically.

---

[← Back to Index](README.md)
