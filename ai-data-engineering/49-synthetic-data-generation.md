# Synthetic Data Generation for ML

[← Back to Index](../index.md)

---

## Overview

Synthetic data is artificially generated data that mirrors the statistical properties, distributions, and relationships of real datasets without containing actual records. For senior data engineers working in the secondary mortgage market, synthetic data is not a novelty — it is a practical necessity driven by regulatory constraints, data scarcity for rare events, and the need to test pipelines without exposing production PII.

Understanding synthetic data generation is increasingly expected in AI/ML-focused data engineering interviews. You will be asked to reason about tradeoffs between fidelity, privacy, and utility, and to demonstrate hands-on familiarity with tools like SDV, CTGAN, and Gretel.ai.

---

## Key Concepts

| Concept | Definition |
|---|---|
| Statistical fidelity | How closely synthetic data matches the real data's distributions and correlations |
| Privacy guarantee | Protection against re-identification of individuals from synthetic records |
| Utility | Whether models trained on synthetic data perform as well as those trained on real data |
| SMOTE | Synthetic Minority Oversampling Technique — interpolates new samples in feature space |
| GAN | Generative Adversarial Network — generator vs. discriminator training paradigm |
| CTGAN | Conditional Tabular GAN, designed for mixed-type tabular data |
| TVAE | Tabular Variational Autoencoder, alternative to GAN for tabular synthesis |
| Differential privacy | Mathematical guarantee that any single record cannot be inferred from output |
| Re-identification risk | Probability that a synthetic record can be linked back to a real individual |
| Loan tape | A flat file listing every loan in an MBS pool with its attributes |

---

## Detailed Explanations

### Why Synthetic Data Matters in Mortgage/Finance

The secondary mortgage market involves highly sensitive borrower data: SSNs, income, credit scores, property addresses, LTV ratios, and delinquency history. Several operational pain points drive synthetic data adoption:

**Privacy and compliance.** GLBA, CCPA, and state-level mortgage regulations restrict use of borrower PII outside production systems. Sharing a real loan tape with a vendor or a new ML team requires complex data sharing agreements. A synthetic tape with equivalent statistical properties can be shared freely.

**Rare event augmentation.** Mortgage defaults, foreclosures, and early payoffs are low-frequency events. A training dataset might have a 2% default rate. Models trained on imbalanced data learn to predict "no default" for everything and still achieve 98% accuracy. Synthetic minority oversampling directly addresses this.

**Pipeline testing.** Validating a new Snowflake ingestion pipeline or dbt model against production data risks accidental mutation or exposure. A synthetic dataset of equivalent schema and volume enables safe, repeatable testing.

**Model validation under OCC/FHFA guidance.** SR 11-7 (model risk management) requires backtesting and sensitivity analysis. Synthetic data allows stress-testing models against scenarios that never appeared in historical data — e.g., a simultaneous spike in unemployment and home price decline.

---

### Types of Synthetic Data Generation

#### 1. Statistical Methods

**SMOTE (Synthetic Minority Oversampling Technique)**

SMOTE is appropriate when you have imbalanced classes and need more examples of the minority class. It operates in feature space: for each minority sample, it finds its k nearest neighbors and creates new samples along the line segments connecting them.

Use case: You have 500,000 performing loans and 10,000 defaults. SMOTE can generate synthetic defaults to balance the training set without duplicating records.

Limitation: SMOTE assumes feature space linearity. It can generate implausible combinations (e.g., a loan with high income but sub-500 FICO) if features are correlated.

**Copula-Based Methods**

Copulas model the joint distribution of variables separately from their marginal distributions. The Gaussian copula is the simplest; vine copulas handle complex dependency structures. SDV's GaussianCopula synthesizer uses this approach.

Use case: Modeling the correlation structure between FICO score, DTI, LTV, and interest rate across a loan tape without assuming multivariate normality.

#### 2. GAN-Based Methods

**CTGAN (Conditional Tabular GAN)**

CTGAN was designed specifically for tabular data with mixed types (continuous, categorical, ordinal). It addresses two key challenges of tabular GANs:

- Mode collapse on multimodal continuous columns: handled via variational Gaussian mixture modeling
- Class imbalance: handled via conditional generation, training the generator to produce samples from specific categories

**TVAE (Tabular Variational Autoencoder)**

TVAE encodes data into a latent space and decodes from it. It tends to have better coverage of rare modes than CTGAN but can produce less realistic individual samples. SDV exposes both as options.

#### 3. LLM-Based Generation

Large language models can generate synthetic loan records via structured prompting. This is particularly useful for generating diverse narrative fields (loan officer notes, appraisal comments) or for small-scale tabular generation when you do not have enough data to train a GAN.

```python
import anthropic
import json

client = anthropic.Anthropic()

prompt = """Generate 5 synthetic mortgage loan records in JSON array format.
Each record must have these fields:
- loan_id: string (format: LN-XXXXXX)
- fico_score: integer between 580 and 820
- ltv_ratio: float between 0.60 and 0.97
- dti_ratio: float between 0.28 and 0.50
- loan_amount: integer between 150000 and 900000
- loan_purpose: one of [purchase, refinance, cash_out_refinance]
- property_state: US state abbreviation
- loan_status: one of [current, 30_dpd, 60_dpd, 90_dpd, foreclosure]
- note_rate: float between 5.5 and 8.5

Ensure realistic correlations: higher FICO should correlate with lower DTI and
better loan_status. High LTV (>0.90) should be more common on purchases.
Return only the JSON array, no explanation."""

response = client.messages.create(
    model="claude-haiku-4-5",
    max_tokens=1024,
    messages=[{"role": "user", "content": prompt}]
)

records = json.loads(response.content[0].text)
```

#### 4. Rule-Based Generation

Template-driven generation using business rules. Fastest to implement, easiest to audit, but does not capture complex correlations. Useful for generating test fixtures for unit tests.

---

### Tools Comparison

| Tool | Approach | Best For | Snowflake Integration |
|---|---|---|---|
| SDV (Synthetic Data Vault) | GaussianCopula, CTGAN, TVAE, HMA | Relational multi-table synthesis | Export to stage |
| CTGAN standalone | GAN | Single large tables | Export to stage |
| Gretel.ai | ACTGAN, LSTM, Transforms | Enterprise, privacy metrics built-in | Native connector |
| Mostly AI | Deep learning | Highly correlated data | SaaS export |
| SMOTE (imbalanced-learn) | Statistical | Class imbalance only | N/A — preprocessing step |

---

### Evaluating Synthetic Data Quality

Three dimensions matter:

**Statistical fidelity**
- Column-level: compare marginal distributions (KS test for continuous, chi-square for categorical)
- Pairwise: compare correlation matrices between real and synthetic
- Multi-variate: train a classifier to distinguish real vs. synthetic records (Train on Synthetic, Test on Real — TSTR)

**Privacy**
- Nearest-neighbor distance ratio: are synthetic records suspiciously close to real records?
- Membership inference attack: can an adversary determine if a specific real record was in the training set?
- Re-identification rate: what fraction of synthetic records can be linked to a real individual using quasi-identifiers?

**Utility**
- TSTR (Train on Synthetic, Test on Real): train an ML model on synthetic data, evaluate on real held-out data, compare to TRTR baseline
- Key metric: accuracy gap between TSTR and TRTR should be less than 2-5%

---

### Differential Privacy and Synthetic Data

Differential privacy (DP) provides a mathematical guarantee: adding or removing any single individual from the training set changes the output distribution by at most a factor of e^epsilon. Tools like Google's DP library and Gretel's ACTGAN support DP training.

In practice, strict DP (epsilon < 1) significantly degrades data utility for mortgage data because loan attributes are highly correlated. Most financial institutions use epsilon between 3 and 10 as a practical tradeoff. Pure DP is required in some federal model validation contexts.

---

### Snowflake for Synthetic Data

Snowflake does not have a native synthetic data generator, but you can combine several features:

```sql
-- 1. Use SAMPLE to create a representative subset for local synthesis
CREATE OR REPLACE TABLE loan_sample AS
SELECT *
FROM production.loans.loan_master TABLESAMPLE (1);  -- 1% sample

-- 2. Use ML functions to score and then perturb
-- After generating synthetic data externally, load and validate:
CREATE OR REPLACE TABLE synthetic_loans (
    loan_id        VARCHAR,
    fico_score     INTEGER,
    ltv_ratio      FLOAT,
    dti_ratio      FLOAT,
    loan_amount    INTEGER,
    loan_purpose   VARCHAR,
    property_state VARCHAR,
    loan_status    VARCHAR,
    note_rate      FLOAT,
    generated_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- 3. Statistical validation query comparing real vs synthetic
WITH real_stats AS (
    SELECT
        AVG(fico_score)    AS avg_fico,
        STDDEV(fico_score) AS std_fico,
        AVG(ltv_ratio)     AS avg_ltv,
        AVG(dti_ratio)     AS avg_dti,
        COUNT_IF(loan_status != 'current') / COUNT(*)::FLOAT AS default_rate
    FROM production.loans.loan_master
),
synth_stats AS (
    SELECT
        AVG(fico_score)    AS avg_fico,
        STDDEV(fico_score) AS std_fico,
        AVG(ltv_ratio)     AS avg_ltv,
        AVG(dti_ratio)     AS avg_dti,
        COUNT_IF(loan_status != 'current') / COUNT(*)::FLOAT AS default_rate
    FROM synthetic_loans
)
SELECT
    r.avg_fico        AS real_avg_fico,
    s.avg_fico        AS synth_avg_fico,
    ABS(r.avg_fico - s.avg_fico) / r.avg_fico AS fico_pct_diff,
    r.default_rate    AS real_default_rate,
    s.default_rate    AS synth_default_rate
FROM real_stats r, synth_stats s;
```

---

### Python: CTGAN Mortgage Loan Synthesis with SDV

```python
import pandas as pd
import numpy as np
from sdv.single_table import CTGANSynthesizer
from sdv.metadata import SingleTableMetadata
from sdv.evaluation.single_table import run_diagnostic, evaluate_quality

# --- Step 1: Prepare real loan tape data ---
# Assume df_real is loaded from Snowflake or a parquet file
# df_real = snowflake_connection.execute("SELECT ... FROM loan_master").fetch_pandas_all()

# For illustration, create a realistic sample
np.random.seed(42)
n = 10_000

fico = np.random.normal(720, 60, n).clip(580, 850).astype(int)
ltv = np.random.beta(5, 2, n).clip(0.50, 0.97)
dti = np.random.beta(3, 5, n).clip(0.20, 0.55)
loan_amount = np.random.lognormal(12.5, 0.5, n).clip(100_000, 1_500_000).astype(int)
note_rate = np.random.normal(7.0, 0.8, n).clip(5.0, 9.5)

# Introduce realistic correlation: high FICO -> lower default probability
default_prob = np.where(fico >= 740, 0.01, np.where(fico >= 680, 0.04, 0.12))
loan_status = np.where(
    np.random.uniform(size=n) < default_prob,
    np.random.choice(['30_dpd', '60_dpd', '90_dpd', 'foreclosure'], n),
    'current'
)

df_real = pd.DataFrame({
    'fico_score':     fico,
    'ltv_ratio':      ltv.round(3),
    'dti_ratio':      dti.round(3),
    'loan_amount':    loan_amount,
    'note_rate':      note_rate.round(3),
    'loan_purpose':   np.random.choice(
                          ['purchase', 'refinance', 'cash_out_refinance'],
                          n, p=[0.55, 0.30, 0.15]),
    'property_state': np.random.choice(
                          ['CA', 'TX', 'FL', 'NY', 'AZ', 'CO', 'WA', 'GA'],
                          n, p=[0.20, 0.15, 0.15, 0.12, 0.08, 0.08, 0.08, 0.14]),
    'loan_status':    loan_status,
})

# --- Step 2: Define metadata ---
metadata = SingleTableMetadata()
metadata.detect_from_dataframe(df_real)

# Override detected types for precision
metadata.update_column('fico_score',     sdtype='numerical', computer_representation='Int64')
metadata.update_column('ltv_ratio',      sdtype='numerical', computer_representation='Float')
metadata.update_column('dti_ratio',      sdtype='numerical', computer_representation='Float')
metadata.update_column('loan_amount',    sdtype='numerical', computer_representation='Int64')
metadata.update_column('note_rate',      sdtype='numerical', computer_representation='Float')
metadata.update_column('loan_purpose',   sdtype='categorical')
metadata.update_column('property_state', sdtype='categorical')
metadata.update_column('loan_status',    sdtype='categorical')

# --- Step 3: Train CTGAN ---
synthesizer = CTGANSynthesizer(
    metadata,
    epochs=300,           # More epochs = better quality, more time
    batch_size=500,
    generator_dim=(256, 256),
    discriminator_dim=(256, 256),
    verbose=True
)
synthesizer.fit(df_real)

# --- Step 4: Generate synthetic data ---
df_synthetic = synthesizer.sample(num_rows=10_000)

# --- Step 5: Evaluate quality ---
diagnostic = run_diagnostic(
    real_data=df_real,
    synthetic_data=df_synthetic,
    metadata=metadata
)

quality_report = evaluate_quality(
    real_data=df_real,
    synthetic_data=df_synthetic,
    metadata=metadata
)

print(f"Overall Quality Score: {quality_report.get_score():.3f}")
# Target: > 0.80 for production-grade synthetic data

# --- Step 6: Save and upload to Snowflake ---
synthesizer.save('mortgage_ctgan_v1.pkl')
df_synthetic.to_parquet('synthetic_loan_tape.parquet', index=False)

# Upload to Snowflake stage
# PUT file://synthetic_loan_tape.parquet @%synthetic_loans;
# COPY INTO synthetic_loans FROM @%synthetic_loans/synthetic_loan_tape.parquet
# FILE_FORMAT = (TYPE = PARQUET);
```

---

### Regulatory Considerations

**SR 11-7 (Model Risk Management).** The OCC/Fed guidance requires model validation including sensitivity analysis and stress testing. Synthetic data generated under a documented methodology with measured statistical fidelity is acceptable for augmenting validation datasets. The validation team must understand how it was generated.

**FHFA oversight.** For Fannie Mae and Freddie Mac sellers/servicers, any model used in credit decisioning must be validated against representative data. Synthetic data can supplement but not replace historical performance data in primary model validation.

**Fair lending.** Synthetic data must preserve the demographic distributions of the real data to avoid introducing disparate impact into model training. Run Adverse Impact Ratio (AIR) checks on protected class proxies (geography, name-derived ethnicity) in both real and synthetic datasets.

**Audit trail.** Document the SDV/CTGAN version, training dataset hash, generation parameters, and quality scores. Treat the synthesizer model artifact like any other model artifact under model governance.

---

## Interview Q&A

**Q1: What is synthetic data and when would you use it instead of anonymized production data?**

Synthetic data is generated de novo by a model trained on real data — no real record is included in the output. Anonymized data modifies real records (masking, tokenization, generalization). The key advantage of synthetic data is that it eliminates re-identification risk that persists in anonymized data through quasi-identifiers like zip code + age + gender combinations. I would choose synthetic data when: (1) we need to share data with a third-party vendor, (2) we are building a dev/test environment that mirrors production schema and distributions, or (3) we need to augment rare events like mortgage defaults that are underrepresented in historical data.

**Q2: How does CTGAN differ from SMOTE and when would you choose one over the other?**

SMOTE operates in feature space: it interpolates new minority-class records between existing ones. It is fast, interpretable, and works well when you have a clear class imbalance problem and your features are reasonably continuous. CTGAN is a full generative model that learns the joint distribution of all columns including categoricals. I use SMOTE when I have a specific imbalanced classification task (e.g., default prediction) and just need more positive-class examples. I use CTGAN when I need a full synthetic dataset — not just oversampled rows — because I want to share the data externally or use it for pipeline testing where all columns must look realistic and internally consistent.

**Q3: How do you evaluate whether synthetic mortgage data is good enough for model training?**

Three dimensions: fidelity, utility, and privacy. For fidelity, I run column-level KS tests (continuous) and chi-square tests (categorical), compare correlation matrices, and check that business constraints hold (e.g., no LTV > 1.0 on non-distressed properties). For utility, I use the TSTR protocol: train a gradient boosting default prediction model on synthetic data, test on a real held-out set, and compare AUC/F1 to the TRTR baseline. An accuracy gap under 3% is my threshold. For privacy, I compute the nearest-neighbor distance ratio — if synthetic records are too close to real records, I have a memorization problem and need to add differential privacy noise or reduce training epochs.

**Q4: What is differential privacy and what are its practical limits for mortgage data?**

Differential privacy (DP) guarantees that the probability of any output from an algorithm changes by at most e^epsilon whether or not any single individual is in the training set. Lower epsilon = stronger privacy guarantee. In practice, mortgage data has high-dimensional correlations between FICO, DTI, LTV, and payment history. Enforcing strict DP (epsilon < 1) degrades synthetic data quality significantly because the noise required to mask individual contributions destroys the correlation structure. Most financial institutions target epsilon between 3 and 8 as a practical tradeoff — meaningful privacy protection without destroying utility. I always document the epsilon value and justify it in the model governance record.

**Q5: How would you build a synthetic MBS pool tape generator for pipeline testing?**

I would use a multi-table approach with SDV's HMASynthesizer (Hierarchical Modeling Algorithm). The data model has two levels: pool header (pool_id, issue_date, agency, WAC, WAM, factor) and loan-level detail (loan_id, pool_id, fico_score, ltv_ratio, dti_ratio, original_balance, current_balance, loan_status). HMA learns the relationships within each table and the referential integrity between them. After training on a masked sample of real pools, I can generate N synthetic pools each with a realistic distribution of loans. I validate the pool-level statistics (weighted average coupon, weighted average LTV, prepayment speeds) against historical FNMA/FHLMC pool disclosures before using in pipeline tests.

**Q6: What is the TSTR methodology and why is it preferred over column-level statistical tests?**

TSTR (Train on Synthetic, Test on Real) is a downstream-task evaluation. You train a model on synthetic data and test it on real held-out data, then compare performance to TRTR (Train on Real, Test on Real). This is preferred over column-level tests because column-level statistics can look good even when the synthetic data fails to capture the multivariate structure that matters for prediction. For example, marginal distributions of FICO and DTI might match perfectly, but the synthetic data might not capture the negative correlation between them — meaning models trained on it would underestimate default risk for high-DTI / low-FICO borrowers. TSTR catches this because prediction accuracy will degrade when that correlation is missing.

**Q7: How does Gretel.ai differ from open-source SDV and when would you pay for a managed service?**

Gretel provides enterprise features that SDV does not: built-in differential privacy training, automated quality and privacy reporting, PII detection and transformation, a managed API, and Snowflake/BigQuery native connectors. For a regulated financial institution, the audit trail and privacy metrics that Gretel generates out of the box can satisfy model governance requirements that would take weeks to build on top of raw SDV. I would use SDV for internal use cases where I control the entire pipeline and need maximum flexibility. I would pay for Gretel when: (1) I need to demonstrate DP compliance to regulators, (2) I am sharing synthetic data with external parties who need a privacy report, or (3) I need a production-grade API for on-demand synthetic data generation at scale.

**Q8: What are the fair lending risks of using synthetic data for model training?**

Synthetic data trained on historical loan performance inherits the historical lending patterns including any discriminatory practices. If the training data reflects redlining, disparate pricing, or other fair lending violations, the synthetic data will preserve those patterns — and a model trained on it could perpetuate them. I mitigate this by: (1) running Adverse Impact Ratio analysis on the synthetic data before use, (2) conditioning synthetic data generation to de-bias underrepresented demographic groups, (3) documenting that synthetic data is a supplement to — not a replacement for — historically representative data in model validation, and (4) involving the fair lending team in review of any synthetic dataset used in credit model development.

**Q9: How would you handle generating synthetic data for a table with a highly skewed loan_amount column?**

Loan amount distributions are typically log-normal with long right tails (jumbos up to $3M+). Standard normalization in CTGAN can struggle with this. My approach: (1) apply a log transform to loan_amount before fitting the synthesizer and inverse-transform after generation — SDV supports custom transformations via RDT transformers, (2) use CTGAN's VGM (Variational Gaussian Mixture) normalization which is designed for multimodal and skewed columns, (3) validate the generated distribution with a QQ-plot against the real log-normal, and (4) clip outliers to the 99.9th percentile of the real data to prevent the synthesizer from generating impossible values.

**Q10: What Snowflake-specific capabilities would you use in a synthetic data workflow?**

My Snowflake-centric workflow: (1) Use TABLESAMPLE to extract a representative 1-5% sample for training without exposing the full dataset; (2) use Dynamic Data Masking on the sample before exporting to the Python synthesis environment, ensuring PII never leaves Snowflake unmasked; (3) after generation, load the synthetic parquet via an internal stage with COPY INTO; (4) use Snowflake's data sharing to provide synthetic data to analytics or vendor environments through a dedicated share rather than file export; (5) for ongoing synthetic data pipelines, use a Snowflake Serverless Task that triggers the Python synthesis job via an external function or Snowpark Container Services — this keeps the synthesis compute co-located with the data and billable to the project's warehouse budget.

---

## Pro Tips

- **Always version your synthesizer model.** Treat CTGAN .pkl files like ML model artifacts — store in S3/Snowflake stage with version tags, training data hash, and quality scores in a model registry table. Reproducibility is required for model governance.

- **Start with SDV diagnostics before training.** Run `metadata.validate_data(df_real)` before fitting. It catches schema issues (nulls in unexpected places, wrong data types) that will silently degrade synthesis quality.

- **Train on a clean, de-duplicated subset.** CTGAN memorizes duplicated rows. Run `df_real.drop_duplicates()` and remove obvious data quality issues before fitting. Garbage in, garbage out applies doubly for generative models.

- **For imbalanced targets, use CTGAN's conditional sampling.** After fitting, generate separate batches with `synthesizer.sample(num_rows=5000, conditions=[Condition({'loan_status': 'foreclosure'})])` to oversample rare events without distorting the rest of the distribution.

- **Benchmark TVAE alongside CTGAN.** On many financial datasets, TVAE trains faster and produces higher utility scores. Run both and compare TSTR AUC before committing to one.

- **Snowflake + Snowpark is the emerging pattern.** As of 2025, you can run SDV synthesis inside Snowpark Container Services — the data never leaves Snowflake, which simplifies compliance and eliminates the export/import overhead. This is the architecture to pitch in interviews at mortgage shops with strict data residency requirements.

- **Document epsilon if you use DP.** If your organization claims DP-protected synthetic data, regulators and auditors will ask for the epsilon value. "We used DP" without a specific epsilon is not an acceptable answer.

---

*Last updated: March 2026 | Study track: AI in Data Engineering*
