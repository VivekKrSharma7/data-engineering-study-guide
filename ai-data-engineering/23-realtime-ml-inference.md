# Real-time ML Inference Pipelines

[← Back to Index](README.md)

---

## Overview

Real-time ML inference is the infrastructure layer that takes a trained model and makes it available to answer questions in milliseconds — not hours. In the US secondary mortgage market, this translates to: flagging a suspicious loan application before it clears underwriting, scoring an incoming agency delivery for hedging purposes the moment it arrives, or ranking refinance leads for a servicer's outbound call center in near-real-time.

For a senior data engineer, the challenge is not training the model — that is largely the data scientist's domain. The challenge is building the serving infrastructure that is fast, reliable, observable, and safely deployable without taking down production systems.

---

## Inference Paradigms

### Real-time vs. Near-Real-time vs. Batch

| Paradigm | Latency Target | Trigger | State Required | Use Case (Mortgage) |
|---|---|---|---|---|
| Real-time (online) | < 100ms | Synchronous API call | Online feature store | Fraud check on loan application |
| Near-real-time | 1s – 30s | Kafka event / micro-batch | Streaming window | Risk scoring on rate lock requests |
| Batch | Minutes – hours | Schedule / Airflow DAG | Data warehouse | Daily portfolio prepayment scoring |

Real-time inference is the hardest. It requires pre-computed or very fast feature computation, model artifacts in memory, and infrastructure capable of handling traffic spikes. The engineering cost is 5–10x that of batch inference for the same model.

---

## Key Concepts

### Online Serving Requirements

**Latency budget breakdown for a 100ms SLA:**

```
Network ingress           ~5ms
Feature retrieval         ~10ms   (online feature store / Redis)
Feature transformation    ~5ms    (Python preprocessing)
Model inference           ~20ms   (in-memory model)
Post-processing           ~5ms    (threshold, calibration)
Response serialization    ~5ms    (JSON marshal)
Network egress            ~5ms    (response)
Overhead / buffer         ~45ms
─────────────────────────────────
Total                     ~100ms
```

Every component in this chain must be profiled and budgeted. A single synchronous database call that takes 50ms blows the budget.

### Model Serving Frameworks

| Framework | Language | Best For | Notes |
|---|---|---|---|
| FastAPI + MLflow | Python | Lightweight REST serving | Good for sklearn/XGBoost models |
| TorchServe | Python/Java | PyTorch model serving | Batching, versioning built-in |
| Triton Inference Server | C++/Python | GPU models, ONNX | NVIDIA; supports multiple backends |
| BentoML | Python | Multi-model serving | Strong packaging, good DX |
| Seldon Core | Kubernetes | MLOps at scale | A/B, canary, shadow built-in |
| Ray Serve | Python | Complex model graphs | Good for chained models |

For a data engineering team without a dedicated MLOps team, **FastAPI + MLflow** is the pragmatic choice: familiar Python, easy Docker deployment, and direct integration with the MLflow Model Registry.

---

## Feature Serving for Real-Time Inference

This is the hardest unsolved problem in real-time ML. Features that are trivial to compute in batch (rolling 6-month prepayment rate for a pool) require significant engineering to serve at sub-100ms latency.

### Online Feature Store Architecture

```
Training Pipeline                  Inference Pipeline
──────────────────                 ──────────────────
Historical batch data              Incoming loan event (Kafka)
  → dbt / Snowflake                       ↓
  → Feature computation            Real-time feature computation
  → Write to offline store         (point-in-time lookup)
    (Snowflake / Delta Lake)               ↓
                                   Online Feature Store
                                   (Redis / DynamoDB / Cassandra)
                                           ↓
                                   FastAPI model server
                                           ↓
                                   Prediction → response
```

### Redis as Online Feature Store

```python
import redis
import json
from typing import Optional

class LoanFeatureStore:
    """
    Serves pre-computed loan-level features from Redis.
    Features are written by a background job that syncs
    from Snowflake every 15 minutes.
    """

    def __init__(self, redis_host: str, redis_port: int = 6379,
                 ttl_seconds: int = 86400):
        self.client = redis.Redis(
            host=redis_host, port=redis_port,
            decode_responses=True, socket_timeout=0.05  # 50ms timeout
        )
        self.ttl = ttl_seconds

    def get_loan_features(self, loan_id: str) -> Optional[dict]:
        key = f"loan_features:{loan_id}"
        raw = self.client.get(key)
        if raw is None:
            return None
        return json.loads(raw)

    def set_loan_features(self, loan_id: str, features: dict) -> None:
        key = f"loan_features:{loan_id}"
        self.client.setex(key, self.ttl, json.dumps(features))

    def bulk_load_from_dataframe(self, df) -> int:
        """Batch load features into Redis from a pandas DataFrame."""
        pipe = self.client.pipeline(transaction=False)
        for _, row in df.iterrows():
            key = f"loan_features:{row['loan_id']}"
            features = row.drop("loan_id").to_dict()
            pipe.setex(key, self.ttl, json.dumps(features))
        pipe.execute()
        return len(df)
```

### Snowflake Background Sync to Redis

```python
# Airflow task: sync Snowflake features to Redis every 15 minutes
def sync_features_to_redis(**context):
    import snowflake.connector
    import pandas as pd
    from mortgage_ml.feature_store import LoanFeatureStore

    conn = snowflake.connector.connect(
        account="myorg-myaccount",
        user="{{ var.value.sf_user }}",
        password="{{ var.value.sf_password }}",
        warehouse="INFERENCE_WH",
        database="MORTGAGE_DB",
        schema="ML_FEATURES",
    )
    # Only sync loans active in the last 30 days to keep Redis lean
    df = pd.read_sql("""
        SELECT  loan_id,
                coupon_spread,
                current_ltv,
                fico_at_origination,
                seasoning_months,
                burnout_count
        FROM    ml_features.prepay_feature_matrix
        WHERE   report_month = DATE_TRUNC('month', CURRENT_DATE)
    """, conn)
    conn.close()

    store = LoanFeatureStore(redis_host="redis.internal", redis_port=6379)
    loaded = store.bulk_load_from_dataframe(df)
    print(f"Synced {loaded} loan features to Redis")
```

---

## Kafka-Based Streaming Inference

```python
# Faust stream processor for near-real-time inference
# Trigger: new loan application event lands in Kafka topic

import faust
import mlflow.pyfunc
import json

app = faust.App(
    "mortgage-inference",
    broker="kafka://kafka.internal:9092",
    value_serializer="json",
)

# Load model once at startup — not per message
mlflow.set_tracking_uri("http://mlflow.internal:5000")
MODEL = mlflow.pyfunc.load_model("models:/FraudDetectionModel/Production")

class LoanApplicationEvent(faust.Record):
    loan_id:          str
    applicant_ssn:    str
    requested_amount: float
    property_zip:     str
    application_ts:   str

applications_topic  = app.topic("loan-applications",  value_type=LoanApplicationEvent)
fraud_scores_topic  = app.topic("fraud-scores")

@app.agent(applications_topic)
async def score_application(applications):
    async for batch in applications.take(100, within=1.0):
        # Build feature matrix for the batch
        import pandas as pd
        records = []
        for app_event in batch:
            records.append({
                "loan_id":          app_event.loan_id,
                "requested_amount": app_event.requested_amount,
                "property_zip":     app_event.property_zip,
                # Additional features from online feature store
                # would be fetched here via Redis
            })
        df = pd.DataFrame(records)
        feature_df = df.drop(columns=["loan_id"])
        scores = MODEL.predict(feature_df)

        for loan_id, score in zip(df["loan_id"], scores):
            await fraud_scores_topic.send(
                value={"loan_id": loan_id, "fraud_score": float(score)}
            )
```

---

## FastAPI + MLflow Model Serving

```python
# mortgage_inference/main.py
from fastapi import FastAPI, HTTPException, BackgroundTasks
from pydantic import BaseModel, Field
from typing import List, Optional
import mlflow.pyfunc
import pandas as pd
import time
import logging
from prometheus_client import Counter, Histogram, generate_latest
from fastapi.responses import PlainTextResponse

logger = logging.getLogger(__name__)

# ── Prometheus metrics ──────────────────────────────────────────────────────
REQUEST_COUNT    = Counter("inference_requests_total",
                           "Total inference requests", ["model", "version"])
REQUEST_LATENCY  = Histogram("inference_latency_seconds",
                             "Inference latency", ["model"],
                             buckets=[.005, .01, .025, .05, .1, .25, .5])
PREDICTION_SCORE = Histogram("prediction_score_distribution",
                             "Distribution of prediction scores", ["model"],
                             buckets=[i/10 for i in range(11)])

# ── Model loading ────────────────────────────────────────────────────────────
mlflow.set_tracking_uri("http://mlflow.internal:5000")

MODELS = {
    "prepayment": mlflow.pyfunc.load_model(
        "models:/PrepaymentModel/Production"
    ),
    "fraud": mlflow.pyfunc.load_model(
        "models:/FraudDetectionModel/Production"
    ),
}

# ── Request / response schemas ────────────────────────────────────────────────
class LoanFeatures(BaseModel):
    loan_id:            str
    coupon_spread:      float    = Field(..., ge=-5.0, le=15.0)
    current_ltv:        float    = Field(..., ge=0.0, le=200.0)
    fico_at_origination: int     = Field(..., ge=300, le=850)
    seasoning_months:   int      = Field(..., ge=0)
    burnout_count:      int      = Field(0, ge=0)

class BatchScoreRequest(BaseModel):
    model_name: str
    loans: List[LoanFeatures]

class LoanPrediction(BaseModel):
    loan_id:    str
    score:      float
    label:      int
    latency_ms: float

class BatchScoreResponse(BaseModel):
    predictions: List[LoanPrediction]
    model_name:  str
    model_version: str
    total_latency_ms: float

# ── Application ───────────────────────────────────────────────────────────────
app = FastAPI(
    title="Mortgage ML Inference API",
    version="2.1.0",
    description="Real-time scoring for prepayment and fraud models",
)

THRESHOLD = {"prepayment": 0.15, "fraud": 0.70}

@app.post("/score/batch", response_model=BatchScoreResponse)
async def score_batch(request: BatchScoreRequest):
    if request.model_name not in MODELS:
        raise HTTPException(
            status_code=404,
            detail=f"Model '{request.model_name}' not found. "
                   f"Available: {list(MODELS.keys())}"
        )

    t0 = time.perf_counter()
    model = MODELS[request.model_name]

    feature_cols = [
        "coupon_spread", "current_ltv",
        "fico_at_origination", "seasoning_months", "burnout_count"
    ]
    records = [loan.dict() for loan in request.loans]
    df = pd.DataFrame(records)
    loan_ids = df["loan_id"].tolist()
    X = df[feature_cols]

    try:
        scores = model.predict(X)
    except Exception as exc:
        logger.error("Inference failed: %s", exc, exc_info=True)
        raise HTTPException(status_code=500, detail=f"Model error: {exc}")

    threshold = THRESHOLD.get(request.model_name, 0.5)
    total_latency_ms = (time.perf_counter() - t0) * 1000

    predictions = []
    for loan_id, score in zip(loan_ids, scores):
        PREDICTION_SCORE.labels(model=request.model_name).observe(float(score))
        predictions.append(LoanPrediction(
            loan_id=loan_id,
            score=float(score),
            label=int(float(score) >= threshold),
            latency_ms=round(total_latency_ms / len(loan_ids), 3),
        ))

    REQUEST_COUNT.labels(
        model=request.model_name, version="production"
    ).inc(len(request.loans))
    REQUEST_LATENCY.labels(model=request.model_name).observe(
        total_latency_ms / 1000
    )

    return BatchScoreResponse(
        predictions=predictions,
        model_name=request.model_name,
        model_version="production",
        total_latency_ms=round(total_latency_ms, 3),
    )

@app.get("/health")
def health():
    return {"status": "ok", "models_loaded": list(MODELS.keys())}

@app.get("/metrics", response_class=PlainTextResponse)
def metrics():
    return generate_latest()
```

---

## SQL Server PREDICT with ONNX

For organizations on SQL Server 2019+, ONNX models can be run directly inside the database engine — no Python runtime required at inference time.

```sql
-- Step 1: Register the ONNX model in SQL Server
EXEC sp_configure 'external scripts enabled', 1;
RECONFIGURE;

-- Insert the ONNX model binary
DECLARE @model VARBINARY(MAX);
SELECT @model = CAST(BulkColumn AS VARBINARY(MAX))
FROM   OPENROWSET(BULK N'C:\models\fraud_detection_v3.onnx', SINGLE_BLOB) AS f;

INSERT INTO dbo.ml_models (model_name, model_version, model_binary, created_at)
VALUES ('FraudDetection', 'v3', @model, GETUTCDATE());

-- Step 2: Run in-database inference using PREDICT
DECLARE @fraud_model VARBINARY(MAX);
SELECT @fraud_model = model_binary
FROM   dbo.ml_models
WHERE  model_name    = 'FraudDetection'
  AND  model_version = 'v3';

SELECT
    la.loan_id,
    la.application_ts,
    p.variable_0    AS fraud_probability,
    CASE WHEN p.variable_0 >= 0.70 THEN 'HIGH_RISK'
         WHEN p.variable_0 >= 0.35 THEN 'MEDIUM_RISK'
         ELSE 'LOW_RISK' END  AS risk_tier
FROM   dbo.loan_applications_staging la
CROSS APPLY PREDICT(
    MODEL = @fraud_model,
    DATA  = la,
    RUNTIME = ONNX
) WITH (variable_0 FLOAT) AS p
WHERE  la.application_date = CAST(GETDATE() AS DATE);
```

This approach eliminates the network hop to an external inference service and keeps data in SQL Server's security perimeter — valuable in environments with strict data governance requirements.

---

## Snowflake Snowpark for In-Database Scoring

```python
# Snowpark UDF for real-time scoring within Snowflake queries
from snowflake.snowpark.functions import udf, col
from snowflake.snowpark.types import FloatType, StringType
import mlflow.pyfunc

# Register the model as a vectorized UDF
# The model file is uploaded to a Snowflake stage
session.add_import("@ML_MODELS/prepayment_v3.pkl")

@udf(name="score_prepayment", is_permanent=True,
     stage_location="@ML_MODELS", replace=True,
     return_type=FloatType(),
     input_types=[FloatType(), FloatType(), FloatType(), FloatType()])
def score_prepayment(coupon_spread: float, current_ltv: float,
                     fico: float, seasoning: float) -> float:
    import sys
    import pickle
    import os

    # Model is loaded once per worker via import cache
    if not hasattr(score_prepayment, "_model"):
        with open(
            os.path.join(sys._xoptions.get("snowflake_import_directory"),
                         "prepayment_v3.pkl"), "rb"
        ) as f:
            score_prepayment._model = pickle.load(f)

    import pandas as pd
    features = pd.DataFrame(
        [[coupon_spread, current_ltv, fico, seasoning]],
        columns=["coupon_spread", "current_ltv",
                 "fico_at_origination", "seasoning_months"]
    )
    return float(score_prepayment._model.predict_proba(features)[0, 1])

# Use the UDF in a Snowflake query
scored_loans = session.table("ML_FEATURES.PREPAY_FEATURE_MATRIX").select(
    col("LOAN_ID"),
    col("COUPON_SPREAD"),
    col("CURRENT_LTV"),
    score_prepayment(
        col("COUPON_SPREAD"), col("CURRENT_LTV"),
        col("FICO_AT_ORIGINATION"), col("SEASONING_MONTHS")
    ).alias("PREPAY_SCORE")
)
```

---

## A/B Testing and Canary Deployments

### Traffic Splitting with FastAPI

```python
import random
from fastapi import Request

# Model registry: challenger vs champion
CHAMPION_MODEL   = mlflow.pyfunc.load_model("models:/PrepaymentModel/Production")
CHALLENGER_MODEL = mlflow.pyfunc.load_model("models:/PrepaymentModel/Staging")

CANARY_TRAFFIC_PCT = 10  # 10% of traffic goes to challenger

@app.post("/score/prepayment")
async def score_with_canary(request: BatchScoreRequest,
                             background_tasks: BackgroundTasks):
    use_challenger = random.randint(1, 100) <= CANARY_TRAFFIC_PCT
    model    = CHALLENGER_MODEL if use_challenger else CHAMPION_MODEL
    variant  = "challenger" if use_challenger else "champion"

    # Score using selected model
    # ... (scoring logic) ...

    # Log which variant was used for later analysis
    background_tasks.add_task(
        log_prediction_to_warehouse,
        loan_ids=loan_ids,
        scores=scores,
        model_variant=variant,
        request_ts=time.time(),
    )
    return response
```

### Shadow Mode Deployment

Shadow mode runs the challenger model on all production traffic but returns only the champion's predictions to the caller. The challenger's outputs are logged silently for offline comparison.

```python
@app.post("/score/prepayment")
async def score_with_shadow(request: BatchScoreRequest,
                             background_tasks: BackgroundTasks):
    # Always return champion predictions
    champion_scores = CHAMPION_MODEL.predict(X)

    # Asynchronously score with challenger — caller never sees this
    async def run_shadow():
        challenger_scores = CHALLENGER_MODEL.predict(X)
        log_shadow_comparison(loan_ids, champion_scores, challenger_scores)

    background_tasks.add_task(run_shadow)

    return build_response(loan_ids, champion_scores, variant="champion")
```

**Shadow mode is the safest canary strategy**: zero production risk, full traffic volume for challenger evaluation.

---

## ONNX Export and Model Optimization

```python
# Export sklearn model to ONNX for faster inference
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType
import onnxruntime as rt
import numpy as np

# Convert
initial_type = [("float_input", FloatTensorType([None, 5]))]
onnx_model = convert_sklearn(
    trained_sklearn_model,
    initial_types=initial_type,
    target_opset=17
)
with open("prepayment_v3.onnx", "wb") as f:
    f.write(onnx_model.SerializeToString())

# Benchmark ONNX vs sklearn inference speed
import time

sess = rt.InferenceSession("prepayment_v3.onnx",
                            providers=["CPUExecutionProvider"])
input_name = sess.get_inputs()[0].name
X_test_np = X_test.values.astype(np.float32)

# ONNX inference
t0 = time.perf_counter()
for _ in range(1000):
    onnx_pred = sess.run(None, {input_name: X_test_np})
onnx_ms = (time.perf_counter() - t0) / 1000 * 1000
print(f"ONNX avg latency:   {onnx_ms:.3f}ms per batch of {len(X_test)} rows")

# sklearn inference
t0 = time.perf_counter()
for _ in range(1000):
    sk_pred = trained_sklearn_model.predict_proba(X_test)
sk_ms = (time.perf_counter() - t0) / 1000 * 1000
print(f"sklearn avg latency: {sk_ms:.3f}ms per batch of {len(X_test)} rows")
# Typical result: ONNX is 3-10x faster than native sklearn
```

---

## Latency Optimization Techniques

| Technique | Typical Speedup | When to Apply |
|---|---|---|
| ONNX export (sklearn → ONNX) | 3–10x | Any sklearn/XGBoost model |
| Model quantization (FP32 → INT8) | 2–4x | Deep learning models |
| Feature pre-computation (offline) | 10–50x | Features that don't require request-time data |
| Redis caching for feature lookups | 10–100x vs DB | Features keyed by entity ID |
| Connection pooling for DB lookups | 2–5x | When DB lookups are unavoidable |
| Async I/O (asyncio / aiohttp) | 2–10x | Multiple I/O-bound feature fetches |
| Batch inference (group requests) | 2–5x per item | High-throughput scenarios |
| Model warm-up (pre-load at startup) | Eliminates cold start | Always |

---

## Horizontal Scaling and Auto-Scaling

```yaml
# Kubernetes HPA for inference service
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: mortgage-inference-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: mortgage-inference
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
    - type: Pods
      pods:
        metric:
          name: inference_latency_p99_ms
        target:
          type: AverageValue
          averageValue: "80"   # Scale up if P99 latency > 80ms
```

---

## Interview Q&A

**Q1: What is training-serving skew, and how do you prevent it in a real-time inference system?**

Training-serving skew occurs when the feature values seen during model training differ from the feature values computed at inference time for the same logical input. This can cause a well-trained model to underperform in production without any obvious errors.

Common causes:
- Different code paths for training vs. inference feature computation (e.g., different null handling, different bucketing logic).
- Time-based features computed relative to `now` vs. a fixed training date.
- Missing features at inference time that were always present in training data.
- Data type differences (int vs. float, different string encodings).

Prevention:
1. Single feature computation codebase — share the same Python functions or dbt SQL between training and inference. Never copy-paste feature logic.
2. Feature store — centralize feature computation. Training reads historical snapshots; inference reads the live version. Both use the same computation engine.
3. Log and compare — at inference time, log feature distributions daily and compare against the training distribution using PSI. Alert on any PSI > 0.1.
4. Integration tests — include a test that runs both the training feature computation and the inference feature computation on the same 100 sample loans and asserts the outputs are identical.

---

**Q2: Walk me through the infrastructure you would build for real-time fraud detection on new mortgage loan applications at a servicer processing 5,000 applications per day.**

5,000 applications per day is roughly 0.06 requests per second average, but with business-hours clustering, peak might be 1–2 RPS. This is modest scale — the architecture does not need to be complex.

Infrastructure:
1. **Model serving**: Single FastAPI application with the ONNX-exported fraud model loaded in memory. 2–3 instances behind a load balancer for availability. No Kubernetes required at this scale; ECS or a pair of EC2 instances is sufficient.
2. **Feature serving**: Most fraud features (application data) arrive with the request itself. Background features (e.g., applicant's historical application count, prior fraud flags) are pre-computed and stored in Redis, keyed by applicant SSN hash.
3. **Kafka integration**: Loan origination system publishes a `loan-application-received` event to Kafka. The inference service consumes this event, computes features, scores the application, and publishes a `fraud-score-computed` event back. The underwriting system consumes the fraud score before rendering a decision.
4. **Monitoring**: Prometheus + Grafana for latency and throughput. MLflow for model version tracking. A daily batch job in Snowflake computes actual fraud rates for applications scored last quarter (ground truth latency ~90 days) and compares against predicted scores to detect model drift.
5. **Fallback**: If the inference service is unavailable, the system defaults to a rules-based scorecard implemented in SQL Server stored procedures. This ensures fraud checks never block the application pipeline.

---

**Q3: What is shadow mode deployment, and when would you use it versus a standard canary deployment?**

Shadow mode: the new (challenger) model receives all production traffic and generates predictions, but those predictions are never returned to the caller. Only the current (champion) model's predictions are used. The challenger's outputs are logged asynchronously and analyzed offline.

Canary mode: a small percentage of live traffic (5–10%) receives the challenger's predictions. Those callers act on the challenger's output.

Use shadow mode when:
- The model is making decisions with real business consequences (approve/deny a loan application, flag fraud). You cannot risk exposing a bad challenger model to even 5% of applicants.
- You need high statistical power to evaluate the challenger before any production exposure. Shadow mode gives you 100% of traffic volume for evaluation.
- The challenger model has not been tested in production conditions at all.

Use canary mode when:
- You have reasonable confidence the challenger is better based on offline evaluation and shadow mode data.
- The decision is reversible or low-stakes (a recommendation, a sort order, a risk score that informs but does not determine an outcome).
- You want to measure real-world business metrics (click-through rate, conversion) that cannot be assessed in shadow mode.

In mortgage, the regulatory and fair lending implications of live A/B testing on credit decisions are significant. Shadow mode is almost always the right choice for models that influence underwriting or pricing.

---

**Q4: How would you handle a model that is taking 250ms to score a single loan application against a 100ms SLA?**

Profile first. Measure where the 250ms is being spent before optimizing anything. Add timing around each stage: feature retrieval, preprocessing, inference, post-processing.

Common findings and fixes:

- **Feature retrieval is the bottleneck** (most common): A synchronous SQL query to Snowflake or SQL Server adds 100–200ms. Fix: pre-compute features to Redis with a background sync job. Redis GET is <1ms.
- **Model inference is slow**: The sklearn predict_proba call is taking 50–100ms. Fix: export to ONNX and serve via ONNX Runtime. Typically 3–10x faster. For GBMs, also consider XGBoost's native predictor.
- **JSON serialization overhead**: For large batch requests, Python's json module is slow. Fix: use orjson (3–10x faster than standard json).
- **Python startup / import overhead**: Model is being loaded per request. Fix: load model at application startup, store in module-level variable, reuse across requests.
- **Threading limitations**: Single-threaded FastAPI is maxing out. Fix: run with multiple uvicorn workers (`--workers 4`) or use async endpoints with proper async I/O.

After profiling and fixing the top bottleneck, re-measure. Repeat. Set up load testing (locust or k6) to simulate 50 RPS and watch P99 latency in Grafana before declaring the problem solved.

---

**Q5: Explain the difference between a feature store's offline store and online store. When does data flow from one to the other?**

The offline store is a historical database of feature values — typically Snowflake, Delta Lake, or Parquet on S3. It stores point-in-time accurate feature snapshots for every entity (loan, borrower, property) going back years. It is used for training data construction: "give me the features for loan X as they existed on 2024-06-15."

The online store is a low-latency key-value store — typically Redis, DynamoDB, or Cassandra. It stores only the latest feature value per entity. It is used for inference: "give me the current features for loan X right now."

Data flows from offline to online via a **materialization job** that runs on a schedule (every 15 minutes, hourly, or triggered by new data):

```
Snowflake feature table (offline)
  → Materialization job (Python / Spark / Snowflake Task)
  → Redis / DynamoDB (online)
  → FastAPI inference service reads from Redis
```

The latency of the online store's data is bounded by the materialization frequency. If features are materialized every 15 minutes, the inference service is working with features that are at most 15 minutes stale. For mortgage scoring (not high-frequency trading), this is typically acceptable. For fraud detection on applications, you may need to materialize more frequently or compute some features in real-time from the request payload.

---

**Q6: How do you ensure model inference results are auditable and reproducible in a regulated industry like mortgage?**

Regulatory requirements (ECOA, Fair Lending, model risk management guidelines like SR 11-7) require that you be able to explain any credit decision and reproduce it years later.

Infrastructure requirements:

1. **Log every prediction**: For every inference call, log: loan_id, model name + version, all input feature values, raw prediction score, threshold used, resulting label, timestamp, requesting system. Write this to an immutable append-only store (S3 + Athena, Snowflake append-only table).

2. **Model versioning**: Every deployed model has a unique version identifier. The version is logged with every prediction. The model artifact (ONNX file, pickle) is stored permanently in S3 and MLflow.

3. **Feature versioning**: Log which version of the feature computation code was used (git commit hash, dbt version, dbt model hash). If the feature SQL changed, you must be able to reproduce the exact features that were used at prediction time.

4. **Reproducibility test**: Maintain a regression test that loads a past model version, recreates the exact feature vector from logged inputs, re-scores, and verifies the score matches the original logged prediction.

5. **Explainability logging**: For models subject to adverse action notice requirements, log SHAP values alongside the prediction score. This enables generating compliant adverse action notices ("The primary reasons for this decision were: low FICO score, high LTV ratio").

---

**Q7: What happens to your real-time inference service when Snowflake is unavailable for an hour during a maintenance window?**

This is a resilience design question. The answer depends on what the inference service depends on Snowflake for.

If Snowflake is used only for model training and offline feature materialization: the Redis online store is pre-loaded. The inference service continues operating normally. Snowflake unavailability has no real-time impact. This is the correct architecture.

If Snowflake is used as the online feature store (queried at inference time): the inference service fails every request. This is the wrong architecture for real-time use cases.

Mitigations if Snowflake is the feature source:

1. **Circuit breaker + stale cache**: Maintain a local in-process LRU cache of recently accessed loan features. On Snowflake timeout, serve from cache with a staleness warning flag in the response.
2. **Degraded mode scoring**: Fall back to a simpler model that uses only request-payload features (no pre-computed features). A logistic regression on application data alone is better than no score.
3. **Feature replication**: Maintain a Redis replica that is refreshed from Snowflake but persists independently. Redis is highly available and does not depend on Snowflake.
4. **Queue and retry**: If the decision is not time-critical (batch decision), queue the scoring request and process it when Snowflake recovers.

---

**Q8: How would you implement model versioning for a production inference service so that you can roll back in under 5 minutes if the new model causes issues?**

Deployment design:

1. **Blue-green model loading**: The inference service loads two model versions simultaneously at startup: the current production version ("blue") and the pending version ("green"). Traffic routing is controlled by a feature flag or config value, not a code deployment.

2. **Feature flag / config-driven routing**: Store the active model version in a Redis key or AWS Parameter Store value. The inference service checks this on each request (cached for 30 seconds). To roll back, update the config value — no service restart required.

```python
import boto3

def get_active_model_version(model_name: str) -> str:
    ssm = boto3.client("ssm")
    param = ssm.get_parameter(
        Name=f"/mortgage-ml/{model_name}/active-version"
    )
    return param["Parameter"]["Value"]  # e.g., "v3" or "v4"
```

3. **Health check with model validation**: The `/health` endpoint runs a quick sanity check — score 5 hard-coded sample loans and assert the outputs are within expected ranges. If the new model fails this check, the deployment pipeline aborts before the config switch.

4. **Automated rollback trigger**: Prometheus alert fires if P99 latency > 150ms or if the prediction score distribution shifts by more than 2 standard deviations from the baseline within 15 minutes of a version switch. The alert triggers an automated rollback by updating the config value.

5. **Model artifact pre-loading**: The new model version is loaded into memory before the traffic switch. Switching from v3 to v4 is a pointer reassignment, not a model file load. This eliminates cold-start latency during rollout.

---

**Q9: What metrics would you monitor for a production real-time inference service, and what thresholds would trigger an alert?**

**Infrastructure metrics** (Prometheus/Grafana):

| Metric | Alert Threshold | Severity |
|---|---|---|
| P99 request latency | > 150ms | Warning; > 300ms Critical |
| Request error rate | > 0.1% | Warning; > 1% Critical |
| Model load success | < 1 | Critical (immediate) |
| Redis cache hit rate | < 90% | Warning |
| CPU utilization | > 80% | Warning (triggers HPA) |

**Model quality metrics** (computed by a daily batch job comparing predictions to outcomes):

| Metric | Alert Threshold |
|---|---|
| PSI for any feature | > 0.25 (severe drift) |
| Prediction score mean shift | > 2 stddev from 30-day baseline |
| AUC on last quarter's labeled loans | > 3% drop vs. previous quarter |
| Calibration error (Brier score) | > 15% degradation |

**Business metrics** (Snowflake query, weekly):

| Metric | Alert Threshold |
|---|---|
| Predicted prepayment rate vs. actual | > 20% relative error |
| Fraud model precision (confirmed frauds / flagged) | < 60% (too many false positives) |
| Fraud model recall (confirmed frauds caught) | < 70% (too many false negatives) |

---

## Pro Tips

1. **Pre-load, never lazy-load.** Models should be loaded into memory at application startup, not on the first request. A cold-start load of a GBM with 500 trees can take 2–5 seconds and will cause the first request after a deployment to timeout. Add a `/warmup` endpoint that scores dummy data, and call it from the deployment pipeline before switching traffic.

2. **The online feature store is an infrastructure dependency — treat it as one.** Redis going down is as bad as the inference service going down. Use Redis Sentinel or Redis Cluster for HA. Set appropriate `socket_timeout` values (50ms) so a slow Redis doesn't cascade into inference service failures.

3. **Batch inference endpoints outperform single-record endpoints.** Even in "real-time" scenarios, batching 10–100 records per API call reduces per-record latency by 5–10x due to amortized overhead. If the caller controls request patterns, push for batching.

4. **ONNX is the lingua franca of model portability.** A model trained in Python with sklearn can be exported to ONNX and run in SQL Server, Java, C++, or any browser — without a Python runtime. In SQL Server environments, this means you can run inference inside the database with PREDICT(), eliminating the network hop entirely.

5. **Shadow mode before any canary in credit decisions.** In mortgage, running a true A/B test (different applicants get different model decisions) raises fair lending compliance questions. Shadow mode collects all the performance data you need with zero regulatory exposure.

6. **Design for the retry.** Real-time inference services get retried by callers. Make your endpoint idempotent: scoring the same loan twice with the same model should produce the same result and should not write duplicate records to the predictions table. Use the loan_id + model_version as a deduplication key.
