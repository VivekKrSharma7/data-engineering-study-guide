# AI in Data Engineering - Quick Reference & Essential Q&A

[Back to Summary Index](README.md)

---

> **Purpose:** Dense, study-ready reference covering AI topics relevant to data engineering -- LLMs, GenAI, vector databases, RAG, prompt engineering, AI APIs, agents, and AI applied to financial/mortgage data. Traditional ML basics (scikit-learn, supervised/unsupervised fundamentals, Spark MLlib, TensorFlow/PyTorch) are intentionally excluded.

---

## 1. LLMs & Transformers

### Key Highlights
- **Transformer architecture** (2017, "Attention Is All You Need"): encoder-decoder with self-attention; replaced RNNs/LSTMs for sequence tasks
- **Self-attention** lets each token attend to every other token in a sequence -- O(n^2) complexity with sequence length
- **Multi-head attention**: runs multiple attention computations in parallel, each learning different relationships
- **Positional encoding**: sinusoidal or learned embeddings added to input tokens since transformers have no inherent sense of order
- **Model families**: encoder-only (BERT -- classification, NER), decoder-only (GPT -- generation), encoder-decoder (T5 -- translation, summarization)
- **Context windows**: GPT-4o ~128K tokens, Claude 3.5/4 ~200K tokens, Gemini 1.5 Pro ~2M tokens, Llama 3 ~128K, Mistral Large ~128K
- **Tokenization**: BPE (GPT), SentencePiece (Llama/T5), WordPiece (BERT); ~1 token = ~4 English characters; ~0.75 words per token
- **Major open models**: Llama 3.1 (8B/70B/405B), Mistral Large 2, Snowflake Arctic (480B MoE, 128 experts, 17B active), Phi-3, Gemma 2
- **Inference parameters**: `temperature` (0 = deterministic, 1 = creative), `top_p` (nucleus sampling, 0.9 typical), `top_k`, `max_tokens`, `stop` sequences

### Essential Q&A

**Q: How does the attention mechanism work?**
A: Computes Query, Key, Value matrices from input. Attention score = softmax(QK^T / sqrt(d_k)) * V. High scores mean strong relevance between token pairs. Multi-head attention runs this in parallel across h heads (typically 8-96), each with dimension d_model/h.

**Q: Why are decoder-only models dominant for generation?**
A: Causal (left-to-right) masking naturally fits autoregressive text generation. Pre-training on next-token prediction scales efficiently. GPT, Claude, Llama, and Mistral are all decoder-only.

**Q: What is the MoE (Mixture of Experts) architecture?**
A: Routes each token to a subset of expert networks via a gating function. Snowflake Arctic uses 480B total parameters but only activates ~17B per token (128 experts, top-2 routing). Benefit: large model capacity with lower inference cost.

**Q: How does temperature affect output for data engineering tasks?**
A: Use temperature=0 for deterministic tasks (SQL generation, schema extraction, data validation). Use 0.3-0.7 for creative tasks (documentation generation). Temperature=1.0+ introduces randomness, unsuitable for structured output.

**Q: What is KV-cache and why does it matter?**
A: During autoregressive generation, Key and Value tensors from previous tokens are cached to avoid recomputation. Reduces generation from O(n^2) to O(n) per new token. Memory-bound -- a 70B model with 128K context can need 40+ GB just for KV-cache.

**Q: How do context windows affect data engineering workflows?**
A: Larger contexts allow processing entire schemas, documentation sets, or log files in a single prompt. Claude's 200K window can hold ~500 pages of text. But cost scales linearly with tokens, and "lost in the middle" effect can reduce accuracy for information buried in long contexts.

---

## 2. Generative AI & Foundation Models

### Key Highlights
- **Foundation model**: large model pre-trained on broad data, adapted via fine-tuning or prompting for downstream tasks
- **Open vs closed**: closed (GPT-4o, Claude, Gemini) -- API-only, no weight access; open (Llama, Mistral, Arctic) -- downloadable weights, self-hostable
- **Model sizes**: small (1-7B, edge/local), medium (13-70B, good quality/cost), large (100B+, highest capability)
- **Snowflake Cortex LLM functions** (serverless, no infra management):
  - `COMPLETE(model, prompt)` -- general-purpose generation
  - `SUMMARIZE(text)` -- text summarization
  - `SENTIMENT(text)` -- returns sentiment score [-1, 1]
  - `TRANSLATE(text, source_lang, target_lang)`
  - `EXTRACT_ANSWER(text, question)` -- extractive QA
- **Azure OpenAI**: enterprise GPT deployment with data residency, VNet integration, content filtering, RBAC; same API as OpenAI with Azure-specific auth
- **Quantization**: reduces model precision (FP16 -> INT8 -> INT4) for smaller size and faster inference with modest quality loss; GGUF format for llama.cpp, GPTQ/AWQ for GPU inference

### Essential Q&A

**Q: When should you use Snowflake Cortex vs. external AI APIs?**
A: Use Cortex when data is already in Snowflake (no data movement), you need governance/RBAC on AI calls, or want pay-per-query pricing. Use external APIs for latest models, custom fine-tuned models, or capabilities Cortex doesn't offer (vision, advanced function calling).

**Q: Show a Snowflake Cortex example for processing loan data.**
```sql
-- Sentiment analysis on borrower communications
SELECT loan_id,
       SNOWFLAKE.CORTEX.SENTIMENT(borrower_notes) AS sentiment_score,
       SNOWFLAKE.CORTEX.SUMMARIZE(borrower_notes) AS summary
FROM loan_servicing.communications
WHERE communication_date >= DATEADD('day', -7, CURRENT_DATE());

-- Extract specific answers from unstructured loan documents
SELECT doc_id,
       SNOWFLAKE.CORTEX.EXTRACT_ANSWER(doc_text, 'What is the loan amount?') AS loan_amount,
       SNOWFLAKE.CORTEX.EXTRACT_ANSWER(doc_text, 'What is the interest rate?') AS rate
FROM loan_documents;
```

**Q: What is the difference between fine-tuning and RAG?**
A: Fine-tuning modifies model weights on domain data -- expensive, needs retraining for updates, best for style/format changes. RAG retrieves relevant documents at query time -- cheaper, updates instantly with new data, best for knowledge-grounded answers. For mortgage data, RAG is typically preferred (regulations change frequently).

**Q: How does Azure OpenAI differ from OpenAI direct?**
A: Same models, but Azure adds: data residency (choose region), VNet/private endpoint support, Azure AD auth, content safety filters, SLA guarantees, and integration with Azure services. Required for regulated industries like finance.

**Q: What are the cost considerations for LLM APIs?**
A: Priced per 1K/1M tokens (input + output). GPT-4o: ~$2.50/$10 per 1M input/output tokens. Claude 3.5 Sonnet: ~$3/$15. Strategies: prompt caching (Claude), batch API (50% discount, 24h turnaround), smaller models for simple tasks, caching repeated queries.

---

## 3. Vector Databases & Embeddings

### Key Highlights
- **Embeddings**: dense numerical vectors capturing semantic meaning; similar concepts have nearby vectors
- **Common dimensions**: 384 (MiniLM), 768 (BERT-base, Snowflake arctic-embed), 1024 (Cohere), 1536 (OpenAI text-embedding-3-small), 3072 (text-embedding-3-large)
- **Embedding models**: OpenAI text-embedding-3-small/large, Sentence-BERT (all-MiniLM-L6-v2), Cohere embed-v3, Snowflake arctic-embed (open source, top-ranked)
- **Vector databases**: pgvector (PostgreSQL extension), Pinecone (managed), Weaviate (open source), Chroma (lightweight/local), Milvus, Qdrant
- **Snowflake VECTOR data type**: native vector storage, `VECTOR_COSINE_SIMILARITY()`, `VECTOR_L2_DISTANCE()`, `VECTOR_INNER_PRODUCT()`
- **Similarity metrics**: cosine similarity (direction, most common), dot product (magnitude-aware), Euclidean/L2 distance (absolute distance)
- **ANN algorithms**: HNSW (graph-based, fast query, high memory), IVF (partition-based, memory-efficient), Product Quantization (compressed vectors)
- **Hybrid search**: combines vector similarity with keyword (BM25) search for better recall

### Essential Q&A

**Q: How do you create and query vectors in Snowflake?**
```sql
-- Create table with vector column
CREATE TABLE document_embeddings (
    doc_id INT,
    content TEXT,
    embedding VECTOR(FLOAT, 768)  -- 768 dimensions
);

-- Similarity search
SELECT doc_id, content,
       VECTOR_COSINE_SIMILARITY(embedding, :query_vector) AS similarity
FROM document_embeddings
ORDER BY similarity DESC
LIMIT 10;
```

**Q: How do you use pgvector in SQL Server environments?**
A: SQL Server 2025 introduces a native VECTOR data type (up to 8,000 dimensions) with `VECTOR_DISTANCE()` function. For earlier versions, use Azure PostgreSQL with pgvector or a standalone vector DB alongside SQL Server.
```sql
-- SQL Server 2025 vector support
CREATE TABLE doc_vectors (
    id INT PRIMARY KEY,
    content NVARCHAR(MAX),
    embedding VECTOR(1536)
);

SELECT TOP 10 id, content,
       VECTOR_DISTANCE('cosine', embedding, @query_vector) AS distance
FROM doc_vectors
ORDER BY distance;
```

**Q: When would you choose cosine vs. dot product similarity?**
A: Cosine similarity normalizes for vector magnitude -- best when you care about directional similarity regardless of document length. Dot product captures both direction and magnitude -- useful when vector norms carry meaning (e.g., document importance). Most RAG systems use cosine.

**Q: What is HNSW and why is it preferred?**
A: Hierarchical Navigable Small World -- a graph-based ANN index. Builds a multi-layer proximity graph. O(log n) query time with 95%+ recall. Tradeoff: high memory (stores graph in RAM) and slower index builds. Parameters: `M` (connections per node, 16 typical), `ef_construction` (build quality, 200 typical), `ef_search` (query quality).

**Q: How do you choose embedding dimensions?**
A: Higher dimensions capture more nuance but cost more storage/compute. 384 for fast prototyping, 768-1024 for production balance, 1536-3072 for maximum quality. OpenAI's text-embedding-3 supports Matryoshka (truncatable) embeddings -- generate at 3072 but store at 256/512/1024 with graceful quality degradation.

**Q: How do you generate embeddings with Python?**
```python
from openai import OpenAI
client = OpenAI()

response = client.embeddings.create(
    model="text-embedding-3-small",
    input=["Loan prepayment risk factors include interest rates and borrower credit"],
    dimensions=768  # Matryoshka truncation
)
vector = response.data[0].embedding  # List of 768 floats
```

---

## 4. RAG Architecture

### Key Highlights
- **RAG (Retrieval-Augmented Generation)**: retrieve relevant documents, inject into LLM context, generate grounded answers
- **Pipeline**: Query -> Embed -> Retrieve (vector search) -> Rerank -> Augment prompt -> Generate
- **Chunking strategies**: fixed-size (512-1024 tokens with overlap), semantic (split on topic boundaries), recursive character splitting, document-structure-aware (headers, sections)
- **Chunk overlap**: 10-20% overlap prevents losing context at boundaries
- **Advanced RAG techniques**:
  - **HyDE** (Hypothetical Document Embeddings): generate a hypothetical answer, embed it, search with that embedding
  - **Multi-query**: rewrite user query into multiple perspectives, retrieve for each, merge results
  - **Parent-child chunking**: retrieve small chunks, return parent (larger) chunks for context
  - **Reranking**: use a cross-encoder (e.g., Cohere rerank, BGE-reranker) to rescore top-K results
- **Snowflake Cortex Search**: managed RAG service -- index text data, query with natural language, handles chunking/embedding/retrieval automatically
- **Evaluation (RAGAS)**: Faithfulness (is answer supported by context?), Answer Relevancy, Context Precision, Context Recall

### Essential Q&A

**Q: Describe a RAG architecture for mortgage document Q&A.**
A: 1) Ingest loan docs (PDFs/MISMO XML) -> extract text -> chunk by section (appraisal, income, credit). 2) Embed chunks with domain-tuned model. 3) Store in vector DB with metadata (loan_id, doc_type, date). 4) At query time: embed question, retrieve top-10 chunks filtered by metadata, rerank to top-3, inject into prompt with system instructions for compliance. 5) LLM generates answer with citations.

**Q: How does Snowflake Cortex Search work?**
```sql
-- Create a search service
CREATE CORTEX SEARCH SERVICE loan_doc_search
  ON doc_text
  ATTRIBUTES doc_type, loan_id
  WAREHOUSE = compute_wh
  TARGET_LAG = '1 hour'
  AS (
    SELECT doc_text, doc_type, loan_id, created_date
    FROM loan_documents
    WHERE status = 'ACTIVE'
  );

-- Query from Python (Snowpark)
from snowflake.core import Root
search_service = Root(session).databases["mydb"].schemas["myschema"] \
    .cortex_search_services["loan_doc_search"]
results = search_service.search(
    query="What are the DTI requirements for conventional loans?",
    columns=["doc_text", "doc_type"],
    filter={"@eq": {"doc_type": "GUIDELINE"}},
    limit=5
)
```

**Q: RAG vs. fine-tuning vs. long context -- when to use each?**
A: **RAG**: best for large/changing knowledge bases, need source citations, data stays in your control. **Fine-tuning**: best for teaching style/format/domain jargon, not for factual knowledge (hallucination risk). **Long context**: best for small document sets (<100 pages) where full context fits; simpler but expensive per query and no persistent index.

**Q: What chunking strategy works best for structured financial documents?**
A: Use document-structure-aware chunking: split on headers/sections from MISMO XML or PDF structure. Keep related fields together (e.g., all borrower income data in one chunk). Add metadata (section type, loan ID) to chunks. Typical chunk size: 512-1024 tokens with 10% overlap. For tables, keep entire table in one chunk.

**Q: How do you evaluate RAG quality?**
A: Use RAGAS framework: **Faithfulness** (0-1, does answer match retrieved context -- catches hallucination), **Answer Relevancy** (does answer address the question), **Context Precision** (are retrieved docs relevant), **Context Recall** (were all needed docs retrieved). Target: faithfulness > 0.9 for financial applications.

**Q: What are common RAG failure modes?**
A: 1) Retrieval miss -- relevant docs not retrieved (fix: better chunking, hybrid search). 2) Context overflow -- too many chunks dilute signal (fix: reranking). 3) Hallucination despite context -- LLM ignores retrieved docs (fix: structured prompts, lower temperature). 4) Stale data -- embeddings not refreshed (fix: incremental indexing pipelines).

---

## 5. Prompt Engineering

### Key Highlights
- **Zero-shot**: task instruction only, no examples
- **One-shot / Few-shot**: include 1 or 3-5 examples in prompt; dramatically improves structured output accuracy
- **Chain-of-thought (CoT)**: "Let's think step by step" or explicit reasoning steps; improves complex reasoning by 20-40%
- **System vs user prompts**: system sets persona/rules (persistent), user provides the specific request
- **Structured output**: request JSON with schema, use `response_format={"type": "json_object"}` in OpenAI API
- **Text-to-SQL**: provide schema DDL + sample data + business glossary in prompt; few-shot examples of similar queries dramatically improve accuracy
- **DSPy**: framework that optimizes prompts programmatically using metrics; replaces manual prompt engineering with compiled "programs"

### Essential Q&A

**Q: Show a text-to-SQL prompt pattern for mortgage data.**
```python
system_prompt = """You are a SQL expert for a mortgage data warehouse on Snowflake.

Schema:
- LOANS(loan_id, origination_date, upb, note_rate, ltv, dti, fico,
        property_state, loan_purpose, occupancy_type)
- PERFORMANCE(loan_id, reporting_period, current_upb, delinquency_status,
              prepayment_flag, default_flag)
- SECURITIES(pool_id, cusip, coupon_rate, original_balance, factor)

Rules:
- Use Snowflake SQL syntax
- Always qualify columns with table aliases
- Use CURRENT_DATE() not GETDATE()
- UPB means Unpaid Principal Balance
- CPR = Conditional Prepayment Rate (annualized)
- CDR = Conditional Default Rate (annualized)

Example:
Q: What is the average FICO by state for 2024 originations?
SQL: SELECT property_state, AVG(fico) AS avg_fico
     FROM loans WHERE YEAR(origination_date) = 2024
     GROUP BY property_state ORDER BY avg_fico DESC;
"""
```

**Q: How does chain-of-thought help data engineering tasks?**
A: For complex queries: "First identify which tables are needed. Then determine join conditions. Then apply filters. Finally, compute aggregations." This reduces errors in multi-table joins, complex CTEs, and window functions. For debugging: "Analyze the error message, identify the root cause, propose the fix."

**Q: What is DSPy and why is it relevant to data engineers?**
A: DSPy treats prompts as programs with typed signatures (e.g., `question -> sql_query`). It automatically optimizes prompts using training examples and metrics (e.g., SQL execution accuracy). Eliminates brittle manual prompt engineering. Useful for building reliable text-to-SQL pipelines.

**Q: How do you ensure consistent JSON output from LLMs?**
A: 1) Use `response_format={"type": "json_schema", "json_schema": {...}}` (OpenAI structured outputs -- guarantees valid JSON matching schema). 2) Provide explicit JSON schema in prompt. 3) Use few-shot examples with the exact JSON structure. 4) For Claude, use tool_use with input_schema for structured extraction.

**Q: What are effective prompt patterns for data quality tasks?**
A: **Validation**: "Given this record: {data}. Check against these rules: {rules}. Return JSON with field_name, is_valid, reason." **Classification**: "Classify this loan document into one of: [APPRAISAL, INCOME_VERIFICATION, CREDIT_REPORT, TITLE, CLOSING]. Return only the category name." **Extraction**: "Extract these fields from the text: borrower_name, property_address, loan_amount. Return as JSON. If a field is not found, use null."

---

## 6. AI APIs & Integration

### Key Highlights
- **OpenAI API**: chat completions (`/v1/chat/completions`), embeddings, function calling (structured tool use), batch API (50% cost reduction), assistants API (stateful with threads)
- **Claude API**: messages API, 200K context window, tool use (function calling), vision (image analysis), prompt caching (90% cost reduction on cached prefixes), extended thinking
- **Azure OpenAI**: same API as OpenAI, Azure AD auth, private endpoints, content filters, region selection for data residency
- **Amazon Bedrock**: multi-model access (Claude, Llama, Titan, Cohere), serverless, AWS IAM integration, Guardrails for content filtering, Knowledge Bases (managed RAG)
- **LangChain**: orchestration framework -- chains, agents, memory, retrieval; useful for complex multi-step LLM workflows
- **LlamaIndex**: data framework for LLM apps -- document loaders, index structures, query engines; optimized for RAG

### Essential Q&A

**Q: Show OpenAI function calling for data pipeline orchestration.**
```python
from openai import OpenAI
client = OpenAI()

tools = [{
    "type": "function",
    "function": {
        "name": "run_sql_query",
        "description": "Execute a SQL query against the data warehouse",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "SQL query to execute"},
                "database": {"type": "string", "enum": ["snowflake", "sqlserver"]}
            },
            "required": ["query", "database"]
        }
    }
}]

response = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Get count of loans originated this month"}],
    tools=tools,
    tool_choice="auto"
)
# Parse tool_calls from response, execute SQL, return result
```

**Q: How does Claude's prompt caching work for batch data processing?**
A: Mark static content (schema definitions, rules, few-shot examples) with `cache_control: {"type": "ephemeral"}`. Cached for 5 minutes. Cached tokens cost 90% less on reads. Ideal for processing thousands of records with the same system prompt -- first call caches, subsequent calls reuse.
```python
import anthropic
client = anthropic.Anthropic()

response = client.messages.create(
    model="claude-sonnet-4-20250514",
    max_tokens=1024,
    system=[
        {"type": "text", "text": large_schema_and_rules,  # Cached after first call
         "cache_control": {"type": "ephemeral"}}
    ],
    messages=[{"role": "user", "content": f"Validate this loan record: {record}"}]
)
```

**Q: When to use LangChain vs. LlamaIndex vs. direct API calls?**
A: **Direct API**: simple, single-call tasks; full control, lowest overhead. **LangChain**: complex chains, agent loops, multi-step workflows, many tool integrations. **LlamaIndex**: document-heavy RAG applications, structured data + unstructured data queries. For most data engineering tasks, start with direct API calls and add frameworks only when complexity demands it.

**Q: How do you handle rate limits and errors in production AI pipelines?**
A: 1) Implement exponential backoff with jitter (tenacity library). 2) Use async/batch APIs for bulk processing. 3) Cache responses for idempotent queries. 4) Set up fallback models (GPT-4o -> GPT-4o-mini, Claude Sonnet -> Haiku). 5) Monitor token usage and costs per pipeline. 6) Use OpenAI batch API for non-time-sensitive bulk processing (50% cheaper, 24h SLA).

**Q: How does Amazon Bedrock fit into AWS data engineering stacks?**
A: Bedrock integrates with Lambda, Step Functions, S3, and Glue. Use it for: embedding generation in ETL pipelines (Titan embeddings), document processing (Claude via Bedrock), and managed RAG (Bedrock Knowledge Bases with OpenSearch Serverless). IAM policies control model access; VPC endpoints keep traffic private.

---

## 7. AI Agents & Automation

### Key Highlights
- **AI Agent**: LLM + tools + reasoning loop; observes, reasons, acts, iterates
- **ReAct pattern**: Reasoning + Acting -- LLM alternates between thinking ("I need to check the schema") and tool calls (execute SQL), looping until task complete
- **Tool calling**: LLM decides which function to call and with what arguments; structured bridge between natural language and code execution
- **Multi-agent systems**: multiple specialized agents collaborating -- CrewAI (role-based), AutoGen (conversational), LangGraph (graph-based state machines)
- **AI-powered ETL**: LLM-assisted schema mapping, data transformation code generation, anomaly detection, data quality rules generation
- **AI code generation**: GitHub Copilot (IDE inline), Claude/ChatGPT (conversational), Cursor (AI-first editor); accelerates SQL, Python, Spark code writing
- **Text-to-SQL agents**: natural language -> SQL with iterative error correction; tools like Vanna.ai, DuckDB + LLM

### Essential Q&A

**Q: Describe an AI agent architecture for automated data quality monitoring.**
A: Agent has tools: `run_sql(query)`, `get_table_schema(table)`, `send_alert(message)`, `log_issue(details)`. Flow: 1) Agent receives "Check data quality for today's loan tape." 2) Reasons: need to get schema, run profiling queries. 3) Calls `get_table_schema` -> examines columns. 4) Generates and runs validation SQL (null checks, range checks, referential integrity). 5) Analyzes results, identifies issues. 6) Calls `send_alert` for critical issues. 7) Returns summary report.

**Q: What is LangGraph and how does it improve on simple agent loops?**
A: LangGraph models agent workflows as state machines (directed graphs). Nodes are actions (LLM calls, tool executions), edges are conditional transitions. Benefits: explicit control flow, human-in-the-loop checkpoints, parallel branches, persistent state, better error handling. Superior to basic ReAct for complex multi-step data pipelines.

**Q: How can AI agents automate ETL development?**
A: 1) **Schema mapping**: agent examines source/target schemas, proposes column mappings using semantic similarity. 2) **Transform generation**: given mapping + business rules in natural language, agent generates SQL/Python transformations. 3) **Testing**: agent generates test cases, runs them, iterates on failures. 4) **Documentation**: agent generates data lineage docs from the pipeline code.

**Q: Show a simple ReAct agent pattern in Python.**
```python
import anthropic

client = anthropic.Anthropic()
tools = [
    {"name": "run_sql", "description": "Run SQL on Snowflake",
     "input_schema": {"type": "object", "properties": {
         "query": {"type": "string"}}, "required": ["query"]}}
]

messages = [{"role": "user", "content": "How many loans defaulted last quarter?"}]

while True:
    response = client.messages.create(
        model="claude-sonnet-4-20250514", max_tokens=4096,
        tools=tools, messages=messages
    )
    if response.stop_reason == "tool_use":
        tool_block = next(b for b in response.content if b.type == "tool_use")
        result = execute_sql(tool_block.input["query"])  # Your SQL executor
        messages.append({"role": "assistant", "content": response.content})
        messages.append({"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_block.id,
             "content": str(result)}
        ]})
    else:
        print(response.content[0].text)
        break
```

**Q: What are the risks of AI-generated SQL in production?**
A: 1) SQL injection if user input flows through LLM to query. 2) Incorrect joins/filters producing wrong results silently. 3) Expensive queries (full table scans, cross joins). Mitigations: validate generated SQL against allow-list of tables/operations, run EXPLAIN before execution, enforce row limits, use read-only credentials, human review for DDL/DML.

---

## 8. AI in SQL Server & Snowflake

### Key Highlights
- **SQL Server ML Services**: R/Python in-database via `sp_execute_external_script`; mostly legacy, being superseded by REST-based approaches
- **`sp_invoke_external_rest_endpoint`** (Azure SQL): call OpenAI/Azure OpenAI directly from T-SQL; great for enrichment in stored procedures
- **PREDICT with ONNX**: deploy ONNX models in SQL Server for in-database scoring; no external runtime needed; supports classification, regression
- **SQL Server 2025**: native VECTOR data type, `VECTOR_DISTANCE()` function, DiskANN-based vector index -- brings vector search to SQL Server natively
- **Snowflake Cortex AI**: fully managed LLM functions (COMPLETE, SUMMARIZE, SENTIMENT, TRANSLATE, EXTRACT_ANSWER), Cortex Search (managed RAG), Cortex Fine-tuning, Cortex Analyst (text-to-SQL)
- **Snowflake ML functions**: `FORECAST()` (time series), `ANOMALY_DETECTION()`, `CLASSIFICATION()`, `TOP_INSIGHTS()` -- SQL-callable ML without Python
- **Snowpark ML**: Python ML framework on Snowflake -- preprocessing, training, model registry, feature store; runs on Snowflake compute

### Essential Q&A

**Q: How do you call Azure OpenAI from SQL Server?**
```sql
-- Azure SQL Database / Managed Instance
DECLARE @response NVARCHAR(MAX);
DECLARE @payload NVARCHAR(MAX) = N'{
    "messages": [
        {"role": "system", "content": "Classify loan status as CURRENT, DELINQUENT, or DEFAULT"},
        {"role": "user", "content": "Borrower missed 3 payments, property in foreclosure"}
    ],
    "temperature": 0
}';

EXEC sp_invoke_external_rest_endpoint
    @url = 'https://myoai.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-02-01',
    @method = 'POST',
    @payload = @payload,
    @credential = [https://myoai.openai.azure.com/],
    @response = @response OUTPUT;

SELECT JSON_VALUE(@response, '$.result.choices[0].message.content') AS classification;
```

**Q: How does PREDICT with ONNX work in SQL Server?**
```sql
-- Load ONNX model (one-time)
DECLARE @model VARBINARY(MAX) = (SELECT BulkColumn FROM OPENROWSET(
    BULK 'path/to/prepayment_model.onnx', SINGLE_BLOB) AS model);

INSERT INTO ml_models (model_name, model_data)
VALUES ('prepayment_v1', @model);

-- Score in real-time
SELECT loan_id, p.*
FROM loans
CROSS APPLY PREDICT(MODEL = (SELECT model_data FROM ml_models
    WHERE model_name = 'prepayment_v1'), DATA = loans) AS p;
```

**Q: How do Snowflake ML functions work for time-series forecasting?**
```sql
-- Forecast monthly prepayment rates
CREATE SNOWFLAKE.ML.FORECAST prepayment_forecast(
    INPUT_DATA => TABLE(
        SELECT reporting_month, pool_cpr
        FROM mbs_performance
        WHERE pool_id = 'FN_MA4500'
        ORDER BY reporting_month
    ),
    TIMESTAMP_COLNAME => 'REPORTING_MONTH',
    TARGET_COLNAME => 'POOL_CPR'
);

-- Generate 6-month forecast
CALL prepayment_forecast!FORECAST(FORECASTING_PERIODS => 6);
```

**Q: What is Snowflake Cortex Analyst?**
A: Text-to-SQL service. You provide a semantic model (YAML) defining tables, columns, relationships, and business terminology. Users ask natural language questions, Cortex Analyst generates and executes SQL. Supports verified queries (curated SQL for common questions) for guaranteed accuracy.

**Q: How does SQL Server 2025 vector search compare to pgvector?**
A: SQL Server 2025 uses DiskANN (Microsoft Research) for ANN indexing -- disk-based, so it handles larger-than-memory datasets well. pgvector uses HNSW (in-memory graph). SQL Server advantage: integrated with existing SQL Server infrastructure, no separate DB needed. pgvector advantage: more mature, richer ecosystem, open source.

---

## 9. AI for Finance & Secondary Market

### Key Highlights
- **Prepayment modeling**: predict CPR/CDR using borrower attributes (FICO, LTV, DTI), macro factors (interest rates, HPI), and loan age (seasoning curve). ML models outperform traditional PSA/SDA curves
- **Credit risk AI**: gradient boosted models (XGBoost/LightGBM) for default prediction; SHAP values required for adverse action notices under ECOA
- **NLP for loan documents**: extract data from 1003 applications, appraisals, title docs; reduce manual review from 45+ minutes to under 5 minutes per loan
- **Anomaly detection in MBS data**: identify unusual prepayment spikes, reporting errors, potential fraud in loan-level data
- **AI for MBS valuation**: Monte Carlo simulations enhanced with ML-predicted prepayment/default speeds; real-time repricing
- **GSE (Fannie/Freddie) compliance**: AI outputs must be auditable; regulatory requirements (SR 11-7) mandate model validation, documentation, and ongoing monitoring

### Essential Q&A

**Q: How does SHAP work for adverse action explanations in lending?**
A: SHAP (SHapley Additive exPlanations) assigns each feature a contribution to the prediction. For a denied loan: if SHAP shows DTI contributed +0.15 to denial probability and FICO contributed +0.10, the adverse action notice can cite "debt-to-income ratio" as the primary reason. ECOA requires specific, actionable reasons -- SHAP provides ranked feature importances per prediction.
```python
import shap

explainer = shap.TreeExplainer(model)
shap_values = explainer(loan_features)

# Top reasons for denial (positive SHAP = toward denial)
denial_reasons = shap_values[0].feature_names[
    shap_values[0].values.argsort()[::-1][:4]  # Top 4 factors
]
```

**Q: How can RAG be applied to GSE seller/servicer guidelines?**
A: Ingest Fannie Mae Selling Guide and Freddie Mac Single-Family Seller/Servicer Guide (thousands of pages). Chunk by section with hierarchy (chapter > section > subsection). Embed and index. When underwriters or systems need to validate a loan attribute, query the RAG system: "What are the LTV limits for cash-out refinances on investment properties?" Returns the exact guideline text with section references.

**Q: What ML approaches work for prepayment modeling?**
A: Features: note rate vs current market rate (incentive), loan age, FICO, LTV, property type, state, loan size, season. Models: XGBoost/LightGBM for CPR prediction, survival analysis for time-to-prepayment. Key insight: rate incentive (note rate - market rate) is the strongest predictor. Validate on out-of-time samples (train on 2018-2022, validate on 2023).

**Q: How is NLP used for loan document processing?**
A: 1) **OCR + layout analysis** (Azure Document Intelligence / AWS Textract) extracts text from scanned docs. 2) **NER models** extract entities: borrower name, property address, loan amount, dates. 3) **Classification** routes documents to correct type (appraisal, title, income). 4) **LLM extraction** handles unstructured notes: "Extract all conditions to close from this underwriter notes field." Reduces data entry errors by 60-80%.

**Q: How do you detect anomalies in MBS loan-level data?**
A: Use Snowflake `ANOMALY_DETECTION()` on time-series metrics (monthly CPR, CDR, delinquency rates) per pool. For loan-level: isolation forest or autoencoder models flag loans with unusual attribute combinations (e.g., 800 FICO + 95% LTV + stated income). Statistical rules catch reporting errors (UPB increases without modification, negative balances).

---

## 10. AI Governance & Compliance

### Key Highlights
- **Responsible AI pillars**: fairness, transparency, accountability, privacy, safety, reliability
- **Model monitoring**: track performance drift over time; **PSI (Population Stability Index)** measures input distribution shift (PSI > 0.2 = significant drift); **KS test** compares score distributions
- **Data privacy**: PII detection and masking before LLM processing; GLBA (financial privacy), CCPA (California consumer rights), GDPR considerations
- **Bias detection**: **disparate impact ratio** (selection rate of protected class / rate of non-protected; < 0.8 = potential violation); **Fairlearn** library for bias metrics and mitigation
- **SR 11-7**: Federal Reserve guidance on model risk management -- requires model validation, documentation, independent review, ongoing monitoring; applies to AI/ML models in banking
- **ECOA**: Equal Credit Opportunity Act -- prohibits discrimination; AI lending models must provide specific adverse action reasons; protected classes include race, sex, age, marital status
- **EU AI Act**: risk-based framework; credit scoring = high-risk; requires conformity assessments, human oversight, transparency

### Essential Q&A

**Q: How do you ensure LLM outputs comply with financial regulations?**
A: 1) **Input guardrails**: strip PII before sending to external LLMs; use Azure OpenAI or self-hosted models for sensitive data. 2) **Output validation**: parse and verify LLM outputs against business rules before acting on them. 3) **Audit trail**: log all prompts, responses, and model versions. 4) **Human-in-the-loop**: require human approval for consequential decisions (loan approvals, adverse actions). 5) **Content filtering**: block generation of discriminatory or non-compliant content.

**Q: What is PSI and how do you implement it?**
A: PSI measures how much a variable's distribution has shifted from a baseline. Used to detect data drift that may degrade model performance.
```python
import numpy as np

def calculate_psi(expected, actual, bins=10):
    """PSI: < 0.1 = no shift, 0.1-0.2 = moderate, > 0.2 = significant"""
    breakpoints = np.quantile(expected, np.linspace(0, 1, bins + 1))
    expected_pct = np.histogram(expected, breakpoints)[0] / len(expected)
    actual_pct = np.histogram(actual, breakpoints)[0] / len(actual)
    # Avoid division by zero
    expected_pct = np.clip(expected_pct, 0.001, None)
    actual_pct = np.clip(actual_pct, 0.001, None)
    psi = np.sum((actual_pct - expected_pct) * np.log(actual_pct / expected_pct))
    return psi

# Monitor monthly: if PSI > 0.2, trigger model revalidation
psi_fico = calculate_psi(baseline_fico_scores, current_month_fico_scores)
```

**Q: How does Fairlearn help detect lending bias?**
A: Fairlearn computes metrics across protected groups and provides mitigation algorithms.
```python
from fairlearn.metrics import MetricFrame, selection_rate, demographic_parity_difference
from sklearn.metrics import accuracy_score

metrics = MetricFrame(
    metrics={"accuracy": accuracy_score, "selection_rate": selection_rate},
    y_true=y_test, y_pred=predictions,
    sensitive_features=demographics["race"]
)
print(metrics.by_group)          # Metrics per group
print(metrics.difference())       # Max disparity between groups
# Disparate impact ratio < 0.8 = potential ECOA violation
```

**Q: What does SR 11-7 require for AI/ML models in banking?**
A: 1) **Model inventory**: catalog all models including AI/ML. 2) **Development documentation**: data sources, methodology, assumptions, limitations. 3) **Independent validation**: separate team validates model performance, data, and conceptual soundness. 4) **Ongoing monitoring**: track performance metrics, PSI, back-testing. 5) **Annual review**: comprehensive reassessment. 6) **Board reporting**: model risk dashboard for senior management. AI models face additional scrutiny on explainability and bias.

**Q: How do you handle PII when using external LLM APIs?**
A: 1) **Detection**: use Presidio (Microsoft) or AWS Comprehend to identify PII (SSN, names, addresses). 2) **Masking**: replace PII with synthetic tokens before sending to LLM ("John Smith" -> "[PERSON_1]"). 3) **De-masking**: map tokens back to original values in the response. 4) **Architecture**: prefer Azure OpenAI (no data used for training, data residency) or self-hosted models (Llama) for sensitive data. 5) **Policy**: never send SSN, account numbers, or DOB to external APIs regardless of provider assurances.

**Q: What is disparate impact analysis for AI lending models?**
A: Compare model outcomes (approval rates) across protected classes. Disparate impact ratio = (approval rate of protected group) / (approval rate of control group). Ratio < 0.8 (the "four-fifths rule") triggers investigation. Even if the model doesn't use race/sex directly, proxy variables (ZIP code, university) can create disparate impact. Mitigations: remove proxy features, use fairness constraints during training, regular monitoring across demographics.

---

## Quick Reference Cheat Sheet

| Topic | Key Numbers & Facts |
|-------|-------------------|
| GPT-4o context | 128K tokens (~96K words) |
| Claude context | 200K tokens (~150K words) |
| Gemini 1.5 Pro | 2M tokens context |
| Snowflake Arctic | 480B params, 17B active (MoE) |
| OpenAI embedding dims | 1536 (small) / 3072 (large) |
| HNSW typical params | M=16, ef_construction=200 |
| RAG chunk size | 512-1024 tokens, 10-20% overlap |
| PSI thresholds | < 0.1 stable, 0.1-0.2 moderate, > 0.2 significant |
| Disparate impact | < 0.8 ratio = potential violation |
| Temperature for SQL | 0 (deterministic) |
| Prompt caching savings | 90% cost reduction (Claude) |
| Batch API savings | 50% cost reduction (OpenAI) |

---

[Back to Summary Index](README.md)
