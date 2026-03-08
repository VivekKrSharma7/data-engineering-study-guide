# RAG (Retrieval-Augmented Generation) Architecture

[Back to Index](../index.md)

---

## Overview

Retrieval-Augmented Generation (RAG) solves the two fundamental weaknesses of standalone LLMs: hallucination and knowledge cutoff. Instead of asking the model to recall facts from its training weights, RAG retrieves the relevant context at query time and provides it to the model as grounding material. For data engineers working in the secondary mortgage market, this means building systems where analysts can query Fannie Mae seller-servicer guides, Freddie Mac guidelines, or Intex deal documentation using natural language — and get accurate, cited answers.

RAG sits at the intersection of information retrieval and generative AI. A data engineer's role is to build the data pipelines, vector stores, chunking strategies, and evaluation infrastructure that make RAG reliable in production.

---

## Key Concepts at a Glance

| Term | Definition |
|---|---|
| RAG | Retrieve relevant documents, inject into LLM prompt as context |
| Chunking | Splitting documents into retrievable units |
| Embedder | Model that converts text chunks to dense vectors |
| Vector store | Database for storing and querying embeddings |
| Retriever | Component that fetches top-k relevant chunks for a query |
| Context window | Maximum tokens an LLM can process in a single call |
| Faithfulness | Does the answer only use information from retrieved context? |
| Relevance | Does the context retrieved match what the query needs? |
| HyDE | Hypothetical Document Embeddings — generate a fake answer to improve retrieval |
| RAGAS | Open-source RAG evaluation framework |

---

## 1. RAG vs. Fine-Tuning: When to Use Each

This is one of the most common interview questions. The answer depends on what problem you are solving.

| Dimension | RAG | Fine-Tuning |
|---|---|---|
| Knowledge update frequency | Real-time / daily | Requires retraining |
| Factual grounding | Strong (cites sources) | Weak (bakes in facts) |
| Data volume needed | Retrieval corpus only | Thousands of labeled examples |
| Cost | Inference + retrieval | Training compute |
| Best for | Proprietary docs, changing data | Style, format, domain vocabulary |
| Hallucination risk | Low (context is provided) | Higher for specific facts |

**Mortgage market example:** To answer questions about the current Fannie Mae Selling Guide (updated quarterly), use RAG — you cannot retrain a model every quarter. To teach a model to output structured JSON in your internal deal schema format, use fine-tuning (or structured output prompting).

**Combination approach:** Fine-tune the embedding model on domain pairs to improve retrieval, use a general LLM for generation with RAG context.

---

## 2. RAG Pipeline Components

```
[Source Documents]
        |
   [Document Loader]   <-- PDF, HTML, Snowflake tables, S3 files
        |
   [Text Chunker]      <-- Split into retrievable units
        |
   [Embedder]          <-- sentence-transformers, OpenAI ada-002, Snowflake arctic-embed
        |
   [Vector Store]      <-- FAISS, Pinecone, Snowflake VECTOR, Azure AI Search
        |
   [Index]             <-- Built once, queried many times

                           At query time:
[User Query] --> [Embedder] --> [Retriever] --> [Top-k Chunks]
                                                       |
                                              [Context Assembly]
                                                       |
                                              [LLM (Claude/GPT-4)]
                                                       |
                                              [Generated Answer]
```

---

## 3. Chunking Strategies

Chunking is the most underestimated engineering decision in RAG. Bad chunking degrades retrieval quality regardless of model quality.

### Fixed-Size Chunking

```python
def fixed_size_chunks(text: str, chunk_size: int = 512, overlap: int = 64) -> list[str]:
    """Split text into overlapping fixed-size token windows."""
    words = text.split()
    chunks = []
    for i in range(0, len(words), chunk_size - overlap):
        chunk = " ".join(words[i : i + chunk_size])
        if chunk:
            chunks.append(chunk)
    return chunks
```

Simple but ignores document structure. A chunk may start mid-sentence.

### Recursive Character Splitting (LangChain default)

```python
from langchain.text_splitter import RecursiveCharacterTextSplitter

splitter = RecursiveCharacterTextSplitter(
    chunk_size=1000,
    chunk_overlap=100,
    separators=["\n\n", "\n", ". ", " ", ""],
)
chunks = splitter.split_text(document_text)
```

Tries to split at paragraph boundaries first, then sentences, then words. Preserves more semantic coherence.

### Semantic Chunking

```python
from langchain_experimental.text_splitter import SemanticChunker
from langchain_openai import OpenAIEmbeddings

# Split where embedding similarity drops below threshold
splitter = SemanticChunker(
    OpenAIEmbeddings(),
    breakpoint_threshold_type="percentile",
    breakpoint_threshold_amount=95,
)
chunks = splitter.split_text(document_text)
```

Groups sentences with similar meaning into the same chunk. More expensive (requires embedding sentences) but significantly better for heterogeneous documents like loan prospectuses.

### Chunking Strategy Comparison

| Strategy | Speed | Quality | Best For |
|---|---|---|---|
| Fixed-size | Fast | Poor | Simple corpora, uniform docs |
| Recursive character | Fast | Good | General documents |
| Sentence-based | Medium | Good | Narrative text |
| Semantic | Slow | Best | Mixed-content PDFs, prospectuses |
| Document-structure-aware | Medium | Best | HTML, structured reports with headers |

**Mortgage market guidance:** Fannie Mae/Freddie Mac guidelines have deep hierarchical structure (chapters > sections > subsections). Use header-aware chunking that retains the section path as metadata, e.g., `{"section": "B3-4.3-04", "title": "Personal Gifts"}` stored alongside each chunk.

---

## 4. Naive RAG vs. Advanced RAG vs. Modular RAG

### Naive RAG

```
Query --> Embed --> ANN Search --> Top-k Chunks --> LLM --> Answer
```

Works for simple corpora. Fails when:
- Query is ambiguous or multi-part
- Relevant information is spread across multiple documents
- The question requires reasoning, not just retrieval

### Advanced RAG

Adds pre-retrieval and post-retrieval enhancements:

**Pre-retrieval:**
- Query rewriting / expansion
- HyDE (Hypothetical Document Embeddings)
- Multi-query retrieval

**Post-retrieval:**
- Re-ranking with cross-encoder
- Context compression (remove irrelevant sentences)
- Lost-in-the-middle mitigation (reorder chunks)

### HyDE (Hypothetical Document Embeddings)

The insight: a query like "What is the minimum FICO for a Fannie Mae conforming loan?" is stylistically different from the guideline text that answers it. HyDE generates a hypothetical answer and embeds that instead of the raw query.

```python
from anthropic import Anthropic

client = Anthropic()

def hyde_retrieval(query: str, retriever, model="claude-3-5-haiku-20241022") -> list:
    # Step 1: Generate hypothetical answer
    response = client.messages.create(
        model=model,
        max_tokens=300,
        messages=[{
            "role": "user",
            "content": (
                f"Write a short passage from a mortgage guideline document that "
                f"would answer this question: {query}\n\nPassage:"
            )
        }]
    )
    hypothetical_doc = response.content[0].text

    # Step 2: Embed the hypothetical document, not the raw query
    results = retriever.search(hypothetical_doc, top_k=5)
    return results
```

### Multi-Query Retrieval

```python
def multi_query_retrieval(query: str, retriever, n_variants: int = 3) -> list:
    """Generate multiple query variants, retrieve for each, deduplicate."""
    response = client.messages.create(
        model="claude-3-5-haiku-20241022",
        max_tokens=200,
        messages=[{
            "role": "user",
            "content": (
                f"Generate {n_variants} alternative phrasings of this search query "
                f"for a mortgage document search system. Return one per line.\n\n"
                f"Original: {query}"
            )
        }]
    )
    variants = response.content[0].text.strip().split("\n")
    variants = [query] + [v.strip() for v in variants if v.strip()]

    seen_ids = set()
    all_results = []
    for variant in variants:
        results = retriever.search(variant, top_k=10)
        for r in results:
            if r["id"] not in seen_ids:
                seen_ids.add(r["id"])
                all_results.append(r)
    return all_results[:20]  # cap total candidates
```

---

## 5. Complete RAG Pipeline with Snowflake + Claude

```python
import snowflake.connector
from anthropic import Anthropic
from sentence_transformers import SentenceTransformer
import numpy as np
import json

# --- Configuration ---
SNOWFLAKE_CONFIG = {
    "account": "<account>",
    "user": "<user>",
    "password": "<password>",
    "warehouse": "COMPUTE_WH",
    "database": "MORTGAGE_DB",
    "schema": "RAG",
}
EMBED_MODEL = "sentence-transformers/all-mpnet-base-v2"
TOP_K = 5

# --- Clients ---
embedder = SentenceTransformer(EMBED_MODEL)
llm = Anthropic()
conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)


def retrieve_chunks(query: str, top_k: int = TOP_K) -> list[dict]:
    """Retrieve top-k chunks using Snowflake vector similarity search."""
    q_emb = embedder.encode(query, normalize_embeddings=True).tolist()
    q_emb_str = json.dumps(q_emb)

    sql = f"""
    SELECT
        chunk_id,
        source_document,
        section_path,
        chunk_text,
        VECTOR_COSINE_SIMILARITY(
            embedding,
            {q_emb_str}::VECTOR(FLOAT, 768)
        ) AS similarity
    FROM mortgage_chunks
    ORDER BY similarity DESC
    LIMIT {top_k}
    """
    cursor = conn.cursor(snowflake.connector.DictCursor)
    cursor.execute(sql)
    return cursor.fetchall()


def build_context(chunks: list[dict]) -> str:
    context_parts = []
    for i, chunk in enumerate(chunks, 1):
        context_parts.append(
            f"[Source {i}: {chunk['SOURCE_DOCUMENT']} | {chunk['SECTION_PATH']}]\n"
            f"{chunk['CHUNK_TEXT']}"
        )
    return "\n\n---\n\n".join(context_parts)


def rag_query(question: str) -> dict:
    # Retrieve
    chunks = retrieve_chunks(question)
    context = build_context(chunks)

    # Generate
    prompt = f"""You are an expert on mortgage guidelines and secondary market practices.
Answer the question using ONLY the provided context. If the context does not contain
sufficient information, say so explicitly. Cite the source number for each claim.

Context:
{context}

Question: {question}

Answer:"""

    response = llm.messages.create(
        model="claude-opus-4-5",
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
    )

    return {
        "answer": response.content[0].text,
        "sources": [
            {
                "source": c["SOURCE_DOCUMENT"],
                "section": c["SECTION_PATH"],
                "similarity": round(c["SIMILARITY"], 4),
            }
            for c in chunks
        ],
        "tokens_used": response.usage.input_tokens + response.usage.output_tokens,
    }


# Example usage
result = rag_query(
    "What are the Fannie Mae requirements for gift funds used as a down payment?"
)
print(result["answer"])
print("\nSources:")
for s in result["sources"]:
    print(f"  {s['source']} | {s['section']} (similarity: {s['similarity']})")
```

---

## 6. RAG with Snowflake Cortex (Cortex Search + COMPLETE)

```sql
-- Query Cortex Search from SQL and feed results to COMPLETE
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'claude-opus-4-5',
    CONCAT(
        'Answer the following question using only the provided context. ',
        'If the answer is not in the context, say so.\n\n',
        'Context:\n',
        search_results.chunk_text,
        '\n\nQuestion: What is the maximum DTI ratio for a conforming loan?\n\nAnswer:'
    )
) AS answer
FROM (
    SELECT LISTAGG(value:chunk_text::STRING, '\n\n') AS chunk_text
    FROM TABLE(
        FLATTEN(
            SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                'loan_guidelines_search',
                '{
                    "query": "maximum DTI ratio conforming loan",
                    "columns": ["chunk_text", "source_document"],
                    "limit": 5
                }'
            ):results
        )
    )
) AS search_results;
```

---

## 7. RAG Evaluation with RAGAS

RAGAS measures four dimensions of RAG quality:

| Metric | Measures | How |
|---|---|---|
| Faithfulness | Does answer stay within context? | LLM judges if each claim is supported by context |
| Answer Relevancy | Does answer address the question? | Reverse-generate questions from the answer, compare to original |
| Context Recall | Were all necessary facts retrieved? | Compare retrieved context to ground truth answer |
| Context Precision | Are retrieved chunks actually useful? | LLM judges which retrieved chunks contributed to the answer |

```python
from ragas import evaluate
from ragas.metrics import faithfulness, answer_relevancy, context_recall, context_precision
from datasets import Dataset

# Build evaluation dataset
eval_data = {
    "question": [
        "What is the minimum FICO score for a Fannie Mae conforming loan?",
        "Can gift funds be used for a down payment on a conventional loan?",
    ],
    "answer": [
        result["answer"] for result in rag_results
    ],
    "contexts": [
        [c["chunk_text"] for c in result["chunks"]] for result in rag_results
    ],
    "ground_truth": [
        "The minimum credit score is 620 for most Fannie Mae loan products.",
        "Yes, gift funds from an acceptable donor can be used for all or part of the down payment.",
    ],
}

dataset = Dataset.from_dict(eval_data)
scores = evaluate(
    dataset,
    metrics=[faithfulness, answer_relevancy, context_recall, context_precision],
)
print(scores)
# {'faithfulness': 0.93, 'answer_relevancy': 0.88, 'context_recall': 0.81, 'context_precision': 0.76}
```

---

## 8. LangChain RAG Implementation

```python
from langchain.document_loaders import PyPDFLoader
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain_community.vectorstores import FAISS
from langchain_openai import OpenAIEmbeddings, ChatOpenAI
from langchain.chains import RetrievalQA
from langchain.prompts import PromptTemplate

# Load and chunk document
loader = PyPDFLoader("fannie_mae_selling_guide.pdf")
pages = loader.load()

splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=100)
chunks = splitter.split_documents(pages)

# Build vector store
embeddings = OpenAIEmbeddings(model="text-embedding-3-small")
vectorstore = FAISS.from_documents(chunks, embeddings)
retriever = vectorstore.as_retriever(search_kwargs={"k": 5})

# Custom prompt for mortgage domain
prompt_template = """You are a mortgage guidelines expert. Use the following context
from Fannie Mae documentation to answer the question accurately.

Context:
{context}

Question: {question}

Provide a precise answer with section references where possible:"""

PROMPT = PromptTemplate(
    template=prompt_template, input_variables=["context", "question"]
)

# Build chain
llm = ChatOpenAI(model="gpt-4o", temperature=0)
qa_chain = RetrievalQA.from_chain_type(
    llm=llm,
    chain_type="stuff",
    retriever=retriever,
    chain_type_kwargs={"prompt": PROMPT},
    return_source_documents=True,
)

result = qa_chain.invoke({"query": "What are the LTV limits for cash-out refinance?"})
print(result["result"])
```

---

## 9. Advanced RAG: Context Compression

When retrieved chunks contain irrelevant sentences, feeding them verbatim wastes tokens and dilutes the signal.

```python
from langchain.retrievers import ContextualCompressionRetriever
from langchain.retrievers.document_compressors import LLMChainExtractor
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(model="gpt-4o-mini", temperature=0)
compressor = LLMChainExtractor.from_llm(llm)

compression_retriever = ContextualCompressionRetriever(
    base_compressor=compressor,
    base_retriever=retriever,
)

# Now only the sentences relevant to the query are returned
compressed_docs = compression_retriever.get_relevant_documents(
    "What documentation is required for self-employed borrowers?"
)
```

---

## 10. Production Considerations

### Latency Budget

| Stage | Typical latency | Optimization |
|---|---|---|
| Query embedding | 10-30ms | Cache common queries, use smaller model |
| Vector search (ANN) | 5-50ms | HNSW efSearch tuning, GPU index |
| Cross-encoder rerank | 50-200ms | Skip for low-stakes queries |
| LLM generation | 500-3000ms | Streaming, smaller model for simple queries |
| **Total** | **600-3300ms** | Target <2s for interactive use |

### Cost Management

```python
import tiktoken

def estimate_rag_cost(
    query: str,
    chunks: list[str],
    model: str = "gpt-4o",
    cost_per_1k_input: float = 0.005,
    cost_per_1k_output: float = 0.015,
) -> dict:
    enc = tiktoken.encoding_for_model(model)
    context = "\n\n".join(chunks)
    input_tokens = len(enc.encode(query + context)) + 200  # system prompt
    estimated_output = 300  # typical answer length

    return {
        "input_tokens": input_tokens,
        "estimated_output_tokens": estimated_output,
        "estimated_cost_usd": (
            input_tokens / 1000 * cost_per_1k_input
            + estimated_output / 1000 * cost_per_1k_output
        ),
    }
```

### Hallucination Reduction Checklist

1. Keep chunk size <= 512 tokens; avoid overwhelming the context window.
2. Instruct the model explicitly: "If the answer is not in the context, say you don't know."
3. Use temperature=0 for factual Q&A.
4. Add faithfulness checking as a post-generation step using a smaller LLM judge.
5. Include source citations in the prompt and require the model to cite them.
6. For critical decisions (loan eligibility, compliance), add a human review step.

---

## Interview Q&A

**Q1. What is RAG and why is it preferred over fine-tuning for most enterprise document Q&A use cases?**

RAG retrieves relevant documents at query time and provides them to the LLM as context, allowing the model to generate grounded, cited answers. Fine-tuning bakes knowledge into model weights, which is expensive to update and prone to hallucination on specific facts. For mortgage guidelines that change quarterly, RAG lets you update the knowledge base by re-indexing documents without any model retraining. Fine-tuning is better for teaching the model a consistent output format or domain-specific reasoning style.

**Q2. Walk me through the complete data pipeline for a RAG system from raw PDF to answerable query.**

(1) **Ingest:** Load PDFs using a document loader (PyMuPDF, LangChain PyPDFLoader). Extract text, preserve structural metadata (page, section header). (2) **Chunk:** Apply recursive character splitting or semantic chunking. Store metadata alongside each chunk in the vector store. (3) **Embed:** Encode chunks using a bi-encoder model. Store vectors in a vector database (Snowflake VECTOR column, FAISS, Pinecone). (4) **Index refresh:** Build an ETL pipeline to detect new or updated documents and re-embed only changed chunks. (5) **Query:** At runtime, embed the query, retrieve top-k chunks via ANN search, optionally re-rank, assemble context, call LLM, return answer with source citations.

**Q3. What is HyDE and when does it help? When does it hurt?**

HyDE generates a hypothetical answer to the query and uses that hypothetical as the retrieval query instead of the raw question. It helps when the query is phrased very differently from the document style — a short question vs. a long guideline paragraph. It helps close the query-document distributional gap. It hurts when the LLM generates a confident-sounding but factually wrong hypothetical that steers retrieval away from the correct documents. It also adds LLM latency to every retrieval call. Use it when baseline Recall@5 is below 0.70 and you have measurable room to improve.

**Q4. You deploy a RAG system for Freddie Mac guidelines and users report that answers are correct but often miss details spread across multiple sections. How do you debug and fix this?**

This is a retrieval coverage problem. Debug by logging retrieved chunk IDs for failing queries and checking whether the missing sections appear anywhere in the top-20 retrieved chunks or whether they are not being retrieved at all. Fixes: (1) **Increase top-k** from 5 to 10-15. (2) **Use multi-query retrieval** to generate sub-questions for compound queries. (3) **Improve chunking** — if related content is split across chunk boundaries, add overlap or use semantic chunking. (4) **Add a synthesis step** — after retrieving top-k, use a second LLM call to identify if the answer requires information not in the current context and trigger a follow-up retrieval.

**Q5. Explain the RAGAS evaluation framework metrics and how you would use them to track RAG system quality over time.**

RAGAS evaluates four dimensions: **Faithfulness** (does every claim in the answer appear in the context — prevents hallucination); **Answer Relevancy** (does the answer actually address the question, not a related tangent); **Context Recall** (were all facts needed for a complete answer retrieved); **Context Precision** (of retrieved chunks, what fraction were actually useful). I'd build a labeled golden dataset of 300-500 representative queries with ground truth answers, run RAGAS weekly against the production system, and alert if faithfulness drops below 0.85 or context recall drops below 0.75. Track these metrics alongside user satisfaction scores from a thumbs-up/down feedback widget.

**Q6. How would you implement RAG using only Snowflake infrastructure, without an external vector database?**

Snowflake supports this end-to-end: (1) Store document chunks in a table with a `VECTOR(FLOAT, 768)` column for embeddings. (2) Generate embeddings using `SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m', chunk_text)` — runs inside Snowflake, no data leaves the account. (3) Use `VECTOR_COSINE_SIMILARITY` for exact search or create a Cortex Search Service for managed ANN search. (4) Use `SNOWFLAKE.CORTEX.COMPLETE('claude-opus-4-5', prompt)` for generation. (5) Combine with Snowflake Notebooks or Streamlit in Snowflake for the UI. This is highly attractive for mortgage companies with strict data residency requirements — the entire RAG pipeline runs within the governed Snowflake environment.

**Q7. What are the main causes of low faithfulness scores in a RAG system, and how do you fix each?**

| Cause | Fix |
|---|---|
| Insufficient context retrieved | Increase top-k, improve chunking, use hybrid search |
| LLM ignores context and uses parametric memory | Stronger system prompt instruction, lower temperature |
| Context window too long (lost-in-the-middle) | Compress context, use reranker to put best chunk first |
| Ambiguous query retrieves wrong context | Add query rewriting, use HyDE |
| LLM model size too small | Upgrade to larger model |

**Q8. How do you handle a RAG system where documents are updated frequently — for example, weekly servicer bulletins from Fannie Mae?**

Build an incremental indexing pipeline: (1) Track document versions using a hash or last-modified timestamp in a `document_registry` table. (2) When new documents arrive, compare against the registry. (3) For changed documents, delete existing chunks from the vector store (by `source_document` foreign key) and re-embed the updated version. (4) For new documents, chunk and embed normally. (5) Never re-embed unchanged documents. (6) Schedule via Snowflake Tasks or Airflow with a daily or real-time trigger. (7) Keep a `valid_from` / `valid_to` on chunk records to support point-in-time retrieval — important for audit trails in mortgage compliance scenarios.

**Q9. Compare LangChain and LlamaIndex for building RAG systems. When would you choose one over the other?**

**LangChain** is a general-purpose agent and chain framework with strong ecosystem support and more integrations (100+ vector stores, document loaders, LLM providers). Better for complex multi-step agents that combine RAG with tool use. Steeper learning curve; abstractions can obscure what's happening.

**LlamaIndex** is purpose-built for indexing and retrieval over structured and unstructured data. Excellent for complex document hierarchies, knowledge graphs, and structured data (SQL + RAG hybrid). Simpler API for pure RAG use cases. Better native support for advanced indexing structures like hierarchical node parsers.

For a mortgage document Q&A system, I'd choose LlamaIndex if the document structure (numbered sections, subsections, cross-references) is important to preserve. I'd choose LangChain if the application needs to combine RAG with API calls, calculations, or structured data queries as part of an agentic workflow.

**Q10. What production architecture decisions would you make for a RAG system serving 500 concurrent analysts in a mortgage company?**

(1) **Caching:** Cache embeddings for common queries (Redis with TTL). Cache LLM responses for identical query+context pairs. (2) **Async architecture:** Use async retrieval (asyncio + async Snowflake connector) to parallelize BM25 + dense retrieval. (3) **Tiered retrieval:** Fast ANN search for candidate retrieval, cross-encoder reranking only for the final 10 results. (4) **Streaming:** Stream LLM tokens to the UI to reduce perceived latency. (5) **Load balancing:** Multiple retrieval replicas behind a load balancer; Snowflake Cortex Search handles this automatically. (6) **Monitoring:** Log query latency, retrieval quality metrics, LLM cost per query, error rates. Use Snowflake's query history for retrieval audit. (7) **Security:** Row-level security on chunks (not all analysts can see all deal data); store chunk permissions in Snowflake and apply as retrieval filter.

---

## Pro Tips

- **Chunk metadata is as important as chunk content.** Store `source_document`, `section_path`, `page_number`, and `ingestion_timestamp` with every chunk. This enables filtered retrieval and source citation.
- **Test chunking on representative documents before building the full index.** Look at 20 random chunks — do they make sense in isolation? A chunk that starts mid-sentence or contains garbled OCR text degrades the entire pipeline.
- **Use a smaller, faster model for re-ranking and compression.** `claude-3-5-haiku-20241022` for context compression; `claude-opus-4-5` only for final generation. This keeps costs manageable at scale.
- **Build a query log table from day one.** Every query, retrieved chunk IDs, similarity scores, and user feedback (thumbs up/down) is gold data for future evaluation and model improvement.
- **Context assembly order matters.** LLMs suffer from "lost in the middle" — information in the middle of a long context is retrieved less reliably than information at the beginning or end. Place the most relevant chunk first.
- **For Intex CDI data:** Intex deal documents (prospectuses, remittance reports) have consistent structure. Build a document-structure-aware chunker that preserves deal section hierarchy and adds deal ID + tranche ID as metadata for filtered RAG.
- **Token budget management:** Set a hard limit on context tokens per query (e.g., 6,000 tokens). If your top-k chunks exceed the budget, prioritize by reranker score and truncate the lowest-ranked chunks.
