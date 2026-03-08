# Apache Spark MLlib for Distributed ML

[Back to Index](../README.md)

---

## Overview

Apache Spark MLlib is Spark's built-in distributed machine learning library, designed to run ML algorithms across clusters at massive scale. For a senior data engineer working in the secondary mortgage market — where you may need to score millions of loans, compute prepayment risk across a portfolio, or train models on years of origination history — MLlib bridges the gap between your existing Spark data pipelines and production ML.

MLlib operates on the same DataFrames you already use for ETL, making it a natural extension of Spark-based workflows rather than a separate toolchain. Unlike scikit-learn (single node) or Snowflake ML (in-warehouse), Spark MLlib scales horizontally and integrates directly with Databricks, Delta Lake, and the Snowflake Spark Connector.

---

## Key Concepts

| Concept | Description |
|---|---|
| Pipeline API | Chain of Transformers and Estimators, similar to scikit-learn Pipeline |
| Transformer | Stateless: transforms a DataFrame (e.g., VectorAssembler, StandardScaler after fit) |
| Estimator | Has a `.fit()` method that produces a Transformer (e.g., LogisticRegression) |
| PipelineModel | Fitted Pipeline that can transform new data |
| ParamGridBuilder | Grid search over hyperparameters |
| CrossValidator | K-fold CV with evaluator metric |
| Evaluator | BinaryClassificationEvaluator, RegressionEvaluator, MulticlassClassificationEvaluator |
| ML vs MLlib | `spark.ml` = DataFrame API (current); `spark.mllib` = RDD API (legacy) |

---

## Spark ML vs Spark MLlib vs Other Options

```
Decision Matrix:

Data Scale     | Framework           | Notes
---------------|---------------------|------------------------------------------
< 10M rows     | scikit-learn        | Single node, rich ecosystem, fast iteration
10M–1B rows    | Spark ML (MLlib)    | Native Spark, runs on existing cluster
In Snowflake   | Snowflake ML        | No data movement, Snowpark Python
Deep learning  | PyTorch/TF + Spark  | Use Petastorm or TorchDistributor
Production NLP | HuggingFace + Spark | Pandas UDFs for inference at scale
```

**Rule of thumb for mortgage data:** If your training set fits in memory on a modern workstation (< 50GB), scikit-learn with joblib parallelism often beats the overhead of Spark cluster coordination. Use Spark ML when the data genuinely does not fit on one node, or when you want the trained model to live inside a Spark/Databricks pipeline.

---

## MLlib Pipeline API

### Core Building Blocks

```python
from pyspark.ml import Pipeline
from pyspark.ml.feature import (
    StringIndexer, OneHotEncoder, VectorAssembler,
    StandardScaler, Imputer
)
from pyspark.ml.classification import RandomForestClassifier
from pyspark.ml.evaluation import BinaryClassificationEvaluator
from pyspark.ml.tuning import ParamGridBuilder, CrossValidator

# Assume df has these columns from a Snowflake loan table:
# loan_purpose (string), credit_score (double), ltv (double),
# dti (double), property_type (string), default_flag (int)

# --- Stage 1: Handle nulls ---
imputer = Imputer(
    inputCols=["credit_score", "ltv", "dti"],
    outputCols=["credit_score_imp", "ltv_imp", "dti_imp"],
    strategy="median"
)

# --- Stage 2: Encode categoricals ---
loan_purpose_idx = StringIndexer(
    inputCol="loan_purpose",
    outputCol="loan_purpose_idx",
    handleInvalid="keep"   # unseen categories at inference time
)
property_type_idx = StringIndexer(
    inputCol="property_type",
    outputCol="property_type_idx",
    handleInvalid="keep"
)
ohe = OneHotEncoder(
    inputCols=["loan_purpose_idx", "property_type_idx"],
    outputCols=["loan_purpose_ohe", "property_type_ohe"]
)

# --- Stage 3: Assemble feature vector ---
assembler = VectorAssembler(
    inputCols=[
        "credit_score_imp", "ltv_imp", "dti_imp",
        "loan_purpose_ohe", "property_type_ohe"
    ],
    outputCol="features_raw"
)

# --- Stage 4: Scale ---
scaler = StandardScaler(
    inputCol="features_raw",
    outputCol="features",
    withMean=True,
    withStd=True
)

# --- Stage 5: Classifier ---
rf = RandomForestClassifier(
    featuresCol="features",
    labelCol="default_flag",
    numTrees=100,
    maxDepth=8,
    seed=42
)

# --- Build pipeline ---
pipeline = Pipeline(stages=[
    imputer, loan_purpose_idx, property_type_idx,
    ohe, assembler, scaler, rf
])
```

### Fit, Evaluate, Cross-Validate

```python
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("LoanDefaultModel").getOrCreate()

# Load from Snowflake via Spark connector
df = (spark.read
      .format("snowflake")
      .options(**sfOptions)   # account, warehouse, database, schema, role
      .option("dbtable", "MORTGAGE.ORIGINATION.LOAN_FEATURES")
      .load())

train, test = df.randomSplit([0.8, 0.2], seed=42)

# Hyperparameter grid
param_grid = (ParamGridBuilder()
    .addGrid(rf.numTrees, [50, 100, 200])
    .addGrid(rf.maxDepth, [5, 8, 12])
    .build())

evaluator = BinaryClassificationEvaluator(
    labelCol="default_flag",
    metricName="areaUnderROC"
)

cv = CrossValidator(
    estimator=pipeline,
    estimatorParamMaps=param_grid,
    evaluator=evaluator,
    numFolds=5,
    parallelism=4    # fit param combos in parallel
)

cv_model = cv.fit(train)
best_model = cv_model.bestModel

predictions = best_model.transform(test)
auc = evaluator.evaluate(predictions)
print(f"Test AUC: {auc:.4f}")

# Inspect feature importances from the RF stage
rf_model = best_model.stages[-1]
print(rf_model.featureImportances)
```

---

## Feature Transformers Reference

| Transformer | Use Case | Mortgage Example |
|---|---|---|
| `StringIndexer` | Categorical -> numeric index | loan_purpose, property_type |
| `OneHotEncoder` | Index -> sparse binary vector | After StringIndexer |
| `VectorAssembler` | Combine columns -> feature vector | All numeric + OHE features |
| `StandardScaler` | Zero mean, unit variance | Credit score, LTV, DTI |
| `MinMaxScaler` | Scale to [0,1] | When you need bounded inputs |
| `Bucketizer` | Continuous -> bins | LTV buckets: <80, 80-90, >90 |
| `QuantileDiscretizer` | Equal-frequency bins | Credit score deciles |
| `PCA` | Dimensionality reduction | Reduce correlated macro features |
| `Imputer` | Fill nulls with mean/median | Missing appraisal values |
| `Word2Vec` | Text -> dense vector | Servicer note embeddings |
| `HashingTF` + `IDF` | TF-IDF for text | Document classification |

---

## Algorithms Available in Spark ML

### Classification
```python
from pyspark.ml.classification import (
    LogisticRegression,
    RandomForestClassifier,
    GBTClassifier,           # Gradient Boosted Trees
    LinearSVC,
    NaiveBayes,
    MultilayerPerceptronClassifier
)

# GBT for delinquency prediction (often outperforms RF on tabular data)
gbt = GBTClassifier(
    featuresCol="features",
    labelCol="delinquent_90d",
    maxIter=100,
    maxDepth=6,
    stepSize=0.1,            # learning rate
    subsamplingRate=0.8,
    seed=42
)
```

### Regression
```python
from pyspark.ml.regression import (
    LinearRegression,
    RandomForestRegressor,
    GBTRegressor,
    GeneralizedLinearRegression   # GLM with link functions
)

# Prepayment speed (CPR) prediction
glm = GeneralizedLinearRegression(
    family="gamma",          # positive continuous target
    link="log",
    featuresCol="features",
    labelCol="cpr_actual",
    maxIter=50
)
```

### Clustering
```python
from pyspark.ml.clustering import KMeans, BisectingKMeans, LDA

# Segment loan portfolio into risk buckets
kmeans = KMeans(k=5, featuresCol="features", seed=42)
kmeans_model = kmeans.fit(loan_features_df)
loan_features_df = kmeans_model.transform(loan_features_df)
# New column "prediction" = cluster assignment 0-4
```

### Collaborative Filtering
```python
from pyspark.ml.recommendation import ALS

# ALS: useful for investor-product affinity models
als = ALS(
    maxIter=10,
    rank=50,
    regParam=0.1,
    userCol="investor_id",
    itemCol="product_id",
    ratingCol="purchase_volume",
    coldStartStrategy="drop"
)
```

---

## Distributed Feature Computation with Spark

Before feeding data to MLlib, heavy feature engineering often happens in Spark SQL/DataFrame API:

```python
from pyspark.sql import functions as F
from pyspark.sql.window import Window

# Rolling 12-month delinquency rate per servicer
servicer_window = (Window
    .partitionBy("servicer_id")
    .orderBy("report_month")
    .rowsBetween(-11, 0))

loan_history = loan_history.withColumn(
    "rolling_dlq_rate",
    F.avg("is_delinquent").over(servicer_window)
)

# Vintage-level cohort features
vintage_agg = (loan_history
    .groupBy("origination_year", "origination_quarter")
    .agg(
        F.avg("credit_score").alias("vintage_avg_fico"),
        F.avg("ltv").alias("vintage_avg_ltv"),
        F.count("*").alias("vintage_loan_count"),
        F.sum("upb").alias("vintage_total_upb")
    ))

# Join back to loan level
df = df.join(vintage_agg, ["origination_year", "origination_quarter"])
```

---

## Structured Streaming + MLlib

Apply a pre-trained PipelineModel to a real-time loan application stream:

```python
# Load pre-fitted model from MLflow
import mlflow.spark

model_uri = "models:/LoanDefaultClassifier/Production"
loaded_model = mlflow.spark.load_model(model_uri)

# Streaming source (Kafka -> Delta Lake)
stream_df = (spark.readStream
    .format("delta")
    .load("/mnt/bronze/loan_applications"))

scored_stream = loaded_model.transform(stream_df)

# Write scored applications to Delta silver layer
query = (scored_stream
    .select("loan_id", "probability", "prediction", "application_ts")
    .writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", "/mnt/checkpoints/loan_scoring")
    .trigger(processingTime="30 seconds")
    .start("/mnt/silver/loan_scores"))
```

---

## Databricks MLflow Integration

```python
import mlflow
import mlflow.spark
from mlflow.models.signature import infer_signature

mlflow.set_experiment("/Shared/MortgageML/LoanDefault")

with mlflow.start_run(run_name="rf_pipeline_v3") as run:
    # Log hyperparameters
    mlflow.log_param("num_trees", 100)
    mlflow.log_param("max_depth", 8)
    mlflow.log_param("train_size", train.count())

    # Fit model
    model = pipeline.fit(train)

    # Evaluate
    preds = model.transform(test)
    auc = evaluator.evaluate(preds)
    mlflow.log_metric("test_auc", auc)

    # Log the Spark ML model
    signature = infer_signature(
        train.drop("default_flag").limit(5).toPandas(),
        preds.select("prediction", "probability").limit(5).toPandas()
    )
    mlflow.spark.log_model(
        model,
        "spark_model",
        signature=signature,
        registered_model_name="LoanDefaultClassifier"
    )

    # Feature importance artifact
    rf_stage = model.stages[-1]
    fi = rf_stage.featureImportances.toArray().tolist()
    mlflow.log_dict({"importances": fi}, "feature_importances.json")

print(f"Run ID: {run.info.run_id}")
```

---

## Snowflake + Spark Connector for ML

```python
# Snowflake Spark Connector options
sf_options = {
    "sfURL": "myorg-myaccount.snowflakecomputing.com",
    "sfUser": "svc_spark_ml",
    "sfPassword": dbutils.secrets.get("snowflake", "password"),
    "sfDatabase": "MORTGAGE_DW",
    "sfSchema": "ML_FEATURES",
    "sfWarehouse": "COMPUTE_WH_XL",
    "sfRole": "ML_ENGINEER"
}

# Read feature table from Snowflake
features_df = (spark.read
    .format("snowflake")
    .options(**sf_options)
    .option("query", """
        SELECT
            loan_id,
            credit_score,
            ltv,
            dti,
            loan_purpose,
            property_type,
            orig_upb,
            note_rate,
            months_since_origination,
            default_flag
        FROM LOAN_ML_FEATURES
        WHERE partition_dt >= DATEADD(year, -5, CURRENT_DATE)
    """)
    .load())

# Train MLlib model on Snowflake data
model = pipeline.fit(features_df)

# Write scored results back to Snowflake
(predictions
    .select("loan_id", "prediction", "probability")
    .write
    .format("snowflake")
    .options(**sf_options)
    .option("dbtable", "LOAN_DEFAULT_SCORES")
    .mode("overwrite")
    .save())
```

---

## Interview Q&A

**Q1: What is the difference between `spark.ml` and `spark.mllib`, and which should you use in 2025?**

Use `spark.ml` exclusively. The `spark.mllib` (RDD-based) API entered maintenance mode in Spark 2.0 and was effectively frozen — no new algorithms, bug fixes only. `spark.ml` operates on DataFrames, which gives you predicate pushdown, columnar storage (Parquet/Delta), Catalyst optimizer integration, and natural interop with Spark SQL. Any new project should use `spark.ml` Pipeline API.

---

**Q2: When would you choose Spark MLlib over scikit-learn for a mortgage ML project?**

Choose Spark MLlib when: (1) training data genuinely exceeds single-node memory — e.g., 10 years of monthly loan performance with 50M+ rows; (2) the feature engineering pipeline already runs in Spark and you want to avoid serializing data to a pandas DataFrame; (3) you need to score hundreds of millions of loans in batch and want to leverage cluster parallelism for inference. Choose scikit-learn when the dataset fits in memory, iteration speed matters (local training is faster for small data), or you need algorithms not in MLlib (e.g., HDBSCAN, XGBoost with DART). In practice, most mortgage ML teams use scikit-learn or XGBoost for model development and Spark for large-scale batch scoring via pandas UDFs.

---

**Q3: How does the Pipeline API handle the train/test leakage problem with scalers and encoders?**

Correctly — but only if you follow the pattern. The Pipeline calls `.fit()` only on training data. That fit computes the scaler mean/std, the StringIndexer vocabulary, and the Imputer medians from train only. When you call `pipeline.fit(train)`, it propagates the fit through all Estimator stages sequentially. The resulting `PipelineModel` contains only Transformers (fitted artifacts), so calling `.transform(test)` applies the training-set statistics to test data without re-fitting. CrossValidator preserves this — it fits on the training fold and evaluates on the validation fold, preventing leakage.

---

**Q4: Explain how you would tune a GBTClassifier for loan default prediction using Spark ML.**

```python
from pyspark.ml.tuning import ParamGridBuilder, TrainValidationSplit

gbt = GBTClassifier(labelCol="default_flag", featuresCol="features")

param_grid = (ParamGridBuilder()
    .addGrid(gbt.maxIter, [50, 100])
    .addGrid(gbt.maxDepth, [4, 6, 8])
    .addGrid(gbt.stepSize, [0.05, 0.1])
    .addGrid(gbt.subsamplingRate, [0.7, 0.9])
    .build())

# TrainValidationSplit is faster than CrossValidator (single split)
tvs = TrainValidationSplit(
    estimator=Pipeline(stages=[...feature_stages..., gbt]),
    estimatorParamMaps=param_grid,
    evaluator=BinaryClassificationEvaluator(
        labelCol="default_flag", metricName="areaUnderROC"
    ),
    trainRatio=0.8,
    parallelism=8
)
tvs_model = tvs.fit(train)
```

For imbalanced default data (typical in mortgage — default rates 1–3%), also set `weightCol` with inverse-frequency class weights, and prefer `areaUnderPR` over `areaUnderROC` as the evaluation metric since it is more sensitive to minority class performance.

---

**Q5: How would you score 50 million active loans with a pre-trained Spark ML model efficiently?**

Load the serialized PipelineModel from MLflow or Delta, then call `.transform()` on the full dataset partitioned appropriately. Key tuning points: (1) partition count — aim for 2–4 partitions per CPU core; (2) broadcast the model artifact if it is small enough (`spark.sql.autoBroadcastJoinThreshold`); (3) use `spark.ml.transform.batchSize` for neural network stages; (4) write output to Delta with Z-ordering on `loan_id` for downstream lookup performance. For Snowflake data, use the Spark connector with pushdown enabled so filters and projections reduce data transferred. If the model is scikit-learn or XGBoost (not Spark-native), wrap it in a Pandas UDF with `PandasUDFType.SCALAR_ITER` to amortize model loading cost per partition.

---

**Q6: What is the difference between BinaryClassificationEvaluator and a custom threshold-based metric, and when does it matter for mortgage risk models?**

`BinaryClassificationEvaluator` with `areaUnderROC` or `areaUnderPR` is threshold-agnostic — it summarizes model discrimination across all thresholds. This is appropriate during model selection. However, for a production mortgage risk model, you ultimately need a decision threshold: "flag loans with P(default) > X for manual review." The optimal threshold depends on the business cost matrix — false negative cost (missing a default) vs. false positive cost (rejecting a good loan). Compute threshold-specific metrics (precision, recall, F-beta, KS statistic) using `predictions.select("probability", "default_flag")` converted to pandas after scoring. The KS statistic is particularly common in credit scoring contexts.

---

**Q7: How do you handle categorical features with high cardinality in Spark MLlib — for example, a servicer_id with 5,000 distinct values?**

Three approaches: (1) Target encoding — replace servicer_id with the mean default rate per servicer computed on training data only, stored as a lookup table joined via Spark SQL. Implement this as a custom Transformer to keep it inside the Pipeline. (2) Frequency encoding — replace with log(count) per category, less prone to leakage. (3) Hashing — use `FeatureHasher` which maps category strings to a fixed-size hash vector without building a vocabulary, avoiding cardinality issues at the cost of hash collisions. For mortgage servicers, target encoding with regularization (shrinkage toward the global mean) is typically most effective, since servicer quality genuinely predicts performance.

---

**Q8: Explain Spark ML's handling of sparse vs. dense vectors and when it matters for performance.**

`VectorAssembler` and `OneHotEncoder` produce `SparseVector` by default when the fraction of non-zero values is low. Sparse vectors store only the indices and values of non-zero elements, reducing memory and speeding up dot products in linear models. For RandomForest and GBT, Spark will convert to dense internally during tree splits. If you have a feature matrix that is genuinely dense (e.g., all numeric — credit score, LTV, DTI, rate), assembling as a dense vector avoids conversion overhead. The `VectorAssembler` has a `handleInvalid` parameter but no explicit density control; use `toDense()` on a VectorUDF or set `spark.ml.linalg.VectorUDF` if you need to force dense representation.

---

**Q9: How would you integrate Spark MLlib with Databricks Feature Store for a mortgage scoring pipeline?**

```python
from databricks.feature_store import FeatureStoreClient

fs = FeatureStoreClient()

# Create feature table (run once)
fs.create_table(
    name="mortgage_ml.loan_features",
    primary_keys=["loan_id", "report_month"],
    schema=feature_df.schema,
    description="Monthly loan-level ML features"
)

# Write features
fs.write_table("mortgage_ml.loan_features", feature_df, mode="merge")

# Train with Feature Store — automatic feature lookup at score time
from databricks.feature_store import FeatureLookup

feature_lookups = [
    FeatureLookup(
        table_name="mortgage_ml.loan_features",
        feature_names=["credit_score", "ltv", "dti", "rolling_dlq_rate"],
        lookup_key=["loan_id", "report_month"]
    )
]

training_set = fs.create_training_set(
    labels_df,          # DataFrame with loan_id, report_month, default_flag
    feature_lookups=feature_lookups,
    label="default_flag"
)

training_df = training_set.load_df()
model = pipeline.fit(training_df)

# Log to MLflow — feature metadata attached automatically
fs.log_model(model, "model", flavor=mlflow.spark, training_set=training_set)
```

This ensures that the same feature computation logic used during training is reused at inference, eliminating training/serving skew.

---

**Q10: What are the limitations of Spark MLlib compared to XGBoost or LightGBM for tabular mortgage data?**

Spark ML's GBT implementation lacks: histogram-based split finding (LightGBM's key speed optimization), native handling of missing values without imputation stages (XGBoost handles NaN natively), dart mode dropout, categorical feature support without encoding, and monotonic constraints (important for credit models where higher LTV should never decrease default probability). In practice, most production credit risk models use XGBoost or LightGBM trained on a single large node, then deployed for inference via pandas UDFs in Spark or via Snowflake Python UDFs. Spark ML GBT is appropriate when you need a pure-Spark pipeline with no external dependencies, or when data volume genuinely requires distributed training.

---

## Pro Tips

- **Persist intermediate DataFrames.** After heavy feature engineering and before fitting, call `df.cache()` or `df.persist(StorageLevel.MEMORY_AND_DISK)`. CrossValidator with 5 folds will recompute the entire DAG 5x otherwise.
- **Use `parallelism` in CrossValidator.** Setting `parallelism=8` on a 16-core cluster cuts CV time roughly 4x by fitting parameter combos concurrently.
- **Monitor with Spark UI.** Stage DAGs in the Spark UI reveal skewed partitions. Loan data often has servicer skew — one servicer with 40% of loans creates a hot partition. Repartition on a synthetic key (`loan_id % 200`) before training.
- **Serialize models to Delta.** `PipelineModel.save("dbfs:/models/loan_default/v3")` writes to Delta-compatible paths. Versioned model directories beat MLflow for ultra-low-latency loading in streaming jobs.
- **Test the Pipeline schema end-to-end.** Run `pipeline.fit(train.limit(1000))` locally before submitting a multi-hour cluster job. Schema mismatches surface immediately on small data.
- **StringIndexer `handleInvalid="keep"`.** Always set this. In production scoring, new origination channels or property types will appear that were never in training data. Without `keep`, the pipeline throws a runtime exception.
- **Feature importance is index-based.** `rf_model.featureImportances` returns a vector indexed by position in the assembled feature vector, not column names. Map indices back to names using `assembler.getInputCols()` and the OHE/StringIndexer output sizes.
