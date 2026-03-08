# Hugging Face Transformers & NLP for Data Engineers

[Back to Index](../README.md)

---

## Overview

Hugging Face is the de facto hub for open-source NLP and multimodal AI. For a data engineer in the secondary mortgage market, it provides pre-trained transformer models that can be applied directly to document-heavy workflows — loan file classification, named entity extraction from closing disclosures, servicer note summarization, and regulatory text analysis — without training a model from scratch.

This guide covers the full ecosystem from model loading and tokenization to production deployment inside Snowflake via Snowpark Container Services, with Python examples targeting mortgage-specific use cases.

---

## Key Concepts

| Component | Description |
|---|---|
| Hugging Face Hub | Model/dataset registry at huggingface.co — 500K+ models |
| `transformers` | Core library: model architectures, tokenizers, pipelines |
| `datasets` | Efficient data loading with Arrow/memory-map; works with Spark |
| `tokenizers` | Rust-accelerated tokenizer library |
| `PEFT` | Parameter-Efficient Fine-Tuning: LoRA, prefix tuning |
| `accelerate` | Multi-GPU/TPU training abstraction |
| `sentence-transformers` | Sentence/document embeddings for semantic search |
| AutoClass | `AutoModel`, `AutoTokenizer` — load any model without knowing its class |
| `pipeline()` | High-level inference API; wraps tokenize + forward + decode |

---

## The Hugging Face Ecosystem

```
huggingface.co (Hub)
    |
    |-- Models (BERT, RoBERTa, Llama, Mistral, DistilBERT, ...)
    |-- Datasets (CommonCrawl, SQuAD, GLUE, ...)
    |-- Spaces (hosted Gradio/Streamlit demos)
    |
transformers (pip install transformers)
    |-- AutoTokenizer, AutoModel, AutoModelForSequenceClassification
    |-- pipeline() -- high-level task inference
    |-- Trainer -- training loop
    |
sentence-transformers (pip install sentence-transformers)
    |-- SentenceTransformer -- encode() -> dense vectors
    |-- semantic search, clustering, reranking
    |
datasets (pip install datasets)
    |-- load_dataset(), Dataset, DatasetDict
    |-- Arrow-backed; handles > RAM via memory mapping
    |
PEFT (pip install peft)
    |-- LoRA, IA3, prefix tuning for efficient fine-tuning
    |-- Fine-tune a 7B model on a single A100 in hours
```

---

## Loading Models: AutoClass Pattern

```python
from transformers import AutoTokenizer, AutoModelForSequenceClassification
import torch

model_name = "distilbert-base-uncased-finetuned-sst-2-english"

tokenizer = AutoTokenizer.from_pretrained(model_name)
model = AutoModelForSequenceClassification.from_pretrained(model_name)

# Tokenize
text = "The Federal Reserve's rate cut significantly improved prepayment speeds."
inputs = tokenizer(text, return_tensors="pt", truncation=True, max_length=512)

# Forward pass
with torch.no_grad():
    outputs = model(**inputs)
    logits = outputs.logits
    probs = torch.softmax(logits, dim=-1)

label = model.config.id2label[probs.argmax().item()]
print(f"Sentiment: {label}, Confidence: {probs.max().item():.3f}")
```

### AutoClass Reference

| Task | AutoClass |
|---|---|
| Feature extraction (embeddings) | `AutoModel` |
| Text classification | `AutoModelForSequenceClassification` |
| Token classification (NER) | `AutoModelForTokenClassification` |
| Question answering | `AutoModelForQuestionAnswering` |
| Summarization / generation | `AutoModelForSeq2SeqLM`, `AutoModelForCausalLM` |
| Masked LM (fill-mask) | `AutoModelForMaskedLM` |

---

## pipeline() — High-Level Inference

```python
from transformers import pipeline

# Text classification
classifier = pipeline(
    "text-classification",
    model="ProsusAI/finbert",   # FinBERT: finance-domain sentiment
    device=0                    # GPU index; -1 for CPU
)

headlines = [
    "Mortgage delinquencies hit 5-year low as employment remains strong",
    "Fed signals rate hikes ahead, mortgage originations expected to fall",
    "Servicer advances surge amid rising 90-day delinquency rates"
]

results = classifier(headlines, batch_size=8, truncation=True)
for headline, result in zip(headlines, results):
    print(f"{result['label']:10s} ({result['score']:.3f}) | {headline}")
```

```python
# Named Entity Recognition
ner_pipe = pipeline(
    "ner",
    model="dslim/bert-base-NER",
    aggregation_strategy="simple"
)

loan_text = """
Borrower John Smith at 4521 Oak Street, Austin TX 78701 applied for a
$425,000 30-year fixed mortgage with First National Bank on March 15, 2025.
"""

entities = ner_pipe(loan_text)
for ent in entities:
    print(f"{ent['entity_group']:10s} | {ent['word']:30s} | score: {ent['score']:.3f}")
# Output:
# PER        | John Smith                     | score: 0.998
# LOC        | 4521 Oak Street, Austin TX...  | score: 0.991
# ORG        | First National Bank            | score: 0.987
```

```python
# Summarization of servicer notes
summarizer = pipeline(
    "summarization",
    model="facebook/bart-large-cnn",
    device=0
)

servicer_note = """
Borrower contacted servicer on 2025-01-10 requesting forbearance due to
job loss. Income documentation received 2025-01-15: W2 showing $72,000
annual salary, recently terminated. Borrower states new employment starts
2025-02-01. Three-month forbearance approved per CARES Act guidelines.
Repayment plan offered: catch-up payment of $5,400 ($1,800/month x 3)
spread over 12 months beginning 2025-05-01. Borrower accepted verbally.
Written agreement mailed 2025-01-20.
"""

summary = summarizer(
    servicer_note,
    max_length=80,
    min_length=30,
    do_sample=False
)
print(summary[0]["summary_text"])
```

---

## Tokenization Deep Dive

Understanding tokenization is critical for debugging NLP pipelines on financial text.

### Tokenization Algorithms

| Algorithm | Used By | How It Works |
|---|---|---|
| BPE (Byte Pair Encoding) | GPT-2, RoBERTa | Iteratively merge most frequent byte pairs |
| WordPiece | BERT, DistilBERT | Like BPE but maximizes language model likelihood |
| SentencePiece | T5, Llama, mT5 | Operates on raw bytes; language-agnostic |
| Unigram | XLNet, some mT5 | Probabilistic subword segmentation |

```python
from transformers import AutoTokenizer

tokenizer = AutoTokenizer.from_pretrained("bert-base-uncased")

# Financial text often has domain-specific tokens
text = "The IO ARM with a 5/1 teaser and 150bps cap has a DSCR of 1.25x"
tokens = tokenizer.tokenize(text)
print(tokens)
# ['the', 'io', 'arm', 'with', 'a', '5', '/', '1', 'te', '##aser',
#  'and', '150', '##bp', '##s', 'cap', 'has', 'a', 'ds', '##cr', 'of', '1', '.', '25', '##x']

# Note: "teaser" split into "te" + "##aser", "DSCR" into "ds" + "##cr"
# Domain-specific fine-tuning or a finance-specific tokenizer handles this better

encoding = tokenizer(
    text,
    return_tensors="pt",
    truncation=True,
    max_length=512,
    padding="max_length",
    return_attention_mask=True,
    return_token_type_ids=True    # for BERT sentence pairs
)

print(f"input_ids shape:      {encoding['input_ids'].shape}")
print(f"attention_mask shape: {encoding['attention_mask'].shape}")
# [CLS] token at index 0, [SEP] at end, [PAD] fills to max_length
```

### Key Tokenizer Parameters for Production

```python
# Batch tokenization for data pipelines
texts = ["loan text 1", "loan text 2", "loan text 3"]

batch = tokenizer(
    texts,
    padding=True,           # pad to longest in batch (not max_length — saves compute)
    truncation=True,
    max_length=512,
    return_tensors="pt",
    return_overflowing_tokens=True,   # handle docs > 512 tokens (sliding window)
    stride=50                          # overlap between chunks
)
# batch["overflow_to_sample_mapping"] maps each chunk back to the original document index
```

---

## Sentence Transformers for Embeddings

```python
from sentence_transformers import SentenceTransformer
import numpy as np

model = SentenceTransformer("all-MiniLM-L6-v2")  # 22M params, fast, good quality

# Encode loan document excerpts
documents = [
    "This is a Closing Disclosure for a 30-year fixed rate mortgage.",
    "Uniform Residential Appraisal Report for single-family property.",
    "Title Insurance Commitment — Schedule B exceptions listed below.",
    "Borrower's Authorization and Certification form.",
]

embeddings = model.encode(documents, batch_size=32, show_progress_bar=True)
print(f"Embedding shape: {embeddings.shape}")   # (4, 384)

# Semantic similarity — find the most similar document to a query
query = "property valuation document"
query_emb = model.encode([query])

from sklearn.metrics.pairwise import cosine_similarity
scores = cosine_similarity(query_emb, embeddings)[0]
best = np.argmax(scores)
print(f"Most similar: '{documents[best]}' (score: {scores[best]:.3f})")
# Output: Most similar: 'Uniform Residential Appraisal Report...' (score: 0.71)
```

### Storing Embeddings in Snowflake

```sql
-- Snowflake VECTOR type (available 2024+)
CREATE OR REPLACE TABLE MORTGAGE.NLP.DOCUMENT_EMBEDDINGS (
    document_id     VARCHAR(50),
    document_type   VARCHAR(50),
    text_excerpt    VARCHAR(2000),
    embedding       VECTOR(FLOAT, 384),   -- all-MiniLM-L6-v2 dimension
    created_ts      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Cosine similarity search
SELECT
    d.document_id,
    d.document_type,
    VECTOR_COSINE_SIMILARITY(d.embedding, :query_embedding) AS similarity
FROM MORTGAGE.NLP.DOCUMENT_EMBEDDINGS d
ORDER BY similarity DESC
LIMIT 10;
```

---

## Batch Inference for Data Pipelines

### Efficient Batch Processing Pattern

```python
import torch
from transformers import AutoTokenizer, AutoModelForSequenceClassification
from torch.utils.data import DataLoader, Dataset
import pandas as pd

class LoanDocDataset(Dataset):
    def __init__(self, texts, tokenizer, max_length=512):
        self.encodings = tokenizer(
            texts,
            padding=True,
            truncation=True,
            max_length=max_length,
            return_tensors="pt"
        )

    def __len__(self):
        return self.encodings["input_ids"].shape[0]

    def __getitem__(self, idx):
        return {k: v[idx] for k, v in self.encodings.items()}


def batch_classify_documents(texts: list[str], batch_size: int = 32) -> pd.DataFrame:
    """Classify mortgage documents at scale using GPU batch inference."""

    model_name = "my-org/mortgage-doc-classifier"   # fine-tuned on internal data
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    model = AutoModelForSequenceClassification.from_pretrained(model_name)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = model.to(device)
    model.eval()

    # Enable mixed precision for ~2x throughput on A10G/A100
    model = model.half()   # fp16

    dataset = LoanDocDataset(texts, tokenizer)
    loader = DataLoader(dataset, batch_size=batch_size, num_workers=4, pin_memory=True)

    all_probs = []
    with torch.no_grad(), torch.autocast(device_type="cuda", dtype=torch.float16):
        for batch in loader:
            batch = {k: v.to(device) for k, v in batch.items()}
            outputs = model(**batch)
            probs = torch.softmax(outputs.logits, dim=-1).cpu().numpy()
            all_probs.extend(probs.tolist())

    labels = [model.config.id2label[p.index(max(p))] for p in all_probs]
    confidences = [max(p) for p in all_probs]

    return pd.DataFrame({
        "text": texts,
        "predicted_class": labels,
        "confidence": confidences
    })
```

### Pandas UDF Wrapper for Spark

```python
import pandas as pd
from pyspark.sql.functions import pandas_udf
from pyspark.sql.types import StringType

@pandas_udf(StringType())
def classify_document_udf(texts: pd.Series) -> pd.Series:
    """Apply HuggingFace classifier to each Spark partition."""
    # Model loaded once per partition (executor), not per row
    from transformers import pipeline as hf_pipeline
    import os

    # Load from mounted model artifact path on Databricks
    model_path = "/dbfs/models/mortgage-doc-classifier"
    clf = hf_pipeline("text-classification", model=model_path, device=0)

    results = clf(texts.tolist(), batch_size=64, truncation=True, max_length=512)
    return pd.Series([r["label"] for r in results])

# Apply to Spark DataFrame
classified_df = loan_docs_df.withColumn(
    "document_class",
    classify_document_udf("text_excerpt")
)
```

---

## NLP Use Cases in Mortgage / Secondary Market

### 1. NER on Loan Documents

```python
from transformers import pipeline

# Fine-tuned NER for mortgage documents (or use a general NER + post-processing)
ner = pipeline("ner", model="dslim/bert-base-NER", aggregation_strategy="simple")

closing_disclosure = """
Property Address: 1842 Maple Drive, Charlotte, NC 28201
Borrower: Maria Elena Rodriguez    SSN: XXX-XX-XXXX
Loan Amount: $387,500    Note Rate: 6.875%    Closing Date: April 3, 2025
Lender: SunTrust Mortgage, Inc.    Loan Number: 2025-NC-084721
"""

entities = ner(closing_disclosure)
mortgage_entities = {
    "borrower": [],
    "address": [],
    "organization": [],
    "amount": []
}

for ent in entities:
    if ent["entity_group"] == "PER":
        mortgage_entities["borrower"].append(ent["word"])
    elif ent["entity_group"] == "LOC":
        mortgage_entities["address"].append(ent["word"])
    elif ent["entity_group"] == "ORG":
        mortgage_entities["organization"].append(ent["word"])
```

### 2. Document Classification

```python
# Zero-shot classification — no fine-tuning needed
classifier = pipeline("zero-shot-classification", model="facebook/bart-large-mnli")

doc_excerpt = "This report presents our opinion of the market value of the subject property..."

result = classifier(
    doc_excerpt,
    candidate_labels=[
        "appraisal report",
        "title commitment",
        "closing disclosure",
        "promissory note",
        "deed of trust",
        "hazard insurance policy",
        "tax certificate"
    ]
)

print(f"Document type: {result['labels'][0]} ({result['scores'][0]:.3f})")
# Output: Document type: appraisal report (0.943)
```

### 3. Servicer Notes Summarization Pipeline

```python
import snowflake.connector
from transformers import pipeline

# Pull servicer notes from Snowflake
conn = snowflake.connector.connect(
    account="myorg-myaccount",
    user="svc_nlp",
    private_key=load_private_key(),
    warehouse="NLP_WH",
    database="MORTGAGE_DW",
    schema="SERVICING"
)

cursor = conn.cursor()
cursor.execute("""
    SELECT loan_id, note_date, note_text
    FROM SERVICER_NOTES
    WHERE note_date >= DATEADD(day, -30, CURRENT_DATE)
      AND note_category = 'LOSS_MITIGATION'
      AND LEN(note_text) > 200
    LIMIT 10000
""")
notes = cursor.fetchall()

summarizer = pipeline("summarization", model="facebook/bart-large-cnn", device=0)

summaries = []
texts = [row[2] for row in notes]

# Batch in groups of 8 (BART is memory-intensive)
for i in range(0, len(texts), 8):
    batch = texts[i:i+8]
    results = summarizer(batch, max_length=100, min_length=30, do_sample=False)
    summaries.extend([r["summary_text"] for r in results])

# Write summaries back to Snowflake
insert_data = [
    (row[0], row[1], summary)
    for row, summary in zip(notes, summaries)
]
cursor.executemany(
    "INSERT INTO SERVICER_NOTE_SUMMARIES (loan_id, note_date, summary) VALUES (%s, %s, %s)",
    insert_data
)
conn.commit()
```

---

## Inference Optimization

### Half Precision (fp16 / bf16)

```python
import torch
from transformers import AutoModel, AutoTokenizer

model = AutoModel.from_pretrained("bert-large-uncased")

# fp16: ~2x speed, ~50% memory on NVIDIA GPUs
model = model.half().cuda()

# bf16: better numerical stability than fp16, preferred on Ampere+ (A10G, A100)
model = model.to(torch.bfloat16).cuda()

# Automatic mixed precision during inference
with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
    outputs = model(**inputs)
```

### Optimization Comparison

| Technique | Speedup | Memory Reduction | When to Use |
|---|---|---|---|
| fp16 inference | ~2x | ~50% | NVIDIA V100/T4/A100 |
| bf16 inference | ~2x | ~50% | Ampere+ GPUs; more stable |
| `torch.compile()` | 1.5–3x | minimal | PyTorch 2.0+; one-time compile cost |
| Batch inference | 4–8x | none | Always; single-item calls are wasteful |
| ONNX Runtime | 1.5–2x | minimal | CPU inference; cross-framework |
| TensorRT | 3–8x | varies | NVIDIA production deployment |
| Quantization (INT8) | 2–4x | ~75% | Edge/CPU; slight accuracy drop |

---

## Hugging Face Inference Endpoints

For production deployments without managing GPU infrastructure:

```python
import requests

API_URL = "https://api-inference.huggingface.co/models/ProsusAI/finbert"
headers = {"Authorization": f"Bearer {HF_API_TOKEN}"}

def query_inference_endpoint(texts: list[str]) -> list[dict]:
    payload = {"inputs": texts, "options": {"wait_for_model": True}}
    response = requests.post(API_URL, headers=headers, json=payload)
    response.raise_for_status()
    return response.json()

results = query_inference_endpoint([
    "Agency MBS spreads widened 15bps on stronger jobs report",
    "Non-QM origination volumes declined 40% year-over-year"
])
```

---

## Snowpark Container Services for HF Models in Snowflake

Run HuggingFace models entirely inside Snowflake — no data leaves the platform:

```python
# Dockerfile for Snowpark Container Services
"""
FROM python:3.11-slim
RUN pip install transformers torch sentence-transformers snowflake-snowpark-python
COPY app.py /app/app.py
CMD ["python", "/app/app.py"]
"""

# app.py — Snowpark UDF serving HuggingFace model
from snowflake.snowpark import Session
from sentence_transformers import SentenceTransformer
import pandas as pd

session = Session.builder.getOrCreate()

model = SentenceTransformer("all-MiniLM-L6-v2")

@udf(name="EMBED_DOCUMENT", packages=["sentence-transformers"])
def embed_document(text: str) -> list:
    return model.encode([text])[0].tolist()
```

```sql
-- After registering the UDF, use it in SQL
SELECT
    document_id,
    document_type,
    EMBED_DOCUMENT(text_excerpt) AS embedding
FROM MORTGAGE.NLP.LOAN_DOCUMENTS
WHERE processed_date = CURRENT_DATE;
```

---

## Interview Q&A

**Q1: What is the difference between `AutoModel` and `AutoModelForSequenceClassification`, and when would you use each?**

`AutoModel` returns the raw transformer backbone — typically a `BaseModelOutput` with `last_hidden_state` (shape `[batch, seq_len, hidden_dim]`). It has no task-specific head. You use it when extracting embeddings for downstream tasks or training custom heads. `AutoModelForSequenceClassification` adds a classification head (linear layer + softmax) on top of the pooled [CLS] representation. Use it for text classification tasks like document type labeling or sentiment analysis. Both load the same pretrained weights; the `ForSequenceClassification` variant adds randomly initialized head weights that need fine-tuning on your labeled data.

---

**Q2: What is tokenization and why does it matter for mortgage document processing?**

Tokenization converts raw text into integer IDs that the model processes. The vocabulary is fixed at pre-training time, so domain-specific terms in mortgage documents — "DSCR," "LTV," "HELOC," "HMDA," "TRID," "CLTV" — may be split into multiple subword tokens (e.g., "DSCR" → ["DS", "##CR"]). This has two implications: (1) the model may not have learned good representations for these terms unless fine-tuned on financial text; (2) a document that appears to be 300 words may tokenize to 500+ tokens, hitting the 512-token limit of BERT-family models. Mitigations include using a finance-specific model like FinBERT, sliding-window tokenization with stride, or chunking documents by section before processing.

---

**Q3: How would you build a pipeline to classify 500,000 loan documents stored in Snowflake by type (appraisal, title, closing disclosure, etc.)?**

Step 1: Extract text excerpts from Snowflake (first 500 characters are typically sufficient for doc-type classification) into a Spark DataFrame or Python batch process. Step 2: Load a fine-tuned or zero-shot classification model. For a cold start with no labeled data, use `facebook/bart-large-mnli` with zero-shot classification. For production, fine-tune `distilbert-base-uncased` on 1,000 manually labeled examples — DistilBERT is 40% smaller and 60% faster than BERT with 97% of its performance. Step 3: Batch inference with GPU (batch_size=64, fp16) using a Pandas UDF in Spark or a Snowpark Python UDTF. Step 4: Write predictions back to Snowflake with confidence scores. Step 5: Route low-confidence predictions (< 0.85) to a human review queue. Expect throughput of ~2,000–5,000 documents/minute on a single A10G GPU.

---

**Q4: Explain the difference between fine-tuning and using a model off-the-shelf. When would you fine-tune a HuggingFace model for mortgage data?**

Off-the-shelf means using a pre-trained model's existing capabilities without modifying weights. This works for general NER, sentiment, and summarization. Fine-tuning updates model weights on domain-specific labeled data, teaching it vocabulary and patterns specific to mortgage. Fine-tune when: (1) the task is domain-specific — e.g., extracting loan numbers, property addresses in the exact formats used in MISMO XML; (2) off-the-shelf performance is below acceptable threshold (< 85% F1 on your test set); (3) you have 500+ labeled examples. Fine-tuning with PEFT/LoRA is practical even on a single GPU: freeze the backbone, train only low-rank adapter matrices (< 1% of parameters), cutting GPU memory by 10–20x versus full fine-tuning.

---

**Q5: What is the difference between sentence-transformers and standard BERT embeddings from `AutoModel`?**

Standard BERT mean-pools the `last_hidden_state` over all tokens to get a sentence vector. This produces poor-quality sentence embeddings because BERT was trained on MLM (fill-mask), not on sentence similarity. Sentence Transformers (SBERT) are BERT-based models fine-tuned on Natural Language Inference and semantic textual similarity data using a siamese network architecture. The resulting embeddings are geometrically meaningful — cosine similarity between two embeddings correlates with semantic similarity. For mortgage document search, vector similarity in Snowflake, or deduplication of servicer notes, always use sentence-transformers (e.g., `all-MiniLM-L6-v2` or `all-mpnet-base-v2`) over raw BERT embeddings.

---

**Q6: How do you handle documents that exceed the 512-token limit of BERT?**

Four strategies: (1) **Truncation** — keep only the first 512 tokens. Works if the relevant information (e.g., document type identifier) is always in the header. (2) **Sliding window** — chunk the document into overlapping 512-token windows using `return_overflowing_tokens=True` and `stride=50` in the tokenizer. Aggregate predictions across chunks (majority vote or max-pooling). (3) **Hierarchical encoding** — split into paragraphs, encode each paragraph independently, then run a second model (or simple aggregation) over paragraph embeddings. (4) **Long-context models** — use Longformer, BigBird, or an LLM with 32K+ context window. For mortgage closing disclosures (typically 5–10 pages), the sliding window approach is standard.

---

**Q7: How would you use FinBERT for market sentiment analysis on mortgage news to feed into a prepayment model?**

```python
from transformers import pipeline
import pandas as pd

finbert = pipeline(
    "text-classification",
    model="ProsusAI/finbert",
    device=0
)

def score_news_sentiment(news_df: pd.DataFrame) -> pd.DataFrame:
    """
    news_df: columns [date, headline, article_text]
    Returns: same + [sentiment_label, sentiment_score, sentiment_numeric]
    """
    # Use headline + first 200 chars of article for speed
    texts = (news_df["headline"] + ". " + news_df["article_text"].str[:200]).tolist()

    results = finbert(texts, batch_size=32, truncation=True, max_length=512)

    news_df["sentiment_label"] = [r["label"] for r in results]
    news_df["sentiment_score"] = [r["score"] for r in results]
    # Map to numeric: positive=1, neutral=0, negative=-1
    label_map = {"positive": 1, "neutral": 0, "negative": -1}
    news_df["sentiment_numeric"] = news_df["sentiment_label"].map(label_map)

    return news_df
```

The resulting `sentiment_numeric` feature, aggregated as a weekly rolling mean, can be added as a macro feature in prepayment speed (CPR) prediction models alongside refinance incentive, seasonality, and burnout indicators.

---

**Q8: What is Retrieval-Augmented Generation (RAG) and how would you implement it for a mortgage Q&A system over regulatory documents?**

RAG combines a retrieval step (semantic search over a document corpus) with a generation step (LLM answers the question based on retrieved context). Architecture: (1) Offline — chunk regulatory documents (RESPA, TRID, Fannie Mae Selling Guide) into 300-token passages, embed with `all-MiniLM-L6-v2`, store vectors in Snowflake VECTOR column or Pinecone. (2) Online — embed user question, retrieve top-K passages by cosine similarity, concatenate passages as context, pass to an LLM (e.g., `mistralai/Mistral-7B-Instruct`) with the prompt `"Answer based on the following context: {context}\n\nQuestion: {question}"`. This is preferable to pure LLM for compliance-sensitive use cases because answers are grounded in source documents and you can cite the exact passage.

---

**Q9: How do you deploy a HuggingFace model in production for low-latency inference (< 100ms p99)?**

For < 100ms p99: (1) Use `distilbert` or `all-MiniLM` — they are 3–6x faster than BERT-large with minimal accuracy loss. (2) Export to ONNX and run via `onnxruntime` on CPU or GPU — typically 1.5–2x faster than PyTorch. (3) For GPU: apply TensorRT optimization (FP16 or INT8) via `optimum` library from HuggingFace — 3–5x faster. (4) Host behind FastAPI with a request queue; use async batching to group concurrent requests into a single forward pass. (5) For Snowflake-native: Snowpark Container Services with a persistent container avoids cold-start overhead. (6) Pre-compute embeddings for static documents offline; only compute embeddings for new/changed documents.

---

**Q10: How does the `datasets` library differ from pandas for processing large NLP datasets, and when does it matter?**

`datasets` is backed by Apache Arrow with memory-mapping: the dataset lives on disk and is accessed via OS page cache, so you can process datasets larger than RAM without loading them fully into memory. It supports lazy `.map()` operations that are applied on-the-fly during iteration, automatic caching of intermediate results, and multi-process transformation. For a 10M-row loan document corpus, loading with pandas would require ~20GB RAM for text columns; `datasets` handles it with 2GB. It also provides direct HuggingFace `Trainer` integration and efficient `DataCollatorWithPadding` for dynamic padding during training. Use `datasets` for any corpus that doesn't comfortably fit in memory or when feeding data to `Trainer`.

---

## Pro Tips

- **Start with FinBERT for anything financial.** `ProsusAI/finbert` is fine-tuned on financial news and outperforms `bert-base` on mortgage market sentiment classification without any fine-tuning.
- **Cache tokenized outputs.** Tokenization is CPU-bound and repeated every training epoch. Call `dataset.map(tokenize_function, batched=True)` once and cache with `datasets` library.
- **Use `pipeline()` for prototyping, not production.** The `pipeline()` API is convenient but adds overhead and limits batching control. For production batch inference, use the raw model + DataLoader pattern.
- **Embedding model selection matters more than you think.** `all-MiniLM-L6-v2` (384-dim) is the default workhorse. For higher accuracy on technical financial text, `BAAI/bge-large-en-v1.5` (1024-dim) consistently ranks higher on the MTEB benchmark.
- **Monitor token length distribution.** Before production, histogram the token lengths of your corpus. If > 20% of documents exceed 512 tokens, you need a chunking strategy — silent truncation loses information.
- **Quantization for CPU inference.** If deploying to a CPU-only environment, apply dynamic quantization: `torch.quantization.quantize_dynamic(model, {torch.nn.Linear}, dtype=torch.qint8)`. Typically 2–4x faster on CPU with < 1% accuracy drop for classification.
- **Never store raw PII in embedding tables.** For mortgage documents containing SSNs, DOBs, and property addresses, redact or tokenize PII before generating and storing embeddings. GDPR and CCPA apply to vector stores.
