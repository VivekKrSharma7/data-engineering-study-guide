# Embeddings & Vector Representations

[Back to Index](../index.md)

---

## Overview

Embeddings are the bridge between human language (and other unstructured data) and machine learning systems. An embedding model converts text, documents, or structured records into dense numerical vectors that capture semantic meaning. Once data is in vector form, it can be stored in a vector database, compared by similarity, clustered, or used as input to downstream ML models.

For a senior data engineer in the secondary mortgage market, embeddings enable: searching servicer notes by meaning, building similarity-based risk models, powering RAG-based compliance Q&A tools, and enriching structured loan data with semantic features derived from unstructured documents.

---

## What Are Embeddings?

An embedding is a function that maps an input (text, image, row of data) to a fixed-length dense float vector. The key property is that **similar inputs produce similar vectors** — vectors close together in high-dimensional space.

```
Input:  "The borrower is 90 days delinquent"
Output: [-0.023, 0.418, -0.112, ..., 0.334]  (384 or 768 or 1536 floats)
```

The vector is a coordinate in a semantic space. Words and concepts that appear in similar contexts in the training data end up as neighboring points in that space.

```python
import numpy as np

# Conceptual: two semantically similar sentences
v1 = np.array([-0.023, 0.418, -0.112, 0.334])  # "borrower is 90 days delinquent"
v2 = np.array([-0.019, 0.411, -0.108, 0.341])  # "mortgagor missed 3 payments"
v3 = np.array([0.312, -0.205, 0.441, -0.118])  # "loan paid off in full"

def cosine_sim(a, b):
    return np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b))

print(f"Similar (delinquent): {cosine_sim(v1, v2):.4f}")  # ~0.999
print(f"Different (payoff):   {cosine_sim(v1, v3):.4f}")  # ~0.05
```

---

## Historical Context: Word-Level Embeddings

### Word2Vec (2013)

Word2Vec (Google) was the first widely adopted embedding approach. It trained shallow neural networks to predict surrounding words (Skip-gram) or the center word from context (CBOW). The result: each word maps to a vector, and algebraic operations work:

```
vector("king") - vector("man") + vector("woman") ≈ vector("queen")
```

**Limitation for data engineering:** Word2Vec produces one vector per word type, ignoring context. "Servicing" has the same vector whether it means loan servicing or auto servicing. Cannot embed full sentences.

### GloVe (2014)

GloVe (Stanford) used word co-occurrence statistics across a large corpus. Better at capturing global statistical meaning, but same limitation: word-level, context-free.

**Practical status:** Word2Vec and GloVe are rarely used in new systems. They are background knowledge for interviews — understand what they solved and what they didn't.

---

## Modern Sentence and Document Embeddings

### Sentence-BERT (SBERT) Family

SBERT (2019) fine-tunes BERT using siamese networks on sentence similarity tasks. This produces sentence-level embeddings where cosine similarity reflects semantic similarity. The most widely used open-source embedding models today are SBERT variants.

Key models from the `sentence-transformers` library:

| Model | Dimensions | Speed | Quality | Best For |
|---|---|---|---|---|
| `all-MiniLM-L6-v2` | 384 | Very Fast | Good | High-volume, latency-sensitive |
| `all-MiniLM-L12-v2` | 384 | Fast | Good+ | Slightly better than L6 |
| `all-mpnet-base-v2` | 768 | Medium | Excellent | Production quality |
| `multi-qa-mpnet-base-dot-v1` | 768 | Medium | Excellent | Q&A/retrieval tasks |
| `paraphrase-multilingual-mpnet-base-v2` | 768 | Medium | Good | Multilingual content |

```python
from sentence_transformers import SentenceTransformer
import numpy as np

model = SentenceTransformer('all-mpnet-base-v2')

# Single embedding
text = "Borrower requested forbearance citing job loss"
embedding = model.encode(text, normalize_embeddings=True)
print(f"Dimensions: {len(embedding)}")  # 768
print(f"Type: {embedding.dtype}")       # float32

# Batch embedding (always prefer batch over loop)
servicer_notes = [
    "Borrower requested forbearance citing job loss",
    "Mortgagor submitted hardship documentation for COVID relief",
    "Loan paid in full via wire transfer, account closed"
]
embeddings = model.encode(servicer_notes, normalize_embeddings=True, batch_size=64)
print(f"Shape: {embeddings.shape}")  # (3, 768)
```

---

## OpenAI Embeddings

OpenAI provides embedding APIs that generally outperform open-source models on general English text, at the cost of API fees and sending data to an external service.

| Model | Dimensions | Max Tokens | Cost (per 1M tokens) | Notes |
|---|---|---|---|---|
| `text-embedding-ada-002` | 1536 | 8191 | $0.10 | Legacy, widely deployed |
| `text-embedding-3-small` | 1536 (adjustable) | 8191 | $0.02 | Best cost/quality |
| `text-embedding-3-large` | 3072 (adjustable) | 8191 | $0.13 | Highest quality |

The `text-embedding-3` models support **dimension reduction** via the `dimensions` parameter — you can request 256, 512, or 1024-dimensional embeddings at lower cost and storage.

```python
from openai import OpenAI
import numpy as np

client = OpenAI(api_key="your-api-key")

def embed_single(text: str, model: str = "text-embedding-3-small") -> list[float]:
    response = client.embeddings.create(input=text, model=model)
    return response.data[0].embedding

def embed_batch(texts: list[str], model: str = "text-embedding-3-small") -> list[list[float]]:
    """Embed a batch of texts. OpenAI accepts up to 2048 inputs per request."""
    response = client.embeddings.create(input=texts, model=model)
    # Sort by index to maintain order (API doesn't guarantee order)
    sorted_data = sorted(response.data, key=lambda x: x.index)
    return [item.embedding for item in sorted_data]

# Example: embed servicer notes
notes = [
    "Borrower 90 days past due, referred to loss mitigation",
    "Forbearance agreement executed, 3 month deferral approved"
]
embeddings = embed_batch(notes)
print(f"Dimensions: {len(embeddings[0])}")  # 1536 (text-embedding-3-small default)

# Reduced dimensions (cheaper, smaller storage)
response = client.embeddings.create(
    input=notes,
    model="text-embedding-3-large",
    dimensions=1024  # reduce from 3072 to 1024
)
```

---

## Embedding Dimensions: Tradeoffs

| Dimensions | Storage per Vector | Typical Model | Tradeoff |
|---|---|---|---|
| 384 | 1.5 KB | all-MiniLM | Fast, cheap, good for high volume |
| 768 | 3 KB | all-mpnet, BERT-base | Balanced quality/cost |
| 1024 | 4 KB | text-embedding-3-large (reduced) | High quality, moderate cost |
| 1536 | 6 KB | text-embedding-ada-002, 3-small | High quality, API cost |
| 3072 | 12 KB | text-embedding-3-large | Maximum quality, expensive |

At 10 million loan documents with 768-dimensional float32 embeddings:
```
10,000,000 vectors × 768 dimensions × 4 bytes = 30.7 GB
```
This is entirely manageable in a vector database or Snowflake VECTOR column. At 3072 dimensions it is 122 GB — still feasible but worth the cost/quality consideration.

---

## Batch Embedding for Large Datasets

For a corpus of millions of servicer notes, you need an efficient batch pipeline.

```python
import pandas as pd
from sentence_transformers import SentenceTransformer
from snowflake.connector import connect
import numpy as np
import json

def batch_embed_and_store(df: pd.DataFrame,
                           text_column: str,
                           id_column: str,
                           snowflake_conn,
                           target_table: str,
                           model_name: str = "all-mpnet-base-v2",
                           batch_size: int = 512):
    """
    Embed a DataFrame column and store results in Snowflake.
    Processes in batches to manage memory.
    """
    model = SentenceTransformer(model_name)
    total = len(df)
    print(f"Embedding {total:,} records in batches of {batch_size}...")

    records_to_insert = []

    for start in range(0, total, batch_size):
        end = min(start + batch_size, total)
        batch_df = df.iloc[start:end]
        texts = batch_df[text_column].fillna("").tolist()

        # Encode batch
        embeddings = model.encode(
            texts,
            normalize_embeddings=True,
            batch_size=64,
            show_progress_bar=False
        )

        for i, (_, row) in enumerate(batch_df.iterrows()):
            records_to_insert.append({
                "id": str(row[id_column]),
                "embedding": embeddings[i].tolist()
            })

        if (start // batch_size) % 10 == 0:
            print(f"  Progress: {end:,}/{total:,}")

    # Bulk insert into Snowflake
    cursor = snowflake_conn.cursor()
    insert_sql = f"""
        INSERT INTO {target_table} (note_id, embedding)
        SELECT
            parse_json(column1):id::STRING,
            parse_json(column1):embedding::ARRAY::VECTOR(FLOAT, 768)
        FROM VALUES (?)
    """
    for record in records_to_insert:
        cursor.execute(insert_sql, (json.dumps(record),))

    snowflake_conn.commit()
    print(f"Stored {len(records_to_insert):,} embeddings in {target_table}")
```

```python
# More efficient: use Snowflake COPY INTO for bulk loading
import tempfile
import os

def bulk_embed_to_snowflake_stage(df, text_col, id_col, stage_name, model_name):
    """Write embeddings to a Snowflake stage for COPY INTO."""
    model = SentenceTransformer(model_name)
    embeddings = model.encode(
        df[text_col].fillna("").tolist(),
        normalize_embeddings=True,
        batch_size=256
    )

    # Write as newline-delimited JSON
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        for i, row in df.iterrows():
            f.write(json.dumps({
                "note_id": str(row[id_col]),
                "embedding": embeddings[i].tolist()
            }) + "\n")
        tmp_path = f.name

    return tmp_path  # caller does PUT + COPY INTO
```

---

## Chunking Strategies for Large Documents

Loan documents (appraisals, closing disclosures, RESPA notices) are too long to embed as a single unit. Most embedding models have a 512-token context window; text beyond that is truncated.

### Fixed-Size Chunking

```python
def chunk_fixed(text: str, chunk_size: int = 512, overlap: int = 50) -> list[str]:
    """Split text into fixed-size token chunks with overlap."""
    words = text.split()
    chunks = []
    start = 0
    while start < len(words):
        end = start + chunk_size
        chunks.append(" ".join(words[start:end]))
        start += chunk_size - overlap
    return chunks
```

### Semantic/Paragraph Chunking (Preferred for Loan Documents)

```python
import re

def chunk_by_section(text: str, max_chunk_words: int = 400) -> list[dict]:
    """
    Chunk loan documents by section headers.
    Preserves semantic units (sections, paragraphs).
    """
    # Split on section headers (e.g., "SECTION 4.", "IV. PROPERTY DESCRIPTION")
    section_pattern = r'(?=(?:SECTION\s+\d+|[IVX]+\.\s+[A-Z]))'
    sections = re.split(section_pattern, text)

    chunks = []
    for section in sections:
        section = section.strip()
        if not section:
            continue

        words = section.split()
        if len(words) <= max_chunk_words:
            chunks.append({"text": section, "word_count": len(words)})
        else:
            # Further split long sections into paragraphs
            paragraphs = [p.strip() for p in section.split('\n\n') if p.strip()]
            buffer = []
            for para in paragraphs:
                buffer.append(para)
                if sum(len(p.split()) for p in buffer) >= max_chunk_words:
                    chunk_text = " ".join(buffer)
                    chunks.append({"text": chunk_text, "word_count": len(chunk_text.split())})
                    buffer = []
            if buffer:
                chunks.append({"text": " ".join(buffer), "word_count": sum(len(p.split()) for p in buffer)})

    return chunks
```

### Chunking Strategy Comparison

| Strategy | Pros | Cons | Best For |
|---|---|---|---|
| Fixed-size, no overlap | Simple, predictable | Splits mid-sentence | Never preferred |
| Fixed-size with overlap | Simple, handles boundary issues | Redundant data, higher storage | High-volume, uniform text |
| Paragraph/semantic | Preserves meaning | Variable chunk sizes | Legal/compliance docs |
| Recursive text splitter | Tries multiple delimiters | Requires tuning | General documents |
| Document structure-aware | Best retrieval quality | Document-type specific logic | Appraisals, disclosures |

---

## Embeddings for Structured Data (Tabular)

Embedding pipelines are not limited to text. Tabular loan data can be embedded for anomaly detection and similarity search.

```python
# Tabular embedding: convert loan record fields to a text template, then embed
def loan_record_to_text(row: dict) -> str:
    """
    Convert a structured loan record to a descriptive text string for embedding.
    This creates a 'semantic fingerprint' of the loan's risk profile.
    """
    return (
        f"Loan originated {row['origination_date']} in {row['state']}. "
        f"Property type: {row['property_type']}. "
        f"Loan amount: ${row['loan_amount']:,.0f}. "
        f"LTV ratio: {row['ltv_ratio']:.1%}. "
        f"Borrower FICO: {row['fico_score']}. "
        f"Debt-to-income: {row['dti_ratio']:.1%}. "
        f"Loan purpose: {row['loan_purpose']}. "
        f"Occupancy: {row['occupancy_type']}. "
        f"Current status: {row['loan_status']}."
    )

import pandas as pd
from sentence_transformers import SentenceTransformer

model = SentenceTransformer('all-mpnet-base-v2')
loans_df = pd.read_parquet("/data/loans/loan_master.parquet")

# Convert each loan row to text and embed
loan_texts = loans_df.apply(loan_record_to_text, axis=1).tolist()
loan_embeddings = model.encode(loan_texts, normalize_embeddings=True, batch_size=256)
# loan_embeddings shape: (n_loans, 768)
# Use for: k-nearest similar loans, anomaly detection, clustering
```

---

## Storing Embeddings: Snowflake, SQL Server, PostgreSQL

### Snowflake

```sql
-- Create table with VECTOR type
CREATE OR REPLACE TABLE loan_note_embeddings (
    note_id      STRING        NOT NULL,
    loan_id      STRING        NOT NULL,
    note_date    DATE,
    note_text    STRING,
    model_name   STRING,       -- track which model produced the embedding
    embedding    VECTOR(FLOAT, 768)
);

-- Query: find notes similar to a reference note
SELECT
    b.loan_id,
    b.note_text,
    VECTOR_COSINE_SIMILARITY(a.embedding, b.embedding) AS similarity
FROM loan_note_embeddings a
JOIN loan_note_embeddings b ON a.note_id != b.note_id
WHERE a.note_id = 'NOTE-REF-001'
ORDER BY similarity DESC
LIMIT 10;
```

### SQL Server 2025

```sql
-- Native vector type (SQL Server 2025)
CREATE TABLE loan_note_embeddings (
    note_id      VARCHAR(50)  NOT NULL PRIMARY KEY,
    loan_id      VARCHAR(20)  NOT NULL,
    note_text    NVARCHAR(MAX),
    model_name   VARCHAR(100),
    embedding    VECTOR(768)
);

-- Semantic search
DECLARE @query_vector VECTOR(768) = (
    SELECT embedding FROM loan_note_embeddings WHERE note_id = 'NOTE-REF-001'
);

SELECT TOP 10
    loan_id,
    note_text,
    VECTOR_DISTANCE('cosine', embedding, @query_vector) AS distance
FROM loan_note_embeddings
WHERE note_id != 'NOTE-REF-001'
ORDER BY VECTOR_DISTANCE('cosine', embedding, @query_vector) ASC;
```

### PostgreSQL with pgvector

```python
import psycopg2
import numpy as np
from sentence_transformers import SentenceTransformer

conn = psycopg2.connect("postgresql://user:password@localhost/mortgage_db")
model = SentenceTransformer('all-mpnet-base-v2')

def store_embedding(conn, note_id: str, loan_id: str, note_text: str):
    embedding = model.encode(note_text, normalize_embeddings=True)
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO loan_note_embeddings
               (note_id, loan_id, note_text, model_name, embedding)
               VALUES (%s, %s, %s, %s, %s)
               ON CONFLICT (note_id) DO UPDATE
               SET embedding = EXCLUDED.embedding,
                   model_name = EXCLUDED.model_name""",
            (note_id, loan_id, note_text, 'all-mpnet-base-v2', embedding.tolist())
        )
    conn.commit()

def semantic_search(conn, query_text: str, top_k: int = 10) -> list:
    query_embedding = model.encode(query_text, normalize_embeddings=True)
    with conn.cursor() as cur:
        cur.execute(
            """SELECT
                note_id,
                loan_id,
                note_text,
                1 - (embedding <=> %s::vector) AS similarity
               FROM loan_note_embeddings
               ORDER BY embedding <=> %s::vector
               LIMIT %s""",
            (query_embedding.tolist(), query_embedding.tolist(), top_k)
        )
        return cur.fetchall()

results = semantic_search(conn, "borrower requesting payment relief", top_k=5)
for note_id, loan_id, text, sim in results:
    print(f"[{sim:.4f}] {loan_id}: {text[:80]}")
```

---

## Embedding Pipeline: End-to-End

```
Source Data          Extract           Embed              Store             Query
-----------          -------           -----              -----             -----
Snowflake table  ->  Pull text     ->  SentenceTransfor  -> VECTOR column  -> VECTOR_COSINE_SIMILARITY
PDF documents    ->  PDF extract   ->  text-embedding-3  -> pgvector       -> <=> operator
Servicer notes   ->  SQL SELECT    ->  all-mpnet-base-v2 -> Qdrant         -> .search()
Appraisals       ->  OCR/extract   ->  OpenAI ada-002    -> Pinecone       -> .query()
```

```python
# Full pipeline example: embed Snowflake servicer notes, store back in Snowflake

from snowflake.snowpark import Session
from sentence_transformers import SentenceTransformer
import pandas as pd

EMBEDDING_MODEL = "all-mpnet-base-v2"
BATCH_SIZE = 512
SOURCE_TABLE = "RAW.SERVICER_NOTES"
TARGET_TABLE = "ENRICHED.LOAN_NOTE_EMBEDDINGS"

def run_embedding_pipeline(session: Session, incremental: bool = True):
    model = SentenceTransformer(EMBEDDING_MODEL)

    # Pull notes not yet embedded
    if incremental:
        sql = f"""
            SELECT s.note_id, s.loan_id, s.note_date, s.note_text
            FROM {SOURCE_TABLE} s
            LEFT JOIN {TARGET_TABLE} e ON s.note_id = e.note_id
            WHERE e.note_id IS NULL
            ORDER BY s.note_date
        """
    else:
        sql = f"SELECT note_id, loan_id, note_date, note_text FROM {SOURCE_TABLE}"

    df = session.sql(sql).to_pandas()
    print(f"Embedding {len(df):,} new notes...")

    if df.empty:
        print("No new notes to embed.")
        return

    # Embed in batches
    texts = df["NOTE_TEXT"].fillna("").tolist()
    embeddings = model.encode(
        texts,
        normalize_embeddings=True,
        batch_size=64,
        show_progress_bar=True
    )

    df["EMBEDDING"] = [e.tolist() for e in embeddings]
    df["MODEL_NAME"] = EMBEDDING_MODEL

    # Write back to Snowflake via Snowpark
    snowpark_df = session.create_dataframe(df[["NOTE_ID", "LOAN_ID", "NOTE_DATE", "NOTE_TEXT", "MODEL_NAME", "EMBEDDING"]])
    snowpark_df.write.mode("append").save_as_table(TARGET_TABLE)
    print(f"Stored {len(df):,} embeddings in {TARGET_TABLE}")

if __name__ == "__main__":
    session = Session.builder.configs(connection_params).create()
    run_embedding_pipeline(session, incremental=True)
```

---

## Model Selection Tradeoffs

| Factor | Open Source (SBERT) | OpenAI API | Custom Fine-tuned |
|---|---|---|---|
| Quality | Good to Excellent | Excellent | Excellent (domain-specific) |
| Cost | Free (compute only) | Per token fee | Training + compute |
| Data privacy | Data stays local | Data sent to OpenAI | Data stays local |
| Latency | Low (local) | Network dependent | Low (if local) |
| Maintenance | Self-managed | None | High |
| Domain adaptation | Fine-tunable | Not fine-tunable | Full control |

**For mortgage/secondary market data:** Prefer open-source (all-mpnet-base-v2) deployed inside Snowflake SPCS or on internal infrastructure. This avoids sending borrower-adjacent text to OpenAI, which requires review of data agreements. If OpenAI quality is required, use the `text-embedding-3-small` model with PII redacted from the text before embedding.

---

## Interview Q&A

**Q1: What is an embedding, and why is it useful for mortgage data engineering?**

An embedding converts text (or other data) into a fixed-length dense float vector that captures semantic meaning. Two pieces of text that mean similar things produce vectors that are close together in vector space. For mortgage data engineering, this is valuable because: servicer notes describing the same issue use wildly different wording — "borrower is delinquent," "mortgagor missed payments," "account past due" all mean the same thing but share no keywords. Embeddings let you search by meaning. This enables semantic search across millions of servicer notes, similarity-based risk identification, RAG pipelines for compliance Q&A, and document clustering.

**Q2: Explain the difference between Word2Vec and Sentence-BERT. Why do we use sentence embeddings instead of averaging word vectors?**

Word2Vec produces a single vector per word type, ignoring context — "bank" (financial) and "bank" (river) get the same vector. Averaging word vectors to represent a sentence destroys word order and meaning. Sentence-BERT uses a transformer encoder (BERT) fine-tuned with a siamese network on sentence similarity datasets. It produces a single vector for the entire sentence that captures contextual meaning, word order, and relationships between words. For a servicer note like "borrower is NOT delinquent but missed a payment," averaging word embeddings would place this near delinquency notes. SBERT understands the negation and produces a more accurate vector.

**Q3: How would you choose between `all-MiniLM-L6-v2` and `all-mpnet-base-v2` for a production pipeline?**

The tradeoff is speed vs. quality. all-MiniLM-L6-v2 (384 dimensions, 6 transformer layers) is roughly 5x faster and uses half the storage of all-mpnet-base-v2 (768 dimensions, 12 layers). For a pipeline embedding 50 million servicer notes nightly on a batch GPU, I would benchmark both on a representative sample of 10,000 notes with ground truth relevance labels (or human-rated pairs). If retrieval quality (precision@5 or NDCG) is within 2-3%, I would use MiniLM for cost and speed. If the quality gap is meaningful on edge cases — legal language, rare mortgage terminology — I would pay for mpnet. In my experience, mpnet wins on domain-specific mortgage text because the richer model better captures industry jargon.

**Q4: What are the data privacy implications of using OpenAI's embedding API on mortgage data?**

OpenAI's API sends data to OpenAI's servers. For mortgage data, this raises concerns under: GLBA (Gramm-Leach-Bliley Act) governing NPI (non-public personal information); FNMA/FHLMC data use agreements that restrict how loan-level data is shared with third parties; state privacy laws (CCPA, NYDFS). Practically: (1) never send data containing borrower SSNs, account numbers, or full names to any external API without a BAA or data processing addendum reviewed by legal; (2) for servicer notes that may contain PII, apply a PII redaction step (regex or a NER model) before embedding; (3) OpenAI does not train on API inputs by default since 2023, but document this assumption in your data inventory; (4) prefer deploying open-source models inside Snowflake SPCS or on internal infrastructure for all PII-adjacent data.

**Q5: Describe a complete embedding pipeline for a RAG system over FNMA Selling Guide documents.**

Step 1 — Ingestion: Download Selling Guide PDFs. Parse with a PDF library (pymupdf, pdfplumber). Extract text per page and section. Step 2 — Chunking: Split into 400-word chunks with 50-word overlap, preserving section header context (prepend the section title to each chunk). Step 3 — Embedding: Use `all-mpnet-base-v2` for each chunk. Or `text-embedding-3-small` if quality justifies the API cost and legal approves. Step 4 — Storage: Store chunk text, embedding, source document, page number, section ID in pgvector or Snowflake VECTOR. Step 5 — Query: Embed the user question with the same model. Retrieve top-5 chunks by cosine similarity. Optionally apply hybrid search (BM25 + vector via RRF). Step 6 — Generation: Pass question + retrieved chunks to Arctic or Claude. Return answer with citations. Step 7 — Monitoring: Track retrieval latency, user feedback (thumbs up/down), and embedding drift when the guide is updated.

**Q6: What is embedding model drift and how do you handle it in production?**

If you embed your corpus with model version 1 and later upgrade to model version 2, the vector spaces are incompatible — similarity scores between old and new embeddings are meaningless. Handling this: (1) include model name and version in every record's metadata; (2) when upgrading the model, re-embed the entire corpus in a new index/table and run both in parallel during a transition period; (3) never mix embeddings from different models in the same vector column or index; (4) schedule periodic quality checks by sampling and manually reviewing top-K retrieval results. For a corpus of 10M notes, a full re-embedding with a 768-dim model typically takes 2-4 hours on a GPU server — plan this as a maintenance window.

**Q7: How do you handle documents longer than the embedding model's context window?**

Most SBERT models truncate at 256-512 tokens; OpenAI embeddings support up to 8191 tokens. For documents longer than the limit: (1) chunking with overlap is the standard solution — split into chunks small enough to fit, embed each chunk, store all chunks with their parent document ID; (2) at query time, retrieve relevant chunks and reconstruct context; (3) for summarization use cases, you can first summarize long documents with an LLM, then embed the summary. The overlap between chunks (50-100 tokens is typical) prevents important context at chunk boundaries from being lost. For a mortgage closing disclosure (20+ pages), I would chunk by section rather than by fixed word count, since sections are the natural semantic unit.

**Q8: How would you embed structured loan data (tabular records) for a similarity search use case?**

Convert each row to a descriptive natural language template: "Loan originated 2023-06 in Texas. LTV: 78%. FICO: 720. DTI: 42%. Property type: Single Family. Status: Current." This template approach works because LLM-trained embedding models encode numbers and categories better in textual context than as raw floats. Alternatives: (1) use a tabular embedding model (TabTransformer, SAINT) that handles mixed numeric/categorical input natively; (2) encode categorical features as learned embeddings in a trained model. The template approach is practical and surprisingly effective for similarity tasks. For the secondary mortgage market, this enables finding historically similar loans to a new acquisition target — useful for due diligence and expected loss modeling.

**Q9: What is the cost implication of using `text-embedding-3-large` vs. `all-mpnet-base-v2` at scale?**

At 10 million servicer notes, average 100 tokens each (100M tokens total): `text-embedding-3-large` at $0.13/1M tokens costs $13. That sounds cheap, but this is a one-time index cost. The ongoing cost is daily incremental embedding of new notes (say 10K notes/day = 1M tokens/day = $0.13/day, $47/year). More impactful: query-time embedding (every user search hits the API). At 1,000 searches/day × 50 tokens = 50K tokens/day at $0.13/1M = $0.0065/day for queries. So API costs are not prohibitive, but the data egress and privacy considerations are more significant than dollar costs. `all-mpnet-base-v2` on a modest GPU instance costs ~$0.10/hour and embeds 10M 100-token notes in about 2 hours = $0.20 total. For recurring use, self-hosted open-source wins on cost by orders of magnitude.

**Q10: How do you validate that your embedding pipeline is producing quality results before deploying to production?**

I use three validation approaches. First, intrinsic evaluation: compute cosine similarity for known-similar pairs (servicer notes describing the same event, written differently) and known-dissimilar pairs (delinquency notes vs. payoff notes). Verify similar pairs score >0.85 and dissimilar pairs score <0.2. Second, retrieval evaluation: take 100 sample queries with known ground-truth relevant documents (manually labeled or derived from business logic). Measure precision@5, recall@10, and NDCG. Third, end-to-end evaluation: for a RAG system, use LLM-as-judge or human evaluators to rate the quality of generated answers on 50 representative questions. If retrieval recall is below 80% on the evaluation set, investigate: are documents chunked too aggressively? Is the embedding model the right choice for domain-specific terminology? Should I add a fine-tuning step?

---

## Pro Tips

- Always use the same model and normalization settings for both indexing and querying. A mismatch silently produces wrong similarity scores.
- Store the `model_name` and `model_version` alongside every embedding in your database. You will need this when you upgrade models.
- Normalize embeddings to unit length (L2 normalization) at creation time. This makes cosine similarity equal to dot product, which is faster to compute and avoids surprises when using different similarity metrics.
- For Sentence Transformers, always use `batch_size` that fills your GPU memory. Processing one text at a time is 10-50x slower than batching.
- Chunking quality has more impact on RAG accuracy than embedding model quality. Invest time in domain-specific chunking logic before upgrading to a more expensive model.
- For mortgage documents, prepend the section title or document type to each chunk before embedding: `"[Appraisal - Subject Property Description] The subject property is a single-family residence..."`. This context dramatically improves retrieval quality.
- Use `text-embedding-3-small` with `dimensions=768` if you need an OpenAI model but want to match the storage footprint of SBERT models.
- Monitor retrieval latency by percentile (p50, p95, p99) not just average. ANN search has occasional slow outliers that affect user experience.
- Re-embed the corpus when the source data distribution shifts significantly — for example, after acquiring a new servicer with different note-writing conventions.
