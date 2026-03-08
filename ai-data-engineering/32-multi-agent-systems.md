# Multi-Agent Systems & Orchestration
[Back to Index](README.md)

[← Back to Index](README.md)

---

## Overview

A single AI agent is powerful but constrained by a single context window, a single reasoning thread, and a single set of responsibilities. Multi-agent systems (MAS) distribute work across multiple specialized agents that collaborate, check each other's work, and operate in parallel. The result is a system that can tackle problems too large or complex for any one agent — analogous to how a data engineering team works: one person writes the SQL, another reviews it, a third validates the output against business rules.

For senior data engineers in the secondary mortgage market, multi-agent systems unlock use cases like automated loan tape reconciliation (research agent identifies discrepancies, SQL agent queries the warehouse, validation agent checks against FNMA/FHLMC guidelines, reporting agent generates the exception report), all running with minimal human intervention.

---

## Key Concepts

| Concept | Definition |
|---|---|
| Orchestrator | Top-level agent that plans, delegates, and aggregates results |
| Sub-agent / Worker | Specialized agent that executes a specific task |
| Critic Agent | Reviews another agent's output and provides corrective feedback |
| Researcher Agent | Gathers information (searches docs, queries data) without executing |
| Executor Agent | Executes actions (runs code, writes files, calls APIs) |
| Sequential Pattern | Agent A → Agent B → Agent C; output flows downstream |
| Parallel Pattern | Multiple agents run simultaneously; results merged afterward |
| Hierarchical Pattern | Orchestrator → [sub-orchestrators] → [workers] |
| State | Shared data structure passed between agents across turns |
| LangGraph | Graph-based framework for stateful, cyclical multi-agent workflows |
| CrewAI | Role-based collaborative agent framework |
| AutoGen | Microsoft's conversational multi-agent framework |

---

## Detailed Explanations

### Why Multi-Agent Systems?

**Specialization:** A single agent asked to simultaneously research FNMA guidelines, write Snowflake SQL, and validate data types performs worse than three specialized agents each focused on one task. Specialization allows tighter system prompts with domain-specific instructions.

**Parallelism:** In a sequential single-agent loop, every step waits for the previous one. In a multi-agent system, independent subtasks run concurrently — cutting wall-clock time significantly for data validation workflows.

**Context window management:** A complex ETL workflow might involve hundreds of thousands of tokens of schema documentation, query results, and intermediate reasoning. Splitting the work across agents means each agent only loads the context relevant to its task.

**Fault tolerance:** If one agent fails, the orchestrator can retry it, reassign to a different agent, or escalate to a human — without losing all prior work.

**Quality control:** A dedicated critic agent that reviews another agent's SQL output catches errors the original agent missed. This mirrors the human code review process.

### Agent Communication Patterns

```
SEQUENTIAL:
[Research Agent] → [SQL Agent] → [Validation Agent] → [Report Agent]
Each agent's output becomes the next agent's input.
Best for: Linear pipelines where each step depends on the prior.

PARALLEL:
              ┌→ [SQL Agent: Table A] ──┐
[Orchestrator]├→ [SQL Agent: Table B] ──┼→ [Merge & Validate Agent]
              └→ [SQL Agent: Table C] ──┘
Best for: Independent tasks that can run concurrently.

HIERARCHICAL:
[Master Orchestrator]
    ├── [ETL Sub-Orchestrator]
    │       ├── [Extract Agent]
    │       └── [Transform Agent]
    └── [QA Sub-Orchestrator]
            ├── [Schema Validation Agent]
            └── [Business Rules Agent]
Best for: Large complex workflows with logical sub-domains.
```

### LangGraph Deep Dive

LangGraph is LangChain's framework for building stateful, graph-based agent workflows. Unlike AgentExecutor (which runs a fixed loop), LangGraph lets you define explicit nodes (processing steps), edges (transitions), and conditional routing (branch based on state).

**Core concepts:**

- **State:** A typed dictionary (TypedDict) that flows through the graph. All nodes read from and write to this shared state.
- **Nodes:** Python functions (or agents) that receive state, do work, and return updated state.
- **Edges:** Define which node runs next. Can be unconditional (A always goes to B) or conditional (go to B or C based on state content).
- **StateGraph:** The graph object that you add nodes and edges to, then compile into a runnable.

```python
from typing import TypedDict, Annotated, List
from langchain_core.messages import BaseMessage, HumanMessage, AIMessage
from langgraph.graph import StateGraph, END
from langgraph.graph.message import add_messages
from langchain_openai import ChatOpenAI

# --- Shared State Definition ---

class ETLWorkflowState(TypedDict):
    messages: Annotated[List[BaseMessage], add_messages]
    source_schema: dict
    target_schema: dict
    mapping: dict
    sql_generated: str
    validation_errors: List[str]
    approved: bool
    final_report: str

# --- Node Functions (each is an agent or processing step) ---

llm = ChatOpenAI(model="gpt-4o", temperature=0)

def schema_research_node(state: ETLWorkflowState) -> ETLWorkflowState:
    """Research agent: fetches source and target schemas."""
    source = fetch_snowflake_schema("CORELOGIC_STAGING.PROPERTY_DATA")
    target = fetch_snowflake_schema("MORTGAGE_DB.LOAN_ORIGINATIONS")
    return {
        "source_schema": source,
        "target_schema": target,
        "messages": [AIMessage(content=f"Schemas fetched. Source: {len(source)} columns, Target: {len(target)} columns")]
    }

def mapping_agent_node(state: ETLWorkflowState) -> ETLWorkflowState:
    """Mapping agent: generates column mapping from source to target."""
    prompt = f"""
    Generate a JSON column mapping from source to target.
    Source columns: {state['source_schema']}
    Target columns: {state['target_schema']}
    Return a JSON object: {{"target_column": "source_expression", ...}}
    Include any necessary type casts or transformations.
    """
    response = llm.invoke([HumanMessage(content=prompt)])
    mapping = parse_json_from_response(response.content)
    return {
        "mapping": mapping,
        "messages": [AIMessage(content=f"Generated mapping for {len(mapping)} columns")]
    }

def sql_generation_node(state: ETLWorkflowState) -> ETLWorkflowState:
    """SQL agent: generates Snowflake INSERT...SELECT from mapping."""
    prompt = f"""
    Write a Snowflake SQL INSERT INTO ... SELECT statement using this mapping:
    {state['mapping']}
    Source table: CORELOGIC_STAGING.PROPERTY_DATA
    Target table: MORTGAGE_DB.LOAN_ORIGINATIONS
    Include WHERE clause to only load today's records (LOAD_DATE = CURRENT_DATE).
    Use proper Snowflake syntax. Add comments for complex transformations.
    """
    response = llm.invoke([HumanMessage(content=prompt)])
    return {
        "sql_generated": response.content,
        "messages": [AIMessage(content="SQL generated")]
    }

def validation_agent_node(state: ETLWorkflowState) -> ETLWorkflowState:
    """Critic agent: validates the generated SQL against business rules."""
    prompt = f"""
    Review this Snowflake SQL for a mortgage loan originations table:
    {state['sql_generated']}

    Check for:
    1. All NOT NULL columns in target are populated (LOAN_ID, UPB, NOTE_RATE, PROPERTY_ZIP)
    2. LTV_RATIO must be between 0.01 and 1.05
    3. NOTE_RATE must be between 0.01 and 0.30
    4. LOAN_TYPE must be one of: CONVENTIONAL, FHA, VA, USDA
    5. No SQL injection risks
    6. Correct Snowflake syntax (QUALIFY, PIVOT, etc.)

    Return JSON: {{"valid": true/false, "errors": ["error1", "error2"]}}
    """
    response = llm.invoke([HumanMessage(content=prompt)])
    result = parse_json_from_response(response.content)
    return {
        "validation_errors": result.get("errors", []),
        "approved": result.get("valid", False),
        "messages": [AIMessage(content=f"Validation: {'PASSED' if result.get('valid') else 'FAILED'} - {result.get('errors', [])}")]
    }

def route_after_validation(state: ETLWorkflowState) -> str:
    """Conditional router: if validation passes, go to execute; else go to fix."""
    if state["approved"]:
        return "execute"
    elif len(state.get("validation_errors", [])) > 3:
        return "escalate_human"  # Too many errors, need human
    else:
        return "fix_sql"

def sql_fix_node(state: ETLWorkflowState) -> ETLWorkflowState:
    """Fix agent: corrects SQL based on validation errors."""
    prompt = f"""
    Fix the following Snowflake SQL based on these validation errors:
    SQL: {state['sql_generated']}
    Errors: {state['validation_errors']}
    Return only the corrected SQL.
    """
    response = llm.invoke([HumanMessage(content=prompt)])
    return {
        "sql_generated": response.content,
        "validation_errors": [],
        "messages": [AIMessage(content="SQL corrected, re-validating")]
    }

def execute_node(state: ETLWorkflowState) -> ETLWorkflowState:
    """Executor node: runs the SQL against Snowflake (read-only validation run)."""
    result = run_snowflake_sql(state["sql_generated"])
    return {
        "final_report": f"ETL completed. Rows inserted: {result['rows_affected']}",
        "messages": [AIMessage(content=state["final_report"])]
    }

# --- Build the Graph ---

builder = StateGraph(ETLWorkflowState)

builder.add_node("research", schema_research_node)
builder.add_node("mapping", mapping_agent_node)
builder.add_node("sql_gen", sql_generation_node)
builder.add_node("validate", validation_agent_node)
builder.add_node("fix_sql", sql_fix_node)
builder.add_node("execute", execute_node)

builder.set_entry_point("research")
builder.add_edge("research", "mapping")
builder.add_edge("mapping", "sql_gen")
builder.add_edge("sql_gen", "validate")

builder.add_conditional_edges(
    "validate",
    route_after_validation,
    {
        "execute": "execute",
        "fix_sql": "fix_sql",
        "escalate_human": END
    }
)
builder.add_edge("fix_sql", "validate")  # Re-validate after fix (cycle)
builder.add_edge("execute", END)

graph = builder.compile()

# --- Run the workflow ---
result = graph.invoke({
    "messages": [HumanMessage(content="Load today's CoreLogic property data into LOAN_ORIGINATIONS")],
    "validation_errors": [],
    "approved": False
})
print(result["final_report"])
```

### Supervisor Pattern

The supervisor pattern has a single orchestrator LLM that receives the task, decides which worker agent to invoke, receives the result, and decides the next step. This is different from a hardcoded graph — the supervisor dynamically routes based on intermediate results.

```python
from langgraph.graph import StateGraph, END
from langchain_core.messages import HumanMessage, AIMessage
import operator
from typing import Sequence

WORKERS = ["sql_agent", "schema_agent", "dq_agent", "report_agent"]

SUPERVISOR_PROMPT = f"""
You are a data engineering supervisor managing a team of specialized agents.
Available workers: {WORKERS}
Given the task and current progress, decide which worker to call next.
Respond with ONLY the worker name, or FINISH if the task is complete.
"""

def supervisor_node(state):
    messages = state["messages"]
    response = llm.invoke([
        HumanMessage(content=SUPERVISOR_PROMPT),
        *messages
    ])
    next_worker = response.content.strip()
    return {"next": next_worker}

def route_to_worker(state):
    return state["next"]
```

### CrewAI: Role-Based Collaborative Agents

CrewAI abstracts agents as "crew members" with roles, goals, and backstories. It handles the orchestration automatically.

```python
from crewai import Agent, Task, Crew, Process
from crewai_tools import tool

# --- Define Tools ---
@tool("Snowflake SQL Runner")
def run_sql(query: str) -> str:
    """Execute SQL against Snowflake mortgage warehouse. Returns results as CSV."""
    return execute_snowflake_query(query)

@tool("dbt Model Reader")
def read_dbt_model(model_name: str) -> str:
    """Read a dbt model SQL file from the project."""
    return read_file(f"dbt_project/models/{model_name}.sql")

# --- Define Agents ---
sql_analyst = Agent(
    role="Senior SQL Analyst",
    goal="Write accurate, optimized Snowflake SQL for mortgage data analysis",
    backstory="""You are a SQL expert with 10+ years in secondary mortgage market data.
    You know FNMA/FHLMC data standards, loan tape formats, and Snowflake-specific optimizations.""",
    tools=[run_sql],
    llm=llm,
    verbose=True
)

data_validator = Agent(
    role="Data Quality Engineer",
    goal="Validate SQL output and flag data quality issues against business rules",
    backstory="""You are a data quality expert who knows MISMO data standards and GSE
    eligibility criteria. You catch errors before they reach production.""",
    tools=[run_sql],
    llm=llm,
    verbose=True
)

report_writer = Agent(
    role="Business Intelligence Analyst",
    goal="Summarize findings into clear, actionable executive reports",
    backstory="You translate technical data findings into business language for risk and ops teams.",
    llm=llm,
    verbose=True
)

# --- Define Tasks ---
analysis_task = Task(
    description="""
    Analyze the 30-day delinquency trends for FHA loans in the Southeast region.
    Query MORTGAGE_DB.LOAN_SERVICING.PAYMENT_HISTORY for the last 90 days.
    Calculate: delinquency rate by state, trend direction, top 5 servicers by delinquency rate.
    """,
    expected_output="SQL query results showing delinquency analysis with key metrics",
    agent=sql_analyst
)

validation_task = Task(
    description="""
    Review the SQL analysis results. Verify:
    - Delinquency rates are within plausible ranges (0-30%)
    - No states have suspiciously round numbers (indicating data issues)
    - Sample sizes are statistically meaningful (>30 loans per state)
    - Results align with known FHA delinquency benchmarks (national avg ~8-12%)
    """,
    expected_output="Validation report: PASS/FAIL for each check with explanations",
    agent=data_validator,
    context=[analysis_task]
)

report_task = Task(
    description="""
    Based on the analysis and validation, write a 1-page executive summary suitable for
    the Chief Risk Officer. Include: key finding, states of concern, recommended actions,
    data confidence level.
    """,
    expected_output="Executive summary report in markdown format",
    agent=report_writer,
    context=[analysis_task, validation_task]
)

# --- Assemble and Run Crew ---
crew = Crew(
    agents=[sql_analyst, data_validator, report_writer],
    tasks=[analysis_task, validation_task, report_task],
    process=Process.sequential,
    verbose=True
)

result = crew.kickoff()
print(result.raw)
```

### Parallel Agent Execution

For data processing tasks where tables are independent, parallel execution dramatically reduces runtime:

```python
import asyncio
from langchain_openai import ChatOpenAI

async def run_dq_check_async(table_name: str, checks: list) -> dict:
    """Run data quality checks on a single table asynchronously."""
    llm = ChatOpenAI(model="gpt-4o", temperature=0)
    # Each agent runs independently with its own context
    result = await executor.ainvoke({
        "input": f"Run these DQ checks on {table_name}: {checks}"
    })
    return {"table": table_name, "result": result["output"]}

async def run_parallel_dq_pipeline():
    """Run DQ checks on all mortgage tables in parallel."""
    tables = [
        ("LOAN_ORIGINATIONS", ["null_check", "range_check", "referential_integrity"]),
        ("PROPERTY_DATA", ["null_check", "address_validation", "appraisal_range"]),
        ("BORROWER_DATA", ["null_check", "ssn_format", "income_reasonableness"]),
        ("PAYMENT_HISTORY", ["null_check", "payment_logic", "balance_reconciliation"])
    ]

    tasks = [run_dq_check_async(table, checks) for table, checks in tables]
    results = await asyncio.gather(*tasks, return_exceptions=True)
    return results

# Run parallel DQ pipeline
results = asyncio.run(run_parallel_dq_pipeline())
```

### Error Handling and Recovery

```python
from langgraph.graph import StateGraph
from typing import TypedDict, Optional

class PipelineState(TypedDict):
    task: str
    result: Optional[str]
    error: Optional[str]
    retry_count: int
    failed_permanently: bool

def safe_agent_node(state: PipelineState) -> PipelineState:
    """Wraps agent execution with error handling and retry logic."""
    try:
        result = execute_agent(state["task"])
        return {"result": result, "error": None}
    except SnowflakeQueryError as e:
        if state["retry_count"] < 3:
            # Structured error feedback for self-correction
            corrected_task = f"{state['task']}\nPrevious attempt failed with: {str(e)}\nPlease fix and retry."
            return {"task": corrected_task, "error": str(e), "retry_count": state["retry_count"] + 1}
        else:
            return {"failed_permanently": True, "error": f"Max retries exceeded: {str(e)}"}
    except Exception as e:
        return {"failed_permanently": True, "error": f"Unrecoverable error: {str(e)}"}

def should_retry(state: PipelineState) -> str:
    if state.get("failed_permanently"):
        return "escalate"
    if state.get("error") and state["retry_count"] < 3:
        return "retry"
    return "continue"
```

### Automated Loan Data Reconciliation System

A complete multi-agent system for reconciling CoreLogic data against internal Snowflake data:

```
[Orchestrator Agent]
    │
    ├── [Ingestion Agent]    ← Pulls new CoreLogic loan tape files
    ├── [Mapping Agent]      ← Maps CoreLogic fields to MISMO/internal schema
    ├── [SQL Agent]          ← Generates comparison queries
    ├── [Reconciliation Agent] ← Identifies discrepancies (loan count, UPB, dates)
    ├── [Business Rules Agent] ← Validates against FNMA/FHLMC eligibility
    └── [Exception Report Agent] ← Generates actionable exception report
```

---

## Interview Questions & Answers

**Q1: Why would you use a multi-agent system instead of a single well-prompted agent for a mortgage data reconciliation workflow?**

Three core reasons: specialization, context management, and quality control. A single agent managing reconciliation, SQL generation, business rule validation, and report writing simultaneously dilutes its focus — you get mediocre performance on all tasks. Specialized agents with tight system prompts (e.g., "You are an expert in FNMA eligibility guidelines; your only job is to check if these loans meet Chapter B3-5 requirements") dramatically improve accuracy on each subtask. Context management is equally important — a reconciliation workflow might involve 50K+ rows of loan data, multiple schemas, and pages of business rules, easily exceeding any model's context window. Splitting work across agents means each agent loads only its relevant context. Finally, a critic/validation agent reviewing another agent's SQL output provides a quality control layer analogous to the code review process, catching errors before they reach production.

**Q2: Explain LangGraph's state management model. How does shared state differ from passing messages between agents?**

LangGraph's state is a TypedDict that every node reads from and writes to. It persists across the entire graph execution — not just the current node's scope. This is fundamentally different from message passing: in a message-passing system (like AutoGen's conversational model), agents communicate by sending text messages to each other, and each agent maintains its own internal state. In LangGraph, all agents share a single structured state object. The advantages of shared state: any node can access any prior computation result (not just what the previous node chose to include in its message), state can include structured data (dicts, lists, typed objects) not just text strings, and you can add `reducers` to control how state fields are updated (e.g., `Annotated[List, operator.add]` means append to the list rather than replace it). For data engineering workflows, this is critical — you want your SQL generation node to access the schema objects fetched by the research node as a structured dict, not as a reconstructed text blob.

**Q3: What is the supervisor pattern in multi-agent systems and when should you use it over a hardcoded graph?**

In the supervisor pattern, a central orchestrator LLM dynamically decides which worker agent to call next, rather than following a predetermined graph structure. The supervisor reads the task and current progress, then outputs the name of the next worker (or FINISH). Use the supervisor pattern when: the workflow structure is genuinely dynamic and cannot be predetermined (e.g., debugging a broken pipeline — you don't know in advance whether you'll need the schema agent, the SQL agent, or the logs agent), or when you want an LLM to reason about prioritization (should I validate this data first, or should I gather more context?). Use a hardcoded graph when the workflow steps are known and sequential — this is more predictable, cheaper (no LLM call for routing), faster, and easier to audit. For regulated mortgage data pipelines, I prefer hardcoded graphs for production ETL (deterministic, auditable) and the supervisor pattern for exploratory analysis or debugging workflows.

**Q4: How does CrewAI's role-based approach differ from LangGraph's graph-based approach?**

CrewAI abstracts the multi-agent problem around human organizational metaphors: you define agents as team members with roles, goals, and backstories, and tasks as work items with expected outputs. CrewAI handles the orchestration (sequential or hierarchical process) automatically — you don't define explicit routing logic. LangGraph is lower-level: you define nodes as functions, edges as transitions, and conditional routing as Python functions. LangGraph gives you complete control over execution flow, supports cycles (retry loops), and allows non-agent nodes (pure functions). In practice: CrewAI is faster to prototype (less boilerplate, intuitive role/task framing), but LangGraph is more production-ready for complex workflows with cycles, dynamic branching, and state that needs careful management. For a mortgage data team, I'd use CrewAI for proof-of-concept multi-agent demos and LangGraph for the production system with proper error handling and audit logging.

**Q5: How do you handle state persistence across multiple agent runs in a long-running workflow?**

LangGraph supports persistent checkpointing via a `checkpointer` — an object that saves graph state after each node execution. Out of the box, LangGraph supports in-memory checkpointing (ephemeral) and Postgres-based checkpointing (durable). For a long-running mortgage reconciliation job that might span hours: configure a Postgres checkpointer (or Snowflake if you want everything in-platform), and give each workflow run a unique `thread_id`. If the workflow fails mid-execution, you can resume from the last checkpoint rather than starting over. This is critical for expensive operations like running 50 SQL queries against Snowflake — you don't want to re-run the first 40 if the 41st fails. Code pattern: `graph.invoke(state, config={"configurable": {"thread_id": "recon_run_20250307_001"}})`. To resume: `graph.invoke(None, config={"configurable": {"thread_id": "recon_run_20250307_001"}})` — LangGraph loads from the checkpoint automatically.

**Q6: What is AutoGen and how does Microsoft's conversational multi-agent approach differ from LangGraph?**

AutoGen (Microsoft) models multi-agent collaboration as conversations: agents are `ConversableAgent` objects that send and receive messages in a chat-like interface. The key differentiator is AutoGen's `GroupChat` — a construct where multiple agents participate in a shared conversation thread, and a `GroupChatManager` routes the conversation to the appropriate agent. This is closer to how humans collaborate in a Slack channel: anyone can respond, and a moderator decides who speaks next. LangGraph, by contrast, is workflow-centric: you explicitly define which node runs when. AutoGen's strength is natural conversational workflows where agents need to debate or iteratively refine an answer (a coder agent writes code, a reviewer agent critiques it, the coder revises). LangGraph's strength is structured data pipelines with well-defined stages. For mortgage ETL, LangGraph is usually the better fit; AutoGen shines for code generation and review workflows.

**Q7: Describe how you would architect a multi-agent system for processing incoming loan tape files.**

I would use a LangGraph hierarchical workflow with six specialized agents: (1) File Intake Agent — monitors an S3/Snowflake Stage for new loan tape files, identifies format (pipe-delimited, fixed-width, XML/MISMO), and routes to the appropriate parser. (2) Schema Discovery Agent — infers column mapping from the loan tape's header row against the target schema, leveraging a RAG store of known servicer schemas for common servicers (Pennymac, UWM, Rocket). (3) Data Type & Quality Agent — profiles the data (null rates, value distributions, type validation), flags anomalies. (4) Business Rules Agent — validates FNMA/FHLMC eligibility (LTV, FICO, DTI, property type constraints), flags ineligible loans. (5) Load Agent — generates and executes the Snowflake COPY INTO or INSERT statement for passing loans. (6) Exception Report Agent — generates a structured exception report for failed loans and emails it to the loan acquisition team. The orchestrator graph defines the sequence with conditional edges: if DQ failures > 5%, halt and escalate to human before loading.

**Q8: How do you test a multi-agent system before deploying it to a production mortgage data environment?**

Five testing strategies: (1) Unit test individual agent nodes in isolation with mocked tool calls — verify each agent produces the expected output format given controlled inputs. (2) Integration test the full graph with a synthetic loan dataset that includes known error conditions (null required fields, out-of-range LTV, invalid CUSIP). Verify the validation agent catches every intentional error. (3) Regression test with historical loan tapes — run the agent system on last month's actual loan tape and compare output against what your existing manual/rule-based process produced. Any discrepancy is a bug or a legitimate improvement to investigate. (4) Adversarial testing — inject malicious inputs (SQL injection attempts in loan data fields, extremely long strings, unexpected encodings). Verify the system handles them gracefully. (5) Cost and latency profiling — run 10 end-to-end test executions and measure token consumption, LLM API costs, and wall-clock time. Set budget alerts before production deployment.

**Q9: What are the failure modes unique to multi-agent systems versus single-agent systems?**

Multi-agent systems introduce failure modes that single-agent systems do not have: (1) Cascading hallucinations — Agent A generates plausible-but-wrong schema mapping, Agent B generates SQL based on that mapping, Agent C validates the SQL (which is syntactically correct but semantically wrong), and the error only surfaces after data is loaded. Mitigation: always validate intermediate outputs against ground truth, not just format correctness. (2) State pollution — if agents write to shared state carelessly, an earlier agent's stale data can corrupt a later agent's context. Mitigation: use immutable state patterns where possible; reducers with explicit append vs. replace semantics. (3) Coordination overhead — in an AutoGen GroupChat with 5 agents, you might get 20+ message exchanges to accomplish what one well-prompted agent could do in 3 steps. Monitor token usage per run. (4) Deadlock / circular dependencies — Agent A waits for Agent B's output while Agent B waits for Agent A. LangGraph's explicit edge definitions prevent this; dynamic systems (AutoGen GroupChat) require careful design. (5) Inconsistent agent personas — if Agent A and Agent C have contradictory instructions about business rules, they will produce contradictory outputs, and the orchestrator may not detect the conflict.

**Q10: Claude Code (Anthropic) is described as a multi-agent coding system. What can a senior data engineer learn from its architecture?**

Claude Code uses a subagent pattern: the primary agent handles conversation and high-level planning, while subagents (spawned via tool calls) handle isolated tasks like reading files, executing code, searching the codebase, and editing specific files. Each subagent gets a focused context: the file-reading subagent only needs the file path, not the entire conversation history. This architecture teaches three lessons for data engineering agents: (1) Granular tool isolation — instead of one "do everything" SQL agent, build separate tools for schema inspection, query generation, query execution, and result interpretation. Each stays within its scope. (2) Context injection discipline — only pass to each subagent the state it actually needs; don't dump the entire pipeline state into every agent's context. (3) Tool-as-interface design — the quality of a multi-agent system is largely determined by the quality of tool definitions. Claude Code's tools (Read, Edit, Bash, Grep) have clean, single-responsibility interfaces. Model your data engineering tools similarly: `get_schema`, `run_sql`, `validate_row_counts`, `write_dbt_model` — each does one thing well.

---

## Pro Tips

- In LangGraph, always use typed state (TypedDict with proper type annotations). Untyped state leads to subtle bugs when agents write incompatible data to the same key.
- Set a `recursion_limit` on LangGraph graph compilation (`graph.compile(recursion_limit=25)`) to prevent infinite retry cycles from consuming your entire API budget.
- For Snowflake-heavy multi-agent workflows, use a single shared connection pool rather than opening a new Snowflake connection per agent per tool call — connection overhead adds up quickly with 5+ parallel agents.
- Log intermediate agent outputs to Snowflake as they are generated, not just at the end of the workflow. This gives you a debugging trail and lets you resume from checkpoints after failures.
- In CrewAI, the `backstory` field is not just flavor text — it significantly influences agent behavior. A backstory that includes specific domain constraints ("You adhere strictly to FNMA Selling Guide Chapter B3 eligibility requirements") improves accuracy on business rule validation tasks.
- Test your multi-agent system with `verbose=True` in development, but switch it off in production — verbose logging from 5+ agents simultaneously produces enormous log volumes.
- Design your state schema before writing any agent code. The state schema is the contract between agents; changing it mid-project requires updating every node. Treat it like a database schema change.
