# Data Privacy in AI: PII, GDPR, CCPA, and GLBA

[← Back to Index](README.md)

---

## Overview

Data privacy in AI is one of the most critical concerns in financial services, particularly in the secondary mortgage market where you are handling some of the most sensitive consumer data that exists: Social Security Numbers, credit scores, income histories, bank account details, and property valuations. AI and ML systems introduce new privacy risks beyond traditional data management because models can memorize training data, leak information through predictions, and inadvertently re-identify individuals from supposedly anonymized features.

This file covers the regulatory landscape governing financial data privacy, the specific risks AI introduces, and the technical controls you can implement in Snowflake, SQL Server, and Python-based pipelines to maintain compliance. As a senior data engineer, your role spans building the infrastructure that enforces these controls — not just understanding policy documents.

---

## Key Concepts at a Glance

| Concept | Definition | Mortgage Relevance |
|---|---|---|
| PII | Personally Identifiable Information | SSN, DOB, name, address in loan files |
| GLBA | Gramm-Leach-Bliley Act | Financial privacy for customers of financial institutions |
| FCRA | Fair Credit Reporting Act | Controls use of credit reports in decisioning |
| CCPA/CPRA | California Consumer Privacy Act / Rights Act | Consumer rights to opt-out, delete, know |
| GDPR | General Data Protection Regulation (EU) | Applies if any EU borrowers or data subjects |
| Differential Privacy | Mathematical framework adding noise to protect individuals | Used in model training and aggregate statistics |
| Federated Learning | Training ML without centralizing raw data | Useful for multi-servicer models |
| Homomorphic Encryption | Computing on encrypted data without decrypting | Enables secure multi-party analytics |
| Synthetic Data | Statistically similar fake data | Replaces PII in dev/test/training environments |

---

## PII in Mortgage Data

The secondary mortgage market handles loan-level data across origination, servicing, securitization, and analytics workflows. The PII exposure surface is extremely broad:

**Direct Identifiers:**
- Social Security Numbers (SSN / TIN)
- Full legal name
- Date of birth
- Driver's license / government ID numbers
- Biometric data (increasingly used in digital origination)

**Quasi-Identifiers (can re-identify when combined):**
- Street address, zip code, census tract
- Loan amount, interest rate, origination date
- Property value, LTV ratio
- Employer name, income band
- Race/ethnicity (collected for HMDA reporting)

**Financial Account Data:**
- Bank account numbers, routing numbers
- Credit card numbers
- Mortgage account numbers
- Payment history details

**In ML pipelines**, even "anonymized" feature sets containing combinations of loan amount + zip code + origination date + rate can be sufficient to re-identify a specific borrower when cross-referenced with public HMDA disclosures.

---

## Regulatory Framework

### GLBA — Gramm-Leach-Bliley Act

The primary US law governing financial data privacy. Applies to financial institutions including mortgage lenders, servicers, and companies handling consumer financial data.

**Key requirements relevant to AI/ML:**
- **Privacy notices**: Consumers must be informed about data sharing practices
- **Opt-out rights**: Consumers can opt out of sharing with non-affiliated third parties
- **Safeguards Rule (16 CFR Part 314)**: Requires administrative, technical, and physical safeguards — updated in 2023 to require encryption, access controls, and penetration testing
- **AI implication**: Using consumer data to train ML models constitutes "processing" under GLBA. If a model is trained on data shared by an affiliate, the original privacy notice must have disclosed that use

**2023 Safeguards Rule updates most relevant to data engineers:**
- Encryption of customer information in transit and at rest
- Multi-factor authentication for accessing customer information
- Monitoring and testing of key controls (logging access to training data)
- Designation of a qualified individual overseeing the information security program

### FCRA — Fair Credit Reporting Act

Governs the use of consumer reports (credit reports, background checks) in credit decisioning.

**AI/ML implications:**
- Credit scores (FICO, VantageScore) are consumer reports — their use in ML models must be for a "permissible purpose"
- Adverse action notices (Reg B / ECOA) must explain why credit was denied — a black-box ML model creates compliance risk
- Furnisher obligations: if your ML model generates data that is then furnished to a CRA, accuracy obligations apply
- The "600-mile rule": a consumer reporting agency cannot report negative information that is more than 7 years old — ML models trained on historical data must respect this

### CCPA / CPRA — California Consumer Privacy Act / Rights Act

Applies to businesses meeting certain thresholds that collect California consumers' personal information.

**Consumer rights under CPRA:**
- Right to know what data is collected and how it is used
- Right to delete personal information (including from ML training sets — this is operationally hard)
- Right to correct inaccurate data
- Right to opt out of the "sale" or "sharing" of personal information
- Right to limit use of sensitive personal information (SSN, financial account info, race/ethnicity)

**Data engineer implication**: If you have trained an ML model on data that includes California residents, and a consumer exercises their deletion right, you may need to retrain or at minimum document why retraining is not feasible (the "undue burden" exception). Maintaining a provenance record of which records contributed to which training run is the prerequisite for any deletion compliance.

### GDPR — General Data Protection Regulation

Less commonly applicable in pure domestic mortgage operations, but relevant if:
- Your firm services loans for EU-based investors or has EU-based employees whose data is processed
- Your firm uses EU-based cloud regions
- Your firm acquires loan portfolios that contain EU citizens

**Key GDPR requirements for AI:**
- **Lawful basis**: Processing must have a legal basis (contract, legitimate interest, consent). Consent for ML training is problematic because it must be specific and withdrawable.
- **Purpose limitation**: Data collected for loan origination cannot be repurposed for training a churn prediction model without a new lawful basis
- **Data minimization**: ML features should be limited to what is necessary — no kitchen-sink feature engineering using all available PII
- **Right to explanation (Article 22)**: Automated decisions with significant effects on individuals require a meaningful explanation — directly relevant to AI credit models
- **Data Protection Impact Assessment (DPIA)**: Required for high-risk processing, including large-scale processing of sensitive data and automated decision-making
- **Cross-border transfers**: Standard Contractual Clauses (SCCs) required if training data moves to US-based cloud from EU

---

## Privacy Risks Introduced by AI/ML

### Training Data Memorization

Large language models and even smaller ML models can memorize specific training examples, particularly rare or unique records. In a mortgage context, an LLM fine-tuned on loan documents might reproduce a specific SSN or account number verbatim in response to a related prompt.

**Research findings:**
- Carlini et al. (2021) demonstrated that GPT-2 memorized and reproduced verbatim training data including PII
- The risk is highest for small training datasets, duplicated records, and models with high parameter counts relative to training set size

**Mitigations:**
- Deduplicate training data before fine-tuning
- Apply differential privacy during training (DP-SGD)
- Use canary tokens to test for memorization before deployment
- Never include SSNs, account numbers, or full names in LLM training corpora

### Inference Attacks

**Model Inversion Attack**: An adversary queries the model repeatedly and reconstructs approximate versions of training data from the model's outputs. For a credit scoring model, this could reveal income or debt patterns of specific borrowers.

**Membership Inference Attack**: Determines whether a specific individual's record was in the training set. This alone is a privacy violation — knowing that someone has a mortgage with a specific servicer is sensitive.

**Attribute Inference Attack**: Given partial information about an individual (name, address), infers sensitive attributes (credit score range, income) by querying a model trained on correlated data.

**Mitigations:**
- Differential privacy in training
- Output perturbation (rounding or adding noise to model outputs)
- Rate limiting and monitoring of prediction APIs
- Minimum group sizes for aggregate outputs

### Re-identification from ML Features

Feature engineering for mortgage models often creates quasi-identifiers. The combination of:
- `loan_amount_bucket` + `origination_year` + `property_state` + `rate_bucket` + `loan_purpose`

...may correspond to a handful of records or even a single record, making re-identification trivial when cross-referenced with public HMDA data.

**HMDA public disclosure files** contain: loan amount, property location (tract), loan type, applicant race/ethnicity, action taken — enough context that model feature sets derived from this data can be cross-referenced.

---

## Privacy-Preserving ML Techniques

### Differential Privacy (DP)

Differential privacy provides a mathematical guarantee: the output of an algorithm changes by at most a bounded amount when any single individual's data is added or removed. This is controlled by the privacy budget parameter epsilon (ε).

- **Low ε** (e.g., 0.1): Strong privacy, higher noise, lower model accuracy
- **High ε** (e.g., 10.0): Weaker privacy, less noise, better accuracy
- For mortgage credit models, ε between 1.0 and 3.0 is a practical range depending on sensitivity

**DP-SGD (Differentially Private Stochastic Gradient Descent)**: The primary mechanism for training neural networks with DP guarantees. Clips per-sample gradients and adds calibrated Gaussian noise before each parameter update.

### Federated Learning

Federated learning trains a global model across multiple data silos without any raw data leaving the silo. Each participant trains locally, shares only model gradients or weight updates, and a central aggregator combines the updates (typically via FedAvg).

**Mortgage industry application:**
- Multiple servicers training a shared prepayment model without sharing individual loan records
- A bank holding company training across subsidiaries without centralizing data in a single environment
- GSE model development using servicer data without taking custody of it

**Limitations**: Gradient updates can still leak information (gradient inversion attacks). FL + DP is the standard combination for strong privacy guarantees.

### Homomorphic Encryption (HE)

Allows computation on ciphertext — the data remains encrypted through the entire computation. The result, when decrypted, matches what you would have gotten computing on plaintext.

**Practical state in 2026**: Fully Homomorphic Encryption (FHE) is real but slow (100x-10,000x overhead vs. plaintext). Libraries like Microsoft SEAL, OpenFHE, and Concrete ML (Zama) make it approachable. Suitable for:
- Secure model inference: send encrypted input, receive encrypted output, never expose borrower data to the inference service
- Privacy-preserving credit score computation across institutions

### Synthetic Data

Statistically similar but non-real data generated to replace PII-containing datasets in development, testing, and ML training.

**Approaches:**
- **Generative Adversarial Networks (GANs)**: SDV (Synthetic Data Vault), CTGAN for tabular data
- **Variational Autoencoders (VAEs)**
- **Statistical methods**: Copula-based synthesis (Gaussian Copula, TVAE)

**Critical warning**: Synthetic data is not automatically private. If generated naively, it can reproduce rare individuals from the training distribution. Combine with differential privacy or membership inference testing.

---

## Snowflake: Data Masking Policies for ML Workloads

```sql
-- Create a masking policy for SSN
-- Returns full SSN only for LOAN_ANALYST role, masked for all others
CREATE OR REPLACE MASKING POLICY ssn_mask AS (val STRING)
  RETURNS STRING ->
    CASE
      WHEN CURRENT_ROLE() IN ('LOAN_ANALYST', 'COMPLIANCE_OFFICER') THEN val
      WHEN CURRENT_ROLE() = 'DATA_SCIENTIST' THEN 'XXX-XX-' || RIGHT(val, 4)
      ELSE '***-**-****'
    END;

-- Apply the masking policy to the column
ALTER TABLE MORTGAGE_ORIGINATION.PUBLIC.LOAN_APPLICATION
  MODIFY COLUMN borrower_ssn
  SET MASKING POLICY ssn_mask;

-- Create a masking policy for account numbers (tokenized)
CREATE OR REPLACE MASKING POLICY account_token_mask AS (val STRING)
  RETURNS STRING ->
    CASE
      WHEN CURRENT_ROLE() IN ('SERVICING_OPS') THEN val
      ELSE SHA2(val || 'SALT_KEY_2026', 256)  -- deterministic token
    END;

-- Row Access Policy: data scientists only see records without SSN in features
-- (train on an approved feature-only view, not the raw table)
CREATE OR REPLACE ROW ACCESS POLICY ml_training_access AS (region STRING)
  RETURNS BOOLEAN ->
    CASE
      WHEN CURRENT_ROLE() = 'ML_ENGINEER' AND region != 'RESTRICTED' THEN TRUE
      WHEN CURRENT_ROLE() IN ('LOAN_ANALYST', 'COMPLIANCE_OFFICER') THEN TRUE
      ELSE FALSE
    END;

-- Approved ML feature view: no direct PII, only derived features
CREATE OR REPLACE SECURE VIEW ML_FEATURES.PREPAYMENT_MODEL_FEATURES AS
SELECT
    SHA2(loan_id || 'TRAINING_SALT', 256)         AS loan_token,   -- pseudonymous ID
    DATEDIFF('month', origination_date, '2024-01-01') AS loan_age_months,
    ROUND(current_balance / 10000) * 10000         AS balance_bucket,  -- generalized
    ROUND(current_rate * 8) / 8                    AS rate_bucket,     -- rounded to 0.125
    loan_purpose,
    property_state,
    -- NO: borrower_name, ssn, dob, address, income, account_number
FROM MORTGAGE_ORIGINATION.PUBLIC.LOAN_APPLICATION
WHERE data_use_consent = TRUE;  -- consent flag must be set
```

---

## SQL Server: Always Encrypted for ML Services

```sql
-- SQL Server Always Encrypted: column-level encryption
-- The database engine never sees the plaintext — only the client application does

-- Step 1: Create Column Master Key (stored in Azure Key Vault)
CREATE COLUMN MASTER KEY CMK_AzureKeyVault
WITH (
    KEY_STORE_PROVIDER_NAME = 'AZURE_KEY_VAULT',
    KEY_PATH = 'https://mortgage-kv.vault.azure.net/keys/CMK/abc123'
);

-- Step 2: Create Column Encryption Key
CREATE COLUMN ENCRYPTION KEY CEK_SSN
WITH VALUES (
    COLUMN_MASTER_KEY = CMK_AzureKeyVault,
    ALGORITHM = 'RSA_OAEP',
    ENCRYPTED_VALUE = 0x01700000016C006F...  -- encrypted CEK bytes
);

-- Step 3: Create table with encrypted columns
CREATE TABLE dbo.BorrowerProfile (
    loan_id          INT NOT NULL,
    borrower_ssn     NVARCHAR(11)  ENCRYPTED WITH (
                         ENCRYPTION_TYPE = DETERMINISTIC,  -- allows equality search
                         ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256',
                         COLUMN_ENCRYPTION_KEY = CEK_SSN),
    borrower_income  DECIMAL(12,2) ENCRYPTED WITH (
                         ENCRYPTION_TYPE = RANDOMIZED,     -- stronger, no search
                         ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256',
                         COLUMN_ENCRYPTION_KEY = CEK_SSN),
    credit_score     INT,  -- not encrypted, used in ML features
    loan_purpose     NVARCHAR(50)
);

-- ML Services in SQL Server: run Python in-database on non-PII columns
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'
import pandas as pd
from sklearn.linear_model import LogisticRegression

# Only non-PII features passed to the model
X = InputDataSet[["credit_score", "ltv", "dti", "loan_age_months"]]
y = InputDataSet["default_flag"]

model = LogisticRegression()
model.fit(X, y)

import pickle
OutputDataSet = pd.DataFrame({"model_bytes": [pickle.dumps(model)]})
',
    @input_data_1 = N'
        SELECT credit_score, ltv, dti, loan_age_months, default_flag
        FROM dbo.LoanFeatures
        WHERE training_set = 1
    ';
```

---

## Python: PII Detection with Microsoft Presidio

```python
"""
PII detection and anonymization pipeline using Microsoft Presidio.
Used to scan ML training datasets for inadvertent PII inclusion.
"""

from presidio_analyzer import AnalyzerEngine, RecognizerRegistry
from presidio_analyzer.nlp_engine import NlpEngineProvider
from presidio_anonymizer import AnonymizerEngine
from presidio_anonymizer.entities import OperatorConfig
import pandas as pd
import re

# Initialize analyzer with US locale
analyzer = AnalyzerEngine()
anonymizer = AnonymizerEngine()

def scan_dataframe_for_pii(df: pd.DataFrame, text_columns: list[str]) -> dict:
    """
    Scan free-text columns in a DataFrame for PII.
    Returns a report of findings by column and row.
    """
    findings = {}

    for col in text_columns:
        col_findings = []
        for idx, value in df[col].dropna().items():
            results = analyzer.analyze(
                text=str(value),
                entities=["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER",
                          "US_SSN", "US_BANK_NUMBER", "US_ITIN",
                          "US_DRIVER_LICENSE", "CREDIT_CARD",
                          "DATE_TIME", "LOCATION", "US_PASSPORT"],
                language="en"
            )
            if results:
                col_findings.append({
                    "row_index": idx,
                    "original_text": value[:50] + "..." if len(str(value)) > 50 else value,
                    "pii_types": [r.entity_type for r in results],
                    "confidence_scores": [round(r.score, 2) for r in results]
                })
        findings[col] = col_findings

    return findings

def anonymize_text_column(df: pd.DataFrame, column: str) -> pd.DataFrame:
    """Replace PII in free-text column with type placeholders."""
    operators = {
        "US_SSN": OperatorConfig("replace", {"new_value": "<SSN>"}),
        "PERSON": OperatorConfig("replace", {"new_value": "<NAME>"}),
        "EMAIL_ADDRESS": OperatorConfig("replace", {"new_value": "<EMAIL>"}),
        "PHONE_NUMBER": OperatorConfig("replace", {"new_value": "<PHONE>"}),
        "US_BANK_NUMBER": OperatorConfig("replace", {"new_value": "<ACCOUNT>"}),
        "DATE_TIME": OperatorConfig("replace", {"new_value": "<DATE>"}),
        "LOCATION": OperatorConfig("replace", {"new_value": "<LOCATION>"}),
    }

    def anonymize_text(text):
        if pd.isna(text):
            return text
        analyzer_results = analyzer.analyze(text=str(text), language="en")
        anonymized = anonymizer.anonymize(
            text=str(text),
            analyzer_results=analyzer_results,
            operators=operators
        )
        return anonymized.text

    df = df.copy()
    df[column] = df[column].apply(anonymize_text)
    return df


# Example: scan a DataFrame of loan notes before adding to training data
if __name__ == "__main__":
    sample_data = pd.DataFrame({
        "loan_id": [1001, 1002, 1003],
        "underwriter_note": [
            "Borrower John Smith (SSN: 123-45-6789) verified income via W2",
            "Property at 123 Oak Street appraised at $450,000, DTI within guidelines",
            "Credit pull authorized by borrower on 03/15/2024, score 742"
        ]
    })

    pii_report = scan_dataframe_for_pii(sample_data, text_columns=["underwriter_note"])
    print("PII Scan Report:")
    for col, findings in pii_report.items():
        print(f"\nColumn: {col}")
        for f in findings:
            print(f"  Row {f['row_index']}: {f['pii_types']} detected")

    # Anonymize before including in training data
    cleaned_data = anonymize_text_column(sample_data, "underwriter_note")
    print("\nAnonymized notes:")
    print(cleaned_data["underwriter_note"].tolist())
```

---

## Python: Differential Privacy with SmartNoise / OpenDP

```python
"""
Applying differential privacy to mortgage aggregate statistics
using the OpenDP library (successor to Microsoft SmartNoise).
"""

import opendp.prelude as dp
import pandas as pd
import numpy as np

dp.enable_features("contrib")

def dp_mean_with_budget(data: list[float], epsilon: float,
                        lower: float, upper: float) -> float:
    """
    Compute differentially private mean with given epsilon budget.
    lower/upper are known bounds on the data (e.g., 0-1500000 for loan balance).
    """
    # Build the DP measurement chain
    meas = (
        dp.vector_domain(dp.atom_domain(bounds=(lower, upper)))
        >> dp.t.then_mean()
        >> dp.m.then_laplace(scale=dp.binary_search_param(
            lambda s: dp.m.make_laplace(
                dp.atom_domain(bounds=(lower, upper)),
                dp.absolute_distance(T=float), s
            ).map(1),
            d_in=1, d_out=epsilon
        ))
    )
    return meas(data)


def compute_dp_aggregates(df: pd.DataFrame, epsilon_budget: float = 1.0) -> pd.DataFrame:
    """
    Compute DP-protected aggregate statistics on loan portfolio.
    Splits epsilon budget across multiple queries (composition).
    """
    # Allocate epsilon budget across queries
    n_queries = 4
    epsilon_per_query = epsilon_budget / n_queries

    results = {}

    # DP count
    count_meas = (
        dp.vector_domain(dp.atom_domain(T=float, bounds=(0.0, 1.0)))
        >> dp.t.then_count(TO=float)
        >> dp.m.then_laplace(scale=1.0 / epsilon_per_query)
    )
    noisy_count = count_meas([1.0] * len(df))
    results["dp_loan_count"] = max(0, round(noisy_count))

    # DP mean loan balance
    balances = df["current_balance"].clip(0, 2_000_000).tolist()
    results["dp_mean_balance"] = dp_mean_with_budget(
        balances, epsilon_per_query, lower=0.0, upper=2_000_000.0
    )

    # DP mean interest rate
    rates = df["current_rate"].clip(0, 20).tolist()
    results["dp_mean_rate"] = dp_mean_with_budget(
        rates, epsilon_per_query, lower=0.0, upper=20.0
    )

    # DP mean LTV
    ltvs = df["ltv"].clip(0, 150).tolist()
    results["dp_mean_ltv"] = dp_mean_with_budget(
        ltvs, epsilon_per_query, lower=0.0, upper=150.0
    )

    return pd.DataFrame([results])


# Privacy budget tracking class
class PrivacyBudgetLedger:
    """Track epsilon consumption across queries on a dataset."""

    def __init__(self, total_epsilon: float, dataset_name: str):
        self.total_epsilon = total_epsilon
        self.remaining_epsilon = total_epsilon
        self.dataset_name = dataset_name
        self.query_log = []

    def consume(self, epsilon: float, query_description: str) -> bool:
        if epsilon > self.remaining_epsilon:
            print(f"BUDGET EXCEEDED: requested {epsilon}, remaining {self.remaining_epsilon:.4f}")
            return False
        self.remaining_epsilon -= epsilon
        self.query_log.append({
            "query": query_description,
            "epsilon_used": epsilon,
            "remaining": self.remaining_epsilon
        })
        print(f"Budget consumed: {epsilon} for '{query_description}'. "
              f"Remaining: {self.remaining_epsilon:.4f}/{self.total_epsilon}")
        return True

    def report(self) -> pd.DataFrame:
        return pd.DataFrame(self.query_log)


# Usage
ledger = PrivacyBudgetLedger(total_epsilon=3.0, dataset_name="2024_Q4_LOAN_POOL")
if ledger.consume(1.0, "mean_balance_by_state"):
    print("Query approved and executed.")
```

---

## Azure Purview for Data Privacy Governance

Azure Purview (Microsoft Purview) provides data discovery, classification, and lineage for ML governance:

**Key capabilities for mortgage AI workloads:**
- **Automated PII scanning**: Classifiers detect SSNs, account numbers, and financial data across Snowflake, SQL Server, Azure Data Lake, and blob storage
- **Data lineage**: Track which datasets fed which ML training runs — critical for deletion compliance under CCPA/CPRA
- **Sensitivity labels**: Apply Microsoft Information Protection labels (Confidential, Highly Confidential) to datasets containing PII, flowing through to downstream ML artifacts
- **Policy enforcement**: Restrict access to sensitive data to approved service principals and roles
- **ML model catalog integration**: Register trained models alongside the data lineage of their training sets

**Data lineage for CCPA deletion compliance:**
```
Purview lineage graph:
  LOAN_APPLICATION (source)
    → ETL_PIPELINE_2024Q4
      → TRAINING_DATASET_PREPAY_V3
        → MODEL_PREPAY_LGBM_2024Q4 (artifact)
```

If a California borrower requests deletion, Purview lineage tells you exactly which models were trained on their record, enabling a structured response.

---

## Interview Q&A

**Q1: A California borrower exercises their CCPA right to deletion. Their record was used to train a mortgage prepayment model. What do you do?**

A: This is one of the hardest operational problems in ML privacy. The CCPA right to deletion applies to stored personal information, but there is no explicit requirement to retrain models. The practical response is multi-layered: First, delete the record from all operational systems and document the deletion. Second, if the training dataset itself is stored (it should be, for reproducibility), delete or redact the individual's record from it and document the action. Third, assess whether retraining is required — regulators have not mandated automatic retraining, but if the model is used in credit decisions, there is legal risk in knowingly retaining influence from a deleted record. For large models where retraining is feasible, retrain and document. For models where retraining is not feasible, document the undue burden justification, implement machine unlearning techniques if available, or accept the risk with legal sign-off. Critically, the prerequisite for any of this is having training data lineage — you cannot delete what you cannot find, which is why Purview or similar data catalog integration is not optional.

**Q2: Explain differential privacy to a mortgage business stakeholder who wants to share aggregate loan portfolio statistics with a GSE without revealing individual borrower data.**

A: Differential privacy is a mathematical guarantee that the statistics you share cannot be used to determine whether any individual borrower's data was included. We add a calibrated amount of statistical noise to the aggregate numbers before sharing. For example, if the true average balance is $342,500, we might share $342,800 — close enough to be analytically useful, but the noise is structured so that no one can infer details about any individual loan. The "privacy budget" (epsilon) controls the trade-off: smaller epsilon means more noise but stronger protection, larger epsilon means less noise but weaker protection. For sharing aggregates with Fannie or Freddie, an epsilon around 1.0 to 2.0 is a reasonable starting point. The key business benefit is that we can share without signing a DUA for every query, because the output is mathematically privacy-safe.

**Q3: What is a membership inference attack and how does it apply to a credit default model?**

A: A membership inference attack is a technique where an adversary can determine, with better-than-chance probability, whether a specific individual's record was used to train a model. The attacker typically trains a meta-classifier that exploits the fact that models tend to have higher confidence and lower loss on their training examples versus held-out examples. In the mortgage context, the risk is that if a competitor or adversary can determine that a specific borrower's record was in the training set for your default model, that itself reveals sensitive information — it means that person has a mortgage with your firm and their data is being used for modeling. Mitigations include differential privacy during training (which bounds membership inference advantage mathematically), using shadow model detection, regularization to reduce overfitting, and ensuring that model prediction APIs do not return raw probability scores that make confidence comparison easy.

**Q4: How does the GLBA Safeguards Rule affect how you design a Snowflake-based ML training pipeline?**

A: The 2023 updated Safeguards Rule requires encryption at rest and in transit, access controls, and monitoring. For a Snowflake ML pipeline this translates to: (1) Tri-Secret Secure or customer-managed keys (CMK) for encryption at rest on tables containing PII; (2) Masking policies that prevent data scientists from seeing raw SSNs, names, or account numbers even in approved training environments; (3) Row access policies that restrict which records can be accessed based on consent flags and data use agreements; (4) Full query auditing via Snowflake ACCESS_HISTORY and QUERY_HISTORY, stored in a compliance-controlled schema with access restricted from the data science team; (5) Service accounts (not personal credentials) with least-privilege grants for ML pipeline execution; and (6) Network policies restricting Snowflake access to approved IP ranges. The Safeguards Rule also requires annual penetration testing — your Snowflake configuration should be in scope for that assessment.

**Q5: What is the difference between tokenization and encryption, and which is more appropriate for ML feature stores?**

A: Encryption is reversible with a key — you can decrypt encrypted data back to its original form. Tokenization replaces sensitive values with non-sensitive surrogate tokens (e.g., replacing SSN 123-45-6789 with the token TKN-8834921), where the mapping is stored in a separate, highly secured token vault. For ML feature stores, tokenization is generally preferred over encryption for several reasons: (1) Tokens can be used as join keys across systems without ever exposing PII — the same borrower gets the same token, enabling consistent tracking; (2) Tokens in the feature store cannot be reversed even if the feature store is compromised, because the vault is separate; (3) ML models trained on token IDs for borrower tracking cannot reverse-engineer the original PII; (4) Encryption in SQL or Snowflake typically prevents indexing and standard SQL operations, whereas tokens are just strings that behave normally in queries. The vault itself (e.g., Protegrity, Voltage, or Azure Key Vault-based token vaults) must be separately secured and audited.

**Q6: How does federated learning apply to the secondary mortgage market? What are the privacy caveats?**

A: Federated learning is relevant when multiple servicers, originators, or the GSEs want to collaborate on a shared model without any party sharing raw loan data. For example, Fannie Mae might want to train a prepayment model using servicer loan-level data that servicers are contractually prohibited from sharing. With federated learning, each servicer trains locally on their book, shares only gradient updates, and a central aggregator (Fannie) produces a global model. Privacy caveats: gradient updates are not inherently private — gradient inversion attacks can reconstruct training examples from gradients, particularly in early training rounds. The standard mitigation is combining federated learning with differential privacy at the gradient level (adding noise before sharing updates). Additionally, the aggregator (Fannie) learns something about the distribution of each participant's data through the gradients, which may have competitive sensitivity. Secure aggregation protocols (computing the sum of gradients without the aggregator seeing individual updates) address this. In practice, the infrastructure complexity is high — expect to use frameworks like PySyft, Flower (flwr), or TensorFlow Federated, and the governance framework (who owns the global model, how updates are versioned, how free riders are prevented) is as complex as the technical implementation.

**Q7: Your data science team wants to use GPT-4 (via the OpenAI API) to analyze underwriter notes for feature extraction. What privacy concerns do you raise?**

A: This is a critical risk scenario. Underwriter notes in mortgage files almost certainly contain PII: borrower names, SSNs, income figures, employer names, property addresses. Sending this data to a third-party LLM API means: (1) GLBA Safeguards Rule concerns — customer information is being transmitted to a third party; the privacy notice must have disclosed this use; (2) Data residency and storage — OpenAI's default API terms (as of 2024/2025) do not use API inputs to train models if opted out, but you must confirm the business associate agreement or data processing terms cover financial PII; (3) CCPA implications — this constitutes "sharing" personal information with a third party; (4) Model memorization risk — if you are fine-tuning rather than zero-shot prompting, you risk memorization of PII in the fine-tuned model. My recommendation: either deploy a self-hosted model (Azure OpenAI in your tenant, which keeps data within your control boundary), or implement a Presidio-based PII scrubbing pipeline that anonymizes notes before sending to any external API. The business case for external API convenience must be weighed against these regulatory risks, and legal must sign off.

**Q8: What is a DPIA and when would you need one for a mortgage ML project?**

A: A Data Protection Impact Assessment (DPIA) is a structured process required under GDPR (Article 35) before undertaking processing that is "likely to result in a high risk" to individuals. While GDPR is EU law, the concept is increasingly being adopted in US state privacy laws (CPRA requires "privacy impact assessments" for high-risk processing). In a mortgage ML context, a DPIA is required (or strongly advisable) when: (1) building automated credit decision systems — these make systematic decisions about individuals with significant effects; (2) processing sensitive data (income, credit history, race/ethnicity for HMDA) at scale; (3) implementing profiling or segmentation systems; (4) using a new technology (biometrics, location data) in ways not previously assessed. The DPIA documents: what data is processed and why, the necessity and proportionality, the risks and mitigations, and who is consulted (DPO, legal, business). For a US-only mortgage ML team, you may not be strictly GDPR-bound, but having a DPIA-equivalent document for high-risk models is excellent MRM (model risk management) practice and directly supports SR 11-7 compliance.

---

## Pro Tips for Senior Data Engineers

1. **Build consent flags into your data model from day one.** A boolean column `ml_training_consent` on the borrower table, populated at consent collection time, is far cheaper than retroactively auditing training sets when CCPA requests arrive.

2. **Treat your training datasets as first-class data assets in your catalog.** Register them in Purview or your data catalog with the originating table lineage attached. If you cannot answer "which training dataset was used for model version X," you cannot comply with deletion requests.

3. **Never use production SSNs or account numbers in dev or test environments.** This sounds obvious but is routinely violated. Implement a Snowflake masking policy or SQL Server Dynamic Data Masking in lower environments by default, not as an opt-in.

4. **Synthetic data for development is not a luxury — it is a compliance control.** Invest in a synthetic data pipeline (SDV/CTGAN for tabular mortgage data) so developers never need to request production data pulls.

5. **Audit your model outputs, not just your model inputs.** A model that outputs predicted default probabilities rounded to many decimal places may be leaking information about the training distribution. Round or bucket outputs to the precision needed for the business decision.

6. **Know the difference between pseudonymization and anonymization.** Replacing SSN with a hash is pseudonymization — it is still personal data under GDPR/CCPA if re-linkage is possible. True anonymization must be irreversible. Most ML features that include loan IDs or borrower tokens are pseudonymized, not anonymized.

7. **Privacy by design beats privacy by retrofit.** In every new ML feature pipeline design review, include a PII field inventory step. Map every field to its regulatory sensitivity before writing the first line of ETL code.

---

*Last updated: March 2026 | Part of AI in Data Engineering Interview Prep series*
