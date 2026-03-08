# Semantic Search & Similarity Search

[Back to Index](../index.md)

---

## Overview

Semantic search moves beyond keyword matching to understand the *meaning* of a query and return results that are conceptually relevant, even when they share no vocabulary with the query. In data engineering for the secondary mortgage market, this unlocks capabilities like searching loan documents by regulatory concept, finding similar deal structures across an MBS portfolio, or retrieving property records using natural language descriptions.

This guide covers the full spectrum from classical lexical retrieval through modern dense vector search, hybrid approaches, and production deployment on Snowflake and Azure.

---

## Key Concepts at a Glance

| Concept | One-Line Definition |
|---|---|
| TF-IDF | Weights terms by frequency in document vs. rarity across corpus |
| BM25 | Probabilistic extension of TF-IDF; standard sparse retrieval baseline |
| Dense retrieval | Encodes query and document as vectors; similarity by dot product / cosine |
| Bi-encoder | Separate encoder for query and document; fast at retrieval time |
| Cross-encoder | Jointly encodes query + document pair; slower but more accurate |
| HNSW | Hierarchical Navigable Small World graph; approximate nearest-neighbor index |
| RRF | Reciprocal Rank Fusion; merges ranked lists from multiple retrievers |
| Hybrid search | Combines sparse (BM25) and dense scores for best-of-both recall |

---

## 1. Lexical Search: BM25 and TF-IDF

### TF-IDF

TF-IDF scores a term `t` in document `d` as:

```
TF-IDF(t, d) = TF(t, d) * IDF(t)
             = (count(t,d) / len(d)) * log(N / df(t))
```

Where `N` is the total number of documents and `df(t)` is the number of documents containing `t`.

**Limitation for mortgage data:** A loan document mentioning "prepayment" 20 times scores highly for that term, but TF-IDF cannot understand that "early payoff" means the same thing.

### BM25

BM25 adds length normalization and a saturation function that prevents very high term frequency from dominating:

```
BM25(t, d) = IDF(t) * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * (|d| / avgdl)))
```

Typical defaults: `k1=1.5`, `b=0.75`.

BM25 is still the dominant baseline in production search systems and the default in Elasticsearch and Azure Cognitive Search.

```python
from rank_bm25 import BM25Okapi
import re

# Corpus: simplified loan document summaries
corpus = [
    "30-year fixed rate mortgage conforming loan Fannie Mae",
    "adjustable rate mortgage 5/1 ARM jumbo non-conforming",
    "FHA loan first-time homebuyer down payment assistance",
    "prepayment penalty clause balloon payment private label",
    "conforming loan limit conventional 30-year fixed Freddie Mac",
]

tokenized = [re.sub(r"[^a-z0-9 ]", "", doc.lower()).split() for doc in corpus]
bm25 = BM25Okapi(tokenized)

query = "conventional conforming fixed rate"
scores = bm25.get_scores(re.sub(r"[^a-z0-9 ]", "", query.lower()).split())
ranked = sorted(enumerate(scores), key=lambda x: x[1], reverse=True)
for idx, score in ranked[:3]:
    print(f"Score {score:.3f}: {corpus[idx]}")
```

---

## 2. Semantic Search: Embedding-Based Retrieval

### How Dense Retrieval Works

1. A **bi-encoder** model (e.g., `sentence-transformers/all-mpnet-base-v2`) encodes every document into a fixed-size vector (e.g., 768 dimensions) offline.
2. At query time, the same model encodes the query.
3. Similarity is computed — typically cosine similarity or inner product — against all stored document vectors.
4. The top-k most similar documents are returned.

The key insight: documents about "prepayment risk" and "early payoff penalty" will have similar embeddings even with zero lexical overlap.

### Cosine Similarity

```
cosine_similarity(A, B) = (A · B) / (||A|| * ||B||)
```

When vectors are L2-normalized (unit vectors), cosine similarity equals the dot product, which is much faster to compute.

```python
import numpy as np
from sentence_transformers import SentenceTransformer

model = SentenceTransformer("sentence-transformers/all-mpnet-base-v2")

# Mortgage document corpus
docs = [
    "The loan has a prepayment penalty clause active for the first 36 months.",
    "Early payoff of the mortgage triggers a fee equal to 3% of outstanding principal.",
    "The conforming loan follows standard Fannie Mae underwriting guidelines.",
    "LTV ratio must not exceed 80% for conventional financing without PMI.",
]

doc_embeddings = model.encode(docs, normalize_embeddings=True)

query = "What happens if the borrower pays off the loan early?"
query_embedding = model.encode([query], normalize_embeddings=True)

scores = (query_embedding @ doc_embeddings.T)[0]
ranked = sorted(enumerate(scores), key=lambda x: x[1], reverse=True)
for idx, score in ranked:
    print(f"Score {score:.4f}: {docs[idx]}")
```

---

## 3. FAISS for Scalable Similarity Search

For millions of MBS loan records, brute-force cosine similarity is too slow. FAISS provides approximate nearest neighbor (ANN) search via HNSW and IVF indexes.

```python
import faiss
import numpy as np
from sentence_transformers import SentenceTransformer

model = SentenceTransformer("sentence-transformers/all-mpnet-base-v2")
DIM = 768

# --- Build index ---
# In production: load from Snowflake stage or S3
docs = [...]  # list of document strings
embeddings = model.encode(docs, normalize_embeddings=True, batch_size=256)
embeddings = embeddings.astype(np.float32)

# HNSW index: M=32 connections per layer, efConstruction=200
index = faiss.IndexHNSWFlat(DIM, 32)
index.hnsw.efConstruction = 200
index.add(embeddings)
faiss.write_index(index, "loan_docs.index")

# --- Query ---
index = faiss.read_index("loan_docs.index")
index.hnsw.efSearch = 64  # higher = more accurate, slower

query = "non-QM loan underwriting exceptions"
q_emb = model.encode([query], normalize_embeddings=True).astype(np.float32)
distances, indices = index.search(q_emb, k=5)

for dist, idx in zip(distances[0], indices[0]):
    print(f"Distance {dist:.4f}: {docs[idx][:80]}")
```

### HNSW Tuning Parameters

| Parameter | Effect | Recommendation |
|---|---|---|
| `M` | Connections per node; higher = more accurate, more memory | 16–64 for high-recall |
| `efConstruction` | Build quality; higher = slower build, better graph | 100–400 |
| `efSearch` | Query accuracy vs. speed trade-off | 64–256 at query time |

---

## 4. Bi-Encoder vs. Cross-Encoder

| Dimension | Bi-Encoder | Cross-Encoder |
|---|---|---|
| Architecture | Query and document encoded independently | Query + document concatenated, encoded jointly |
| Speed | Very fast (pre-computed doc embeddings) | Slow (must run inference per query-doc pair) |
| Accuracy | Good | Significantly better |
| Typical use | First-stage retrieval (top-100) | Second-stage re-ranking (top-10 from top-100) |
| Example model | `all-mpnet-base-v2` | `cross-encoder/ms-marco-MiniLM-L-6-v2` |

```python
from sentence_transformers import CrossEncoder

reranker = CrossEncoder("cross-encoder/ms-marco-MiniLM-L-6-v2")

# candidates: top-20 docs from bi-encoder retrieval
query = "Fannie Mae conforming loan seller guide requirements"
candidates = [...]  # list of document strings

pairs = [[query, doc] for doc in candidates]
scores = reranker.predict(pairs)
reranked = sorted(zip(scores, candidates), reverse=True)
top5 = [doc for _, doc in reranked[:5]]
```

---

## 5. Hybrid Search with Reciprocal Rank Fusion (RRF)

Hybrid search combines the recall breadth of BM25 with the semantic precision of dense retrieval.

**RRF formula:**

```
RRF_score(d) = sum_over_rankers( 1 / (k + rank(d)) )
```

`k=60` is the standard constant that reduces the impact of high ranks.

```python
def reciprocal_rank_fusion(bm25_ranking: list, dense_ranking: list, k: int = 60) -> list:
    """
    bm25_ranking, dense_ranking: lists of doc_ids in ranked order (best first).
    Returns merged list of (doc_id, rrf_score) sorted descending.
    """
    scores = {}
    for rank, doc_id in enumerate(bm25_ranking, start=1):
        scores[doc_id] = scores.get(doc_id, 0) + 1 / (k + rank)
    for rank, doc_id in enumerate(dense_ranking, start=1):
        scores[doc_id] = scores.get(doc_id, 0) + 1 / (k + rank)
    return sorted(scores.items(), key=lambda x: x[1], reverse=True)


# Usage
bm25_ids   = [3, 1, 7, 2, 9]   # BM25 top-5 doc ids
dense_ids  = [7, 3, 5, 1, 8]   # Dense top-5 doc ids
merged = reciprocal_rank_fusion(bm25_ids, dense_ids)
print(merged)
# [(3, 0.032...), (7, 0.031...), (1, 0.030...), ...]
```

---

## 6. Snowflake Cortex Search

Snowflake Cortex Search provides managed hybrid search (BM25 + vector) directly on Snowflake tables — no external vector database required.

```sql
-- Step 1: Create a Cortex Search Service on a loan documents table
CREATE OR REPLACE CORTEX SEARCH SERVICE loan_doc_search
  ON document_text
  ATTRIBUTES loan_id, doc_type, origination_date
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 hour'
  AS
    SELECT
        loan_id,
        doc_type,
        origination_date,
        document_text
    FROM loan_documents
    WHERE doc_type IN ('appraisal', 'title', 'closing_disclosure');

-- Step 2: Query via SQL (REST API also available)
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'loan_doc_search',
    '{
        "query": "prepayment penalty early payoff fee",
        "columns": ["loan_id", "doc_type", "document_text"],
        "filter": {"@eq": {"doc_type": "closing_disclosure"}},
        "limit": 5
    }'
);
```

---

## 7. Azure Cognitive Search with Vector Fields

```python
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery
from azure.core.credentials import AzureKeyCredential
from sentence_transformers import SentenceTransformer

model = SentenceTransformer("sentence-transformers/all-mpnet-base-v2")
client = SearchClient(
    endpoint="https://<service>.search.windows.net",
    index_name="loan-docs",
    credential=AzureKeyCredential("<key>")
)

query = "property appraisal below contract price"
q_vector = model.encode(query, normalize_embeddings=True).tolist()

vector_query = VectorizedQuery(
    vector=q_vector,
    k_nearest_neighbors=50,
    fields="embedding"
)

# Hybrid: text BM25 + vector
results = client.search(
    search_text=query,          # BM25 component
    vector_queries=[vector_query],  # dense component
    select=["loan_id", "doc_type", "document_text"],
    top=10
)
for r in results:
    print(r["loan_id"], r["@search.score"])
```

---

## 8. Evaluation Metrics

### NDCG@k (Normalized Discounted Cumulative Gain)

Measures ranking quality where higher-ranked relevant results are worth more.

```
DCG@k  = sum_{i=1}^{k} rel_i / log2(i+1)
NDCG@k = DCG@k / IDCG@k          (IDCG = ideal DCG)
```

### MRR (Mean Reciprocal Rank)

```
MRR = (1/|Q|) * sum_q (1 / rank_of_first_relevant_result_q)
```

Good for tasks with a single correct answer (e.g., "find the exact loan agreement").

### Recall@k

```
Recall@k = |relevant docs in top-k| / |total relevant docs|
```

Critical for RAG pipelines: if relevant context is not retrieved, generation quality collapses.

```python
def recall_at_k(retrieved_ids: list, relevant_ids: set, k: int) -> float:
    top_k = set(retrieved_ids[:k])
    return len(top_k & relevant_ids) / len(relevant_ids) if relevant_ids else 0.0

def mrr(results_per_query: list[list], relevant_per_query: list[set]) -> float:
    rr_scores = []
    for retrieved, relevant in zip(results_per_query, relevant_per_query):
        rr = 0.0
        for rank, doc_id in enumerate(retrieved, start=1):
            if doc_id in relevant:
                rr = 1.0 / rank
                break
        rr_scores.append(rr)
    return sum(rr_scores) / len(rr_scores)
```

---

## 9. End-to-End Semantic Search System

```
Query --> [Bi-Encoder] --> Query Vector
                                |
               +----------------+----------------+
               |                                 |
         [FAISS ANN]                        [BM25 Index]
               |                                 |
          Dense Top-50                     Sparse Top-50
               |                                 |
               +----------[RRF Merge]------------+
                                |
                          Merged Top-20
                                |
                        [Cross-Encoder Re-rank]
                                |
                           Final Top-5
```

---

## Interview Q&A

**Q1. Why does BM25 often outperform TF-IDF in practice, and when would you still reach for TF-IDF?**

BM25's saturation function caps the contribution of very high term frequency, preventing a document that repeats a keyword 200 times from dominating results. Its length normalization via the `b` parameter handles documents of varying sizes better than raw TF normalization. TF-IDF remains useful when you need a simple, interpretable feature vector for downstream ML (e.g., logistic regression on document categories) because TF-IDF matrices are standard inputs for scikit-learn pipelines.

**Q2. Explain the trade-off between bi-encoders and cross-encoders. How do you use both in a production system?**

Bi-encoders encode query and document independently, so document embeddings can be pre-computed and stored. Retrieval is a fast ANN lookup — milliseconds for millions of documents. However, the model cannot compare query and document tokens directly, so relevance modeling is weaker. Cross-encoders take the query-document pair as input, allowing full attention between all tokens. This gives much better relevance scores but requires a forward pass per candidate pair. The standard pattern is a two-stage pipeline: bi-encoder retrieves top-100 candidates in <50ms; cross-encoder re-ranks to top-10 in an additional 100-300ms.

**Q3. What is HNSW and why does it scale better than a flat index?**

Hierarchical Navigable Small World is a graph-based ANN algorithm. It builds a layered graph where the top layers have long-range connections (for global navigation) and lower layers have dense local connections (for fine-grained search). A query starts at the top layer, greedily moves toward the query vector, then descends to more precise layers. This achieves O(log N) search complexity vs. O(N) for a flat brute-force index. For a corpus of 10 million loan documents, HNSW search takes ~5ms versus 2+ seconds for brute force.

**Q4. You have a search system returning good semantic results but missing exact term matches (e.g., loan number "LN-2024-0047382"). How do you fix this?**

This is the classic hybrid search problem. Dense encoders are terrible at exact string matching — a loan ID has no semantic neighbors. The fix is hybrid search: run BM25 in parallel for the exact term match and merge results using RRF. The loan ID will rank #1 in BM25; unrelated documents that happen to semantically cluster near the query will be deprioritized by RRF since they won't appear in both ranked lists. In Elasticsearch, this is the `hybrid` retriever combining `knn` + `match`. In Snowflake, Cortex Search implements this natively.

**Q5. How would you build a semantic search system for 50 million Fannie Mae/Freddie Mac loan documents stored in Snowflake?**

First, extract text from documents staged in S3/Azure Blob and chunk them (512-token windows with overlap). Embed chunks using a finance-tuned bi-encoder model running on Snowflake Container Services or a dedicated GPU cluster. Store embeddings in Snowflake as VECTOR(FLOAT, 768) columns (available in Snowflake's vector data type). Create a Cortex Search Service for managed hybrid retrieval. For custom ANN needs, export embeddings to FAISS with an IVF-PQ index (inverted file + product quantization) to reduce memory from ~150GB to ~15GB. Evaluate with a labeled test set measuring Recall@10 and NDCG@5.

**Q6. What is Reciprocal Rank Fusion and why is it preferred over score normalization for combining BM25 and dense scores?**

Score normalization (e.g., min-max scaling) is fragile because BM25 and cosine similarity scores have different distributions and scales that vary by query. A score of 0.8 in one system and 0.8 in another may represent very different confidence levels. RRF uses only rank positions, making it distribution-agnostic. It also handles the common case where a document appears in one ranked list but not the other — it simply gets no contribution from the missing list. Empirically, RRF performs on par with or better than learned fusion weights in most retrieval benchmarks.

**Q7. How do you handle domain-specific vocabulary in mortgage document search? The off-the-shelf model doesn't know what "QM Safe Harbor" or "GSE rep and warrant" means.**

Several approaches in increasing order of effectiveness: (1) Vocabulary injection at query time — expand the query using a domain glossary before encoding. (2) Fine-tune the bi-encoder using contrastive learning on in-domain query-document pairs. Positive pairs can come from user click logs, analyst queries, or synthetic data generated by an LLM. (3) Train a domain-specific embedding model from scratch using mortgage corpus via Masked Language Modeling, then fine-tune for retrieval. For most production scenarios, fine-tuning a general model like `all-mpnet-base-v2` on 10,000-50,000 domain pairs (using multiple negatives ranking loss) provides 15-30% NDCG improvement over the zero-shot baseline.

**Q8. What evaluation metrics would you use to validate a semantic search system before promoting to production, and what thresholds would you target?**

| Metric | Measurement | Target threshold |
|---|---|---|
| Recall@10 | Are relevant docs in top-10? | >0.85 for RAG pipelines |
| NDCG@5 | Ranking quality of top-5 | >0.75 |
| MRR | Mean first-hit rank | >0.70 |
| Latency p95 | Query response time | <200ms |
| Index freshness | Lag from document ingestion to searchable | <1 hour |

I'd build a labeled evaluation dataset of at least 200-500 queries with human-annotated relevant documents, representative of actual analyst queries against loan and deal documentation.

**Q9. Compare Snowflake Cortex Search, Azure Cognitive Search, and a self-managed FAISS deployment. When would you choose each?**

**Cortex Search** is best when data already lives in Snowflake and the team lacks ML infrastructure expertise. Managed service — no index tuning, automatic refresh, SQL-native. Limitation: less control over embedding model choice.

**Azure Cognitive Search** is ideal for Azure-native shops that need tight integration with Azure OpenAI, cognitive skills (OCR, entity extraction), and security (managed identity, private endpoints). Good for searching scanned PDF documents where OCR enrichment is needed.

**Self-managed FAISS** gives maximum control over the embedding model, index parameters, and serving infrastructure. Worth the operational cost when you need sub-10ms latency at scale, custom domain-adapted models, or when data cannot leave your on-premises environment due to regulatory constraints.

**Q10. How does semantic search specifically improve workflows in the secondary mortgage market compared to keyword search?**

Keyword search fails on three common secondary market problems: (1) **Synonym explosion** — analysts search for "prepayment speed" but documents say "CPR", "PSA", or "conditional prepayment rate". A domain-tuned semantic model clusters these concepts. (2) **Cross-document entity linking** — finding all documents related to a specific servicer even when the servicer name varies (abbreviations, predecessor names after M&A). (3) **Regulatory concept retrieval** — searching for "CFPB ability-to-repay rule implications" returns relevant deal analysis documents even when the exact phrase never appears. The productivity gain for credit analysts reviewing deal documentation or due diligence teams reviewing rep-and-warrant packages is substantial.

---

## Pro Tips

- **Normalize embeddings at index time.** Once vectors are L2-normalized, cosine similarity equals dot product. FAISS `IndexFlatIP` (inner product) is faster than `IndexFlatL2` and gives identical results for normalized vectors.
- **Batch encode documents.** `model.encode(docs, batch_size=256, show_progress_bar=True)` is 10-50x faster than encoding one-by-one. Use GPU if encoding millions of chunks.
- **Version your embedding model.** If you retrain or upgrade the model, all stored embeddings must be recomputed. Pin model versions in your artifact registry and store the model name alongside the embedding in Snowflake.
- **Chunk with overlap.** For long loan documents, use 512-token chunks with 64-token overlap to avoid cutting a key sentence at a chunk boundary.
- **Monitor retrieval quality in production.** Log query + top-k results + whether the user clicked / expanded a result. This implicit feedback builds labeled data for future model fine-tuning.
- **For Snowflake VECTOR columns:** use `VECTOR_COSINE_SIMILARITY` or `VECTOR_INNER_PRODUCT` functions. As of 2025, Snowflake supports `VECTOR(FLOAT, N)` columns with approximate search via Cortex and exact search via SQL functions.
- **Filter before search, not after.** If you only need documents of `doc_type = 'appraisal'`, apply that filter at the ANN index level (Cortex Search `filter`, FAISS with ID selector, or Azure Search `filter` parameter) to avoid wasted compute on irrelevant candidates.
