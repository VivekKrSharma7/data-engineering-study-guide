# Snowflake Cortex AI & ML Functions

[Back to Index](README.md)

---

## Overview

Snowflake Cortex brings enterprise AI directly into the Snowflake data platform — no external API keys to manage, no data egress, no Python infrastructure to maintain. For a senior data engineer working with MBS pool data, servicer notes, and loan-level attributes, Cortex provides LLM functions callable in pure SQL, semantic search over unstructured documents, a natural-language-to-SQL interface (Cortex Analyst), and document parsing. This guide covers every major Cortex capability with SQL syntax, credit cost guidance, and mortgage-specific examples.

---

## Key Concepts at a Glance

| Cortex Feature | Category | Primary Use Case |
|---|---|---|
| `COMPLETE()` | LLM | Freeform generation, summarization, extraction |
| `SUMMARIZE()` | LLM | Single-function text summarization |
| `SENTIMENT()` | LLM | Sentiment score on short text |
| `TRANSLATE()` | LLM | Language translation |
| `EXTRACT_ANSWER()` | LLM | QA over a passage |
| `CLASSIFY_TEXT()` | LLM | Zero/few-shot classification |
| Cortex Search | Search | Semantic search over Snowflake data |
| Cortex Analyst | NL2SQL | Chat interface over data |
| Document AI | Document | PDF/form field extraction |
| Cortex Fine-tuning | LLM | Domain-adapted models |
| `FORECAST()` | ML | Time-series prediction |
| `ANOMALY_DETECTION()` | ML | Outlier detection |
| `CLASSIFICATION()` | ML | Binary/multi-class ML |

---

## Cortex LLM Functions

### SNOWFLAKE.CORTEX.COMPLETE()

The most flexible Cortex function. Supports multiple models and structured output.

```sql
-- Basic completion: summarize a servicer note
SELECT
    loan_id,
    note_date,
    servicer_note,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic-instruct',
        'Summarize this mortgage servicer note in one sentence, '
        || 'focusing on the borrower''s delinquency status and any action taken: '
        || servicer_note
    ) AS note_summary
FROM mortgage_db.servicing.servicer_notes
WHERE note_date >= CURRENT_DATE - 30
  AND LENGTH(servicer_note) > 100
LIMIT 100;

-- Using messages array syntax for chat-style prompting
SELECT
    loan_id,
    SNOWFLAKE.CORTEX.COMPLETE(
        'mistral-large2',
        [
            {
                'role': 'system',
                'content': 'You are a mortgage risk analyst. Extract structured data from servicer notes.'
            },
            {
                'role': 'user',
                'content': 'Extract the following fields as JSON from this note: '
                         || '{"delinquency_days": <number|null>, "forbearance_requested": <true|false>, '
                         || '"modification_type": <string|null>, "next_contact_date": <YYYY-MM-DD|null>}. '
                         || 'Note: ' || servicer_note
            }
        ],
        {
            'temperature': 0,
            'max_tokens': 200
        }
    ) AS extracted_json
FROM mortgage_db.servicing.servicer_notes
WHERE processing_status = 'PENDING';

-- Parse the JSON output
WITH extracted AS (
    SELECT
        loan_id,
        SNOWFLAKE.CORTEX.COMPLETE(
            'mistral-large2',
            'Return only valid JSON. Extract from this servicer note: '
            || '{"delinquency_days": <integer or null>, "forbearance_requested": <true/false>}. '
            || 'Note: ' || servicer_note
        ) AS raw_json
    FROM mortgage_db.servicing.servicer_notes
    WHERE note_date = CURRENT_DATE - 1
)
SELECT
    loan_id,
    TRY_PARSE_JSON(raw_json):delinquency_days::INT    AS delinquency_days,
    TRY_PARSE_JSON(raw_json):forbearance_requested::BOOLEAN AS forbearance_requested
FROM extracted;
```

### Supported Models

| Model | Strengths | Best For |
|---|---|---|
| `snowflake-arctic-instruct` | Fast, cost-efficient, Snowflake-hosted | Bulk classification, extraction |
| `mistral-large2` | Strong reasoning, 128K context | Complex extraction, multi-step analysis |
| `mistral-7b` | Very fast, low cost | Simple classification, sentiment |
| `llama3.1-70b` | Open weights, strong general capability | Summarization, QA |
| `llama3.1-8b` | Fastest, cheapest | Real-time, high-volume tasks |
| `reka-flash` | Multimodal-ready | Document analysis |
| `jamba-instruct` | Long context (256K) | Full loan file analysis |

### SNOWFLAKE.CORTEX.SUMMARIZE()

Convenience wrapper around COMPLETE for summarization. Uses Snowflake's optimized internal prompt.

```sql
-- Summarize all servicer notes for a loan into a single portfolio summary
SELECT
    loan_id,
    SNOWFLAKE.CORTEX.SUMMARIZE(
        LISTAGG(note_date || ': ' || servicer_note, ' | ') WITHIN GROUP (ORDER BY note_date)
    ) AS loan_summary
FROM mortgage_db.servicing.servicer_notes
WHERE loan_id = 'L-2024-00134'
GROUP BY loan_id;
```

### SNOWFLAKE.CORTEX.SENTIMENT()

Returns a score between -1.0 (most negative) and 1.0 (most positive).

```sql
-- Analyze sentiment of borrower communications
SELECT
    loan_id,
    communication_date,
    LEFT(communication_text, 100) AS preview,
    SNOWFLAKE.CORTEX.SENTIMENT(communication_text) AS sentiment_score,
    CASE
        WHEN SNOWFLAKE.CORTEX.SENTIMENT(communication_text) >= 0.3  THEN 'POSITIVE'
        WHEN SNOWFLAKE.CORTEX.SENTIMENT(communication_text) <= -0.3 THEN 'NEGATIVE'
        ELSE 'NEUTRAL'
    END AS sentiment_label
FROM mortgage_db.servicing.borrower_communications
WHERE communication_date >= CURRENT_DATE - 90;

-- Aggregate sentiment trends by servicer and month
SELECT
    servicer_id,
    DATE_TRUNC('month', communication_date) AS month,
    AVG(SNOWFLAKE.CORTEX.SENTIMENT(communication_text)) AS avg_sentiment,
    COUNT(*) AS communication_count
FROM mortgage_db.servicing.borrower_communications
GROUP BY 1, 2
ORDER BY 1, 2;
```

### SNOWFLAKE.CORTEX.TRANSLATE()

```sql
-- Translate Spanish-language servicer notes for English-language reporting
SELECT
    loan_id,
    servicer_note AS original_spanish,
    SNOWFLAKE.CORTEX.TRANSLATE(
        servicer_note,
        'es',   -- source language
        'en'    -- target language
    ) AS english_translation
FROM mortgage_db.servicing.servicer_notes
WHERE note_language = 'es';
```

### SNOWFLAKE.CORTEX.EXTRACT_ANSWER()

Extracts a specific answer from a passage — useful for structured extraction without COMPLETE's overhead.

```sql
-- Extract specific fields from dense legal text
SELECT
    doc_id,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        doc_text,
        'What is the maturity date of this mortgage?'
    ) AS maturity_date_answer,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        doc_text,
        'What is the original principal balance?'
    ) AS original_balance_answer
FROM mortgage_db.documents.closing_disclosures
WHERE doc_type = 'CLOSING_DISCLOSURE'
  AND maturity_date IS NULL;  -- Fill gaps in structured fields
```

### SNOWFLAKE.CORTEX.CLASSIFY_TEXT()

Zero/few-shot classification with customizable labels.

```sql
-- Classify servicer notes by loss mitigation action type
SELECT
    loan_id,
    note_date,
    servicer_note,
    SNOWFLAKE.CORTEX.CLASSIFY_TEXT(
        servicer_note,
        ['FORBEARANCE_REQUEST', 'REPAYMENT_PLAN', 'LOAN_MODIFICATION',
         'SHORT_SALE', 'DEED_IN_LIEU', 'FORECLOSURE_REFERRAL',
         'BORROWER_CONTACT', 'PAYMENT_RECEIVED', 'OTHER']
    ) AS note_classification
FROM mortgage_db.servicing.servicer_notes
WHERE classification IS NULL
LIMIT 1000;

-- With few-shot examples for higher accuracy
SELECT
    loan_id,
    SNOWFLAKE.CORTEX.CLASSIFY_TEXT(
        servicer_note,
        [
            {
                'label': 'IMMINENT_DEFAULT',
                'examples': [
                    'Borrower stated they will be unable to make next payment due to job loss',
                    'Customer called to report upcoming hardship, requesting options'
                ]
            },
            {
                'label': 'ACTIVE_DEFAULT',
                'examples': [
                    'Payment 60+ days past due, foreclosure timeline initiated',
                    'No response to 3 contact attempts, referred to attorney'
                ]
            },
            {
                'label': 'CURRENT',
                'examples': [
                    'Payment received in full, account current',
                    'Escrow analysis completed, no delinquency'
                ]
            }
        ]
    ) AS default_risk_category
FROM mortgage_db.servicing.servicer_notes;
```

---

## Cortex Search

Cortex Search provides managed semantic + keyword hybrid search over Snowflake tables. No external search index required.

```sql
-- Create a Cortex Search Service on servicer notes
CREATE OR REPLACE CORTEX SEARCH SERVICE mortgage_db.servicing.servicer_notes_search
    ON servicer_note
    ATTRIBUTES loan_id, note_date, servicer_id, loan_state
    WAREHOUSE = COMPUTE_WH
    TARGET_LAG = '1 hour'
AS
    SELECT
        loan_id,
        note_date,
        servicer_id,
        loan_state,
        servicer_note
    FROM mortgage_db.servicing.servicer_notes
    WHERE note_date >= '2023-01-01';

-- Query using the REST API (from Streamlit in Snowflake or external app)
-- The search service handles embedding + reranking automatically
-- In Snowpark Python:
-- from snowflake.cortex import CortexSearchService
-- results = session.cortex_search('servicer_notes_search')
--     .query('borrower hardship medical emergency California', limit=10)
```

---

## Cortex Analyst

Cortex Analyst enables natural language queries over structured data by converting questions to SQL using a semantic model definition (YAML).

```yaml
# semantic_model.yaml - Define the semantic layer for Cortex Analyst
name: mortgage_portfolio_model
description: MBS pool and loan-level performance data

tables:
  - name: loan_performance
    base_table:
      database: mortgage_db
      schema: analytics
      table: loan_performance_monthly
    dimensions:
      - name: loan_id
        expr: loan_id
        data_type: TEXT
      - name: pool_id
        expr: pool_id
        data_type: TEXT
      - name: loan_state
        expr: property_state
        data_type: TEXT
    time_dimensions:
      - name: report_date
        expr: report_date
        data_type: DATE
    measures:
      - name: current_upb
        expr: current_unpaid_principal_balance
        data_type: NUMBER
        description: Current unpaid principal balance in dollars
      - name: cpr
        expr: conditional_prepayment_rate
        data_type: NUMBER
        description: Annualized prepayment speed as a percentage
      - name: delinquency_rate
        expr: delinquent_loan_count / total_loan_count
        data_type: NUMBER
        description: Fraction of loans 30+ days delinquent
```

---

## Document AI

Document AI extracts structured fields from PDFs and scanned forms — critical for processing 1003 applications and closing packages.

```sql
-- Create a Document AI model for 1003 loan applications
CREATE OR REPLACE SNOWFLAKE.ML.DOCUMENT_INTELLIGENCE_MODEL mortgage_db.ml.urla_1003_extractor
    FROM '@mortgage_db.documents.doc_stage/1003_training_samples/'
    TASK = 'EXTRACTION'
    DOCUMENT_TYPE = 'FORM';

-- Process new documents from a stage
SELECT
    RELATIVE_PATH AS file_name,
    mortgage_db.ml.urla_1003_extractor!PREDICT(
        GET_PRESIGNED_URL('@mortgage_db.documents.incoming_stage', RELATIVE_PATH),
        1  -- page number
    ) AS extracted_fields
FROM DIRECTORY('@mortgage_db.documents.incoming_stage')
WHERE RELATIVE_PATH LIKE '%.pdf';

-- Parse the extraction result
WITH doc_extraction AS (
    SELECT
        RELATIVE_PATH AS file_name,
        mortgage_db.ml.urla_1003_extractor!PREDICT(
            GET_PRESIGNED_URL('@mortgage_db.documents.incoming_stage', RELATIVE_PATH),
            1
        ) AS result
    FROM DIRECTORY('@mortgage_db.documents.incoming_stage')
)
SELECT
    file_name,
    result:__documentMetadata:ocrScore::FLOAT       AS ocr_confidence,
    result:borrower_name[0]:value::STRING            AS borrower_name,
    result:loan_amount[0]:value::FLOAT               AS loan_amount,
    result:property_address[0]:value::STRING         AS property_address,
    result:loan_purpose[0]:value::STRING             AS loan_purpose
FROM doc_extraction;
```

---

## Cortex Fine-tuning

Fine-tune an LLM on your proprietary mortgage data to improve accuracy on domain-specific tasks.

```sql
-- Create training data for fine-tuning a note classification model
CREATE OR REPLACE TABLE mortgage_db.ml.note_classification_training AS
SELECT
    servicer_note AS prompt,
    note_classification AS completion
FROM mortgage_db.servicing.servicer_notes_labeled
WHERE note_classification IS NOT NULL
  AND annotation_quality_score >= 4  -- human-verified labels
  AND LENGTH(servicer_note) BETWEEN 50 AND 2000;

-- Create the fine-tuning job
CREATE OR REPLACE SNOWFLAKE.CORTEX.FINE_TUNE mortgage_db.ml.mortgage_note_classifier
    BASE_MODEL = 'mistral-7b'
    TRAINING_DATA = SELECT prompt, completion FROM mortgage_db.ml.note_classification_training
    VALIDATION_DATA = SELECT prompt, completion FROM mortgage_db.ml.note_classification_validation;

-- Check fine-tuning status
SELECT SNOWFLAKE.CORTEX.FINE_TUNE_STATUS('mortgage_db.ml.mortgage_note_classifier');

-- Use the fine-tuned model in COMPLETE
SELECT
    loan_id,
    SNOWFLAKE.CORTEX.COMPLETE(
        'mortgage_db.ml.mortgage_note_classifier',  -- custom fine-tuned model
        servicer_note
    ) AS classification
FROM mortgage_db.servicing.servicer_notes
WHERE classification IS NULL;
```

---

## Using Cortex in Data Pipelines (Streams + Tasks)

```sql
-- Stream to capture new servicer notes
CREATE OR REPLACE STREAM mortgage_db.servicing.servicer_notes_stream
    ON TABLE mortgage_db.servicing.servicer_notes
    APPEND_ONLY = TRUE;

-- Staging table for enriched notes
CREATE OR REPLACE TABLE mortgage_db.servicing.servicer_notes_enriched (
    note_id         BIGINT,
    loan_id         VARCHAR(20),
    note_date       DATE,
    servicer_note   VARCHAR,
    note_summary    VARCHAR,
    sentiment_score FLOAT,
    note_category   VARCHAR,
    enriched_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Task that runs every 15 minutes to enrich new notes
CREATE OR REPLACE TASK mortgage_db.servicing.enrich_servicer_notes_task
    WAREHOUSE = CORTEX_WH
    SCHEDULE = '15 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('mortgage_db.servicing.servicer_notes_stream')
AS
INSERT INTO mortgage_db.servicing.servicer_notes_enriched
    (note_id, loan_id, note_date, servicer_note, note_summary, sentiment_score, note_category)
SELECT
    s.note_id,
    s.loan_id,
    s.note_date,
    s.servicer_note,
    SNOWFLAKE.CORTEX.SUMMARIZE(s.servicer_note)           AS note_summary,
    SNOWFLAKE.CORTEX.SENTIMENT(s.servicer_note)           AS sentiment_score,
    SNOWFLAKE.CORTEX.CLASSIFY_TEXT(
        s.servicer_note,
        ['PAYMENT_EVENT', 'LOSS_MITIGATION', 'BORROWER_CONTACT',
         'LEGAL_ACTION', 'ESCROW_ISSUE', 'OTHER']
    )                                                      AS note_category
FROM mortgage_db.servicing.servicer_notes_stream AS s;

-- Activate the task
ALTER TASK mortgage_db.servicing.enrich_servicer_notes_task RESUME;
```

---

## Cortex Credit Cost Reference

| Function | Model | Tokens Consumed | Approximate Cost |
|---|---|---|---|
| `SENTIMENT()` | Internal | ~100 tokens/call | $0.00002/call |
| `SUMMARIZE()` | Internal | ~500 tokens/call | $0.0001/call |
| `CLASSIFY_TEXT()` | Internal | ~200 tokens/call | $0.00004/call |
| `COMPLETE()` | llama3.1-8b | Per token | $0.10/1M tokens |
| `COMPLETE()` | mistral-large2 | Per token | $2.00/1M tokens |
| `COMPLETE()` | snowflake-arctic | Per token | $0.30/1M tokens |
| Cortex Search | N/A | Per query + indexing | $0.10/1K queries |

**Cost optimization tips:**
- Use `llama3.1-8b` or `mistral-7b` for classification — accuracy is within 2-5% of larger models on structured tasks.
- Set `max_tokens` explicitly in `COMPLETE()` options to cap output length.
- Pre-filter records before calling Cortex — don't enrich notes shorter than 50 characters.
- Cache results: after running `SENTIMENT()`, store in a column; never re-call for the same text.

---

## Interview Q&A

**Q1: What is Snowflake Cortex and how does it differ from calling an external LLM API from a Snowflake Snowpark function?**

A: Cortex is Snowflake's managed AI layer — LLM inference runs inside Snowflake's infrastructure, meaning data never leaves the Snowflake security perimeter. With Cortex, you call functions like `SNOWFLAKE.CORTEX.COMPLETE()` directly in SQL or Snowpark with no API keys, no network egress policy management, and no external service latency. By contrast, calling an external LLM from a Snowpark Python UDF requires managing secrets in Snowflake Secret Manager, handling network policies to allow outbound HTTPS, managing retries and rate limiting in Python, and accepting that data leaves Snowflake's environment — which may violate data governance policies for MNPI-classified MBS pool data. Cortex also integrates with Snowflake's cost governance (virtual warehouse compute credits or Cortex-specific credit consumption), making cost attribution straightforward in a data engineering team's budget model.

**Q2: Walk through how you would build a pipeline to summarize 5 years of servicer notes for 50,000 loans in Snowflake Cortex.**

A: The approach is a staged batch pipeline to manage cost and avoid compute timeouts. First, create a `processed_flag` column on the `servicer_notes` table (or a separate enrichment tracking table keyed on `note_id`) to make the pipeline idempotent. Second, group notes by loan and concatenate them chronologically using `LISTAGG` with `WITHIN GROUP (ORDER BY note_date)`, but cap the total input at roughly 4,000 characters to stay within model context limits and control token costs. Third, create a Task with a `SCHEDULE = '10 MINUTE'` cadence that processes a fixed batch (e.g., 500 loans per run) using `LIMIT` and the processing flag, calling `SNOWFLAKE.CORTEX.SUMMARIZE()` or `COMPLETE()` with `llama3.1-70b`. Fourth, write results to a `loan_note_summaries` table. For 50,000 loans with average 2,000-character note history, total token consumption is approximately 50M input tokens — at arctic rates, roughly $15. Use a dedicated `CORTEX_WH` X-Small warehouse for the Task to avoid contention with analytical queries.

**Q3: How does Cortex Search differ from a traditional LIKE-based full-text search in Snowflake?**

A: `LIKE '%term%'` is a substring match that has no understanding of meaning, synonyms, or context. Cortex Search uses a hybrid approach: BM25 keyword scoring (similar to traditional full-text search) combined with dense vector retrieval using embeddings from a transformer model, then reranked with an LLM-based relevance scorer. The result is that a query for "borrower financial hardship" returns notes containing "job loss," "medical bills," "temporary income reduction" — concepts that are semantically related but don't share keywords. For a mortgage servicer portfolio, this matters when analysts are trying to find similar loss mitigation situations across a pool without knowing the exact terminology used by individual servicers. Cortex Search also eliminates the need to manage a separate embedding pipeline, an external vector store, and a retrieval API — the service handles incremental updates via `TARGET_LAG`, and you query it via REST or Snowpark SDK.

**Q4: What are the supported models in Cortex COMPLETE() and how do you choose between them for a mortgage classification task?**

A: Model selection is a tradeoff of accuracy, latency, and cost. For classifying servicer notes into 8-10 predefined categories, `llama3.1-8b` or `mistral-7b` typically achieve 88-92% accuracy at roughly 10x lower cost than `mistral-large2` and 3x lower latency. Use `mistral-large2` or `llama3.1-70b` for complex extraction tasks where the model must parse dense legal language (e.g., extracting all covenants from a pooling and servicing agreement) or when chain-of-thought reasoning improves accuracy on ambiguous cases. Use `snowflake-arctic-instruct` for tasks that benefit from Snowflake's optimization — it's highly competitive on structured extraction. For a production pipeline processing 100,000 notes daily, benchmark all candidate models on a labeled sample of 500 notes first; the accuracy delta often does not justify the cost differential. Also consider `jamba-instruct` for very long documents (full loan files) since it supports 256K context.

**Q5: How do you implement Cortex Analyst and what is the semantic model YAML used for?**

A: Cortex Analyst exposes a REST API that accepts natural language questions and returns SQL (and optionally executes it). The semantic model YAML is the critical configuration layer — it tells the LLM the business meaning of tables, columns, measures, and relationships. Without it, the LLM would generate SQL against raw column names like `curr_upb` and miss business logic like "delinquency rate = delinquent loans / total loans." The YAML defines: tables and their descriptions, dimension columns (slicing attributes like `property_state`, `servicer_id`), time dimensions, computed measures (including formulas), and optional verified SQL examples for common questions. In a mortgage data engineering context, the semantic model would expose measures like CPR (conditional prepayment rate), CDR (conditional default rate), and weighted average coupon — each with precise SQL definitions matching the GSE reporting standards. The model is stored in a Snowflake stage and referenced when creating the Cortex Analyst service. Access control is governed by Snowflake RBAC — analysts only see data their role can access, even when querying via natural language.

**Q6: Describe how you would use CLASSIFY_TEXT() with few-shot examples versus zero-shot for a mortgage-specific task. When does few-shot matter?**

A: Zero-shot classification passes only the label names to the model. Few-shot passes label names plus example texts for each label. Few-shot matters when label boundaries are ambiguous in the mortgage domain — for example, distinguishing "IMMINENT_DEFAULT" (borrower is current but signaling upcoming non-payment) from "ACTIVE_DEFAULT" (payment already missed) requires the model to understand the temporal framing of servicer note language. With zero-shot, the model relies entirely on general training; with few-shot, you anchor it to your specific vocabulary ("unable to make next payment" = IMMINENT_DEFAULT in your taxonomy vs. potentially LOSS_MITIGATION in a different taxonomy). In practice, add 3-5 representative examples per class from your labeled data. The `CLASSIFY_TEXT()` function accepts either a list of strings (zero-shot) or a list of objects with `label` and `examples` keys (few-shot). For mortgage note classification, I typically see a 5-10 percentage point accuracy improvement with 3 examples per class, making few-shot worth the additional prompt engineering effort.

**Q7: What are the cost and performance implications of running Cortex LLM functions inside a Task on a large table?**

A: Cortex LLM functions consume Cortex credits (separate from compute credits for most functions, though some use warehouse compute). The key performance consideration is that these functions are not vectorized across rows like a native SQL function — each row incurs a separate model invocation internally. For a table with 1M rows, calling `SUMMARIZE()` on every row is an expensive serial operation. Mitigation strategies: (1) Use a stream + task pattern to process only new/changed rows rather than the full table. (2) Partition processing across multiple tasks running in parallel on different `loan_id` ranges. (3) Pre-filter aggressively — only call the LLM on notes longer than a minimum length, or where a previous classification was null. (4) Use multi-row batching where possible: `COMPLETE()` with a prompt that asks the model to classify multiple notes at once (returning a JSON array) reduces per-call overhead, but requires careful output parsing and error handling. (5) Monitor Cortex credit consumption in the `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_USAGE_HISTORY` view and set Resource Monitors on the warehouse running Cortex tasks.

**Q8: How does Cortex Fine-tuning work and when would you use it over a general model for mortgage data?**

A: Cortex Fine-tuning creates a custom version of a base model (currently `mistral-7b` is supported) trained on your labeled data, using a supervised instruction fine-tuning approach. The training data is `(prompt, completion)` pairs stored in a Snowflake table. When to use it: (1) When a general model achieves less than 85% accuracy on your classification task despite few-shot examples — common when your label taxonomy is highly domain-specific (e.g., Fannie Mae vs. Freddie Mac pool classification codes). (2) When you need consistent output format (e.g., always output exactly one of N codes with no prose) — fine-tuned models are more reliably instructable on format. (3) When you have 500+ high-quality labeled examples per class. When NOT to use it: for tasks where prompting a larger general model outperforms a fine-tuned smaller model, or when your labeled data is fewer than 200 examples per class (risk of overfitting). The fine-tuned model is deployed as a Snowflake-managed endpoint accessible only within your account, so it inherits all your RBAC and data residency guarantees.

**Q9: How would you use Cortex in a Snowflake data pipeline to detect and flag unusual servicer behavior patterns?**

A: This is a multi-step pipeline combining ML and LLM functions. Step 1: Use `SNOWFLAKE.ML.ANOMALY_DETECTION` (covered in the next guide) to flag servicer accounts where numeric metrics (call frequency, forbearance grant rate, average days to first contact) are statistical outliers compared to peer servicers in the same period. Step 2: For servicers flagged as anomalous, use `SNOWFLAKE.CORTEX.COMPLETE()` to summarize the most recent 30 days of servicer notes for those loans, generating a narrative explanation of the anomaly. Step 3: Use `SNOWFLAKE.CORTEX.SENTIMENT()` to aggregate sentiment on borrower communications for flagged servicers — a declining sentiment trend alongside metric anomalies is a stronger signal. Step 4: Combine the anomaly flag, narrative summary, and sentiment trend in a Snowflake Alert that notifies the portfolio oversight team via email or Slack when all three signals align. This pattern avoids needing a separate MLOps platform — the entire pipeline, from data to alert, runs inside Snowflake.

**Q10: What governance controls should you implement when using Cortex LLM functions on loan-level PII data in Snowflake?**

A: Cortex processes data within Snowflake's infrastructure in the same region as your account, which satisfies data residency requirements. Governance controls include: (1) Column-level masking policies — apply dynamic data masking on columns containing SSNs, borrower names, and property addresses so that when a downstream role calls a Cortex function on those columns, they see masked values. This prevents the LLM from receiving raw PII if the calling role does not have clearance. (2) Row access policies — ensure Cortex tasks and pipelines run under service account roles that only see loan records they are authorized to process. (3) Query auditing — all Cortex function calls appear in `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` with the full SQL, enabling audit review. (4) Object tagging — tag columns containing MNPI or PII using Snowflake object tags, then create a policy that restricts those tagged columns from being passed to external functions (note: Cortex is internal, but the principle applies). (5) Cost governance — set Cortex credit budgets at the account or warehouse level using Resource Monitors, and assign Cortex usage to specific cost centers using query tags (`ALTER SESSION SET QUERY_TAG = '{"cost_center":"servicing_analytics"}'`).

---

## Pro Tips

- **Always TRY_PARSE_JSON() on COMPLETE() output.** Even with `temperature=0`, LLMs occasionally return prose around the JSON. Use `TRY_PARSE_JSON()` instead of `PARSE_JSON()` to avoid hard failures; implement a retry or fallback path for null results.
- **Cortex Search is not a SELECT.** You query it via a REST API call or Snowpark SDK — you cannot call it in a SQL SELECT statement. Design your application layer accordingly; use Streamlit in Snowflake for quick prototyping.
- **Use a dedicated warehouse for Cortex tasks.** Cortex LLM functions are I/O-heavy workloads; running them on the same warehouse as analytical queries causes credit contention and query timeouts. A separate X-Small warehouse with `AUTO_SUSPEND = 60` is cost-efficient.
- **Monitor CORTEX_USAGE_HISTORY.** The `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_USAGE_HISTORY` view (available with a latency of up to 3 hours) shows token consumption, model used, and credits charged per query. Set up a daily summary alert if Cortex is a significant cost driver.
- **Cortex Analyst semantic models are version-controlled artifacts.** Store them in your Git repository and deploy via Snowflake CLI. Treat them like dbt model configurations — changes should go through PR review since they affect how the LLM interprets business questions.
- **For high-accuracy extraction, use structured output prompts.** Instructing `COMPLETE()` to return only valid JSON with a specific schema and `temperature=0` dramatically improves parse success rates. Include the word "ONLY" in your instruction: "Return ONLY a JSON object with these keys..."
