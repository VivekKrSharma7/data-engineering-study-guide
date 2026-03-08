# AI Agents & Agentic Workflows
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

AI agents are autonomous systems powered by large language models (LLMs) that go beyond single-turn question-answering. They perceive their environment, reason about what actions to take, execute those actions via tools, observe results, and iterate until a goal is achieved. For senior data engineers, agents represent a paradigm shift: instead of writing every ETL step manually, you can delegate exploratory or repetitive work to an agent that knows your schema and your business rules.

In the US secondary mortgage market, agentic workflows unlock use cases like automated loan tape validation, dynamic SQL generation against Snowflake, proactive data quality alerting, and self-healing pipeline remediation — all with minimal human intervention.

---

## Key Concepts

| Concept | One-Line Definition |
|---|---|
| LLM Brain | The reasoning engine (GPT-4, Claude 3.5, etc.) that decides what to do next |
| Tools | Functions the agent can call: run SQL, call an API, read a file |
| Memory | What the agent remembers: in-context (short), vector store (long), episodic |
| Planning | Strategy for breaking a goal into steps |
| ReAct Pattern | Reasoning + Acting loop: Thought → Action → Observation → repeat |
| Agent Executor | Framework component that runs the ReAct loop |
| Human-in-the-Loop | Checkpoints where a human must approve before the agent proceeds |
| Hallucination Risk | Agent confidently generating wrong SQL, schema names, or business logic |

---

## Detailed Explanations

### What Is an AI Agent?

A standard LLM call is stateless: you send a prompt, get a response, done. An agent wraps the LLM in a loop:

```
Goal → [LLM reasons] → [Chooses tool] → [Tool executes] → [Observes result] → [LLM reasons again] → ... → Final Answer
```

The agent stops when it decides the goal is achieved or a max-iteration limit is hit.

### Agent Components

**1. LLM Brain**
The LLM is the decision-maker. It reads the current state (goal + history + tool results) and outputs either a tool call or a final answer. GPT-4o and Claude 3.5 Sonnet are the dominant choices for production agents due to their strong instruction-following and tool-calling capabilities.

**2. Tools (Function Calling)**
Tools are Python functions exposed to the LLM via a schema. The LLM does not execute code — it outputs a structured JSON describing which tool to call and with what arguments. The framework then executes the function and feeds the result back.

```python
from langchain.tools import tool

@tool
def run_snowflake_query(sql: str) -> str:
    """Execute a SQL query against Snowflake and return results as CSV string.
    Use this to answer questions about loan data."""
    import snowflake.connector
    conn = snowflake.connector.connect(
        user="svc_agent",
        account="myorg-myaccount",
        warehouse="COMPUTE_WH",
        database="MORTGAGE_DB",
        schema="LOAN_ORIGINATIONS"
    )
    cur = conn.cursor()
    cur.execute(sql)
    rows = cur.fetchall()
    cols = [d[0] for d in cur.description]
    conn.close()
    lines = [",".join(cols)] + [",".join(str(v) for v in row) for row in rows]
    return "\n".join(lines[:50])  # cap rows to avoid token overflow
```

**3. Memory**

- **Short-term (context window):** Everything in the current conversation. Limited to the model's context window (128K–200K tokens for modern models).
- **Long-term (vector store):** Previous conversations, documentation, schema info stored in a vector DB (Pinecone, pgvector, Snowflake Cortex Search). Retrieved via semantic similarity at query time.
- **Episodic memory:** A structured log of past agent runs — what the agent tried, what worked, what failed. Useful for avoiding repeated mistakes.

**4. Planning Strategies**

| Strategy | Description | Best For |
|---|---|---|
| Sequential | Steps executed one after another | Linear ETL pipelines |
| Tree of Thought | Explore multiple reasoning paths, pick best | Complex debugging |
| Step-Back Prompting | First answer an abstract question, then apply | Data modeling decisions |
| Plan-and-Execute | Upfront plan generated, then executed | Long multi-step workflows |

### ReAct Pattern (Reasoning + Acting)

ReAct is the foundational agent loop. The LLM alternates between Thought (internal reasoning) and Action (tool call), then receives an Observation (tool output).

```
Thought: I need to find loans with missing property zip codes in Q4 2024.
Action: run_snowflake_query
Action Input: SELECT COUNT(*) FROM LOAN_ORIGINATIONS WHERE PROPERTY_ZIP IS NULL AND ORIGINATION_DATE >= '2024-10-01'
Observation: 1,847

Thought: 1,847 loans have missing zip codes. I should check if this is worse than prior quarters.
Action: run_snowflake_query
Action Input: SELECT DATE_TRUNC('quarter', ORIGINATION_DATE) AS qtr, COUNT(*) AS missing_zips FROM LOAN_ORIGINATIONS WHERE PROPERTY_ZIP IS NULL GROUP BY 1 ORDER BY 1
Observation: 2024-07-01,312 / 2024-10-01,1847

Thought: Q4 is 5.9x worse than Q3. This is a data quality incident. I should return a summary.
Final Answer: Q4 2024 has 1,847 loans with missing PROPERTY_ZIP — a 491% increase over Q3 2024 (312). Recommend immediate upstream data feed investigation.
```

### LangChain Agents

LangChain provides high-level abstractions for building agents.

```python
from langchain_openai import ChatOpenAI
from langchain.agents import create_react_agent, AgentExecutor
from langchain import hub

llm = ChatOpenAI(model="gpt-4o", temperature=0)
tools = [run_snowflake_query, get_table_schema, check_dbt_model_status]

# Pull a standard ReAct prompt template from LangChain Hub
prompt = hub.pull("hwchase17/react")

agent = create_react_agent(llm, tools, prompt)
executor = AgentExecutor(
    agent=agent,
    tools=tools,
    verbose=True,
    max_iterations=10,
    handle_parsing_errors=True
)

result = executor.invoke({
    "input": "Find the top 5 servicers by unpaid principal balance for conventional loans closed in January 2025"
})
print(result["output"])
```

### OpenAI Assistants API

OpenAI's Assistants API is a managed agent runtime. You define tools (Code Interpreter, File Search, custom functions), and OpenAI handles the ReAct loop, thread management, and state persistence.

```python
from openai import OpenAI

client = OpenAI()

assistant = client.beta.assistants.create(
    name="Mortgage Data Analyst",
    instructions="You are a senior data analyst for a mortgage servicer. Answer questions using the SQL tool against our Snowflake warehouse.",
    tools=[{"type": "function", "function": snowflake_query_schema}],
    model="gpt-4o"
)

thread = client.beta.threads.create()
client.beta.threads.messages.create(
    thread_id=thread.id,
    role="user",
    content="What is the 90-day delinquency rate for FHA loans in Texas this month?"
)

run = client.beta.threads.runs.create_and_poll(
    thread_id=thread.id,
    assistant_id=assistant.id
)
```

### Claude Tool Use for Agentic Tasks

Anthropic's Claude supports native tool use with structured JSON schemas. Claude 3.5 Sonnet is particularly strong at following tool call schemas accurately.

```python
import anthropic

client = anthropic.Anthropic()

tools = [
    {
        "name": "run_sql",
        "description": "Execute SQL against Snowflake mortgage database",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Valid Snowflake SQL statement"}
            },
            "required": ["query"]
        }
    }
]

response = client.messages.create(
    model="claude-3-5-sonnet-20241022",
    max_tokens=4096,
    tools=tools,
    messages=[{"role": "user", "content": "How many loans are in forbearance by state?"}]
)
```

### Snowflake Cortex Analyst

Cortex Analyst is Snowflake's native AI agent for Text-to-SQL. You provide a semantic model (YAML describing tables, columns, relationships, and business metrics), and Cortex Analyst generates and executes SQL in response to natural language questions — no external API calls, no data leaving Snowflake.

```yaml
# semantic_model.yaml (simplified)
name: mortgage_analytics
tables:
  - name: LOAN_ORIGINATIONS
    description: One row per funded loan
    columns:
      - name: LOAN_ID
        description: Unique loan identifier (MERS MIN format)
      - name: UPB
        description: Unpaid principal balance at origination in USD
      - name: NOTE_RATE
        description: Interest rate on the promissory note
      - name: LTV_RATIO
        description: Loan-to-value ratio at origination
metrics:
  - name: avg_note_rate
    description: Average note rate weighted by UPB
    expr: SUM(NOTE_RATE * UPB) / SUM(UPB)
```

### Data Engineering Agents in Practice

**SQL Writing Agent:** Given a business question and a schema, generates, executes, and explains SQL. Useful for ad-hoc analysis without requiring the analyst to know Snowflake syntax.

**Pipeline Debugging Agent:** Reads dbt test failure logs, identifies the failing model, inspects source data, hypothesizes root cause, and proposes a fix.

**dbt Model Generation Agent:** Given a description of a new data mart requirement, generates a dbt model file, schema YAML, and test definitions.

**Data Quality Monitoring Agent:** Runs on a schedule, compares current metrics to historical baselines, flags anomalies, and creates JIRA tickets automatically.

### Human-in-the-Loop Patterns

Not all agent actions should be autonomous. For high-stakes data operations (dropping tables, modifying production records, deploying pipeline changes), require human approval:

```python
from langchain.tools import tool

@tool
def deploy_dbt_model_to_production(model_name: str) -> str:
    """Deploy a dbt model change to production. REQUIRES HUMAN APPROVAL."""
    # In practice, this would post to Slack/email and await approval
    approval = request_human_approval(
        action=f"Deploy dbt model: {model_name}",
        context="Agent-generated model change",
        approvers=["data-eng-lead@company.com"]
    )
    if approval.granted:
        return trigger_dbt_cloud_job(model_name)
    return "Deployment rejected by human reviewer."
```

### Agent Reliability and Hallucination Risks

Agents inherit all LLM failure modes, compounded by the multi-step loop:

| Risk | Mitigation |
|---|---|
| Wrong SQL (hallucinated column names) | Always provide schema context; validate SQL before execution |
| Infinite loops | Set max_iterations (10–15 is typical) |
| Cascading errors | Each tool call should return structured error messages, not raw exceptions |
| Prompt injection via data | Sanitize tool outputs before feeding back to LLM |
| Confidently wrong final answers | Add a "critic" step or require citations from tool outputs |

---

## Building a Data Quality Monitoring Agent

```python
from langchain_openai import ChatOpenAI
from langchain.tools import tool
from langchain.agents import create_react_agent, AgentExecutor
from langchain import hub
import snowflake.connector
import json
from datetime import date

# --- Tool Definitions ---

@tool
def get_null_rate(table: str, column: str) -> str:
    """Get the percentage of NULL values for a column in a Snowflake table."""
    sql = f"""
        SELECT
            COUNT_IF({column} IS NULL) AS null_count,
            COUNT(*) AS total_count,
            ROUND(100.0 * COUNT_IF({column} IS NULL) / NULLIF(COUNT(*), 0), 2) AS null_pct
        FROM {table}
        WHERE LOAD_DATE = CURRENT_DATE
    """
    return _run_sql(sql)

@tool
def get_row_count_trend(table: str, days: int = 7) -> str:
    """Get daily row counts for a table over the last N days."""
    sql = f"""
        SELECT LOAD_DATE, COUNT(*) AS row_count
        FROM {table}
        WHERE LOAD_DATE >= DATEADD(day, -{days}, CURRENT_DATE)
        GROUP BY 1
        ORDER BY 1
    """
    return _run_sql(sql)

@tool
def get_value_distribution(table: str, column: str) -> str:
    """Get top 10 value distribution for a categorical column."""
    sql = f"""
        SELECT {column}, COUNT(*) AS cnt,
               ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
        FROM {table}
        WHERE LOAD_DATE = CURRENT_DATE
        GROUP BY 1
        ORDER BY 2 DESC
        LIMIT 10
    """
    return _run_sql(sql)

@tool
def create_dq_alert(severity: str, table: str, issue: str, details: str) -> str:
    """Log a data quality alert to the DQ_ALERTS table."""
    sql = f"""
        INSERT INTO MORTGAGE_DB.MONITORING.DQ_ALERTS
            (ALERT_DATE, SEVERITY, TABLE_NAME, ISSUE_DESCRIPTION, DETAILS, CREATED_BY)
        VALUES
            (CURRENT_DATE, '{severity}', '{table}', '{issue}', '{details}', 'dq_agent_v1')
    """
    return _run_sql(sql)

def _run_sql(sql: str) -> str:
    conn = snowflake.connector.connect(
        user="svc_dq_agent",
        account="myorg-myaccount",
        warehouse="COMPUTE_WH",
        database="MORTGAGE_DB",
        schema="LOAN_ORIGINATIONS",
        role="DQ_AGENT_ROLE"
    )
    try:
        cur = conn.cursor()
        cur.execute(sql)
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description] if cur.description else []
        return json.dumps({"columns": cols, "rows": rows[:20]})
    except Exception as e:
        return json.dumps({"error": str(e)})
    finally:
        conn.close()

# --- Agent Setup ---

llm = ChatOpenAI(model="gpt-4o", temperature=0)
tools = [get_null_rate, get_row_count_trend, get_value_distribution, create_dq_alert]
prompt = hub.pull("hwchase17/react")

agent = create_react_agent(llm, tools, prompt)
executor = AgentExecutor(
    agent=agent,
    tools=tools,
    verbose=True,
    max_iterations=15,
    handle_parsing_errors=True
)

# --- Run Daily DQ Check ---

dq_goal = """
Perform a data quality check on today's load for LOAN_ORIGINATIONS table.
Check the following:
1. NULL rate for LOAN_ID, BORROWER_SSN_LAST4, PROPERTY_ZIP, NOTE_RATE, UPB
2. Row count trend vs last 7 days — flag if today is >20% different from the 7-day average
3. Distribution of LOAN_PURPOSE — flag if any unexpected values appear
4. Distribution of LOAN_TYPE — flag if CONVENTIONAL share drops below 60%
For any issue found, create a DQ alert with appropriate severity (CRITICAL, HIGH, MEDIUM, LOW).
Provide a final summary of all findings.
"""

result = executor.invoke({"input": dq_goal})
print(result["output"])
```

---

## Interview Questions & Answers

**Q1: What is the ReAct pattern and why does it matter for data engineering agents?**

ReAct (Reasoning + Acting) is the foundational loop for LLM agents: the model generates a Thought (internal reasoning), selects an Action (tool call with arguments), receives an Observation (tool output), and repeats until it reaches a Final Answer. For data engineering, this matters because data tasks are inherently multi-step: you need to inspect schema, write a query, check the result, iterate on the query, and finally summarize findings. ReAct enables the agent to handle this exploratory, iterative nature of data work rather than trying to answer in a single shot. The loop also provides auditability — you can trace exactly what the agent reasoned and did at each step.

**Q2: How do you prevent an agent from hallucinating Snowflake table or column names?**

Several layers of defense: First, always inject a schema summary into the system prompt or tool description — list available tables, key columns, and their data types so the LLM has grounding. Second, implement a SQL validation step before execution: parse the SQL and check all referenced tables/columns against a schema registry (information_schema or a cached schema manifest). Third, add a retry mechanism: if a query fails with "Object not found", catch the error, feed it back to the agent as an Observation, and let it self-correct. Fourth, restrict the agent's database role to read-only on specific schemas — this limits blast radius. In my Snowflake environments I also maintain a lightweight semantic layer YAML (similar to Cortex Analyst format) and always include the relevant table descriptions in the agent's context.

**Q3: What is the difference between short-term and long-term agent memory, and when would you use each for mortgage data workflows?**

Short-term memory is the agent's context window — everything in the current conversation including prior tool calls and observations. It's ephemeral and reset between runs. Long-term memory persists across sessions in a vector store or database. For mortgage data workflows: short-term memory is sufficient for a single ad-hoc analysis session (e.g., "find all FHA loans closed in January with LTV > 97"). Long-term memory becomes valuable for a persistent monitoring agent that needs to remember "last Tuesday we found 1,847 null zips and that was an anomaly" — so today it can compare against that baseline. Long-term memory is also useful for storing schema documentation, business rule definitions (FNMA/FHLMC eligibility criteria), and past remediation steps so the agent can reference them without re-discovering them every run.

**Q4: How does Snowflake Cortex Analyst differ from a general-purpose LangChain SQL agent?**

Cortex Analyst is purpose-built for Text-to-SQL within Snowflake with three key advantages: (1) Data never leaves Snowflake — the LLM reasoning happens inside Snowflake's infrastructure, satisfying strict data governance and PII requirements typical in the mortgage industry. (2) It uses a semantic model (a YAML file you maintain) to ground the LLM in your business vocabulary — "delinquency rate" maps to a specific formula, "active loans" means a specific filter — eliminating ambiguity. (3) It's managed and versioned by Snowflake, reducing operational overhead. A LangChain SQL agent gives you more flexibility (multi-step reasoning, cross-system tools, custom memory), but requires you to manage hosting, API keys, prompt engineering, and data governance yourself. For governed, read-heavy analytics on Snowflake data, Cortex Analyst is often the better production choice.

**Q5: What are the most important guardrails to put on a data engineering agent before deploying it to production?**

Seven non-negotiable guardrails: (1) Read-only database role — agent should never have INSERT/UPDATE/DELETE on production tables unless that is the explicit purpose. (2) Row result caps — limit query results returned to the agent to prevent token overflow and cost explosion. (3) Max iterations limit — prevent infinite loops; 10–15 iterations is typical. (4) SQL allowlist/denylist — block DROP, TRUNCATE, ALTER, GRANT at the tool execution layer, not just the prompt. (5) Output validation — before presenting the final answer, check it for obviously wrong numbers (e.g., a loan count of 0 when thousands are expected). (6) Audit logging — log every tool call with timestamp, SQL executed, and result row count to a separate audit table. (7) Human-in-the-loop for write operations — any agent action that modifies data or deploys code requires an async human approval step.

**Q6: Explain the Plan-and-Execute pattern and when it is preferable to standard ReAct.**

Plan-and-Execute (also called Plan-then-Execute) splits the agent into two phases: a Planner LLM call that generates a full step-by-step plan upfront, and an Executor that works through each step in sequence. Standard ReAct is fully online — the agent decides the next action only after seeing the previous result, which can lead to meandering reasoning on complex tasks. Plan-and-Execute is preferable when: the task has a well-defined structure (e.g., run 12 specific DQ checks across 5 tables), you want to show the user a plan for approval before execution (human-in-the-loop), or you need to parallelize — once you have a plan, independent steps can be dispatched concurrently. The tradeoff is that the upfront plan may become stale if early steps reveal unexpected data conditions, requiring re-planning logic.

**Q7: How would you build an agent to generate a dbt model for a new business requirement?**

I would give the agent three tools: (1) get_table_schema(table_name) — returns column names, types, and descriptions from Snowflake information_schema; (2) read_existing_dbt_model(model_name) — reads an existing model file as a style reference; (3) write_dbt_model(model_name, sql, description) — writes the model to the dbt project directory and generates the schema.yml entry. The agent flow: read the requirement, identify source tables (using schema tools), find a similar existing model for style reference, generate the SQL using Snowflake-specific syntax (CTEs, QUALIFY for deduplication, etc.), generate the schema.yml with column descriptions and dbt tests (not_null, unique, accepted_values), then write both files. A human-in-the-loop checkpoint before write is critical — the agent should output a preview and await approval. I would run dbt compile (not dbt run) as a final tool call to catch syntax errors before commit.

**Q8: What are the practical limitations of using LLMs as the "brain" of a data pipeline orchestration agent?**

Five practical limitations: (1) Non-determinism — the same input can produce different SQL on different runs, which is unacceptable for audited mortgage reporting pipelines. Mitigate with temperature=0 and output validation. (2) Context window constraints — a full Snowflake schema with hundreds of tables cannot fit in a single context. Requires smart retrieval (RAG over schema descriptions) to surface only relevant tables. (3) Latency — even a 5-step ReAct loop with GPT-4o can take 30–60 seconds, too slow for real-time pipeline decisions. Pre-generate queries offline. (4) Cost — each iteration consumes tokens; a runaway 15-iteration loop on GPT-4o costs real money at scale. Set hard iteration limits and monitor spend. (5) Auditability — regulators (CFPB, GSE counterparties) require explainable data transformations. LLM reasoning logs are verbose but not the same as deterministic code audit trails. Agents are best for exploratory and development tasks, not the final production execution layer.

**Q9: How does Claude's tool use differ from OpenAI's function calling, and does the difference matter in practice?**

Both implement structured tool calling where the model outputs a JSON object specifying a function name and arguments rather than executing code directly. The practical differences: Claude uses an `input_schema` with JSON Schema format and tends to be more conservative — it will refuse to call a tool if it lacks sufficient information rather than hallucinating arguments. OpenAI's function calling is slightly more permissive and has broader third-party library support (most LangChain examples default to OpenAI). For mortgage data environments, Claude's conservatism is often preferable — I'd rather the agent ask for clarification than generate a plausible-looking but wrong SQL query against loan records. Claude 3.5 Sonnet also handles long, complex schema contexts better than GPT-4o in my experience with wide Snowflake tables.

**Q10: Describe a real scenario where a data quality monitoring agent would provide more value than a traditional Airflow-based DQ check.**

Traditional Airflow DQ checks are pre-written assertions: null rate < 5%, row count within 10% of yesterday. They answer yes/no. A data quality agent adds three capabilities traditional checks cannot easily provide: (1) Root cause investigation — when a check fails, the agent can immediately drill into the data ("null zips are concentrated in loans from servicer ACME Corp, only for loans originated after 2024-11-15, correlating with their system migration"); (2) Adaptive thresholds — the agent can reason about whether a 15% row count drop matters given that yesterday was a holiday; (3) Natural language incident reports — instead of a Slack message saying "DQ check LOAN_ORIGINATIONS_NULL_CHECK FAILED", the agent generates "Q4 2024 load contains 1,847 null PROPERTY_ZIP values (5.9x Q3 baseline), concentrated in FHA loans from the Southeast region. Likely upstream cause: CoreLogic property data feed outage reported 2024-10-03. Recommend: hold these loans from the MBS pool calculation until resolved." This level of contextual, actionable insight is where agents earn their complexity cost.

---

## Pro Tips

- Always pass `handle_parsing_errors=True` in LangChain's AgentExecutor — LLM output formatting is imperfect and the agent will otherwise crash on minor JSON issues.
- For Snowflake agents, create a dedicated service account role (e.g., `DQ_AGENT_ROLE`) with explicit grants only on the schemas the agent needs. Never use SYSADMIN or ACCOUNTADMIN.
- Maintain a schema manifest file (JSON or YAML) that gets regenerated nightly from `INFORMATION_SCHEMA.COLUMNS` — inject the relevant portion into every agent context window to eliminate hallucinated column names.
- Use `temperature=0` for all data engineering agents. Creativity is the enemy of correct SQL.
- Log every agent run (goal, tool calls, final answer, elapsed time, token count) to a Snowflake table. This creates an audit trail and lets you analyze which queries the agent most often gets wrong.
- For the secondary mortgage market specifically, hardcode GSE eligibility constraints (FNMA/FHLMC LTV limits, FICO floors, DTI caps) into tool descriptions rather than relying on the LLM to recall them accurately.
- Test agents with "adversarial" inputs — ask for metrics that don't exist, reference tables with typos — to ensure graceful error handling before production deployment.
