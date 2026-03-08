# SQL Server AI & Azure AI Integration

[Back to Index](../index.md)

---

## Overview

Azure AI services extend SQL Server and Azure SQL Database into an intelligent data platform. For a senior data engineer in the US secondary mortgage market, this means enriching loan-level data with machine learning predictions, extracting entities from servicer notes, classifying documents, and detecting anomalies — all without moving data out of the SQL ecosystem. This guide covers the full integration stack: Azure OpenAI via REST, ONNX model scoring inside SQL Server, Azure Cognitive Search for semantic retrieval, and the new vector data type introduced in SQL Server 2025.

---

## Key Concepts at a Glance

| Capability | Technology | SQL Server Version |
|---|---|---|
| Call LLMs via REST | `sp_invoke_external_rest_endpoint` | SQL Server 2022 / Azure SQL |
| Score ML models inline | `PREDICT` + ONNX | SQL Server 2017+ |
| Vector storage & search | `vector` data type | SQL Server 2025 / Azure SQL |
| Semantic search on text | Azure Cognitive Search | Azure SQL + Search indexer |
| Intelligent Query Processing | Adaptive joins, feedback loops | SQL Server 2019+ |
| Cloud ML scoring | Azure ML managed endpoints | Azure SQL |

---

## Azure AI Services Overview

### Cognitive Services Relevant to Mortgage Data

- **Azure OpenAI Service** — GPT-4o, GPT-4, text-embedding-3-large. Use for summarizing servicer notes, extracting structured fields from free-text, generating SQL from natural language.
- **Azure AI Language** — Named entity recognition (NER), key phrase extraction, sentiment analysis. Relevant for borrower communication analysis.
- **Azure Form Recognizer (Document Intelligence)** — Extract structured fields from loan applications, closing disclosures, 1003 forms.
- **Azure AI Search** — Semantic search across document libraries; integrates with SQL via indexers.
- **Azure Machine Learning Studio** — Train, register, and deploy custom models (default risk, prepayment speed) as REST endpoints callable from SQL.

---

## Connecting SQL Server to Azure AI

### Option 1: sp_invoke_external_rest_endpoint (SQL Server 2022+)

SQL Server 2022 introduced native outbound REST calls. No linked server required.

```sql
-- Enable the feature (Azure SQL: enabled by default; on-prem requires sp_configure)
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'Ole Automation Procedures', 1;
RECONFIGURE;

-- Store the Azure OpenAI key securely in a database-scoped credential
CREATE DATABASE SCOPED CREDENTIAL [AzureOpenAICredential]
WITH IDENTITY = 'HTTPEndpointHeaders',
SECRET = '{"api-key":"YOUR_AZURE_OPENAI_KEY"}';

-- Call Azure OpenAI to summarize a servicer note
DECLARE @payload NVARCHAR(MAX);
DECLARE @response NVARCHAR(MAX);
DECLARE @note NVARCHAR(MAX) = (
    SELECT TOP 1 servicer_note
    FROM dbo.loan_servicing_events
    WHERE loan_id = 'L-2024-00134'
    ORDER BY event_date DESC
);

SET @payload = JSON_MODIFY(
    JSON_MODIFY(
        '{"model":"gpt-4o","messages":[]}',
        '$.messages[0].role', 'system'
    ),
    '$.messages[0].content',
    'You are a mortgage data analyst. Summarize the following servicer note in one sentence, focusing on delinquency status and borrower intent.'
);
SET @payload = JSON_MODIFY(@payload, 'append $.messages', JSON_QUERY(
    '{"role":"user","content":"' + REPLACE(@note, '"', '\"') + '"}'
));

EXEC sp_invoke_external_rest_endpoint
    @url = 'https://YOUR_RESOURCE.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-02-01',
    @method = 'POST',
    @credential = [AzureOpenAICredential],
    @payload = @payload,
    @response = @response OUTPUT;

-- Parse the JSON response
SELECT JSON_VALUE(@response, '$.result.choices[0].message.content') AS summary;
```

### Option 2: EXTERNAL DATA SOURCE (PolyBase / REST via Azure Data Factory)

For bulk enrichment workflows, use Azure Data Factory pipelines that read from SQL, call AI services, and write results back. This is preferred for processing millions of loan records.

### Option 3: Linked Server to Azure SQL / Synapse

```sql
-- Create a linked server to Azure SQL Database
EXEC sp_addlinkedserver
    @server = 'AzureSQLProd',
    @srvproduct = '',
    @provider = 'MSOLEDBSQL',
    @datasrc = 'yourserver.database.windows.net',
    @catalog = 'MortgageDB';

EXEC sp_addlinkedsrvlogin
    @rmtsrvname = 'AzureSQLProd',
    @useself = 'FALSE',
    @rmtuser = 'svc_etl',
    @rmtpassword = 'YOUR_PASSWORD';
```

---

## PREDICT Function with ONNX Models

ONNX (Open Neural Network Exchange) lets you train a model anywhere (Python/scikit-learn, PyTorch) and score it inside SQL Server without a Python runtime in the critical path.

### Workflow

1. Train model in Python.
2. Export to ONNX format.
3. Load ONNX binary into SQL Server.
4. Score with `PREDICT`.

```python
# Python: train a prepayment risk classifier and export to ONNX
import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType

# Assume X_train has features: coupon_rate, ltv, fico, loan_age, hpi_change
model = GradientBoostingClassifier(n_estimators=200, max_depth=4)
model.fit(X_train, y_train)

initial_type = [('float_input', FloatTensorType([None, 5]))]
onnx_model = convert_sklearn(model, initial_types=initial_type)

with open('prepayment_model.onnx', 'wb') as f:
    f.write(onnx_model.SerializeToString())
```

```sql
-- Load ONNX model into SQL Server
CREATE TABLE dbo.ml_models (
    model_id    INT IDENTITY PRIMARY KEY,
    model_name  NVARCHAR(100) NOT NULL,
    model_data  VARBINARY(MAX) NOT NULL,
    created_at  DATETIME2 DEFAULT SYSUTCDATETIME()
);

-- Load via OPENROWSET or from file share
INSERT INTO dbo.ml_models (model_name, model_data)
SELECT 'prepayment_risk_v3', bulkcolumn
FROM OPENROWSET(BULK 'C:\models\prepayment_model.onnx', SINGLE_BLOB) AS b;

-- Score loans using PREDICT
SELECT
    l.loan_id,
    l.coupon_rate,
    l.current_ltv,
    l.fico_score,
    l.loan_age_months,
    l.hpi_change_12m,
    p.variable_out0 AS prepayment_probability
FROM dbo.active_loans AS l
CROSS APPLY PREDICT(
    MODEL = (SELECT TOP 1 model_data FROM dbo.ml_models WHERE model_name = 'prepayment_risk_v3'),
    DATA = l,
    RUNTIME = ONNX
) WITH (variable_out0 FLOAT) AS p
WHERE l.pool_id = 'FN-2024-C0045';
```

---

## Storing and Retrieving Vectors (SQL Server 2025 / Azure SQL)

SQL Server 2025 adds a native `vector` data type and vector distance functions, enabling semantic search directly in T-SQL.

```sql
-- Create table with vector embeddings for loan documents
CREATE TABLE dbo.loan_document_embeddings (
    doc_id          BIGINT IDENTITY PRIMARY KEY,
    loan_id         NVARCHAR(20) NOT NULL,
    doc_type        NVARCHAR(50) NOT NULL,  -- '1003', 'servicer_note', 'appraisal'
    doc_text        NVARCHAR(MAX) NOT NULL,
    embedding       VECTOR(1536) NOT NULL,  -- text-embedding-3-small dimension
    created_at      DATETIME2 DEFAULT SYSUTCDATETIME()
);

-- Create a vector index for ANN search
CREATE INDEX ix_loan_doc_vector
ON dbo.loan_document_embeddings (embedding)
USING VECTOR_ANN
WITH (metric = 'cosine');

-- Generate embedding for a query via Azure OpenAI, then find similar documents
DECLARE @query_text NVARCHAR(500) = 'borrower requested loan modification due to hardship';
DECLARE @query_vector VECTOR(1536);

-- (In practice: call sp_invoke_external_rest_endpoint to get embedding, parse JSON, cast to VECTOR)
-- Semantic similarity search
SELECT TOP 10
    loan_id,
    doc_type,
    LEFT(doc_text, 200) AS doc_preview,
    VECTOR_DISTANCE('cosine', embedding, @query_vector) AS cosine_distance
FROM dbo.loan_document_embeddings
ORDER BY cosine_distance ASC;
```

---

## JSON-Based AI Response Parsing in T-SQL

Azure AI services return JSON. SQL Server's JSON functions are essential for extraction.

```sql
-- Parse complex Azure OpenAI structured output
DECLARE @ai_response NVARCHAR(MAX) = '{
  "choices": [{
    "message": {
      "content": "{\"delinquency_status\": \"60-day\", \"borrower_intent\": \"reinstatement\", \"risk_score\": 72, \"key_dates\": [\"2024-11-15\", \"2024-12-01\"]}"
    }
  }]
}';

-- Extract nested JSON content (the model returned JSON-in-JSON)
DECLARE @inner_json NVARCHAR(MAX) =
    JSON_VALUE(@ai_response, '$.choices[0].message.content');

SELECT
    JSON_VALUE(@inner_json, '$.delinquency_status')  AS delinquency_status,
    JSON_VALUE(@inner_json, '$.borrower_intent')     AS borrower_intent,
    CAST(JSON_VALUE(@inner_json, '$.risk_score') AS INT) AS risk_score,
    key_date.value                                   AS key_date
FROM OPENJSON(@inner_json, '$.key_dates') AS key_date;
```

---

## Azure Machine Learning Integration

```sql
-- Score using an Azure ML managed online endpoint
-- Store endpoint URL and key as database-scoped credential
CREATE DATABASE SCOPED CREDENTIAL [AzureMLEndpointCred]
WITH IDENTITY = 'HTTPEndpointHeaders',
SECRET = '{"Authorization":"Bearer YOUR_AML_KEY"}';

-- Batch score a pool of loans
DECLARE @batch_payload NVARCHAR(MAX);

SELECT @batch_payload = (
    SELECT
        loan_id,
        coupon_rate,
        current_ltv,
        fico_score,
        loan_age_months,
        dti_ratio,
        property_state
    FROM dbo.active_loans
    WHERE pool_id = 'FN-2024-C0045'
    FOR JSON PATH, ROOT('data')
);

DECLARE @ml_response NVARCHAR(MAX);
EXEC sp_invoke_external_rest_endpoint
    @url = 'https://YOUR_ML_ENDPOINT.azureml.net/score',
    @method = 'POST',
    @credential = [AzureMLEndpointCred],
    @payload = @batch_payload,
    @response = @ml_response OUTPUT;

-- Parse and store predictions
INSERT INTO dbo.loan_ml_scores (loan_id, model_name, score, scored_at)
SELECT
    JSON_VALUE(pred.[value], '$.loan_id'),
    'default_risk_v5',
    CAST(JSON_VALUE(pred.[value], '$.default_probability') AS FLOAT),
    SYSUTCDATETIME()
FROM OPENJSON(@ml_response, '$.result.predictions') AS pred;
```

---

## Azure Cognitive Search Integration

Azure AI Search can index SQL Server tables and enable full semantic/vector search over loan documents.

```sql
-- Table optimized for Cognitive Search indexing
CREATE TABLE dbo.servicer_notes_search (
    note_id         BIGINT IDENTITY PRIMARY KEY,
    loan_id         NVARCHAR(20) NOT NULL,
    note_date       DATE NOT NULL,
    note_text       NVARCHAR(MAX) NOT NULL,
    note_category   NVARCHAR(50),
    -- Computed columns for search facets
    note_year       AS YEAR(note_date) PERSISTED,
    note_quarter    AS CONCAT('Q', DATEPART(QUARTER, note_date), '-', YEAR(note_date)) PERSISTED,
    -- Change tracking for incremental indexing
    row_version     ROWVERSION NOT NULL
);

-- Enable change tracking for incremental Cognitive Search indexing
ALTER DATABASE MortgageDB SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 7 DAYS);
ALTER TABLE dbo.servicer_notes_search ENABLE CHANGE_TRACKING;
```

---

## Classifying Loan Documents with Azure AI (End-to-End Pattern)

```sql
-- Stored procedure: classify and enrich a batch of incoming loan documents
CREATE OR ALTER PROCEDURE dbo.usp_classify_loan_documents
    @batch_size INT = 100
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @credential_name SYSNAME = 'AzureOpenAICredential';
    DECLARE @endpoint NVARCHAR(500) =
        'https://YOUR_RESOURCE.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-02-01';

    -- Process unclassified documents in batches
    DECLARE doc_cursor CURSOR FAST_FORWARD FOR
        SELECT doc_id, doc_text
        FROM dbo.loan_documents
        WHERE classification IS NULL
        AND doc_text IS NOT NULL
        ORDER BY created_at
        OFFSET 0 ROWS FETCH NEXT @batch_size ROWS ONLY;

    DECLARE @doc_id BIGINT, @doc_text NVARCHAR(MAX);
    DECLARE @payload NVARCHAR(MAX), @response NVARCHAR(MAX), @classification NVARCHAR(50);

    OPEN doc_cursor;
    FETCH NEXT FROM doc_cursor INTO @doc_id, @doc_text;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @payload = '{
          "model": "gpt-4o",
          "messages": [
            {"role":"system","content":"Classify this mortgage document as exactly one of: URLA_1003, APPRAISAL, TITLE_COMMITMENT, CLOSING_DISCLOSURE, SERVICER_NOTE, LOSS_MITIGATION, OTHER. Return only the classification label."},
            {"role":"user","content":"' + REPLACE(LEFT(@doc_text, 2000), '"', '\"') + '"}
          ],
          "max_tokens": 20,
          "temperature": 0
        }';

        EXEC sp_invoke_external_rest_endpoint
            @url = @endpoint,
            @method = 'POST',
            @credential = [AzureOpenAICredential],
            @payload = @payload,
            @response = @response OUTPUT;

        SET @classification = LTRIM(RTRIM(
            JSON_VALUE(@response, '$.result.choices[0].message.content')
        ));

        UPDATE dbo.loan_documents
        SET classification = @classification, classified_at = SYSUTCDATETIME()
        WHERE doc_id = @doc_id;

        FETCH NEXT FROM doc_cursor INTO @doc_id, @doc_text;
    END;

    CLOSE doc_cursor;
    DEALLOCATE doc_cursor;
END;
```

---

## Azure Synapse Analytics + ML

For large-scale scoring across MBS pools, Synapse Dedicated SQL Pool integrates with Azure ML via the `PREDICT` function (same ONNX pattern) and Synapse Pipelines for orchestration.

```sql
-- Synapse: score entire pool with ONNX model stored in Azure ML
-- Model must be registered in the Synapse workspace linked service
SELECT
    loan_id,
    pool_id,
    p.predicted_cpr AS predicted_cpr_3m
FROM dbo.active_loans_dist  -- Synapse distributed table
CROSS APPLY PREDICT(
    MODEL = 'prepayment_forecast_model',  -- references Synapse ML model registry
    DATA = dbo.active_loans_dist
) WITH (predicted_cpr FLOAT) AS p;
```

---

## Interview Q&A

**Q1: How do you call Azure OpenAI from within a SQL Server stored procedure, and what are the security considerations?**

A: SQL Server 2022 introduced `sp_invoke_external_rest_endpoint`, which makes outbound HTTPS calls to any REST API. You store the API key in a `DATABASE SCOPED CREDENTIAL` using the `HTTPEndpointHeaders` identity type, which prevents the key from appearing in plain text in procedure code. On-premises SQL Server also requires enabling `Ole Automation Procedures` via `sp_configure`. Security considerations include: network egress rules (the SQL Server agent/service account must reach the Azure OpenAI endpoint — typically via a private endpoint or service endpoint on Azure SQL), secret rotation (credential must be updated when the key rotates), logging (consider a wrapper procedure that logs all AI calls to an audit table), and PII handling (loan data sent to OpenAI must comply with your data use agreements and any MNPI/PII redaction requirements common in secondary mortgage workflows).

**Q2: What is the PREDICT function and how does ONNX model scoring differ from Python extensibility?**

A: `PREDICT` is a T-SQL function that scores a pre-trained ML model against a rowset inline, without invoking the Python or R extensibility framework at runtime. The model must be in ONNX format and stored as a `VARBINARY(MAX)` value in SQL Server. The key advantage over Python extensibility (`sp_execute_external_script`) is that `PREDICT` runs entirely inside the SQL process — no external process launch, no serialization of data to/from a Python session. This means lower latency (sub-millisecond for simple models), no dependency on the Launchpad service, and ability to use it in views and inline TVFs. The tradeoff is that only ONNX-compatible model types are supported (no arbitrary Python logic). For mortgage use cases, this is ideal for scoring default risk or prepayment speed on incoming loan events in real time.

**Q3: How does the new `vector` data type in SQL Server 2025 enable RAG (Retrieval-Augmented Generation) patterns?**

A: The `vector` data type stores fixed-dimension floating-point arrays (up to 1998 dimensions) and the `VECTOR_DISTANCE` function computes cosine, dot product, or Euclidean distance natively. For RAG in a mortgage context: (1) generate embeddings for all servicer notes and loan documents using Azure OpenAI `text-embedding-3-small` or `text-embedding-3-large`; (2) store embeddings in a `vector` column; (3) create a `VECTOR_ANN` index for approximate nearest neighbor search; (4) at query time, embed the user's question, call `VECTOR_DISTANCE` to retrieve the top-K most relevant documents, and pass those documents plus the question to GPT-4o via `sp_invoke_external_rest_endpoint`. This pattern lets analysts query loan histories in natural language without a separate vector database, keeping all data in the SQL governance boundary.

**Q4: How do you handle large-scale document enrichment (e.g., 10 million servicer notes) with Azure AI when cursor-based approaches are too slow?**

A: Cursor-based enrichment is a prototype pattern, not a production one. For 10M records, use Azure Data Factory (ADF) or Synapse Pipelines: (1) configure a SQL source activity reading in partitioned batches by date or loan ID range; (2) call the AI service via an ADF Web Activity or Azure Function activity; (3) write results back via a SQL sink activity. For even higher throughput, use Azure Databricks with the Azure OpenAI Python SDK, which supports async concurrent calls with retry/backoff, achieving thousands of enrichments per second. Store results in a staging table in SQL Server and merge into the production table. Always include a `processed_flag` or `enriched_at` timestamp so pipelines are idempotent.

**Q5: What is Intelligent Query Processing in Azure SQL and how does it relate to AI?**

A: Intelligent Query Processing (IQP) is a suite of adaptive optimizations in the SQL Server query processor, not AI in the traditional sense, but it uses feedback loops and statistical learning. Key features include: Adaptive Memory Grant Feedback (adjusts memory grants between executions based on actual usage — eliminates the classic "tempdb spill" problem on large hash joins); Adaptive Join (switches between hash and nested loops at runtime based on actual cardinality); Parameter Sensitivity Plan optimization (SQL 2022 — generates multiple plans for a single query to handle parameter sniffing); and Degree of Parallelism feedback. In Azure SQL, these are on by default under the latest database compatibility level (160). The connection to AI is that Intelligent Query Processing shares the feedback-loop philosophy with ML; future versions are expected to use learned cost models trained on workload history.

**Q6: Walk through how you would set up a pipeline to extract named entities (borrower name, loan number, property address) from unstructured servicer notes at scale.**

A: The pipeline has four layers. (1) Extraction: schedule an ADF pipeline (or Synapse Pipeline) that reads servicer notes added in the last 24 hours from `dbo.servicer_notes`. (2) AI enrichment: call Azure AI Language's NER endpoint in batches of 5 (the API's per-document limit) using an ADF ForEach activity or Azure Function. The NER endpoint returns a JSON array of entity spans with category labels (`Person`, `Location`, `Quantity`, etc.). (3) Parsing and storage: an Azure Function parses the NER JSON response and inserts rows into `dbo.servicer_note_entities` (columns: `note_id`, `entity_text`, `entity_category`, `confidence_score`, `char_offset`). (4) Downstream use: a view joins `servicer_notes` to `servicer_note_entities` so analysts can query "find all notes mentioning a specific address" or "find notes with borrower names that don't match the loan record" — the latter being a data quality signal relevant to MERS reconciliation.

**Q7: What are the cost implications of calling Azure OpenAI from SQL Server for every loan event, and how do you manage them?**

A: Azure OpenAI pricing is per token (input + output), and GPT-4o at $5/1M input tokens can get expensive fast. Cost management strategies: (1) Use the smallest model that meets accuracy requirements — `gpt-4o-mini` at $0.15/1M input tokens for classification tasks; reserve GPT-4o for complex summarization. (2) Implement a caching layer — store the embedding or AI result in SQL with a hash of the input text as the cache key; avoid re-calling the API for identical or near-identical text. (3) Batch rather than real-time: most enrichment use cases tolerate a 1-hour delay; batch 10K records per call using array inputs rather than one record per call. (4) Set `max_tokens` tightly in the payload — for classification returning a single label, `max_tokens=20` prevents the model from generating long responses. (5) Implement a circuit breaker in the stored procedure that checks a configuration table for a `disable_ai_calls` flag, allowing cost control without code deployment.

**Q8: How do you handle schema changes in Azure OpenAI JSON responses gracefully in T-SQL?**

A: JSON_VALUE returns NULL rather than throwing an error when a path does not exist, which is actually helpful for graceful degradation. Defensive patterns include: (1) Always check `JSON_VALUE(@response, '$.error.code') IS NULL` before parsing results — Azure OpenAI returns an error object when rate-limited or when content is filtered. (2) Use `ISNULL(JSON_VALUE(...), 'UNKNOWN')` for optional fields. (3) Store the raw JSON response in an audit column (`raw_ai_response NVARCHAR(MAX)`) alongside parsed fields — this lets you re-parse without re-calling the API when the parsing logic changes. (4) Use `OPENJSON` with an explicit `WITH` clause for strongly-typed parsing of arrays; this makes schema expectations explicit and fails loudly when structure changes. (5) Wrap AI calls in TRY/CATCH blocks and log failures to an `ai_call_errors` table with the full payload and response for debugging.

**Q9: Describe a real-world scenario where you would use Azure Cognitive Search alongside SQL Server for mortgage data.**

A: Servicer portfolio managers often need to search thousands of loss mitigation notes to find loans with similar hardship circumstances (e.g., "medical emergency with job loss in California"). A traditional `LIKE '%medical%'` query misses synonyms and context. The solution: (1) Create an Azure AI Search index with SQL Server as the data source, using an indexer that runs hourly. (2) Enable semantic ranking (L2 reranking using a transformer model hosted by Microsoft) and vector search (embed each note using Azure OpenAI and store the embedding in the index). (3) Application queries the Search index's REST API rather than SQL directly for the discovery use case. (4) Search returns loan IDs ranked by semantic similarity; the application then queries SQL Server for full loan data using those IDs. This hybrid pattern leverages SQL for transactional integrity and joins while delegating full-text semantic ranking to the purpose-built search service.

**Q10: What are the governance and compliance considerations for using Azure AI on mortgage loan data?**

A: Secondary mortgage market data is subject to MNPI rules, GLBA, FCRA, and investor data use restrictions. Key governance controls: (1) PII/MNPI redaction before sending data to Azure OpenAI — use Azure AI Language's PII detection API or regex-based masking to remove SSNs, names, and addresses before they leave the network perimeter; alternatively, use Azure OpenAI within a virtual network with private endpoints so data never traverses the public internet. (2) Data residency — confirm Azure OpenAI deployment is in a US region to satisfy data residency requirements. (3) Opt-out of model training — ensure Microsoft's Data Protection Addendum is in place; Azure OpenAI does not use customer data to train models by default, but this must be contractually confirmed. (4) Audit logging — log every AI call (timestamp, user/service principal, input hash, output) to an immutable audit table or Azure Monitor Log Analytics. (5) Model explainability — for any ONNX model used in credit decisions, maintain SHAP value documentation to satisfy fair lending examination requirements under ECOA/Reg B.

---

## Pro Tips

- **Test REST calls with Azure CLI first.** Before embedding `sp_invoke_external_rest_endpoint` in a procedure, validate the exact JSON payload and response structure using `curl` or the Azure OpenAI Playground. Debugging malformed JSON inside T-SQL is painful.
- **Store model versions.** Add a `model_version` and `model_name` column to every table that receives AI-generated scores. You will need to re-score with updated models and the audit trail is essential.
- **Use ONNX for latency-sensitive paths.** If a default risk score must be computed during a loan origination INSERT trigger (rare but real in some pipelines), ONNX `PREDICT` is the only viable option — Python extensibility adds 50-200ms per call.
- **Rate limit awareness.** Azure OpenAI has per-minute token limits. Build exponential backoff into any stored procedure that loops over records; check `JSON_VALUE(@response, '$.error.code') = '429'` and `WAITFOR DELAY` before retrying.
- **Vector index maintenance.** The `VECTOR_ANN` index in SQL Server 2025 requires periodic reorganization as embeddings are inserted. Include it in your index maintenance job, but be aware it has different fragmentation semantics than B-tree indexes.
- **Semantic kernel integration.** For complex agentic workflows (e.g., automated underwriting assistant), consider Microsoft Semantic Kernel or LangChain with a SQL Server plugin rather than pure T-SQL orchestration. T-SQL is ideal for enrichment pipelines; agent frameworks are better for multi-step reasoning workflows.
