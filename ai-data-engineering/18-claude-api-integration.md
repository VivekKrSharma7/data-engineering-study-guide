# Anthropic Claude API Integration for Data Engineers
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

Anthropic's Claude API provides access to a family of large language models optimized for long-context reasoning, code generation, and document analysis. For a senior data engineer in the mortgage/MBS domain, Claude's defining capabilities are its 200K token context window (enabling full securitization document ingestion), nuanced code generation across SQL and Python, and a strong safety-oriented design that reduces hallucination risk in high-stakes financial contexts.

Claude is available through Anthropic's direct API, Amazon Bedrock (enterprise AWS integration), and Snowflake Cortex (native SQL invocation). This guide covers the full production integration surface for each deployment path with mortgage-domain examples throughout.

---

## Key Concepts

| Concept | Description |
|---|---|
| Claude Opus | Highest capability model; best for complex reasoning and long documents |
| Claude Sonnet | Balanced performance and cost; default choice for most production tasks |
| Claude Haiku | Fastest and cheapest; best for high-volume classification and extraction |
| Messages API | Stateless HTTP API with system prompt + alternating user/assistant turns |
| 200K context window | Enables processing of entire prospectuses, servicing agreements, or code files |
| Tool use | Structured function calling with typed JSON schemas |
| Computer use | Claude 3.5 Sonnet can control a desktop GUI environment |
| Prompt caching | Cache large static context blocks to reduce cost and latency |
| Message Batches API | Async batch processing up to 10,000 requests per batch |
| Amazon Bedrock | AWS-hosted Claude with IAM auth, VPC isolation, and no data training |
| Snowflake Cortex | Run Claude inference via SQL inside Snowflake |

---

## Model Comparison

| Model | Context | Input Cost (per 1M tokens) | Best Use Case |
|---|---|---|---|
| Claude Opus 4 | 200K | ~$15 | Complex securitization analysis, multi-doc reasoning |
| Claude Sonnet 4 | 200K | ~$3 | SQL generation, ETL code, default pipeline tasks |
| Claude Haiku 3.5 | 200K | ~$0.80 | High-volume field extraction, data classification |

> Verify current pricing at console.anthropic.com — rates change with model releases.

---

## Detailed Explanations with Examples

### Messages API: System Prompt and Conversation Turns

The Claude Messages API uses a clean system + messages structure:

```python
import anthropic

client = anthropic.Anthropic()  # Reads ANTHROPIC_API_KEY from environment

response = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=2048,
    system="""You are a senior data engineer specializing in mortgage-backed securities.
All SQL you generate targets Snowflake. Use CTEs for readability.
Never use SELECT *. Always add column aliases on aggregations.
Return only the SQL — no explanation unless explicitly asked.""",
    messages=[
        {
            "role": "user",
            "content": "Write a query to compute the 60-day delinquency rate by pool for the current month."
        }
    ]
)

sql = response.content[0].text
print(sql)

# Usage metadata
print(f"Input tokens:  {response.usage.input_tokens}")
print(f"Output tokens: {response.usage.output_tokens}")
```

Multi-turn conversation:

```python
messages = [
    {"role": "user",      "content": "Write a query for WAC by pool."},
    {"role": "assistant", "content": "SELECT pool_id, SUM(note_rate * curr_upb) / SUM(curr_upb) AS wac FROM loan_master GROUP BY pool_id;"},
    {"role": "user",      "content": "Now add a WHERE clause to filter only FNMA pools."}
]

response = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=512,
    system="You are a Snowflake SQL expert for mortgage analytics.",
    messages=messages
)
```

### Claude's 200K Context Window — Processing Large Documents

The 200K token context window (~150,000 words) is Claude's standout capability for mortgage data work. A full Fannie Mae MBS prospectus supplement (typically 200-400 pages as text) fits in a single API call:

```python
import anthropic
import pathlib

client = anthropic.Anthropic()

def analyze_securitization_document(pdf_text: str, questions: list[str]) -> dict:
    """
    Analyze a full MBS prospectus using Claude's long context.
    pdf_text: full extracted text from the prospectus
    questions: list of specific analysis questions
    """
    question_block = "\n".join(f"{i+1}. {q}" for i, q in enumerate(questions))

    response = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=4096,
        system="""You are a structured finance analyst. Answer questions about
MBS documents precisely. Cite specific sections when referencing document text.
Return answers as a JSON array with keys: question_number, answer, source_section.""",
        messages=[
            {
                "role": "user",
                "content": f"""DOCUMENT:\n{pdf_text}\n\nQUESTIONS:\n{question_block}"""
            }
        ]
    )
    import json
    return json.loads(response.content[0].text)

# Example questions for a FNMA pool prospectus
questions = [
    "What is the aggregate original principal balance of the trust?",
    "What is the weighted average remaining term to maturity?",
    "What credit enhancement mechanisms are described?",
    "What are the delinquency triggers for early amortization?",
    "Which servicer is responsible for advancing delinquent payments?"
]
```

### Tool Use / Function Calling

Claude's tool use mirrors OpenAI's function calling in capability but has a slightly different API structure:

```python
import anthropic
import json

client = anthropic.Anthropic()

tools = [
    {
        "name": "execute_sql_query",
        "description": "Run a read-only SQL query against the Snowflake mortgage warehouse",
        "input_schema": {
            "type": "object",
            "properties": {
                "sql": {
                    "type": "string",
                    "description": "The SELECT SQL query to execute"
                },
                "explanation": {
                    "type": "string",
                    "description": "Plain English: what this query answers"
                }
            },
            "required": ["sql", "explanation"]
        }
    },
    {
        "name": "flag_data_quality_issue",
        "description": "Record a data quality issue found during analysis",
        "input_schema": {
            "type": "object",
            "properties": {
                "table_name":    {"type": "string"},
                "column_name":   {"type": "string"},
                "issue_type":    {"type": "string", "enum": ["null_value", "range_violation", "referential_integrity", "format_error"]},
                "severity":      {"type": "string", "enum": ["LOW", "MEDIUM", "HIGH", "CRITICAL"]},
                "description":   {"type": "string"}
            },
            "required": ["table_name", "issue_type", "severity", "description"]
        }
    }
]

def run_tool_loop(user_question: str, tool_executor) -> str:
    """Run a Claude agent loop until it returns a final text response."""
    messages = [{"role": "user", "content": user_question}]

    while True:
        response = client.messages.create(
            model="claude-sonnet-4-5",
            max_tokens=2048,
            system="You are a mortgage data analyst. Use tools to answer questions accurately.",
            tools=tools,
            messages=messages
        )

        if response.stop_reason == "end_turn":
            return response.content[0].text

        if response.stop_reason == "tool_use":
            # Add assistant response to history
            messages.append({"role": "assistant", "content": response.content})

            # Execute each tool call
            tool_results = []
            for block in response.content:
                if block.type == "tool_use":
                    result = tool_executor(block.name, block.input)
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": json.dumps(result)
                    })

            messages.append({"role": "user", "content": tool_results})
```

### Claude for Code Generation: SQL, Python, dbt

```python
def generate_dbt_model(
    source_table: str,
    transformation_description: str,
    target_grain: str
) -> str:
    """Generate a complete dbt SQL model with documentation."""
    response = client.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=3000,
        system="""Generate dbt SQL models for Snowflake. Always include:
1. A config block with materialization strategy and cluster_by keys
2. Source references using {{ source() }} macro
3. A model-level documentation comment block
4. Clear CTE names that describe each transformation step
5. Final SELECT that matches the stated target grain exactly
Return only the SQL, no surrounding prose.""",
        messages=[{
            "role": "user",
            "content": f"""
Source table: {source_table}
Transformation: {transformation_description}
Target grain: {target_grain}
Generate the complete dbt model.
"""
        }]
    )
    return response.content[0].text

# Example
model_sql = generate_dbt_model(
    source_table="raw.loan_master",
    transformation_description="""
Calculate monthly delinquency metrics per servicer:
- Count of loans by delinquency bucket (current, 30, 60, 90+)
- Total UPB per bucket
- Percentage of portfolio by bucket
""",
    target_grain="one row per servicer per month"
)
```

### Vision Capabilities: Reading Loan Document Images

Claude can analyze images of documents, charts, and scanned forms:

```python
import anthropic
import base64

client = anthropic.Anthropic()

def extract_from_loan_document_image(image_path: str) -> dict:
    """Extract structured fields from a scanned loan document image."""
    with open(image_path, "rb") as f:
        image_data = base64.standard_b64encode(f.read()).decode("utf-8")

    # Detect media type from extension
    ext = image_path.split(".")[-1].lower()
    media_type = {"jpg": "image/jpeg", "jpeg": "image/jpeg",
                  "png": "image/png", "pdf": "application/pdf"}.get(ext, "image/jpeg")

    response = client.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=1024,
        system="""Extract mortgage document fields. Return ONLY valid JSON matching:
{
  "document_type": "string",
  "loan_number": "string or null",
  "borrower_name": "string or null",
  "property_address": "string or null",
  "loan_amount": "number or null",
  "interest_rate": "number or null",
  "origination_date": "YYYY-MM-DD or null",
  "lender_name": "string or null"
}
Use null for any field not present in the document.""",
        messages=[{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": media_type,
                        "data": image_data
                    }
                },
                {
                    "type": "text",
                    "text": "Extract all available mortgage fields from this document image."
                }
            ]
        }]
    )
    import json
    return json.loads(response.content[0].text)
```

### Prompt Caching for Cost Reduction

When your system prompt or context (e.g., full schema DDL, regulatory document) is large and reused across many calls, prompt caching eliminates redundant processing:

```python
import anthropic

client = anthropic.Anthropic()

# Load large static context once (e.g., full data dictionary: ~50K tokens)
with open("/data/mortgage_data_dictionary.txt") as f:
    data_dictionary = f.read()

# System prompt with cache_control on the large static portion
response = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=1024,
    system=[
        {
            "type": "text",
            "text": data_dictionary,
            "cache_control": {"type": "ephemeral"}  # Cache this block
        },
        {
            "type": "text",
            "text": "Use the above data dictionary to answer questions about the mortgage data schema."
            # This smaller, dynamic part is not cached
        }
    ],
    messages=[{
        "role": "user",
        "content": "What table contains the loan delinquency history?"
    }]
)

# Check cache performance
print(f"Cache read tokens:    {response.usage.cache_read_input_tokens}")
print(f"Cache creation tokens:{response.usage.cache_creation_input_tokens}")
print(f"Regular input tokens: {response.usage.input_tokens}")
# Cache reads cost ~10% of normal input token price
```

### Message Batches API

For large-scale async processing (month-end MBS analytics, full-portfolio document extraction):

```python
import anthropic
import json
import time

client = anthropic.Anthropic()

def submit_loan_analysis_batch(loan_records: list[dict]) -> str:
    """Submit a batch of loan risk analysis requests."""
    requests = []
    for loan in loan_records:
        requests.append(
            anthropic.types.message_create_params.MessageCreateParamsNonStreaming(
                model="claude-haiku-3-5",
                max_tokens=150,
                system="Classify mortgage loan risk as LOW, MEDIUM, HIGH, or CRITICAL. Return JSON: {\"risk\": \"string\", \"rationale\": \"string\"}",
                messages=[{
                    "role": "user",
                    "content": (
                        f"FICO={loan['fico']}, LTV={loan['ltv']:.1%}, "
                        f"DTI={loan['dti']:.1%}, PropType={loan['prop_type']}, "
                        f"LoanType={loan['loan_type']}, Status={loan['status']}"
                    )
                }]
            )
        )

    # Build batch request objects
    batch_requests = [
        {"custom_id": f"loan-{loan['loan_id']}", "params": req}
        for loan, req in zip(loan_records, requests)
    ]

    batch = client.messages.batches.create(requests=batch_requests)
    print(f"Batch submitted: {batch.id}")
    return batch.id

def poll_and_retrieve_batch(batch_id: str, poll_interval: int = 60) -> list[dict]:
    """Poll batch until complete and return results."""
    while True:
        batch = client.messages.batches.retrieve(batch_id)
        print(f"Status: {batch.processing_status} | "
              f"Succeeded: {batch.request_counts.succeeded} | "
              f"Pending: {batch.request_counts.processing}")

        if batch.processing_status == "ended":
            break
        time.sleep(poll_interval)

    results = []
    for result in client.messages.batches.results(batch_id):
        if result.result.type == "succeeded":
            content = result.result.message.content[0].text
            results.append({
                "loan_id": result.custom_id.replace("loan-", ""),
                "analysis": json.loads(content)
            })
    return results
```

### Claude via Amazon Bedrock

Bedrock integration uses your AWS IAM credentials — no Anthropic API key needed:

```python
import anthropic
import boto3

# Use Bedrock runtime client
bedrock_client = anthropic.AnthropicBedrock(
    aws_region="us-east-1"
    # Credentials from environment / instance profile / assumed role
    # aws_access_key, aws_secret_key can be passed explicitly if needed
)

response = bedrock_client.messages.create(
    model="anthropic.claude-sonnet-4-5-20251001-v1:0",  # Bedrock model ID format
    max_tokens=2048,
    system="You are a mortgage data engineer. Write Snowflake SQL.",
    messages=[{
        "role": "user",
        "content": "Generate a reconciliation query comparing LOAN_MASTER to SERVICER_FEED."
    }]
)

print(response.content[0].text)
```

IAM policy required for the calling role:

```json
{
  "Effect": "Allow",
  "Action": [
    "bedrock:InvokeModel",
    "bedrock:InvokeModelWithResponseStream"
  ],
  "Resource": "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-*"
}
```

### Claude via Snowflake Cortex

Call Claude directly from SQL — zero data egress from Snowflake:

```sql
-- Single call: generate pool commentary
SELECT
    POOL_ID,
    LOAN_COUNT,
    TOTAL_UPB,
    SNOWFLAKE.CORTEX.COMPLETE(
        'claude-sonnet-4-5',
        [
            {
                'role': 'system',
                'content': 'You are a structured finance analyst. Write concise investor commentary.'
            },
            {
                'role': 'user',
                'content': CONCAT(
                    'Write a 3-sentence pool performance summary for: ',
                    'Pool=', POOL_ID,
                    ', Loans=', LOAN_COUNT::VARCHAR,
                    ', UPB=$', TO_CHAR(TOTAL_UPB, '999,999,999,999'),
                    ', WAC=', WAC::VARCHAR, '%',
                    ', 60+DLQ=', DLQ_60_PLUS_PCT::VARCHAR, '%'
                )
            }
        ]
    ) AS POOL_COMMENTARY
FROM POOL_MONTHLY_METRICS
WHERE REPORT_MONTH = DATE_TRUNC('month', CURRENT_DATE());

-- Batch extraction: parse MISMO XML fields stored in a VARCHAR column
SELECT
    LOAN_ID,
    SNOWFLAKE.CORTEX.COMPLETE(
        'claude-haiku-3-5',
        CONCAT(
            'Extract these fields from the MISMO XML as JSON: ',
            'LoanAmount, InterestRate, PropertyType, OccupancyType, LienPosition. ',
            'Return only valid JSON. XML: ', MISMO_XML_TEXT
        )
    )::VARIANT AS EXTRACTED_FIELDS
FROM LOAN_STAGING
WHERE LOAD_STATUS = 'PENDING_PARSE'
LIMIT 1000;
```

### Streaming with Claude

```python
import anthropic

client = anthropic.Anthropic()

def stream_pipeline_analysis(pipeline_description: str):
    """Stream a technical analysis of a pipeline design."""
    with client.messages.stream(
        model="claude-sonnet-4-5",
        max_tokens=2000,
        system="You are a data engineering architect. Provide technical analysis with specific recommendations.",
        messages=[{
            "role": "user",
            "content": f"Analyze this pipeline design and identify risks:\n{pipeline_description}"
        }]
    ) as stream:
        for text in stream.text_stream:
            print(text, end="", flush=True)

    # Final message available after stream ends
    final_message = stream.get_final_message()
    print(f"\n\nTotal tokens: {final_message.usage.input_tokens + final_message.usage.output_tokens}")
```

---

## Interview Q&A

**Q1: What is Claude's most significant technical differentiator for mortgage document processing, and how would you operationalize it?**

Claude's 200K token context window is the defining capability for mortgage document work. A full Fannie Mae or Freddie Mac MBS prospectus supplement, loan-level disclosure file, or servicing agreement typically runs 150-400 pages. With a 200K context, you can pass an entire document as a single API call and ask structured questions about cross-referenced sections — something impossible with models limited to 4K or 32K tokens that require complex chunking and multi-call reconciliation. Operationally, you build a pipeline that: converts PDFs to text via `pdfplumber`, checks token count with the Anthropic tokenizer, passes documents under 180K tokens as single calls, and applies a hierarchical summarization approach for the rare documents exceeding that threshold. Key outputs — extracted CUSIP, trust assets, enhancement triggers, servicer terms — are parsed as JSON via Claude's structured output mode and written to a `DOCUMENT_EXTRACTIONS` table. This replaces fragile regex-based document parsing that breaks on format changes.

**Q2: Compare Claude Opus, Sonnet, and Haiku. Which would you choose for each of three different mortgage data pipeline tasks?**

Haiku for high-volume, simple classification — for example, classifying 500,000 loan modification letters into 8 disposition categories, or tagging MISMO XML records with property type codes. It is 15-20x cheaper than Sonnet with acceptable accuracy for well-defined classification schemas. Sonnet for the production workhorses — generating SQL from business analyst questions, creating dbt model code, writing ETL transformation logic, generating monthly pool commentary from structured metrics. It hits the best capability-to-cost ratio for tasks requiring genuine reasoning. Opus for the hardest document reasoning tasks — analyzing complex cross-collateralization provisions in a CDO indenture, reconciling contradictory terms across a 300-page PSA, or generating a comprehensive data lineage narrative across 40 pipeline steps. You pay ~5x Sonnet's price but get materially better multi-step reasoning and fewer hallucinations on ambiguous legal and financial text.

**Q3: How does prompt caching work in the Claude API and what is the practical cost benefit for your use case?**

Prompt caching allows you to mark a portion of your input (typically via `cache_control: {type: "ephemeral"}`) as cacheable. On the first call, Anthropic processes and caches that block for up to 5 minutes (ephemeral) or up to 1 hour in some configurations. Subsequent calls that send the identical cached block skip re-processing and are charged at approximately 10% of the normal input token price (cache read vs. full input). For a mortgage data platform, the practical pattern is: your system prompt includes a full data dictionary (50K tokens) and the relevant MISMO field reference (30K tokens) — static content that never changes per call. Without caching, every SQL generation call pays for 80K tokens of static context. With caching, the first call in a session pays full price; subsequent calls in that window pay 10% for those 80K tokens. For a pipeline processing 1,000 analyst queries per day, this yields roughly 70-80% cost reduction on the static context portion of each call.

**Q4: How would you use Claude to parse complex securitization documents (PSA, prospectus) to populate a structured database?**

The workflow: (1) Convert source documents (PDF or EDGAR SGML filings) to plain text; (2) Design a JSON schema representing the fields your database needs — pool characteristics, enhancement levels, trigger thresholds, servicer obligations, remittance dates, waterfall priorities; (3) Build a system prompt that defines each field, its expected format, and how to handle missing data; (4) Call Claude Opus with the full document text and request structured JSON output; (5) Parse and validate the JSON with Pydantic, routing low-confidence or structurally invalid extractions to a human review queue; (6) Upsert validated records to your `SECURITIZATION_TERMS` table with a `SOURCE_DOC`, `EXTRACTION_TS`, and `CONFIDENCE_SCORE` column; (7) Run reconciliation checks — for instance, verify that extracted original balance matches the balance reported in monthly remittance reports. Over time, you build a labeled dataset of correct extractions that you use to evaluate prompt changes and catch regressions when Claude model versions update.

**Q5: Explain Claude's tool use mechanism and describe an agentic pipeline you would build for automated data quality investigation.**

Claude's tool use works via a request-response loop: you declare tool schemas, Claude emits `tool_use` blocks when it wants to invoke them, your code executes the tools, and you feed results back as `tool_result` blocks in the next `user` message. The loop continues until Claude emits a final text response. For automated DQ investigation: define tools including `run_sql_query`, `flag_dq_issue`, `get_table_profile`, and `send_alert`. The agent receives a trigger — "table LOAN_MASTER failed yesterday's null check on FICO_ORIG for 3,200 records." It calls `get_table_profile` to understand distribution context, calls `run_sql_query` to characterize which loans are affected (by origination date range, servicer, property type), calls `run_sql_query` again to check if upstream staging tables have the same nulls, and ultimately calls `flag_dq_issue` with severity and root cause, plus `send_alert` if severity is HIGH. The human sees a complete investigation narrative, not just a raw row count from the check that fired.

**Q6: What are the compliance advantages of running Claude via Amazon Bedrock vs. the direct Anthropic API for mortgage data?**

Bedrock's compliance advantages: (1) Data does not leave your AWS account — inference requests stay within the AWS network boundary; (2) Anthropic does not use Bedrock-accessed model calls to train future models (confirmed in AWS BAA terms); (3) You authenticate with IAM roles rather than API keys, enabling fine-grained access control and full CloudTrail audit logging of every model invocation; (4) Bedrock is covered under AWS's existing compliance certifications: SOC 1/2/3, PCI-DSS, HIPAA, FedRAMP Moderate — critical for GLBA and state privacy law compliance; (5) You can deploy inference within a specific AWS region (e.g., us-east-1) for data residency requirements; (6) VPC endpoints allow inference calls that never traverse the public internet. For a mortgage servicer processing NPI, Bedrock provides a compliance posture that is easier to document in your model risk management framework and vendor risk assessments than the direct Anthropic API.

**Q7: How does Claude's approach to code generation compare to GPT-4o, and when would you choose Claude for SQL or Python generation?**

Claude tends to produce more defensive, well-commented code with stronger error handling and more consistent adherence to coding conventions specified in the system prompt. For SQL in particular, Claude is less likely to introduce syntax that works in one dialect but not another, and it handles complex CTEs and window function logic with fewer structural errors. GPT-4o is faster and often more concise. In practice: prefer Claude Sonnet for complex multi-step SQL (multi-level window functions, recursive CTEs, complex JOIN chains with non-obvious business logic) and for generating production Python code (ETL functions, pipeline modules) where code review friction matters. GPT-4o-mini is preferable for high-volume, simple template-filling tasks where speed and cost dominate. For teams that have standardized on AWS, Claude via Bedrock eliminates a separate vendor relationship with Anthropic.

**Q8: How would you implement cost optimization for a high-volume Claude integration processing 100,000 loan records daily?**

Cost optimization stack: (1) Model tiering — route classification and simple extraction to Haiku (~$0.80/M tokens), moderate reasoning to Sonnet (~$3/M), heavy document analysis to Opus (~$15/M); build a request router that selects the model based on task type and record complexity; (2) Prompt caching — cache your full schema DDL and business rules dictionary across all calls in a session window; (3) Message Batches API — submit all non-real-time processing as batch jobs (50% cost reduction not available for Claude currently, but batch scheduling reduces peak rate limit pressure); (4) Token budget management — set conservative `max_tokens` per task type; an LTV validation response should never need 2,000 tokens; (5) Output compression — for JSON extractions, define compact field names in your schema to reduce completion tokens; (6) Deduplication — cache responses for identical inputs (hash the prompt) to avoid re-processing identical records when pipelines rerun partial loads. Track per-pipeline cost daily in a `LLM_COST_LOG` table and alert on anomalies.

**Q9: How would you build a text-to-SQL assistant for mortgage analysts using Claude with appropriate enterprise safeguards?**

Architecture with Claude: (1) Use a rich system prompt containing the full warehouse schema DDL (cacheable), business glossary, and explicit rules: SELECT only, no DML/DDL, Snowflake dialect, use specific date functions; (2) Enable tool use with a single `execute_readonly_sql` tool — this structures Claude's SQL output as typed JSON rather than free text, making it parseable without regex; (3) Before execution, pass the tool-extracted SQL through `sqlglot.parse()` to confirm it is syntactically valid and contains no disallowed statement types; (4) Execute under a dedicated read-only Snowflake role with row-level security applied to any PII columns; (5) Log all interactions — user ID, natural language question, generated SQL, execution time, row count, and model version — to an `ANALYST_QUERY_LOG` table; (6) Implement a human-in-the-loop review for queries touching PII tables; (7) Run monthly accuracy reviews against a golden question set to detect prompt regression when model versions change.

**Q10: What is Claude's Computer Use capability and could it have legitimate data engineering applications?**

Computer Use (available in Claude 3.5 Sonnet) allows Claude to observe a desktop screenshot, reason about the UI state, and emit actions (mouse click, keyboard input, screenshot request) to operate GUI applications. In data engineering, legitimate use cases are narrow but real: (1) automating interactions with legacy data vendor portals that have no API — for example, downloading monthly MBS factor files from an agency website that requires multi-step web navigation; (2) operating legacy Windows-based ETL tools (SSIS, Informatica designer) for documentation or migration analysis; (3) UI testing of internal data quality dashboards. The significant cautions: Computer Use requires a controlled sandbox environment (not your production machine); every action should be logged and reviewed; never run it against systems containing live PII; it is not suitable for production automation of critical workflows. Treat it as an automation assistant for low-frequency, human-supervised tasks, not an autonomous production agent.

---

## Pro Tips

- **Default to Sonnet.** Unless you have a proven need for Opus's additional reasoning depth or Haiku's cost floor, Sonnet is the right starting point for 80% of data engineering tasks.
- **Cache your schema.** If your system prompt includes DDL, mark it with `cache_control`. On a pipeline running 500 calls per hour, the savings are immediate and substantial.
- **Use Bedrock for any pipeline touching NPI.** The compliance documentation writes itself — IAM roles, CloudTrail, regional data residency, no training data use. Direct API is fine for non-PII metadata and development.
- **Snowflake Cortex is the zero-egress path.** If your data is already in Snowflake and you want LLM-enhanced SQL without external API calls, Cortex with Claude is the cleanest option for governed environments.
- **Pin model versions.** Use `claude-sonnet-4-5-20251001` not `claude-sonnet-4-5`. Model behavior can shift between version releases. Run regression tests before migrating to a new version.
- **Multi-turn for iterative SQL refinement.** Claude handles multi-turn SQL refinement better than most models — let analysts ask follow-up questions and Claude will correctly amend the prior query rather than rewriting from scratch.
- **Validate JSON outputs with Pydantic.** Claude almost always produces valid JSON when asked, but "almost" is not acceptable in pipelines. A Pydantic model parse step catches edge cases and gives clear error messages for downstream debugging.
- **Log token usage per pipeline step.** Cost and performance monitoring at the pipeline-step level, not just the aggregate account level, is what lets you identify optimization opportunities.

---

*Last updated: 2026-03-07 | Target: Senior Data Engineer, SQL Server / Snowflake, US Secondary Mortgage Market*
