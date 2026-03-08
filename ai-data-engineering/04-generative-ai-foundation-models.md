# Generative AI & Foundation Models

[Back to Index](README.md)

---

## Overview

Foundation models are large neural networks pre-trained on massive datasets — billions of documents, images, and code repositories — that develop general-purpose representations transferable to many downstream tasks. For data engineers, they are no longer a "nice to have": they power SQL generation, schema inference, data quality summarization, and ETL code scaffolding inside the platforms you already run (Snowflake Cortex, Azure OpenAI, BigQuery ML).

This module covers what foundation models are, which ones matter for the enterprise data stack, and how to integrate them into data pipelines using code you can run today.

---

## Key Concepts

| Term | Definition |
|---|---|
| Foundation model | A large pre-trained model adapted for many tasks via fine-tuning or prompting |
| Parameters | Learnable weights; a proxy for model capacity (7B, 70B, 405B, etc.) |
| Inference | Running a trained model to produce output — the only operation data engineers usually perform |
| Token | The unit of text a model processes; roughly 0.75 words in English |
| Context window | Maximum tokens the model can process in one call |
| RAG | Retrieval-Augmented Generation — grounding model output with live data |
| VRAM | GPU memory required to load a model for inference |
| Quantization | Reducing weight precision (FP16 → INT4) to fit models on less VRAM |

---

## Foundation Model Families

### Closed / API-only Models

| Model Family | Provider | Key Strengths for Data Engineering |
|---|---|---|
| GPT-4o, GPT-4 Turbo | OpenAI / Azure OpenAI | SQL generation, code, function calling |
| Claude 3.5 Sonnet, Claude 3 Opus | Anthropic | Long-context doc analysis, precise instructions |
| Gemini 1.5 Pro | Google DeepMind | 1M token context; useful for large schema analysis |
| Mistral Large | Mistral AI | Competitive coding quality, EU data residency |

### Open-Weight Models (Self-Hostable)

| Model | Parameters | VRAM (FP16) | Notes |
|---|---|---|---|
| Llama 3.1 8B | 8B | ~16 GB | Fast, cheap inference; good for classification |
| Llama 3.1 70B | 70B | ~140 GB | Near-GPT-4 on coding benchmarks |
| Llama 3.1 405B | 405B | ~810 GB | Requires multi-GPU cluster |
| Mistral 7B / Mixtral 8x7B | 7B / 46.7B active | ~14 GB / ~90 GB | MoE architecture; efficient for throughput |
| Code Llama 34B | 34B | ~68 GB | Specialized for SQL/Python code generation |

**VRAM quick rule:** FP16 requires ~2 bytes per parameter. INT4 quantization cuts that by ~4x. A 7B model at INT4 fits on a single 8 GB consumer GPU.

---

## Model Capabilities Relevant to Data Engineering

### SQL Generation
Models can translate natural language business questions into syntactically correct SQL, including complex window functions, CTEs, and dialect-specific syntax (T-SQL vs. Snowflake SQL vs. BigQuery SQL).

### Schema Inference
Given sample data (CSV headers, JSON blobs, API responses), models can infer column names, data types, nullability, and relationships — accelerating the metadata capture step of data onboarding.

### Data Summarization
Models can summarize the contents of a result set, explain anomalies, or generate data quality reports in natural language — useful for automated pipeline alerting.

### Code Generation
Scaffold dbt models, Airflow DAGs, PySpark jobs, and Snowflake Procedures from a plain-English description of the transformation logic.

---

## Snowflake Cortex LLM Functions

Snowflake Cortex exposes hosted foundation models as SQL functions — no external API keys, no data leaving your Snowflake account.

### Available Functions

| Function | Purpose | Example Input |
|---|---|---|
| `SNOWFLAKE.CORTEX.COMPLETE` | General text generation / SQL gen | System + user prompt |
| `SNOWFLAKE.CORTEX.SENTIMENT` | Returns score -1.0 to 1.0 | Customer review text |
| `SNOWFLAKE.CORTEX.SUMMARIZE` | Abstractive summary | Long document |
| `SNOWFLAKE.CORTEX.TRANSLATE` | Language translation | Text + target language code |
| `SNOWFLAKE.CORTEX.EXTRACT_ANSWER` | QA over a passage | Question + context text |

### Cortex Code Examples

```sql
-- Summarize customer feedback stored in a Snowflake table
SELECT
    review_id,
    customer_id,
    review_text,
    SNOWFLAKE.CORTEX.SUMMARIZE(review_text)          AS summary,
    SNOWFLAKE.CORTEX.SENTIMENT(review_text)          AS sentiment_score,
    SNOWFLAKE.CORTEX.TRANSLATE(review_text, 'es')    AS review_spanish
FROM raw.customer_reviews
WHERE review_date >= CURRENT_DATE - 30;
```

```sql
-- Extract structured answers from unstructured support tickets
SELECT
    ticket_id,
    ticket_body,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        ticket_body,
        'What product is the customer asking about?'
    ) AS product_mentioned,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        ticket_body,
        'What is the severity of the issue?'
    ) AS severity
FROM raw.support_tickets;
```

```sql
-- Use COMPLETE with a prompt template for SQL generation helper
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'mistral-large',
    CONCAT(
        'You are a Snowflake SQL expert. Generate a valid Snowflake SQL query. ',
        'Schema: orders(order_id INT, customer_id INT, amount DECIMAL, order_date DATE). ',
        'Question: ', :user_question
    )
) AS generated_sql;
```

```sql
-- Batch classify product descriptions using COMPLETE
SELECT
    product_id,
    product_description,
    PARSE_JSON(
        SNOWFLAKE.CORTEX.COMPLETE(
            'llama3-8b',
            CONCAT(
                'Classify this product description into one of: Electronics, Clothing, Food, Other. ',
                'Return JSON: {"category": "<value>", "confidence": <0-1>}. ',
                'Description: ', product_description
            )
        )
    ) AS classification
FROM products.catalog;
```

---

## Azure OpenAI Service for Enterprise Data

Azure OpenAI gives you GPT-4 / GPT-4o models with private networking, managed identity auth, content filtering, and data residency controls — critical requirements for regulated industries.

### Python Integration with Azure OpenAI

```python
import os
from openai import AzureOpenAI
import pandas as pd
import json

# Initialize client using managed identity or environment variables
client = AzureOpenAI(
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
    api_key=os.environ["AZURE_OPENAI_API_KEY"],
    api_version="2024-02-01"
)

DEPLOYMENT_NAME = "gpt-4o"  # your Azure deployment name

# ── Prompt template for SQL generation ───────────────────────────────────────
def generate_sql(schema: str, question: str) -> str:
    """Generate T-SQL from a natural language question and schema description."""
    system_prompt = """You are a senior SQL Server developer.
Generate valid T-SQL queries only.
Always use CTEs for complex logic.
Never use SELECT *."""

    user_prompt = f"""Schema:
{schema}

Question: {question}

Provide only the SQL query, no explanation."""

    response = client.chat.completions.create(
        model=DEPLOYMENT_NAME,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user",   "content": user_prompt}
        ],
        temperature=0.1,   # low temperature for deterministic SQL
        max_tokens=1000
    )
    return response.choices[0].message.content

# ── Summarize a Pandas DataFrame ─────────────────────────────────────────────
def summarize_dataframe(df: pd.DataFrame, context: str) -> str:
    """Generate a natural language summary of query results."""
    sample = df.head(20).to_markdown(index=False)
    stats  = df.describe().to_markdown()

    prompt = f"""Context: {context}

Sample data (first 20 rows):
{sample}

Statistics:
{stats}

Provide a concise 3-sentence business summary of this data, highlighting anomalies."""

    response = client.chat.completions.create(
        model=DEPLOYMENT_NAME,
        messages=[{"role": "user", "content": prompt}],
        temperature=0.3,
        max_tokens=300
    )
    return response.choices[0].message.content

# ── Schema inference from CSV headers + sample rows ──────────────────────────
def infer_schema(csv_sample: str, table_name: str) -> dict:
    """Infer DDL from a CSV sample."""
    prompt = f"""Given this CSV data sample for table '{table_name}':

{csv_sample}

Return a JSON object with this structure:
{{
  "columns": [
    {{"name": "col_name", "sql_type": "NVARCHAR(255)", "nullable": true, "notes": "..."}}
  ],
  "suggested_primary_key": "col_name",
  "potential_foreign_keys": []
}}"""

    response = client.chat.completions.create(
        model=DEPLOYMENT_NAME,
        messages=[{"role": "user", "content": prompt}],
        temperature=0,
        max_tokens=800,
        response_format={"type": "json_object"}
    )
    return json.loads(response.choices[0].message.content)


# ── Usage example ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    schema = """
    dbo.loans (
        loan_id         INT PRIMARY KEY,
        customer_id     INT NOT NULL,
        origination_date DATE NOT NULL,
        original_balance DECIMAL(18,2),
        current_balance  DECIMAL(18,2),
        rate             DECIMAL(6,4),
        status           VARCHAR(20)  -- ACTIVE, PAID_OFF, DEFAULT, PREPAID
    )
    """
    question = "Show the monthly prepayment rate for the last 12 months"
    sql = generate_sql(schema, question)
    print(sql)
```

---

## Cost Comparison Across Providers (March 2026)

| Provider | Model | Input ($/1M tokens) | Output ($/1M tokens) | Context Window |
|---|---|---|---|---|
| OpenAI | GPT-4o | $2.50 | $10.00 | 128K |
| OpenAI | GPT-4o mini | $0.15 | $0.60 | 128K |
| Anthropic | Claude 3.5 Sonnet | $3.00 | $15.00 | 200K |
| Anthropic | Claude 3 Haiku | $0.25 | $1.25 | 200K |
| Google | Gemini 1.5 Pro | $1.25 | $5.00 | 1M |
| Google | Gemini 1.5 Flash | $0.075 | $0.30 | 1M |
| Azure OpenAI | GPT-4o (PTU) | Flat hourly | Flat hourly | 128K |
| Self-hosted | Llama 3.1 8B | Compute only | Compute only | 128K |

**Data engineering cost guidance:** For batch jobs processing millions of rows, use small/fast models (GPT-4o mini, Gemini Flash, Llama 8B). Reserve large models for interactive SQL generation or high-stakes schema design. One million tokens is roughly 750,000 words — a substantial ETL workload.

---

## Prompt Templates for Data Engineering Tasks

### ETL Documentation Generator
```
You are a data engineering documentation writer.
Given a SQL transformation query, generate:
1. A one-sentence description
2. Source tables and columns consumed
3. Business rules applied
4. Output columns and their derivation logic

Query:
{sql_query}
```

### Data Quality Rule Generator
```
You are a data quality engineer.
Given a table schema, generate 5 Great Expectations validation rules
in Python (ExpectationSuite format) covering nullability, range checks,
and referential integrity.

Schema: {schema}
Sample failing rows: {sample_rows}
```

### dbt Model Scaffold
```
Generate a dbt SQL model for Snowflake that:
- Reads from {{ ref('stg_orders') }} and {{ ref('stg_customers') }}
- Joins on customer_id
- Calculates lifetime value as sum of amount
- Adds a data quality flag column

Follow dbt best practices: use CTEs, add column-level comments.
```

---

## Interview Q&A

### Q1: What is a foundation model and why does it matter to a data engineer?

**Answer:** A foundation model is a large neural network trained on a broad corpus of data (text, code, structured data) using self-supervised learning. The key insight is that a single training run produces a model capable of many tasks through prompting or lightweight fine-tuning, rather than training a separate model per task.

For data engineers, this matters because: (1) SQL generation capabilities can accelerate ad-hoc query development for analysts; (2) schema inference from unstructured sources (PDFs, emails, JSON) becomes feasible without custom NLP pipelines; (3) platforms like Snowflake Cortex package these capabilities as SQL functions, so you use them without leaving your existing data stack; (4) they enable natural language interfaces for business users to query data warehouses, reducing the query-writing burden on data teams.

### Q2: How do you choose between Snowflake Cortex and Azure OpenAI for an enterprise data pipeline?

**Answer:** The decision hinges on data residency, cost model, and integration complexity.

Snowflake Cortex: data never leaves your Snowflake account, billing is in Snowflake credits (no separate API contract), functions are called in SQL (zero new infrastructure), latency is higher than direct API calls. Best for: batch enrichment jobs on data already in Snowflake, governed BI/analytics use cases, organizations on the Snowflake Enterprise tier.

Azure OpenAI: faster inference, private VNet integration, managed identity auth, content filtering policies, PTU (provisioned throughput) for predictable latency. Best for: real-time applications, organizations already standardized on Azure, pipelines outside Snowflake (ADF, Databricks, Azure Functions).

For a regulated financial institution, I would use Snowflake Cortex for anything touching PII already in Snowflake, and Azure OpenAI with private endpoints for application-layer features that need sub-500ms response times.

### Q3: What is the difference between open-weight and closed models, and what are the data engineering tradeoffs?

**Answer:** Open-weight models (Llama 3, Mistral, Mixtral) release their weights publicly — you can download, fine-tune, and self-host them. Closed models (GPT-4, Claude) are accessible only through APIs; you never control the weights.

Tradeoffs for data engineers:

| Dimension | Open-weight | Closed |
|---|---|---|
| Data privacy | Full control — data stays on-premises | Data sent to provider API |
| Cost at scale | Fixed infrastructure cost | Variable per-token cost |
| Latency | Depends on your hardware | Provider-managed, predictable |
| Quality ceiling | Slightly below frontier | State of the art |
| Maintenance burden | You own upgrades and ops | Zero ops |
| Fine-tuning | Fully supported | Limited (OpenAI fine-tune API) |

For a bank with strict data residency requirements, running Llama 3.1 70B on dedicated GPU instances is often the only compliant path for customer data enrichment pipelines.

### Q4: Explain tokens and context windows. Why do they matter when designing data pipelines that call LLMs?

**Answer:** A token is the smallest unit a language model processes — approximately 0.75 English words or 4 characters. Context window is the maximum number of tokens the model can process in a single call (input + output combined).

For data pipeline design this matters in three ways:

1. **Chunking strategy:** If you are summarizing a large SQL query result (10,000 rows), the full result likely exceeds the context window. You must chunk the data, summarize each chunk, then summarize the summaries (map-reduce pattern).

2. **Cost control:** Input tokens drive the majority of API cost. Sending full table contents instead of aggregated samples is an expensive anti-pattern. Always pre-aggregate in SQL before sending to the model.

3. **Batching efficiency:** For batch enrichment (classifying 1M product descriptions), structure prompts to maximize token density per API call. Using `COMPLETE` in Snowflake Cortex in a single `SELECT` statement sends one row per call by default — consider batching rows into a single prompt for throughput.

### Q5: How do you prevent sensitive data (PII, financial data) from being sent to external LLM APIs?

**Answer:** A layered approach:

1. **Architecture-first:** Prefer Snowflake Cortex or Azure OpenAI with private endpoints so data never traverses the public internet.
2. **Data masking before API calls:** Use Snowflake dynamic data masking or a pre-processing step to replace PII fields (SSN, account numbers) with synthetic tokens before passing text to the model. Store the mapping in a secure vault.
3. **Column-level policies:** In Snowflake, use row access policies and column masking policies so that only de-identified columns are accessible to the data pipeline service account calling Cortex.
4. **LLM gateway/proxy:** Route all API traffic through a centralized proxy (e.g., Azure API Management) that enforces data classification rules, strips or masks sensitive patterns (regex on SSN, credit card formats) before forwarding to the model.
5. **Audit logging:** Log every prompt and response with the pipeline job ID, user, and data classification level. This enables forensics if a data leak is suspected.

### Q6: What is RAG (Retrieval-Augmented Generation) and when would a data engineer build a RAG pipeline?

**Answer:** RAG is a pattern where you retrieve relevant documents from a knowledge base at query time and inject them into the model's prompt, rather than relying solely on the model's trained knowledge. The model then answers based on the retrieved context.

A data engineer would build a RAG pipeline when:
- Users need to query internal documentation (data dictionaries, SLAs, business rules) that was not part of the model's training data
- Answers must cite specific, up-to-date facts (current inventory levels, latest regulatory filings)
- Hallucination risk is unacceptable and grounding in retrieved text reduces it

Architecture: source documents → chunk and embed → store in vector database (Pinecone, Weaviate, pgvector, Snowflake's VECTOR type) → at query time, embed the question, retrieve top-k similar chunks → inject chunks + question into model prompt → return grounded answer.

For a data engineering team, a common RAG use case is a natural language interface to the data catalog: users ask "what does the `prepayment_flag` column mean?" and the system retrieves the relevant data dictionary entry to ground the LLM's answer.

### Q7: How do you evaluate the quality of LLM-generated SQL in a production pipeline?

**Answer:** A production SQL generation pipeline needs automated evaluation at multiple levels:

1. **Syntax validation:** Parse the generated SQL with `sqlglot` or execute against a read-only sandbox database. Reject and retry if parse errors occur.
2. **Schema grounding check:** Extract table and column references from the generated SQL; verify each exists in the information schema. A column hallucination is a silent bug.
3. **Result spot-check:** Run the query on a sample period; compare row count and aggregated totals against a known-good reference query. Alert if variance exceeds a threshold.
4. **Semantic evaluation (offline):** Build a golden set of (question, expected SQL) pairs. Track exact-match accuracy and execution-match accuracy (different SQL, same result) across model versions.
5. **Human-in-the-loop for high stakes:** For queries that will drive financial reporting, require analyst approval before the generated SQL is promoted to production.

### Q8: Compare the cost and latency tradeoffs of batch vs. real-time LLM inference in a data pipeline.

**Answer:**

| Dimension | Batch | Real-time |
|---|---|---|
| Latency | Minutes to hours | Milliseconds to seconds |
| Throughput | Very high (parallelizable) | Limited by API rate limits |
| Cost | Can use cheaper/slower models | May need fastest model for UX |
| Failure handling | Retry at row level, continue job | Must return error quickly |
| Use cases | Enrichment, classification, summarization | SQL generation for analysts, chatbots |

For batch, I would use Snowflake Cortex `COMPLETE` in a `CREATE TABLE AS SELECT` statement — it parallelizes across Snowflake's compute and bills at credit cost with no external API keys. For real-time, Azure OpenAI with PTU (provisioned throughput) gives sub-300ms p99 latency with predictable billing.

The key design decision: if results do not need to be returned interactively, always choose batch. Processing 1 million classification calls in an overnight batch job costs a fraction of real-time equivalent throughput.

### Q9: What Snowflake Cortex models are available, and how do you select the right one?

**Answer:** As of early 2026, Snowflake Cortex exposes hosted versions of: `mistral-large`, `llama3-8b`, `llama3-70b`, `llama3.1-8b`, `llama3.1-70b`, `mixtral-8x7b`, `reka-flash`, and `arctic` (Snowflake's own model). Availability varies by Snowflake region.

Selection criteria:
- **Highest quality needed (complex SQL gen, reasoning):** `mistral-large` or `llama3-70b`
- **Bulk enrichment at low cost:** `llama3-8b` — fast and cheap in Snowflake credits
- **Structured extraction / classification:** `mixtral-8x7b` gives good instruction-following at moderate cost
- **Snowflake-optimized tasks:** `arctic` is tuned for enterprise SQL and data tasks

Always benchmark on your specific task with a 100-row sample before committing to a model for production batch jobs. Snowflake credits per 1M tokens vary significantly across models.

### Q10: How would you build a pipeline that uses an LLM to auto-generate dbt model documentation?

**Answer:** Here is a practical architecture for a senior data engineering team:

1. **Extraction:** Query `information_schema.columns` and the dbt manifest JSON to collect table names, column names, types, and any existing descriptions.
2. **Enrichment context:** Pull 10-row sample data and column statistics (min, max, null %, distinct count) from Snowflake.
3. **Prompt construction:** Build a structured prompt: "Given these columns and sample data, generate a dbt schema.yml description for each column that explains its business meaning. Be concise (under 20 words per column)."
4. **API call:** Use Azure OpenAI or Snowflake Cortex; output JSON with column name → description mapping.
5. **Write-back:** Parse the JSON response and update the `schema.yml` files in the dbt project using Python file I/O or the dbt Cloud API.
6. **PR creation:** Open a GitHub pull request with the generated documentation for a data engineer to review before merging.
7. **Evaluation loop:** Track a human-approval rate metric over time. If the approval rate drops (model started hallucinating business terms), trigger a prompt revision.

This pipeline can generate first-draft documentation for hundreds of dbt models in an hour, dramatically reducing documentation debt.

---

## Pro Tips

- **Temperature = 0 for SQL, higher for summaries.** SQL generation needs determinism; creative summaries benefit from slight variation. Set `temperature=0.0` to `0.1` for code generation tasks.
- **Always include the SQL dialect in your prompt.** "Generate valid Snowflake SQL" produces far fewer errors than "generate SQL." Models know the difference between T-SQL, BigQuery SQL, and Snowflake SQL syntax.
- **Version your prompt templates like code.** Store prompts in your dbt project or a dedicated `prompts/` directory in your data engineering repo. Track changes in Git. A prompt change is a pipeline change.
- **Use JSON mode or structured output.** When calling OpenAI or Azure OpenAI, use `response_format={"type": "json_object"}` to guarantee parseable output. Parsing free-text responses in production is fragile.
- **Set token budgets.** Always set `max_tokens` to prevent runaway responses driving up cost. For SQL generation, 800 tokens is sufficient for most queries. For summarization, 200-400 is usually enough.
- **Monitor Cortex costs in Snowflake.** Query `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` filtered on `SERVICE_TYPE = 'AI_SERVICES'` to track Cortex credit consumption by warehouse and query tag.
- **Test on adversarial inputs.** Pass ambiguous questions, misspelled column names, and questions referencing non-existent tables into your SQL generation pipeline to find failure modes before analysts do.
