# SQL Server Architecture Overview

[Back to SQL Server Index](./README.md)

---

## 1. High-Level SQL Server Components

SQL Server is not a single monolithic application — it is a platform composed of several major services, each serving a distinct role in the data ecosystem.

### 1.1 Database Engine

The **Database Engine** is the core service of SQL Server. It is responsible for:

- Storing, processing, and securing relational data
- Handling all T-SQL query execution
- Managing transactions with full ACID compliance
- Providing programmatic surfaces (stored procedures, triggers, views, functions)

The Database Engine itself is split into two major subsystems:

| Subsystem | Responsibility |
|-----------|---------------|
| **Relational Engine** | Query parsing, optimization, and execution plan generation |
| **Storage Engine** | Physical I/O, buffer management, locking, logging, and transaction management |

### 1.2 SQL Server Analysis Services (SSAS)

SSAS provides **OLAP** (Online Analytical Processing) and **data mining** capabilities. It operates in two modes:

- **Multidimensional mode** — traditional cubes with MDX query language
- **Tabular mode** — in-memory columnar model using DAX query language (more modern, generally preferred for new projects)

### 1.3 SQL Server Reporting Services (SSRS)

SSRS is a server-based report generation platform:

- Paginated reports authored in Report Builder or Visual Studio (SSDT)
- Delivers reports via a web portal, email subscriptions, or SharePoint integration
- Supports parameterized reports, drill-through, and subreports

### 1.4 SQL Server Integration Services (SSIS)

SSIS is an **ETL** (Extract, Transform, Load) platform:

- Graphical package designer with control flow and data flow tasks
- Supports complex data transformations, conditional logic, and error handling
- Packages can be deployed to the SSIS Catalog (project deployment model) or MSDB (legacy package deployment model)
- Common data flow components: OLE DB Source/Destination, Lookup, Derived Column, Conditional Split, Multicast

### 1.5 Other Notable Components

| Component | Purpose |
|-----------|---------|
| **SQL Server Agent** | Job scheduling, alerts, and automation |
| **Full-Text Search** | Linguistic full-text indexing and search |
| **Service Broker** | Asynchronous messaging between databases |
| **Replication** | Data distribution (snapshot, transactional, merge) |
| **PolyBase** | Query external data sources (Hadoop, Azure Blob, Oracle, etc.) using T-SQL |
| **Machine Learning Services** | Run R and Python scripts inside the database engine |

---

## 2. SQLOS (SQL Server Operating System)

SQLOS is SQL Server's **internal operating system layer** that sits between SQL Server and the Windows OS. It was introduced in SQL Server 2005 and is one of the most important architectural components to understand.

### Why SQLOS Exists

SQL Server needs fine-grained control over scheduling, memory, and I/O that the Windows OS scheduler cannot provide efficiently for a high-throughput database workload. SQLOS provides:

- **Non-preemptive (cooperative) scheduling** — threads voluntarily yield rather than being preempted by the OS
- **Memory management** — unified memory allocation with memory clerks and memory brokers
- **I/O management** — asynchronous I/O completion handling
- **Exception handling and deadlock detection**

### 2.1 Schedulers

A **scheduler** maps to a logical CPU. Each scheduler manages its own:

- Runnable queue (threads waiting to run)
- Waiter list (threads waiting on a resource)
- I/O completion list

```sql
-- View scheduler information
SELECT
    scheduler_id,
    cpu_id,
    status,
    current_tasks_count,
    runnable_tasks_count,
    current_workers_count,
    active_workers_count,
    work_queue_count
FROM sys.dm_os_schedulers
WHERE status = 'VISIBLE ONLINE';
```

**Key point:** If `runnable_tasks_count` is consistently greater than 0, you have CPU pressure — tasks are waiting for CPU time.

### 2.2 Worker Threads

A **worker thread** (or simply "worker") is a thread that executes tasks. The relationship is:

```
Scheduler (1) --> (many) Workers --> (many) Tasks
```

- Workers are created on demand up to `max worker threads` (default: 0 = auto-configured based on CPU count)
- Auto-configured formula (64-bit): 512 + ((logical CPUs - 4) * 16) for CPUs > 4
- Workers are pooled and reused

```sql
-- Check max worker threads setting
SELECT max_workers_count FROM sys.dm_os_sys_info;

-- Monitor worker thread usage
SELECT
    SUM(current_workers_count) AS total_workers,
    SUM(active_workers_count) AS active_workers,
    (SELECT max_workers_count FROM sys.dm_os_sys_info) AS max_workers
FROM sys.dm_os_schedulers
WHERE status = 'VISIBLE ONLINE';
```

**Warning:** Running out of worker threads is a critical situation that causes new connections to fail. Monitor the ratio of current workers to max workers.

### 2.3 Memory Nodes

SQLOS organizes memory into **memory nodes** that align with NUMA (Non-Uniform Memory Access) topology:

- Each memory node contains multiple **memory clerks** (consumers of memory)
- Memory clerks track allocations for specific purposes (buffer pool, plan cache, lock manager, etc.)
- **Memory brokers** coordinate memory distribution between clerks under pressure

---

## 3. System Databases

Every SQL Server instance has four system databases. Understanding them is critical for both interviews and production management.

### 3.1 master

- The **most critical** system database
- Contains: all system-level configuration, login accounts, linked server definitions, server-level settings, metadata about all other databases
- If `master` is lost and there is no backup, the entire instance must be rebuilt
- Should be backed up regularly

### 3.2 msdb

- Used by **SQL Server Agent** for job scheduling, alerts, and operators
- Stores: job definitions, job history, SSIS packages (legacy deployment), backup/restore history, Database Mail configuration, maintenance plans, log shipping configuration
- Also stores Policy-Based Management policies and Data Collector information

### 3.3 model

- **Template database** — every new database created on the instance is a copy of `model`
- Any object, setting, or configuration placed in `model` will exist in all subsequently created databases
- Common use: set default recovery model, add standard audit tables, or configure default file growth settings
- Also used as the template when `tempdb` is recreated at each instance startup

### 3.4 tempdb

- **Shared temporary workspace** — recreated from `model` every time SQL Server starts
- Never needs to be backed up (it cannot be backed up)
- Used for:
  - Temporary tables (`#temp`, `##global_temp`)
  - Table variables (when spilled to disk)
  - Row versioning (snapshot isolation, RCSI, online index operations, AFTER triggers)
  - Sort spills, hash spills, spool operations
  - DBCC CHECK operations
  - Worktables for cursors and certain joins

**Best practices for tempdb:**
- Multiple data files (typically 1 per logical CPU, up to 8, then add in groups of 4 if contention persists)
- Equal sizing of all data files (proportional fill algorithm)
- Place on fast storage (SSD/NVMe)
- Enable trace flag 1118 (full extent allocation — default in SQL Server 2016+)
- Enable instant file initialization

```sql
-- Check tempdb file configuration
SELECT
    name,
    physical_name,
    size * 8 / 1024 AS size_mb,
    growth,
    is_percent_growth
FROM tempdb.sys.database_files;

-- Monitor tempdb space usage
SELECT
    SUM(unallocated_extent_page_count) * 8 / 1024 AS free_space_mb,
    SUM(user_object_reserved_page_count) * 8 / 1024 AS user_objects_mb,
    SUM(internal_object_reserved_page_count) * 8 / 1024 AS internal_objects_mb,
    SUM(version_store_reserved_page_count) * 8 / 1024 AS version_store_mb
FROM sys.dm_db_file_space_usage;
```

---

## 4. Instance vs. Database Level Architecture

### Instance Level

An **instance** is a single installation of the SQL Server Database Engine. A server can host multiple instances (one default + multiple named instances).

Instance-level items:
- Server logins and security
- Linked servers
- SQL Server Agent jobs
- Server-level triggers
- Server configuration options (`sp_configure`)
- `master`, `msdb`, `model`, `tempdb`
- Error log, default trace
- Endpoints
- Memory allocation (buffer pool is shared across all databases)
- Worker thread pool (shared)

### Database Level

Each database is an **isolated unit** with its own:
- Data files (`.mdf`, `.ndf`) and log files (`.ldf`)
- Recovery model (FULL, BULK_LOGGED, SIMPLE)
- Users and schemas
- Compatibility level
- Collation (can differ from instance collation)
- Database-scoped configurations (SQL Server 2016+)
- Contained database authentication (optional)

```sql
-- Instance-level configuration
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure;

-- Database-level properties
SELECT
    name,
    recovery_model_desc,
    compatibility_level,
    collation_name,
    is_read_committed_snapshot_on,
    snapshot_isolation_state_desc
FROM sys.databases;
```

---

## 5. SQL Server Editions

| Feature | Enterprise | Standard | Express |
|---------|-----------|----------|---------|
| **Max Compute** | OS max | 4 sockets / 24 cores | 1 socket / 4 cores |
| **Max Memory (Buffer Pool)** | OS max | 128 GB | 1,410 MB |
| **Max Database Size** | 524 PB | 524 PB | 10 GB |
| **Availability Groups** | Full (read secondaries, auto-failover) | Basic AG (2 nodes, no read secondary) | Not available |
| **Online Index Operations** | Yes | No (Standard 2016+ partial) | No |
| **Data Compression** | Yes | Yes (2016 SP1+) | Yes (2016 SP1+) |
| **Columnstore Indexes** | Yes | Yes (2016 SP1+) | Yes (2016 SP1+) |
| **Partitioning** | Yes | Yes (2016 SP1+) | No |
| **In-Memory OLTP** | Yes | Yes (2016 SP1+, limited) | Yes (2016 SP1+, limited) |
| **Resource Governor** | Yes | No | No |
| **Parallel Query (DOP)** | Unlimited | Limited to lesser of cores or DOP setting | 1 (serial only) |

**Developer Edition** has all Enterprise features but is licensed only for dev/test use.

---

## 6. Client-Server Architecture & TDS Protocol

### Client-Server Model

SQL Server follows a classic **client-server architecture**:

```
[Client Application]
        |
   (Network Library)
        |
   [TDS Protocol over TCP/IP, Named Pipes, or Shared Memory]
        |
   [SQL Server Network Interface (SNI)]
        |
   [SQL Server Database Engine]
```

### TDS (Tabular Data Stream) Protocol

**TDS** is the application-layer protocol used for communication between clients and SQL Server.

- Originally developed by Sybase (SQL Server's ancestor), maintained by Microsoft
- Operates over TCP port **1433** (default instance) or dynamic ports (named instances)
- SQL Server Browser Service (UDP 1434) resolves named instance ports

**TDS packet flow:**
1. **Login** — client sends login record with authentication credentials
2. **SQL Command** — client sends T-SQL batch
3. **Response** — server returns result set(s), messages, errors
4. **Attention** — client can cancel a running query

All major client libraries speak TDS:
- **ADO.NET** (System.Data.SqlClient / Microsoft.Data.SqlClient)
- **ODBC** (SQL Server Native Client, MSOLEDBSQL)
- **JDBC** (Microsoft JDBC Driver)
- **OLE DB** (MSOLEDBSQL — the modern provider; SQLOLEDB is deprecated)

```sql
-- View active connections and their protocol
SELECT
    session_id,
    net_transport,
    protocol_type,
    client_net_address,
    local_tcp_port
FROM sys.dm_exec_connections;
```

---

## 7. Relational Engine vs. Storage Engine

These are the two major subsystems of the Database Engine, and understanding the boundary between them is essential.

### Relational Engine (Query Processor)

Handles everything **logical** — turning your T-SQL into an optimized execution plan:

| Component | Role |
|-----------|------|
| **Command Parser** | Parses T-SQL syntax into a parse tree |
| **Algebrizer** | Resolves names (tables, columns), validates data types, performs binding |
| **Query Optimizer** | Cost-based optimizer that generates candidate execution plans and picks the cheapest |
| **Query Executor** | Executes the plan by calling into the Storage Engine via OLE DB interfaces |

### Storage Engine

Handles everything **physical** — getting data to and from disk:

| Component | Role |
|-----------|------|
| **Access Methods** | Heap scans, index seeks/scans, index maintenance (splits, merges) |
| **Buffer Manager** | Manages the buffer pool (data page cache in memory) |
| **Transaction Manager** | BEGIN/COMMIT/ROLLBACK, write-ahead logging (WAL) |
| **Lock Manager** | Row, page, extent, table, and database-level locking |
| **Log Manager** | Writes to the transaction log (sequential, synchronous writes) |

**The interface between them:** The Query Executor calls Access Methods in the Storage Engine using an OLE DB rowset interface. The Storage Engine returns data pages to the Relational Engine for processing.

---

## 8. Common Interview Questions & Answers

### Q1: What is SQLOS and why does SQL Server need it?

**A:** SQLOS is SQL Server's internal operating system layer that provides cooperative (non-preemptive) scheduling, memory management, and I/O handling. SQL Server needs it because the Windows thread scheduler uses preemptive scheduling, which causes excessive context switching for a database workload with thousands of concurrent operations. SQLOS allows worker threads to voluntarily yield at known safe points, resulting in more efficient CPU utilization and reduced overhead.

### Q2: Why does tempdb need multiple data files?

**A:** When many sessions concurrently create and drop temporary objects, they contend for allocation bitmap pages (PFS, GAM, SGAM) in tempdb. Having multiple equally sized data files distributes this contention because SQL Server uses a proportional fill algorithm to spread allocations across files. The general recommendation is to start with one file per logical CPU up to 8, then add more in groups of 4 only if allocation contention persists (visible as PAGELATCH waits on pages 2:1:1, 2:1:2, etc.).

### Q3: What happens when a client sends a query to SQL Server?

**A:** The query travels over the TDS protocol to the SNI layer. The relational engine's parser creates a parse tree, the algebrizer resolves names and data types, and the query optimizer produces a cost-based execution plan (or retrieves one from plan cache). The query executor then iterates the plan operators, calling into the storage engine's access methods to retrieve data from the buffer pool (or disk if not cached). Results flow back to the client as TDS packets.

### Q4: What is the difference between Enterprise and Standard Edition from an architecture perspective?

**A:** Key architectural differences include: Enterprise supports unlimited memory for the buffer pool (Standard is capped at 128 GB), Enterprise can use unlimited cores for parallel queries (Standard is limited to 24 cores), Enterprise supports full Always On Availability Groups with read replicas (Standard only supports Basic AG), and Enterprise has features like Resource Governor for workload isolation, online index rebuild without blocking, and advanced partitioning capabilities.

### Q5: Explain the difference between instance-level and database-level security.

**A:** At the instance level, you create **logins** (Windows logins, SQL logins, or certificate/key-based logins) that authenticate to the SQL Server instance. At the database level, you create **users** mapped to those logins, and assign permissions via roles (db_datareader, db_datawriter, custom roles). A login with sysadmin maps to `dbo` in every database. Contained databases can bypass the login requirement by authenticating users directly at the database level.

### Q6: What are the system databases and what happens if you lose each one?

**A:** `master` — losing it means rebuilding the instance; it holds all server-level metadata. `msdb` — losing it means losing all Agent jobs, backup history, SSIS packages, and alert definitions; the instance still runs. `model` — losing it means new databases cannot be created and tempdb cannot be recreated at startup. `tempdb` — it cannot be lost in the traditional sense because it is recreated at every startup, but if its files are corrupted or the drive is full, SQL Server will not start.

---

## 9. Tips for the Interview

1. **Draw the architecture.** If you are at a whiteboard, sketch the client-server flow: Client -> TDS -> Relational Engine (Parser -> Algebrizer -> Optimizer -> Executor) -> Storage Engine (Access Methods -> Buffer Manager -> Disk). This demonstrates deep understanding.

2. **Know your version differences.** Many features that were Enterprise-only became available in Standard/Express starting with SQL Server 2016 SP1 (compression, columnstore, partitioning). Interviewers often test whether you know what is available in your edition.

3. **Mention SQLOS when discussing performance.** It shows you understand SQL Server at a deeper level than most candidates. Talk about schedulers, worker threads, and cooperative scheduling.

4. **Be specific about tempdb.** Almost every SQL Server interview touches on tempdb. Know the file count recommendation, why it matters, what the version store is, and how to monitor it.

5. **Relate architecture to troubleshooting.** For example: "When I see THREADPOOL waits, I know we are running out of worker threads, which relates to the SQLOS scheduler architecture. I would check `sys.dm_os_schedulers` and `sys.dm_os_waiting_tasks` to diagnose further."

6. **Know the protocols.** TDS is a surprisingly common interview question for senior roles. Understand that it is the wire protocol, that it runs on TCP 1433 by default, and that SNI is the abstraction layer within SQL Server.

---
