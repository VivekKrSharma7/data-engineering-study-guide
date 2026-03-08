# LangChain & LlamaIndex for Data Engineers
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

LangChain and LlamaIndex are the two dominant Python frameworks for building LLM-powered applications. For a senior data engineer, these frameworks serve as the connective tissue between your data infrastructure — Snowflake, SQL Server, S3, Delta Lake — and large language models. Understanding when and how to use each is essential for designing systems like natural language query interfaces over loan databases, automated MBS report generation, and intelligent data pipelines.

**LangChain** excels at orchestration: chaining LLM calls, managing agents that use tools, and building multi-step reasoning workflows.

**LlamaIndex** excels at data ingestion and retrieval-augmented generation (RAG): loading, indexing, and querying your own data sources with LLMs.

---

## Key Concepts at a Glance

| Concept | LangChain | LlamaIndex |
|---|---|---|
| Primary strength | Orchestration, agents, chains | Data ingestion, RAG, indexing |
| Core abstraction | Chain / Agent | Index / Query Engine |
| SQL integration | SQLDatabaseChain, SQL Agent | SQLDatabase connector |
| Snowflake support | Via SQLAlchemy | Native Snowflake connector |
| Tracing/observability | LangSmith | LlamaTrace / Arize Phoenix |
| Best for | Multi-step workflows, tool use | Document Q&A, structured retrieval |

---

## LangChain Deep Dive

### Core Abstractions

**LLMs and ChatModels**

LangChain wraps any LLM provider behind a common interface:

```python
from langchain_openai import ChatOpenAI, OpenAI
from langchain_anthropic import ChatAnthropic

# Chat model (preferred for most use cases)
llm = ChatOpenAI(model="gpt-4o", temperature=0)

# Direct completion model (legacy)
completion_llm = OpenAI(model="gpt-3.5-turbo-instruct", temperature=0)
```

**PromptTemplates**

```python
from langchain_core.prompts import ChatPromptTemplate, PromptTemplate

# Chat prompt with system + human messages
prompt = ChatPromptTemplate.from_messages([
    ("system", "You are a mortgage data analyst. Always return valid SQL for Snowflake."),
    ("human", "Generate a SQL query to answer: {question}\n\nTable schema:\n{schema}"),
])

# Single-string prompt template
sql_prompt = PromptTemplate.from_template(
    "Translate this question to SQL: {question}\nSchema: {schema}"
)
```

**OutputParsers**

```python
from langchain_core.output_parsers import StrOutputParser, JsonOutputParser
from langchain_core.pydantic_v1 import BaseModel, Field

class SQLQuery(BaseModel):
    sql: str = Field(description="The SQL query")
    explanation: str = Field(description="Plain English explanation")

parser = JsonOutputParser(pydantic_object=SQLQuery)
```

### LCEL — LangChain Expression Language

LCEL uses the pipe operator (`|`) to compose chains. It is lazy (builds a Runnable graph), supports streaming, batching, and async out of the box.

```python
from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser

llm = ChatOpenAI(model="gpt-4o", temperature=0)

# Simple chain: prompt | llm | parser
chain = (
    ChatPromptTemplate.from_messages([
        ("system", "You are a senior mortgage data analyst."),
        ("human", "{question}"),
    ])
    | llm
    | StrOutputParser()
)

response = chain.invoke({"question": "What is CPR and how is it calculated?"})

# Batch processing
responses = chain.batch([
    {"question": "Define WAC"},
    {"question": "Define WAM"},
    {"question": "Define WALA"},
])

# Streaming
for chunk in chain.stream({"question": "Explain prepayment risk"}):
    print(chunk, end="", flush=True)
```

**Branching with RunnableParallel**

```python
from langchain_core.runnables import RunnableParallel, RunnablePassthrough

# Run two chains in parallel
parallel_chain = RunnableParallel(
    sql_query=sql_chain,
    explanation=explanation_chain,
).assign(combined=lambda x: f"{x['sql_query']}\n-- {x['explanation']}")
```

### LangChain Agents

Agents let the LLM decide which tools to call and in what order. The LLM reasons about the goal, selects a tool, observes the result, and repeats until done.

**ReAct Agent (Reason + Act)**

```python
from langchain.agents import AgentExecutor, create_react_agent
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI

@tool
def get_pool_factor(cusip: str) -> str:
    """Retrieve the current pool factor for a given MBS CUSIP from Snowflake."""
    # In production: query Snowflake
    return f"Pool factor for {cusip}: 0.7823 (as of 2026-03-01)"

@tool
def get_prepayment_speed(cusip: str, period: str) -> str:
    """Get 1-month, 3-month, or 12-month CPR for an MBS pool."""
    return f"CPR for {cusip} ({period}): 14.2%"

tools = [get_pool_factor, get_prepayment_speed]
llm = ChatOpenAI(model="gpt-4o", temperature=0)

agent = create_react_agent(llm, tools, prompt=react_prompt)
agent_executor = AgentExecutor(agent=agent, tools=tools, verbose=True)

result = agent_executor.invoke({
    "input": "What is the pool factor and 3-month CPR for CUSIP 31371NUC7?"
})
```

**OpenAI Function/Tool Calling Agent (preferred for GPT-4)**

```python
from langchain.agents import create_tool_calling_agent

agent = create_tool_calling_agent(llm, tools, prompt)
executor = AgentExecutor(agent=agent, tools=tools, verbose=True, max_iterations=5)
```

### LangChain with SQL Databases

**SQLDatabaseChain (simple, single-step)**

```python
from langchain_community.utilities import SQLDatabase
from langchain_experimental.sql import SQLDatabaseChain
from langchain_openai import ChatOpenAI

# Connect to Snowflake via SQLAlchemy
connection_string = (
    "snowflake://{user}:{password}@{account}/{database}/{schema}"
    "?warehouse={warehouse}&role={role}"
).format(**snowflake_creds)

db = SQLDatabase.from_uri(connection_string, include_tables=["LOAN_MASTER", "POOL_HISTORY"])
llm = ChatOpenAI(model="gpt-4o", temperature=0)

chain = SQLDatabaseChain.from_llm(llm, db, verbose=True, return_intermediate_steps=True)
result = chain.invoke("What is the average LTV for loans originated in 2024 Q1?")
```

**SQL Agent (multi-step, can inspect schema, handle errors)**

```python
from langchain_community.agent_toolkits import create_sql_agent
from langchain_community.agent_toolkits.sql.toolkit import SQLDatabaseToolkit

toolkit = SQLDatabaseToolkit(db=db, llm=llm)

agent_executor = create_sql_agent(
    llm=llm,
    toolkit=toolkit,
    verbose=True,
    agent_type="openai-tools",
    max_iterations=10,
    handle_parsing_errors=True,
)

result = agent_executor.invoke({
    "input": "Find the top 10 servicers by delinquency rate for loans with FICO < 680"
})
```

### Memory and Conversation History

```python
from langchain_community.chat_message_histories import ChatMessageHistory
from langchain_core.runnables.history import RunnableWithMessageHistory

store = {}

def get_session_history(session_id: str) -> ChatMessageHistory:
    if session_id not in store:
        store[session_id] = ChatMessageHistory()
    return store[session_id]

chain_with_history = RunnableWithMessageHistory(
    chain,
    get_session_history,
    input_messages_key="question",
    history_messages_key="history",
)

# Each call maintains context within the session
chain_with_history.invoke(
    {"question": "Show me delinquent loans in California"},
    config={"configurable": {"session_id": "analyst-session-1"}}
)
chain_with_history.invoke(
    {"question": "Now filter those to only loans originated after 2022"},
    config={"configurable": {"session_id": "analyst-session-1"}}
)
```

---

## LlamaIndex Deep Dive

### Architecture Overview

LlamaIndex organizes data pipelines into three stages:

1. **Load** — Data connectors (SimpleDirectoryReader, DatabaseReader, SnowflakeReader)
2. **Index** — Transform and store (VectorStoreIndex, KnowledgeGraphIndex, SQLStructStoreIndex)
3. **Query** — Query engines and retrievers return context to the LLM

### Data Connectors

```python
from llama_index.core import SimpleDirectoryReader, Document
from llama_index.readers.database import DatabaseReader
from llama_index.readers.snowflake import SnowflakeReader

# Load PDFs from a directory (e.g., prospectus documents)
documents = SimpleDirectoryReader("./mbs_prospectus/").load_data()

# Load from a SQL database
db_reader = DatabaseReader(
    uri="snowflake://user:pass@account/DB/SCHEMA"
)
docs_from_sql = db_reader.load_data(
    query="SELECT loan_id, notes FROM LOAN_MASTER WHERE status = 'DELINQUENT'"
)

# Snowflake-specific reader
sf_reader = SnowflakeReader(
    account="myaccount",
    user="myuser",
    password="mypassword",
    database="MORTGAGE_DW",
    schema="ANALYTICS",
    warehouse="COMPUTE_WH",
)
pool_docs = sf_reader.load_data(
    query="SELECT * FROM POOL_CHARACTERISTICS WHERE REPORT_DATE = CURRENT_DATE"
)
```

### Building a RAG System with VectorStoreIndex

```python
from llama_index.core import VectorStoreIndex, Settings
from llama_index.llms.openai import OpenAI
from llama_index.embeddings.openai import OpenAIEmbedding
from llama_index.vector_stores.chroma import ChromaVectorStore
import chromadb

# Configure global settings
Settings.llm = OpenAI(model="gpt-4o", temperature=0)
Settings.embed_model = OpenAIEmbedding(model="text-embedding-3-large")
Settings.chunk_size = 512
Settings.chunk_overlap = 64

# Persistent vector store
chroma_client = chromadb.PersistentClient(path="./chroma_db")
collection = chroma_client.get_or_create_collection("mbs_docs")
vector_store = ChromaVectorStore(chroma_collection=collection)

# Build or load index
from llama_index.core import StorageContext
storage_context = StorageContext.from_defaults(vector_store=vector_store)

index = VectorStoreIndex.from_documents(
    documents,
    storage_context=storage_context,
    show_progress=True,
)

# Query
query_engine = index.as_query_engine(similarity_top_k=5)
response = query_engine.query(
    "What are the prepayment assumptions used in this pool prospectus?"
)
print(response.response)
for node in response.source_nodes:
    print(f"  Source: {node.metadata.get('file_name')} (score: {node.score:.3f})")
```

### LlamaIndex with Snowflake — NL-to-SQL

```python
from llama_index.core import SQLDatabase
from llama_index.core.query_engine import NLSQLTableQueryEngine
from sqlalchemy import create_engine

engine = create_engine(
    "snowflake://user:pass@account/MORTGAGE_DW/ANALYTICS"
    "?warehouse=COMPUTE_WH"
)

sql_database = SQLDatabase(
    engine,
    include_tables=["LOAN_MASTER", "POOL_SUMMARY", "DELINQUENCY_HISTORY"],
)

query_engine = NLSQLTableQueryEngine(
    sql_database=sql_database,
    tables=["LOAN_MASTER", "POOL_SUMMARY"],
    llm=Settings.llm,
    verbose=True,
)

response = query_engine.query(
    "What is the weighted average coupon for 30-year fixed loans in the Southeast?"
)
print(f"SQL: {response.metadata['sql_query']}")
print(f"Answer: {response.response}")
```

---

## Complete Production RAG System: LangChain + Snowflake

```python
"""
Production-grade RAG system for querying mortgage guidelines
and Snowflake loan data simultaneously.
"""

import os
from typing import List
from langchain_openai import ChatOpenAI, OpenAIEmbeddings
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnablePassthrough, RunnableParallel
from langchain_community.vectorstores import Chroma
from langchain_community.utilities import SQLDatabase
from langchain_core.documents import Document


# ── Configuration ────────────────────────────────────────────────────────────
SNOWFLAKE_URI = (
    "snowflake://{user}:{password}@{account}/MORTGAGE_DW/ANALYTICS"
    "?warehouse=COMPUTE_WH&role=DATA_ANALYST"
).format(**{k: os.environ[k] for k in ["user","password","account"]})

llm = ChatOpenAI(model="gpt-4o", temperature=0)
embeddings = OpenAIEmbeddings(model="text-embedding-3-large")


# ── Vector store for guideline documents ─────────────────────────────────────
def build_guideline_retriever(persist_dir: str = "./chroma_guidelines"):
    vectorstore = Chroma(
        persist_directory=persist_dir,
        embedding_function=embeddings,
        collection_name="mortgage_guidelines",
    )
    return vectorstore.as_retriever(
        search_type="mmr",           # Maximum Marginal Relevance
        search_kwargs={"k": 4, "fetch_k": 20},
    )


# ── SQL tool ──────────────────────────────────────────────────────────────────
def get_sql_context(question: str) -> str:
    """Generate and execute SQL against Snowflake for factual loan data."""
    db = SQLDatabase.from_uri(SNOWFLAKE_URI, include_tables=[
        "LOAN_MASTER", "POOL_SUMMARY", "DELINQUENCY_HISTORY"
    ])
    schema = db.get_table_info()

    sql_gen_chain = (
        ChatPromptTemplate.from_messages([
            ("system", (
                "You are a Snowflake SQL expert for a secondary mortgage market database. "
                "Write a single SELECT query only. No explanation. No markdown."
            )),
            ("human", "Schema:\n{schema}\n\nQuestion: {question}"),
        ])
        | llm
        | StrOutputParser()
    )
    sql = sql_gen_chain.invoke({"schema": schema, "question": question})
    try:
        result = db.run(sql)
        return f"SQL: {sql}\nResult: {result}"
    except Exception as e:
        return f"SQL generation failed: {e}"


# ── Hybrid RAG chain ──────────────────────────────────────────────────────────
def build_hybrid_chain(retriever):
    def format_docs(docs: List[Document]) -> str:
        return "\n\n---\n\n".join(d.page_content for d in docs)

    rag_prompt = ChatPromptTemplate.from_messages([
        ("system", (
            "You are a senior mortgage data analyst at a secondary market firm. "
            "Answer questions using the provided guideline context and SQL data. "
            "Be precise; cite sources when available."
        )),
        ("human", (
            "Guideline Context:\n{guideline_context}\n\n"
            "Live Data from Snowflake:\n{sql_context}\n\n"
            "Question: {question}"
        )),
    ])

    chain = (
        RunnableParallel(
            guideline_context=(lambda x: x["question"]) | retriever | format_docs,
            sql_context=(lambda x: x["question"]) | get_sql_context,
            question=RunnablePassthrough() | (lambda x: x["question"]),
        )
        | rag_prompt
        | llm
        | StrOutputParser()
    )
    return chain


# ── Main ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    retriever = build_guideline_retriever()
    chain = build_hybrid_chain(retriever)

    questions = [
        "What is the max LTV for a cash-out refi on a 2-unit property?",
        "How many loans in our portfolio exceed the guideline LTV limit?",
    ]
    for q in questions:
        print(f"\nQ: {q}")
        print(f"A: {chain.invoke({'question': q})}")
```

---

## LangSmith — Tracing and Debugging

```python
import os
os.environ["LANGCHAIN_TRACING_V2"] = "true"
os.environ["LANGCHAIN_API_KEY"] = "ls__your_key_here"
os.environ["LANGCHAIN_PROJECT"] = "mortgage-nl-query"

# All chain/agent calls are now automatically traced
# View traces at: https://smith.langchain.com
```

Key LangSmith capabilities for production:
- Full trace of every LLM call: input tokens, output tokens, latency, cost
- Dataset creation from production traces for regression testing
- Evaluation runs: compare prompt versions against ground-truth SQL queries
- Alerting on error rates and latency spikes

---

## LangChain vs LlamaIndex: Decision Matrix

| Use Case | Recommendation |
|---|---|
| NL query over a single SQL database | LangChain SQL Agent |
| RAG over PDF/Word loan documents | LlamaIndex VectorStoreIndex |
| Multi-step agent using 5+ tools | LangChain agents |
| Hybrid: documents + structured data | LlamaIndex RouterQueryEngine or LangChain |
| Complex retrieval with re-ranking | LlamaIndex (more retrieval primitives) |
| Production monitoring | LangSmith (LangChain) |
| Snowflake data + guideline docs | LlamaIndex with SQLDatabase + VectorIndex |

---

## Interview Q&A

**Q1: What is the difference between LangChain and LlamaIndex, and when would you choose one over the other?**

LangChain is primarily an orchestration framework — it excels at building agents, chaining multiple LLM calls, and integrating a wide variety of tools (SQL, web search, APIs). LlamaIndex is primarily a data framework focused on ingesting, indexing, and retrieving unstructured and structured data for RAG pipelines. In practice, for a secondary mortgage market system, I'd use LangChain when building a multi-step agent that can query Snowflake, call an external pricing API, and generate a formatted report. I'd use LlamaIndex when building a system that needs to intelligently search across thousands of guideline PDFs, pool prospectuses, and structured loan data using semantic retrieval.

**Q2: Explain LCEL and why Anthropic and OpenAI engineering teams recommend it over the older chain classes.**

LCEL (LangChain Expression Language) uses Python's `|` operator to compose Runnable objects into a directed acyclic graph. The key advantages are: (1) built-in streaming at every step with no extra code, (2) automatic async support via `.ainvoke()` and `.astream()`, (3) parallelism via `RunnableParallel`, (4) first-class LangSmith tracing, and (5) the same interface works whether you're running a single chain or a complex branching workflow. The older `LLMChain`, `SequentialChain` classes are harder to stream and debug. LCEL chains are also serializable to JSON for deployment.

**Q3: How does a LangChain SQL Agent differ from SQLDatabaseChain?**

`SQLDatabaseChain` is a single-pass approach: it takes the question, generates SQL, executes it, and returns the answer. It fails gracefully on schema complexity. The SQL Agent uses a tool-calling loop — it can first call a schema-inspection tool, see which tables exist, call a sample-rows tool to understand the data, generate SQL, handle errors by re-trying with corrections, and only then return an answer. For a complex mortgage database with 50+ tables, the SQL Agent is far more robust because it can discover the right tables rather than requiring the full schema in the prompt.

**Q4: What is the "lost in the middle" problem in RAG, and how do LlamaIndex retrieval strategies address it?**

Research shows LLMs perform worst on information that appears in the middle of a long context window. When a retriever returns 10 chunks, the LLM tends to use the first and last chunks but misses the middle ones. LlamaIndex addresses this with: (1) **MMR (Maximum Marginal Relevance)** retrieval to reduce redundancy and increase diversity, (2) **reranking** with a cross-encoder (e.g., `CohereRerank`) that rescores retrieved chunks by relevance before passing to the LLM, (3) **sentence window retrieval** that retrieves individual sentences but sends surrounding context, and (4) **auto-merging retrieval** that fetches small chunks but merges adjacent chunks when many come from the same parent node.

**Q5: How would you build a natural language query interface over your Snowflake loan database for non-technical analysts?**

I'd use a LangChain SQL Agent with several hardening steps: (1) limit the agent to a curated set of read-only views rather than raw tables to prevent accidental data exposure, (2) inject few-shot examples of known-good question/SQL pairs into the system prompt to improve accuracy on domain-specific terminology like "CPR", "WALA", "servicer advance", (3) add a query validator that checks generated SQL for dangerous patterns (UPDATE, DROP, full table scans without WHERE), (4) implement a result cache using Redis to avoid re-running expensive Snowflake queries for repeated questions, (5) surface the generated SQL to the analyst so they can verify it, and (6) log all traces to LangSmith for monitoring and continuous improvement.

**Q6: What are callbacks in LangChain and how would you use them in production?**

Callbacks are event handlers that fire at each step of a chain or agent execution. LangChain provides callbacks for `on_llm_start`, `on_llm_end`, `on_chain_start`, `on_chain_end`, `on_tool_start`, `on_tool_end`, and `on_agent_action`. In production, I'd use custom callbacks to: (1) push latency and token-count metrics to Datadog or CloudWatch, (2) log every SQL query generated to an audit table in Snowflake (important for regulated mortgage data), (3) implement circuit-breaker logic that halts execution if the LLM generates more than 3 failed SQL queries in a row, and (4) send Slack alerts when the agent takes more than 10 iterations, which often indicates an infinite loop.

**Q7: How do you handle data freshness and point-in-time correctness in a LlamaIndex RAG system over mortgage data?**

Point-in-time correctness is critical in secondary market data — a guideline document from 2023 may have been superseded. My approach: (1) embed document metadata (effective date, superseded date, version) into each chunk and store it in the vector store, (2) use metadata filters at query time to restrict retrieval to documents effective on or before the query date, (3) implement a document refresh pipeline that re-indexes PDFs nightly when new guideline versions are published, (4) use LlamaIndex's `VectorStoreIndex` with Pinecone or Weaviate which support metadata filtering natively, and (5) add a recency boost to the reranker so newer documents score higher for time-sensitive queries like current LTV limits.

**Q8: What are the cost and latency trade-offs between GPT-4o, GPT-4o-mini, and Claude for a high-volume SQL generation system?**

For a system generating hundreds of SQL queries per day over a mortgage database: GPT-4o gives the best accuracy on complex joins and window functions but costs ~$5/M input tokens and has ~1-2s latency. GPT-4o-mini costs ~$0.15/M input tokens and is fast (~300ms) but struggles with complex multi-table queries. My production approach is a tiered strategy: route simple, single-table questions to GPT-4o-mini, and complex analytical questions (multiple CTEs, window functions over large datasets) to GPT-4o. I'd implement this in LCEL using a `RunnableBranch` that classifies query complexity first. Claude Haiku/Sonnet are comparable alternatives for the cost-tier routing.

**Q9: How would you prevent SQL injection when using a LangChain SQL Agent against production Snowflake data?**

Multiple layers of defense: (1) connect as a read-only service account with SELECT grants only on approved views — no DDL, DML, or schema access, (2) parse the LLM-generated SQL with `sqlparse` before execution to reject any statement that is not a SELECT, (3) add a query timeout (Snowflake `STATEMENT_TIMEOUT_IN_SECONDS`) to prevent expensive runaway queries, (4) whitelist the tables/views the agent can access using LangChain's `include_tables` parameter on `SQLDatabase`, (5) never pass user credentials in the SQL context — use Snowflake OAuth tokens that expire, and (6) log every generated SQL statement with the user identity to a Snowflake audit table for SOX compliance.

**Q10: Describe how you would evaluate whether a LangChain SQL agent is production-ready for mortgage analysts.**

I'd build an evaluation dataset of 100 question/correct-SQL pairs covering the breadth of analyst questions: simple aggregations, time-series trends, multi-table joins, and edge cases like "as of" date filters. Then I'd measure: (1) **execution success rate** — does the SQL run without errors? Target >95%, (2) **answer correctness** — does the query return the right data? Verified by running both LLM-generated and hand-written SQL and comparing results, (3) **latency P50/P95** — acceptable for analyst workflow (<5s P95), (4) **token cost per query** — must fit within budget, (5) **hallucination rate** — queries that return data but answer the wrong question. I'd use LangSmith's evaluation framework to run this test suite on every prompt change before deploying to production.

---

## Pro Tips

- Always use `include_tables` when constructing `SQLDatabase` — never expose the full schema to the LLM. It reduces prompt size, cost, and the risk of the agent joining to sensitive tables.
- Set `max_iterations` on `AgentExecutor`. Without it, a confused agent will loop until you hit the API rate limit or run up a large bill.
- For Snowflake, use warehouse auto-suspend and set a query timeout. An LLM-generated full-table scan on a 500M row loan table will run for minutes and cost real money.
- LlamaIndex's `SentenceWindowNodeParser` consistently outperforms naive fixed-size chunking for guideline documents. Use chunk size 128 tokens with a window size of 3 sentences.
- Store embeddings in a vector store that supports metadata filtering (Pinecone, Weaviate, Qdrant) rather than Chroma in production. Metadata filtering lets you enforce point-in-time correctness without re-ranking.
- LangSmith is free for low-volume usage. Turn it on from day one — retroactively debugging a production RAG system without traces is extremely painful.
- When building a SQL agent for non-technical users, include 5-10 few-shot examples of your most common domain-specific queries (CPR, delinquency, roll rates) directly in the system prompt. This alone can improve accuracy by 20-30%.
