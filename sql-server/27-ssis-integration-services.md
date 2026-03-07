# SSIS (SQL Server Integration Services)

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [What is SSIS?](#what-is-ssis)
2. [SSIS Architecture](#ssis-architecture)
3. [Control Flow vs Data Flow](#control-flow-vs-data-flow)
4. [Package Design](#package-design)
5. [Common Transformations](#common-transformations)
6. [Connection Managers](#connection-managers)
7. [Variables and Expressions](#variables-and-expressions)
8. [Event Handlers](#event-handlers)
9. [Error Handling and Logging](#error-handling-and-logging)
10. [Package Deployment Models](#package-deployment-models)
11. [SSIS Catalog (SSISDB)](#ssis-catalog-ssisdb)
12. [Environment Variables](#environment-variables)
13. [Performance Tuning SSIS](#performance-tuning-ssis)
14. [Incremental Loading Patterns](#incremental-loading-patterns)
15. [SSIS vs Alternatives](#ssis-vs-alternatives)
16. [Common Interview Questions](#common-interview-questions)
17. [Tips](#tips)

---

## What is SSIS?

SQL Server Integration Services (SSIS) is Microsoft's enterprise-grade ETL (Extract, Transform, Load) platform for data integration, data migration, and workflow automation. It ships with SQL Server and is developed using SQL Server Data Tools (SSDT) within Visual Studio.

SSIS is used for:

- **Data warehousing** -- extracting data from disparate sources, transforming it, and loading it into a data warehouse.
- **Data migration** -- moving data between systems during upgrades, platform changes, or consolidation.
- **Data cleansing** -- standardizing, deduplicating, and validating data.
- **Workflow automation** -- orchestrating file operations, email notifications, SQL maintenance tasks, and more.

---

## SSIS Architecture

SSIS has a layered architecture with several key components:

### Core Components

| Component | Description |
|-----------|-------------|
| **SSIS Runtime (Control Flow Engine)** | Manages package execution, enforces task ordering via precedence constraints, handles event propagation, logging, breakpoints, and transactions. |
| **Data Flow Engine (Pipeline Engine)** | Manages the in-memory movement and transformation of data. Operates on buffers for high throughput. |
| **SSIS Object Model** | Programmatic API for creating, modifying, and executing packages (managed code). |
| **SSIS Service** | Windows service that manages storage and monitoring of packages (primarily for legacy package deployment model). |
| **SSIS Catalog (SSISDB)** | SQL Server database that stores deployed projects, manages execution, and provides built-in reporting (project deployment model). |

### Execution Architecture

```
Package Execution Flow:
+---------------------------------------------------+
|  SSIS Runtime (Control Flow Engine)               |
|  - Validates package                              |
|  - Resolves variables and expressions             |
|  - Executes tasks per precedence constraints      |
|                                                    |
|   +---------------------------------------------+ |
|   | Data Flow Task (Pipeline Engine)             | |
|   | - Source adapters read data into buffers      | |
|   | - Transformations operate on buffer rows      | |
|   | - Destination adapters write buffer data      | |
|   | - Uses execution trees and buffer management  | |
|   +---------------------------------------------+ |
+---------------------------------------------------+
```

### Buffer Architecture in the Data Flow

The Data Flow Engine uses an in-memory buffer-based architecture:

- Data is read from sources into **buffers** (blocks of rows in memory).
- Each buffer has a fixed row count determined by `DefaultBufferMaxRows` and a maximum size determined by `DefaultBufferSize`.
- Transformations operate on rows within these buffers.
- **Synchronous transformations** operate on existing buffers in-place (row by row, no new buffer allocation).
- **Asynchronous transformations** create new output buffers (e.g., Sort, Aggregate) and can block execution until all input is received.

---

## Control Flow vs Data Flow

This is one of the most fundamental distinctions in SSIS and a very common interview topic.

### Control Flow

The Control Flow is the **orchestration layer** of a package. It defines the workflow -- what tasks to execute and in what order.

- Contains **tasks** (units of work) and **containers** (grouping/looping constructs).
- Tasks are connected via **precedence constraints** (success, failure, completion, or expression-based).
- Executes tasks **sequentially or in parallel** based on constraint topology.
- Does NOT move data row-by-row; it manages the overall process.

**Common Control Flow Tasks:**

| Task | Purpose |
|------|---------|
| Data Flow Task | Hosts the data flow pipeline |
| Execute SQL Task | Runs SQL statements or stored procedures |
| Script Task | Runs custom C# or VB.NET code |
| File System Task | Copy, move, delete files and directories |
| Send Mail Task | Sends email notifications |
| Execute Package Task | Calls another SSIS package |
| Foreach Loop Container | Iterates over a collection (files, ADO recordsets, etc.) |
| For Loop Container | Iterates based on a counter/condition |
| Sequence Container | Groups tasks for organization, transactions, or shared scoping |
| Execute Process Task | Runs an external program or script |
| FTP Task | Transfers files via FTP |
| Expression Task | Evaluates an expression and assigns the result to a variable |

### Data Flow

The Data Flow is the **data movement and transformation layer**. It exists inside a Data Flow Task in the control flow.

- Contains **sources**, **transformations**, and **destinations**.
- Data moves through the pipeline as **rows in memory buffers**.
- Operates at the row and column level.
- Supports parallel execution paths within a single data flow.

**Key Difference Summary:**

| Aspect | Control Flow | Data Flow |
|--------|-------------|-----------|
| Scope | Package-level workflow | Row-level data movement |
| Connects | Tasks via precedence constraints | Components via data paths |
| Granularity | Task-level | Row and column level |
| Purpose | Orchestration | ETL transformation |
| Parallelism | Independent tasks can run in parallel | Multiple paths within pipeline run concurrently |

---

## Package Design

### Package Structure

A well-designed SSIS package follows a clear structure:

```
Package
├── Connection Managers (shared connections)
├── Variables (package-scoped, task-scoped)
├── Parameters (project or package level)
├── Event Handlers (OnError, OnPreExecute, etc.)
├── Control Flow
│   ├── Sequence Container: "Initialize"
│   │   ├── Execute SQL Task: "Truncate Staging"
│   │   └── Expression Task: "Set RunDate"
│   ├── Sequence Container: "Extract and Load"
│   │   ├── Data Flow Task: "Load Customers"
│   │   └── Data Flow Task: "Load Orders"
│   └── Sequence Container: "Post-Process"
│       ├── Execute SQL Task: "Merge to Dimension"
│       └── Send Mail Task: "Notify Completion"
└── Data Flow (inside Data Flow Tasks)
    ├── OLE DB Source
    ├── Derived Column Transformation
    ├── Lookup Transformation
    └── OLE DB Destination
```

### Design Best Practices

1. **Use Sequence Containers** to logically group related tasks.
2. **Parameterize everything** -- server names, database names, file paths, dates.
3. **Separate staging from transformation** -- load raw data first, then transform.
4. **Keep data flows focused** -- one data flow per logical entity (customers, orders, etc.).
5. **Use a master/parent package** to orchestrate child packages via Execute Package Task.
6. **Use consistent naming conventions** (e.g., `DFT_LoadCustomers`, `ESQLT_TruncateStaging`, `FELC_ProcessFiles`).

### Common Naming Convention Prefixes

| Prefix | Component |
|--------|-----------|
| DFT | Data Flow Task |
| ESQLT | Execute SQL Task |
| SCR | Script Task / Script Component |
| FSYS | File System Task |
| FLC | For Loop Container |
| FELC | Foreach Loop Container |
| SEQC | Sequence Container |
| EPKG | Execute Package Task |
| SMT | Send Mail Task |

---

## Common Transformations

### Lookup Transformation

Used to enrich data by joining input rows with a reference dataset (typically a database table). This is the most performance-critical and frequently used transformation.

**Use Cases:** Surrogate key lookup in data warehousing, data enrichment, data validation.

**Cache Modes:**

| Mode | Description | When to Use |
|------|-------------|-------------|
| Full Cache (default) | Loads entire reference table into memory before processing | Reference table fits in memory; best performance |
| Partial Cache | Caches rows as they are looked up (LRU eviction) | Reference table too large for memory; many repeated lookups |
| No Cache | Queries the database for every input row | Reference table changes during execution; small input set |

```sql
-- Example: Lookup to get surrogate key for a dimension
-- Reference query for the Lookup transformation:
SELECT CustomerBusinessKey, CustomerSK
FROM dw.DimCustomer
WHERE IsCurrent = 1;

-- The Lookup matches input column [CustomerID] to reference column [CustomerBusinessKey]
-- and returns [CustomerSK] to add to the pipeline.
```

**Handling No-Match Rows:**

Configure the Lookup's error output:
- **Redirect rows to no match output** -- most common; send unmatched rows to a separate path (e.g., insert new dimension members).
- **Ignore failure** -- NULL is returned for lookup columns; continue processing.
- **Fail component** -- default; package fails on first no-match.

### Derived Column Transformation

Creates new columns or replaces existing columns using SSIS expressions.

**Use Cases:** Data type conversions, string manipulation, calculated fields, NULL handling.

```
-- SSIS Expression Examples inside Derived Column:

-- Trim and uppercase a name
UPPER(TRIM(CustomerName))

-- Create a full name from parts
FirstName + " " + LastName

-- Handle NULLs with conditional
ISNULL(MiddleName) ? "" : MiddleName

-- Format a date as string
(DT_WSTR, 10)(DATEPART("yyyy", OrderDate)) + "-" +
RIGHT("0" + (DT_WSTR, 2)(DATEPART("mm", OrderDate)), 2) + "-" +
RIGHT("0" + (DT_WSTR, 2)(DATEPART("dd", OrderDate)), 2)

-- Cast data types
(DT_DECIMAL, 2)SalesAmount

-- Current timestamp
GETDATE()
```

### Conditional Split Transformation

Routes rows to different outputs based on Boolean conditions. Similar to a CASE statement or series of IF/ELSE checks.

```
-- Conditional Split conditions:

Output Name: "HighValue"
Condition:   SalesAmount > 10000

Output Name: "MediumValue"
Condition:   SalesAmount > 1000 && SalesAmount <= 10000

Output Name: "LowValue"
Condition:   SalesAmount <= 1000

Default Output: "UnclassifiedRows"
```

**Real-World Example:** Route incoming order records to different staging tables based on region, or split error records from valid records.

### Union All Transformation

Combines rows from multiple inputs into a single output. This is the SSIS equivalent of SQL `UNION ALL`.

- Does **not** remove duplicates (use Sort + script or Aggregate for that).
- Columns are matched by position or mapping.
- **Synchronous** transformation -- very fast, no blocking.

### Merge Join Transformation

Performs INNER, LEFT, or FULL OUTER joins between two **sorted** inputs.

**Requirements:**
- Both inputs MUST be sorted on the join key(s).
- The `IsSorted` property must be set to `True` on both inputs.
- Sort key columns must have `SortKeyPosition` property set.

```
-- To use Merge Join:
-- 1. Sort both inputs by the join key (use Sort transformation or ORDER BY in source query)
-- 2. Connect the sorted inputs to Merge Join
-- 3. Configure join type (Inner, Left Outer, Full Outer)
-- 4. Map join columns and select output columns

-- Prefer ORDER BY in the source query over the Sort transformation for performance:
SELECT CustomerID, CustomerName, Region
FROM Customers
ORDER BY CustomerID;  -- Sort at the source
```

### Sort Transformation

Sorts data on one or more columns, optionally removing duplicate rows.

**Warning:** The Sort transformation is **asynchronous** -- it blocks the pipeline until ALL rows are read into memory, then sorts and releases. This can be a major performance bottleneck.

**Best Practice:** Whenever possible, sort at the source using `ORDER BY` in the SQL query, and set the `IsSorted` and `SortKeyPosition` properties on the output. This avoids the in-memory sort.

### Aggregate Transformation

Performs aggregate operations (SUM, AVG, COUNT, MIN, MAX, COUNT DISTINCT, GROUP BY).

- **Asynchronous** transformation -- buffers all input before producing output.
- Supports multiple aggregate outputs from a single component.
- Configure `KeyScale` and `CountDistinctScale` hints for memory optimization.

```
-- Equivalent of:
SELECT Region, ProductCategory,
       SUM(SalesAmount) AS TotalSales,
       COUNT(*) AS OrderCount
FROM SalesData
GROUP BY Region, ProductCategory;
```

### Other Important Transformations

| Transformation | Type | Description |
|---------------|------|-------------|
| Multicast | Synchronous | Sends every row to multiple outputs (data duplication) |
| OLE DB Command | Synchronous | Executes a SQL command per row (slow; avoid for large datasets) |
| Script Component | Either | Custom C#/VB.NET logic as source, transformation, or destination |
| Data Conversion | Synchronous | Converts column data types |
| Row Count | Synchronous | Counts rows passing through and stores in a variable |
| Slowly Changing Dimension | Synchronous | Wizard-based SCD handling (avoid in production; use custom logic) |
| Fuzzy Lookup | Asynchronous | Approximate matching using fuzzy logic |
| Pivot / Unpivot | Synchronous | Rotates rows to columns and vice versa |

---

## Connection Managers

Connection managers define how SSIS connects to external systems. They are reusable across tasks and data flows within a package or project.

### Common Connection Manager Types

| Type | Use Case |
|------|----------|
| OLE DB | SQL Server, Oracle, other OLE DB providers -- most common for relational databases |
| ADO.NET | .NET provider-based connections; useful for newer drivers |
| Flat File | CSV, fixed-width, delimited text files |
| Excel | Excel workbook files (.xls, .xlsx) |
| ODBC | ODBC driver-based connections |
| SMTP | Email server connections for Send Mail Task |
| FTP | FTP server connections |
| HTTP | HTTP endpoints for web service calls |
| MSOLAP | Analysis Services connections |

### Project-Level vs Package-Level Connection Managers

- **Project-level** connection managers are shared across all packages in a project (shown with `(project)` suffix in SSDT). Use these for common connections.
- **Package-level** connection managers are scoped to a single package.

### Parameterizing Connection Managers

Connection strings should never be hardcoded. Use expressions or parameters:

```
-- Using an expression on the ConnectionString property:
"Data Source=" + @[$Project::ServerName] +
";Initial Catalog=" + @[$Project::DatabaseName] +
";Provider=SQLNCLI11.1;Integrated Security=SSPI;"

-- Or use project parameters mapped via SSIS Catalog environments
```

---

## Variables and Expressions

### Variables

Variables store values at runtime and can be scoped to the package, container, task, or event handler.

| Property | Description |
|----------|-------------|
| Name | Variable identifier |
| Scope | Where the variable is visible (package, container, task) |
| Data Type | Boolean, Byte, Char, DateTime, Decimal, Double, Int16, Int32, Int64, Object, SByte, Single, String, UInt32, UInt64 |
| Value | Current value |
| EvaluateAsExpression | If True, the Value is computed from the Expression property |

**System Variables** (read-only, provided by SSIS runtime):

| Variable | Description |
|----------|-------------|
| `System::PackageName` | Name of the executing package |
| `System::StartTime` | Package start time |
| `System::ExecutionInstanceGUID` | Unique ID for this execution |
| `System::TaskName` | Current task name |
| `System::ContainerStartTime` | Current container's start time |
| `System::MachineName` | Machine where package runs |
| `System::UserName` | User running the package |

### Expressions

SSIS expressions are used in Derived Column transformations, variable evaluation, precedence constraints, and property expressions.

```
-- Common Expression Functions:

-- String functions
UPPER("hello")           -- "HELLO"
LOWER("HELLO")           -- "hello"
TRIM(" text ")           -- "text"
LEN("hello")             -- 5
SUBSTRING("hello", 1, 3) -- "hel"
REPLACE("abc", "b", "x") -- "axc"
FINDSTRING("hello world", "world", 1) -- 7

-- Date functions
GETDATE()                           -- current datetime
DATEADD("dd", -1, GETDATE())       -- yesterday
DATEPART("yyyy", GETDATE())        -- current year
DATEDIFF("dd", StartDate, EndDate) -- days between

-- Null handling
ISNULL(ColumnName)                  -- returns Boolean
REPLACENULL(ColumnName, "default") -- replaces NULL with value (SQL 2012+)

-- Type casting
(DT_STR, 50, 1252)IntColumn        -- int to string
(DT_I4)"123"                       -- string to int
(DT_DBTIMESTAMP)"2026-01-15"       -- string to datetime

-- Conditional (ternary)
Condition ? TrueValue : FalseValue
SalesAmount > 1000 ? "High" : "Low"
```

### Property Expressions

Property expressions dynamically set task and component properties at runtime:

```
-- Dynamic file path using a variable:
-- Set on Flat File Connection Manager's ConnectionString property:
@[User::FolderPath] + "\\Export_" +
(DT_WSTR, 4)(DATEPART("yyyy", GETDATE())) +
RIGHT("0" + (DT_WSTR, 2)(DATEPART("mm", GETDATE())), 2) +
RIGHT("0" + (DT_WSTR, 2)(DATEPART("dd", GETDATE())), 2) + ".csv"
-- Result: C:\Data\Export_20260307.csv
```

---

## Event Handlers

Event handlers allow you to execute tasks in response to specific events raised during package execution. They are configured per executable (package, container, or task).

### Available Events

| Event | When Fired |
|-------|------------|
| OnPreExecute | Before a task/container begins execution |
| OnPostExecute | After a task/container finishes execution |
| OnPreValidate | Before validation of a task/container |
| OnPostValidate | After validation of a task/container |
| OnError | When an error occurs |
| OnWarning | When a warning occurs |
| OnInformation | When an informational message is raised |
| OnProgress | When progress is updated (data flow rows processed) |
| OnTaskFailed | When a task fails (fires after OnError) |
| OnVariableValueChanged | When a variable value changes (must enable RaiseChangedEvent on the variable) |
| OnQueryCancel | When the execution can be cancelled |

### Real-World Event Handler Example

```
-- OnError Event Handler pattern:
-- 1. Execute SQL Task: Log error details to an audit table

INSERT INTO dbo.ETL_ErrorLog
    (PackageName, TaskName, ErrorCode, ErrorDescription, ErrorTime)
VALUES
    (?, ?, ?, ?, GETDATE());

-- Parameter mappings:
-- Parameter 0 -> System::PackageName
-- Parameter 1 -> System::SourceName
-- Parameter 2 -> System::ErrorCode
-- Parameter 3 -> System::ErrorDescription

-- 2. Send Mail Task: Notify the team about the failure
```

---

## Error Handling and Logging

### Error Handling Strategies

**1. Data Flow Error Outputs**

Every data flow component has an error output. For each column, you can configure:

- **Fail Component** (default) -- stops the pipeline on error.
- **Redirect Row** -- sends the error row to a separate output path for logging/investigation.
- **Ignore Failure** -- discards the error and continues (use with caution).

```
-- Common pattern: Redirect error rows to an error table
-- Error output automatically includes:
--   ErrorCode (int) -- SSIS error code
--   ErrorColumn (int) -- lineage ID of the column that caused the error

-- Use a Script Component to convert these to readable descriptions:
-- Row.ErrorDescription = ComponentMetaData.GetErrorDescription(Row.ErrorCode);
-- Row.ErrorColumnName = /* resolve lineage ID to column name */
```

**2. Control Flow Error Handling**

- Use **Failure precedence constraints** (red connector) to route execution on failure.
- Use **Event Handlers (OnError, OnTaskFailed)** for centralized error handling.
- Use **Checkpoints** to enable package restart from the point of failure.

**3. Checkpoint Files**

```
-- Package Properties for checkpoints:
-- CheckpointFileName: C:\SSIS\Checkpoints\MyPackage.chk
-- CheckpointUsage: IfExists (or Always)
-- SaveCheckpoints: True

-- Each task's FailPackageOnFailure must be True for it to be a checkpoint target.
-- On restart, completed tasks are skipped; execution resumes from the failed task.
```

### Logging

**Built-in SSIS Log Providers:**

| Provider | Destination |
|----------|-------------|
| SSIS Log Provider for SQL Server | SQL Server table (sysssislog) |
| SSIS Log Provider for Windows Event Log | Windows Event Log |
| SSIS Log Provider for Text Files | Flat text file |
| SSIS Log Provider for XML Files | XML file |
| SSIS Log Provider for SQL Server Profiler | Trace file (.trc) |

**SSISDB Catalog Logging (Project Deployment Model):**

With the project deployment model, logging is built into the SSISDB catalog. Configure the logging level at execution:

| Level | Detail |
|-------|--------|
| None | No logging |
| Basic | Minimal events -- start, end, errors, warnings |
| Performance | Data flow performance statistics |
| Verbose | All events including custom messages |
| RuntimeLineage | Data lineage tracking (SQL 2016+) |

```sql
-- Query SSISDB execution logs:
SELECT
    e.execution_id,
    e.folder_name,
    e.project_name,
    e.package_name,
    e.status,          -- 1=Created, 2=Running, 3=Cancelled, 4=Failed, 7=Succeeded
    e.start_time,
    e.end_time,
    DATEDIFF(SECOND, e.start_time, e.end_time) AS duration_seconds
FROM catalog.executions e
ORDER BY e.execution_id DESC;

-- Query error messages from a specific execution:
SELECT
    om.message_time,
    om.message_source_name,
    om.message_type,   -- 120=Error, 110=Warning, 70=Info
    om.message
FROM catalog.operation_messages om
WHERE om.operation_id = @execution_id
  AND om.message_type = 120   -- Errors only
ORDER BY om.message_time;

-- Query data flow performance statistics:
SELECT
    es.execution_id,
    es.package_name,
    es.task_name,
    es.dataflow_path_name,
    es.source_component_name,
    es.destination_component_name,
    es.rows_sent,
    es.created_time
FROM catalog.execution_data_statistics es
WHERE es.execution_id = @execution_id;
```

---

## Package Deployment Models

SSIS supports two deployment models. Understanding the differences is critical for interviews.

### Package Deployment Model (Legacy)

- Packages are deployed **individually** to MSDB database or file system.
- Configuration via **XML config files**, **SQL Server table**, **environment variables**, **registry entries**, or **parent package variables**.
- Managed by the SSIS Service.
- Execution via `dtexec`, SQL Server Agent, or `dtutil`.

### Project Deployment Model (Recommended, SQL 2012+)

- The entire project (`.ispac` file) is deployed as a unit to the **SSIS Catalog (SSISDB)**.
- Configuration via **project and package parameters** with **environment variables**.
- Built-in execution logging, versioning, and security.
- Execution via SSISDB stored procedures, SQL Server Agent, or SSDT.

### Comparison

| Feature | Package Model | Project Model |
|---------|--------------|---------------|
| Deployment unit | Individual package | Entire project |
| Configuration | XML configs, SQL table, etc. | Parameters + Environments |
| Logging | Must configure manually | Built-in via SSISDB |
| Versioning | Manual | Automatic (previous versions stored) |
| Security | File/MSDB permissions | SSISDB catalog roles and permissions |
| Execution | dtexec, SQL Agent | catalog.start_execution, SQL Agent |
| Recommended | Legacy only | Yes -- all new development |

---

## SSIS Catalog (SSISDB)

The SSIS Catalog is a SQL Server database (`SSISDB`) that serves as the central management point for the project deployment model.

### Setting Up SSISDB

```sql
-- SSISDB is created via SSMS: right-click "Integration Services Catalogs" -> "Create Catalog"
-- Or via T-SQL (requires CLR integration):

-- Enable CLR
EXEC sp_configure 'clr enabled', 1;
RECONFIGURE;

-- The catalog creation requires a master encryption key password
-- (protects sensitive parameters and connection strings)
```

### SSISDB Hierarchy

```
SSISDB
├── Folders
│   ├── Projects
│   │   ├── Packages
│   │   └── Project Parameters
│   └── Environments
│       └── Environment Variables
```

### Key SSISDB Stored Procedures

```sql
-- Deploy a project (usually done via SSDT or PowerShell, but can be T-SQL):
DECLARE @project_binary VARBINARY(MAX);
-- Load .ispac file into @project_binary
EXEC catalog.deploy_project
    @folder_name = N'ETL',
    @project_name = N'SalesETL',
    @project_stream = @project_binary;

-- Create an execution instance:
DECLARE @execution_id BIGINT;
EXEC catalog.create_execution
    @folder_name = N'ETL',
    @project_name = N'SalesETL',
    @package_name = N'LoadCustomers.dtsx',
    @reference_id = NULL,           -- environment reference, or NULL
    @execution_id = @execution_id OUTPUT;

-- Set a parameter override:
EXEC catalog.set_execution_parameter_value
    @execution_id = @execution_id,
    @object_type = 30,              -- 30 = package parameter, 20 = project parameter
    @parameter_name = N'BatchDate',
    @parameter_value = '2026-03-07';

-- Set the logging level:
EXEC catalog.set_execution_parameter_value
    @execution_id = @execution_id,
    @object_type = 50,              -- 50 = system parameter
    @parameter_name = N'LOGGING_LEVEL',
    @parameter_value = 1;           -- 0=None, 1=Basic, 2=Performance, 3=Verbose

-- Start execution:
EXEC catalog.start_execution @execution_id = @execution_id;
```

---

## Environment Variables

Environments in the SSIS Catalog provide a way to externalize configuration values (server names, file paths, credentials) and vary them across deployment targets (Dev, QA, Prod).

### Setting Up Environments

```sql
-- Create an environment
EXEC catalog.create_environment
    @folder_name = N'ETL',
    @environment_name = N'Production';

-- Add variables to the environment
EXEC catalog.create_environment_variable
    @folder_name = N'ETL',
    @environment_name = N'Production',
    @variable_name = N'SourceServer',
    @data_type = N'String',
    @sensitive = 0,
    @value = N'PRODSQL01';

EXEC catalog.create_environment_variable
    @folder_name = N'ETL',
    @environment_name = N'Production',
    @variable_name = N'DBPassword',
    @data_type = N'String',
    @sensitive = 1,                 -- encrypted at rest
    @value = N'P@ssw0rd!';

-- Create a reference from the project to the environment
EXEC catalog.create_environment_reference
    @folder_name = N'ETL',
    @project_name = N'SalesETL',
    @environment_name = N'Production',
    @reference_type = R;            -- R = relative (same folder), A = absolute

-- Map project/package parameters to environment variables via SSMS GUI
-- or by setting parameter values to reference environment variables
```

### Multi-Environment Pattern

```
Folder: ETL
├── Project: SalesETL
│   ├── Parameter: SourceServer (mapped to environment variable)
│   ├── Parameter: TargetServer (mapped to environment variable)
│   └── Parameter: FilePath (mapped to environment variable)
├── Environment: Development
│   ├── SourceServer = DEVSQL01
│   ├── TargetServer = DEVSQL01
│   └── FilePath = C:\Dev\Data\
├── Environment: QA
│   ├── SourceServer = QASQL01
│   ├── TargetServer = QASQL01
│   └── FilePath = \\QAShare\Data\
└── Environment: Production
    ├── SourceServer = PRODSQL01
    ├── TargetServer = PRODDW01
    └── FilePath = \\ProdShare\Data\
```

---

## Performance Tuning SSIS

### Data Flow Performance

**1. Buffer Tuning**

```
-- Key Data Flow Task properties:
DefaultBufferSize     -- Max buffer size in bytes (default: 10 MB)
DefaultBufferMaxRows  -- Max rows per buffer (default: 10,000)
EngineThreads         -- Threads for pipeline execution (default: 10)

-- Increase DefaultBufferSize for wide rows (many columns)
-- Increase DefaultBufferMaxRows for narrow rows (few columns)
-- Monitor BufferSizeTuning event to see actual buffer allocation
```

**2. Prefer Synchronous Over Asynchronous Transformations**

- Synchronous transformations (Derived Column, Conditional Split, Lookup with Full Cache) reuse existing buffers -- fast.
- Asynchronous transformations (Sort, Aggregate, Merge Join) require full data copy to new buffers -- slow.
- Avoid the Sort transformation; sort at the source with `ORDER BY`.

**3. Optimize Lookups**

- Use **Full Cache** mode when the reference table fits in memory.
- Filter the reference query to only needed columns and rows.
- Use SQL cache connection manager for shared lookup caches across packages.
- Index the lookup source table on the join key.

**4. Source Query Optimization**

```sql
-- Use SQL command instead of Table/View mode for sources:
-- This allows column pruning (select only needed columns)
SELECT CustomerID, CustomerName, Region
FROM dbo.Customers WITH (NOLOCK)
WHERE ModifiedDate >= ?;
-- Use parameterized queries to reduce data volume
```

**5. Destination Optimization**

- Use **OLE DB Destination** with "Fast Load" (bulk insert) mode.
- Set `FastLoadOptions`: `TABLOCK, CHECK_CONSTRAINTS OFF, FIRE_TRIGGERS OFF`.
- Increase `MaximumInsertCommitSize` (0 = single commit at end; set to 0 for best performance if you can rerun on failure).
- Drop indexes before load, rebuild after (for large loads).

**6. Parallel Execution**

- Set `MaxConcurrentExecutables` at the package level (default: -1, meaning number of processors + 2).
- Use multiple Data Flow Tasks in parallel when loading independent tables.
- Within a data flow, independent paths execute concurrently.

### General Performance Tips

```
-- 1. Network: Keep SSIS server close to data sources/destinations
-- 2. Staging: Use staging tables to break complex ETL into simple steps
-- 3. Data types: Use appropriate data types; avoid unnecessary DT_WSTR when DT_STR suffices
-- 4. Logging: Use Basic logging level in production (Verbose is expensive)
-- 5. Memory: Monitor memory usage; 64-bit runtime supports more memory than 32-bit
-- 6. Avoid: Row-by-row operations (OLE DB Command); use set-based SQL when possible
```

---

## Incremental Loading Patterns

Incremental loading is essential for efficient ETL -- loading only new or changed data rather than full reloads.

### Pattern 1: Change Tracking Column (Most Common)

```sql
-- Source table has a ModifiedDate or RowVersion column
-- Store the last loaded value and use it as a filter

-- Step 1: Get the last loaded watermark
-- Execute SQL Task:
SELECT MAX(LastLoadedDate) AS Watermark
FROM dbo.ETL_Control
WHERE PackageName = 'LoadCustomers';
-- Store result in variable: @[User::LastWatermark]

-- Step 2: Extract only changed rows
-- OLE DB Source:
SELECT CustomerID, CustomerName, Email, ModifiedDate
FROM source.dbo.Customers
WHERE ModifiedDate > ?;
-- Parameter: @[User::LastWatermark]

-- Step 3: Update watermark after successful load
-- Execute SQL Task:
UPDATE dbo.ETL_Control
SET LastLoadedDate = GETDATE()
WHERE PackageName = 'LoadCustomers';
```

### Pattern 2: Change Data Capture (CDC)

```sql
-- SQL Server CDC tracks INSERT, UPDATE, DELETE operations
-- SSIS has built-in CDC components (SQL 2012+):

-- CDC Source: Reads changes from CDC tables
-- CDC Splitter: Splits change rows by operation type (Insert, Update, Delete)

-- Process:
-- 1. CDC Control Task: Get processing range (LSN-based)
-- 2. Data Flow: CDC Source -> CDC Splitter
--    -> Inserts go to insert destination
--    -> Updates go to OLE DB Command (UPDATE) or staging
--    -> Deletes go to OLE DB Command (DELETE) or soft-delete
-- 3. CDC Control Task: Mark processing range as complete
```

### Pattern 3: Timestamp with Merge

```sql
-- Combine incremental extract with T-SQL MERGE for upsert logic

-- Data Flow: Load incremental changes into staging table
-- Execute SQL Task: MERGE from staging into target

MERGE dbo.DimCustomer AS target
USING dbo.Staging_Customer AS source
    ON target.CustomerBusinessKey = source.CustomerID
WHEN MATCHED AND (
    target.CustomerName <> source.CustomerName OR
    target.Email <> source.Email
) THEN
    UPDATE SET
        target.CustomerName = source.CustomerName,
        target.Email = source.Email,
        target.ModifiedDate = GETDATE()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CustomerBusinessKey, CustomerName, Email, CreatedDate)
    VALUES (source.CustomerID, source.CustomerName, source.Email, GETDATE());
```

### Pattern 4: Lookup-Based Insert/Update Split

```
-- In the Data Flow:
-- 1. Source: Extract new/changed rows from source
-- 2. Lookup: Match against destination on business key
--    - Match output -> Conditional Split (check if columns changed) -> OLE DB Command (UPDATE)
--    - No Match output -> OLE DB Destination (INSERT new rows)

-- This pattern avoids MERGE and works well in SSIS
-- but the OLE DB Command for updates is row-by-row (slow for large updates)
-- Better approach: load all changes to staging, then use T-SQL MERGE
```

---

## SSIS vs Alternatives

### SSIS vs Azure Data Factory (ADF)

| Aspect | SSIS | ADF |
|--------|------|-----|
| Deployment | On-premises (or Azure VM) | Cloud-native (Azure PaaS) |
| Development | Visual Studio (SSDT) | Azure Portal, VS Code (ARM/Bicep) |
| Transformations | Rich in-memory transformations | Copy Activity + Data Flows (Spark-based), or call external compute |
| Data volume | Single-server bound | Scales across cloud compute |
| Cost | SQL Server license | Pay-per-use (pipeline runs, DIU) |
| Scheduling | SQL Server Agent | Built-in triggers (schedule, tumbling window, event-based) |
| Connectivity | OLE DB, ODBC, Flat File, etc. | 100+ native connectors (SaaS, cloud, on-prem via IR) |
| Hybrid | N/A | Integration Runtime supports on-prem via Self-Hosted IR; can run SSIS packages via Azure-SSIS IR |
| Monitoring | SSISDB catalog | Azure Monitor, built-in dashboards |
| Version control | File-based, integrate with Git manually | Native Git integration (GitHub, Azure DevOps) |
| Best for | On-prem SQL Server workloads, complex row-level transformations | Cloud-first architectures, hybrid scenarios, orchestration at scale |

### SSIS vs Informatica PowerCenter

| Aspect | SSIS | Informatica |
|--------|------|-------------|
| Licensing | Included with SQL Server | Separate (expensive) license |
| Platform | Windows/SQL Server only | Cross-platform (Windows, Linux, cloud) |
| Source support | Primarily Microsoft stack | Broad heterogeneous support |
| Metadata management | SSISDB | Informatica Metadata Manager |
| Reusability | Package/project reuse | Mapplets, reusable transformations |
| Enterprise features | Good | Advanced (pushdown optimization, grid computing, data quality) |
| Best for | Microsoft-centric shops | Large enterprise, heterogeneous environments |

### SSIS vs Python/PySpark ETL

| Aspect | SSIS | Python/PySpark |
|--------|------|---------------|
| Development | GUI-based (drag and drop) | Code-based (scripts) |
| Flexibility | Constrained by available components | Unlimited (any library/API) |
| Performance | Good for SQL Server workloads | Excellent for distributed big data (Spark) |
| Testing | Limited unit testing | Full unit testing frameworks (pytest) |
| Version control | XML-based .dtsx files (merge conflicts) | Clean text files (easy Git diffs) |
| Learning curve | Low (GUI) | Higher (coding required) |
| Best for | Traditional SQL Server ETL | Modern data engineering, big data, ML pipelines |

---

## Common Interview Questions

### Q1: What is the difference between Control Flow and Data Flow in SSIS?

**A:** The Control Flow is the orchestration layer that manages the workflow of a package. It contains tasks connected by precedence constraints and determines what runs, in what order, and under what conditions. The Data Flow exists inside a Data Flow Task and handles row-level data movement. It contains sources, transformations, and destinations connected by data paths (pipelines) where data flows as rows in memory buffers. Control Flow operates at the task level; Data Flow operates at the row and column level.

### Q2: Explain the difference between synchronous and asynchronous transformations.

**A:** Synchronous transformations process rows in-place within existing buffers. Each input row produces zero or one output row, and no new buffer allocation is needed. Examples: Derived Column, Conditional Split, Lookup (Full Cache). They are fast and efficient.

Asynchronous transformations require new output buffers separate from the input buffers. They may need to consume all input before producing output (fully blocking, like Sort and Aggregate) or can produce output as input arrives (semi-blocking, like Merge Join). Asynchronous transformations are slower because they double memory usage and break the pipeline's streaming behavior.

### Q3: How do you handle errors in an SSIS data flow?

**A:** There are three approaches: (1) **Fail Component** -- the default; the pipeline stops on the first error. (2) **Redirect Row** -- error rows are sent to a separate error output path where they can be logged to an error table for investigation; this is the most common production approach. (3) **Ignore Failure** -- the error is discarded and processing continues. Error outputs include ErrorCode and ErrorColumn lineage ID, which can be translated to human-readable descriptions via a Script Component.

### Q4: What are the Lookup transformation cache modes and when would you use each?

**A:** Full Cache (default) pre-loads the entire reference dataset into memory before processing begins. Use it when the reference table fits in memory -- it provides the best performance. Partial Cache retrieves and caches rows on demand with LRU eviction. Use it when the reference table is too large for memory but many input rows match the same reference rows. No Cache queries the database for every input row. Use it only when the reference data changes during execution or the input dataset is very small.

### Q5: What is the difference between the Package Deployment Model and the Project Deployment Model?

**A:** The Package Deployment Model (legacy) deploys packages individually to MSDB or the file system, uses XML configuration files for parameterization, and requires manual logging configuration. The Project Deployment Model (recommended since SQL 2012) deploys the entire project as an `.ispac` file to the SSISDB catalog, uses parameters and environment variables for configuration, provides built-in logging and execution reporting, automatic versioning, and granular security through catalog roles. New development should always use the Project Deployment Model.

### Q6: How would you implement incremental loading in SSIS?

**A:** The most common pattern uses a watermark column (e.g., ModifiedDate or RowVersion). Store the last successfully loaded watermark in a control table. At the start of each run, retrieve the watermark, use it to filter the source query to extract only rows changed since the last load, load them to a staging table, then use a MERGE statement or Lookup-based logic to insert new rows and update existing rows in the target. After success, update the watermark. Alternatives include Change Data Capture (CDC) with SSIS CDC components, and Change Tracking.

### Q7: How do you optimize SSIS performance for large data volumes?

**A:** Key strategies include: (1) Tune buffer sizes (`DefaultBufferSize` and `DefaultBufferMaxRows`). (2) Use synchronous transformations wherever possible; avoid the Sort transformation and sort at the source. (3) Use Full Cache Lookup with filtered reference queries. (4) Select only needed columns in source queries. (5) Use Fast Load (bulk insert) at destinations with `TABLOCK`. (6) Drop and rebuild indexes around large loads. (7) Parallelize independent data flows. (8) Run the 64-bit runtime for more memory. (9) Stage data and use set-based T-SQL operations instead of row-by-row transformations.

### Q8: How does SSIS handle transactions?

**A:** SSIS supports transactions at multiple levels. Each task and container has a `TransactionOption` property with three settings: **Required** (starts a new transaction or joins the parent's), **Supported** (joins the parent's transaction if one exists), and **NotSupported** (does not participate in any transaction). Transactions use the Microsoft Distributed Transaction Coordinator (MSDTC). A common pattern is to set a Sequence Container to `Required` and its child tasks to `Supported`, so all tasks in the container participate in a single transaction. If any task fails, the entire transaction rolls back.

### Q9: What is the SSIS Catalog and why is it important?

**A:** The SSIS Catalog (SSISDB) is a SQL Server database that serves as the central store for SSIS projects deployed using the Project Deployment Model. It provides: project and package storage with automatic versioning, parameter and environment variable management for multi-environment configuration, built-in execution logging with configurable verbosity levels (Basic, Performance, Verbose), execution reporting through catalog views, security through database roles, and stored procedures to programmatically execute and monitor packages. It replaces the need for external configuration files and custom logging infrastructure.

### Q10: Can you run SSIS packages in the cloud?

**A:** Yes. Azure Data Factory provides the **Azure-SSIS Integration Runtime**, which is a fully managed cluster of Azure VMs dedicated to running SSIS packages. You deploy your packages to an SSISDB hosted in Azure SQL Database or Azure SQL Managed Instance, and ADF orchestrates their execution. This is the lift-and-shift approach. Alternatively, you can run SSIS on a SQL Server instance in an Azure VM. For new cloud-native development, Microsoft recommends using ADF Data Flows or Mapping Data Flows instead of SSIS.

---

## Tips

1. **Master the fundamentals** -- Control Flow vs Data Flow, synchronous vs asynchronous, and buffer architecture are the topics that separate senior candidates from junior ones.

2. **Always recommend the Project Deployment Model** in interviews. If asked about the Package model, acknowledge it but position it as legacy.

3. **Know the SSISDB catalog views** -- `catalog.executions`, `catalog.operation_messages`, and `catalog.execution_data_statistics` are essential for demonstrating operational knowledge.

4. **Performance tuning questions are common** -- Have a clear, ordered approach: reduce data volume at the source, use synchronous transformations, tune buffers, use bulk load, parallelize.

5. **Understand the trade-offs** -- Know when SSIS is the right tool (on-prem SQL Server ETL) and when alternatives like ADF, Spark, or Python are better fits.

6. **Practice explaining Lookup configurations** -- Full Cache vs Partial Cache vs No Cache, and how to handle no-match rows. This is a very common interview deep-dive.

7. **Be ready to discuss incremental loading** -- This is one of the most practical and frequently asked topics. Have a clear pattern with watermarks, staging, and MERGE.

8. **Mention error handling proactively** -- Error output redirection, checkpoint files, and OnError event handlers show production experience.

9. **Version control challenges** -- SSIS `.dtsx` files are XML and notoriously hard to merge in Git. Mention this as a real-world pain point and discuss mitigation strategies (small packages, clear ownership, Biml for code generation).

10. **Biml (Business Intelligence Markup Language)** -- If you want to stand out, mention Biml as a way to generate SSIS packages programmatically from metadata, reducing manual effort and improving consistency across hundreds of packages.
