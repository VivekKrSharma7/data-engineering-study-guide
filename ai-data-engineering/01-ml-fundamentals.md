# ML Fundamentals for Data Engineers
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

Machine learning (ML) is the practice of training algorithms to learn patterns from data and make predictions or decisions without being explicitly programmed for every case. For a senior data engineer, ML is not a foreign discipline — it is an extension of the data work you already do. The pipelines you build, the feature tables you design, and the data quality you enforce are the foundation every ML model depends on.

This guide bridges your deep SQL Server and Snowflake expertise with core ML concepts, explains where data engineering ends and data science begins, and prepares you to answer interview questions about ML in data platform contexts.

---

## Learning Type Taxonomy

| Type | Definition | Example | DE Relevance |
|---|---|---|---|
| Supervised | Model learns from labeled input-output pairs | Predict loan default (label: defaulted Y/N) | You build the labeled feature tables |
| Unsupervised | Model finds structure in unlabeled data | Cluster borrowers by behavior | You build the raw feature store |
| Reinforcement | Agent learns by trial-and-error with rewards | Portfolio rebalancing agents | Less common in DE pipelines |
| Semi-supervised | Mix of labeled and unlabeled data | Fraud detection with few known cases | You manage label propagation pipelines |

---

## Key Concepts

### 1. Supervised Learning: Regression vs. Classification

**Regression** predicts a continuous numeric value.
- Example: Predicting a loan's prepayment speed (CPR — Conditional Prepayment Rate).
- SQL analogy: Think of regression as a weighted `AVG()` across features. Instead of equal weights, the model learns optimal coefficients.

**Classification** predicts a discrete category.
- Example: Will this loan default in the next 90 days? (Binary: Yes/No)
- Multi-class: Which delinquency bucket will this loan fall into? (Current, 30-DPD, 60-DPD, 90+)
- SQL analogy: Like a `CASE WHEN` with learned boundaries instead of hard-coded thresholds.

### 2. Unsupervised Learning: Clustering

**Clustering** groups data points by similarity without labels.
- Example: Segment MBS pools by prepayment behavior for pricing models.
- SQL analogy: Like `GROUP BY` on features you cannot name yet — the model discovers the groups.

Common algorithms:
- **k-Means**: Assign each point to the nearest of k centroids. Fast, scalable.
- **DBSCAN**: Density-based; handles irregular shapes and outliers well.
- **Hierarchical**: Builds a tree of clusters. Useful when k is unknown.

### 3. Bias-Variance Tradeoff

| Term | Meaning | Symptom |
|---|---|---|
| High Bias (Underfitting) | Model is too simple; misses patterns | High error on training AND test data |
| High Variance (Overfitting) | Model memorizes training data; fails on new data | Low training error, high test error |
| Sweet spot | Model generalizes well | Low error on both training and held-out data |

**DE implication:** Overfitting is often a data problem. Leaky features (data from the future sneaking into training), duplicate rows, or imbalanced classes all cause misleading variance metrics. You will be asked to audit pipelines for these issues.

### 4. Train / Validation / Test Split

```
All Data
├── Training Set   (~70%)  — model sees this; learns weights
├── Validation Set (~15%)  — tuning hyperparameters; NOT used for final eval
└── Test Set       (~15%)  — final held-out evaluation; touched once
```

**For time-series data (loan performance):** Never split randomly. Use a **temporal split** — train on older vintages, test on recent ones. Random splits leak future information.

```python
# Temporal split — correct for loan time-series
df = df.sort_values("reporting_date")
cutoff = df["reporting_date"].quantile(0.80)
train = df[df["reporting_date"] < cutoff]
test  = df[df["reporting_date"] >= cutoff]
```

### 5. Cross-Validation

**k-Fold CV** splits data into k folds, trains k models (each using a different fold as validation), and averages the results. Reduces variance in model evaluation.

```python
from sklearn.model_selection import cross_val_score
from sklearn.ensemble import RandomForestClassifier

scores = cross_val_score(
    RandomForestClassifier(n_estimators=100, random_state=42),
    X_train, y_train,
    cv=5,
    scoring="roc_auc"
)
print(f"CV AUC: {scores.mean():.4f} ± {scores.std():.4f}")
```

**TimeSeriesSplit** for sequential data — preserves temporal order across folds.

---

## Common Algorithms

### Linear Regression
Fits a straight line (or hyperplane) through data: `y = β₀ + β₁x₁ + β₂x₂ + ... + ε`

- Assumptions: linearity, homoscedasticity, no multicollinearity.
- Use when: relationship is roughly linear and interpretability matters.
- DE note: Feature scaling (StandardScaler) is required; correlated features (multicollinearity) degrade coefficients.

### Decision Trees
Recursively splits data on the feature that maximizes information gain (or minimizes Gini impurity).

- Interpretable — you can read the rules.
- Prone to overfitting on their own.
- SQL analogy: A deeply nested `CASE WHEN` tree, but learned from data.

### Random Forest
An ensemble of decision trees trained on random subsets of data (bagging) and random subsets of features. Averages predictions across trees.

- Handles missing values and non-linear relationships well.
- Feature importance scores are useful for feature selection.
- Scales well to large datasets with Spark MLlib.

### XGBoost (Gradient Boosted Trees)
Builds trees sequentially; each tree corrects the errors of the previous one (boosting). State-of-the-art for tabular data.

- Often wins Kaggle competitions on structured data.
- Sensitive to hyperparameter tuning (learning rate, max depth, subsample).
- Works extremely well on loan performance features.

### k-Nearest Neighbors (k-NN)
Classifies a new point based on the majority class of its k nearest neighbors.

- Simple, non-parametric, no training phase.
- Computationally expensive at inference time on large datasets.
- Sensitive to feature scale — always normalize inputs.

---

## Model Evaluation Metrics

### Regression Metrics

| Metric | Formula | Interpretation |
|---|---|---|
| MAE | `mean(|y - ŷ|)` | Average absolute error; same units as target |
| RMSE | `sqrt(mean((y - ŷ)²))` | Penalizes large errors more; sensitive to outliers |
| R² | `1 - SS_res/SS_tot` | Proportion of variance explained; 1.0 is perfect |
| MAPE | `mean(|y - ŷ| / y) * 100` | Percentage error; avoid when y can be zero |

### Classification Metrics

| Metric | Formula | When to use |
|---|---|---|
| Accuracy | `(TP+TN)/(TP+TN+FP+FN)` | Only when classes are balanced |
| Precision | `TP/(TP+FP)` | When false positives are costly (fraud flags) |
| Recall | `TP/(TP+FN)` | When false negatives are costly (missed defaults) |
| F1 Score | `2 * P*R / (P+R)` | Harmonic mean; good for imbalanced classes |
| AUC-ROC | Area under ROC curve | Threshold-independent ranking quality; 0.5 = random |
| PR-AUC | Area under Precision-Recall curve | Better than ROC when positive class is rare |

**Mortgage context:** For default prediction, recall matters more than precision. Missing a real default (false negative) is more costly than flagging a non-default (false positive).

---

## Python Code Examples

### Full sklearn Pipeline for Loan Default Prediction

```python
import pandas as pd
import numpy as np
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler, OneHotEncoder
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.metrics import classification_report, roc_auc_score
import xgboost as xgb

# --- Load feature table (built in Snowflake, exported) ---
df = pd.read_parquet("loan_features.parquet")

NUMERIC_FEATURES = ["ltv", "dti", "fico_score", "loan_age_months",
                    "current_balance", "rate_spread", "hpa_12m"]
CATEGORICAL_FEATURES = ["loan_purpose", "property_type", "occupancy_type"]
TARGET = "default_90dpd_flag"

X = df[NUMERIC_FEATURES + CATEGORICAL_FEATURES]
y = df[TARGET]

# Temporal split — do NOT use random split for loan data
cutoff_idx = int(len(df) * 0.80)
X_train, X_test = X.iloc[:cutoff_idx], X.iloc[cutoff_idx:]
y_train, y_test = y.iloc[:cutoff_idx], y.iloc[cutoff_idx:]

# --- Preprocessing pipeline ---
numeric_transformer = Pipeline([
    ("scaler", StandardScaler())
])
categorical_transformer = Pipeline([
    ("ohe", OneHotEncoder(handle_unknown="ignore", sparse_output=False))
])
preprocessor = ColumnTransformer([
    ("num", numeric_transformer, NUMERIC_FEATURES),
    ("cat", categorical_transformer, CATEGORICAL_FEATURES)
])

# --- Model pipeline ---
model_pipeline = Pipeline([
    ("prep", preprocessor),
    ("clf", xgb.XGBClassifier(
        n_estimators=400,
        max_depth=5,
        learning_rate=0.05,
        subsample=0.8,
        colsample_bytree=0.8,
        scale_pos_weight=(y_train == 0).sum() / (y_train == 1).sum(),  # handle imbalance
        eval_metric="auc",
        random_state=42,
        n_jobs=-1
    ))
])

model_pipeline.fit(X_train, y_train)

# --- Evaluation ---
y_pred_proba = model_pipeline.predict_proba(X_test)[:, 1]
print(f"Test AUC-ROC: {roc_auc_score(y_test, y_pred_proba):.4f}")
print(classification_report(y_test, model_pipeline.predict(X_test)))
```

### Feature Importance Extraction

```python
# Extract feature names after OHE
ohe_features = (model_pipeline.named_steps["prep"]
                .named_transformers_["cat"]
                .named_steps["ohe"]
                .get_feature_names_out(CATEGORICAL_FEATURES))
all_features = NUMERIC_FEATURES + list(ohe_features)

importances = (model_pipeline.named_steps["clf"]
               .feature_importances_)
feat_df = (pd.DataFrame({"feature": all_features, "importance": importances})
           .sort_values("importance", ascending=False)
           .head(15))
print(feat_df)
```

### Writing Predictions Back to Snowflake

```python
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

predictions_df = X_test.copy()
predictions_df["default_probability"] = y_pred_proba
predictions_df["loan_id"] = df.iloc[cutoff_idx:]["loan_id"].values
predictions_df["model_version"] = "xgb_v1.2"
predictions_df["scored_at"] = pd.Timestamp.utcnow()

conn = snowflake.connector.connect(
    account="myaccount",
    user="svc_mlops",
    private_key_file="/secrets/rsa_key.p8",
    warehouse="ML_WH",
    database="MORTGAGE_DB",
    schema="ML_SCORES"
)

write_pandas(conn, predictions_df[["loan_id", "default_probability",
                                   "model_version", "scored_at"]],
             "DEFAULT_PREDICTIONS", auto_create_table=True)
conn.close()
```

---

## SQL Analogies for ML Concepts

```sql
-- REGRESSION analogy: weighted average with learned coefficients
-- Real regression: y = 0.3*fico + 0.5*ltv + 0.2*dti + intercept
-- SQL approximation (manual coefficients):
SELECT
    loan_id,
    0.30 * (fico_score / 850.0)
  + 0.50 * (ltv / 100.0)
  + 0.20 * (dti / 50.0) AS manual_risk_score
FROM loan_features;

-- CLUSTERING analogy: GROUP BY on discovered segments
-- k-Means result stored back as a label in Snowflake:
SELECT
    cluster_label,
    COUNT(*)              AS loan_count,
    AVG(cpr_12m)          AS avg_prepay_speed,
    AVG(default_rate)     AS avg_default_rate,
    AVG(fico_score)       AS avg_fico
FROM loan_cluster_scores
GROUP BY cluster_label
ORDER BY avg_default_rate DESC;

-- TRAIN/TEST SPLIT analogy using ROW_NUMBER and date logic
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (ORDER BY origination_date) AS rn,
        COUNT(*) OVER ()                              AS total_count
    FROM loan_features
)
SELECT
    *,
    CASE WHEN rn <= total_count * 0.80 THEN 'TRAIN' ELSE 'TEST' END AS split_flag
FROM ranked;
```

---

## How ML Differs from Traditional ETL Work

| Dimension | Traditional ETL | ML Pipelines |
|---|---|---|
| Output | Clean, transformed data | Predictions, scores, embeddings |
| Reproducibility | Deterministic | Stochastic (seeds matter) |
| Validation | Row counts, nulls, schema | AUC, drift metrics, data distribution |
| Versioning | Table versions, CDC | Model versions, feature store versions |
| Latency | Batch acceptable | May require sub-second inference |
| Failure modes | Missing rows, wrong joins | Silent degradation (model drift) |
| Monitoring | Pipeline SLA alerts | Model performance alerts, data drift |

---

## Data Engineering Role in ML

Your job as a DE in ML systems:

1. **Feature Engineering Pipelines** — Build and maintain Snowflake tables that compute features at the right grain, on schedule, with no future leakage.
2. **Feature Store Integration** — Register features in tools like Feast, Tecton, or Snowflake Feature Store. Ensure training and serving features are identical (training-serving skew kills models).
3. **Model Serving Infrastructure** — Containerize model artifacts, build REST API wrappers, write inference results back to the data warehouse.
4. **Data Quality for ML** — Label quality checks, class distribution monitoring, outlier detection. A model trained on bad labels learns bad behavior.
5. **Retraining Pipelines** — Automate model retraining on a schedule or when drift is detected. Archive model artifacts and evaluation metrics.
6. **Experiment Tracking** — Integrate MLflow or W&B into pipelines to capture hyperparameters, metrics, and data versions for every run.

---

## Interview Q&A

**Q1: You are asked to build a pipeline that predicts 90-day loan default probability. Walk me through the full data engineering work required before a model can be trained.**

**A:** I would start by identifying the label source — typically a loan performance history table tracking delinquency status by reporting month. I would define the label as: was this loan 90+ DPD within the next 6 months from the observation date? This requires careful point-in-time feature construction to avoid leakage — every feature for a given observation date must use only data available as of that date, not data from the future.

Next I would build a feature table in Snowflake with a grain of `(loan_id, observation_date)`. Features would include static loan attributes (FICO, LTV, DTI, product type) and dynamic features computed at the observation date (loan age, current balance, payment history, house price appreciation from an external index). I would implement dbt models for this, with tests on null rates, value distributions, and date integrity.

I would implement a temporal train/test split — training on loans observed before a cutoff date, testing on loans observed after. I would document the feature definitions, register them in a feature store, and snapshot the training dataset to S3/Azure Blob with a version tag for reproducibility.

---

**Q2: What is training-serving skew and how do you prevent it?**

**A:** Training-serving skew occurs when the features fed to the model at inference time are computed differently than the features used during training. For example, during training you computed a rolling 12-month average payment count from a historical table, but at serving time you query a real-time table that uses a slightly different date window or includes incomplete current-month data.

Prevention strategies: (1) Use a feature store where training and serving both call the same feature computation logic. (2) Log the feature values used for every prediction and periodically compare their distribution to the training distribution. (3) Write integration tests that run the training feature pipeline and the serving feature pipeline on the same loan and assert identical outputs. (4) Pin dependency versions and timestamp all external data sources used in feature computation.

---

**Q3: What is the difference between RMSE and MAE? When would you use each for a mortgage model?**

**A:** MAE (Mean Absolute Error) treats all errors equally — a 10-unit error counts exactly 10 times as much as a 1-unit error. RMSE (Root Mean Square Error) squares errors before averaging, so large errors are penalized disproportionately.

For prepayment speed (CPR) prediction, where the cost of being 5 CPR off on a $500M pool is vastly more consequential than being 1 CPR off on a small pool, RMSE is more appropriate because it punishes large errors more heavily, aligning with business consequences. For a model predicting monthly escrow shortfall where large errors are rare outliers that should not dominate the metric, MAE gives a more stable, interpretable picture of average model performance.

---

**Q4: Explain the bias-variance tradeoff in terms a business stakeholder would understand.**

**A:** Imagine you are estimating how fast a specific pool of mortgages will prepay next year. A model with high bias is oversimplified — it might just predict the historical average prepayment for all pools, ignoring the current interest rate environment. It is consistently wrong in the same direction. A model with high variance is oversensitive — it memorized last year's specific pool behaviors and fails to generalize to new pools with similar characteristics. Both types of errors cost money.

The goal is a model that is complex enough to capture real patterns (low bias) but simple enough to generalize to new data (low variance). We control this tradeoff by choosing the right model complexity, applying regularization, and using cross-validation to detect overfitting early.

---

**Q5: How does XGBoost differ from a Random Forest, and when would you prefer one over the other?**

**A:** Both are ensembles of decision trees, but they build trees differently. Random Forest uses bagging — trains many trees independently in parallel on random subsets, then averages their predictions. XGBoost uses boosting — trains trees sequentially, where each tree focuses on correcting the mistakes of the previous ensemble.

XGBoost typically achieves higher accuracy on tabular data because it directly optimizes a loss function and corrects errors iteratively. Random Forest is faster to train (parallelizable), more robust to hyperparameter settings, less prone to overfitting with default settings, and easier to deploy in restricted environments. For a loan default model where I have time to tune hyperparameters and the target is maximizing AUC, I would start with XGBoost. For a rapid prototype or a model that needs to train quickly on a schedule, I would use Random Forest.

---

**Q6: What is AUC-ROC and what does a value of 0.72 mean in practice for a default model?**

**A:** AUC-ROC measures how well the model ranks positive examples (defaults) above negative examples (non-defaults) across all possible classification thresholds. A value of 0.5 means the model is no better than random. A value of 1.0 means it perfectly separates defaults from non-defaults. A value of 0.72 means that if you randomly pick one loan that eventually defaulted and one that did not, the model will correctly rank the defaulting loan as higher risk 72% of the time.

In mortgage modeling, AUC of 0.72 on a 90-DPD default flag is reasonable for a simple model but would likely be improved by adding macroeconomic features (unemployment rate, HPI), servicer behavior variables, and more granular payment history. Industry credit risk models on well-prepared data often achieve 0.80–0.88 AUC.

---

**Q7: How would you detect and handle class imbalance in a default prediction dataset where only 2% of loans default?**

**A:** First I would confirm the imbalance with a simple value count. With 2% positives, a model that predicts "no default" for every loan gets 98% accuracy but is completely useless — accuracy is the wrong metric here.

Handling strategies: (1) **Resampling** — oversample the minority class with SMOTE (Synthetic Minority Over-sampling Technique) or undersample the majority class. (2) **Class weights** — pass `class_weight="balanced"` to sklearn classifiers or `scale_pos_weight` to XGBoost; this penalizes misclassification of the minority class more heavily. (3) **Threshold tuning** — instead of using 0.5 as the decision threshold, find the threshold that maximizes F1 or meets a specific recall target on the validation set. (4) **Evaluation metrics** — use PR-AUC (Precision-Recall AUC) rather than ROC-AUC, since PR-AUC is more sensitive to minority class performance when the class is rare.

---

**Q8: A data scientist hands you a Jupyter notebook that produces a model. How do you productionize it as a data engineer?**

**A:** I treat the notebook as a specification, not production code. My steps: (1) **Extract and refactor** — pull the feature computation logic into dbt models or a Python module with unit tests, separate from model training code. (2) **Parameterize** — replace hardcoded values (dates, file paths, thresholds) with config files or environment variables. (3) **Package** — create a Python package or Docker image with pinned dependency versions (`requirements.txt` or `pyproject.toml` with hashes). (4) **Orchestrate** — build an Airflow (or Prefect) DAG with separate tasks for: data validation, feature computation, model training, model evaluation, model registration (MLflow), and score writing. (5) **Register** — log model artifacts, hyperparameters, and evaluation metrics to MLflow. Gate promotion to production on AUC exceeding a threshold. (6) **Monitor** — add data drift detection (Evidently or custom SQL queries) that alerts when feature distributions shift significantly from the training distribution.

---

**Q9: What is cross-validation and why is k-fold CV inappropriate for time-series loan data?**

**A:** Cross-validation is a technique for estimating model performance by training and evaluating on multiple non-overlapping subsets of the data. Standard k-fold CV randomly assigns rows to k folds and rotates which fold is used for validation.

This is inappropriate for time-series loan data because loans are not independent across time — there are macroeconomic correlations, seasonal patterns, and policy regime shifts. If fold 3 contains loans from 2020 (pandemic shock) and fold 1 contains loans from 2022 (rate hike cycle), a model trained on fold 1 and validated on fold 3 is effectively seeing "future" patterns during training. This gives optimistically biased performance estimates.

The correct approach is `TimeSeriesSplit` (sklearn) or a custom walk-forward validation: always train on older observations, validate on strictly newer ones. Each fold's validation window should be entirely after its training window with no overlap.

---

**Q10: Explain what a feature store is and why a data engineer should own it, not the data science team.**

**A:** A feature store is a centralized repository that stores, versions, and serves pre-computed feature values for use in both model training and real-time inference. It decouples feature computation (DE work) from model training (DS work).

Data engineers should own the feature store because features are fundamentally data artifacts: they require the same data quality guarantees, SLA commitments, lineage tracking, and governance as any production table. Data scientists should be consumers of features, not producers. If a data scientist computes a feature ad hoc in a notebook using slightly different logic than what runs in the serving pipeline, you get training-serving skew and degraded model performance. The DE ensures that features are computed once, tested, versioned, and served identically at training and inference time — exactly the kind of work data engineers are already doing for analytics tables.

---

## Pro Tips

- Always audit feature tables for **point-in-time correctness** before any model training. One future-leaking feature can make a 0.65 AUC model look like 0.92 AUC.
- When a data scientist reports surprisingly good model performance, your first instinct should be to check for data leakage, not celebrate.
- Scale numeric features before training k-NN, SVMs, or linear models. Tree-based models (RF, XGBoost) do not require scaling.
- In mortgage/MBS contexts, always prefer **temporal splits** over random splits. The industry standard is to validate on out-of-sample vintages.
- Feature importance scores from tree models are useful for feature selection and business communication, but they are sensitive to correlated features — correlated features split importance between themselves and each appears less important than it truly is.
- XGBoost's `scale_pos_weight = negative_count / positive_count` is a fast, effective first step for handling class imbalance without resampling.
- When writing model scores back to SQL Server or Snowflake, always include `model_version`, `scored_at`, and `pipeline_run_id` columns. You will thank yourself when debugging a score regression six months later.
- The distinction between a **model** and a **pipeline** matters in interviews: the model is the artifact that makes predictions; the pipeline is everything around it — data extraction, feature computation, preprocessing, inference, and score storage.
