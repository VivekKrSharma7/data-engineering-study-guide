# AWS SageMaker for Data Engineers

[Back to Index](README.md)

---

## Overview

Amazon SageMaker is AWS's fully managed ML platform. It covers the complete ML lifecycle: data preparation, feature engineering, model training, evaluation, deployment, and monitoring. For senior data engineers in the US secondary mortgage market who already operate Snowflake on AWS, SageMaker integrates natively with S3, Glue, and the broader AWS ecosystem. This module covers SageMaker's architecture, its integration with Snowflake, Amazon Bedrock for LLMs, and cost optimization strategies relevant to production mortgage ML workloads.

---

## Key Concepts at a Glance

| Component | What It Does | Mortgage Use Case |
|---|---|---|
| SageMaker Studio | Unified ML IDE | Develop prepayment models interactively |
| Training Jobs | Managed training on EC2 | Train XGBoost on 10 years of loan history |
| Feature Store | Online + offline feature registry | Serve FICO, DTI, LTV features at scoring time |
| Pipelines | CI/CD for ML (MLOps) | Automate monthly model retraining |
| Batch Transform | Large-scale batch inference | Score full agency MBS pool monthly |
| Model Monitor | Drift + quality detection | Alert when score distribution shifts post-FOMC |
| SageMaker Clarify | Bias + explainability | Fair lending analysis per ECOA |
| Amazon Bedrock | Managed LLMs (Claude, Titan) | Summarize appraisal reports |
| AWS Glue ML | ETL with ML transforms | Deduplicate servicer loan data across feeds |

---

## 1. SageMaker Studio

SageMaker Studio is a browser-based IDE that unifies all SageMaker capabilities. It replaced the older SageMaker Notebooks experience and provides:
- **JupyterLab** environment with SageMaker-specific extensions
- **Experiments** tracking panel (native MLflow-compatible)
- **Pipelines** visual DAG editor
- **Feature Store** browser
- **Model Registry** management
- **Canvas** (no-code AutoML for business analysts)
- **JumpStart** (curated model hub — pre-trained foundation models, Hugging Face, etc.)

### Studio Domain Setup Pattern

```
Studio Domain
  └── User Profiles (per data scientist / engineer)
        └── App (JupyterServer or KernelGateway)
              └── Execution Role (IAM — grants S3, Feature Store, ECR access)
```

Data engineers typically need the `AmazonSageMakerFullAccess` policy plus custom S3 bucket policies for loan tape storage.

---

## 2. SageMaker Training Jobs

### Training Job Architecture

SageMaker provisions EC2 instances, copies training code + data from S3, runs training, saves model artifacts back to S3, then terminates the instances. Billing is per-second, from job start to instance termination.

### Built-in Algorithm: XGBoost for Mortgage Credit Scoring

```python
import boto3
import sagemaker
from sagemaker.inputs import TrainingInput
from sagemaker.estimator import Estimator

session = sagemaker.Session()
role = "arn:aws:iam::<account-id>:role/SageMakerExecutionRole"
bucket = "s3://mortgage-ml-data"

# Use SageMaker's managed XGBoost container
xgb_image_uri = sagemaker.image_uris.retrieve(
    framework="xgboost",
    region="us-east-1",
    version="1.7-1"
)

xgb_estimator = Estimator(
    image_uri=xgb_image_uri,
    role=role,
    instance_count=1,
    instance_type="ml.m5.4xlarge",
    use_spot_instances=True,          # Managed spot training
    max_run=7200,                     # 2 hours max
    max_wait=10800,                   # 3 hours including spot wait time
    output_path=f"{bucket}/models/credit-score/",
    sagemaker_session=session,
    base_job_name="mortgage-credit-xgb",
)

# Set XGBoost hyperparameters
xgb_estimator.set_hyperparameters(
    objective="binary:logistic",
    num_round=500,
    max_depth=6,
    eta=0.05,
    subsample=0.8,
    colsample_bytree=0.8,
    eval_metric="auc",
    early_stopping_rounds=20,
)

# Point to S3 training data (CSV or libsvm format)
train_data = TrainingInput(
    s3_data=f"{bucket}/features/train/",
    content_type="text/csv"
)
val_data = TrainingInput(
    s3_data=f"{bucket}/features/validation/",
    content_type="text/csv"
)

xgb_estimator.fit({"train": train_data, "validation": val_data})
print(f"Training job: {xgb_estimator.latest_training_job.name}")
```

### Built-in Algorithms Relevant to Mortgage

| Algorithm | Use Case | Notes |
|---|---|---|
| XGBoost | Credit scoring, default prediction | Most widely used; supports custom objective |
| Linear Learner | Fast baseline logistic/linear regression | Good for HMDA analysis |
| Random Cut Forest | Anomaly detection in loan data | Catches data quality issues, fraud signals |
| DeepAR | Time-series forecasting | CPR/CDR rate forecasting |
| BlazingText | Text classification | Loan condition categorization |
| Object2Vec | Entity embeddings | Servicer / investor relationship embeddings |

---

## 3. SageMaker Processing Jobs

Processing Jobs run data transformation code on managed containers without a training job — used for preprocessing, postprocessing, and model evaluation.

```python
from sagemaker.processing import ScriptProcessor, ProcessingInput, ProcessingOutput
from sagemaker import get_execution_role

processor = ScriptProcessor(
    image_uri=xgb_image_uri,
    command=["python3"],
    instance_type="ml.m5.xlarge",
    instance_count=1,
    role=role,
    base_job_name="loan-feature-preprocessing",
)

processor.run(
    code="src/preprocess.py",
    inputs=[
        ProcessingInput(
            source=f"{bucket}/raw/loan_tape/2026/Q1/",
            destination="/opt/ml/processing/input"
        )
    ],
    outputs=[
        ProcessingOutput(
            source="/opt/ml/processing/output/train",
            destination=f"{bucket}/features/train/"
        ),
        ProcessingOutput(
            source="/opt/ml/processing/output/validation",
            destination=f"{bucket}/features/validation/"
        ),
    ],
    arguments=["--target-col", "default_flag", "--test-split", "0.2"],
)
```

---

## 4. SageMaker Feature Store

Feature Store provides a centralized repository with two serving modes:

| Mode | Backend | Latency | Use Case |
|---|---|---|---|
| **Online Store** | In-memory (Redis-compatible) | < 10ms | Real-time scoring at lock desk |
| **Offline Store** | S3 Parquet (Glue catalog) | Minutes | Training data retrieval |

### Creating and Populating a Feature Group

```python
import pandas as pd
import boto3
from sagemaker.feature_store.feature_group import FeatureGroup
from sagemaker.feature_store.feature_definition import (
    FeatureDefinition, FeatureTypeEnum
)

feature_group = FeatureGroup(
    name="mortgage-loan-features",
    sagemaker_session=session
)

feature_group.load_feature_definitions(data_frame=features_df)

feature_group.create(
    s3_uri=f"{bucket}/feature-store/",
    record_identifier_name="loan_id",
    event_time_feature_name="as_of_date",
    role_arn=role,
    enable_online_store=True,
    online_store_config={
        "EnableOnlineStore": True,
        "TtlDuration": {"Unit": "Days", "Value": 90}
    }
)

# Ingest features
feature_group.ingest(
    data_frame=features_df,
    max_workers=4,
    wait=True
)

# Real-time lookup at scoring time
response = feature_group.get_record(
    record_identifier_value_as_string="LOAN-2026-000123"
)
features = {r["FeatureName"]: r["ValueAsString"] for r in response["Record"]}
```

---

## 5. SageMaker Pipelines (MLOps)

SageMaker Pipelines is a CI/CD system for ML workflows, integrated with the Model Registry for approval-gated deployments.

```python
from sagemaker.workflow.pipeline import Pipeline
from sagemaker.workflow.steps import ProcessingStep, TrainingStep, TransformStep
from sagemaker.workflow.model_step import ModelStep
from sagemaker.workflow.parameters import ParameterString, ParameterFloat
from sagemaker.workflow.conditions import ConditionGreaterThanOrEqualTo
from sagemaker.workflow.condition_step import ConditionStep
from sagemaker.workflow.functions import JsonGet

as_of_date = ParameterString(name="AsOfDate", default_value="2026-03-01")
min_auc     = ParameterFloat(name="MinAcceptableAUC", default_value=0.78)

# Step 1: Preprocessing
step_process = ProcessingStep(name="LoanFeatureEngineering", processor=processor,
    inputs=[...], outputs=[...], code="src/preprocess.py")

# Step 2: Training
step_train = TrainingStep(name="TrainCreditModel", estimator=xgb_estimator,
    inputs={"train": TrainingInput(step_process.properties.ProcessingOutputConfig
                                   .Outputs["train"].S3Output.S3Uri,
                                   content_type="text/csv")})

# Step 3: Evaluate model
step_eval = ProcessingStep(name="EvaluateModel", processor=processor,
    inputs=[ProcessingInput(source=step_train.properties.ModelArtifacts.S3ModelArtifacts,
                            destination="/opt/ml/processing/model")],
    outputs=[ProcessingOutput(source="/opt/ml/processing/eval",
                              destination=f"{bucket}/eval/")],
    code="src/evaluate.py")

# Step 4: Conditional registration
cond_auc = ConditionGreaterThanOrEqualTo(
    left=JsonGet(step_eval, f"{bucket}/eval/metrics.json", "auc"),
    right=min_auc
)
step_register = ModelStep(name="RegisterCreditModel", ...)
step_fail     = ...

step_cond = ConditionStep(
    name="CheckModelQuality",
    conditions=[cond_auc],
    if_steps=[step_register],
    else_steps=[step_fail]
)

pipeline = Pipeline(
    name="mortgage-credit-retrain",
    parameters=[as_of_date, min_auc],
    steps=[step_process, step_train, step_eval, step_cond],
    sagemaker_session=session
)
pipeline.upsert(role_arn=role)
pipeline.start(parameters={"AsOfDate": "2026-03-01"})
```

---

## 6. SageMaker Endpoints: Real-Time and Async Inference

### Real-Time Endpoint

```python
from sagemaker.model import Model
from sagemaker.predictor import Predictor

model = xgb_estimator.create_model(role=role)
predictor = model.deploy(
    initial_instance_count=2,
    instance_type="ml.c5.xlarge",
    endpoint_name="credit-score-realtime",
)

# Invoke endpoint
import numpy as np
payload = "720,0.75,0.38,36,1"   # fico,ltv,dti,loan_age,product_type_enc
result = predictor.predict(payload)
print(f"Default probability: {result}")
```

### Async Endpoint (for larger payloads)

Async endpoints accept requests, store output to S3, and send SNS notification on completion. Suitable for scoring batches of 10-1000 loans with complex feature computation.

---

## 7. SageMaker Batch Transform

For full-portfolio monthly scoring without maintaining a persistent endpoint:

```python
from sagemaker.transformer import Transformer

transformer = Transformer(
    model_name=xgb_estimator.latest_training_job.name,
    instance_count=4,                    # Parallel scoring nodes
    instance_type="ml.m5.2xlarge",
    output_path=f"{bucket}/scores/2026/03/",
    strategy="MultiRecord",              # Pack multiple rows per request
    assemble_with="Line",
    accept="text/csv",
)

transformer.transform(
    data=f"{bucket}/features/scoring/2026/03/",
    content_type="text/csv",
    split_type="Line",
    join_source="Input",                 # Append input columns to output
    wait=True
)
```

---

## 8. SageMaker Model Monitor

Model Monitor compares production traffic to a training baseline, detecting:
- **Data quality drift:** Feature distributions shift (e.g., average FICO drops 30 points)
- **Model quality:** Prediction accuracy vs ground truth labels
- **Bias drift:** Fairness metrics shift across demographic groups
- **Feature attribution drift:** SHAP values change

```python
from sagemaker.model_monitor import DefaultModelMonitor, DataCaptureConfig
from sagemaker.model_monitor.dataset_format import DatasetFormat

# Enable data capture on endpoint
data_capture = DataCaptureConfig(
    enable_capture=True,
    sampling_percentage=100,
    destination_s3_uri=f"{bucket}/capture/credit-score/",
    capture_options=["REQUEST", "RESPONSE"]
)

# Create baseline from training data
monitor = DefaultModelMonitor(role=role, instance_type="ml.m5.xlarge")
monitor.suggest_baseline(
    baseline_dataset=f"{bucket}/features/baseline/",
    dataset_format=DatasetFormat.csv(header=True),
    output_s3_uri=f"{bucket}/monitor/baseline/",
    wait=True
)

# Schedule monitoring job (runs hourly)
monitor.create_monitoring_schedule(
    monitor_schedule_name="credit-score-drift-monitor",
    endpoint_input="credit-score-realtime",
    statistics=monitor.baseline_statistics(),
    constraints=monitor.suggested_constraints(),
    schedule_cron_expression="cron(0 * ? * * *)",
    output_s3_uri=f"{bucket}/monitor/reports/",
)
```

---

## 9. SageMaker Clarify: Bias and Explainability

Required for ECOA/Fair Lending compliance:

```python
from sagemaker import clarify

clarify_processor = clarify.SageMakerClarifyProcessor(
    role=role, instance_count=1, instance_type="ml.c5.xlarge",
    sagemaker_session=session
)

bias_config = clarify.BiasConfig(
    label_values_or_threshold=[1],         # Default = 1
    facet_name="race_ethnicity",           # Protected class
    facet_values_or_threshold=["Hispanic or Latino", "Black or African American"],
    group_name="census_tract_group"
)

explainability_config = clarify.SHAPConfig(
    baseline=[["720", "0.70", "0.35", "24", "1"]],  # Reference point
    num_samples=100,
    agg_method="mean_abs",
    save_local_shap_values=True
)

clarify_processor.run_bias(
    data_config=clarify.DataConfig(
        s3_data_input_path=f"{bucket}/features/scoring/2026/03/",
        s3_output_path=f"{bucket}/clarify/bias/",
        label="default_flag",
        headers=["fico","ltv","dti","loan_age","product_type_enc","race_ethnicity","default_flag"],
    ),
    bias_config=bias_config,
    model_config=clarify.ModelConfig(model_name="credit-score-model", instance_type="ml.c5.xlarge"),
    model_predicted_label_config=clarify.ModelPredictedLabelConfig(probability_threshold=0.5)
)
```

---

## 10. SageMaker + Snowflake Integration

SageMaker can pull training data directly from Snowflake using the Snowflake Connector for Python inside a Training or Processing Job container:

```python
# Inside a SageMaker Training Job (src/train.py)
import snowflake.connector
import pandas as pd
import os

conn = snowflake.connector.connect(
    account=os.environ["SF_ACCOUNT"],        # Passed as container env var
    user=os.environ["SF_USER"],
    password=os.environ["SF_PASSWORD"],       # Retrieved from AWS Secrets Manager
    warehouse="COMPUTE_WH",
    database="MORTGAGE_DW",
    schema="FEATURES",
    role="SAGEMAKER_READ_ROLE"
)

query = """
    SELECT loan_id, fico, ltv, dti, loan_age, product_type_enc, default_flag
    FROM   V_CREDIT_FEATURES
    WHERE  as_of_date = %(as_of_date)s
    AND    data_split = 'TRAIN'
"""
df = pd.read_sql(query, conn, params={"as_of_date": os.environ["AS_OF_DATE"]})
conn.close()
```

For large datasets (>10M rows), use Snowflake's S3 unload to stage data before training rather than querying row by row:

```sql
COPY INTO @mortgage_stage/sagemaker/features/train/
FROM (
    SELECT loan_id, fico, ltv, dti, loan_age, product_type_enc, default_flag
    FROM   V_CREDIT_FEATURES
    WHERE  as_of_date = '2026-03-01'
    AND    data_split = 'TRAIN'
)
FILE_FORMAT = (TYPE = CSV COMPRESSION = NONE FIELD_OPTIONALLY_ENCLOSED_BY = '"')
OVERWRITE = TRUE;
```

---

## 11. Amazon Bedrock

Bedrock is AWS's managed LLM API service, providing access to Claude (Anthropic), Titan (Amazon), Llama (Meta), Mistral, and others — without managing infrastructure.

```python
import boto3, json

bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")

def analyze_appraisal_report(report_text: str) -> dict:
    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 500,
        "messages": [
            {
                "role": "user",
                "content": (
                    "You are a mortgage underwriting assistant. From this appraisal report, "
                    "extract: (1) appraised value, (2) condition rating, "
                    "(3) comparable sales range, (4) any flags or concerns.\n\n"
                    f"Report:\n{report_text}"
                )
            }
        ]
    })

    response = bedrock.invoke_model(
        modelId="anthropic.claude-3-5-sonnet-20241022-v2:0",
        contentType="application/json",
        accept="application/json",
        body=body
    )
    return json.loads(response["body"].read())

# Titan embeddings for semantic search over loan conditions
def embed_text(text: str) -> list[float]:
    body = json.dumps({"inputText": text})
    response = bedrock.invoke_model(
        modelId="amazon.titan-embed-text-v2:0",
        body=body, contentType="application/json", accept="application/json"
    )
    return json.loads(response["body"].read())["embedding"]
```

---

## 12. AWS Glue ML Transforms

Glue's `FindMatches` transform uses ML to deduplicate records without writing matching rules manually. Useful for reconciling loan data across multiple servicer feeds:

```python
import boto3

glue = boto3.client("glue", region_name="us-east-1")

# Create ML transform for loan deduplication
response = glue.create_ml_transform(
    Name="loan-servicer-dedup",
    InputRecordTables=[{
        "DatabaseName": "mortgage_raw",
        "TableName": "servicer_loan_feeds_combined"
    }],
    Parameters={
        "TransformType": "FIND_MATCHES",
        "FindMatchesParameters": {
            "PrimaryKeyColumnName": "loan_id",
            "PrecisionRecallTradeoff": 0.9,    # Favor precision for regulatory data
            "AccuracyCostTradeoff": 0.9,
            "EnforceProvidedLabels": True
        }
    },
    Role="arn:aws:iam::<account>:role/GlueMLRole",
    GlueVersion="3.0",
    MaxCapacity=10.0
)
```

---

## 13. Cost Optimization

| Strategy | Estimated Savings | Implementation |
|---|---|---|
| Managed Spot Training | 60-90% on training | `use_spot_instances=True` + checkpoint to S3 |
| Serverless Inference | 70%+ vs always-on endpoint | Use for low-traffic scoring APIs |
| Batch Transform vs Endpoint | Eliminate idle endpoint cost | Nightly batch scoring → Batch Transform |
| Right-size instance type | 20-40% | Profile job memory/CPU; downsize from ml.m5.4xlarge to ml.m5.xlarge if underutilized |
| S3 Intelligent-Tiering for Feature Store | 30-50% storage | Tag offline store buckets with lifecycle policy |
| Multi-model endpoints | Share instance across models | Host prepayment + credit models on same ml.c5.2xlarge |

**Spot Instance Checkpointing Pattern (critical for long training jobs):**

```python
xgb_estimator = Estimator(
    ...
    use_spot_instances=True,
    max_run=7200,
    max_wait=10800,
    checkpoint_s3_uri=f"{bucket}/checkpoints/credit-xgb/",
    checkpoint_local_path="/opt/ml/checkpoints/",
)
# In training script: save model checkpoint every 50 rounds
# XGBoost supports xgb.train(..., callbacks=[xgb.callback.TrainingCheckPoint(...)])
```

---

## Interview Q&A

**Q1: Explain the SageMaker Feature Store online vs. offline store architecture and how you would design it for a real-time mortgage scoring system.**

The online store uses a low-latency in-memory store (backed by DynamoDB) that returns individual records in < 10ms — suitable for synchronous scoring at the point of lock request. The offline store writes features to S3 in Parquet format (queryable via Athena or AWS Glue), making training dataset assembly straightforward. For a mortgage scoring system: at lock time, the application calls the Feature Store online API with `loan_id` to retrieve current FICO, LTV, DTI, and other features, then invokes the SageMaker endpoint. Monthly, training jobs pull from the offline store via Athena to assemble point-in-time correct feature snapshots, avoiding feature leakage. Key design consideration: record the `event_time` accurately (the date as-of which the feature was valid) so training dataset assembly uses only features that were available at the time of the historical decision being modeled.

**Q2: What is managed spot training in SageMaker and what failure modes must a data engineer handle?**

Managed spot training uses EC2 Spot instances, which AWS can interrupt with 2 minutes notice when capacity is reclaimed. SageMaker handles interruptions by checkpointing model state to S3 and restarting the job automatically. The training script must implement checkpointing — for XGBoost, this means saving the booster object every N rounds. `max_wait` must be set greater than `max_run` to allow for interruption wait time. The main risk for data engineers: if the training script does not implement checkpointing, an interruption causes the full job to restart from epoch 0, wasting the spot savings. Always test checkpoint/resume behavior before using spot for production training. For jobs under 30 minutes, spot may not be worth the complexity.

**Q3: How does SageMaker Pipelines support a model governance process for a regulated mortgage lender?**

SageMaker Pipelines integrates with the Model Registry, which supports approval states: `PendingManualApproval`, `Approved`, `Rejected`. A pipeline can be configured to register a new model version with `PendingManualApproval` status, which blocks automatic deployment. A model risk officer reviews the evaluation metrics (AUC, Gini, KS statistic, fairness metrics from Clarify) attached to the model version, then approves or rejects via the Studio UI or API. An EventBridge rule fires on approval and triggers a deployment pipeline. This creates a complete audit trail: who approved which model version, on what date, with what supporting metrics. For FHFA/FFIEC model risk examinations, this trail is essential.

**Q4: How would you integrate Snowflake as a data source for SageMaker training jobs at scale?**

For small datasets (< 1M rows), use the Snowflake Python connector directly inside the Training Job container, passing credentials via AWS Secrets Manager. For large datasets, the pattern is: (1) Run a SageMaker Processing Job that executes a Snowflake COPY INTO S3 command to unload the training data to a staging bucket. (2) The subsequent Training Job reads from S3. This decouples data extraction from training, avoids Snowflake warehouse contention during training, and leverages S3's high-throughput data loading. Set the Snowflake warehouse to X-Small for the unload job since unload operations are IO-bound, not compute-bound.

**Q5: How does Amazon Bedrock differ from deploying open-source LLMs on SageMaker JumpStart?**

Bedrock is a serverless API — no instance management, no container images, per-token billing. JumpStart deploys LLM containers on SageMaker managed endpoints, requiring instance selection, scaling configuration, and per-hour billing even when idle. Bedrock is preferable when: the workload is bursty (document processing triggers), simplicity is valued, and you need commercially licensed models (Claude, Titan). JumpStart on dedicated instances is preferable when: you need VPC isolation with no data leaving your network, you require fine-tuning on proprietary mortgage data (Bedrock fine-tuning is available but limited), or you need deterministic latency SLAs that serverless APIs cannot guarantee. For a mortgage company processing appraisal PDFs intermittently throughout the day, Bedrock's pay-per-token model is more cost-effective.

**Q6: What does SageMaker Model Monitor detect, and how would you respond to a data drift alert on a credit scoring model?**

Model Monitor detects four drift types: (1) Data quality — feature statistics deviate from baseline (e.g., FICO mean drops, LTV standard deviation increases). (2) Model quality — prediction accuracy against ground truth degrades. (3) Bias drift — fairness metrics across protected classes shift. (4) Feature attribution drift — SHAP importance rankings change. Response process for a credit scoring drift alert: First, examine the drift report to identify which features are drifting. If FICO distribution has shifted, investigate upstream data sourcing (credit bureau pull parameters, borrower population mix change). If the drift is a legitimate population shift (e.g., rate environment changed purchase/refi mix), trigger the retraining pipeline. If the drift is a data quality issue (incorrect ETL), fix the data pipeline and rescore. Document all decisions for model risk management.

**Q7: How would you design a batch scoring pipeline for 500,000 loans monthly using SageMaker, minimizing cost?**

Architecture: (1) EventBridge scheduled rule on the first of the month triggers an AWS Step Functions state machine. (2) Step 1: Snowflake COPY INTO S3 exports loan features. (3) Step 2: SageMaker Batch Transform runs with 4x ml.m5.2xlarge instances, `MultiRecord` strategy, batching 1000 rows per request. Billing is ~2-3 hours total for 500K loans. (4) Step 3: Lambda function loads scored CSV from S3 back to Snowflake via COPY INTO. (5) No persistent endpoint — Batch Transform provisions and terminates instances per job. Estimated cost: ~$2-3 per monthly run vs ~$400/month for an always-on ml.c5.xlarge endpoint. The key cost optimization is eliminating the persistent endpoint entirely since the use case is monthly batch, not real-time.

**Q8: Explain how SageMaker Clarify supports ECOA compliance in a mortgage lending context.**

ECOA (Equal Credit Opportunity Act) and Reg B require that credit decisions not discriminate based on race, color, religion, national origin, sex, marital status, age, or public assistance receipt. SageMaker Clarify computes: (1) **Pre-training bias metrics** — is the training data itself biased? Metrics like Class Imbalance (CI) and Difference in Positive Proportions (DPP) identify if protected groups are underrepresented or historically denied at higher rates. (2) **Post-training bias metrics** — does the trained model produce disparate impact? Disparate Impact (DI) ratio, Statistical Parity Difference. (3) **Explainability** — SHAP values show which features drove a specific denial. For adverse action notice requirements, per-prediction SHAP values can be mapped to FCRA/ECOA-compliant adverse action reason codes. The Clarify output should be reviewed by fair lending counsel and included in model validation documentation.

**Q9: What is the difference between SageMaker real-time endpoints, asynchronous endpoints, and serverless endpoints?**

| Type | Latency | Payload Size | Scaling | Best For |
|---|---|---|---|---|
| Real-time | < 1 second | Up to 6MB | Auto-scaling with warm instances | Lock desk pricing |
| Asynchronous | Seconds to minutes | Up to 1GB | Queue-based, scales to 0 | Complex per-loan scoring |
| Serverless | < 1 second (cold: ~5s) | Up to 4MB | Instant scale-to-0 | Infrequent scoring requests |

For mortgage workloads: real-time for lock desk (< 100 loans/request, SLA < 200ms); async for per-loan document extraction + scoring combos (large payload, acceptable latency); serverless for internal tools, compliance lookups, or test environments where idle cost must be zero.

**Q10: How would you use AWS Glue ML FindMatches to deduplicate loan records across multiple servicer data feeds?**

FindMatches is a supervised deduplication transform. The workflow: (1) Combine all servicer feeds into a single Glue table with a `feed_source` column. (2) Label ~1000 record pairs as match/no-match using the Labeling UI (or import labels from a known golden set). (3) Train the ML transform — Glue trains a model on the labeled pairs. (4) Apply the transform to the full dataset; it assigns `match_id` values to records it believes represent the same loan. (5) A post-processing Glue job picks the canonical record per `match_id` group (e.g., most recent update, or apply field-level priority: servicer A for balance, servicer B for escrow). Precision-recall tradeoff: for regulatory data, set `PrecisionRecallTradeoff` > 0.85 to favor avoiding false merges (incorrectly combining two different loans), accepting that some true duplicates are missed.

---

## Pro Tips

- **Always checkpoint long training jobs.** Any training job over 30 minutes that uses spot instances must implement S3 checkpointing or you risk full restarts.
- **Use SageMaker Experiments even for non-production runs.** Every training run creates a permanent record with hyperparameters, metrics, and artifacts. Invaluable during model risk examination when an auditor asks "show me all models trained on this dataset."
- **Separate IAM roles for training vs. inference.** Training roles need S3 read on raw data; inference roles need only Feature Store read and the inference bucket. Principle of least privilege.
- **Snowflake S3 unload is far faster than row-by-row extraction.** For any dataset over 500K rows, always stage to S3 first via COPY INTO.
- **Use Multi-Model Endpoints when serving many infrequently-used models.** A portfolio of 200 pool-level prepayment models can share a single endpoint — SageMaker lazy-loads models on first request and LRU-evicts cold models.
- **Tag all SageMaker resources.** Tag training jobs, endpoints, and models with `project`, `environment`, `cost-center`. Essential for AWS Cost Explorer allocation in a mortgage company with multiple business units.
- **Bedrock Claude models require explicit model access enablement.** In AWS console, go to Bedrock > Model Access and request access per model per region before running any code. This is a common gotcha that blocks new deployments.
- **SageMaker Pipeline DAGs are immutable after creation — use `upsert()`.** Always call `pipeline.upsert(role_arn=role)` in CI/CD to update an existing pipeline definition rather than creating duplicates.
