# Vector Databases (pgvector, Pinecone, Weaviate, Chroma, Qdrant)

[Back to Index](README.md)

---

## Overview

Vector databases store and retrieve high-dimensional numerical vectors — the mathematical representations produced by embedding models. They are the storage layer of modern AI pipelines: whenever you build semantic search, RAG (Retrieval-Augmented Generation), or similarity-based recommendations, a vector database is how you find relevant data at query time.

For a senior data engineer in the secondary mortgage market, this means: searching servicer notes by semantic meaning instead of keywords, finding similar borrower profiles for risk modeling, locating comparable properties for AVM validation, and powering document retrieval for compliance Q&A systems.

---

## What Are Vectors and Why Do They Need a Specialized Store?

An embedding model converts text, images, or structured data into a dense float array — a vector. Two semantically similar texts produce vectors that are close together in high-dimensional space, even if they share no keywords.

```
"Borrower is 60 days past due" → [0.12, -0.45, 0.88, ..., 0.33]  (768 floats)
"Mortgagor missed two payments"  → [0.13, -0.44, 0.87, ..., 0.31]  (768 floats)
# These vectors are very close despite sharing no words
```

A traditional SQL `WHERE note LIKE '%past due%'` would not match the second sentence. Vector search finds it because the vectors are close.

**Why not just store vectors in SQL?** You can store them (float arrays), but finding the nearest neighbors across millions of vectors requires specialized index structures. A naive scan of 10M 768-dimensional vectors is computationally prohibitive. Vector databases provide Approximate Nearest Neighbor (ANN) indexes that return results in milliseconds.

---

## Vector Similarity Metrics

| Metric | Formula | Best For |
|---|---|---|
| Cosine Similarity | dot(A,B) / (\|A\| * \|B\|) | Normalized text embeddings (most common) |
| Dot Product | sum(A[i] * B[i]) | When vectors are pre-normalized (equals cosine) |
| Euclidean Distance | sqrt(sum((A[i]-B[i])^2)) | Spatial/image embeddings |
| Manhattan Distance | sum(abs(A[i]-B[i])) | Sparse vectors, tabular data |

For text embeddings produced by Sentence Transformers or OpenAI, **cosine similarity** is the standard choice. Many libraries normalize embeddings at creation time, making cosine similarity equivalent to dot product — which is faster to compute.

```python
import numpy as np

def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    return np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b))

# Example: two servicer note embeddings
note_a = np.array([0.12, -0.45, 0.88, 0.33])  # "60 days past due"
note_b = np.array([0.13, -0.44, 0.87, 0.31])  # "missed two payments"
note_c = np.array([0.95, 0.10, -0.20, 0.05])  # "borrower made early payoff"

print(cosine_similarity(note_a, note_b))  # ~0.999 — very similar
print(cosine_similarity(note_a, note_c))  # ~0.05 — very different
```

---

## ANN Index Algorithms

Finding exact nearest neighbors requires scanning every vector — O(n). ANN algorithms trade a small accuracy loss for dramatically faster search.

### HNSW (Hierarchical Navigable Small World)

HNSW builds a multi-layer graph where each node connects to nearby nodes. Search starts at the top (sparse) layer and navigates down to the bottom (dense) layer, pruning the search space at each level.

- **Pros:** Excellent recall (>95%), fast queries, supports incremental inserts
- **Cons:** High memory usage (~100 bytes per vector per dimension in the graph)
- **Used by:** pgvector, Qdrant, Weaviate, Milvus, SQL Server 2025

### IVF (Inverted File Index)

IVF clusters vectors using k-means at build time. At query time, search is limited to the nearest cluster(s).

- **Pros:** Lower memory than HNSW, good for very large datasets
- **Cons:** Requires training phase, poor performance on newly inserted vectors until re-indexed
- **Used by:** Pinecone, Faiss, Milvus

### LSH (Locality Sensitive Hashing)

LSH hashes similar vectors to the same bucket using random projections.

- **Pros:** Extremely fast, simple
- **Cons:** Lower recall than HNSW/IVF, best for approximate use cases
- **Used by:** Older systems, rarely preferred today

| Algorithm | Recall | Memory | Insert Speed | Query Speed |
|---|---|---|---|---|
| HNSW | High (>95%) | High | Fast | Very Fast |
| IVF | Medium-High | Medium | Slow (rebuild) | Fast |
| LSH | Medium | Low | Very Fast | Very Fast |
| Flat (exact) | 100% | Low | Fast | Slow at scale |

---

## Major Vector Databases

### pgvector (PostgreSQL Extension)

pgvector adds a `vector` data type and ANN indexing to PostgreSQL. If your organization already runs PostgreSQL, pgvector is the lowest-friction path to vector search.

```sql
-- Install the extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Create a table with an embedding column
CREATE TABLE loan_documents (
    doc_id      SERIAL PRIMARY KEY,
    loan_id     VARCHAR(20),
    doc_type    VARCHAR(50),
    doc_text    TEXT,
    embedding   vector(768)  -- 768-dimensional SBERT embedding
);

-- Create an HNSW index
CREATE INDEX ON loan_documents
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- Insert a document with its embedding (embedding generated externally)
INSERT INTO loan_documents (loan_id, doc_type, doc_text, embedding)
VALUES ('LN-2023-00123', 'servicer_note', 'Borrower is 60 days past due',
        '[0.12, -0.45, 0.88, ...]'::vector);

-- Semantic search: find the 5 most similar notes to a query embedding
SELECT
    loan_id,
    doc_text,
    1 - (embedding <=> '[0.13, -0.44, 0.87, ...]'::vector) AS similarity
FROM loan_documents
ORDER BY embedding <=> '[0.13, -0.44, 0.87, ...]'::vector
LIMIT 5;
```

pgvector operators:
- `<=>` — cosine distance (1 - cosine similarity)
- `<->` — euclidean distance
- `<#>` — negative dot product (for dot product similarity, order ASC)

### Pinecone

Pinecone is a fully managed cloud vector database. No infrastructure to manage, handles billions of vectors, strong at filtering.

```python
from pinecone import Pinecone, ServerlessSpec

pc = Pinecone(api_key="your-api-key")

# Create an index (do once)
pc.create_index(
    name="loan-documents",
    dimension=768,
    metric="cosine",
    spec=ServerlessSpec(cloud="aws", region="us-east-1")
)

index = pc.Index("loan-documents")

# Upsert vectors (id, values, metadata)
vectors = [
    {
        "id": "LN-2023-00123-note-1",
        "values": [0.12, -0.45, 0.88, ...],  # 768 floats
        "metadata": {
            "loan_id": "LN-2023-00123",
            "doc_type": "servicer_note",
            "state": "TX",
            "loan_status": "Delinquent"
        }
    }
]
index.upsert(vectors=vectors)

# Query with metadata filtering (hybrid: vector + structured filter)
results = index.query(
    vector=[0.13, -0.44, 0.87, ...],
    top_k=10,
    filter={"state": {"$eq": "TX"}, "loan_status": {"$eq": "Delinquent"}},
    include_metadata=True
)

for match in results.matches:
    print(f"ID: {match.id}, Score: {match.score:.4f}, Loan: {match.metadata['loan_id']}")
```

### Weaviate

Open-source, multi-modal, with a built-in schema and optional native vectorization.

```python
import weaviate
from weaviate.classes.config import Configure, Property, DataType

client = weaviate.connect_to_local()

# Define a collection (schema)
client.collections.create(
    name="LoanDocument",
    vectorizer_config=Configure.Vectorizer.none(),  # bring your own vectors
    properties=[
        Property(name="loan_id", data_type=DataType.TEXT),
        Property(name="doc_type", data_type=DataType.TEXT),
        Property(name="doc_text", data_type=DataType.TEXT),
        Property(name="state", data_type=DataType.TEXT),
    ]
)

collection = client.collections.get("LoanDocument")

# Insert with pre-computed vector
collection.data.insert(
    properties={
        "loan_id": "LN-2023-00123",
        "doc_type": "servicer_note",
        "doc_text": "Borrower is 60 days past due",
        "state": "TX"
    },
    vector=[0.12, -0.45, 0.88, ...]
)

# Semantic search with filter
results = collection.query.near_vector(
    near_vector=[0.13, -0.44, 0.87, ...],
    limit=5,
    filters=weaviate.classes.query.Filter.by_property("state").equal("TX")
)
for obj in results.objects:
    print(obj.properties["loan_id"], obj.metadata.distance)

client.close()
```

### Chroma

Local, Python-native, zero infrastructure. Best for development, prototyping, and small-scale production (< 1M vectors).

```python
import chromadb
from chromadb.utils import embedding_functions

# Local persistent storage
client = chromadb.PersistentClient(path="/data/loan-chroma")

# Use a Sentence Transformer for automatic embedding
ef = embedding_functions.SentenceTransformerEmbeddingFunction(
    model_name="all-MiniLM-L6-v2"
)

collection = client.get_or_create_collection(
    name="loan_servicer_notes",
    embedding_function=ef,
    metadata={"hnsw:space": "cosine"}
)

# Add documents — Chroma embeds them automatically
collection.add(
    documents=[
        "Borrower is 60 days past due on mortgage",
        "Mortgagor missed two consecutive monthly payments",
        "Borrower made full payoff, loan closed in good standing"
    ],
    metadatas=[
        {"loan_id": "LN-001", "state": "TX"},
        {"loan_id": "LN-002", "state": "FL"},
        {"loan_id": "LN-003", "state": "CA"}
    ],
    ids=["note-1", "note-2", "note-3"]
)

# Query — Chroma embeds the query automatically
results = collection.query(
    query_texts=["loan is delinquent"],
    n_results=2,
    where={"state": "TX"}
)
print(results["documents"])
print(results["distances"])
```

### Qdrant

Rust-based, fast, excellent filtering, strong for production workloads. Docker or managed cloud.

```python
from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance, VectorParams, PointStruct, Filter, FieldCondition, MatchValue
)

client = QdrantClient(url="http://localhost:6333")

# Create a collection
client.create_collection(
    collection_name="loan_documents",
    vectors_config=VectorParams(size=768, distance=Distance.COSINE)
)

# Upsert points
client.upsert(
    collection_name="loan_documents",
    points=[
        PointStruct(
            id=1,
            vector=[0.12, -0.45, 0.88, ...],
            payload={
                "loan_id": "LN-2023-00123",
                "doc_type": "servicer_note",
                "state": "TX",
                "delinquency_days": 60
            }
        )
    ]
)

# Search with filter
results = client.search(
    collection_name="loan_documents",
    query_vector=[0.13, -0.44, 0.87, ...],
    query_filter=Filter(
        must=[
            FieldCondition(key="state", match=MatchValue(value="TX")),
            FieldCondition(key="delinquency_days", range={"gte": 30})
        ]
    ),
    limit=5
)
for hit in results:
    print(hit.id, hit.score, hit.payload["loan_id"])
```

### Milvus

Distributed, scales to billions of vectors, cloud-native. Used in large enterprise search systems.

| Database | Deployment | Scale | Best For |
|---|---|---|---|
| pgvector | Self-hosted (PG) | Millions | Existing PG users |
| Pinecone | Managed cloud | Billions | Zero-ops, production |
| Weaviate | Self/managed | Billions | Multi-modal, schema-rich |
| Chroma | Local/server | < 1M | Dev, prototyping |
| Qdrant | Self/managed | Billions | Rust speed, rich filters |
| Milvus | Self/managed | Trillions | Distributed enterprise |

---

## Snowflake Vector Data Type

Snowflake added a native `VECTOR` type in 2024, enabling vector storage and similarity search without leaving Snowflake.

```sql
-- Create a table with a vector column (768-dimensional floats)
CREATE OR REPLACE TABLE loan_note_embeddings (
    note_id       STRING,
    loan_id       STRING,
    note_text     STRING,
    note_date     DATE,
    embedding     VECTOR(FLOAT, 768)
);

-- Insert with casting from array
INSERT INTO loan_note_embeddings
SELECT
    note_id,
    loan_id,
    note_text,
    note_date,
    embed_loan_text(note_text)::VECTOR(FLOAT, 768)  -- from a SPCS embedding function
FROM raw_servicer_notes;

-- Cosine similarity search using VECTOR_COSINE_SIMILARITY
SELECT
    loan_id,
    note_text,
    VECTOR_COSINE_SIMILARITY(
        embedding,
        (SELECT embedding FROM loan_note_embeddings WHERE note_id = 'REF-NOTE-001')
    ) AS similarity
FROM loan_note_embeddings
ORDER BY similarity DESC
LIMIT 10;

-- Alternatively, using VECTOR_L2_DISTANCE for euclidean
SELECT
    loan_id,
    note_text,
    VECTOR_L2_DISTANCE(embedding, :query_vector) AS distance
FROM loan_note_embeddings
ORDER BY distance ASC
LIMIT 10;
```

Available Snowflake vector functions:
- `VECTOR_COSINE_SIMILARITY(v1, v2)` — returns float in [-1, 1]
- `VECTOR_L2_DISTANCE(v1, v2)` — euclidean distance
- `VECTOR_INNER_PRODUCT(v1, v2)` — dot product

---

## SQL Server 2025 Vector Support

SQL Server 2025 introduces a native `vector` data type and `VECTOR_DISTANCE` function, making semantic search possible without leaving SQL Server.

```sql
-- Create a table with vector column (SQL Server 2025)
CREATE TABLE loan_documents (
    doc_id      INT IDENTITY PRIMARY KEY,
    loan_id     VARCHAR(20),
    doc_text    NVARCHAR(MAX),
    embedding   VECTOR(768)  -- native vector type
);

-- Insert (application inserts float array as JSON-style syntax)
INSERT INTO loan_documents (loan_id, doc_text, embedding)
VALUES ('LN-001', 'Borrower 60 days past due',
        CAST('[0.12, -0.45, 0.88, ...]' AS VECTOR(768)));

-- Semantic search using VECTOR_DISTANCE
SELECT TOP 5
    loan_id,
    doc_text,
    VECTOR_DISTANCE('cosine', embedding,
        CAST('[0.13, -0.44, 0.87, ...]' AS VECTOR(768))) AS distance
FROM loan_documents
ORDER BY VECTOR_DISTANCE('cosine', embedding,
    CAST('[0.13, -0.44, 0.87, ...]' AS VECTOR(768))) ASC;
```

---

## Hybrid Search: Vector + Keyword

Pure vector search misses exact matches; pure keyword search misses semantic variants. Hybrid search combines both using Reciprocal Rank Fusion (RRF) or a weighted score.

```python
# Hybrid search pattern using Qdrant (supports hybrid natively)
# or combining pgvector + PostgreSQL full-text search

def hybrid_search_postgres(conn, query_text: str, query_vector: list, limit: int = 10):
    """Combine BM25 keyword search with cosine vector search using RRF."""
    sql = """
    WITH keyword_results AS (
        SELECT
            note_id,
            loan_id,
            note_text,
            ts_rank(to_tsvector('english', note_text),
                    plainto_tsquery('english', %(query_text)s)) AS keyword_score,
            ROW_NUMBER() OVER (ORDER BY ts_rank(
                to_tsvector('english', note_text),
                plainto_tsquery('english', %(query_text)s)) DESC) AS keyword_rank
        FROM loan_note_embeddings
        WHERE to_tsvector('english', note_text) @@ plainto_tsquery('english', %(query_text)s)
        LIMIT 100
    ),
    vector_results AS (
        SELECT
            note_id,
            loan_id,
            note_text,
            1 - (embedding <=> %(query_vector)s::vector) AS vector_score,
            ROW_NUMBER() OVER (
                ORDER BY embedding <=> %(query_vector)s::vector ASC
            ) AS vector_rank
        FROM loan_note_embeddings
        LIMIT 100
    ),
    -- Reciprocal Rank Fusion
    rrf AS (
        SELECT
            COALESCE(k.note_id, v.note_id) AS note_id,
            COALESCE(k.loan_id, v.loan_id) AS loan_id,
            COALESCE(k.note_text, v.note_text) AS note_text,
            COALESCE(1.0 / (60 + k.keyword_rank), 0) +
            COALESCE(1.0 / (60 + v.vector_rank), 0) AS rrf_score
        FROM keyword_results k
        FULL OUTER JOIN vector_results v USING (note_id)
    )
    SELECT note_id, loan_id, note_text, rrf_score
    FROM rrf
    ORDER BY rrf_score DESC
    LIMIT %(limit)s
    """
    with conn.cursor() as cur:
        cur.execute(sql, {
            "query_text": query_text,
            "query_vector": query_vector,
            "limit": limit
        })
        return cur.fetchall()
```

---

## Use Cases in Mortgage / Secondary Market

| Use Case | Vector DB Role |
|---|---|
| Semantic search on servicer notes | Find notes discussing same issue regardless of wording |
| Similar borrower profiles | K-nearest borrowers by risk embedding for model validation |
| Comparable property search | Find similar properties for AVM calibration |
| RAG over compliance documents | Retrieve relevant FHFA/CFPB rule sections for LLM Q&A |
| Fraud pattern detection | Cluster similar loan applications to surface synthetic identity patterns |
| Delinquency early warning | Find historically similar performing loans that later defaulted |

---

## Interview Q&A

**Q1: What problem does a vector database solve that a traditional relational database cannot?**

Traditional databases excel at exact and range queries on structured data. They cannot efficiently answer "find me records semantically similar to this text" across millions of rows. A vector database stores high-dimensional embeddings and uses ANN indexes (HNSW, IVF) to find approximate nearest neighbors in milliseconds. Without a specialized index, searching 10M 768-dimensional vectors would require computing millions of cosine similarities per query — far too slow for interactive use. Snowflake's VECTOR type and pgvector both add this capability on top of existing SQL infrastructure, which is typically the best starting point for a data engineering team.

**Q2: Explain HNSW indexing in plain terms. Why is it preferred over IVF for many use cases?**

HNSW builds a layered graph. The top layer is sparse — each vector is connected to a few distant neighbors, letting search skip large regions quickly. Lower layers are progressively denser. Search starts at the top layer, navigates toward the query vector, then descends to more precise layers. This gives high recall (typically >95%) and fast queries even on incremental inserts, because new vectors can be added to the graph without a rebuild. IVF requires k-means clustering at index build time and degrades for recently inserted vectors until re-indexed. For a live pipeline ingesting new servicer notes daily, HNSW handles incremental updates much more gracefully.

**Q3: How would you implement semantic search on servicer notes in Snowflake without using an external vector database?**

I would use Snowflake's native VECTOR type. The pipeline: generate embeddings for all notes using a Snowflake UDF backed by SPCS (running a Sentence Transformer) or by calling an embedding model via Cortex; store embeddings in a `VECTOR(FLOAT, 768)` column; at query time, embed the search query the same way and use `VECTOR_COSINE_SIMILARITY` or order by `VECTOR_L2_DISTANCE` to retrieve the top-N similar notes. For batch ingestion, a Snowflake task runs nightly on new notes. The advantage over an external vector DB is zero data movement — all data stays in Snowflake.

**Q4: What is hybrid search and when is it important for mortgage data?**

Hybrid search combines vector (semantic) search with keyword (BM25/full-text) search, typically using Reciprocal Rank Fusion to merge the ranked lists. It matters for mortgage data because loan numbers, regulation codes (e.g., "12 CFR 1026.36"), property addresses, and investor codes are exact identifiers that semantic search handles poorly — but servicer notes and legal comments benefit from semantic understanding. A user searching "REG-Z disclosure for adjustable rate loan" needs both: exact term matching for "REG-Z" and semantic understanding to surface notes that discuss adjustable rate disclosures without using those exact words.

**Q5: How would you choose between Pinecone and Qdrant for a production mortgage document search system?**

The key dimensions: operational overhead, cost model, and filtering capability. Pinecone is fully managed — no infrastructure, strong SLA, predictable scaling, but higher cost per vector and per query, and less control. Qdrant is self-hosted (Docker/Kubernetes) or managed, cheaper at volume, has excellent payload filtering with arbitrary JSON metadata, and is open-source. For a regulated environment where you want data residency control and are willing to manage infrastructure, Qdrant on your own Kubernetes cluster (or Snowflake SPCS) is a strong choice. For a small team that wants zero operational overhead, Pinecone is the pragmatic answer. I would avoid Pinecone if the index needs to hold PII-adjacent metadata without a separate privacy review.

**Q6: What is the difference between cosine similarity and euclidean distance for vector search, and which should you use for text embeddings?**

Cosine similarity measures the angle between two vectors, ignoring their magnitude. Euclidean distance measures the straight-line distance between two points in space, which is sensitive to magnitude. For text embeddings, cosine similarity is standard because it captures directional semantic meaning regardless of how long or short the source text was. A short note and a long document can embed to vectors with very different magnitudes but nearly identical direction if they discuss the same topic — cosine handles this correctly, euclidean does not. When using normalized embeddings (which Sentence Transformers and OpenAI produce by default), cosine similarity equals the dot product, which is faster to compute.

**Q7: How does Snowflake's VECTOR type compare to pgvector for an organization already standardized on Snowflake?**

For an organization on Snowflake, the VECTOR type wins on simplicity: no separate infrastructure, no ETL to keep in sync, query data in the same SQL environment you use for everything else, governed by the same RBAC and data masking policies. pgvector requires a PostgreSQL instance — either a managed RDS/Azure Database for PostgreSQL or self-hosted. The VECTOR type supports VECTOR_COSINE_SIMILARITY and VECTOR_L2_DISTANCE, which covers the vast majority of use cases. The limitation is Snowflake does not yet have a dedicated ANN index structure like HNSW — searches are full scans on the vector column, which limits practical scale before performance degrades. For high-volume, low-latency serving (sub-10ms), a dedicated Qdrant or Pinecone index is still faster.

**Q8: Describe a RAG pipeline architecture for answering questions about FNMA Selling Guide documents.**

The pipeline has two phases. Index phase: download all FNMA Selling Guide PDFs; chunk each document into 512-token overlapping chunks; embed each chunk using a Sentence Transformer (all-mpnet-base-v2 for quality); store chunk text, embedding, source document, page number, and section ID in a vector database (e.g., pgvector or Snowflake VECTOR). Query phase: user submits a question; embed the question with the same model; retrieve top-5 most similar chunks by cosine similarity; pass the question + retrieved chunks as context to an LLM (Arctic or Claude); LLM generates an answer grounded in the retrieved text; return the answer with citations (source document and section). The key engineering concern is chunk quality — bad chunking (splitting mid-sentence, losing context) degrades retrieval more than model choice.

**Q9: How would you handle vector index maintenance in a production pipeline with daily updates?**

This depends on the database. For HNSW-based systems (pgvector, Qdrant): new vectors are inserted incrementally into the graph — no rebuild needed. I would set up a nightly batch job that embeds new records and inserts them. For IVF-based systems (Faiss, older Pinecone pod-based): I would upsert into the index and schedule a periodic full re-index (weekly or monthly) during low-traffic hours to maintain recall quality as the distribution of new vectors may differ from the original clustering. In Snowflake, the VECTOR type currently performs full scans, so maintenance is just ensuring the underlying table is clustered by a relevant dimension (e.g., state, date) to reduce scan volume.

**Q10: What are the data governance considerations for storing mortgage document embeddings in a vector database?**

Embeddings derived from PII-containing documents (borrower names, SSNs, addresses embedded in servicer notes) can potentially be used to reconstruct approximate source text — they are not fully anonymous. From a GLBA perspective, embeddings should be governed at the same sensitivity level as the source data. Practically: (1) store embeddings with the same access controls as the source table; (2) apply data masking or redaction before embedding if PII is not needed for the use case; (3) include the vector database in your data inventory and DSAR (Data Subject Access Request) process; (4) retain embeddings only as long as the source data retention policy requires; (5) if using a third-party managed vector DB (Pinecone), include it in your vendor data processing agreements.

---

## Pro Tips

- Default to Snowflake VECTOR type or pgvector first. Adding a new database to your stack adds operational complexity. Only introduce a dedicated vector DB when scale or latency requirements justify it.
- Always use the same embedding model for indexing and querying. Switching models requires re-embedding your entire corpus.
- For Pinecone and Qdrant, store rich metadata alongside vectors. Filtering in the vector layer (e.g., `state = 'TX'`) is far faster than post-filtering results in your application layer.
- Benchmark your chosen ANN index at the scale you expect in production, not at prototype scale. HNSW recall degrades if `ef_search` is set too low; tune it to match your recall requirements.
- For RAG pipelines, retrieval quality matters more than LLM quality. Spending effort on good chunking, high-quality embeddings, and hybrid search typically produces larger accuracy gains than upgrading the LLM.
- In Snowflake, use `VECTOR_COSINE_SIMILARITY` in a CTE with a pre-computed query vector to avoid re-computing the query embedding multiple times in a single query.
- Monitor p95 and p99 query latency, not just average. ANN algorithms have tail latency spikes that can affect user-facing applications.
