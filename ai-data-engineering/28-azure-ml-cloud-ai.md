# Azure ML & Cloud AI Services for Data Engineers

[Back to Index](README.md)

---

## Overview

Azure Machine Learning is Microsoft's cloud-based platform for building, training, deploying, and managing ML models at enterprise scale. For senior data engineers working in the US secondary mortgage market, Azure ML provides native integration with SQL Server, Snowflake, and Azure Data Factory — enabling end-to-end ML pipelines that sit alongside existing data infrastructure. This module covers the full Azure ML stack plus the Cognitive Services and OpenAI offerings that are increasingly embedded in data pipelines.

---

## Key Concepts at a Glance

| Component | What It Does | Mortgage Use Case |
|---|---|---|
| Azure ML Studio | Browser-based IDE for ML | Build credit scoring experiments |
| Compute Clusters | Auto-scaling training compute | Train models on full loan tape history |
| Azure ML Pipelines | Orchestrate multi-step ML workflows | Feature engineering -> training -> scoring |
| AutoML | Automated model selection + tuning | Baseline prepayment speed models |
| Model Registry | Version and stage ML models | Promote v3 credit model to production |
| Azure OpenAI | Enterprise GPT-4 + embeddings API | Summarize loan servicing notes |
| Form Recognizer / AI Document Intelligence | Extract structured fields from PDFs | Parse 1003, closing disclosures, appraisals |
| AI Search (Cognitive Search) | Vector + keyword + semantic search | Search loan condition comments |
| Azure Databricks ML | Databricks with MLflow on Azure | Large-scale MBS pool analytics |

---

## 1. Azure ML Studio: Workspaces, Compute, and Datasets

### Workspace Architecture

An Azure ML Workspace is the top-level resource. It owns:
- **Compute** (instances, clusters, serverless, attached Kubernetes)
- **Datasets / Data Assets** (registered data references)
- **Experiments** (run history, metrics, logs)
- **Models** (registry entries with versions and stages)
- **Endpoints** (real-time and batch deployment targets)
- **Pipelines** (reusable orchestration DAGs)

A workspace ties to a Resource Group, Storage Account (blob), Key Vault, Container Registry, and Application Insights. All are created together via the workspace provisioning.

### Compute Options

```
Compute Instance   -- Single-node VM for development notebooks (D-series, GPU options)
Compute Cluster    -- Multi-node auto-scaling for training (min 0 nodes = cost savings)
Serverless Compute -- No pre-provisioned cluster; job scheduler handles resource allocation
Attached Compute   -- External Databricks, Synapse, HDInsight, or AKS clusters
Inference Cluster  -- AKS cluster managed by Azure ML for real-time endpoints
```

**Mortgage relevance:** A compute cluster with `min_instances=0` and `max_instances=8` scales to zero overnight, avoiding idle cost when batch scoring is not running.

---

## 2. Azure ML Pipelines

### Pipeline Step Types

| Step Type | Purpose |
|---|---|
| `PythonScriptStep` | Run arbitrary Python on a compute cluster |
| `ParallelRunStep` | Distributed inference over large file sets |
| `AutoMLStep` | Embed AutoML experiment inside a pipeline |
| `DataTransferStep` | Move data between datastores |
| `HyperDriveStep` | Hyperparameter sweep inside a pipeline |

### SDK v2 Pipeline Example

```python
from azure.ai.ml import MLClient, Input, Output
from azure.ai.ml.dsl import pipeline
from azure.ai.ml import command
from azure.identity import DefaultAzureCredential

ml_client = MLClient(
    credential=DefaultAzureCredential(),
    subscription_id="<sub-id>",
    resource_group_name="rg-mortgage-ml",
    workspace_name="aml-mortgage-prod"
)

# Define component: feature engineering
feature_eng = command(
    name="feature_engineering",
    display_name="Loan Feature Engineering",
    code="./src/feature_eng",
    command="python feature_eng.py --input ${{inputs.raw_loans}} --output ${{outputs.features}}",
    environment="azureml:mortgage-sklearn-env:3",
    compute="cpu-cluster-8",
    inputs={"raw_loans": Input(type="uri_folder")},
    outputs={"features": Output(type="uri_folder")},
)

# Define component: model training
train_model = command(
    name="train_credit_model",
    display_name="Train Credit Score Model",
    code="./src/train",
    command="python train.py --features ${{inputs.features}} --model-output ${{outputs.model}}",
    environment="azureml:mortgage-sklearn-env:3",
    compute="cpu-cluster-8",
    inputs={"features": Input(type="uri_folder")},
    outputs={"model": Output(type="mlflow_model")},
)

@pipeline(
    name="mortgage_credit_scoring_pipeline",
    description="End-to-end credit model retraining pipeline",
)
def mortgage_pipeline(raw_loan_data):
    feat_step = feature_eng(raw_loans=raw_loan_data)
    train_step = train_model(features=feat_step.outputs.features)
    return {"trained_model": train_step.outputs.model}

pipeline_job = mortgage_pipeline(
    raw_loan_data=Input(
        type="uri_folder",
        path="azureml://datastores/loan_tape_store/paths/2026/Q1/"
    )
)

submitted = ml_client.jobs.create_or_update(pipeline_job, experiment_name="credit-model-v4")
print(f"Pipeline job submitted: {submitted.name}")
```

---

## 3. Azure AutoML

AutoML iterates over algorithm families and hyperparameter combinations to find the best model for a given task. For data engineers it is valuable as a fast baseline before investing in custom model development.

### Supported Task Types

- Classification (loan default binary prediction)
- Regression (prepayment speed, LTV at origination)
- Forecasting (delinquency rates, monthly prepayment CPR)
- NLP classification (loan condition text categorization)
- Computer Vision (document image classification)

### AutoML SDK v2 Example

```python
from azure.ai.ml import automl, Input
from azure.ai.ml.constants import AssetTypes

# Forecasting prepayment CPR by pool
forecasting_job = automl.forecasting(
    compute="cpu-cluster-8",
    experiment_name="cpr-forecast-automl",
    training_data=Input(
        type=AssetTypes.MLTABLE,
        path="azureml://datastores/loan_tape_store/paths/cpr_monthly/"
    ),
    target_column_name="CPR",
    primary_metric="normalized_root_mean_squared_error",
    forecast_horizon=12,        # months ahead
    time_column_name="as_of_date",
    time_series_id_column_names=["pool_id", "product_type"],
    n_cross_validations=5,
)
forecasting_job.set_limits(
    timeout_minutes=120,
    max_trials=50,
    enable_early_termination=True,
)
returned_job = ml_client.jobs.create_or_update(forecasting_job)
```

---

## 4. Azure ML Model Registry and Deployment

```python
from azure.ai.ml.entities import Model, ManagedOnlineEndpoint, ManagedOnlineDeployment
from azure.ai.ml.constants import AssetTypes

# Register model from completed training job
model = ml_client.models.create_or_update(
    Model(
        path=f"azureml://jobs/{submitted.name}/outputs/trained_model",
        name="credit-score-model",
        description="XGBoost credit scoring model - Q1 2026 retrain",
        type=AssetTypes.MLFLOW_MODEL,
        tags={"regulatory": "FHFA-compliant", "vintage": "2026Q1"},
    )
)

# Create real-time endpoint
endpoint = ManagedOnlineEndpoint(
    name="credit-score-endpoint",
    auth_mode="key",
)
ml_client.online_endpoints.begin_create_or_update(endpoint).result()

# Deploy model to endpoint
deployment = ManagedOnlineDeployment(
    name="blue",
    endpoint_name="credit-score-endpoint",
    model=f"credit-score-model:{model.version}",
    instance_type="Standard_DS3_v2",
    instance_count=2,
)
ml_client.online_deployments.begin_create_or_update(deployment).result()
```

---

## 5. Azure ML + SQL Server Integration

### In-Database Scoring with SQL Server ML Services

SQL Server 2019+ includes ML Services (Python/R in-process). Models trained in Azure ML can be serialized and called directly from T-SQL:

```sql
-- Store serialized model in a table
CREATE TABLE dbo.MLModels (
    ModelName    VARCHAR(100) PRIMARY KEY,
    ModelBinary  VARBINARY(MAX),
    TrainedDate  DATE,
    AUC          FLOAT
);

-- Score loans using Python ML Services
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'
import pickle, pandas as pd
model = pickle.loads(bytes(model_binary[0]))
df = InputDataSet.copy()
df["score"] = model.predict_proba(
    df[["fico","ltv","dti","loan_age","product_type_enc"]]
)[:,1]
OutputDataSet = df[["loan_id","score"]]
',
    @input_data_1 = N'
        SELECT loan_id, fico, ltv, dti, loan_age,
               product_type_enc
        FROM   dbo.LoanFeatures
        WHERE  as_of_date = CONVERT(date, GETDATE())
    ',
    @params = N'@model_binary VARBINARY(MAX)',
    @model_binary = (SELECT ModelBinary FROM dbo.MLModels WHERE ModelName = ''credit-score-v4'')
WITH RESULT SETS ((loan_id BIGINT, score FLOAT));
```

---

## 6. Azure Cognitive Services for Mortgage Data

### Azure AI Document Intelligence (Form Recognizer)

Extracts structured fields from unstructured mortgage documents — 1003 applications, appraisals, closing disclosures, pay stubs.

```python
from azure.ai.formrecognizer import DocumentAnalysisClient
from azure.core.credentials import AzureKeyCredential

client = DocumentAnalysisClient(
    endpoint="https://mortgage-doc-ai.cognitiveservices.azure.com/",
    credential=AzureKeyCredential("<key>")
)

with open("loan_1003_scan.pdf", "rb") as f:
    poller = client.begin_analyze_document(
        "prebuilt-mortgage.us.1003",   # prebuilt 1003 model
        document=f
    )

result = poller.result()
for field_name, field in result.documents[0].fields.items():
    print(f"{field_name}: {field.value!r}  (confidence: {field.confidence:.2f})")
# Output example:
# BorrowerName: 'Jane Smith'  (confidence: 0.98)
# LoanAmount: 425000.0        (confidence: 0.99)
# PropertyAddress: '123 Main St, Anytown VA 22033'  (confidence: 0.97)
```

### Azure OpenAI Service

```python
from openai import AzureOpenAI

client = AzureOpenAI(
    azure_endpoint="https://mortgage-openai.openai.azure.com/",
    api_key="<key>",
    api_version="2024-08-01-preview"
)

# Summarize loan servicing notes for risk review
def summarize_servicing_notes(notes_text: str) -> str:
    response = client.chat.completions.create(
        model="gpt-4o",
        messages=[
            {"role": "system", "content":
             "You are a mortgage risk analyst. Summarize servicing notes "
             "into: (1) current status, (2) key risk flags, (3) recommended action."},
            {"role": "user", "content": notes_text}
        ],
        temperature=0.1,
        max_tokens=400
    )
    return response.choices[0].message.content

# Vectorize loan condition text for semantic search
def embed_loan_condition(text: str) -> list[float]:
    response = client.embeddings.create(
        model="text-embedding-3-large",
        input=text
    )
    return response.data[0].embedding
```

---

## 7. Azure AI Search (Cognitive Search) — Vector + Semantic

```python
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery
from azure.core.credentials import AzureKeyCredential

search_client = SearchClient(
    endpoint="https://mortgage-search.search.windows.net",
    index_name="loan-conditions-index",
    credential=AzureKeyCredential("<key>")
)

query_vector = embed_loan_condition("borrower unable to provide income documentation")

results = search_client.search(
    search_text=None,
    vector_queries=[
        VectorizedQuery(
            vector=query_vector,
            k_nearest_neighbors=5,
            fields="condition_vector"
        )
    ],
    select=["loan_id", "condition_text", "assigned_to", "created_date"]
)

for r in results:
    print(f"Loan {r['loan_id']}: {r['condition_text'][:80]}")
```

---

## 8. Azure Databricks ML

Databricks on Azure combines Delta Lake, Spark, and MLflow in a lakehouse architecture. It is the preferred choice when training data volumes exceed single-node capacity (multi-billion-row loan history).

```python
# In a Databricks notebook (DBR 14.x ML Runtime)
import mlflow
import mlflow.xgboost
from pyspark.sql import SparkSession
import xgboost as xgb
from sklearn.model_selection import train_test_split

spark = SparkSession.builder.getOrCreate()

# Read Delta Lake loan table — time travel to training cutoff
df = spark.read.format("delta") \
    .option("versionAsOf", 142) \
    .table("mortgage.loan_features_gold") \
    .toPandas()

X = df[["fico","ltv","dti","loan_age","product_type_enc"]]
y = df["default_flag"]
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)

mlflow.set_experiment("/Shared/Mortgage/credit-model")
with mlflow.start_run(run_name="xgb-Q1-2026"):
    mlflow.xgboost.autolog()
    model = xgb.XGBClassifier(
        n_estimators=500, max_depth=6, learning_rate=0.05,
        use_label_encoder=False, eval_metric="auc"
    )
    model.fit(X_train, y_train, eval_set=[(X_test, y_test)])
    mlflow.log_param("training_version", 142)
    mlflow.log_metric("test_auc", float(model.evals_result()["validation_0"]["auc"][-1]))
```

---

## 9. Azure Data Factory with ML Integration

ADF can call Azure ML pipelines as an activity within a broader data orchestration workflow:

```json
{
  "name": "CallCreditScoringPipeline",
  "type": "AzureMLExecutePipeline",
  "typeProperties": {
    "mlPipelineId": "pipeline-credit-scoring-v4-id",
    "experimentName": "credit-model-retrain",
    "mlPipelineParameters": {
      "as_of_date": "@formatDateTime(pipeline().parameters.asOfDate,'yyyy-MM-dd')"
    }
  }
}
```

**Typical ADF + AML orchestration pattern:**
1. ADF Copy Activity pulls loan tape from Snowflake to ADLS Gen2
2. ADF AzureMLExecutePipeline runs feature engineering + scoring
3. ADF Copy Activity writes scored output back to Snowflake
4. ADF stored procedure calls SQL Server to update dashboard tables

---

## 10. Pricing and Cost Management

| Resource | Approx Cost | Cost Control Strategy |
|---|---|---|
| Compute Cluster (D4s v3, 4 cores) | ~$0.19/hr/node | Set min_instances=0; idle teardown |
| Compute Instance (DS3 v2) | ~$0.27/hr | Auto-shutdown schedule |
| Serverless Compute | Per-second billing | Default for dev/test workloads |
| Managed Online Endpoint (DS3 v2 x2) | ~$0.54/hr | Use batch endpoint for non-RT scoring |
| Azure OpenAI GPT-4o | ~$5/1M input tokens | Cache embeddings; use GPT-4o-mini for triage |
| Form Recognizer | $1.50/1000 pages | Batch PDFs; cache extracted JSON |

---

## Interview Q&A

**Q1: How does Azure ML compute cluster auto-scaling work and what are the cold-start implications for production scoring?**

A compute cluster scales from 0 to N nodes based on job queue depth. When `min_instances=0`, the first job submitted after idle teardown waits 2-5 minutes for node provisioning. For production scoring pipelines where latency matters (e.g., same-day lock requests), set `min_instances=1` or use Serverless Compute which has faster cold-start. For nightly batch scoring, zero-node idle is appropriate since the ADF trigger has no SLA tighter than 15 minutes.

**Q2: What is the difference between Azure ML Managed Online Endpoints and Batch Endpoints? When would you use each in a mortgage context?**

Managed Online Endpoints provide synchronous, low-latency HTTP inference (P99 < 200ms) backed by auto-scaling AKS. Batch Endpoints run asynchronous inference over file sets, invoked by job submission rather than HTTP request. In a mortgage pipeline, use online endpoints for real-time lock desk pricing that needs sub-second scores; use batch endpoints for nightly full-portfolio re-scoring of 500K loans against the updated credit model. Batch endpoints are significantly cheaper because compute is only allocated during job execution.

**Q3: How would you integrate Azure AI Document Intelligence into a loan origination data pipeline?**

Design the pipeline as: (1) Document arrives in ADLS blob container (trigger via Event Grid). (2) ADF pipeline calls Form Recognizer using the prebuilt 1003 or custom trained model. (3) Extracted JSON fields are validated against business rules (required fields present, confidence > 0.85). (4) High-confidence extractions are inserted directly into the SQL Server loan staging table. (5) Low-confidence documents are routed to a human review queue (Logic App / Teams notification). This replaces manual data entry for approximately 80% of documents and routes the difficult 20% to reviewers with pre-populated fields.

**Q4: How does Azure ML SDK v2 differ from v1, and why should a data engineer care?**

SDK v2 introduces a YAML-first, CLI-compatible approach where components, environments, and jobs are defined as reusable YAML assets versioned in a registry. Key differences: components replace PipelineStep classes; `@pipeline` decorator replaces Pipeline/StepSequence; job submission replaces Experiment.submit(). For data engineers, v2 is important because it aligns with the Azure ML CLI v2, enabling GitOps-style ML pipelines where job definitions are stored in source control and deployed via CI/CD. If you are maintaining a pre-2023 codebase, migration from v1 to v2 is not trivial but is required for long-term support.

**Q5: Explain how you would use Azure OpenAI embeddings to build a semantic search index over loan condition text in a large servicing portfolio.**

Generate embeddings (text-embedding-3-large, 3072 dimensions) for each unique condition text string — not each loan, since conditions repeat across loans. Store embeddings in Azure AI Search with a vector field. At query time, embed the search query and run a vector similarity search (cosine distance, top-k=10). Optionally combine with keyword filters (loan_status='Active', assigned_team='QC'). Rerank results with Azure AI Search semantic ranker. This enables analysts to search "borrower hardship income loss" and find all loans with semantically similar conditions even if exact wording differs. Cache embeddings in SQL Server to avoid re-generating for known condition strings.

**Q6: What is Azure AutoML's "glass-box" vs "black-box" distinction and how does it affect regulatory use in mortgage lending?**

AutoML produces models that can be inspected via SHAP (SHapley Additive exPlanations) feature importance, stored in the MLflow run. However, the ECOA/Reg B requirement for adverse action notices mandates that a lender can explain specific denial reasons for individual applicants. Azure AutoML models satisfy this via the Responsible AI dashboard, which provides per-prediction SHAP waterfall charts. That said, regulators (OCC, FFIEC) expect a model governance process: documented model risk management, champion-challenger testing, and annual validation. AutoML is appropriate for initial model selection but the final production model must be validated by a model risk team before deployment in underwriting.

**Q7: How would you set up an Azure ML Pipeline for monthly model retraining triggered by data drift detection?**

Architecture: (1) Azure ML Model Monitor runs weekly data drift detection comparing production scoring inputs to training baseline. (2) When drift score exceeds threshold (e.g., Population Stability Index > 0.2), Model Monitor triggers an Azure Event Grid event. (3) ADF or Logic App receives the event and submits the AML retraining pipeline. (4) Retraining pipeline runs: data validation -> feature engineering -> AutoML/custom training -> champion-challenger evaluation. (5) If new model AUC improvement > 1%, it is registered as a new model version with status=Staging. (6) Model Risk team approves promotion to Production via the Model Registry stage transition. The full pipeline should be idempotent — re-running it with the same data produces the same registered model version.

**Q8: How does Azure Databricks ML integrate with Azure ML?**

Databricks can log experiments and models to Azure ML's MLflow tracking server using the azureml-mlflow package. Set `mlflow.set_tracking_uri(ws.get_mlflow_tracking_uri())` inside a Databricks notebook. Models trained in Databricks appear in the Azure ML Model Registry. Databricks is preferred when: training data is in Delta Lake at scale (>100M rows), feature engineering requires Spark, or GPU clusters are needed for deep learning. Azure ML is preferred for managed endpoints, AutoML, and tight ADF integration. The two platforms are complementary on Azure: Databricks for compute-heavy training, Azure ML for deployment and governance.

**Q9: What are the key security and compliance considerations when deploying Azure ML in a mortgage company's environment?**

- **Network isolation:** Deploy workspace with Private Endpoint; disable public internet access. All compute communicates via VNet injection.
- **Data residency:** Configure all datastores in the same Azure region (e.g., East US) to comply with data residency requirements.
- **Key management:** Use Customer-Managed Keys (CMK) with Azure Key Vault for workspace storage encryption. Required for NPI (non-public personal information) in loan data.
- **RBAC:** Assign least-privilege roles — Data Scientists get AzureML Data Scientist role (no endpoint management); Data Engineers get Contributor on datastores only.
- **Audit logging:** Enable Azure Monitor diagnostic settings on the workspace; forward to Log Analytics. FFIEC exam may request access logs.
- **Model governance:** All models in production must have documented training data lineage, performance metrics, and approval date — use Azure ML tags and the Model Registry description fields.

**Q10: How would you use Azure Machine Learning CLI v2 to automate pipeline submissions in a CI/CD context?**

```bash
# Login and set workspace context
az ml configure --defaults workspace=aml-mortgage-prod \
                            resource-group=rg-mortgage-ml \
                            location=eastus

# Submit a pipeline job defined in YAML
az ml job create --file ./pipelines/credit-retrain-job.yml \
                 --set inputs.as_of_date="2026-03-01" \
                 --stream

# Promote model to production after review
az ml model update --name credit-score-model \
                   --version 7 \
                   --set tags.stage=Production
```
In a GitHub Actions or Azure DevOps pipeline, this allows model retraining to be triggered by a pull request merge or scheduled cron, with the ML workspace credentials stored as pipeline secrets. The YAML job definition lives in source control, providing full auditability.

---

## Pro Tips

- **Tag everything in the Model Registry.** Use tags like `regulatory=FHFA`, `vintage=2026Q1`, `champion=true`. Auditors and model risk teams will thank you.
- **Use Serverless Compute for short ad-hoc jobs.** The 2-3 min cold-start penalty is acceptable; you avoid cluster management overhead entirely.
- **Separate feature engineering code from model training code.** Register feature engineering as its own component so it can be reused across models (credit, prepayment, valuation).
- **Cache Form Recognizer results.** Store extracted JSON in a blob alongside the source PDF with the same name. Before calling the API, check if a cached JSON exists. Form Recognizer billing is per page — caching eliminates redundant calls on reprocessing runs.
- **Azure OpenAI deployments are regional.** If your primary region has quota limits, request capacity in a secondary region and implement retry-with-fallback in your embedding service code.
- **Monitor compute cluster quota.** Default Azure subscription quotas for GPU/high-memory VMs are low. Submit quota increase requests before a project deadline, not during.
- **Use Delta Lake on ADLS Gen2 as your Azure ML datastore.** It gives you time travel for reproducible training data versions — critical for model validation and regulatory back-testing.
- **ParallelRunStep / ParallelJob is the right tool for batch inference over millions of loans.** It shards the input dataset across N mini-batches and runs them on all cluster nodes simultaneously. Throughput scales linearly with node count.
