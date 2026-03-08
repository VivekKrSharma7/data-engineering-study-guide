# LLM Fine-tuning & Adaptation (LoRA, PEFT, RLHF)
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

Fine-tuning adapts a pre-trained large language model to a specific domain, task, or behavior. For a senior data engineer in the secondary mortgage market, fine-tuning is relevant when base models underperform on domain-specific tasks: generating syntactically correct Snowflake SQL for your proprietary schema, understanding mortgage terminology (WALA, CPR, PSA, CLTV), or producing structured outputs that match your internal data formats.

This module covers the full spectrum — from deciding whether fine-tuning is the right tool, through the mechanics of LoRA and QLoRA, to practical execution on Hugging Face, Azure ML, AWS SageMaker, and Snowflake Cortex.

---

## When to Fine-tune vs. Alternatives

| Approach | When to Use | Cost | Effort |
|---|---|---|---|
| Prompt engineering | Base model is capable; just needs guidance | Low | Low |
| Few-shot prompting | Need consistent output format; <100 examples | Low | Low |
| RAG | Domain knowledge is in documents/DB; changes frequently | Medium | Medium |
| Fine-tuning | Domain terminology is rare; output format is rigid; latency/cost at scale | High | High |
| Full pre-training | Entirely new domain with massive proprietary corpus | Very high | Very high |

**Fine-tune when:**
- The base model consistently fails on domain-specific SQL (e.g., Snowflake `FLATTEN`, `LATERAL`, `MATCH_RECOGNIZE` syntax)
- You need strict output formatting (JSON with required mortgage fields) without lengthy prompt instructions
- You're making >1M API calls/day and want to use a smaller, cheaper model that matches GPT-4 quality on your specific tasks
- You need the model to "know" your internal table/column naming conventions without always providing schema in-context

**Do NOT fine-tune when:**
- You can solve the problem with a better system prompt
- Your domain knowledge changes frequently (RAG is better — you can update documents without retraining)
- You have fewer than 500 high-quality examples
- You don't have GPU infrastructure or budget for training

---

## Full Fine-tuning vs. Parameter-Efficient Fine-tuning (PEFT)

**Full fine-tuning** updates all model weights. A 7B parameter model requires ~14GB GPU RAM just to store weights in float16, plus optimizer states and gradients — easily 80GB+. Impractical without a cluster of A100s.

**PEFT** freezes most model weights and trains only a small set of additional parameters — typically <1% of total parameters — while achieving 80-95% of full fine-tuning performance.

```
Full fine-tuning:  7B params × 2 bytes (fp16) = 14 GB weights
                   + 28 GB optimizer states (Adam: 2× weights)
                   + 14 GB gradients = ~56 GB minimum

LoRA fine-tuning:  14 GB frozen weights (no gradient needed)
                   + ~50 MB trainable LoRA parameters
                   + optimizer states for LoRA only ≈ 15-16 GB total
```

---

## LoRA — Low-Rank Adaptation

### How It Works

LoRA (Hu et al., 2021) inserts small trainable weight matrices into the attention layers of a transformer. For a weight matrix W of shape (d × k), instead of updating W directly, LoRA learns two low-rank matrices A (d × r) and B (r × k), where r << d. The effective weight update is:

```
W_new = W + (alpha/r) * B * A
```

Where:
- `r` = rank (typically 4, 8, 16, or 64) — controls capacity vs. efficiency
- `alpha` = scaling factor (often set equal to r)
- `A` is initialized with Gaussian noise, `B` is initialized to zero (so the initial LoRA contribution is zero)

Only A and B are trained. W stays frozen. At inference, B*A can be merged into W with no latency penalty.

### Key Parameters

| Parameter | Typical Values | Effect |
|---|---|---|
| `r` (rank) | 4, 8, 16, 32, 64 | Higher r = more capacity, more trainable params |
| `lora_alpha` | Equal to r or 2×r | Scaling; effective LR scales as alpha/r |
| `target_modules` | `q_proj, v_proj` or all attention | Which layers get LoRA adapters |
| `lora_dropout` | 0.05–0.1 | Regularization during training |
| `bias` | `"none"` or `"lora_only"` | Whether bias terms are trained |

### LoRA Fine-tuning with PEFT Library

```python
"""
LoRA fine-tuning of Mistral-7B for Snowflake SQL generation.
Target task: generate valid Snowflake SQL from natural language questions
about a secondary mortgage market database.
"""

import torch
from datasets import Dataset
from transformers import (
    AutoTokenizer,
    AutoModelForCausalLM,
    TrainingArguments,
    BitsAndBytesConfig,
)
from peft import (
    LoraConfig,
    get_peft_model,
    TaskType,
    prepare_model_for_kbit_training,
)
from trl import SFTTrainer

# ── Model and tokenizer ───────────────────────────────────────────────────────
MODEL_ID = "mistralai/Mistral-7B-Instruct-v0.3"

tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
tokenizer.pad_token = tokenizer.eos_token
tokenizer.padding_side = "right"

# QLoRA: load in 4-bit with bitsandbytes
bnb_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",          # Normal Float 4 — better than uniform quantization
    bnb_4bit_compute_dtype=torch.bfloat16,
    bnb_4bit_use_double_quant=True,     # Nested quantization saves ~0.4 bits/param
)

model = AutoModelForCausalLM.from_pretrained(
    MODEL_ID,
    quantization_config=bnb_config,
    device_map="auto",                  # Spread across available GPUs
    trust_remote_code=True,
)

# Prepare model for k-bit training (cast LayerNorm to fp32, etc.)
model = prepare_model_for_kbit_training(model)

# ── LoRA configuration ────────────────────────────────────────────────────────
lora_config = LoraConfig(
    task_type=TaskType.CAUSAL_LM,
    r=16,                               # Rank
    lora_alpha=32,                      # Scaling = alpha/r = 2.0
    target_modules=[                    # Apply to all attention projections
        "q_proj", "k_proj", "v_proj",
        "o_proj", "gate_proj",
        "up_proj", "down_proj",
    ],
    lora_dropout=0.05,
    bias="none",
    inference_mode=False,
)

model = get_peft_model(model, lora_config)
model.print_trainable_parameters()
# Output: trainable params: 41,943,040 || all params: 3,794,071,552 || trainable%: 1.1051

# ── Training data ─────────────────────────────────────────────────────────────
def format_instruction(example: dict) -> str:
    """Format as Mistral instruction template."""
    return (
        f"[INST] You are a Snowflake SQL expert for a secondary mortgage market database.\n"
        f"Schema: {example['schema']}\n\n"
        f"Generate a Snowflake SQL query for: {example['question']} [/INST]\n"
        f"{example['sql']}"
    )

# Sample training data (in production: 500-2000 high-quality pairs)
raw_data = [
    {
        "schema": "LOAN_MASTER(LOAN_ID, ORIG_DATE, NOTE_RATE, CURR_RATE, CURR_BALANCE, "
                  "LTV, CLTV, DTI, FICO, STATE, SERVICER_ID, DELINQUENCY_STATUS)",
        "question": "What is the weighted average note rate by state for loans originated in 2024?",
        "sql": (
            "SELECT STATE,\n"
            "       SUM(NOTE_RATE * CURR_BALANCE) / SUM(CURR_BALANCE) AS WAC\n"
            "FROM LOAN_MASTER\n"
            "WHERE YEAR(ORIG_DATE) = 2024\n"
            "GROUP BY STATE\n"
            "ORDER BY WAC DESC;"
        ),
    },
    {
        "schema": "LOAN_MASTER(LOAN_ID, ORIG_DATE, NOTE_RATE, CURR_BALANCE, LTV, DTI, FICO, "
                  "DELINQUENCY_STATUS, SERVICER_ID)",
        "question": "Find all loans 90+ days delinquent with FICO below 640 and LTV above 90",
        "sql": (
            "SELECT LOAN_ID, NOTE_RATE, CURR_BALANCE, LTV, DTI, FICO\n"
            "FROM LOAN_MASTER\n"
            "WHERE DELINQUENCY_STATUS >= 3\n"   # 3 = 90+ days
            "  AND FICO < 640\n"
            "  AND LTV > 90\n"
            "ORDER BY CURR_BALANCE DESC;"
        ),
    },
]

dataset = Dataset.from_list([{"text": format_instruction(ex)} for ex in raw_data])
dataset = dataset.train_test_split(test_size=0.1)

# ── Training ──────────────────────────────────────────────────────────────────
training_args = TrainingArguments(
    output_dir="./mortgage-sql-lora",
    num_train_epochs=3,
    per_device_train_batch_size=4,
    gradient_accumulation_steps=4,     # Effective batch = 16
    learning_rate=2e-4,
    lr_scheduler_type="cosine",
    warmup_ratio=0.05,
    fp16=False,
    bf16=True,                          # Use bfloat16 on Ampere+ GPUs
    logging_steps=25,
    save_strategy="epoch",
    evaluation_strategy="epoch",
    load_best_model_at_end=True,
    report_to="wandb",                  # or "tensorboard"
)

trainer = SFTTrainer(
    model=model,
    train_dataset=dataset["train"],
    eval_dataset=dataset["test"],
    peft_config=lora_config,
    dataset_text_field="text",
    max_seq_length=2048,
    tokenizer=tokenizer,
    args=training_args,
)

trainer.train()

# Save the LoRA adapter (small! ~80-200 MB vs 14 GB for full model)
trainer.model.save_pretrained("./mortgage-sql-lora-adapter")
tokenizer.save_pretrained("./mortgage-sql-lora-adapter")
```

### Loading and Merging LoRA Weights

```python
from peft import PeftModel
from transformers import AutoModelForCausalLM, AutoTokenizer

# Option 1: Load adapter on top of base model (slower inference, separate files)
base_model = AutoModelForCausalLM.from_pretrained(MODEL_ID, device_map="auto")
model = PeftModel.from_pretrained(base_model, "./mortgage-sql-lora-adapter")

# Option 2: Merge adapter into base weights (faster inference, single model file)
merged_model = model.merge_and_unload()
merged_model.save_pretrained("./mortgage-sql-merged")
```

---

## QLoRA — Quantized LoRA

QLoRA (Dettmers et al., 2023) combines 4-bit quantization of the base model with LoRA training. Key innovations:

1. **NF4 (Normal Float 4)**: 4-bit data type optimized for normally distributed weights — better than naive int4
2. **Double quantization**: Quantize the quantization constants themselves, saving ~0.37 bits per parameter
3. **Paged optimizers**: Use NVIDIA unified memory to page optimizer states to CPU RAM when GPU RAM is full, preventing OOM crashes during gradient spikes

**Memory savings:**

| Configuration | GPU RAM for 7B Model |
|---|---|
| Full fine-tuning (float32) | ~112 GB |
| Full fine-tuning (bfloat16) | ~56 GB |
| LoRA (bfloat16) | ~16 GB |
| QLoRA (NF4 + LoRA) | ~6 GB |

QLoRA enables fine-tuning a 7B model on a single consumer GPU (RTX 3090/4090 with 24GB VRAM).

---

## Other PEFT Methods

**Prefix Tuning**
Prepends trainable "virtual tokens" to the input/hidden states at every transformer layer. These prefix vectors are learned during training; the base model is frozen. Less parameter-efficient than LoRA for most tasks.

**Adapter Layers**
Inserts small bottleneck MLP layers inside each transformer block (between the attention and FFN sub-layers). Trains only these adapters. Slightly increases inference latency because adapters cannot be merged like LoRA weights.

**IA3 (Infused Adapter by Inhibiting and Amplifying Inner Activations)**
Multiplies activations by learned vectors (not matrices). Extremely parameter-efficient — even fewer params than LoRA. Works well for classification and NLU tasks but less proven for generation tasks like SQL.

---

## Instruction Fine-tuning vs. Domain Adaptation

| | Instruction Fine-tuning | Domain Adaptation |
|---|---|---|
| Goal | Teach the model to follow instructions | Teach the model domain knowledge/vocabulary |
| Data | (instruction, response) pairs | Domain text corpus (no labels needed) |
| Training objective | Next-token prediction on responses | Next-token prediction on all domain text |
| Example | (question, SQL) pairs for your schema | Fannie Mae guidelines, prospectus documents |
| Result | Better task performance | Better understanding of domain terms |

In practice, for mortgage SQL generation, you want both: domain adaptation on your internal docs + instruction fine-tuning on (question, SQL) pairs.

---

## RLHF and DPO

### RLHF (Reinforcement Learning from Human Feedback)

RLHF is how ChatGPT-style alignment is done. It involves three stages:
1. **SFT (Supervised Fine-tuning)**: Fine-tune on (prompt, good response) pairs
2. **Reward model training**: Train a separate model to score responses based on human preference labels (response A vs. response B)
3. **PPO (Proximal Policy Optimization)**: Fine-tune the SFT model using the reward model as the reward signal

RLHF is complex, unstable, and requires significant engineering. For most data engineering use cases, it's overkill.

### DPO (Direct Preference Optimization)

DPO (Rafailov et al., 2023) achieves similar alignment goals as RLHF but by directly optimizing on preference pairs without training a separate reward model. Given pairs of (prompt, chosen_response, rejected_response), DPO maximizes the likelihood of chosen over rejected.

```python
from trl import DPOTrainer, DPOConfig

# Preference dataset format
preference_data = [
    {
        "prompt": "Generate SQL for: average DTI by state",
        "chosen": "SELECT STATE, AVG(DTI) FROM LOAN_MASTER GROUP BY STATE;",
        "rejected": "SELECT * FROM LOAN_MASTER WHERE STATE IS NOT NULL;",  # Wrong
    }
]

dpo_config = DPOConfig(
    beta=0.1,               # Controls KL divergence penalty (higher = stay closer to base)
    learning_rate=5e-7,
    num_train_epochs=1,
    per_device_train_batch_size=2,
)

dpo_trainer = DPOTrainer(
    model=sft_model,
    ref_model=ref_model,    # Copy of SFT model, frozen
    args=dpo_config,
    train_dataset=preference_dataset,
    tokenizer=tokenizer,
)
dpo_trainer.train()
```

**DPO for SQL generation**: use DPO to penalize SQL that runs but returns wrong results, and reward SQL that returns the expected output. Build (prompt, correct_sql, wrong_sql) triplets from your evaluation dataset.

---

## Snowflake Cortex Fine-tuning

Snowflake Cortex (as of 2025) allows fine-tuning Mistral and other models directly on Snowflake data without moving data outside Snowflake — important for regulated mortgage data.

```sql
-- Step 1: Create training dataset as a Snowflake table
CREATE OR REPLACE TABLE MORTGAGE_DW.ML.SQL_FINETUNE_DATA AS
SELECT
    OBJECT_CONSTRUCT(
        'messages', ARRAY_CONSTRUCT(
            OBJECT_CONSTRUCT('role', 'system', 'content', 'You are a Snowflake SQL expert.'),
            OBJECT_CONSTRUCT('role', 'user', 'content', PROMPT),
            OBJECT_CONSTRUCT('role', 'assistant', 'content', SQL_RESPONSE)
        )
    ) AS training_record
FROM MORTGAGE_DW.ML.CURATED_SQL_PAIRS
WHERE QUALITY_SCORE >= 4;  -- Only use high-quality examples

-- Step 2: Submit fine-tuning job via Cortex
SELECT SNOWFLAKE.CORTEX.FINETUNE(
    'CREATE',
    'MORTGAGE_DW.ML.MORTGAGE_SQL_MODEL',    -- Output model name
    'mistral-7b',                            -- Base model
    'SELECT training_record FROM MORTGAGE_DW.ML.SQL_FINETUNE_DATA',
    {
        'validation_data': 'SELECT training_record FROM MORTGAGE_DW.ML.SQL_VALIDATION_DATA',
        'epochs': 3
    }
);

-- Step 3: Monitor training
SELECT SNOWFLAKE.CORTEX.FINETUNE('DESCRIBE', 'MORTGAGE_DW.ML.MORTGAGE_SQL_MODEL');

-- Step 4: Use the fine-tuned model
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'MORTGAGE_DW.ML.MORTGAGE_SQL_MODEL',
    'Generate SQL: What is the average CLTV for California loans originated in Q1 2025?'
) AS generated_sql;
```

**Advantages of Cortex fine-tuning**: data never leaves Snowflake (critical for MNPI-sensitive mortgage data), no GPU infrastructure to manage, built-in model versioning, integrates with existing Snowflake RBAC.

---

## Fine-tuning on Azure ML and AWS SageMaker

### Azure ML

```python
from azure.ai.ml import MLClient, command
from azure.ai.ml.entities import AmlCompute, Environment

# Define fine-tuning job
job = command(
    code="./src",
    command="python finetune_lora.py --model_id ${{inputs.model_id}} --data_path ${{inputs.data_path}}",
    inputs={"model_id": "mistralai/Mistral-7B-Instruct-v0.3", "data_path": "azureml:mortgage-sql-data:1"},
    compute="gpu-cluster-a100",
    environment="AzureML-ACPT-pytorch-2.2-cuda12.1@latest",
    instance_type="Standard_NC96ads_A100_v4",  # 4× A100 80GB
)
ml_client.jobs.create_or_update(job)
```

### AWS SageMaker with Hugging Face DLC

```python
import sagemaker
from sagemaker.huggingface import HuggingFace

huggingface_estimator = HuggingFace(
    entry_point="finetune_lora.py",
    source_dir="./src",
    instance_type="ml.p4d.24xlarge",    # 8× A100 40GB
    instance_count=1,
    role=sagemaker.get_execution_role(),
    transformers_version="4.37",
    pytorch_version="2.1",
    py_version="py310",
    hyperparameters={
        "model_id": "mistralai/Mistral-7B-Instruct-v0.3",
        "epochs": 3,
        "per_device_train_batch_size": 4,
        "lora_r": 16,
        "lora_alpha": 32,
    },
)
huggingface_estimator.fit({"training": "s3://my-bucket/mortgage-sql-data/"})
```

---

## Training Data Preparation

Quality matters far more than quantity for fine-tuning. For SQL generation:

```python
# Data quality checklist for mortgage SQL fine-tuning pairs

def validate_training_example(example: dict) -> dict:
    """Validate and score a (question, SQL) training pair."""
    issues = []

    # 1. SQL must be syntactically valid
    import sqlparse
    parsed = sqlparse.parse(example["sql"])
    if not parsed or not parsed[0].tokens:
        issues.append("Invalid SQL syntax")

    # 2. SQL must reference only real tables
    known_tables = {"LOAN_MASTER", "POOL_SUMMARY", "DELINQUENCY_HISTORY",
                    "SERVICER_MASTER", "PAYMENT_HISTORY"}
    sql_upper = example["sql"].upper()
    for table in ["FROM", "JOIN"]:
        # Basic extraction — in production use a proper SQL parser
        pass

    # 3. Question must be specific enough
    if len(example["question"].split()) < 5:
        issues.append("Question too vague")

    # 4. SQL must contain a WHERE or GROUP BY for aggregation questions
    if any(kw in example["question"].lower() for kw in ["average", "total", "count", "by"]):
        if "GROUP BY" not in sql_upper and "WHERE" not in sql_upper:
            issues.append("Missing GROUP BY or WHERE for aggregation question")

    return {"valid": len(issues) == 0, "issues": issues, **example}

# Recommended dataset sizes
# Task                          | Min Examples | Target Examples
# SQL generation (single table) | 200          | 500
# SQL generation (multi-table)  | 400          | 1000
# Domain QA                     | 300          | 800
# Structured output (JSON)      | 200          | 500
```

---

## Evaluating Fine-tuned Models

```python
from evaluate import load
import sqlparse

def evaluate_sql_model(model, tokenizer, test_dataset):
    results = {"execution_success": 0, "exact_match": 0, "bleu": 0}
    bleu = load("bleu")

    for example in test_dataset:
        # Generate SQL
        inputs = tokenizer(example["prompt"], return_tensors="pt").to(model.device)
        outputs = model.generate(**inputs, max_new_tokens=256, temperature=0)
        generated_sql = tokenizer.decode(outputs[0], skip_special_tokens=True)

        # Execution accuracy (most important metric)
        try:
            # In production: actually run against a test database
            parsed = sqlparse.parse(generated_sql)
            if parsed and str(parsed[0]).strip():
                results["execution_success"] += 1
        except Exception:
            pass

        # Exact match (strict)
        if generated_sql.strip().lower() == example["sql"].strip().lower():
            results["exact_match"] += 1

        # BLEU score (loose similarity)
        bleu_score = bleu.compute(
            predictions=[generated_sql], references=[[example["sql"]]]
        )
        results["bleu"] += bleu_score["bleu"]

    n = len(test_dataset)
    return {k: v / n for k, v in results.items()}
```

**Key metrics for domain-specific fine-tuning:**

| Metric | Description | Target |
|---|---|---|
| Execution accuracy | SQL runs without error | >95% |
| Answer accuracy | SQL returns correct result | >85% |
| Exact match | Identical to reference SQL | >40% (low bar — multiple valid SQLs exist) |
| BLEU-4 | N-gram overlap with reference | >0.55 |
| Domain term recall | Uses correct column/table names | >98% |

---

## Interview Q&A

**Q1: Explain LoRA and why it works for fine-tuning LLMs without full GPU cluster access.**

LoRA (Low-Rank Adaptation) works on the insight that weight updates during fine-tuning have low intrinsic rank — the delta W that makes a general model specialized can be well-approximated by a low-rank matrix. Instead of updating W directly, LoRA trains two small matrices A (d × r) and B (r × k) where r is typically 8-16, far smaller than the original dimensions. Only these matrices are trained; the base weights are frozen. For a 7B parameter Mistral model, LoRA reduces trainable parameters from 7 billion to about 40 million — a 175× reduction. Combined with QLoRA's 4-bit quantization of base weights, you can fine-tune on a single 24GB GPU. The adapters are also small (80-200 MB vs. 14 GB for the full model), making them easy to version and deploy.

**Q2: When would you recommend fine-tuning over RAG for a mortgage data use case?**

RAG is better when: knowledge is in documents that change frequently (guideline updates), you need source citations, or the domain knowledge can be expressed as text chunks. Fine-tuning is better when: (1) you need the model to generate correct Snowflake SQL using your specific table/column naming conventions without providing the full schema in every prompt — a fine-tuned model "knows" your schema, (2) you need consistent structured output (specific JSON format for loan characteristics) that's hard to enforce through prompting, (3) you're calling the model thousands of times per day and want to use a smaller, cheaper model (7B) that matches GPT-4 quality on your narrow task, saving 10-20× on API costs. For a secondary mortgage market shop, I'd often combine both: fine-tune for SQL generation, use RAG for guideline lookups.

**Q3: What is the difference between QLoRA and LoRA, and when would you use each?**

LoRA trains adapters on top of a full-precision (float16 or bfloat16) frozen base model. QLoRA trains adapters on top of a 4-bit quantized (NF4) base model, dramatically reducing memory. The catch: QLoRA is slightly slower to train (dequantization overhead) and can have marginally lower quality than LoRA in some benchmarks, though the gap is small for most tasks. Use LoRA when you have sufficient GPU RAM (>16 GB per 7B model) and want maximum training throughput. Use QLoRA when you're RAM-constrained — a 7B model with QLoRA fits in 6 GB of VRAM, enabling training on an RTX 3060 or in a cloud instance with a single T4 GPU.

**Q4: How do you choose the rank `r` for LoRA?**

Rank controls the capacity of the LoRA adapter — higher rank means more expressiveness but more parameters and risk of overfitting. General guidance: start with r=8 for simple tasks (classification, short-form generation), r=16 for medium complexity (SQL generation, summarization), r=64 for complex tasks (math reasoning, long-form generation). For mortgage SQL generation, r=16 is a solid starting point. I'd tune r via ablation: train with r=4, 8, 16, 32 and evaluate on the held-out test set. For our use case, I'd expect r=16 to be the sweet spot — SQL is syntactically rigid, so high capacity is less important than ensuring the model learns your schema naming conventions.

**Q5: What is the risk of catastrophic forgetting in fine-tuning, and how do PEFT methods mitigate it?**

Catastrophic forgetting occurs when fine-tuning on a narrow task degrades the model's general capabilities — the model "forgets" how to do things it could before. Full fine-tuning is most susceptible because all weights are updated. PEFT methods mitigate this by freezing base model weights; only the small adapters or prefix vectors are trained. The base model's general knowledge (reasoning, language understanding) is preserved. For a mortgage SQL model, this means the fine-tuned model still understands natural language nuance, can follow complex instructions, and handles edge cases — it just also knows your specific schema and SQL dialect.

**Q6: How would you structure a training dataset for fine-tuning a model on Snowflake SQL generation for a mortgage database?**

I'd aim for 500-1000 high-quality (question, SQL) pairs covering: (1) simple aggregations — AVG, SUM, COUNT with GROUP BY; (2) multi-table joins — loan + servicer + payment history; (3) time-series queries — year-over-year comparisons, rolling windows; (4) Snowflake-specific syntax — FLATTEN for semi-structured, QUALIFY with window functions, MATCH_RECOGNIZE for pattern detection; (5) edge cases — null handling, date arithmetic, percentage calculations; and (6) domain-specific metrics — WAC, WAM, CPR computation. Data quality checklist: SQL must execute successfully against a test database, returns the correct answer for the question, uses the actual column names from your schema (not approximations), and follows your team's SQL style guide. I'd have a senior analyst review and validate every example before using it for training.

**Q7: Explain RLHF and why DPO is often a more practical alternative for enterprise use cases.**

RLHF requires three separate training stages: supervised fine-tuning, training a reward model on human preference data, then PPO reinforcement learning using the reward model as a signal. PPO is notoriously unstable — it requires careful hyperparameter tuning, the reward model can be gamed by the policy model (reward hacking), and the whole pipeline needs significant engineering to run reliably. DPO simplifies this to a single training stage: given (prompt, preferred_response, rejected_response) triplets, it directly maximizes the log-ratio of the policy's probability of preferred vs. rejected responses, with a KL divergence penalty to prevent mode collapse. For enterprise use cases like SQL generation, DPO is practical: collect pairs where one SQL answer is correct and one is wrong, and train with TRL's DPOTrainer. You get alignment-like behavior without the reward model engineering overhead.

**Q8: How would you evaluate whether a fine-tuned SQL model is better than GPT-4 with a detailed system prompt?**

I'd run a structured evaluation on a held-out test set of 200 (question, correct_answer) pairs: (1) Execution accuracy — does the generated SQL run without syntax errors? (2) Functional correctness — does the SQL return the right answer? I'd run both the fine-tuned model's SQL and the ground-truth SQL against a test Snowflake database and compare results. (3) Latency — the fine-tuned 7B model should be 5-10× faster than GPT-4. (4) Cost per query — 7B hosted on a single A10 GPU is roughly 50× cheaper than GPT-4 API calls at scale. (5) Schema adherence — does the model use the correct column names without schema in the prompt? If the fine-tuned model achieves >90% functional correctness vs. GPT-4's baseline with a full schema prompt, I'd consider deploying it for production query volume.

**Q9: What is Snowflake Cortex fine-tuning and what are its advantages for regulated financial data?**

Snowflake Cortex fine-tuning (GA in 2025) allows you to fine-tune Mistral models directly within your Snowflake account using SQL commands. The training data is a Snowflake table; the resulting model is stored in your Snowflake account and invoked via `SNOWFLAKE.CORTEX.COMPLETE()`. For a secondary mortgage market firm, the key advantages are: (1) Data residency — loan data, borrower PII, and MNPI-sensitive pool data never leave your Snowflake environment, satisfying data governance requirements; (2) No MLOps overhead — no GPU cluster to provision, no Docker containers, no model serving infrastructure; (3) Snowflake RBAC controls model access — the same role-based permissions that govern table access apply to model invocation; (4) Native integration — the fine-tuned model can be called inline in SQL queries alongside your existing Snowflake transformations.

**Q10: What training data volume and quality thresholds have you seen work in practice for fine-tuning SQL generation models?**

In practice: below 200 examples, fine-tuning often does not outperform a well-engineered few-shot prompt. Between 200-500 high-quality examples, you get meaningful improvement on in-distribution queries. Beyond 1000 examples, returns diminish unless you are significantly expanding the task diversity. Quality matters more than quantity — 300 examples where every SQL has been validated by execution against a real database beats 3000 examples scraped from Stack Overflow. For mortgage SQL specifically, I'd prioritize: examples with your exact column names (not generic aliases), examples covering Snowflake-specific syntax that base models underperform on (QUALIFY, FLATTEN, PIVOT), and negative examples for DPO that represent common failure modes (wrong join keys, missing WHERE clauses). I'd also implement data augmentation: take each gold SQL and paraphrase the question 3-5 different ways to increase diversity without additional SQL-writing effort.

---

## Pro Tips

- Always validate generated SQL by actually running it against a test Snowflake database before including it in your training set. A training example with wrong SQL teaches the model to be wrong.
- Set `lora_alpha = 2 * r` as a starting point. This keeps the effective learning rate stable relative to rank.
- Target modules matter: adding LoRA to all projection matrices (`q_proj`, `k_proj`, `v_proj`, `o_proj`, `gate_proj`, `up_proj`, `down_proj`) consistently outperforms targeting only `q_proj` and `v_proj` for generation tasks.
- Use `gradient_checkpointing=True` during QLoRA training to reduce GPU memory at the cost of ~30% slower training. Essential when batch size > 1.
- For Snowflake Cortex fine-tuning, keep your training examples in a dedicated schema with Snowflake Data Classification tags (`SENSITIVE`, `RESTRICTED`) to ensure proper access control before initiating the fine-tuning job.
- Always track training runs with Weights & Biases or MLflow. Fine-tuning decisions (rank, learning rate, epochs) made without loss curves are guesswork.
- After merging LoRA weights, quantize the merged model with GGUF/llama.cpp for CPU inference deployment, or GPTQ/AWQ for GPU inference. A merged 7B model in Q4_K_M GGUF runs at ~25 tokens/second on a single A10 GPU.
