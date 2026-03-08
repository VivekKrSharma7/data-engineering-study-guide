# Large Language Models (LLMs) & Transformers Architecture
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

The transformer architecture, introduced in the 2017 paper "Attention Is All You Need," is the foundation of every major large language model in use today. LLMs represent the most significant shift in applied AI since deep learning replaced handcrafted feature engineering in computer vision. For data engineers, LLMs create an entirely new class of data pipeline: retrieval-augmented generation (RAG), embedding pipelines, vector stores, and LLM API integration layers.

This guide covers the architecture deeply enough to answer technical interview questions, maps transformer concepts to data engineering work, and provides production-ready code patterns for integrating LLMs with SQL Server and Snowflake environments.

---

## Why Transformers Replaced RNNs

| Limitation of RNNs | How Transformers Solve It |
|---|---|
| Sequential computation — can't parallelize | Attention is computed over all positions simultaneously |
| Vanishing gradients over long sequences | Direct attention connections between any two tokens; no gradient path through time |
| Fixed hidden state bottleneck | Each token attends to all others directly |
| Slow training on long sequences | Parallelizable matrix operations; trains orders of magnitude faster on GPUs |

The key insight: instead of processing tokens one at a time and compressing context into a hidden state, transformers directly compute relationships between every pair of tokens in the input simultaneously.

---

## Transformer Architecture

```
Input Tokens
     │
[Token Embedding] + [Positional Encoding]
     │
     ▼
┌─────────────────────────────────────┐
│         Transformer Block × N       │
│                                     │
│  ┌─────────────────────────────┐    │
│  │   Multi-Head Self-Attention  │    │
│  └─────────────┬───────────────┘    │
│                │ + Residual         │
│  ┌─────────────▼───────────────┐    │
│  │      Layer Normalization     │    │
│  └─────────────┬───────────────┘    │
│                │                    │
│  ┌─────────────▼───────────────┐    │
│  │  Feed-Forward Network (FFN)  │    │
│  └─────────────┬───────────────┘    │
│                │ + Residual         │
│  ┌─────────────▼───────────────┐    │
│  │      Layer Normalization     │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
     │
[Output Layer / LM Head]
     │
  Predictions
```

### Core Components

**1. Token Embedding**
Maps discrete token IDs to dense vectors (e.g., 768 or 4096 dimensions). The vocabulary is typically 32,000–128,000 tokens. Common tokenization algorithms: BPE (Byte Pair Encoding) and SentencePiece.

**2. Positional Encoding**
Transformers have no inherent sense of token order. Positional encodings inject position information into the embedding. Original paper used sinusoidal functions; modern LLMs use learned positional embeddings or RoPE (Rotary Position Embedding).

**3. Self-Attention**
The most important component. For each token, computes how much it should "attend to" every other token.

```
Attention(Q, K, V) = softmax( QKᵀ / √d_k ) · V
```

- **Q (Query):** "What am I looking for?"
- **K (Key):** "What do I advertise as my content?"
- **V (Value):** "What information do I contribute if attended to?"
- `d_k`: dimension of key vectors (scaling factor to prevent softmax saturation)

The result: a weighted average of value vectors, where weights reflect how relevant each token is to the current query token.

**4. Multi-Head Attention**
Run `h` parallel attention heads, each with its own Q/K/V projection matrices. Each head learns a different type of relationship (syntax, coreference, semantic similarity). Concatenate outputs and project.

```python
# Conceptual multi-head attention (simplified)
import torch, torch.nn as nn, torch.nn.functional as F

class MultiHeadAttention(nn.Module):
    def __init__(self, d_model: int = 512, n_heads: int = 8):
        super().__init__()
        assert d_model % n_heads == 0
        self.d_k = d_model // n_heads
        self.n_heads = n_heads
        self.W_q = nn.Linear(d_model, d_model)
        self.W_k = nn.Linear(d_model, d_model)
        self.W_v = nn.Linear(d_model, d_model)
        self.W_o = nn.Linear(d_model, d_model)

    def forward(self, x: torch.Tensor,
                mask: torch.Tensor | None = None) -> torch.Tensor:
        B, T, D = x.shape
        Q = self.W_q(x).view(B, T, self.n_heads, self.d_k).transpose(1, 2)
        K = self.W_k(x).view(B, T, self.n_heads, self.d_k).transpose(1, 2)
        V = self.W_v(x).view(B, T, self.n_heads, self.d_k).transpose(1, 2)
        scores = (Q @ K.transpose(-2, -1)) / (self.d_k ** 0.5)
        if mask is not None:
            scores = scores.masked_fill(mask == 0, float("-inf"))
        attn = F.softmax(scores, dim=-1)
        out = (attn @ V).transpose(1, 2).contiguous().view(B, T, D)
        return self.W_o(out)
```

**5. Feed-Forward Network (FFN)**
Applied independently to each token position after attention. Typically 4x wider than the model dimension. Captures token-level transformations that do not require cross-token interaction.

---

## Model Family Taxonomy

| Family | Architecture | Training Objective | Examples | Best For |
|---|---|---|---|---|
| GPT (decoder-only) | Masked self-attention (causal) | Next token prediction | GPT-4, Claude, Llama, Mistral | Text generation, chat, code |
| BERT (encoder-only) | Bidirectional self-attention | Masked language modeling + NSP | BERT, RoBERTa, DeBERTa | Classification, NER, embeddings |
| T5 / BART (encoder-decoder) | Full attention (encoder) + causal (decoder) | Text-to-text | T5, BART, Flan-T5 | Translation, summarization, Q&A |
| Sentence Transformers | BERT-based + pooling | Contrastive/cosine similarity | all-MiniLM, BGE, E5 | Semantic embeddings, RAG retrieval |

**When to use each:**
- Building a chatbot or document Q&A system → GPT-family (Claude, GPT-4, Llama)
- Classifying loan documents by type → Fine-tuned BERT or DeBERTa
- Generating structured output (JSON) from unstructured text → GPT-4 with function calling / structured output
- Building a RAG retrieval pipeline → Sentence Transformer for embeddings, GPT for generation

---

## Pre-training, Fine-tuning, RLHF

### Pre-training
Train on hundreds of billions of tokens from the internet, books, and code. This is where the fundamental language understanding is built. Requires thousands of GPUs and months of computation. Data engineers at AI labs build the pre-training data pipelines.

### Fine-tuning
Take a pre-trained model and continue training on a smaller, domain-specific dataset. The model retains general knowledge but becomes expert in a specific domain.

- **Full fine-tuning:** Update all parameters. Expensive; requires multiple GPUs.
- **LoRA (Low-Rank Adaptation):** Inject small trainable rank decomposition matrices; freeze base model. 90% fewer trainable parameters. Standard technique for fine-tuning on a single GPU.
- **Instruction fine-tuning:** Fine-tune on (instruction, response) pairs to make a raw language model follow instructions.

### RLHF (Reinforcement Learning from Human Feedback)
Three-stage process: (1) Supervised fine-tuning on demonstrations. (2) Train a reward model on human preference rankings. (3) Optimize the LLM against the reward model using PPO (a reinforcement learning algorithm). This is how ChatGPT, Claude, and Gemini were made helpful and safe.

**DE relevance:** RLHF requires massive infrastructure for human annotation pipelines, reward model training data management, and PPO training data flows. This is specialized work at AI labs, but knowing what it is positions you well in interviews.

---

## Tokens, Context Windows, and Tokenization

| Model | Context Window | Approximate Token Capacity |
|---|---|---|
| GPT-3.5 | 16K tokens | ~12,000 words |
| GPT-4 | 128K tokens | ~96,000 words |
| Claude 3.5 Sonnet | 200K tokens | ~150,000 words |
| Gemini 1.5 Pro | 1M tokens | ~750,000 words |
| Llama 3.1 70B | 128K tokens | ~96,000 words |

**1 token ≈ 0.75 words** (for English; varies by language and content type).

**Tokenization example:**
```
Input:  "prepayment risk analysis"
Tokens: ["prep", "ayment", " risk", " analysis"]   # BPE tokenization
IDs:    [40062, 1009, 4927, 6492]
```

**DE implications:** Context window limits affect RAG chunk sizing and the cost of long-context prompts. Always measure token counts before assuming content fits.

```python
import tiktoken  # OpenAI tokenizer

enc = tiktoken.encoding_for_model("gpt-4")
text = "Analyze the prepayment risk for this MBS pool given current rate environment."
tokens = enc.encode(text)
print(f"Token count: {len(tokens)}")  # → 16
```

---

## Inference Parameters

| Parameter | Range | Effect |
|---|---|---|
| Temperature | 0.0 – 2.0 | 0 = deterministic/greedy; higher = more random/creative |
| Top-p (nucleus sampling) | 0.0 – 1.0 | Consider only tokens comprising top p probability mass |
| Top-k | 1 – vocabulary size | Consider only k highest probability tokens |
| Max tokens | 1 – context limit | Maximum output length |
| Frequency penalty | -2.0 – 2.0 | Penalize tokens already used; reduces repetition |
| Stop sequences | Strings | Stop generation when these strings appear in output |

**For data extraction tasks:** Use `temperature=0` for maximum determinism. For creative generation or diverse output, use `temperature=0.7–1.0`.

---

## Embeddings from LLMs

An embedding is a dense numeric vector that represents the semantic meaning of text. Semantically similar texts produce vectors that are close together (measured by cosine similarity or dot product).

```python
from sentence_transformers import SentenceTransformer
import numpy as np

model = SentenceTransformer("BAAI/bge-large-en-v1.5")  # 1024-dim embeddings

texts = [
    "The loan prepaid due to refinancing at a lower rate.",
    "Borrower paid off mortgage via refi to capture rate savings.",
    "The property was sold at foreclosure auction.",
]
embeddings = model.encode(texts, normalize_embeddings=True)
# Shape: (3, 1024)

# Cosine similarity (dot product when normalized)
sim_01 = np.dot(embeddings[0], embeddings[1])  # ~0.94 — very similar
sim_02 = np.dot(embeddings[0], embeddings[2])  # ~0.45 — dissimilar
print(f"Prepay vs Refi: {sim_01:.3f}")
print(f"Prepay vs Foreclosure: {sim_02:.3f}")
```

---

## Retrieval-Augmented Generation (RAG) Architecture

RAG solves the knowledge cutoff and hallucination problems by grounding LLM responses in retrieved facts from your data.

```
User Query
    │
    ▼
[Embedding Model] → Query Vector
    │
    ▼
[Vector Store]  ← Semantic Search (cosine similarity / ANN)
    │ (returns top-k relevant document chunks)
    ▼
[Prompt Assembly]
  System Prompt + Context Chunks + User Query
    │
    ▼
[LLM API] → Answer grounded in retrieved context
    │
    ▼
[Response + Source Citations]
```

### Full RAG Pipeline Implementation

```python
import os
import openai
from sentence_transformers import SentenceTransformer
import chromadb
from chromadb.utils import embedding_functions

# --- Step 1: Index loan documents into vector store ---
def build_vector_index(documents: list[dict],
                       collection_name: str = "loan_docs") -> chromadb.Collection:
    client = chromadb.PersistentClient(path="./chroma_db")

    embed_fn = embedding_functions.SentenceTransformerEmbeddingFunction(
        model_name="BAAI/bge-large-en-v1.5"
    )
    collection = client.get_or_create_collection(
        name=collection_name,
        embedding_function=embed_fn,
        metadata={"hnsw:space": "cosine"}
    )

    collection.add(
        ids=[doc["id"] for doc in documents],
        documents=[doc["text"] for doc in documents],
        metadatas=[doc["metadata"] for doc in documents]
    )
    return collection

# --- Step 2: Retrieve relevant chunks ---
def retrieve(query: str, collection: chromadb.Collection,
             n_results: int = 4) -> list[str]:
    results = collection.query(
        query_texts=[query],
        n_results=n_results,
        include=["documents", "metadatas", "distances"]
    )
    return results["documents"][0]  # list of relevant text chunks

# --- Step 3: Generate answer with LLM ---
def answer_with_rag(query: str, collection: chromadb.Collection,
                    model: str = "gpt-4o") -> str:
    context_chunks = retrieve(query, collection)
    context_str = "\n\n---\n\n".join(context_chunks)

    client = openai.OpenAI(api_key=os.environ["OPENAI_API_KEY"])
    response = client.chat.completions.create(
        model=model,
        temperature=0,
        messages=[
            {"role": "system", "content": (
                "You are a mortgage data analyst. Answer questions using ONLY "
                "the provided context. If the answer is not in the context, say "
                "'I don't have enough information.' Cite the source document."
            )},
            {"role": "user", "content": (
                f"Context:\n{context_str}\n\nQuestion: {query}"
            )}
        ],
        max_tokens=800
    )
    return response.choices[0].message.content
```

---

## Calling LLM APIs: OpenAI and Anthropic

### OpenAI API — Structured Data Extraction

```python
import openai, json, os

client = openai.OpenAI(api_key=os.environ["OPENAI_API_KEY"])

def extract_loan_fields(document_text: str) -> dict:
    """Extract structured fields from an unstructured loan document."""
    response = client.chat.completions.create(
        model="gpt-4o",
        temperature=0,
        response_format={"type": "json_object"},
        messages=[
            {"role": "system", "content": (
                "Extract the following fields from the mortgage document. "
                "Return valid JSON with keys: borrower_name, loan_amount, "
                "interest_rate, origination_date, property_address, ltv_ratio. "
                "Use null for missing fields."
            )},
            {"role": "user", "content": document_text}
        ],
        max_tokens=400
    )
    return json.loads(response.choices[0].message.content)

# Usage
raw_text = """
DEED OF TRUST dated March 1, 2024. Borrower: John A. Smith.
Loan Amount: $485,000. Interest Rate: 6.875% per annum.
Property: 1423 Maple Drive, Charlotte, NC 28277. LTV: 80%.
"""
fields = extract_loan_fields(raw_text)
# → {"borrower_name": "John A. Smith", "loan_amount": 485000,
#    "interest_rate": 6.875, "origination_date": null,
#    "property_address": "1423 Maple Drive, Charlotte, NC 28277", "ltv_ratio": 80.0}
```

### Anthropic (Claude) API

```python
import anthropic, os

client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])

def summarize_servicer_notes(notes: str) -> str:
    """Summarize free-text servicer notes into structured risk flags."""
    message = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=1024,
        messages=[
            {
                "role": "user",
                "content": (
                    "Read these mortgage servicer notes and identify: "
                    "(1) delinquency risk factors, (2) borrower hardship indicators, "
                    "(3) any forbearance or modification mentions. "
                    "Format as bullet points.\n\nNotes:\n" + notes
                )
            }
        ]
    )
    return message.content[0].text
```

---

## Integrating LLMs with Snowflake

Snowflake Cortex provides native LLM functions that run inside Snowflake without exporting data:

```sql
-- Cortex LLM functions (Snowflake native)
-- Summarize servicer notes stored in a table
SELECT
    loan_id,
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            'Summarize these servicer notes in one sentence, '
            'flagging any default risk indicators:\n\n',
            servicer_notes
        )
    ) AS notes_summary
FROM servicer_notes_staging
WHERE notes_summary IS NULL
  AND LENGTH(servicer_notes) > 100;

-- Generate embeddings natively in Snowflake (Cortex Embed)
SELECT
    document_id,
    SNOWFLAKE.CORTEX.EMBED_TEXT_1024(
        'voyage-finance-2',   -- finance-domain embedding model
        document_text
    ) AS embedding_vector
FROM loan_documents
WHERE document_type = 'SERVICER_COMMENT';

-- Semantic search using vector similarity
SELECT
    d.document_id,
    d.document_text,
    VECTOR_COSINE_SIMILARITY(
        d.embedding_vector::VECTOR(FLOAT, 1024),
        SNOWFLAKE.CORTEX.EMBED_TEXT_1024(
            'voyage-finance-2',
            'borrower requested forbearance due to job loss'
        )::VECTOR(FLOAT, 1024)
    ) AS similarity_score
FROM loan_documents d
ORDER BY similarity_score DESC
LIMIT 10;
```

---

## Integrating LLMs with SQL Server

SQL Server does not have native LLM functions, but you can call LLM APIs from stored procedures using `sp_invoke_external_rest_endpoint` (Azure SQL) or from external Python scripts:

```sql
-- Azure SQL: Call OpenAI via sp_invoke_external_rest_endpoint
-- (Requires Azure SQL and a Database Scoped Credential for the API key)
DECLARE @url NVARCHAR(4000) =
    'https://myopenai.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-02-01';

DECLARE @body NVARCHAR(MAX) = JSON_QUERY(N'{
    "messages": [
        {"role": "system", "content": "Extract loan fields as JSON."},
        {"role": "user",   "content": "Loan originated 2024-01-15, amount $300,000, rate 7.25%"}
    ],
    "temperature": 0,
    "max_tokens": 300
}');

DECLARE @response NVARCHAR(MAX);
EXEC sp_invoke_external_rest_endpoint
    @url = @url,
    @method = 'POST',
    @headers = '{"Content-Type":"application/json"}',
    @credential = [https://myopenai.openai.azure.com],
    @payload = @body,
    @response = @response OUTPUT;

SELECT JSON_VALUE(@response, '$.result.choices[0].message.content') AS llm_output;
```

---

## Token Costs and Optimization

Token costs (as of early 2025, approximate):

| Model | Input (per 1M tokens) | Output (per 1M tokens) |
|---|---|---|
| GPT-4o | $2.50 | $10.00 |
| GPT-4o mini | $0.15 | $0.60 |
| Claude 3.5 Sonnet | $3.00 | $15.00 |
| Claude 3 Haiku | $0.25 | $1.25 |
| Llama 3.1 70B (self-hosted) | infra cost only | infra cost only |

### Cost Optimization Strategies for Data Engineers

```python
# Strategy 1: Route to cheaper model based on task complexity
def smart_route(prompt: str, task_type: str) -> str:
    CHEAP_MODEL  = "gpt-4o-mini"
    SMART_MODEL  = "gpt-4o"
    # Simple extraction → cheap model; complex reasoning → smart model
    model = CHEAP_MODEL if task_type in ("extraction", "classification") else SMART_MODEL
    return call_openai(prompt, model=model)

# Strategy 2: Batch requests to minimize API overhead
def batch_extract(documents: list[str], batch_size: int = 20) -> list[dict]:
    results = []
    for i in range(0, len(documents), batch_size):
        batch = documents[i:i+batch_size]
        # Combine into a single prompt with numbered items
        combined = "\n\n".join(
            f"Document {j+1}:\n{doc}" for j, doc in enumerate(batch)
        )
        response = call_openai(
            f"Extract fields from each numbered document. "
            f"Return a JSON array with {len(batch)} objects.\n\n{combined}",
            model="gpt-4o-mini"
        )
        results.extend(json.loads(response))
    return results

# Strategy 3: Cache embeddings — never recompute for the same text
import hashlib, json, redis

r = redis.Redis(host="redis-host", port=6379, decode_responses=False)

def get_embedding_cached(text: str, model_name: str) -> list[float]:
    cache_key = f"emb:{model_name}:{hashlib.sha256(text.encode()).hexdigest()}"
    cached = r.get(cache_key)
    if cached:
        return json.loads(cached)
    embedding = get_embedding_from_api(text, model_name)
    r.setex(cache_key, 86400 * 7, json.dumps(embedding))  # TTL: 7 days
    return embedding

# Strategy 4: Truncate prompts to control context length
def truncate_to_tokens(text: str, max_tokens: int = 2000,
                        model: str = "gpt-4o") -> str:
    import tiktoken
    enc = tiktoken.encoding_for_model(model)
    tokens = enc.encode(text)
    if len(tokens) <= max_tokens:
        return text
    return enc.decode(tokens[:max_tokens])
```

---

## Vector Store Options for DE Infrastructure

| Store | Type | Best For | DE Integration |
|---|---|---|---|
| Snowflake (native vector) | Cloud DW native | Snowflake-native RAG; no new infra | SQL-based; Cortex Embed |
| pgvector (PostgreSQL) | Extension | Teams already on Postgres | Standard SQL + psycopg2 |
| Chroma | Embedded / hosted | Prototyping, small scale | Python-native |
| Pinecone | Managed cloud | Production RAG, serverless | REST API |
| Weaviate | Managed / self-hosted | Hybrid search (vector + BM25) | REST + Python client |
| Azure AI Search | Managed cloud | Azure ecosystem | REST API, .NET / Python SDK |
| FAISS | In-memory library | Custom high-performance ANN search | Python; no server |

**Recommendation for a Snowflake-centric shop:** Use Snowflake's native vector type and Cortex Embed — zero new infrastructure, unified governance, cost on the Snowflake bill. For latency-sensitive real-time retrieval (< 50ms), use Pinecone or Azure AI Search.

---

## Interview Q&A

**Q1: Explain the attention mechanism to a senior data engineer who understands SQL but has not studied transformers.**

**A:** Think of attention as a JOIN with learned weights instead of hard equality conditions. In a standard SQL JOIN, you match rows where `A.id = B.id` — binary match. In attention, every token queries every other token and gets a score based on their learned similarity. The result is a weighted average: "token 5 is 60% influenced by token 2, 30% by token 8, and 10% by everything else."

Concretely: imagine a row of tokens representing a sentence. For each token, we compute three vectors — a Query (what I need), a Key (what I offer), and a Value (what I contribute). The attention score between token i and token j is the dot product of i's Query and j's Key, normalized with softmax. The output for token i is the weighted sum of all Value vectors. This lets every word "gather context" from every other word in a single matrix multiplication — fully parallelizable, unlike the sequential nature of SQL cursors or RNN hidden states.

---

**Q2: What is the difference between GPT (decoder-only) and BERT (encoder-only)? When would you use each in a data pipeline?**

**A:** The distinction is in the attention mask applied during training. BERT uses bidirectional attention — every token can attend to every other token in both directions. This makes it excellent at understanding full-sentence context but unsuitable for generation (you cannot generate token-by-token if future tokens are visible during training).

GPT uses causal (left-to-right) masking — each token can only attend to itself and previous tokens. This enables autoregressive generation: predict the next token, append it, predict the next, repeat. The tradeoff is that understanding tasks (classification, extraction) are slightly less powerful than BERT because the model cannot see future context.

For data pipeline use cases: BERT (or DeBERTa) for classifying loan documents by type, extracting named entities from servicer notes, or building sentence embeddings for RAG retrieval. GPT-family for generating text: summarizing servicer notes, answering natural language questions about loan data, generating SQL from business questions (text-to-SQL).

---

**Q3: What is RAG and why is it preferable to fine-tuning for most enterprise data pipeline use cases?**

**A:** RAG (Retrieval-Augmented Generation) grounds LLM responses in retrieved external documents rather than relying solely on knowledge baked into model weights during training. The pipeline: embed the user query, retrieve the most similar document chunks from a vector store, inject those chunks into the prompt as context, generate a response grounded in retrieved content.

RAG is preferable to fine-tuning in most enterprise scenarios for several reasons: (1) **Freshness** — fine-tuning locks knowledge into model weights at training time; RAG can incorporate documents updated this morning. (2) **Cost** — fine-tuning requires compute, expertise, and ongoing maintenance; RAG adds an embedding and vector search layer at a fraction of the cost. (3) **Auditability** — RAG responses can cite the exact retrieved chunks that informed the answer; fine-tuned model responses cannot. (4) **Data governance** — sensitive data stays in your controlled vector store, not in model weights hosted by a third party. (5) **Iteration speed** — updating RAG knowledge base is a re-indexing job; updating a fine-tuned model is a retraining cycle.

Fine-tuning is appropriate when: you need the model to respond in a specific style or format consistently, follow domain-specific instructions reliably, or understand highly specialized terminology that RAG context alone cannot provide.

---

**Q4: Walk me through how you would build a RAG pipeline on top of Snowflake for a mortgage servicing team that wants to query loan documents in natural language.**

**A:** End-to-end design:

Step 1 — Document ingestion: Loan documents (servicer notes, appraisals, correspondence) are stored as text in a Snowflake table with columns `document_id`, `loan_id`, `document_type`, `document_text`, `document_date`.

Step 2 — Chunking: Documents longer than ~500 tokens are chunked with overlap (e.g., 500-token chunks with 100-token overlap) to avoid splitting context across chunk boundaries. This can be a dbt model or a Python UDF in Snowflake.

Step 3 — Embedding: Use `SNOWFLAKE.CORTEX.EMBED_TEXT_1024` to generate embedding vectors for each chunk. Store them in a Snowflake table with a VECTOR column. This runs entirely inside Snowflake — no data leaves.

Step 4 — Retrieval: When a user submits a query, embed the query text, then use `VECTOR_COSINE_SIMILARITY` in Snowflake to find the top-k most similar chunks. This is a SQL query.

Step 5 — Generation: Pass the retrieved chunks as context to an LLM (Cortex's `COMPLETE` function, or an external API call). Return the generated answer with source citations.

Step 6 — Serving: Expose via a FastAPI endpoint that takes a loan ID and a natural language question, queries Snowflake for relevant chunks, calls the LLM, and returns the answer. Log every query-response pair back to Snowflake for monitoring and audit.

---

**Q5: What is a context window and what data engineering problems does a limited context window create?**

**A:** The context window is the maximum number of tokens a transformer can process in a single forward pass — the working memory of an LLM. All tokens in the context are mutually visible through attention.

Data engineering problems: (1) **Long document handling** — a 50-page mortgage appraisal at ~25 words/page is ~8,000+ tokens; it fits in a 128K window but dozens of documents concatenated do not. You need chunking and retrieval strategies. (2) **Prompt engineering costs** — a detailed system prompt consumes tokens that could hold document context; you must balance instruction length against document context length. (3) **Summarization cascades** — when documents exceed the context window, you must split and summarize in stages ("map-reduce summarization"), adding pipeline complexity and cost. (4) **Performance degradation** — "lost in the middle" is a documented phenomenon where LLMs struggle to attend to information in the middle of a very long context window even when it technically fits; relevant chunks retrieved by RAG and placed near the end of the prompt outperform full-document context.

---

**Q6: How does temperature affect LLM output and how should you set it for data extraction versus analysis tasks?**

**A:** Temperature scales the logit distribution before the softmax in token sampling. At temperature 0, the model always picks the highest-probability token (greedy decoding) — fully deterministic, maximally repetitive. At higher temperatures, the distribution is flattened, making lower-probability tokens more likely — more creative, more varied, but potentially less accurate.

For data extraction from loan documents (extract borrower name, loan amount, interest rate) — use temperature 0. You want deterministic, consistent output every time. The same document should produce the same extracted JSON on every call.

For analysis and summarization tasks (summarize servicer notes, explain what risk factors exist in this loan file) — use temperature 0.3 to 0.7. A small amount of temperature makes the output more naturally written without significantly compromising accuracy.

For generating diverse candidates (generate 5 different email templates for a servicer outreach campaign) — use temperature 0.8 to 1.0. Diversity is the goal.

---

**Q7: Explain how you would store and query vector embeddings in Snowflake. What are the performance considerations?**

**A:** Snowflake supports a native VECTOR data type as of 2024. You store embeddings as `VECTOR(FLOAT, 1024)` columns. The key query pattern is `VECTOR_COSINE_SIMILARITY` or `VECTOR_L2_DISTANCE` for nearest-neighbor search.

```sql
-- Store embeddings
ALTER TABLE loan_document_chunks
ADD COLUMN embedding_vector VECTOR(FLOAT, 1024);

-- Search (exact nearest neighbor)
SELECT chunk_id, chunk_text,
    VECTOR_COSINE_SIMILARITY(embedding_vector,
        :query_embedding::VECTOR(FLOAT, 1024)) AS score
FROM loan_document_chunks
ORDER BY score DESC LIMIT 10;
```

Performance considerations: (1) Snowflake performs exact nearest-neighbor search (brute force scan), not approximate nearest-neighbor (ANN). This is accurate but scales as O(n) with the number of vectors. For tens of millions of chunks, query latency can become a concern — filter by metadata first (loan_id, document_type, date_range) to reduce the scan size. (2) Query embeddings must match the dimension of stored embeddings exactly. (3) Partition/cluster the chunk table by a high-cardinality business key (loan_id) so metadata filters eliminate most rows before the vector scan. (4) For sub-second latency requirements at scale, consider Pinecone or Azure AI Search with ANN indexing (HNSW algorithm) alongside Snowflake for bulk analytics.

---

**Q8: What is the difference between fine-tuning and prompt engineering? When is each sufficient?**

**A:** Prompt engineering modifies the input (the prompt) to elicit better behavior from a frozen, unmodified model. Techniques include: few-shot examples, chain-of-thought instructions, explicit output format specification, persona assignment, and system prompt optimization. Zero cost to implement; instant results.

Fine-tuning updates the model's weights on domain-specific data, changing what the model "knows" and how it responds by default. Requires labeled examples, compute, expertise, and ongoing maintenance.

Prompt engineering is sufficient for: most extraction and classification tasks where examples can be provided in the prompt; tasks where a well-specified system prompt plus 3–5 examples produces acceptable output; and rapid prototyping where time-to-value matters.

Fine-tuning is warranted when: the task requires domain knowledge not present in the base model (e.g., internal company terminology, proprietary data schemas); latency or cost requirements mean you need a smaller model that performs as well as a large model with a long prompt; or prompt engineering has been exhaustively explored and still falls short of required accuracy.

In practice: always exhaust prompt engineering and RAG before considering fine-tuning. Most enterprise LLM use cases are solved by prompt engineering plus RAG.

---

**Q9: You are building a system that uses GPT-4o to extract fields from 2 million loan documents. Estimate the cost and describe how you would optimize it.**

**A:** Rough estimation: average loan document is ~1,500 words, approximately 2,000 tokens. A system prompt for extraction is ~200 tokens. Input: 2,200 tokens × 2M documents = 4.4 billion input tokens. Output: ~200 tokens per document × 2M = 400M output tokens.

At GPT-4o pricing ($2.50/M input, $10.00/M output): input = $11,000, output = $4,000 — total ~$15,000. This is a one-time cost if documents are stable.

Optimization strategies: (1) **Use a cheaper model** — GPT-4o mini at $0.15/$0.60 per M tokens reduces this to ~$1,000. Validate accuracy on a sample first. (2) **Parallel batching** — use async API calls with rate limiting to process thousands of documents per minute rather than sequentially. (3) **Cache results** — hash document text and cache extracted JSON in Snowflake; never re-process a document that hasn't changed. (4) **Incremental processing** — only process new or updated documents; not the full 2M on every run. (5) **Chunk only what matters** — if you only need fields from the first page of each document, truncate before sending. (6) **Self-hosted open source** — Llama 3.1 70B on Azure/AWS GPU instances can match GPT-4o mini quality on structured extraction at infrastructure cost only; break-even over a large enough volume.

---

**Q10: What is the "lost in the middle" problem and how does it affect how you design RAG chunk ordering?**

**A:** Research has shown that transformer LLMs exhibit a U-shaped attention pattern over long contexts: they reliably attend to content near the beginning and end of the context window but struggle to utilize information placed in the middle of a long prompt. This is known as the "lost in the middle" problem.

For RAG pipeline design: (1) **Rerank results** — after retrieving top-k chunks by embedding similarity, use a cross-encoder reranker to reorder them by relevance to the query. Place the most relevant chunks at the beginning or end of the context block, not in the middle. (2) **Limit context size** — do not stuff all k=20 retrieved chunks into the prompt. Use k=3–5 high-quality chunks rather than k=20 mediocre ones. Quality beats quantity. (3) **Chunking granularity** — smaller, more precise chunks (200–300 tokens) allow the retrieval step to be more targeted, reducing the amount of irrelevant context that dilutes attention. (4) **Metadata filtering first** — filter by loan_id, date range, or document type before vector search to reduce retrieved context to genuinely relevant documents.

---

## Pro Tips

- Temperature 0 in production data pipelines. Always. Non-deterministic extraction in a data pipeline creates irreproducible outputs that are nearly impossible to debug.
- Always log token counts per API call. Token budgets spiral quickly in production — instrument before you deploy.
- Snowflake Cortex is the fastest path to LLM features for a Snowflake shop: no new infrastructure, unified security, and costs on the existing Snowflake contract. Know the available models and their capabilities.
- RAG retrieval quality is more important than LLM quality. A mediocre LLM with perfect retrieval outperforms a state-of-the-art LLM with poor retrieval. Invest engineering effort in chunking strategy, embedding model selection, and reranking.
- Store embeddings with their source text hash. When documents are updated, you can detect which embeddings need to be recomputed without re-embedding the entire corpus.
- In regulated industries (mortgage, finance), LLM outputs must be auditable. Log the exact prompt, retrieved context, and raw LLM response for every production call. You will need it for model risk management documentation.
- The sentence-transformers library (BAAI/bge-large-en-v1.5 or intfloat/e5-large-v2) provides free, high-quality embeddings you can run locally. Use them for prototyping and cost-sensitive batch jobs before committing to paid embedding APIs.
- SQL Server shops on Azure can use Azure OpenAI Service for data residency compliance — model inference stays within your Azure tenant and does not cross to OpenAI's public API.
- Know the difference between a vector store query (approximate nearest neighbor for semantic retrieval) and a traditional database query (exact match on indexed columns). Hybrid search — combining both — is the production standard: filter by loan_id, date, document type (SQL), then vector search within that filtered set.
