# OpenAI API & ChatGPT Integration for Data Engineers

[← Back to Index](README.md)

---

## Overview

The OpenAI API gives data engineers programmatic access to GPT-4o, embeddings, function calling, and batch processing — capabilities that can automate SQL generation, document extraction, pipeline code creation, and semantic search across mortgage data assets. Unlike a chat interface, the API is a structured HTTP service with deterministic authentication, rate limits, token budgets, and explicit model versioning. Treating it like any other external API — with retry logic, cost monitoring, schema validation, and audit logging — is what separates production-grade integrations from proof-of-concept scripts.

This guide covers the full OpenAI API surface area relevant to a senior data engineer working with SQL Server, Snowflake, and mortgage/MBS data pipelines.

---

## Key Concepts

| Concept | Description |
|---|---|
| Chat Completions API | Core endpoint for conversational and generative tasks |
| Messages array | The conversation history sent with each request: system/user/assistant roles |
| GPT-4o | Fastest, most capable omni model; supports vision, JSON mode |
| GPT-4-turbo | High-capability model with 128K context window |
| Embeddings API | Converts text to dense vectors for semantic search and similarity |
| Function calling | Structured mechanism for the model to invoke tools with typed JSON |
| Batch API | Asynchronous processing of large request volumes at 50% cost |
| Streaming | Server-sent events for real-time token delivery |
| Assistants API | Stateful agent framework with persistent threads and file search |
| Azure OpenAI | Enterprise-hosted OpenAI models with VNet isolation and compliance |

---

## Model Comparison

| Model | Context | Strengths | Best Use Case | Relative Cost |
|---|---|---|---|---|
| gpt-4o | 128K | Speed + vision + JSON mode | SQL gen, doc extraction, default choice | Medium |
| gpt-4o-mini | 128K | Cheapest capable model | High-volume classification, simple transforms | Low |
| gpt-4-turbo | 128K | Deep reasoning | Complex multi-step pipeline logic | High |
| gpt-3.5-turbo | 16K | Legacy, fast | Simple lookups, not recommended for new work | Very Low |
| text-embedding-3-large | — | Best embedding quality | Semantic search over large corpora | Medium |
| text-embedding-3-small | — | Cost-efficient embeddings | High-volume embedding pipelines | Low |

---

## Detailed Explanations with Examples

### Chat Completions API: Messages Array

Every call to the Chat Completions API sends the full conversation history. Understanding the three roles is fundamental:

```python
import openai

client = openai.OpenAI()  # Reads OPENAI_API_KEY from environment

response = client.chat.completions.create(
    model="gpt-4o",
    messages=[
        {
            "role": "system",
            "content": "You are a SQL expert for a Snowflake mortgage data warehouse."
        },
        {
            "role": "user",
            "content": "Write a query to compute the weighted average coupon (WAC) for each pool."
        }
    ],
    temperature=0,
    max_tokens=1024
)

sql = response.choices[0].message.content
print(sql)

# Access usage metrics
print(f"Prompt tokens:     {response.usage.prompt_tokens}")
print(f"Completion tokens: {response.usage.completion_tokens}")
print(f"Total tokens:      {response.usage.total_tokens}")
```

### Embeddings API for Semantic Search

Embeddings enable semantic similarity search across data dictionaries, business glossaries, and loan documents:

```python
import openai
import numpy as np
from typing import List

client = openai.OpenAI()

def embed_texts(texts: List[str], model: str = "text-embedding-3-small") -> List[List[float]]:
    """Embed a list of texts. Respects the 8191 token limit per text."""
    response = client.embeddings.create(
        input=texts,
        model=model
    )
    return [item.embedding for item in response.data]

def cosine_similarity(a: List[float], b: List[float]) -> float:
    a, b = np.array(a), np.array(b)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))

# Build a searchable index of column descriptions
column_descriptions = [
    "CURR_UPB: Current unpaid principal balance of the loan in dollars",
    "NOTE_RATE: The contractual interest rate on the promissory note",
    "POOL_FACTOR: Remaining principal as a decimal fraction of original balance",
    "ORIG_FICO: Borrower credit score at origination",
    "LTV_ORIG: Loan-to-value ratio at origination",
    "DTI_BACK: Back-end debt-to-income ratio at underwriting",
]

column_vectors = embed_texts(column_descriptions)

# Semantic search
query = "what is the borrower's creditworthiness score?"
query_vector = embed_texts([query])[0]

scores = [(desc, cosine_similarity(query_vector, vec))
          for desc, vec in zip(column_descriptions, column_vectors)]
scores.sort(key=lambda x: x[1], reverse=True)
print("Top match:", scores[0][0])  # ORIG_FICO: Borrower credit score at origination
```

### Function Calling / Tool Use

Function calling is how you get the model to return structured, typed data rather than prose:

```python
import json
import openai

client = openai.OpenAI()

tools = [
    {
        "type": "function",
        "function": {
            "name": "query_loan_database",
            "description": "Execute a read-only SQL query against the mortgage data warehouse",
            "parameters": {
                "type": "object",
                "properties": {
                    "sql": {
                        "type": "string",
                        "description": "The SELECT SQL query to execute"
                    },
                    "description": {
                        "type": "string",
                        "description": "Plain-English description of what this query retrieves"
                    }
                },
                "required": ["sql", "description"]
            }
        }
    }
]

def run_agent_turn(user_question: str):
    messages = [
        {"role": "system", "content": "You answer questions about mortgage data by writing SQL queries."},
        {"role": "user",   "content": user_question}
    ]

    response = client.chat.completions.create(
        model="gpt-4o",
        messages=messages,
        tools=tools,
        tool_choice="auto",
        temperature=0
    )

    msg = response.choices[0].message
    if msg.tool_calls:
        for call in msg.tool_calls:
            args = json.loads(call.function.arguments)
            print("Generated SQL:")
            print(args["sql"])
            print("Purpose:", args["description"])

run_agent_turn("How many loans are more than 90 days delinquent in pool FNMA-2024-0091?")
```

### Batch API for Large-Scale Processing

The Batch API processes up to 50,000 requests asynchronously at 50% cost — essential for month-end MBS analytics:

```python
import json
import openai

client = openai.OpenAI()

def create_batch_job(loan_records: list[dict]) -> str:
    """Submit a batch of loan narrative generation requests."""
    requests = []
    for i, loan in enumerate(loan_records):
        requests.append({
            "custom_id": f"loan-{loan['loan_id']}",
            "method": "POST",
            "url": "/v1/chat/completions",
            "body": {
                "model": "gpt-4o-mini",
                "messages": [
                    {
                        "role": "system",
                        "content": "Generate a one-sentence risk summary for this mortgage loan."
                    },
                    {
                        "role": "user",
                        "content": (
                            f"Loan ID: {loan['loan_id']}, "
                            f"FICO: {loan['fico']}, "
                            f"LTV: {loan['ltv']:.1%}, "
                            f"DTI: {loan['dti']:.1%}, "
                            f"Status: {loan['status']}"
                        )
                    }
                ],
                "temperature": 0,
                "max_tokens": 100
            }
        })

    # Write JSONL file
    batch_file = "/tmp/loan_batch.jsonl"
    with open(batch_file, "w") as f:
        for req in requests:
            f.write(json.dumps(req) + "\n")

    # Upload and submit
    with open(batch_file, "rb") as f:
        uploaded = client.files.create(file=f, purpose="batch")

    batch = client.batches.create(
        input_file_id=uploaded.id,
        endpoint="/v1/chat/completions",
        completion_window="24h"
    )
    return batch.id

def retrieve_batch_results(batch_id: str) -> list[dict]:
    """Poll and retrieve batch results."""
    batch = client.batches.retrieve(batch_id)
    if batch.status != "completed":
        raise RuntimeError(f"Batch not complete. Status: {batch.status}")

    content = client.files.content(batch.output_file_id)
    results = []
    for line in content.text.splitlines():
        item = json.loads(line)
        results.append({
            "loan_id": item["custom_id"].replace("loan-", ""),
            "summary": item["response"]["body"]["choices"][0]["message"]["content"]
        })
    return results
```

### Streaming Responses

Use streaming for interactive tools where users expect real-time output:

```python
def stream_sql_generation(question: str):
    """Stream SQL generation output token by token."""
    with client.chat.completions.stream(
        model="gpt-4o",
        messages=[
            {"role": "system", "content": "Write Snowflake SQL. Return only the SQL."},
            {"role": "user",   "content": question}
        ],
        temperature=0
    ) as stream:
        for text in stream.text_stream:
            print(text, end="", flush=True)
    print()  # newline after completion
```

### Token Counting and Cost Estimation

```python
import tiktoken

def estimate_cost(
    prompt: str,
    expected_completion_tokens: int = 500,
    model: str = "gpt-4o"
) -> dict:
    enc = tiktoken.encoding_for_model(model)
    prompt_tokens = len(enc.encode(prompt))

    # Pricing per 1M tokens (as of early 2026, verify current pricing)
    pricing = {
        "gpt-4o":       {"input": 2.50,  "output": 10.00},
        "gpt-4o-mini":  {"input": 0.15,  "output": 0.60},
        "gpt-4-turbo":  {"input": 10.00, "output": 30.00},
    }

    p = pricing.get(model, pricing["gpt-4o"])
    input_cost  = (prompt_tokens           / 1_000_000) * p["input"]
    output_cost = (expected_completion_tokens / 1_000_000) * p["output"]

    return {
        "prompt_tokens": prompt_tokens,
        "estimated_completion_tokens": expected_completion_tokens,
        "estimated_cost_usd": round(input_cost + output_cost, 6)
    }
```

### Rate Limits and Retry Logic

```python
import time
import openai
from openai import RateLimitError, APITimeoutError, APIConnectionError

def call_with_retry(
    messages: list,
    model: str = "gpt-4o",
    max_retries: int = 5,
    base_delay: float = 1.0
) -> str:
    """Exponential backoff for transient API errors."""
    for attempt in range(max_retries):
        try:
            response = client.chat.completions.create(
                model=model,
                messages=messages,
                temperature=0
            )
            return response.choices[0].message.content
        except RateLimitError as e:
            if attempt == max_retries - 1:
                raise
            wait = base_delay * (2 ** attempt)
            print(f"Rate limit hit. Waiting {wait:.1f}s (attempt {attempt + 1})")
            time.sleep(wait)
        except (APITimeoutError, APIConnectionError) as e:
            if attempt == max_retries - 1:
                raise
            time.sleep(base_delay * (2 ** attempt))
    raise RuntimeError("Max retries exceeded")
```

### Integrating OpenAI with Snowflake via External Functions

```sql
-- Step 1: Create API integration in Snowflake
CREATE OR REPLACE API INTEGRATION openai_integration
    API_PROVIDER = aws_api_gateway
    API_AWS_ROLE_ARN = 'arn:aws:iam::123456789:role/snowflake-openai-role'
    ENABLED = TRUE
    API_ALLOWED_PREFIXES = ('https://api.openai.com/v1/');

-- Step 2: Create external function wrapping a Lambda that calls OpenAI
CREATE OR REPLACE EXTERNAL FUNCTION generate_loan_summary(loan_json VARIANT)
    RETURNS VARIANT
    API_INTEGRATION = openai_integration
    AS 'https://your-api-gateway.amazonaws.com/prod/openai-proxy';

-- Step 3: Use in SQL
SELECT
    LOAN_ID,
    GENERATE_LOAN_SUMMARY(
        OBJECT_CONSTRUCT(
            'fico',    FICO_ORIG,
            'ltv',     LTV_ORIG,
            'balance', ORIG_BALANCE,
            'type',    PROP_TYPE,
            'status',  LOAN_STATUS
        )
    ) AS AI_SUMMARY
FROM LOAN_MASTER
WHERE LOAN_STATUS = 'DELINQUENT'
LIMIT 100;
```

### Integrating OpenAI with SQL Server via Python ML Services

```python
# Stored procedure body running in SQL Server ML Services (Python)
# sp_execute_external_script @language=N'Python', @script=N'
import openai
import pandas as pd

client = openai.AzureOpenAI(
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
    api_key=os.environ["AZURE_OPENAI_KEY"],
    api_version="2024-12-01"
)

results = []
for _, row in InputDataSet.iterrows():
    response = client.chat.completions.create(
        model="gpt-4o",  # Azure deployment name
        messages=[
            {"role": "system", "content": "Classify mortgage loan risk as LOW/MEDIUM/HIGH."},
            {"role": "user",   "content": f"FICO={row.FICO_ORIG}, LTV={row.LTV_ORIG}, DTI={row.DTI_BACK}"}
        ],
        temperature=0,
        max_tokens=10
    )
    results.append(response.choices[0].message.content.strip())

InputDataSet["RISK_TIER"] = results
OutputDataSet = InputDataSet
# '
```

### Azure OpenAI Service

Azure OpenAI provides the same GPT-4o models with enterprise controls:

| Feature | Public OpenAI API | Azure OpenAI |
|---|---|---|
| Data residency | US-based | Choose region (East US, West Europe, etc.) |
| VNet integration | No | Yes (Private Endpoint) |
| Managed Identity auth | No | Yes (no API key needed) |
| Content filtering | Model-level | Configurable per deployment |
| SLA | None | 99.9% uptime SLA |
| Compliance | SOC2 | SOC2, HIPAA, FedRAMP |
| Rate limit customization | No | Yes (PTU — provisioned throughput units) |

```python
from openai import AzureOpenAI
import os

client = AzureOpenAI(
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],  # https://your-resource.openai.azure.com/
    api_key=os.environ["AZURE_OPENAI_KEY"],
    api_version="2024-12-01"
)

response = client.chat.completions.create(
    model="gpt-4o",   # This is your Azure deployment name, not the model name
    messages=[
        {"role": "system", "content": "You are a mortgage data analyst."},
        {"role": "user",   "content": "Summarize delinquency trends for Q4 2024."}
    ],
    temperature=0
)
```

---

## Interview Q&A

**Q1: Explain the messages array structure in the Chat Completions API. How does the role of each message type affect model behavior?**

The messages array is an ordered list of conversation turns, each with a `role` and `content`. The `system` role provides persistent instructions that the model treats as ground rules — persona, output constraints, domain knowledge. It is not part of the visible "conversation" but shapes how the model interprets and responds to all subsequent messages. The `user` role represents inputs from the human or the calling application. The `assistant` role represents the model's previous responses, which you include when you want multi-turn conversation continuity — for example, a SQL refining loop where the analyst asks follow-up questions about a query the model just wrote. For deterministic pipeline tasks (SQL gen, data extraction), you typically send only system + one user message per call — no assistant history needed — to keep calls stateless and cost-predictable.

**Q2: When would you choose the Batch API over the standard Chat Completions API for mortgage data processing?**

The Batch API is appropriate when: (1) the processing is not time-sensitive (you have 24 hours to wait); (2) you are processing hundreds to thousands of records — for example, generating risk commentary for all 40,000 loans in a month-end pool report; (3) cost optimization is a priority, since Batch API pricing is 50% of synchronous pricing; (4) you want to avoid rate limit management complexity, since the Batch API handles queuing internally. You would NOT use Batch API for interactive analyst queries, real-time data quality alerts, or any pipeline step that must complete within the same transaction window as dependent downstream tasks.

**Q3: How do function calling and structured outputs differ from just asking the model to "return JSON"?**

Asking the model to "return JSON" relies on the model's instruction-following behavior — it will usually comply but can still return prose, malformed JSON, or JSON with unexpected keys under edge cases. Function calling (and the newer Structured Outputs feature with `response_format: {"type": "json_schema", "json_schema": {...}}`) is enforced at the inference level: the model's token sampling is constrained to only produce tokens that form valid JSON matching your schema. This guarantees valid JSON and correct key presence for required fields. For production pipelines parsing loan data or generating typed configurations, use strict structured outputs — it eliminates an entire class of parse errors and the defensive try/except JSON parsing boilerplate that developers otherwise write.

**Q4: How do you integrate OpenAI with Snowflake without sending sensitive mortgage data to a third-party API?**

There are three patterns in increasing data sensitivity: (1) For metadata and aggregated statistics (pool-level metrics, not borrower PII), call the public OpenAI API directly from Snowflake External Functions via a Lambda proxy; (2) For data governed under privacy agreements, use Azure OpenAI deployed in your own Azure subscription with Private Endpoint — data never traverses the public internet; (3) For maximum control, use Snowflake Cortex, which runs hosted models (including Claude and Mistral) entirely inside your Snowflake environment — no data ever leaves the Snowflake trust boundary. The choice depends on data classification: loan-level PII requires option 2 or 3; pool-level summaries can use option 1 with appropriate DUA agreements with OpenAI.

**Q5: Describe the OpenAI Assistants API and when it would be useful for a data engineering use case.**

The Assistants API provides stateful, multi-turn agent sessions with persistent threads, file upload and retrieval, code interpreter execution, and configurable tools. For data engineering, useful scenarios include: (1) a persistent analyst assistant that maintains conversation context across a full session of SQL refinement questions; (2) file search over uploaded data dictionaries, agency guidelines, or MISMO documentation — the API handles chunking and embedding; (3) code interpreter for exploratory data analysis on uploaded CSV exports without setting up a Python environment. The key architectural difference from Chat Completions is that Assistants maintain server-side state (threads), which simplifies multi-turn applications but introduces dependencies on OpenAI's infrastructure for session continuity. For stateless, high-volume pipeline processing, Chat Completions with explicit message history is more appropriate.

**Q6: How would you implement cost monitoring for OpenAI API usage in a data pipeline?**

Implement a decorator or wrapper function around every API call that: (1) captures `response.usage.prompt_tokens` and `response.usage.completion_tokens` from every response; (2) multiplies by the current model pricing to compute per-call cost; (3) writes a record to a cost monitoring table with columns: `call_timestamp`, `model`, `pipeline_name`, `prompt_tokens`, `completion_tokens`, `cost_usd`, `request_id`; (4) aggregates daily/weekly cost reports with alerts if a pipeline exceeds a configured budget threshold. Additionally, use the OpenAI usage dashboard for cross-validation. For Snowflake pipelines using External Functions or Cortex, track token usage through query metadata and warehouse credit consumption. Set hard limits at the organizational level using OpenAI's spending caps and project-level API key isolation.

**Q7: What is exponential backoff and why is it specifically important for OpenAI API integrations in high-volume mortgage processing?**

Exponential backoff is a retry strategy where the wait time between retries grows exponentially — typically: 1s, 2s, 4s, 8s, 16s — rather than retrying immediately or at fixed intervals. It is important for OpenAI integrations because: (1) OpenAI enforces rate limits by tokens-per-minute (TPM) and requests-per-minute (RPM) at the model tier level; (2) month-end MBS reporting typically triggers large concurrent batch jobs that saturate these limits; (3) immediate retries worsen the rate limit situation by adding more requests to an already overloaded quota; (4) exponential backoff with jitter (adding a small random offset) prevents thundering herd — multiple workers all retrying at identical intervals. Also use the `Retry-After` header value when present in 429 responses, as it gives the precise cooldown time rather than relying on geometric progression guesses.

**Q8: How do embeddings enable semantic search over a mortgage data dictionary, and how is this different from SQL LIKE queries?**

SQL LIKE queries match on literal string patterns — they cannot find that "current outstanding balance" and "CURR_UPB" refer to the same concept, or that "delinquency" and "past due" describe the same loan state. Embeddings encode semantic meaning as dense vectors in a high-dimensional space, where conceptually similar phrases are geometrically close (high cosine similarity). You pre-compute embeddings for all column descriptions, business term definitions, and data lineage notes. At query time, embed the user's natural language question, compute cosine similarity against your index, and return the top-k most semantically relevant schema elements. This enables a "find the right column for this business concept" capability that SQL cannot provide. In practice, store embeddings in Snowflake's VECTOR data type or a dedicated vector store (pgvector, Pinecone), and combine semantic retrieval with SQL metadata filtering for hybrid search.

**Q9: What are the compliance considerations when using OpenAI API for processing US mortgage data?**

The primary concerns are: (1) GLBA (Gramm-Leach-Bliley Act) — requires safeguards for nonpublic personal information (NPI); sending borrower names, SSNs, or loan amounts to a third-party API requires a data processing agreement and confirmation that the data is not used for model training; (2) CCPA/state privacy laws — borrower data from California residents has additional protections; (3) FCRA considerations for any output that could influence credit decisions; (4) Regulation B / Fair Housing Act — LLM-generated risk classifications must not introduce discriminatory patterns against protected classes. Mitigations: use Azure OpenAI with data processing addendum (DPA) and opt-out of training data use; anonymize or pseudonymize borrower PII before sending to the API (send FICO/LTV/DTI, not names/SSNs); document all AI-assisted decisions in the model risk management framework under SR 11-7 guidance.

**Q10: How would you build a text-to-SQL chatbot for mortgage analysts using the OpenAI API with proper guardrails?**

Architecture: (1) Analyst submits a natural language question through a Streamlit or React front end; (2) The question is embedded and used to retrieve the top-5 most relevant table descriptions from a schema vector store; (3) A Chat Completions call with system prompt containing those table DDLs generates a SQL SELECT statement using function calling with a strict JSON schema; (4) A SQL parser (sqlglot or sqlparse) validates that the output is a syntactically valid SELECT with no DDL or DML; (5) The SQL executes against Snowflake under a read-only service account; (6) Results return to the analyst with the SQL displayed for transparency; (7) All queries log to an audit table with user ID, question, generated SQL, row count, and execution time. Feedback thumbs-up/down ratings feed a labeled dataset for future prompt optimization via DSPy or fine-tuning.

---

## Pro Tips

- **Never hardcode API keys.** Use environment variables or a secrets manager (AWS Secrets Manager, Azure Key Vault). Rotate keys quarterly.
- **Use project-scoped API keys** in OpenAI's dashboard to isolate cost and rate limits per pipeline or team.
- **Prefer gpt-4o-mini for classification and extraction tasks** that run at high volume. Reserve gpt-4o for complex SQL generation and reasoning tasks. The cost difference is 15-20x.
- **Always validate JSON outputs with Pydantic.** Even with `response_format: json_object`, add a Pydantic model parse step so schema violations surface immediately with clear error messages.
- **Log the full prompt and response** for every LLM call in production pipelines. You will need this for debugging, auditing, and model-version migration testing.
- **Use the `seed` parameter** for reproducibility in testing. Setting a fixed seed makes the model more likely to return identical outputs for identical inputs, which helps regression testing.
- **Batch similar tasks together.** Concatenate multiple short extraction tasks into a single API call using a structured format rather than calling the API once per record — this reduces per-call overhead and rate limit pressure.
- **Test against model version changes.** OpenAI periodically updates models under the same name (e.g., gpt-4o-2024-11-20 vs gpt-4o-2025-01-15). Pin to a specific model version in production and run regression tests before upgrading.

---

*Last updated: 2026-03-07 | Target: Senior Data Engineer, SQL Server / Snowflake, US Secondary Mortgage Market*
