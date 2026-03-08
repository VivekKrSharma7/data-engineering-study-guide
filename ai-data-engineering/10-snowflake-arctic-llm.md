# Snowflake Arctic & LLM Integration

[Back to Index](../index.md)

---

## Overview

Snowflake Arctic is Snowflake's first open-source large language model, released in April 2024. It is purpose-built for enterprise tasks: SQL generation, coding, instruction following, and data analysis. Arctic is available natively inside Snowflake through Cortex AI functions, meaning no data ever leaves your Snowflake environment — a critical compliance requirement in regulated industries like the US secondary mortgage market.

This module covers Arctic's architecture, how to use it alongside other LLMs in Snowflake Cortex, external LLM integrations, and how to build AI-powered data applications on top of mortgage and loan data.

---

## Snowflake Arctic: Architecture & Design

### Mixture of Experts (MoE)

Arctic uses a **Mixture of Experts** architecture. Instead of activating all model parameters on every token, a router selects a small subset of "expert" sub-networks for each input. This allows Arctic to have a large total parameter count (480B) while activating only 17B parameters per forward pass — delivering quality comparable to dense 70B models at a fraction of the compute cost.

| Property | Value |
|---|---|
| Total parameters | 480B |
| Active parameters per token | 17B |
| Architecture | Dense transformer + residual MoE layers |
| Expert count | 128 |
| License | Apache 2.0 (fully open weights) |
| Training focus | SQL, code, instruction following |

### Training Philosophy

Snowflake trained Arctic with a "enterprise intelligence" focus — meaning the training data and fine-tuning emphasized:
- Structured query generation (SQL, Python)
- Following precise multi-step instructions
- Summarizing and classifying business text
- Avoiding hallucination on factual enterprise data

This makes Arctic a strong choice for mortgage data pipelines where accurate SQL generation and document summarization are more important than creative writing or open-ended reasoning.

---

## Key Concepts

### Cortex COMPLETE Function

`SNOWFLAKE.CORTEX.COMPLETE` is the primary SQL interface to LLMs in Snowflake. It accepts a model name and a prompt, returning the model's text response.

```sql
-- Basic usage: ask Arctic a question inline
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'snowflake-arctic',
    'Summarize the following loan servicer note in one sentence: ' || servicer_note
) AS summary
FROM loan_servicer_notes
WHERE note_date >= '2024-01-01'
LIMIT 100;
```

```sql
-- Using the messages array format (chat-style)
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'snowflake-arctic',
    [
        {'role': 'system', 'content': 'You are a mortgage data analyst. Answer questions about loan data concisely.'},
        {'role': 'user', 'content': 'What is a DSCR loan and why does it matter for secondary market investors?'}
    ]
) AS response;
```

### Supported Models in Cortex COMPLETE

| Model | Best For | Notes |
|---|---|---|
| `snowflake-arctic` | SQL gen, classification, summarization | Open weights, free within limits |
| `llama3.1-70b` | General reasoning, complex instructions | Meta, strong general model |
| `llama3.1-8b` | Fast, low-cost tasks | Good for high-volume classification |
| `mistral-large2` | Multilingual, coding | Strong European compliance model |
| `mixtral-8x7b` | Cost-effective MoE baseline | Older but proven |
| `claude-3-5-sonnet` | Complex analysis, long context | Anthropic, via Cortex |
| `reka-flash` | Multimodal tasks | Reka AI |

---

## Arctic for SQL Generation

SQL generation is one of Arctic's strongest use cases. A senior data engineer can use it to accelerate writing complex Snowflake queries, generating stored procedure boilerplate, or letting business analysts generate their own queries from plain English.

```sql
-- Text-to-SQL: convert a business question to SQL
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'snowflake-arctic',
    $$You are a Snowflake SQL expert. Given the following schema, write a valid Snowflake SQL query.

Schema:
- LOAN_MASTER (loan_id, origination_date, loan_amount, interest_rate, ltv_ratio, borrower_fico, loan_status)
- SERVICER_EVENTS (event_id, loan_id, event_date, event_type, event_description)
- PROPERTY (property_id, loan_id, state, zip_code, property_type, appraisal_value)

Question: Show me the average LTV ratio and FICO score for all loans originated in 2023 that are currently delinquent, grouped by state.

Return only the SQL, no explanation.$$
) AS generated_sql;
```

```python
# Python: use Snowpark to run Arctic-generated SQL dynamically
from snowflake.snowpark import Session
from snowflake.snowpark.functions import call_builtin, lit, col

session = Session.builder.configs(connection_params).create()

def generate_and_run_sql(business_question: str, schema_description: str) -> any:
    """Generate SQL from natural language using Arctic, then execute it."""
    prompt = f"""You are a Snowflake SQL expert. Schema:
{schema_description}

Write a valid Snowflake SQL query for: {business_question}
Return ONLY the SQL query, nothing else."""

    # Generate SQL via Arctic
    result = session.sql(
        "SELECT SNOWFLAKE.CORTEX.COMPLETE('snowflake-arctic', ?) AS sql_query",
        params=[prompt]
    ).collect()

    generated_sql = result[0]["SQL_QUERY"].strip()

    # Safety check: only allow SELECT statements
    if not generated_sql.upper().startswith("SELECT"):
        raise ValueError("Generated SQL is not a SELECT statement")

    return session.sql(generated_sql).to_pandas()

df = generate_and_run_sql(
    business_question="Show average FICO by loan status for 2023 originations",
    schema_description="LOAN_MASTER(loan_id, origination_date, borrower_fico, loan_status)"
)
```

---

## Data Summarization and Report Generation

Arctic excels at transforming raw loan servicer notes, property appraisal comments, and compliance audit logs into structured summaries.

```sql
-- Batch summarize servicer notes and classify delinquency reason
SELECT
    loan_id,
    note_date,
    servicer_note,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic',
        'Classify the primary reason for delinquency in one of these categories: ' ||
        '[Job Loss, Medical, Divorce, Rate Reset, Natural Disaster, Unknown]. ' ||
        'Note: ' || servicer_note ||
        '. Respond with only the category name.'
    ) AS delinquency_reason,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic',
        'Summarize this servicer note in one sentence under 25 words: ' || servicer_note
    ) AS note_summary
FROM loan_servicer_notes
WHERE note_date >= DATEADD('day', -30, CURRENT_DATE());
```

```sql
-- Generate an executive summary of a loan portfolio segment
WITH portfolio_stats AS (
    SELECT
        COUNT(*) AS total_loans,
        AVG(loan_amount) AS avg_balance,
        AVG(borrower_fico) AS avg_fico,
        SUM(CASE WHEN loan_status = 'Delinquent' THEN 1 ELSE 0 END) AS delinquent_count,
        AVG(ltv_ratio) AS avg_ltv
    FROM loan_master
    WHERE state = 'TX' AND origination_date >= '2023-01-01'
)
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'llama3.1-70b',
    'Write a 3-sentence executive summary of this Texas 2023 loan portfolio for an investor report. ' ||
    'Total loans: ' || total_loans ||
    ', Average balance: $' || ROUND(avg_balance, 0) ||
    ', Average FICO: ' || ROUND(avg_fico, 0) ||
    ', Delinquent: ' || delinquent_count ||
    ', Average LTV: ' || ROUND(avg_ltv * 100, 1) || '%'
) AS executive_summary
FROM portfolio_stats;
```

---

## Snowflake External Functions: Calling OpenAI and Anthropic

When you need a model not yet available in Cortex, Snowflake External Functions let you call any HTTP API from SQL. For regulated mortgage data, ensure your external API agreements cover data handling requirements.

```sql
-- Create the API integration for OpenAI
CREATE OR REPLACE API INTEGRATION openai_integration
    API_PROVIDER = aws_api_gateway
    API_AWS_ROLE_ARN = 'arn:aws:iam::123456789:role/snowflake-openai-role'
    API_ALLOWED_PREFIXES = ('https://your-api-gw.execute-api.us-east-1.amazonaws.com/prod/')
    ENABLED = TRUE;

-- Create the external function
CREATE OR REPLACE EXTERNAL FUNCTION call_openai_gpt4(prompt STRING)
    RETURNS VARIANT
    API_INTEGRATION = openai_integration
    AS 'https://your-api-gw.execute-api.us-east-1.amazonaws.com/prod/openai';

-- Use the external function in a query
SELECT
    loan_id,
    call_openai_gpt4('Analyze loan risk: FICO=' || borrower_fico || ', LTV=' || ltv_ratio):choices[0]:message:content::STRING AS risk_analysis
FROM loan_master
LIMIT 10;
```

---

## Snowpark Container Services: Hugging Face Models

For full control, you can run open-source Hugging Face models inside Snowflake using Snowpark Container Services (SPCS). This keeps all data in Snowflake and avoids external API calls entirely.

```python
# Dockerfile for a Hugging Face embedding/inference service in SPCS
# (Deployed as an image to Snowflake Image Registry)

# app.py — FastAPI service running inside SPCS
from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer
from typing import List

app = FastAPI()
model = SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2')

class EmbedRequest(BaseModel):
    texts: List[str]

@app.post("/embed")
def embed(request: EmbedRequest):
    embeddings = model.encode(request.texts, normalize_embeddings=True)
    return {"embeddings": embeddings.tolist()}

@app.get("/health")
def health():
    return {"status": "ok"}
```

```sql
-- Register the SPCS service as a Snowflake function
CREATE OR REPLACE FUNCTION embed_loan_text(text STRING)
    RETURNS ARRAY
    SERVICE = loan_ml_service
    ENDPOINT = 'inference'
    AS '/embed';

-- Use it to embed servicer notes
SELECT
    loan_id,
    embed_loan_text(servicer_note) AS note_embedding
FROM loan_servicer_notes
WHERE note_date = CURRENT_DATE();
```

---

## Streamlit in Snowflake: AI-Powered Loan Data App

Streamlit in Snowflake (SiS) runs Python directly inside Snowflake — no external hosting needed.

```python
# streamlit_app.py — Loan Portfolio Q&A with Arctic
import streamlit as st
from snowflake.snowpark.context import get_active_session
import json

session = get_active_session()

st.title("Loan Portfolio Assistant (Powered by Snowflake Arctic)")
st.caption("Ask questions about your mortgage portfolio in plain English.")

# Show a snapshot of the portfolio
with st.expander("Portfolio Snapshot"):
    stats = session.sql("""
        SELECT
            COUNT(*) AS total_loans,
            AVG(loan_amount) AS avg_balance,
            AVG(borrower_fico) AS avg_fico,
            SUM(CASE WHEN loan_status = 'Delinquent' THEN 1 ELSE 0 END) AS delinquent_count
        FROM loan_master
    """).to_pandas()
    st.dataframe(stats)

user_question = st.text_input("Ask a question about the portfolio:")

if user_question:
    with st.spinner("Arctic is thinking..."):
        schema = """
        LOAN_MASTER(loan_id, origination_date, loan_amount, interest_rate,
                    ltv_ratio, borrower_fico, loan_status, state)
        SERVICER_EVENTS(event_id, loan_id, event_date, event_type)
        PROPERTY(property_id, loan_id, zip_code, property_type, appraisal_value)
        """
        prompt = f"""You are a mortgage data analyst with access to Snowflake.
Schema: {schema}
Question: {user_question}
Write a Snowflake SQL query that answers this question. Return ONLY the SQL."""

        result = session.sql(
            "SELECT SNOWFLAKE.CORTEX.COMPLETE('snowflake-arctic', ?) AS sql_query",
            params=[prompt]
        ).collect()

        generated_sql = result[0]["SQL_QUERY"].strip()
        st.subheader("Generated SQL")
        st.code(generated_sql, language="sql")

        try:
            data = session.sql(generated_sql).to_pandas()
            st.subheader("Results")
            st.dataframe(data)
        except Exception as e:
            st.error(f"SQL execution error: {e}")
```

---

## LLM Gateway Pattern: Managing Multiple Providers

As your organization experiments with multiple LLMs, a gateway pattern lets you abstract model selection behind a consistent interface.

```sql
-- Stored procedure: LLM router that selects model based on task type
CREATE OR REPLACE PROCEDURE call_llm(task_type STRING, prompt STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    model_name STRING;
    response STRING;
BEGIN
    -- Route to the right model based on task
    model_name := CASE task_type
        WHEN 'sql_generation'     THEN 'snowflake-arctic'
        WHEN 'summarization'      THEN 'llama3.1-8b'
        WHEN 'complex_reasoning'  THEN 'llama3.1-70b'
        WHEN 'classification'     THEN 'mistral-large2'
        ELSE 'snowflake-arctic'
    END;

    SELECT SNOWFLAKE.CORTEX.COMPLETE(:model_name, :prompt)
    INTO :response;

    RETURN response;
END;
$$;

-- Use it
CALL call_llm('summarization', 'Summarize: Borrower called to report job loss. Requesting forbearance.');
```

---

## Interview Q&A

**Q1: What is Snowflake Arctic and how does it differ from models like Llama or GPT-4?**

Arctic is Snowflake's open-source LLM (Apache 2.0), built specifically for enterprise data tasks. It uses a Mixture of Experts architecture with 480B total parameters but only 17B active per token. Unlike GPT-4 (closed, general-purpose) or Llama (open, general-purpose), Arctic was trained with emphasis on SQL generation, coding, and instruction following in structured data contexts. For data engineers, this means Arctic performs well on tasks that map directly to what we do — writing SQL, classifying records, summarizing documents — while being cheaper to run than dense models of equivalent quality.

**Q2: How would you use Cortex COMPLETE in a production mortgage data pipeline?**

I would use it selectively for tasks that genuinely benefit from language understanding — not for anything a deterministic SQL expression can handle. Concrete uses: batch-classify servicer notes by delinquency reason, generate plain-English summaries of daily portfolio changes for executive dashboards, enrich loan records with sentiment scores from customer service transcripts. I would wrap all LLM calls in a try/except or Snowflake task error handler, store both the raw prompt and response for audit purposes (important in mortgage compliance), and monitor cost via QUERY_HISTORY.

**Q3: How do External Functions differ from Cortex COMPLETE for calling LLMs?**

Cortex COMPLETE calls models hosted inside Snowflake's own infrastructure — data never leaves Snowflake. External Functions call an HTTP endpoint you control (typically behind API Gateway), meaning data does leave Snowflake. For secondary mortgage market data covered by GLBA and investor data sharing agreements, Cortex COMPLETE is preferable from a compliance standpoint. External Functions are useful when you need a model Snowflake doesn't yet support natively, or when you need a specific fine-tuned model your team has deployed.

**Q4: What is Snowpark Container Services and when would you use it for AI workloads?**

SPCS lets you run arbitrary Docker containers inside Snowflake's compute infrastructure. For AI, this means running Hugging Face inference servers, custom fine-tuned models, or Python ML pipelines that need GPU compute — all without data leaving Snowflake. I would use SPCS when: (1) I need a specific open-source model not available in Cortex, (2) I need to run a fine-tuned model trained on proprietary mortgage data, or (3) I need to embed large volumes of documents using Sentence Transformers for a RAG pipeline, and I want to avoid per-API-call costs.

**Q5: How would you build a text-to-SQL system for business analysts over mortgage data?**

The pipeline would be: (1) create a well-documented schema description including table names, column names with business meanings, and example values; (2) use a Streamlit in Snowflake app as the front end; (3) call Arctic via Cortex COMPLETE with the schema + user question as the prompt; (4) parse the generated SQL, enforce it starts with SELECT (no DML), and execute it; (5) display results. Key risks: hallucinated table/column names, JOINs on wrong keys, incorrect date filters. Mitigations: include column names and data types in the prompt, use few-shot examples of correct queries, validate generated SQL against INFORMATION_SCHEMA before execution.

**Q6: How does Arctic's MoE architecture benefit high-volume batch inference on loan data?**

In a batch job classifying 10 million servicer notes, you care about throughput and cost, not just latency. MoE activates only 17B parameters per token instead of the full 480B, meaning each inference call consumes far less compute. Snowflake can therefore parallelize more concurrent inferences at lower cost compared to a dense 70B model. For me, running nightly classification across a large GNMA/FNMA pool, this translates directly to staying within Cortex credit budgets while still getting strong classification accuracy.

**Q7: What are the key considerations for using LLMs on data covered by GLBA or FNMA/FHLMC data requirements?**

First, data residency: Cortex COMPLETE keeps data inside Snowflake, which is generally acceptable since Snowflake is already your data platform. External LLM APIs require reviewing your data sharing agreements. Second, auditability: store every prompt and response in an audit table with timestamps, user context, and model version — examiners may ask what AI was applied to what data. Third, model drift: LLM responses are non-deterministic; for any decision that feeds into loan disposition or reporting, add human review or use LLMs only for enrichment fields not binding decisions. Fourth, PII: ensure borrower PII is redacted or tokenized before it enters any prompt sent to external APIs.

**Q8: How would you evaluate whether Arctic is the right model for a specific task versus Llama 3.1 70B?**

I would run a structured evaluation: (1) collect 100–200 representative examples of the task (e.g., servicer note classification); (2) manually label ground truth; (3) run both models with identical prompts and measure accuracy, plus hallucination rate on edge cases; (4) measure latency and Cortex credit cost per 1,000 calls; (5) decide based on accuracy/cost tradeoff. For SQL generation on our specific schema, I would also test with few-shot examples vs. zero-shot. Arctic tends to win on cost at similar accuracy for structured tasks; Llama 3.1 70B tends to win on complex multi-step reasoning or long-form analysis.

**Q9: Describe how you would operationalize LLM-based enrichment in a Snowflake data pipeline.**

I would use Snowflake Tasks and Streams: a stream captures new rows inserted into the raw servicer notes table; a task fires every hour, processes only the new rows, calls Cortex COMPLETE for classification and summarization, and writes results to an enriched table. The task logs success/failure to a pipeline audit table. I set a MAX_ERROR_INTEGRATION on the task so one bad LLM response doesn't fail the entire batch. For cost control, I set a row limit per task run and use the cheaper `llama3.1-8b` for high-volume classification, reserving Arctic or Llama 70B for lower-volume summary tasks.

**Q10: What is Streamlit in Snowflake and what advantage does it offer over hosting a Streamlit app externally?**

Streamlit in Snowflake runs the Python Streamlit app inside Snowflake's own compute, with a direct Snowpark session — no credentials management, no VPN, no external hosting. Data never leaves the Snowflake perimeter. For mortgage data, this is a significant compliance advantage: business analysts get self-service data apps without IT needing to set up external infrastructure or worry about data egress. The tradeoff is that SiS has some Python library restrictions and no persistent file system, but for read-oriented dashboards and LLM-powered Q&A tools it is the right deployment model.

---

## Pro Tips

- Always include a system prompt when using chat-format prompts in Cortex COMPLETE. Setting the model's role (e.g., "You are a mortgage data analyst") dramatically improves output quality and consistency.
- Store prompts and responses in a dedicated `LLM_AUDIT_LOG` table. In mortgage, you will be asked to explain any AI-assisted enrichment during regulatory review.
- Use `llama3.1-8b` for volume classification tasks and `snowflake-arctic` or `llama3.1-70b` only where you need higher accuracy. This keeps Cortex credit consumption under control.
- When generating SQL with an LLM, always validate that the output is a SELECT statement before executing it. Never allow LLM-generated DML to run without a human approval step.
- Arctic's open Apache 2.0 license means you can download the weights and run it on your own GPU infrastructure if you ever need to move off Snowflake — a useful negotiating point with Snowflake on credit pricing.
- In Streamlit in Snowflake, use `st.cache_data` to cache expensive LLM calls. Repeated identical prompts should not burn Cortex credits.
- Test all LLM-based SQL generators against your INFORMATION_SCHEMA to catch hallucinated column or table names before results reach end users.
