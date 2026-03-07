# Database Engine Internals

[Back to SQL Server Index](./README.md)

---

## 1. The Two Halves of the Database Engine

The SQL Server Database Engine is divided into two major subsystems:

- **Relational Engine** (also called the Query Processor) — responsible for understanding *what* data you want
- **Storage Engine** — responsible for *physically retrieving or modifying* that data

Every query you execute passes through both. Understanding their internals is what separates a senior engineer from someone who just writes T-SQL.

---

## 2. Relational Engine Deep Dive

The Relational Engine processes a T-SQL statement through three sequential phases before execution begins.

### 2.1 Command Parser (Query Parser)

The parser performs:

1. **Lexical analysis** — tokenizes the T-SQL text into keywords, identifiers, literals, and operators
2. **Syntax validation** — checks that the statement conforms to T-SQL grammar rules
3. **Parse tree generation** — produces an internal tree representation of the query

If parsing fails, you get an error like:

```
Msg 102, Level 15, State 1 — Incorrect syntax near '...'
```

**Key point:** The parser does NOT check whether tables or columns actually exist. It only validates syntax. A query referencing a nonexistent table will pass the parser successfully.

### 2.2 Algebrizer (Binding / Name Resolution)

The algebrizer takes the parse tree and performs:

1. **Name resolution** — verifies that referenced tables, columns, functions, and data types exist in the catalog
2. **Type derivation** — determines the output data type of each expression
3. **Aggregate binding** — identifies GROUP BY semantics and validates aggregate usage
4. **Subquery processing** — unnests and normalizes subqueries where possible
5. **Output: Query Processor Tree** — a fully resolved, normalized logical tree

If binding fails, you get errors like:

```
Msg 208, Level 16, State 1 — Invalid object name 'dbo.NonExistentTable'
Msg 207, Level 16, State 1 — Invalid column name 'NonExistentColumn'
```

The algebrizer also computes a **hash of the query tree** that is used to look up cached plans in the plan cache. This hash is based on the resolved object references, not the raw text.

### 2.3 Query Optimizer

The SQL Server Query Optimizer is a **cost-based optimizer** — it generates multiple candidate execution plans, estimates the cost of each (in abstract CPU + I/O units), and selects the cheapest one.

#### Optimization Phases

The optimizer works in escalating phases to avoid spending too much time on simple queries:

| Phase | Description |
|-------|-------------|
| **Trivial Plan** | For very simple queries (e.g., `INSERT INTO ... VALUES`, single-table `SELECT` with obvious index). No cost-based optimization needed. |
| **Phase 0 (Transaction Processing)** | Applies a small set of transformation rules suitable for OLTP queries. If a "good enough" plan is found, optimization stops. |
| **Phase 1 (Quick Plan)** | Applies more transformation rules, considers more join orders. |
| **Phase 2 (Full Optimization)** | Exhaustive search with all transformation rules. Only reached for complex queries. |

```sql
-- See which optimization phase was used
-- Look for StatementOptmLevel in the XML plan
SET STATISTICS XML ON;
SELECT * FROM Sales.Orders WHERE OrderDate > '2025-01-01';
SET STATISTICS XML OFF;
```

#### What the Optimizer Considers

- **Join order** — for N tables, there are N! possible join orderings; the optimizer prunes aggressively
- **Join algorithms** — Nested Loops, Merge Join, Hash Match
- **Access methods** — index seek vs. scan, covering indexes, index intersection
- **Parallelism** — whether to use a parallel plan (based on cost threshold for parallelism)
- **Statistics** — histogram data on value distributions, used to estimate cardinality (row counts)
- **Constraints** — foreign keys, unique constraints, and check constraints can eliminate unnecessary joins or filters

#### Cardinality Estimation

The **Cardinality Estimator (CE)** predicts how many rows each operator will produce. Accurate cardinality estimates are the single most important factor for good plan quality.

- **Legacy CE** — used through SQL Server 2012
- **New CE (CE 70 → CE 150+)** — introduced in SQL Server 2014, uses a different mathematical model for multi-column correlations and ascending key scenarios

```sql
-- Force legacy CE for testing
SELECT * FROM Sales.Orders
WHERE OrderDate > '2025-01-01'
OPTION (USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION'));

-- Check which CE a plan used
-- Look for CardinalityEstimationModelVersion in the XML plan
```

**Common CE problems:**
- Outdated statistics (fix: `UPDATE STATISTICS`)
- Parameter sniffing (fix: `OPTIMIZE FOR`, `RECOMPILE`, Query Store)
- Correlated predicates the CE assumes are independent (fix: multi-column statistics, filtered statistics)

### 2.4 Query Executor

Once the optimizer produces an execution plan, the **Query Executor** drives the actual execution:

- Operates in an **iterator model** (also called the Volcano model)
- Each operator in the plan implements `Open()`, `GetNext()`, `Close()` methods
- Data flows from leaf operators (scans/seeks) up through the plan tree to the root (SELECT)
- The executor calls into the Storage Engine via the **Access Methods** interface to read or write data pages

---

## 3. Storage Engine Deep Dive

### 3.1 Access Methods

Access Methods is the layer that knows how to navigate SQL Server's on-disk structures:

- **Heap scan** — reads all pages in the IAM (Index Allocation Map) chain
- **Clustered index scan** — reads leaf-level pages in order (linked list traversal)
- **Clustered index seek** — navigates the B-tree from root to leaf
- **Nonclustered index seek/scan** — same B-tree navigation, but on the nonclustered index structure
- **Key/RID lookup** — fetches remaining columns from the base table after a nonclustered index seek
- **Index maintenance** — handles page splits, page merges, and allocation during INSERT/UPDATE/DELETE

```sql
-- Observe access methods in action
SET STATISTICS IO ON;
SELECT CustomerID, OrderDate
FROM Sales.Orders
WHERE CustomerID = 42;
SET STATISTICS IO OFF;

-- Output shows: logical reads, physical reads, read-ahead reads
-- logical reads = pages accessed from buffer pool
-- physical reads = pages fetched from disk
-- read-ahead reads = pages brought in proactively by the read-ahead mechanism
```

### 3.2 Buffer Manager

The **Buffer Manager** manages the **buffer pool** — SQL Server's primary data cache in memory.

**Core responsibilities:**
- Maintaining the mapping between data pages on disk and page frames in memory
- Deciding which pages to keep and which to evict (LRU-K eviction policy)
- Coordinating with the lazy writer and checkpoint processes
- Handling read-ahead to prefetch pages before they are needed

**How a page read works:**

1. Access Methods requests a page (by database_id, file_id, page_id)
2. Buffer Manager checks the **hash table** for the page in the buffer pool
3. **Cache hit** — page is in memory, return a pointer immediately
4. **Cache miss** — allocate a free page frame, issue an asynchronous I/O to read the page from disk, return it once loaded

Every page in the buffer pool has a **BUF structure** that tracks:
- Dirty bit (has the page been modified since it was read from disk?)
- Pin count (is anyone currently using this page?)
- Reference count (for LRU-K aging)

```sql
-- What is in the buffer pool right now?
SELECT
    DB_NAME(database_id) AS database_name,
    COUNT(*) AS pages_in_memory,
    COUNT(*) * 8 / 1024 AS mb_in_memory
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY pages_in_memory DESC;
```

### 3.3 Transaction Manager

The Transaction Manager ensures **ACID** properties through **Write-Ahead Logging (WAL)**:

**WAL Rule:** Before any dirty page is written to disk, all log records describing the changes to that page must first be written (hardened) to the transaction log.

**Transaction lifecycle:**

1. `BEGIN TRANSACTION` — assigns a transaction ID, marks the start in the log
2. Modifications generate log records (before/after images)
3. Log records are written to the **log buffer** in memory
4. On `COMMIT` — log buffer is flushed (hardened) to the `.ldf` file. This is the point of durability.
5. The actual data pages may remain dirty in the buffer pool — they will be written to disk later by checkpoint or lazy writer

**Recovery process (at startup):**

| Phase | Action |
|-------|--------|
| **Analysis** | Scan the log from the last checkpoint to find dirty pages and active transactions at the time of crash |
| **Redo (Roll Forward)** | Replay all committed transactions that may not have been written to data files |
| **Undo (Roll Back)** | Reverse all uncommitted transactions |

```sql
-- View active transactions
SELECT
    transaction_id,
    name,
    transaction_begin_time,
    CASE transaction_type
        WHEN 1 THEN 'Read/Write'
        WHEN 2 THEN 'Read-Only'
        WHEN 3 THEN 'System'
        WHEN 4 THEN 'Distributed'
    END AS transaction_type,
    CASE transaction_state
        WHEN 0 THEN 'Not fully initialized'
        WHEN 1 THEN 'Initialized, not started'
        WHEN 2 THEN 'Active'
        WHEN 3 THEN 'Ended (read-only)'
        WHEN 4 THEN 'Commit initiated'
        WHEN 5 THEN 'Prepared, awaiting resolution'
        WHEN 6 THEN 'Committed'
        WHEN 7 THEN 'Rolling back'
        WHEN 8 THEN 'Rolled back'
    END AS transaction_state
FROM sys.dm_tran_active_transactions;
```

### 3.4 Lock Manager

The Lock Manager provides **concurrency control** through a hierarchy of locks:

**Lock granularity (smallest to largest):**

| Level | Abbreviation | Description |
|-------|-------------|-------------|
| KEY | KEY | Single row in an index |
| RID | RID | Single row in a heap |
| PAGE | PAG | 8 KB data or index page |
| EXTENT | EXT | Group of 8 contiguous pages |
| HoBT | HoBT | Heap or B-tree partition |
| TABLE | TAB | Entire table including indexes |
| DATABASE | DB | Entire database |

**Lock modes:**

| Mode | Abbreviation | Purpose |
|------|-------------|---------|
| Shared | S | Reading data (SELECT) |
| Update | U | Reading with intent to modify (prevents conversion deadlocks) |
| Exclusive | X | Modifying data (INSERT, UPDATE, DELETE) |
| Intent Shared | IS | Signals intent to place S locks at a lower level |
| Intent Exclusive | IX | Signals intent to place X locks at a lower level |
| Schema Modification | Sch-M | DDL operations (ALTER TABLE) |
| Schema Stability | Sch-S | Query compilation — blocks Sch-M |

**Lock escalation:** When a single transaction holds more than ~5,000 locks on a single table, the Lock Manager attempts to escalate to a table lock to save memory. This can be controlled per table:

```sql
-- Disable lock escalation on a specific table
ALTER TABLE Sales.Orders SET (LOCK_ESCALATION = DISABLE);

-- Allow escalation to partition level (partitioned tables)
ALTER TABLE Sales.Orders SET (LOCK_ESCALATION = AUTO);

-- Monitor current locks
SELECT
    resource_type,
    resource_database_id,
    resource_associated_entity_id,
    request_mode,
    request_status,
    request_session_id
FROM sys.dm_tran_locks
WHERE resource_database_id = DB_ID();
```

---

## 4. Background System Processes

### 4.1 Lazy Writer

The **lazy writer** monitors the free buffer list in the buffer pool. When free pages drop below a threshold:

1. Scans the buffer pool for "old" pages (low reference count)
2. If the page is **clean** (not modified), simply frees the page frame
3. If the page is **dirty**, writes it to disk first, then frees it
4. Maintains a minimum free buffer list size for incoming page requests

**When you see heavy lazy writer activity**, it indicates **memory pressure** — SQL Server does not have enough memory for its working set and is constantly evicting pages.

```sql
-- Monitor lazy writer activity
SELECT *
FROM sys.dm_os_performance_counters
WHERE counter_name IN ('Lazy writes/sec', 'Free Pages', 'Page life expectancy');
```

### 4.2 Checkpoint Process

The **checkpoint** writes all dirty pages for a database to disk. Its purpose is to reduce **crash recovery time** by minimizing the amount of log that needs to be replayed during redo.

**Types of checkpoints:**

| Type | Trigger |
|------|---------|
| **Automatic** | Approximately every 1 minute (controlled by `recovery interval` setting) |
| **Manual** | `CHECKPOINT` command |
| **Indirect** | SQL Server 2012+: target-based, tries to keep recovery under `TARGET_RECOVERY_TIME` seconds |
| **Internal** | During backup, DBCC CHECKDB, database shutdown, certain ALTER DATABASE operations |

**Checkpoint vs. Lazy Writer:**

| Aspect | Checkpoint | Lazy Writer |
|--------|-----------|-------------|
| **Trigger** | Time/log-based | Memory pressure |
| **Scope** | All dirty pages for a database | Pages from any database |
| **Frees pages?** | No — just writes dirty pages to disk | Yes — evicts pages from buffer pool |
| **Goal** | Reduce recovery time | Maintain free page supply |

```sql
-- Check target recovery time (indirect checkpoint)
SELECT name, target_recovery_time_in_seconds
FROM sys.databases;

-- Force a checkpoint
CHECKPOINT;
```

### 4.3 Other Important System Threads

| Thread | Purpose |
|--------|---------|
| **Resource Monitor** | Monitors overall memory state, signals low-memory conditions to memory clerks |
| **Log Writer** | Flushes log buffers to the transaction log file on commit |
| **Deadlock Monitor** | Runs every 5 seconds (escalates to every second under deadlock conditions), detects deadlock cycles, kills the least expensive victim |
| **Ghost Cleanup** | Removes "ghost records" (logically deleted rows) from index leaf pages in the background |
| **Read-Ahead Thread** | Prefetches pages from disk in 64-page (512 KB) chunks ahead of sequential scans |

---

## 5. How a Query Flows: End to End

Here is the complete lifecycle of a `SELECT` query from the moment a client sends it to when results are returned:

```
1. CLIENT sends T-SQL batch over TDS protocol
       |
2. COMMAND PARSER
   - Tokenize and syntax check
   - Produce parse tree
       |
3. ALGEBRIZER
   - Resolve object names, column names, data types
   - Produce query processor tree
   - Compute plan cache hash
       |
4. PLAN CACHE LOOKUP
   - Check if a matching plan exists
   - If YES → skip optimization, reuse plan (step 6)
   - If NO → proceed to optimization (step 5)
       |
5. QUERY OPTIMIZER
   - Generate candidate plans using transformation rules
   - Estimate costs using statistics and cardinality estimator
   - Select the cheapest plan
   - Insert plan into plan cache
       |
6. QUERY EXECUTOR
   - Walk the plan tree using the iterator model
   - Call Open() on root operator → cascades down to leaf
   - Call GetNext() to pull rows up through the tree
       |
7. ACCESS METHODS (Storage Engine)
   - Navigate B-tree or heap structures
   - Request pages from Buffer Manager
       |
8. BUFFER MANAGER
   - Check buffer pool hash table
   - Cache hit: return page pointer
   - Cache miss: read from disk, add to buffer pool, return pointer
       |
9. RESULTS flow back up through the operator tree
       |
10. QUERY EXECUTOR packages results into TDS packets
       |
11. CLIENT receives result set
```

---

## 6. Compilation, Recompilation, and Plan Cache

### Plan Cache Fundamentals

The **plan cache** (formerly called the procedure cache) stores compiled execution plans for reuse:

- Stored in buffer pool memory, managed by the `CACHESTORE_SQLCP` (ad hoc plans) and `CACHESTORE_OBJCP` (stored procedure plans) memory clerks
- Plans are keyed by a hash of the query text (for ad hoc) or the object ID (for stored procedures)
- Plans are evicted under memory pressure or when invalidated

```sql
-- View cached plans
SELECT
    cp.objtype,
    cp.cacheobjtype,
    cp.usecounts,
    cp.size_in_bytes / 1024 AS size_kb,
    st.text AS query_text,
    qp.query_plan
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) qp
ORDER BY cp.usecounts DESC;
```

### What Causes Recompilation?

| Cause | Example |
|-------|---------|
| Schema change | Adding/dropping an index, altering a table |
| Statistics update | Auto-stats or manual `UPDATE STATISTICS` |
| `WITH RECOMPILE` | Explicit request on procedure or statement |
| SET option changes | Different `SET ANSI_NULLS`, `SET QUOTED_IDENTIFIER`, etc. between sessions |
| Temp table changes | Enough rows added to `#temp` to cross recompilation threshold |
| Plan eviction | Memory pressure pushes plan out of cache |

### Optimize for Ad Hoc Workloads

For environments with many unique ad hoc queries, a single-use plan bloat problem can waste plan cache memory:

```sql
-- Enable optimization for ad hoc workloads
-- Stores only a plan stub on first execution; full plan cached on second execution
EXEC sp_configure 'optimize for ad hoc workloads', 1;
RECONFIGURE;

-- Check plan cache bloat
SELECT
    objtype,
    COUNT(*) AS plan_count,
    SUM(size_in_bytes) / 1024 / 1024 AS total_mb,
    AVG(usecounts) AS avg_use_count
FROM sys.dm_exec_cached_plans
GROUP BY objtype
ORDER BY total_mb DESC;
```

---

## 7. Batch Mode vs. Row Mode Execution

### Row Mode (Traditional)

- Each operator processes **one row at a time**
- The `GetNext()` call returns a single row
- Suitable for OLTP workloads with small result sets
- Has been the execution model since SQL Server 1.0

### Batch Mode

- Each operator processes a **batch of rows** (typically ~900 rows) at a time
- Uses CPU-optimized, vectorized code paths
- Originally introduced in SQL Server 2012 for **columnstore indexes only**
- **Batch Mode on Rowstore** — introduced in SQL Server 2019, allows batch mode processing even without columnstore indexes when the optimizer deems it beneficial

**When batch mode helps:**
- Aggregations over large data sets
- Hash joins with large inputs
- Window functions over large partitions
- Analytics and reporting queries

```sql
-- Force batch mode with a hint (SQL Server 2019+)
SELECT
    CustomerID,
    SUM(TotalAmount) AS Total
FROM Sales.Orders
GROUP BY CustomerID
OPTION (USE HINT('ALLOW_BATCH_MODE'));

-- In an execution plan, look for the "Actual Execution Mode" property:
-- "Row" or "Batch"
```

**Batch mode operators include:** Hash Match, Sort, Window Aggregate, Filter, Columnstore Index Scan, Batch Mode Adaptive Join.

---

## 8. SQL Server Process Architecture

### Single Process, Multiple Threads

SQL Server runs as a **single Windows process** (`sqlservr.exe`) that manages its own internal thread scheduling via SQLOS.

```
sqlservr.exe (single process)
  ├── SQLOS Schedulers (1 per logical CPU)
  │     ├── Worker Thread Pool
  │     │     ├── User query threads
  │     │     ├── Background system threads
  │     │     └── Task processing
  │     └── I/O Completion Ports
  ├── Buffer Pool (shared memory region)
  ├── Plan Cache
  ├── Lock Manager Hash Table
  └── Log Buffers (per database)
```

### Thread Types

| Thread Type | Description |
|-------------|-------------|
| **User worker threads** | Execute user queries and stored procedures |
| **System worker threads** | Lazy writer, checkpoint, log writer, ghost cleanup, deadlock monitor |
| **Listener threads** | Accept new incoming connections on the TDS endpoint |
| **Signal handler** | Handles shutdown, service control signals |
| **Resource Monitor** | Monitors memory state and triggers memory notifications |
| **Task Factory** | Creates and assigns tasks to available workers |

### Parallel Query Execution

When a query qualifies for parallelism (estimated cost > `cost threshold for parallelism`, default: 5):

1. The optimizer generates a parallel plan with **exchange operators** (Distribute Streams, Repartition Streams, Gather Streams)
2. At runtime, a **parent task** coordinates N **child tasks** (where N = DOP)
3. Each child task runs on a separate scheduler/worker thread
4. Data is distributed among threads via exchange (hash, round-robin, or broadcast partitioning)

```sql
-- Control parallelism
EXEC sp_configure 'cost threshold for parallelism', 50;  -- raise from default 5
EXEC sp_configure 'max degree of parallelism', 8;
RECONFIGURE;

-- Per-query DOP control
SELECT * FROM Sales.LargeTable
WHERE Region = 'West'
OPTION (MAXDOP 4);
```

**CXPACKET / CXCONSUMER waits:** These indicate parallel query execution. `CXPACKET` waits are normal in parallel plans — the producing threads wait while the consuming thread processes rows. High `CXPACKET` waits combined with poor performance usually indicate a skewed parallel plan (one thread doing most of the work).

---

## 9. Common Interview Questions & Answers

### Q1: Walk me through what happens internally when you execute a stored procedure for the first time vs. the second time.

**A:** On the **first execution**: The T-SQL is parsed, the algebrizer resolves all object references, and the query optimizer performs full cost-based optimization to generate an execution plan. The compiled plan is stored in the plan cache (CACHESTORE_OBJCP). The executor then runs the plan.

On the **second execution**: The parser and algebrizer still run to produce a query hash, but the plan cache lookup finds the existing compiled plan. The optimizer is **skipped entirely**. The executor reuses the cached plan. This is significantly faster — compilation of complex procedures can take hundreds of milliseconds.

The risk is **parameter sniffing**: the plan was optimized for the first call's parameter values, which may be suboptimal for subsequent calls with different values.

### Q2: What is the difference between the lazy writer and checkpoint?

**A:** Both write dirty pages to disk, but for different reasons:

- **Checkpoint** writes dirty pages to reduce crash recovery time. It does NOT free pages from the buffer pool — the pages remain in memory as clean pages.
- **Lazy writer** writes dirty pages AND frees them from the buffer pool to maintain a supply of free page frames. It only activates under memory pressure.

If you see high lazy writer activity, it means SQL Server is under memory pressure and is evicting pages to make room for new ones.

### Q3: Explain lock escalation. When is it a problem and how do you handle it?

**A:** Lock escalation occurs when a single transaction accumulates approximately 5,000 locks on a single table. The Lock Manager attempts to convert many fine-grained locks (row or page) into a single table lock to save memory. This becomes a problem when the escalation to a table-level exclusive lock blocks other concurrent users.

Solutions:
- `ALTER TABLE ... SET (LOCK_ESCALATION = DISABLE)` — prevents escalation but uses more memory
- `ALTER TABLE ... SET (LOCK_ESCALATION = AUTO)` — escalates to partition lock for partitioned tables
- Reduce transaction size (process in smaller batches)
- Add appropriate indexes so fewer rows are locked
- Use RCSI (Read Committed Snapshot Isolation) to eliminate reader-writer blocking

### Q4: How does the query optimizer decide between a Nested Loops join, Merge Join, and Hash Match join?

**A:**

- **Nested Loops**: Best for small outer input with indexed inner input. The optimizer estimates cost based on outer row count multiplied by seek cost on inner. Good for OLTP with selective filters.
- **Merge Join**: Requires both inputs sorted on the join key (or an index providing order). Very efficient for large, pre-sorted inputs. Produces output in sorted order.
- **Hash Match**: Builds a hash table from the smaller (build) input, then probes with the larger (probe) input. Used when inputs are large and unsorted. Requires memory for the hash table (memory grant).

The optimizer costs all applicable options and picks the cheapest. It may even consider multiple join types within the same plan for different join operations.

### Q5: What is batch mode execution and when does it matter?

**A:** Batch mode processes approximately 900 rows at a time through each operator, using vectorized CPU instructions, compared to row mode which processes one row at a time. Originally it required columnstore indexes, but SQL Server 2019 introduced "batch mode on rowstore" which can use batch mode on traditional B-tree indexes when the optimizer estimates it would be beneficial.

Batch mode is most impactful for analytical queries with large scans, aggregations, sorts, and hash joins. It can provide 2-10x performance improvement for these workloads due to reduced per-row function call overhead and better CPU cache utilization.

### Q6: What is Write-Ahead Logging and why is it fundamental?

**A:** Write-Ahead Logging (WAL) is the rule that log records describing a change must be hardened to the transaction log BEFORE the changed data page can be written to a data file. This guarantees durability: even if SQL Server crashes immediately after a COMMIT, the committed changes can be recovered by replaying the log during the redo phase of crash recovery.

WAL means that a COMMIT only needs to wait for a sequential log write (fast), not for random data page writes (slow). This is why transaction log performance is critical — log write latency directly impacts commit latency.

---

## 10. Tips for the Interview

1. **Practice explaining the query lifecycle end-to-end.** This is the most common "explain internals" question. Be able to walk through: Parse -> Algebrize -> Optimize (or plan cache hit) -> Execute -> Access Methods -> Buffer Manager -> Results.

2. **Know why recompilation happens.** Statistics updates, schema changes, SET option changes, and temp table threshold crossings are the most common causes. Be able to explain how to detect excessive recompilation via `sys.dm_exec_query_stats` (plan_generation_num) or Extended Events.

3. **Understand the iterator (Volcano) model.** Saying "each operator calls GetNext() on its child operator to pull one row at a time" demonstrates you understand how execution plans actually run, not just how to read them.

4. **Be ready to discuss parameter sniffing in depth.** It ties together the optimizer, plan cache, and recompilation. Know the problem (plan optimized for one parameter value reused for a very different value) and the solutions (`OPTION(RECOMPILE)`, `OPTIMIZE FOR UNKNOWN`, Query Store forced plans, plan guides).

5. **Mention the recovery model when discussing the Transaction Manager.** Understanding that WAL, the transaction log, and the recovery model (FULL vs. SIMPLE vs. BULK_LOGGED) are all interconnected shows comprehensive knowledge.

6. **Connect background processes to monitoring.** For example: "I monitor `Page life expectancy` and `Lazy writes/sec` to detect memory pressure, and `Checkpoint pages/sec` to understand I/O patterns during checkpoints."

---
