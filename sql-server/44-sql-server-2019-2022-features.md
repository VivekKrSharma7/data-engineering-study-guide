# SQL Server 2019-2022 New Features

[Back to SQL Server Index](./README.md)

---

## Overview

SQL Server 2019 (version 15.x) and SQL Server 2022 (version 16.x) introduced transformative features targeting query performance, resilience, security, and cloud integration. As a senior Data Engineer, deep understanding of these features demonstrates that you stay current with the platform and can leverage modern capabilities to solve real-world problems. This guide covers the most important features across both releases.

---

## 1. Intelligent Query Processing (IQP)

IQP is a family of features that automatically improve query performance without requiring application code changes. These features build on each other across SQL Server 2017, 2019, and 2022.

### 1.1 Batch Mode on Rowstore

**Introduced:** SQL Server 2019 (compatibility level 150)

Traditionally, batch mode execution (processing rows in batches of ~900) was only available with columnstore indexes. SQL Server 2019 extends batch mode to rowstore heap and B-tree indexes for eligible operators.

**Eligible Operators:**
- Hash joins, hash aggregates, sorts
- Window functions
- Filters, compute scalars

**When It Activates:**
- Query is under compatibility level 150+
- Query involves sufficient rows (optimizer cost threshold)
- No columnstore index required

```sql
-- Verify batch mode on rowstore is being used
-- Look for "Batch" in the Actual Execution Mode column
SET STATISTICS XML ON;

SELECT
    CustomerID,
    COUNT(*) AS OrderCount,
    SUM(TotalDue) AS TotalSpend
FROM Sales.SalesOrderHeader
GROUP BY CustomerID
HAVING COUNT(*) > 10
ORDER BY TotalSpend DESC;

SET STATISTICS XML OFF;

-- In the execution plan XML, look for:
-- ActualExecutionMode="Batch" on operators like Hash Match
```

**Real-World Impact:** Analytics-style queries on rowstore tables (aggregations, sorts, window functions) can see 2x-5x performance improvements without adding columnstore indexes.

### 1.2 Memory Grant Feedback

**Evolution Across Versions:**
- **SQL Server 2017:** Batch mode memory grant feedback
- **SQL Server 2019:** Batch mode + row mode memory grant feedback (with compat level 150)
- **SQL Server 2022:** Percentile and persistence-based memory grant feedback

Memory grant feedback adjusts memory allocations for queries based on actual usage from previous executions.

**The Problem:** The optimizer estimates how much memory a query needs for sorts and hash operations. Overestimates waste memory. Underestimates cause spills to tempdb.

```sql
-- Detect memory grant issues
SELECT
    qs.query_id,
    qt.query_sql_text,
    rs.avg_query_max_used_memory * 8 / 1024 AS avg_used_memory_mb,
    rs.min_query_max_used_memory * 8 / 1024 AS min_used_memory_mb,
    rs.max_query_max_used_memory * 8 / 1024 AS max_used_memory_mb
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_plan qp ON rs.plan_id = qp.plan_id
JOIN sys.query_store_query qs ON qp.query_id = qs.query_id
JOIN sys.query_store_query_text qt ON qs.query_text_id = qt.query_text_id
WHERE rs.avg_query_max_used_memory > 0
ORDER BY rs.avg_query_max_used_memory DESC;
```

**SQL Server 2022 Enhancements:**
- **Percentile-based:** Uses multiple recent executions to calculate the grant, handling variable workloads better
- **Persistence:** Feedback is stored in Query Store, surviving restarts and plan evictions
- **CE feedback:** Cardinality estimation model adjustments are also persisted

```sql
-- Check memory grant feedback in Query Store (SQL 2022)
SELECT
    qp.query_id,
    qp.plan_id,
    qpf.feature_desc,
    qpf.feedback_data,
    qpf.state_desc
FROM sys.query_store_plan_feedback qpf
JOIN sys.query_store_plan qp ON qpf.plan_id = qp.plan_id;
```

### 1.3 Table Variable Deferred Compilation

**Introduced:** SQL Server 2019 (compatibility level 150)

**The Problem:** Before SQL Server 2019, table variables always reported an estimated row count of 1, regardless of actual cardinality. This led to terrible plan choices for table variables with many rows.

**The Fix:** Deferred compilation delays compilation of statements referencing table variables until first execution, at which point the actual row count is known.

```sql
-- Before SQL 2019: optimizer assumes @tvp has 1 row
-- After SQL 2019: optimizer uses actual row count

DECLARE @CustomerOrders TABLE (
    CustomerID INT,
    OrderCount INT
);

-- Insert thousands of rows
INSERT INTO @CustomerOrders
SELECT CustomerID, COUNT(*)
FROM Sales.SalesOrderHeader
GROUP BY CustomerID;

-- With deferred compilation, this join gets the right plan
-- because the optimizer knows @CustomerOrders has thousands of rows
SELECT
    co.CustomerID,
    co.OrderCount,
    c.CustomerName
FROM @CustomerOrders co
JOIN Sales.Customers c ON co.CustomerID = c.CustomerID
WHERE co.OrderCount > 5;
```

**Impact:** Queries using table variables with significant row counts may see dramatic plan improvements, often changing from nested loop joins to hash or merge joins.

### 1.4 Adaptive Joins

**Introduced:** SQL Server 2017 (batch mode), extended in 2019

Adaptive joins defer the choice between a nested loop join and a hash join until runtime, based on actual input row counts.

```
-- In the execution plan, you will see:
-- "Adaptive Join" operator
-- Adaptive Threshold Rows: X
-- If input rows < threshold -> Nested Loop
-- If input rows >= threshold -> Hash Match
```

**How It Works:**
1. The optimizer creates a plan with an adaptive join operator
2. At runtime, it counts rows from the build input
3. If rows exceed the threshold, it switches to hash join
4. If rows are below the threshold, it uses nested loop

**Requirements:**
- Compatibility level 140+ (batch mode) or 150+ (row mode eligible)
- Query Store must be enabled
- The optimizer must consider both join types viable

### 1.5 Interleaved Execution

**Introduced:** SQL Server 2017 (compatibility level 140)

Interleaved execution pauses query optimization after executing a multi-statement table-valued function (MSTVF) to get accurate cardinality, then resumes optimization with the correct estimate.

```sql
-- Without interleaved execution: MSTVF always estimates 100 rows
-- With interleaved execution: actual row count is used

CREATE FUNCTION dbo.GetCustomerOrders(@MinDate DATE)
RETURNS @Results TABLE (CustomerID INT, OrderDate DATE, Total MONEY)
AS
BEGIN
    INSERT INTO @Results
    SELECT CustomerID, OrderDate, TotalDue
    FROM Sales.SalesOrderHeader
    WHERE OrderDate >= @MinDate;
    RETURN;
END;
GO

-- The optimizer now correctly estimates rows from this function
SELECT
    r.CustomerID,
    c.CustomerName,
    r.Total
FROM dbo.GetCustomerOrders('2024-01-01') r
JOIN Sales.Customers c ON r.CustomerID = c.CustomerID;
```

### 1.6 Scalar UDF Inlining

**Introduced:** SQL Server 2019 (compatibility level 150)

Scalar UDFs traditionally created a per-row function call overhead with its own execution context. UDF inlining transforms eligible scalar functions into inline subqueries within the calling query.

```sql
-- This UDF can be inlined
CREATE OR ALTER FUNCTION dbo.GetDiscountedPrice(
    @Price DECIMAL(10,2),
    @DiscountPct DECIMAL(5,2)
)
RETURNS DECIMAL(10,2)
WITH SCHEMABINDING -- Required for inlining
AS
BEGIN
    RETURN @Price * (1.0 - @DiscountPct / 100.0);
END;
GO

-- When inlined, this query does NOT call the function row-by-row
-- Instead, the expression is expanded inline in the plan
SELECT
    ProductID,
    ListPrice,
    dbo.GetDiscountedPrice(ListPrice, 10.0) AS DiscountedPrice
FROM Production.Products;

-- Check if a function is inlineable
SELECT
    OBJECT_NAME(object_id) AS function_name,
    is_inlineable
FROM sys.sql_modules
WHERE definition IS NOT NULL
  AND OBJECTPROPERTY(object_id, 'IsScalarFunction') = 1;
```

**Requirements for Inlining:**
- Function must use `WITH SCHEMABINDING`
- No table variables, cursors, or certain constructs
- No recursive calls
- Database compatibility level 150+
- Inlining not disabled at database or function level

```sql
-- Disable inlining for a specific function (if causing issues)
CREATE OR ALTER FUNCTION dbo.MyFunction()
RETURNS INT
WITH INLINE = OFF
AS
BEGIN
    RETURN 1;
END;

-- Disable inlining at database level
ALTER DATABASE SCOPED CONFIGURATION SET TSQL_SCALAR_UDF_INLINING = OFF;
```

### 1.7 Approximate Query Processing

**Introduced:** SQL Server 2019

Provides fast approximate results for large-scale aggregations where exact precision is not required.

```sql
-- APPROX_COUNT_DISTINCT: Faster than COUNT(DISTINCT) with ~2% error
-- Useful for dashboards, analytics, and data exploration

-- Traditional (exact but slower on large tables):
SELECT COUNT(DISTINCT CustomerID) AS ExactCount
FROM Sales.SalesOrderDetail;

-- Approximate (much faster with ~2% error rate):
SELECT APPROX_COUNT_DISTINCT(CustomerID) AS ApproxCount
FROM Sales.SalesOrderDetail;

-- SQL Server 2022 adds APPROX_PERCENTILE_CONT and APPROX_PERCENTILE_DISC
SELECT
    DepartmentID,
    APPROX_PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY Salary) AS MedianSalary,
    APPROX_PERCENTILE_DISC(0.9) WITHIN GROUP (ORDER BY Salary) AS P90Salary
FROM HR.Employees
GROUP BY DepartmentID;
```

---

## 2. Accelerated Database Recovery (ADR)

**Introduced:** SQL Server 2019

ADR fundamentally redesigns the SQL Server recovery process using a persistent version store (PVS).

### The Problem with Traditional Recovery

Traditional SQL Server crash recovery has three phases:
1. **Analysis:** Scan the log to determine what needs redoing/undoing
2. **Redo:** Replay committed transactions from the log
3. **Undo:** Roll back uncommitted transactions

For long-running transactions, the undo phase can take hours, during which the database is unavailable.

### How ADR Solves This

ADR introduces:
- **Persistent Version Store (PVS):** Stores row versions in the user database (or tempdb). During undo, the engine simply points to the PVS version instead of physically rolling back changes.
- **sLog (secondary log stream):** A small in-memory log for non-versioned operations (locks, metadata). Enables fast analysis and redo.
- **Logical Revert:** Undo is nearly instantaneous -- just reference the PVS version.

```sql
-- Enable ADR
ALTER DATABASE [MyDatabase] SET ACCELERATED_DATABASE_RECOVERY = ON;

-- Check ADR status
SELECT name, is_accelerated_database_recovery_on
FROM sys.databases;

-- Monitor PVS space usage
SELECT
    pvs_off_row_page_count * 8 / 1024 AS pvs_size_mb,
    current_aborted_transaction_count,
    aborted_version_cleaner_start_time,
    aborted_version_cleaner_end_time
FROM sys.dm_db_persisted_sku_details; -- SQL 2019 specific DMV name may vary

-- Better: use this on SQL Server 2019+
SELECT * FROM sys.dm_tran_persistent_version_store_stats;
```

### ADR Benefits

| Aspect | Traditional Recovery | With ADR |
|---|---|---|
| Long transaction rollback | Minutes to hours | Seconds |
| Database availability after crash | Delayed by undo phase | Near-instant |
| Log truncation | Blocked by active transactions | PVS handles versioning |
| Transaction log growth | Large for long transactions | Minimal |

### ADR Considerations

- PVS consumes space in the user database -- monitor and manage
- PVS cleanup is background process; may lag under heavy workload
- Slight overhead for DML operations (version generation)
- Enabled by default in Azure SQL Database
- Excellent for workloads with long-running transactions or frequent rollbacks

```sql
-- Force PVS cleanup manually if space is growing
EXEC sys.sp_persistent_version_cleanup @dbname = N'MyDatabase';

-- Check active transactions blocking PVS cleanup
SELECT
    database_id,
    db_name(database_id) AS database_name,
    pvs_off_row_page_count_at_cleanup_start,
    pvs_off_row_page_count_at_cleanup_end
FROM sys.dm_tran_persistent_version_store_stats;
```

---

## 3. SQL Server 2022 Features

### 3.1 Ledger Tables

Ledger tables provide tamper-evidence for data, enabling cryptographic verification that data has not been illicitly altered.

**Two Types:**
- **Updatable Ledger Tables:** Allow normal DML but maintain a cryptographic history of all changes
- **Append-Only Ledger Tables:** Only allow inserts (no updates or deletes)

```sql
-- Create an updatable ledger table
CREATE TABLE Finance.AccountBalances (
    AccountID INT NOT NULL PRIMARY KEY,
    AccountHolder NVARCHAR(100),
    Balance DECIMAL(18,2),
    LastModified DATETIME2
) WITH (
    SYSTEM_VERSIONING = ON,
    LEDGER = ON
);

-- Create an append-only ledger table
CREATE TABLE Audit.TransactionLog (
    TransactionID INT IDENTITY(1,1),
    AccountID INT,
    Amount DECIMAL(18,2),
    TransactionDate DATETIME2 DEFAULT SYSUTCDATETIME()
) WITH (
    LEDGER = ON (APPEND_ONLY = ON)
);

-- View the ledger history
SELECT * FROM Finance.AccountBalances_Ledger;

-- Verify the ledger (check for tampering)
EXEC sp_verify_database_ledger
    N'[{"database_name":"MyDB","block_id":0,"hash":"0x..."}]';

-- Query ledger views
SELECT
    t.*,
    lv.ledger_transaction_id,
    lv.ledger_operation_type_desc,
    lv.ledger_sequence_number
FROM Finance.AccountBalances_Ledger lv
JOIN sys.database_ledger_transactions t
    ON lv.ledger_transaction_id = t.transaction_id
ORDER BY t.commit_time;
```

**Use Cases:**
- Financial records requiring audit trail
- Regulatory compliance (SOX, GDPR data lineage)
- Healthcare records integrity
- Supply chain tracking

### 3.2 Parameter-Sensitive Plan Optimization (PSP)

**The Problem:** Parameter sniffing causes a plan optimized for one parameter value to perform poorly for a different value distribution.

**Traditional Workarounds:**
- `OPTION (RECOMPILE)` -- expensive for frequent queries
- `OPTION (OPTIMIZE FOR (@param = value))` -- static, not adaptive
- Plan guides -- maintenance overhead

**PSP Solution:** SQL Server 2022 automatically creates multiple plan variants for the same query based on parameter value ranges (low, medium, high cardinality).

```sql
-- PSP is automatic at compatibility level 160
-- The optimizer identifies "sensitive" parameters and creates
-- dispatcher plans that route to different variants

-- Example: A query where @Status has highly skewed distribution
-- 'Active' = 95% of rows, 'Cancelled' = 0.1% of rows

CREATE PROCEDURE dbo.GetOrdersByStatus @Status VARCHAR(20)
AS
BEGIN
    SELECT OrderID, CustomerID, OrderDate, TotalDue
    FROM Sales.SalesOrderHeader
    WHERE Status = @Status;
END;

-- SQL 2022 creates separate plan variants:
-- Variant 1: For @Status = 'Active' (table scan, since 95% of rows)
-- Variant 2: For @Status = 'Cancelled' (index seek, since 0.1% of rows)

-- Check for PSP plans in Query Store
SELECT
    qp.plan_id,
    qp.query_id,
    qp.query_plan_hash,
    qv.query_variant_query_id,
    qv.parent_query_id,
    qv.dispatcher_plan_id
FROM sys.query_store_query_variant qv
JOIN sys.query_store_plan qp ON qv.query_variant_query_id = qp.query_id;
```

### 3.3 Query Store Hints

Query Store hints allow applying query hints to queries without modifying application code.

```sql
-- Apply a hint to a specific query via Query Store
-- First, find the query_id from Query Store
SELECT q.query_id, qt.query_sql_text
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE qt.query_sql_text LIKE '%SalesOrderHeader%';

-- Apply a hint (e.g., force MAXDOP 4)
EXEC sys.sp_query_store_set_hints
    @query_id = 42,
    @query_hints = N'OPTION (MAXDOP 4)';

-- Apply multiple hints
EXEC sys.sp_query_store_set_hints
    @query_id = 42,
    @query_hints = N'OPTION (MAXDOP 4, RECOMPILE)';

-- Apply a USE HINT
EXEC sys.sp_query_store_set_hints
    @query_id = 42,
    @query_hints = N'OPTION (USE HINT(''FORCE_LEGACY_CARDINALITY_ESTIMATION''))';

-- View active hints
SELECT
    query_hint_id,
    query_id,
    query_hints,
    source_desc
FROM sys.query_store_query_hints;

-- Remove a hint
EXEC sys.sp_query_store_clear_hints @query_id = 42;
```

**Benefits:**
- Fix query performance without modifying application code
- Alternative to plan guides (simpler, Query Store integrated)
- Can apply any valid query hint
- Survives plan cache evictions (persisted in Query Store)

### 3.4 Contained Availability Groups

Contained AGs encapsulate instance-level metadata (logins, SQL Agent jobs, linked servers) within the AG, so they fail over with the databases.

**The Problem with Traditional AGs:**
- Logins, Agent jobs, linked servers are instance-level objects
- Must be manually synchronized across replicas
- Drift causes failures after failover

**Contained AG Solution:**
```sql
-- Create a contained availability group
CREATE AVAILABILITY GROUP [MyContainedAG]
WITH (
    CONTAINED,
    CLUSTER_TYPE = WSFC,
    DB_FAILOVER = ON,
    DTC_SUPPORT = NONE
)
FOR DATABASE [MyDatabase]
REPLICA ON
    N'Node1' WITH (ENDPOINT_URL = 'TCP://Node1:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = AUTOMATIC),
    N'Node2' WITH (ENDPOINT_URL = 'TCP://Node2:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = AUTOMATIC);

-- Contained AG creates a system database per AG
-- Instance-level objects are stored there and replicated
-- Logins, Agent jobs, linked servers fail over automatically
```

### 3.5 Azure Synapse Link for SQL Server

Enables near-real-time analytics by automatically replicating data from SQL Server 2022 to Azure Synapse Analytics.

**Key Points:**
- No ETL pipelines needed -- automatic change feed
- Minimal impact on source OLTP performance
- Data lands in Synapse dedicated or serverless SQL pools
- Enables hybrid transactional/analytical processing (HTAP)

### 3.6 S3-Compatible Object Storage Integration

SQL Server 2022 can read and write to S3-compatible storage (AWS S3, MinIO, etc.).

```sql
-- Create a credential for S3 access
CREATE DATABASE SCOPED CREDENTIAL S3Credential
WITH IDENTITY = 'S3 Access Key',
SECRET = 'access_key_id:secret_access_key';

-- Create an external data source
CREATE EXTERNAL DATA SOURCE S3DataSource
WITH (
    LOCATION = 's3://mybucket.s3.amazonaws.com/',
    CREDENTIAL = S3Credential
);

-- Backup to S3
BACKUP DATABASE [MyDatabase]
TO URL = 's3://mybucket.s3.amazonaws.com/backups/MyDB.bak'
WITH CREDENTIAL = 'S3Credential', COMPRESSION;

-- Restore from S3
RESTORE DATABASE [MyDatabase]
FROM URL = 's3://mybucket.s3.amazonaws.com/backups/MyDB.bak'
WITH CREDENTIAL = 'S3Credential';

-- Use OPENROWSET to query Parquet files on S3
SELECT *
FROM OPENROWSET(
    BULK 's3://mybucket.s3.amazonaws.com/data/',
    FORMAT = 'PARQUET',
    DATA_SOURCE = 'S3DataSource'
) AS [data];
```

### 3.7 Buffer Pool Parallel Scan

**Introduced:** SQL Server 2022

Improves the performance of buffer pool scanning operations, which benefits:
- `DBCC CHECKDB` -- runs faster on large databases
- Buffer pool cleanup during memory pressure
- Lazy writer operations
- Large memory dumps

**Impact:** On systems with large memory (hundreds of GB), operations that scan the buffer pool can be 2x-5x faster. This is automatic and requires no configuration.

---

## 4. Additional SQL Server 2019 Features Worth Knowing

### Data Virtualization with PolyBase Enhancements

SQL Server 2019 expanded PolyBase to connect to Oracle, Teradata, MongoDB, and other ODBC sources without moving data.

```sql
-- Query Oracle data from SQL Server (no data movement)
CREATE EXTERNAL DATA SOURCE OracleSource
WITH (
    LOCATION = 'oracle://oracle-server:1521',
    CREDENTIAL = OracleCredential,
    CONNECTION_OPTIONS = 'ServerName=oracle-server;SID=ORCL'
);

CREATE EXTERNAL TABLE dbo.OracleCustomers (
    CustomerID INT,
    CustomerName NVARCHAR(200)
)
WITH (
    DATA_SOURCE = OracleSource,
    LOCATION = '[HR].[CUSTOMERS]'
);

-- Query as if it were a local table
SELECT * FROM dbo.OracleCustomers WHERE CustomerID = 100;
```

### SQL Server Big Data Clusters (Deprecated)

SQL Server 2019 introduced Big Data Clusters for Kubernetes-based deployments combining SQL Server, Spark, and HDFS. Note: This feature was retired and is not available in SQL Server 2022.

### Tempdb Metadata Optimization

```sql
-- Reduce contention on tempdb system table pages
ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;

-- Requires restart; makes tempdb catalog operations memory-optimized
-- Significant improvement for workloads with heavy temp table creation
```

### Verbose Truncation Warnings

```sql
-- SQL Server 2019 now tells you WHICH column and WHICH value was truncated
-- Instead of the generic "String or binary data would be truncated" error

-- Enable at database level:
ALTER DATABASE SCOPED CONFIGURATION SET VERBOSE_TRUNCATION_WARNINGS = ON;

-- Error message now includes:
-- "String or binary data would be truncated in table 'dbo.MyTable',
--  column 'Description'. Truncated value: 'This is the actual val...'"
```

---

## 5. Summary: IQP Feature Availability by Version

| Feature | SQL 2017 (140) | SQL 2019 (150) | SQL 2022 (160) |
|---|---|---|---|
| Batch Mode Adaptive Joins | Yes | Yes | Yes |
| Interleaved Execution (MSTVF) | Yes | Yes | Yes |
| Batch Mode Memory Grant Feedback | Yes | Yes | Enhanced (percentile, persistence) |
| Row Mode Memory Grant Feedback | No | Yes | Enhanced |
| Batch Mode on Rowstore | No | Yes | Yes |
| Table Variable Deferred Compilation | No | Yes | Yes |
| Scalar UDF Inlining | No | Yes | Yes |
| Approximate Count Distinct | No | Yes | Yes |
| Approximate Percentile | No | No | Yes |
| Parameter Sensitive Plan Optimization | No | No | Yes |
| CE Feedback | No | No | Yes |
| DOP Feedback | No | No | Yes |
| Optimized Plan Forcing | No | No | Yes |
| Query Store Hints | No | No | Yes |

---

## Common Interview Questions and Answers

### Q1: Explain Intelligent Query Processing and name five key features.

**Answer:** Intelligent Query Processing (IQP) is a family of automatic query performance improvements that require no application code changes -- typically only a compatibility level upgrade. Five key features are:

1. **Batch Mode on Rowstore** -- enables batch-mode execution for analytics queries on traditional rowstore tables, providing 2-5x speedups for aggregations and sorts.
2. **Memory Grant Feedback** -- automatically adjusts memory grants based on actual usage, eliminating spills to tempdb and reducing wasted memory.
3. **Table Variable Deferred Compilation** -- provides accurate cardinality estimates for table variables instead of the fixed estimate of 1 row.
4. **Scalar UDF Inlining** -- transforms eligible scalar functions into inline expressions, eliminating per-row function call overhead.
5. **Adaptive Joins** -- defers the choice between nested loop and hash join until runtime based on actual row counts.

The philosophy behind IQP is "upgrade and get faster" -- these are automatic improvements that activate at the appropriate compatibility level.

### Q2: What is Accelerated Database Recovery and why is it important?

**Answer:** ADR redesigns the SQL Server recovery process using a Persistent Version Store (PVS). In traditional recovery, rolling back a long-running transaction requires scanning the transaction log and physically undoing changes, which can take hours for very large transactions. ADR stores pre-change row versions in the PVS, so undo becomes a logical revert that completes in seconds regardless of transaction size. This provides near-instant database recovery after a crash, near-instant transaction rollback, and aggressive log truncation unblocked by active transactions. ADR is particularly valuable for ETL workloads with large batch operations, systems requiring maximum uptime, and Azure SQL Database where it is enabled by default.

### Q3: How does Parameter-Sensitive Plan Optimization work in SQL Server 2022?

**Answer:** PSP addresses parameter sniffing by allowing the optimizer to create multiple plan variants for the same parameterized query. When the optimizer identifies a parameter that has a skewed data distribution (e.g., a status column where 95% of rows are 'Active'), it creates a dispatcher plan that routes execution to different plan variants based on the parameter value at runtime. Low-cardinality parameter values get plans optimized for few rows (typically index seeks), while high-cardinality values get plans optimized for many rows (typically scans). This is stored in Query Store and works automatically at compatibility level 160. It is a significant improvement over the previous single-plan-fits-all approach, though it does not solve all parameter sniffing scenarios -- it focuses on the most impactful cases with clear cardinality skew.

### Q4: What are Ledger Tables and when would you use them?

**Answer:** Ledger tables in SQL Server 2022 provide blockchain-inspired tamper-evidence for relational data. Each change to a ledger table is cryptographically hashed and chained to previous entries, creating a verifiable audit trail. There are two types: updatable ledger tables (allow DML with full history tracking) and append-only ledger tables (inserts only). I would use ledger tables for financial transaction records where regulators require proof that data has not been altered, healthcare records requiring data integrity verification, supply chain data where multiple parties need to trust the data lineage, and any compliance scenario (SOX, GDPR) requiring tamper-evident audit trails. The key advantage over traditional temporal tables is the cryptographic verification -- you can mathematically prove data integrity, not just track history.

### Q5: Compare SQL Server 2019 PolyBase with SQL Server 2022 S3 integration.

**Answer:** SQL Server 2019 expanded PolyBase beyond Hadoop to support Oracle, Teradata, MongoDB, and generic ODBC sources through external tables. This enables data virtualization -- querying remote data without moving it. SQL Server 2022's S3 integration is complementary but different: it allows SQL Server to directly read and write to S3-compatible object storage for backup/restore operations and for querying Parquet files via OPENROWSET. While PolyBase focuses on federated querying across heterogeneous data sources, S3 integration focuses on storage flexibility and interoperability with the data lake ecosystem. Together, they position SQL Server 2022 as a hub that can reach into virtually any data source or storage tier.

---

## Tips for Interview Success

1. **Know the compatibility level story.** Every IQP feature maps to a specific compatibility level. Be able to articulate that you can migrate to a newer SQL Server version while keeping the old compat level, then upgrade incrementally to unlock IQP features one tier at a time.

2. **Emphasize "automatic" improvements.** The theme of IQP is zero-code-change performance gains. Interviewers want to hear that you understand when NOT to write custom code because the engine handles it automatically.

3. **Understand the trade-offs.** ADR adds PVS space overhead. Scalar UDF inlining requires SCHEMABINDING and has restrictions. PSP does not solve all parameter sniffing. Showing awareness of limitations demonstrates depth.

4. **Connect features to real scenarios.** Do not just list features. Say "I would use ADR for our nightly ETL because we have a 2-hour batch insert that, if rolled back, blocks the database for 45 minutes under traditional recovery."

5. **Know what was deprecated or removed.** Big Data Clusters were introduced in 2019 and retired before 2022. Mentioning awareness of the lifecycle shows you track the platform holistically.

6. **Be ready to demo Query Store Hints.** This is a practical, high-impact feature that interviewers love asking about because it solves the age-old problem of "how do you fix a bad plan without changing app code."

7. **Highlight cloud-connected features.** SQL Server 2022 leans heavily into cloud connectivity (Synapse Link, S3 integration, Azure AD auth, MI Link). This shows you understand Microsoft's hybrid strategy.

---
