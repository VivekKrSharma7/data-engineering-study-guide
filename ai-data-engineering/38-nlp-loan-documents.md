# NLP for Loan Document Processing

[← Back to Index](README.md)

---

## Overview

A typical mortgage loan package contains 200-500 pages across 20-30 distinct document types. Manual data entry from these documents drives high operational costs, keying errors, and closing delays. NLP and document AI pipelines replace manual extraction with automated, validated workflows: OCR converts scanned images to text, document classifiers route each page to the right extractor, NER and form-extraction models pull structured fields, and validation logic cross-checks extracted values against the loan origination system (LOS) of record. This guide covers the full pipeline — from raw PDF ingestion to a validated structured record — with emphasis on tools relevant to Azure, AWS, and Snowflake environments used in the secondary mortgage market.

---

## Key Concepts

| Concept | Definition |
|---|---|
| OCR | Optical Character Recognition — converts scanned document images to machine-readable text |
| NER | Named Entity Recognition — identifies and classifies entities (names, amounts, dates, addresses) in text |
| Form Extraction | Identifying key-value pairs from structured form fields |
| Table Extraction | Parsing rows and columns from tabular content in documents |
| Document Classification | Predicting document type (appraisal, title policy, CD, etc.) from content |
| 1003 | Uniform Residential Loan Application — the primary mortgage application form |
| Closing Disclosure (CD) | TRID-required form disclosing final loan terms and costs at closing |
| Deed of Trust / Mortgage | Security instrument pledging property as collateral |
| Textract | AWS managed OCR and form/table extraction service |
| Azure Document Intelligence | Azure managed service for forms, tables, and custom document models |
| Snowflake Document AI | Snowflake Cortex feature: CLASSIFY and EXTRACT_ANSWER on staged documents |

---

## Types of Loan Documents

### Core Origination Package

| Document | Key Fields | Extraction Challenge |
|---|---|---|
| 1003 Application | Borrower name, SSN, income, assets, employment, loan amount, property address | Multi-page, section-based; handwritten and typed versions |
| Appraisal (URAR 1004) | Appraised value, effective date, comparable sales, property condition | Complex grid layouts, sketch maps |
| Closing Disclosure | APR, loan amount, rate, closing costs, cash to close | Multi-section TRID form; tolerances matter legally |
| Note | Interest rate, payment schedule, maturity date, rider list | Standardized FNMA/FHLMC forms but state variations exist |
| Deed of Trust / Mortgage | Legal description, lien position, trustee name | State-specific templates; critical for title chain |
| Title Commitment | Exceptions and exclusions, covered amount, policy type | Unstructured narrative with legal exceptions list |
| W-2 / 1099 | Employer name, wages, federal withholding, year | Variable layouts across employers and tax years |
| Bank Statements | Account number, balance, transaction history | Hundreds of transaction rows; NSF events must be flagged |
| VOE / VOR | Employer, hire date, salary; landlord, rent amount | Often faxed PDFs — degraded scan quality |

---

## Document Processing Pipeline

```
Raw Input (PDF / TIFF / JPEG)
        │
        ▼
[1] Pre-processing
    - PDF splitting (one doc → individual pages)
    - Image deskewing, denoising, binarization
    - Resolution normalization (300 DPI minimum for OCR)
        │
        ▼
[2] OCR Layer
    - AWS Textract / Azure Document Intelligence / Tesseract
    - Output: raw text blocks + bounding box coordinates
    - Confidence scores per word/line
        │
        ▼
[3] Document Classification
    - ML classifier: predict document type from text features
    - Route to type-specific extractor
        │
        ▼
[4] Field Extraction
    - Form fields: key-value pair detection
    - Tables: row/column structure detection
    - NER: entities not in structured fields
    - LLM-based extraction for unstructured narrative sections
        │
        ▼
[5] Post-processing & Validation
    - Normalize values (dates, currency, percentages)
    - Cross-validate against LOS data (loan amount, borrower name, property address)
    - Flag discrepancies for human review
        │
        ▼
[6] Structured Output
    - Load to Snowflake staging table
    - Trigger downstream data quality checks
    - Audit trail: page-level confidence scores, extraction timestamps
```

---

## OCR Tool Comparison

| Tool | Strengths | Limitations | Best For |
|---|---|---|---|
| AWS Textract | Table extraction, form key-value, Queries API, native S3 integration | Cost at scale; async API latency | Mixed documents in AWS pipelines |
| Azure Document Intelligence | Prebuilt models for W-2, 1099, pay stubs, ID; custom model training | Azure ecosystem lock-in | Azure-native shops; prebuilt mortgage forms |
| Google Document AI | High accuracy on unstructured text; processor specialization | Less native mortgage-specific models | General NLP pipeline |
| Tesseract | Open source, no cost, local processing | Lower accuracy on degraded scans; no form structure | Dev/test; high-volume low-quality images |

---

## Python: Azure Document Intelligence Extraction Pipeline

```python
import os
import json
from azure.ai.formrecognizer import DocumentAnalysisClient
from azure.core.credentials import AzureKeyCredential
import pandas as pd
from datetime import datetime

# -------------------------------------------------------
# Configuration
# -------------------------------------------------------
ENDPOINT = os.environ["AZURE_FORM_RECOGNIZER_ENDPOINT"]
KEY      = os.environ["AZURE_FORM_RECOGNIZER_KEY"]

client = DocumentAnalysisClient(
    endpoint=ENDPOINT,
    credential=AzureKeyCredential(KEY)
)

# -------------------------------------------------------
# 1. Closing Disclosure extraction using prebuilt model
# -------------------------------------------------------
def extract_closing_disclosure(pdf_path: str) -> dict:
    """
    Uses Azure prebuilt-document model to extract key-value pairs
    from a TRID Closing Disclosure.
    """
    with open(pdf_path, "rb") as f:
        poller = client.begin_analyze_document(
            "prebuilt-document", document=f
        )
    result = poller.result()

    extracted = {}
    for kv in result.key_value_pairs:
        if kv.key and kv.value:
            key_text   = kv.key.content.strip()
            value_text = kv.value.content.strip()
            confidence = kv.confidence
            extracted[key_text] = {
                "value": value_text,
                "confidence": confidence
            }
    return extracted

# -------------------------------------------------------
# 2. Table extraction from bank statements
# -------------------------------------------------------
def extract_bank_statement_tables(pdf_path: str) -> list[pd.DataFrame]:
    """
    Extract transaction tables from bank statement PDFs.
    Returns list of DataFrames, one per detected table.
    """
    with open(pdf_path, "rb") as f:
        poller = client.begin_analyze_document(
            "prebuilt-layout", document=f
        )
    result = poller.result()

    tables = []
    for table in result.tables:
        grid = {}
        for cell in table.cells:
            row = cell.row_index
            col = cell.column_index
            if row not in grid:
                grid[row] = {}
            grid[row][col] = cell.content

        df = pd.DataFrame.from_dict(grid, orient="index")
        df.columns = range(df.shape[1])
        tables.append(df)

    return tables

# -------------------------------------------------------
# 3. Document classifier
# -------------------------------------------------------
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
import pickle

DOC_TYPES = [
    "LOAN_APPLICATION_1003",
    "APPRAISAL",
    "CLOSING_DISCLOSURE",
    "NOTE",
    "DEED_OF_TRUST",
    "TITLE_COMMITMENT",
    "W2",
    "BANK_STATEMENT",
    "PAY_STUB"
]

def classify_document(raw_text: str, model_path: str) -> str:
    """
    Predict document type from raw OCR text.
    Returns document type string.
    """
    with open(model_path, "rb") as f:
        pipeline = pickle.load(f)  # TfidfVectorizer + LogisticRegression pipeline
    pred = pipeline.predict([raw_text])[0]
    return DOC_TYPES[pred]

# -------------------------------------------------------
# 4. NER pipeline using spaCy custom model
# -------------------------------------------------------
import spacy

nlp = spacy.load("mortgage_ner_model")  # custom trained model

def extract_entities_from_text(text: str) -> dict:
    """
    Extract mortgage-specific entities:
    BORROWER_NAME, PROPERTY_ADDRESS, LOAN_AMOUNT, INTEREST_RATE,
    ORIGINATION_DATE, MATURITY_DATE, LENDER_NAME, SSN_REDACTED
    """
    doc = nlp(text)
    entities = {}
    for ent in doc.ents:
        entities[ent.label_] = ent.text
    return entities

# -------------------------------------------------------
# 5. LLM-based extraction for unstructured narrative sections
# -------------------------------------------------------
import openai  # or use Azure OpenAI endpoint

def extract_title_exceptions(title_text: str) -> list[str]:
    """
    Use GPT-4 to extract title exceptions from unstructured narrative.
    Traditional regex/NER fails on legal exception language.
    """
    response = openai.chat.completions.create(
        model="gpt-4o",
        messages=[
            {
                "role": "system",
                "content": (
                    "You are a mortgage title expert. "
                    "Extract all Schedule B title exceptions as a JSON list of strings. "
                    "Return only valid JSON."
                )
            },
            {"role": "user", "content": title_text}
        ],
        temperature=0,
        response_format={"type": "json_object"}
    )
    result = json.loads(response.choices[0].message.content)
    return result.get("exceptions", [])

# -------------------------------------------------------
# 6. Validation: cross-check against LOS
# -------------------------------------------------------
def validate_extracted_fields(extracted: dict, los_record: dict) -> list[dict]:
    """
    Compare extracted document fields against loan origination system.
    Returns list of discrepancies for human review queue.
    """
    TOLERANCE_DOLLAR = 1.00   # $1 tolerance for currency fields
    TOLERANCE_RATE   = 0.001  # 0.1% tolerance for interest rates

    discrepancies = []

    checks = [
        ("LOAN_AMOUNT",    "loan_amount",    TOLERANCE_DOLLAR),
        ("INTEREST_RATE",  "note_rate",      TOLERANCE_RATE),
        ("BORROWER_NAME",  "borrower_name",  None),
        ("PROPERTY_ADDRESS", "property_address", None),
    ]

    for doc_key, los_key, tolerance in checks:
        doc_val = extracted.get(doc_key, {}).get("value")
        los_val = los_record.get(los_key)

        if doc_val is None or los_val is None:
            discrepancies.append({
                "field": doc_key,
                "issue": "MISSING",
                "doc_value": doc_val,
                "los_value": los_val
            })
            continue

        if tolerance is not None:
            try:
                doc_num = float(str(doc_val).replace("$", "").replace(",", ""))
                los_num = float(los_val)
                if abs(doc_num - los_num) > tolerance:
                    discrepancies.append({
                        "field": doc_key,
                        "issue": "MISMATCH",
                        "doc_value": doc_val,
                        "los_value": los_val,
                        "delta": abs(doc_num - los_num)
                    })
            except ValueError:
                pass
        else:
            if str(doc_val).upper() != str(los_val).upper():
                discrepancies.append({
                    "field": doc_key,
                    "issue": "MISMATCH",
                    "doc_value": doc_val,
                    "los_value": los_val
                })

    return discrepancies
```

---

## AWS Textract for Loan Documents

```python
import boto3
import json
import time

textract = boto3.client("textract", region_name="us-east-1")
s3       = boto3.client("s3")

def analyze_loan_document_async(bucket: str, key: str) -> dict:
    """
    Asynchronous Textract analysis for multi-page PDFs.
    Returns complete Textract response with FORMS, TABLES, SIGNATURES.
    """
    response = textract.start_document_analysis(
        DocumentLocation={"S3Object": {"Bucket": bucket, "Name": key}},
        FeatureTypes=["FORMS", "TABLES", "SIGNATURES"]
    )
    job_id = response["JobId"]

    # Poll for completion
    while True:
        result = textract.get_document_analysis(JobId=job_id)
        status = result["JobStatus"]
        if status in ("SUCCEEDED", "FAILED"):
            break
        time.sleep(5)

    if status == "FAILED":
        raise RuntimeError(f"Textract job {job_id} failed")

    # Collect all pages (paginated)
    blocks = result["Blocks"]
    next_token = result.get("NextToken")
    while next_token:
        result = textract.get_document_analysis(
            JobId=job_id, NextToken=next_token
        )
        blocks.extend(result["Blocks"])
        next_token = result.get("NextToken")

    return {"JobId": job_id, "Blocks": blocks}

def extract_form_fields(blocks: list) -> dict:
    """
    Parse Textract KEY_VALUE_SET blocks into a flat dict.
    """
    key_map, value_map, block_map = {}, {}, {}

    for block in blocks:
        block_map[block["Id"]] = block
        if block["BlockType"] == "KEY_VALUE_SET":
            if "KEY" in block.get("EntityTypes", []):
                key_map[block["Id"]] = block
            else:
                value_map[block["Id"]] = block

    def get_text(block):
        text = ""
        for rel in block.get("Relationships", []):
            if rel["Type"] == "CHILD":
                for child_id in rel["Ids"]:
                    child = block_map.get(child_id, {})
                    if child.get("BlockType") == "WORD":
                        text += child.get("Text", "") + " "
        return text.strip()

    results = {}
    for key_id, key_block in key_map.items():
        key_text = get_text(key_block)
        value_text = ""
        for rel in key_block.get("Relationships", []):
            if rel["Type"] == "VALUE":
                for val_id in rel["Ids"]:
                    val_block = value_map.get(val_id)
                    if val_block:
                        value_text = get_text(val_block)
        if key_text:
            results[key_text] = value_text

    return results
```

---

## Snowflake Document AI

Snowflake Cortex Document AI allows querying staged PDF documents directly with natural language using `EXTRACT_ANSWER` and `CLASSIFY` functions (Preview/GA status varies by region).

```sql
-- Stage documents in Snowflake internal stage
PUT file:///local/path/closing_disclosure_12345.pdf
    @LOAN_DOCS.STAGE_CLOSING_DISCLOSURES
    AUTO_COMPRESS=FALSE;

-- Extract specific fields using EXTRACT_ANSWER
SELECT
    relative_path                                           AS document_name,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        GET_PRESIGNED_URL(@LOAN_DOCS.STAGE_CLOSING_DISCLOSURES,
                          relative_path, 3600),
        'What is the loan amount?'
    )['answer']::STRING                                    AS loan_amount,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        GET_PRESIGNED_URL(@LOAN_DOCS.STAGE_CLOSING_DISCLOSURES,
                          relative_path, 3600),
        'What is the interest rate?'
    )['answer']::STRING                                    AS interest_rate,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        GET_PRESIGNED_URL(@LOAN_DOCS.STAGE_CLOSING_DISCLOSURES,
                          relative_path, 3600),
        'What is the borrower name?'
    )['answer']::STRING                                    AS borrower_name
FROM DIRECTORY(@LOAN_DOCS.STAGE_CLOSING_DISCLOSURES)
WHERE relative_path ILIKE '%.pdf';

-- Document classification
SELECT
    relative_path,
    SNOWFLAKE.CORTEX.CLASSIFY(
        GET_PRESIGNED_URL(@LOAN_DOCS.STAGE_ALL_DOCS, relative_path, 3600),
        ARRAY_CONSTRUCT(
            'CLOSING_DISCLOSURE', 'NOTE', 'DEED_OF_TRUST',
            'APPRAISAL', 'TITLE_COMMITMENT', 'BANK_STATEMENT', 'W2'
        )
    )['label']::STRING AS document_type
FROM DIRECTORY(@LOAN_DOCS.STAGE_ALL_DOCS);
```

---

## Loading Extracted Data to Snowflake

```sql
-- Staging table for extracted document fields
CREATE OR REPLACE TABLE LOAN_DOCS.EXTRACTED_FIELDS (
    extraction_id       VARCHAR       DEFAULT UUID_STRING(),
    loan_id             VARCHAR       NOT NULL,
    document_type       VARCHAR       NOT NULL,
    document_name       VARCHAR       NOT NULL,
    extraction_source   VARCHAR       NOT NULL,  -- TEXTRACT, AZURE_DI, SNOWFLAKE_CORTEX
    field_name          VARCHAR       NOT NULL,
    field_value         VARCHAR,
    confidence_score    FLOAT,
    page_number         INT,
    extracted_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    validated_flag      BOOLEAN       DEFAULT FALSE,
    validation_status   VARCHAR,      -- MATCH, MISMATCH, MISSING, PENDING
    los_value           VARCHAR
);

-- Discrepancy view for human review queue
CREATE OR REPLACE VIEW LOAN_DOCS.V_REVIEW_QUEUE AS
SELECT
    e.loan_id,
    e.document_type,
    e.document_name,
    e.field_name,
    e.field_value        AS extracted_value,
    e.los_value,
    e.confidence_score,
    e.extraction_source,
    e.extracted_at
FROM LOAN_DOCS.EXTRACTED_FIELDS e
WHERE e.validation_status IN ('MISMATCH', 'MISSING')
   OR e.confidence_score < 0.80
ORDER BY e.extracted_at DESC;
```

---

## LLM-Based Extraction vs. Traditional NLP

| Dimension | Traditional NLP (spaCy / regex / ML) | LLM-Based Extraction (GPT-4 / Claude) |
|---|---|---|
| Setup cost | High (labeled training data, model training) | Low (prompt engineering) |
| Accuracy on structured forms | High (form models are well-defined) | Comparable, can be better for variation |
| Accuracy on unstructured text | Medium (NER depends on training domain) | High (better contextual understanding) |
| Latency | Low (local inference, <100ms) | Higher (API calls, 1-10 seconds) |
| Cost at scale | Low (after initial training) | High (token-based pricing) |
| Explainability | High (rule-based or feature-level) | Low (black box) |
| Regulatory comfort | Higher (deterministic) | Lower (requires validation framework) |
| Best use | High-volume form fields, known layouts | Unstructured narrative, edge cases |

Recommended approach: use Azure Document Intelligence prebuilt models for known forms (1003, W-2, 1099, pay stubs), LLM extraction for title exception narratives and unusual document types, and traditional NER for entity linking across documents.

---

## Interview Q&A

**Q1: What are the key challenges in processing mortgage loan documents with OCR, and how do you address them?**

The primary challenges are: (1) scan quality — faxed documents, folded pages, handwritten fields; addressed by pre-processing (deskewing, denoising, adaptive binarization) and selecting OCR engines with confidence scoring so low-confidence pages are flagged for review; (2) document variability — lenders use different 1003 versions, state-specific deeds of trust, non-standard appraisal formats; addressed by training custom extraction models per document type; (3) table density — bank statements and payment schedules have complex multi-row tables with merged cells; AWS Textract and Azure Layout API handle this better than raw Tesseract; (4) PII — SSNs, DOBs, account numbers must be redacted or tokenized before landing in analytics systems; handled at the post-OCR layer before any downstream storage.

**Q2: How do you validate that an extracted loan amount from the Closing Disclosure matches the loan origination system?**

The validation layer compares the normalized numeric value extracted from the CD against the `LOAN_AMOUNT` field in the LOS via a direct join on `LOAN_ID`. Currency strings ("$485,000.00") are stripped of symbols and commas before comparison. We apply a $1.00 tolerance to account for rounding. Any delta exceeding tolerance is written to a discrepancy table and placed in a human review queue. We also cross-validate across documents within the same package — the loan amount on the Note, the CD, and the 1003 should all agree; three-way discrepancies indicate a potential fraud indicator or data entry error.

**Q3: When would you use Snowflake Document AI versus AWS Textract or Azure Document Intelligence?**

Use Snowflake Document AI when: (1) documents are already staged in Snowflake internal stages and the extraction volume is moderate; (2) you want SQL-native extraction without building a separate microservice; (3) the use case is exploratory or for ad hoc analyst queries. Use Textract or Azure Document Intelligence when: (1) you need high-throughput, production-grade extraction with SLAs; (2) you need prebuilt models for specific form types (Azure has W-2, 1099, invoice models); (3) you need fine-grained confidence scores and bounding-box coordinates for UI review interfaces; (4) the documents live in S3 or Azure Blob and the extraction service is part of a broader cloud-native pipeline.

**Q4: How do you build a document classifier to distinguish between a Closing Disclosure and a Note?**

Start with TF-IDF features on the first page's text (document type is almost always determinable from page one). Key signal words: "Closing Disclosure" appears verbatim in TRID-compliant CDs; "Adjustable Rate Note" or "Fixed Rate Note" in Notes; "Deed of Trust" or "Mortgage" in security instruments. A Logistic Regression or SVM classifier trained on 1,000-2,000 labeled examples per class achieves >98% accuracy on standard GSE document packages. Edge cases: multi-document PDFs bundled by the scanner require page-level classification and document boundary detection. For production, supplement the text classifier with layout features: page count, table density, header/footer patterns.

**Q5: What NLP pipeline would you build to extract all comparable sales from a residential appraisal report?**

The appraisal URAR 1004 has a standard six-column grid for comparable sales. Use Azure Document Intelligence's Layout API to extract the table structure — it handles merged headers and multi-row cells well. Once you have the table as a DataFrame, normalize column headers to canonical names (address, sale date, sale price, GLA, lot size, condition). For non-standard appraisal formats, train a custom Azure Document Intelligence model on 50-100 labeled appraisals, which typically achieves >90% field-level accuracy. For comp sale prices, add a validation step comparing extracted comp values to public deed records via ATTOM or CoreLogic API to flag implausible sales.

**Q6: How do you handle PII in a loan document processing pipeline?**

PII in mortgage documents includes SSNs, full DOBs, account numbers, and income figures. The pipeline must: (1) redact or tokenize at the earliest possible stage — immediately after OCR output, before writing to any storage system; (2) use a pattern-based redaction layer (regex for SSN format XXX-XX-XXXX, account number patterns) combined with an NER model identifying PERSON entities; (3) replace values with tokens in the extracted field store (e.g., SSN → vault-assigned token, retrievable only by authorized processes); (4) ensure Snowflake column-level security on tables storing extracted PII fields; (5) maintain audit logs of who accessed extracted PII fields and when. CCPA, GLBA, and investor data security addenda all require demonstrable PII controls.

**Q7: How would you measure the accuracy of your document extraction pipeline in production?**

Define a ground truth dataset: 500-1,000 manually reviewed loan packages with field-level annotations. Compute field-level precision and recall: how often does the extractor produce the correct value for `LOAN_AMOUNT`, `INTEREST_RATE`, `BORROWER_NAME`, etc.? Track: (1) extraction rate — percentage of fields successfully extracted vs. missing; (2) accuracy — of extracted fields, percentage matching ground truth within tolerance; (3) confidence calibration — do high-confidence extractions actually have higher accuracy? In production monitoring, use LOS match rate as a proxy for accuracy: if the extraction-to-LOS match rate for `LOAN_AMOUNT` drops below 95%, trigger an alert. Maintain a random sampling program where 2-5% of all packages receive full manual review to catch model drift.

**Q8: What is the difference between AWS Textract Queries and standard key-value extraction?**

Standard key-value extraction finds all key-value pairs in a document based on visual layout — it returns everything it can detect but doesn't let you target specific fields. The Queries API lets you ask targeted questions: `"What is the loan amount?"` and Textract returns the specific answer with its bounding box and confidence score. Queries is far more useful in mortgage processing because: (1) you define exactly which fields matter per document type; (2) it handles documents where the field label and value are not visually adjacent (common in dense form layouts); (3) you avoid parsing a 200-key dict to find the three values you actually need. The trade-off is cost — Queries is priced separately from standard analysis.

**Q9: How do you build a loan document ingestion pipeline that meets audit requirements?**

Every step must produce an immutable audit record: (1) document receipt — timestamp, source system, file hash (SHA-256), operator ID; (2) OCR output — confidence score per page, OCR engine version, processing timestamp; (3) extraction output — field name, extracted value, confidence, page reference, model version; (4) validation result — match/mismatch against LOS, reviewer ID and timestamp if manually resolved; (5) final disposition — accepted, rejected, exception-noted. Store audit records in append-only Snowflake tables (ROW ACCESS POLICY restricting deletes). For SOC 2 and investor audit purposes, you need to demonstrate that a specific extracted value at a specific point in time drove a specific downstream decision.

**Q10: How would you use an LLM to improve extraction of title insurance exception language?**

Title exceptions are unstructured legal narrative (e.g., "Subject to easements, restrictions, and conditions of record as shown on Plat Book 12, Page 34, Public Records of Orange County, Florida"). Traditional regex and NER models fail because the exceptions are highly varied, jurisdiction-specific, and often multi-sentence. LLM approach: (1) extract all text from Schedule B of the title commitment using OCR; (2) prompt GPT-4 / Claude to return a structured JSON list of exceptions, each with `type` (easement, restriction, encumbrance, lien), `description`, and `instrument_reference`; (3) post-process the JSON to check for material items requiring underwriter review (e.g., open mortgages, mechanic's liens, code violations); (4) store both the raw LLM output and the structured result for audit purposes. The key control: all LLM-flagged "material" items are routed to a human title examiner — the LLM does not make final underwriting decisions.

---

## Pro Tips

- Azure Document Intelligence's prebuilt W-2 model is production-ready and handles most employer formats. Do not build a custom model for W-2 unless you have a high volume of non-standard formats.
- For multi-page PDFs, split into individual pages before classification. Page-level classification then re-aggregates into document-level results, which is more accurate than classifying the whole PDF as one unit.
- Snowflake staged documents in internal stages are accessible to Cortex Document AI but not from external functions. If you need both Snowflake SQL and external ML processing, stage documents in S3/Azure Blob and reference from both.
- Confidence score thresholds should be set per field, not globally. `LOAN_AMOUNT` might require confidence > 0.95 while `PROPERTY_TYPE` can tolerate 0.85.
- The Freddie Mac UCD (Uniform Closing Dataset) and Fannie Mae MISMO schema define the canonical field names for mortgage closing data. Map your extracted fields to MISMO 3.4 names for interoperability with investor delivery systems.
- When building custom Azure Document Intelligence models, annotate at least 5 examples of each layout variant. Closing Disclosures from different LOS vendors (Encompass, Byte, OpenClose) have subtly different field placements.

---

[← Back to Index](README.md)
