# AI Cost Optimization & Infrastructure for Data Engineers
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

AI infrastructure cost management has become a core responsibility for data engineers as LLM APIs, GPU compute, and vector databases move from experimental to production. For a senior data engineer in the secondary mortgage market, the stakes are high: a poorly architected AI pipeline can consume tens of thousands of dollars per month in API credits and compute — often without a clear ROI story to justify it.

This topic appears in senior DE interviews because hiring managers want to know that candidates can design cost-conscious AI systems, not just systems that work. You will be asked to reason about model selection, caching strategies, infrastructure tradeoffs, and how to build the business case for AI investment.

---

## Key Concepts

| Concept | Definition |
|---|---|
| Token | The unit of LLM billing; roughly 0.75 words per token |
| Input vs output tokens | Input (prompt) tokens cost less than output (completion) tokens |
| Prompt caching | Reusing a cached KV state for repeated prompt prefixes — reduces input token costs |
| Semantic caching | Caching LLM responses by embedding similarity rather than exact match |
| Quantization | Reducing model weight precision (FP32 → INT8 → INT4) to shrink size and speed inference |
| Distillation | Training a smaller student model to mimic a larger teacher model |
| Pruning | Removing low-importance weights from a trained model |
| Spot/preemptible instances | Spare cloud capacity at 60-90% discount; can be reclaimed with short notice |
| ONNX | Open Neural Network Exchange — cross-platform format for optimized inference |
| Cortex | Snowflake's serverless AI/ML function layer; billed in Snowflake credits |

---

## Detailed Explanations

### LLM API Cost Structure

#### Pricing by Model (March 2026 approximate)

| Model | Input (per 1M tokens) | Output (per 1M tokens) | Best For |
|---|---|---|---|
| GPT-4o | $5.00 | $15.00 | Complex reasoning, multi-step tasks |
| GPT-4o mini | $0.15 | $0.60 | Classification, extraction, simple Q&A |
| Claude Sonnet 4.x | $3.00 | $15.00 | Long context, analysis, code generation |
| Claude Haiku 3.x | $0.25 | $1.25 | High-volume, latency-sensitive tasks |
| Llama 3.3 70B (self-hosted) | ~$0.40-0.80* | same | Cost control at scale, no data leaving infra |
| Snowflake Cortex (mistral-large) | ~4 credits/1K tokens | varies | Already in Snowflake ecosystem |

*Self-hosted inference cost depends on GPU instance type and utilization rate.

#### Input vs Output Token Cost Asymmetry

Output tokens cost 3-5x more than input tokens across all major providers. This has direct architectural implications:

- Long system prompts are relatively cheap — invest in detailed instructions to reduce back-and-forth
- Streaming responses that generate verbose output are expensive — constrain output with explicit instructions ("respond in JSON only", "limit to 200 words")
- Few-shot examples in the prompt (input tokens) are cheaper than hoping the model figures it out and requiring correction turns (more output tokens)

For mortgage document processing (loan applications, appraisals, title commitments), a typical extraction prompt might be 2,000 input tokens with 500 output tokens. At GPT-4o pricing: (2000/1M × $5) + (500/1M × $15) = $0.01 + $0.0075 = $0.0175 per document. At 100,000 documents/month: $1,750/month just for one extraction task.

#### Prompt Caching (Claude)

Anthropic's prompt caching allows you to mark prompt prefixes (system prompts, few-shot examples, large context documents) as cacheable. Cached tokens cost 90% less on re-read. A 10,000-token system prompt used in 1 million calls:

- Without caching: 10,000 × 1M × $3.00/1M = $30,000
- With caching (after first write): 10,000 × 1M × $0.30/1M = $3,000 (90% savings)

Cache lifetime is 5 minutes for standard calls; extended caching is available for longer-lived sessions.

---

### Compute Infrastructure for ML

#### CPU vs GPU vs TPU

| Scenario | Recommended Compute | Reason |
|---|---|---|
| Batch inference, small models (<1B params) | CPU (c5/c6i instances) | Cost-effective, no GPU memory overhead |
| Real-time inference, large models | GPU (T4, A10G) | Parallelism required for acceptable latency |
| Training large models (>7B params) | GPU (A100, H100) | Memory bandwidth and FLOP throughput |
| Training at Google scale | TPU v4/v5 | Purpose-built, not available on other clouds |
| Embedding generation at scale | GPU (T4) or CPU with ONNX | Embeddings are inference — T4 is cost-optimal |

#### GPU Types for ML Workloads

| GPU | VRAM | FP16 TFLOPS | Best Use Case | Approx On-Demand $/hr |
|---|---|---|---|---|
| T4 | 16GB | 65 | Inference, small model fine-tuning | $0.53 (g4dn.xlarge) |
| A10G | 24GB | 125 | Inference, mid-size models | $1.20 (g5.xlarge) |
| A100 (40GB) | 40GB | 312 | Training, large model inference | $3.20 (p4d) |
| A100 (80GB) | 80GB | 312 | Training 13B+ models | $4.10 |
| H100 | 80GB | 1,979 | Training frontier models | $10-15 |

For secondary mortgage market AI workloads (document classification, data extraction, anomaly detection on loan tapes), a T4 or A10G for inference and an A100 for occasional fine-tuning is the typical architecture. H100s are only justified for training models from scratch, which almost no financial institution does.

#### Spot Instances: 60-80% Cost Reduction

Spot (AWS) / Preemptible (GCP) / Spot (Azure) instances use spare capacity at massive discounts. They can be reclaimed with 2-minute (AWS) notice. This makes them ideal for:

- Model training jobs with checkpointing enabled
- Batch inference pipelines (process loan tapes overnight)
- Hyperparameter tuning sweeps

They are NOT suitable for real-time inference APIs serving interactive users.

```python
# Example: SageMaker training job with spot instances
import boto3

sagemaker_client = boto3.client('sagemaker')

training_job_config = {
    'TrainingJobName': 'mortgage-default-model-v3',
    'AlgorithmSpecification': {
        'TrainingImage': '763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-training:2.1-gpu-py310',
        'TrainingInputMode': 'File'
    },
    'EnableManagedSpotTraining': True,
    'StoppingCondition': {
        'MaxRuntimeInSeconds': 86400,
        'MaxWaitTimeInSeconds': 172800  # Wait up to 2x runtime for spot capacity
    },
    'CheckpointConfig': {
        'S3Uri': 's3://mortgage-ml-artifacts/checkpoints/mortgage-default-v3/',
        'LocalPath': '/opt/ml/checkpoints'
    },
    'ResourceConfig': {
        'InstanceType': 'ml.p3.2xlarge',  # V100 GPU
        'InstanceCount': 1,
        'VolumeSizeInGB': 50
    },
    # ... role, input/output config
}
# Spot training on p3.2xlarge: ~$0.918/hr vs $3.06/hr on-demand (70% savings)
```

---

### Snowflake AI Cost Optimization

#### Cortex Credit Consumption

Snowflake Cortex LLM functions are billed in Snowflake credits. Credit consumption varies by model:

| Cortex Function | Model | Credits per 1M tokens |
|---|---|---|
| COMPLETE | mistral-large | ~4-6 credits |
| COMPLETE | llama3.1-70b | ~2-3 credits |
| COMPLETE | mistral-7b | ~0.5 credits |
| EMBED_TEXT_1024 | snowflake-arctic-embed | ~0.2 credits |
| CLASSIFY_TEXT | (managed) | ~0.4 credits |
| SENTIMENT | (managed) | ~0.1 credits |

At $2-4 per Snowflake credit (enterprise pricing varies), processing 1M documents with Cortex COMPLETE on mistral-large could cost $8-24 per million input tokens — more expensive than direct API access. The value proposition is operational simplicity (no ETL to external API, governed billing, no data leaving Snowflake).

#### Warehouse Sizing for ML Workloads

ML workloads in Snowflake (Cortex functions, ML classification, forecasting) have different compute profiles than SQL queries:

```sql
-- Create a dedicated warehouse for AI/ML workloads
-- Separate from ETL and analytics to enable independent scaling and cost tracking
CREATE WAREHOUSE ml_inference_wh
    WAREHOUSE_SIZE = 'MEDIUM'
    AUTO_SUSPEND = 60          -- Aggressive auto-suspend for bursty ML workloads
    AUTO_RESUME = TRUE
    MAX_CLUSTER_COUNT = 3      -- Scale out for parallel document processing
    SCALING_POLICY = 'ECONOMY' -- Prefer filling clusters before adding new ones
    COMMENT = 'AI/ML inference workloads - billed to AI_OPS cost center';

-- Tag for cost allocation
ALTER WAREHOUSE ml_inference_wh SET TAG governance.cost_center = 'AI_OPERATIONS';

-- Batch Cortex calls to amortize warehouse startup cost
-- Bad pattern: calling COMPLETE row-by-row in a loop
-- Good pattern: process in batches using a single query
SELECT
    loan_id,
    SNOWFLAKE.CORTEX.COMPLETE(
        'mistral-7b',
        CONCAT(
            'Extract the following fields from this mortgage note in JSON format: ',
            '{"original_balance": null, "note_rate": null, "maturity_date": null}. ',
            'Document: ', document_text
        )
    ) AS extracted_fields
FROM mortgage_documents
WHERE processing_status = 'pending'
  AND document_type = 'promissory_note'
LIMIT 1000;  -- Process in controlled batches
```

#### Snowflake Serverless Tasks for ML Pipelines

Serverless tasks eliminate warehouse management overhead and idle costs for scheduled ML jobs:

```sql
-- Serverless task: daily synthetic data quality scoring
CREATE OR REPLACE TASK ml_ops.quality_check_task
    SCHEDULE = 'USING CRON 0 6 * * * America/New_York'
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'SMALL'  -- Serverless, auto-sizes
AS
    INSERT INTO ml_ops.synthetic_data_quality_log
    SELECT
        CURRENT_DATE()                               AS check_date,
        'synthetic_loans'                            AS table_name,
        COUNT(*)                                     AS record_count,
        AVG(fico_score)                              AS avg_fico,
        STDDEV(fico_score)                           AS std_fico,
        AVG(ltv_ratio)                               AS avg_ltv,
        COUNT_IF(loan_status != 'current') / COUNT(*)::FLOAT AS default_rate,
        CURRENT_TIMESTAMP()                          AS logged_at
    FROM synthetic_loans
    WHERE generated_at >= DATEADD('day', -1, CURRENT_TIMESTAMP());
```

---

### Model Optimization for Cost

#### Quantization

Quantization reduces the numerical precision of model weights, cutting memory and compute requirements:

| Precision | Size vs FP32 | Accuracy Loss | Use Case |
|---|---|---|---|
| FP32 | 1x | None (baseline) | Training |
| FP16 / BF16 | 0.5x | Negligible | Training, large model inference |
| INT8 | 0.25x | ~0.5-1% | Production inference |
| INT4 | 0.125x | ~1-3% | Edge, cost-sensitive inference |
| GPTQ (4-bit) | 0.125x | ~1-2% | LLM inference on consumer GPUs |

A 7B parameter LLM at FP32 requires ~28GB VRAM. At INT4, it fits in ~4GB — enabling inference on a single T4 GPU instead of requiring an A100.

```python
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
import torch

# Load a Llama model with 4-bit quantization for cost-efficient inference
quantization_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_compute_dtype=torch.bfloat16,
    bnb_4bit_use_double_quant=True,   # Nested quantization for additional savings
    bnb_4bit_quant_type="nf4"          # NF4 data type, better for LLMs
)

model = AutoModelForCausalLM.from_pretrained(
    "meta-llama/Llama-3.1-8B-Instruct",
    quantization_config=quantization_config,
    device_map="auto"
)
tokenizer = AutoTokenizer.from_pretrained("meta-llama/Llama-3.1-8B-Instruct")

# This model now fits on a T4 (16GB) vs requiring an A10G (24GB) at FP16
# T4 on-demand: $0.53/hr vs A10G: $1.20/hr — 56% cost reduction
```

#### Distillation

Train a smaller student model to replicate the behavior of a larger teacher:

1. Generate a labeled dataset by running the teacher model on your task-specific data
2. Fine-tune a smaller base model on teacher outputs
3. The student model runs at a fraction of the cost

Example: distill GPT-4o's mortgage document extraction behavior into a fine-tuned Llama-3.1-8B. The student model runs on a T4 instead of requiring OpenAI API calls. Break-even analysis: if you process >50,000 documents/month, fine-tuning cost is amortized within 1-2 months.

#### ONNX Optimization for Inference

```python
from optimum.onnxruntime import ORTModelForSequenceClassification
from transformers import AutoTokenizer
import numpy as np

# Convert a fine-tuned loan document classifier to ONNX with quantization
# This achieves 2-4x throughput improvement and eliminates PyTorch overhead

model_id = "mortgage-models/loan-doc-classifier-v2"

# Load and export to ONNX with INT8 quantization
ort_model = ORTModelForSequenceClassification.from_pretrained(
    model_id,
    export=True,
    provider="CPUExecutionProvider"  # CPU inference — no GPU needed for this task
)
tokenizer = AutoTokenizer.from_pretrained(model_id)

# Inference is now 3x faster than PyTorch on CPU
def classify_document(text: str) -> str:
    inputs = tokenizer(text, return_tensors="pt", truncation=True, max_length=512)
    outputs = ort_model(**inputs)
    predicted_class = outputs.logits.argmax(-1).item()
    labels = ['purchase_agreement', 'appraisal', 'title_commitment', 'promissory_note', 'closing_disclosure']
    return labels[predicted_class]
```

---

### Vector Database Costs: Managed vs Self-Hosted

| Option | Monthly Cost (10M vectors) | Latency | Operational Overhead |
|---|---|---|---|
| Pinecone (serverless) | ~$70-200 | Low | None |
| Weaviate Cloud | ~$100-300 | Low | None |
| Qdrant Cloud | ~$50-150 | Low | Low |
| pgvector (RDS) | ~$30-80 (RDS cost) | Medium | Medium |
| Qdrant self-hosted (EC2) | ~$30-60 (instance) | Low | High |
| Chroma in-process | ~$0 (compute only) | Very low | High |
| Snowflake (VECTOR type) | Included in warehouse | Medium | None if already in Snowflake |

For mortgage document search (loan policies, guidelines, regulatory docs), Snowflake's native VECTOR type is often the right choice if the data already lives in Snowflake — no additional service to manage or pay for. For high-QPS semantic search (>1,000 queries/second), a dedicated vector DB with ANN indexing is necessary.

---

### Python: API Cost Tracking and Semantic Caching

```python
import hashlib
import time
import json
import sqlite3
from dataclasses import dataclass, asdict
from typing import Optional
import anthropic
import numpy as np
from sentence_transformers import SentenceTransformer

# --- Cost tracker ---
@dataclass
class APICallRecord:
    timestamp: float
    model: str
    input_tokens: int
    output_tokens: int
    input_cost_usd: float
    output_cost_usd: float
    total_cost_usd: float
    cache_hit: bool
    task_type: str

MODEL_PRICING = {
    "claude-haiku-4-5":   {"input": 0.00000025, "output": 0.00000125},
    "claude-sonnet-4-5":  {"input": 0.000003,   "output": 0.000015},
    "gpt-4o":             {"input": 0.000005,    "output": 0.000015},
    "gpt-4o-mini":        {"input": 0.00000015,  "output": 0.0000006},
}

class CostTracker:
    def __init__(self, db_path: str = "ai_cost_tracking.db"):
        self.conn = sqlite3.connect(db_path)
        self._init_db()

    def _init_db(self):
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS api_calls (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL,
                model TEXT,
                input_tokens INTEGER,
                output_tokens INTEGER,
                input_cost_usd REAL,
                output_cost_usd REAL,
                total_cost_usd REAL,
                cache_hit INTEGER,
                task_type TEXT
            )
        """)
        self.conn.commit()

    def record(self, record: APICallRecord):
        d = asdict(record)
        d['cache_hit'] = int(d['cache_hit'])
        self.conn.execute("""
            INSERT INTO api_calls
            (timestamp, model, input_tokens, output_tokens,
             input_cost_usd, output_cost_usd, total_cost_usd, cache_hit, task_type)
            VALUES (:timestamp, :model, :input_tokens, :output_tokens,
                    :input_cost_usd, :output_cost_usd, :total_cost_usd, :cache_hit, :task_type)
        """, d)
        self.conn.commit()

    def monthly_summary(self) -> dict:
        row = self.conn.execute("""
            SELECT
                SUM(total_cost_usd)   AS total_cost,
                SUM(input_tokens)     AS total_input_tokens,
                SUM(output_tokens)    AS total_output_tokens,
                COUNT(*)              AS total_calls,
                SUM(CASE WHEN cache_hit = 1 THEN 1 ELSE 0 END) AS cache_hits,
                SUM(CASE WHEN cache_hit = 1 THEN total_cost_usd ELSE 0 END) AS saved_by_cache
            FROM api_calls
            WHERE timestamp >= strftime('%s', 'now', 'start of month')
        """).fetchone()
        return {
            "total_cost_usd":     round(row[0] or 0, 4),
            "total_input_tokens": row[1] or 0,
            "total_output_tokens":row[2] or 0,
            "total_calls":        row[3] or 0,
            "cache_hit_rate":     round((row[4] or 0) / max(row[3] or 1, 1), 3),
            "saved_by_cache_usd": round(row[5] or 0, 4),
        }

def calculate_cost(model: str, input_tokens: int, output_tokens: int) -> tuple[float, float, float]:
    pricing = MODEL_PRICING.get(model, {"input": 0.000005, "output": 0.000015})
    input_cost  = input_tokens  * pricing["input"]
    output_cost = output_tokens * pricing["output"]
    return input_cost, output_cost, input_cost + output_cost


# --- Semantic cache ---
class SemanticCache:
    """
    Cache LLM responses by embedding similarity.
    If a new query is within cosine similarity threshold of a cached query,
    return the cached response instead of calling the API.
    """
    def __init__(self, similarity_threshold: float = 0.95, cache_size: int = 1000):
        self.threshold = similarity_threshold
        self.cache_size = cache_size
        self.embedder = SentenceTransformer('all-MiniLM-L6-v2')  # 80MB, CPU-friendly
        self.cache: list[dict] = []  # [{embedding, prompt, response, metadata}]

    def _cosine_similarity(self, a: np.ndarray, b: np.ndarray) -> float:
        return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))

    def get(self, prompt: str) -> Optional[str]:
        if not self.cache:
            return None
        query_embedding = self.embedder.encode(prompt)
        best_score, best_response = 0.0, None
        for entry in self.cache:
            score = self._cosine_similarity(query_embedding, entry['embedding'])
            if score > best_score:
                best_score, best_response = score, entry['response']
        if best_score >= self.threshold:
            return best_response
        return None

    def set(self, prompt: str, response: str):
        embedding = self.embedder.encode(prompt)
        self.cache.append({'embedding': embedding, 'prompt': prompt, 'response': response})
        if len(self.cache) > self.cache_size:
            self.cache.pop(0)  # Evict oldest (LRU would be more sophisticated)


# --- Instrumented LLM client ---
class CostAwareLLMClient:
    def __init__(self, task_type: str = "general"):
        self.client = anthropic.Anthropic()
        self.tracker = CostTracker()
        self.semantic_cache = SemanticCache(similarity_threshold=0.95)
        self.task_type = task_type

    def complete(
        self,
        prompt: str,
        model: str = "claude-haiku-4-5",
        max_tokens: int = 512,
        use_cache: bool = True
    ) -> str:
        # Check semantic cache first
        if use_cache:
            cached = self.semantic_cache.get(prompt)
            if cached is not None:
                self.tracker.record(APICallRecord(
                    timestamp=time.time(), model=model,
                    input_tokens=0, output_tokens=0,
                    input_cost_usd=0, output_cost_usd=0, total_cost_usd=0,
                    cache_hit=True, task_type=self.task_type
                ))
                return cached

        # Call API
        response = self.client.messages.create(
            model=model,
            max_tokens=max_tokens,
            messages=[{"role": "user", "content": prompt}]
        )
        result = response.content[0].text
        input_t  = response.usage.input_tokens
        output_t = response.usage.output_tokens
        ic, oc, tc = calculate_cost(model, input_t, output_t)

        self.tracker.record(APICallRecord(
            timestamp=time.time(), model=model,
            input_tokens=input_t, output_tokens=output_t,
            input_cost_usd=ic, output_cost_usd=oc, total_cost_usd=tc,
            cache_hit=False, task_type=self.task_type
        ))

        if use_cache:
            self.semantic_cache.set(prompt, result)

        return result

# Usage
llm = CostAwareLLMClient(task_type="mortgage_extraction")
result = llm.complete(
    "Extract loan_amount, note_rate, and maturity_date from: "
    "Borrower agrees to repay $425,000 at 6.875% per annum, maturing 2054-05-01.",
    model="claude-haiku-4-5"
)
print(llm.tracker.monthly_summary())
```

---

### ROI Calculation for AI Initiatives in Financial Services

A structured ROI framework prevents AI projects from dying in budget reviews:

```
ROI = (Net Benefit - Total Cost) / Total Cost × 100%

Net Benefit = Labor savings + Error reduction value + Throughput increase value + Risk reduction value
Total Cost  = Development + Infrastructure (annual) + Maintenance + Training
```

**Example: AI-assisted loan tape data quality screening**

| Item | Monthly Value/Cost |
|---|---|
| Current manual review: 2 analysts × $95/hr × 20 hrs/month | $3,800 saved |
| Error catch rate improvement: 15% fewer data quality escapes × $500 avg remediation | $750 saved |
| Faster pipeline: 4-hr reduction in month-end close | $200 saved (soft) |
| **Total monthly benefit** | **$4,750** |
| LLM API costs (Haiku, ~500K tokens/month) | $125 |
| Snowflake Cortex credits | $200 |
| Engineering maintenance (0.1 FTE) | $1,500 |
| **Total monthly cost** | **$1,825** |
| **Monthly net benefit** | **$2,925** |
| **Annual ROI** | **160%** |
| **Payback period** (assuming $45K build cost) | ~15 months |

---

### Build vs Buy for AI Infrastructure

| Scenario | Build | Buy |
|---|---|---|
| Standard LLM API usage | N/A | OpenAI / Anthropic API |
| High-volume inference (>10M calls/month) | Self-hosted Llama on EC2 | API if simplicity valued |
| Vector search (already in Snowflake) | Snowflake VECTOR type | Only if QPS >1,000 |
| ML platform / feature store | Only if 50+ ML models | SageMaker / Vertex |
| Model monitoring | MLflow (open source) | Arize / Evidently Cloud |
| Fine-tuning | OpenAI fine-tune API (small) | Self-hosted for large jobs |

---

## Interview Q&A

**Q1: How would you reduce LLM API costs by 80% for a high-volume mortgage document extraction pipeline without changing the model?**

Four levers available without changing the model: (1) Prompt caching — if you have a large system prompt or few-shot examples repeated across calls, mark them as cacheable in Claude or use OpenAI's cached input pricing. On a 5,000-token system prompt repeated 100,000 times, this alone can save 70-90% of input token costs. (2) Semantic caching — many mortgage extraction queries are near-identical (same document templates, same question types). A semantic cache with a 0.95 cosine similarity threshold will hit 30-50% of requests in a production pipeline. (3) Batching — instead of calling the API per document, batch multiple documents into a single prompt with structured output instructions. This amortizes per-request overhead and reduces the number of API calls. (4) Output compression — constrain output format to JSON with specific field names. "Extract in JSON: {loan_amount, note_rate}" generates far fewer output tokens than "Please extract the loan amount and interest rate from the document above and format your answer clearly." Output tokens cost 3-5x more, so this matters.

**Q2: When would you choose a self-hosted Llama model over the OpenAI API for a financial services use case?**

Three scenarios favor self-hosting: (1) Data residency requirements — if loan data cannot leave your cloud VPC, calling OpenAI's API is not possible. Self-hosted Llama on EC2 or inside Snowflake Serverless keeps data internal. (2) Volume economics — at roughly 50,000+ documents per month for complex extraction tasks, the break-even against a Llama deployment on a reserved A10G instance (~$800/month) tips in favor of self-hosting. At 500,000 documents/month, self-hosting is dramatically cheaper. (3) Fine-tuning control — if you need to fine-tune on proprietary mortgage terminology and keep the fine-tuned weights confidential, self-hosting is required. The tradeoff: you own the ops overhead, model updates, and scaling complexity. For most financial institutions at moderate volume, a hybrid approach works well — use the API for development and low-volume tasks, self-host only the pipelines that justify it.

**Q3: Explain quantization. How does INT8 quantization affect a loan classification model and when would you use INT4?**

Quantization converts model weights from high-precision floating point (FP32, 32 bits per weight) to lower precision integers. INT8 uses 8 bits per weight, reducing model size by 75% and memory bandwidth requirements proportionally. For a loan document classifier (say a fine-tuned BERT), INT8 quantization typically causes 0.5-1% accuracy drop because the classifier makes discrete decisions (doc type A vs B) where small weight perturbations matter less than in regression tasks. I use INT8 for production inference on classification and extraction models without hesitation. INT4 goes further — 87.5% size reduction — but accuracy loss reaches 1-3% and is more unpredictable. I use INT4 for LLM inference where the model is so large that INT4 is the only way to fit it on available hardware (e.g., a 7B LLM on a T4 with 16GB VRAM). For critical credit scoring models, I would not use INT4 — the risk of unexpected accuracy degradation in tail cases is not worth the cost savings.

**Q4: What is semantic caching and how does it differ from exact-match caching?**

Exact-match caching stores responses keyed by the exact prompt string. It is effective only when prompts are byte-for-byte identical — rare in practice because dates, document IDs, and small wording variations break the cache. Semantic caching embeds the prompt using a sentence transformer model and stores the embedding alongside the response. On a new query, it embeds the prompt, computes cosine similarity against all cached embeddings, and returns the cached response if similarity exceeds a threshold (typically 0.93-0.97). For mortgage pipelines, this is highly effective because document extraction prompts follow a small number of templates. "Extract the principal balance from this promissory note dated 2024-03-15" and "Extract the principal balance from this promissory note dated 2024-09-22" should return the same instructions to the model — semantic caching catches this. The key tuning parameter is the threshold: too high (0.99) and you get few cache hits; too low (0.85) and you risk returning incorrect cached responses for genuinely different queries.

**Q5: How do Snowflake Cortex AI functions compare to direct API calls for a mortgage data pipeline?**

Cortex's value proposition is operational simplicity: the LLM call happens inside Snowflake's security perimeter, governed by your existing RBAC, billed to your Snowflake contract, and requires no external API credentials management. For a team already heavily invested in Snowflake, this reduces architectural complexity significantly. The tradeoffs: Cortex model selection is limited to what Snowflake offers (Mistral, Llama, Snowflake Arctic, Reka); you cannot use Claude or GPT-4o. Cortex credit costs per token are higher than direct API calls once you account for the credit-to-dollar conversion. Cortex is the right choice when: the data is already in Snowflake, compliance requires data never leave the platform, and the available models are sufficient for the task (most extraction and classification tasks). Direct API calls are better when: you need the latest frontier models, you are doing complex reasoning that requires GPT-4o or Claude, or your per-token volume is high enough that the cost premium of Cortex is material.

**Q6: How would you architect a cost-efficient ML training pipeline for a mortgage default prediction model that retrains monthly?**

Monthly retraining with cost efficiency points to spot instances with checkpointing. My architecture: (1) Data prep runs in Snowflake (already paid for) — feature engineering, train/test split, export to S3 as parquet; (2) Training launches on AWS SageMaker with managed spot training on p3.2xlarge (~$0.92/hr vs $3.06/hr on-demand, 70% savings). Training with checkpointing means if the spot instance is reclaimed, the job resumes from the last checkpoint rather than starting over. For a gradient boosting model on 2M loan records, training typically completes in 2-4 hours, so spot interruption risk is low; (3) Model artifacts (weights, feature importance, SHAP values) are stored in S3 and registered in MLflow; (4) Inference is served via a persistent low-cost endpoint — a c6i.xlarge CPU instance running the XGBoost model via FastAPI, containerized in ECS Fargate. The model does not need GPU for inference. Total monthly compute cost for this pipeline: approximately $40-80 in spot training + $150-200 for a persistent CPU inference endpoint.

**Q7: How do you build a business case for AI infrastructure investment in a mortgage servicer?**

I use a four-part framework. First, quantify the current state cost: how many analyst-hours per month are spent on the manual process the AI will replace, at what fully-loaded hourly rate. Second, model the benefit: labor savings, error reduction (each data quality escape in a loan tape has a known remediation cost), throughput improvement (can we process more pools per month?), and risk reduction (can we catch compliance issues before they become regulatory findings?). Third, model the AI cost: API/Cortex credits, infrastructure, and an engineering FTE fraction for maintenance — I always include maintenance because systems that appear free to run become expensive when something breaks. Fourth, calculate payback period: for regulatory risk reduction, I also include a probability-weighted cost of non-compliance (OCC exam findings, repurchase demands from agencies). At most servicers, a well-structured AI investment targeting manual data processing tasks pays back in 12-18 months and provides ongoing ROI of 100-200%. The key is being conservative on the benefit side and explicit on the cost side — CFOs in financial services distrust AI hype and will respect detailed cost modeling.

**Q8: What is model distillation and when would you use it for a mortgage AI use case?**

Distillation trains a smaller student model to replicate the outputs of a larger teacher model. The process: (1) run the expensive teacher model (e.g., GPT-4o) on a large set of mortgage documents to generate high-quality labeled outputs; (2) fine-tune a smaller base model (e.g., Llama-3.1-8B) on those teacher-labeled examples; (3) the student model learns to produce teacher-quality outputs at a fraction of the inference cost. I would use this for a high-volume extraction task — for example, extracting structured data fields from title commitments or closing disclosures, where we have 500,000+ documents per month. The one-time cost of generating teacher labels (perhaps $5,000-10,000 in API calls) is amortized over months of cheap student model inference. The risk is that the student model may fail on edge cases that the teacher handled gracefully — so I always maintain a fallback where low-confidence student predictions are routed to the teacher model for review.

**Q9: How do you monitor and alert on AI infrastructure costs to prevent budget overruns?**

Three layers of cost monitoring. First, real-time tracking: every LLM API call logs input tokens, output tokens, model, and computed cost to a cost_tracking table (SQLite for dev, Snowflake for production). This enables dashboards showing daily burn rate vs budget. Second, budget alerts: AWS Budgets alerts at 80% and 100% of monthly LLM API budget; Snowflake resource monitors with SUSPEND action at the credit limit for the ML warehouse. Third, anomaly detection: a daily job computes rolling average cost per document processed. If cost per document spikes (e.g., a prompt change accidentally increased token usage by 5x), the alert fires before the monthly bill arrives. In production, I also track cache hit rate — a drop from 40% to 5% cache hits is an early warning that something changed in the prompt structure that broke semantic caching, causing unnecessary API spend.

**Q10: What GPU would you choose for running a fine-tuned 7B LLM for real-time mortgage document Q&A, and why?**

For real-time inference on a 7B LLM, the A10G (24GB VRAM) is my first choice. At FP16, a 7B model requires ~14GB VRAM, which fits comfortably on an A10G with headroom for batch size > 1. The A10G offers 125 TFLOPS of FP16 compute and costs approximately $1.20/hr on g5.xlarge — a reasonable cost for real-time inference. If I apply INT4 quantization (GPTQ or AWQ), the model fits on a T4 (16GB VRAM) at $0.53/hr — a 56% cost reduction. The tradeoff is slightly higher latency per token (T4 has lower throughput) and 1-2% accuracy degradation from quantization. For a document Q&A use case where accuracy on edge cases matters (loan officers are querying complex title insurance exceptions), I would prefer the A10G at FP16. If this were a high-volume classification task where a 1% accuracy drop is acceptable, I would quantize to INT4 and run on T4 instances. I would not use an H100 for inference — the 10-15x cost premium over A10G is only justified for training or extremely high-throughput batch inference at scale.

---

## Pro Tips

- **Track cost per unit of output, not total cost.** "We spent $3,000 on LLM APIs last month" is meaningless. "$0.003 per document extracted" is actionable. Normalize cost to your business metric from day one.

- **Haiku for classification, Sonnet for reasoning.** In nearly every financial services AI pipeline, 70-80% of tasks are structured extraction or classification — these do not require frontier model capability. Default to Claude Haiku or GPT-4o mini for these. Reserve Sonnet/GPT-4o for tasks that demonstrably require complex reasoning. A mixed-model routing layer pays for itself immediately.

- **Reserved instances for stable inference workloads.** If you have a persistent inference endpoint that runs 24/7, a 1-year reserved instance saves 30-40% over on-demand. Do not run production inference on on-demand instances after the workload stabilizes.

- **Snowflake resource monitors are non-negotiable.** Every ML warehouse should have a resource monitor with a SUSPEND action. One runaway Cortex query processing the wrong table without a LIMIT can consume a month's worth of credits in hours.

- **Semantic caching threshold tuning matters.** Spend time on this. Run your first week of production queries without caching to build a representative query set. Then sweep similarity thresholds from 0.90 to 0.98 and measure cache hit rate vs false-positive rate (wrong cached answer returned). The optimal threshold is use-case specific.

- **Model the full cost lifecycle.** The most common mistake in AI project budgeting is counting only API/compute costs and forgetting: data labeling for fine-tuning, engineering time for prompt engineering and evaluation, monitoring infrastructure, and the cost of model retraining when data drift degrades performance. A complete cost model adds 40-60% to the naive estimate.

- **Build a model selection decision tree for your org.** Document which model to use for which task class, with cost and latency benchmarks from your actual workloads. This prevents every new project from independently discovering that GPT-4o is expensive and Haiku is fast — and prevents the opposite mistake of defaulting to cheap models for tasks that require strong reasoning.

---

*Last updated: March 2026 | Study track: AI in Data Engineering*
