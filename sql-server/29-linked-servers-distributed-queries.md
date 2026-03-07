# Linked Servers & Distributed Queries

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Linked Servers Overview](#linked-servers-overview)
2. [Creating Linked Servers](#creating-linked-servers)
3. [Four-Part Naming](#four-part-naming)
4. [OPENQUERY](#openquery)
5. [OPENROWSET](#openrowset)
6. [OPENDATASOURCE](#opendatasource)
7. [Linked Server Security](#linked-server-security)
8. [Distributed Transactions (MSDTC)](#distributed-transactions-msdtc)
9. [Performance Considerations](#performance-considerations)
10. [Troubleshooting Linked Servers](#troubleshooting-linked-servers)
11. [Alternatives to Linked Servers](#alternatives-to-linked-servers)
12. [Common Interview Questions](#common-interview-questions)
13. [Tips](#tips)

---

## Linked Servers Overview

A linked server allows SQL Server to execute commands against OLE DB data sources on remote servers. This enables distributed queries, distributed transactions, and remote procedure calls across heterogeneous data sources.

### Key Components

- **OLE DB Provider** - The driver layer that translates SQL Server requests to the target data source format.
- **Linked Server Definition** - Metadata in `sys.servers` that maps a logical name to a remote server and provider.
- **Login Mappings** - Security configuration that maps local logins to remote credentials.
- **Four-Part Name** - The syntax `[LinkedServer].[Database].[Schema].[Object]` used to reference remote objects.

### Common Use Cases

- Querying data across SQL Server instances
- Accessing Oracle, MySQL, PostgreSQL, or other RDBMS from SQL Server
- Reading data from Excel files, Access databases, or flat files
- Cross-database reporting where replication is not warranted
- Data migration and one-time data transfers

---

## Creating Linked Servers

### Using sp_addlinkedserver

```sql
-- Link to another SQL Server instance
EXEC sp_addlinkedserver
    @server = N'REMOTE_SQL',                          -- Logical name
    @srvproduct = N'',                                -- Leave empty for SQL Server
    @provider = N'SQLNCLI11',                         -- SQL Server Native Client
    @datasrc = N'RemoteServerName\InstanceName';      -- Actual server address
GO

-- Link to an Oracle database
EXEC sp_addlinkedserver
    @server = N'ORACLE_PROD',
    @srvproduct = N'Oracle',
    @provider = N'OraOLEDB.Oracle',
    @datasrc = N'OracleServiceName';
GO

-- Link to a MySQL database via ODBC
EXEC sp_addlinkedserver
    @server = N'MYSQL_SERVER',
    @srvproduct = N'MySQL',
    @provider = N'MSDASQL',
    @provstr = N'DRIVER={MySQL ODBC 8.0 Unicode Driver};SERVER=mysql-host;DATABASE=mydb;';
GO

-- Link to an Excel file
EXEC sp_addlinkedserver
    @server = N'EXCEL_DATA',
    @srvproduct = N'Jet 4.0',
    @provider = N'Microsoft.ACE.OLEDB.12.0',
    @datasrc = N'C:\Data\Report.xlsx',
    @provstr = N'Excel 12.0;HDR=YES';
GO
```

### Using SSMS

1. Server Objects > Linked Servers > Right-click > New Linked Server
2. Configure the General page (server name, provider, data source)
3. Configure the Security page (login mappings)
4. Configure Server Options (RPC, RPC Out, etc.)

### Configuring Linked Server Options

```sql
-- Enable RPC and RPC Out (required for executing remote stored procedures)
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'rpc', @optvalue = N'true';
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'rpc out', @optvalue = N'true';

-- Enable distributed transactions
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'remote proc transaction promotion', @optvalue = N'true';

-- Set query timeout (0 = no timeout)
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'query timeout', @optvalue = N'600';

-- Set connection timeout
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'connect timeout', @optvalue = N'30';

-- Allow lazy schema validation (can improve performance)
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'lazy schema validation', @optvalue = N'true';

-- Use remote collation
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'use remote collation', @optvalue = N'true';
```

### Viewing and Managing Linked Servers

```sql
-- List all linked servers
SELECT * FROM sys.servers WHERE is_linked = 1;

-- List linked server logins
SELECT * FROM sys.linked_logins;

-- Drop a linked server and all its login mappings
EXEC sp_dropserver @server = N'REMOTE_SQL', @droplogins = 'droplogins';

-- Test the connection
EXEC sp_testlinkedserver N'REMOTE_SQL';
```

---

## Four-Part Naming

The standard way to reference objects on a linked server is using the four-part name:

```
[LinkedServerName].[DatabaseName].[SchemaName].[ObjectName]
```

### Examples

```sql
-- Query a table on a remote SQL Server
SELECT CustomerID, Name, Email
FROM [REMOTE_SQL].[SalesDB].[dbo].[Customers]
WHERE Region = 'West';

-- Join local and remote tables
SELECT
    o.OrderID,
    o.OrderDate,
    c.Name AS CustomerName
FROM dbo.Orders AS o
INNER JOIN [REMOTE_SQL].[SalesDB].[dbo].[Customers] AS c
    ON o.CustomerID = c.CustomerID
WHERE o.OrderDate >= '2026-01-01';

-- Execute a remote stored procedure (requires RPC Out enabled)
EXEC [REMOTE_SQL].[SalesDB].[dbo].[usp_GetCustomerOrders] @CustomerID = 1001;

-- INSERT into a remote table
INSERT INTO [REMOTE_SQL].[SalesDB].[dbo].[AuditLog] (EventType, EventDate, Details)
VALUES ('DataSync', GETDATE(), 'Sync completed from local server');
```

### Limitations of Four-Part Naming

- Query optimizer has limited ability to push predicates to the remote server.
- Statistics from the remote table are not always available locally, leading to suboptimal plans.
- Cannot use four-part names in some DDL statements.
- Performance can be poor for large result sets or complex joins.

---

## OPENQUERY

`OPENQUERY` executes a pass-through query on the linked server. The entire query string is sent to the remote server for execution, which typically results in better performance than four-part naming because filtering happens remotely.

```sql
-- Basic OPENQUERY
SELECT *
FROM OPENQUERY(REMOTE_SQL, 'SELECT CustomerID, Name, Email FROM SalesDB.dbo.Customers WHERE Region = ''West''');

-- Join OPENQUERY result with a local table
SELECT
    o.OrderID,
    o.OrderDate,
    remote_cust.Name
FROM dbo.Orders AS o
INNER JOIN OPENQUERY(REMOTE_SQL,
    'SELECT CustomerID, Name FROM SalesDB.dbo.Customers WHERE IsActive = 1'
) AS remote_cust
    ON o.CustomerID = remote_cust.CustomerID;

-- INSERT via OPENQUERY
INSERT INTO OPENQUERY(REMOTE_SQL, 'SELECT EventType, EventDate FROM SalesDB.dbo.AuditLog')
VALUES ('Sync', GETDATE());

-- UPDATE via OPENQUERY
UPDATE OPENQUERY(REMOTE_SQL, 'SELECT Status FROM SalesDB.dbo.Orders WHERE OrderID = 5001')
SET Status = 'Shipped';

-- DELETE via OPENQUERY
DELETE FROM OPENQUERY(REMOTE_SQL, 'SELECT * FROM SalesDB.dbo.TempData WHERE ProcessDate < ''2026-01-01''');

-- OPENQUERY with Oracle linked server
SELECT *
FROM OPENQUERY(ORACLE_PROD, 'SELECT employee_id, first_name, last_name FROM hr.employees WHERE department_id = 10');
```

### Dynamic OPENQUERY

```sql
-- OPENQUERY does not accept variables directly; use dynamic SQL
DECLARE @Region NVARCHAR(50) = N'West';
DECLARE @sql NVARCHAR(MAX);

SET @sql = N'SELECT * FROM OPENQUERY(REMOTE_SQL, ''SELECT CustomerID, Name FROM SalesDB.dbo.Customers WHERE Region = ''''' + @Region + ''''''')';

EXEC sp_executesql @sql;
```

---

## OPENROWSET

`OPENROWSET` provides ad-hoc access to remote data without requiring a predefined linked server. It is useful for one-off queries or when you do not want to maintain a persistent linked server definition.

```sql
-- Ad-hoc query to another SQL Server (no linked server needed)
SELECT *
FROM OPENROWSET(
    'SQLNCLI11',
    'Server=RemoteServer\Instance;Trusted_Connection=yes;',
    'SELECT CustomerID, Name FROM SalesDB.dbo.Customers WHERE Region = ''West'''
);

-- Query with SQL authentication
SELECT *
FROM OPENROWSET(
    'SQLNCLI11',
    'Server=RemoteServer;UID=sa;PWD=P@ssw0rd;',
    'SELECT * FROM SalesDB.dbo.Products'
);

-- Read from an Excel file
SELECT *
FROM OPENROWSET(
    'Microsoft.ACE.OLEDB.12.0',
    'Excel 12.0;Database=C:\Data\Report.xlsx;HDR=YES',
    'SELECT * FROM [Sheet1$]'
);

-- BULK import from a file (different usage of OPENROWSET)
SELECT *
FROM OPENROWSET(
    BULK 'C:\Data\customers.csv',
    FORMATFILE = 'C:\Data\customers.fmt',
    FIRSTROW = 2
) AS data;
```

### Enabling Ad-Hoc Queries

`OPENROWSET` and `OPENDATASOURCE` require the `Ad Hoc Distributed Queries` option to be enabled:

```sql
-- Enable ad-hoc distributed queries
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;

EXEC sp_configure 'Ad Hoc Distributed Queries', 1;
RECONFIGURE;
```

---

## OPENDATASOURCE

`OPENDATASOURCE` is similar to `OPENROWSET` but uses four-part naming syntax with an inline connection string, rather than a pass-through query.

```sql
-- Query another SQL Server using OPENDATASOURCE
SELECT *
FROM OPENDATASOURCE(
    'SQLNCLI11',
    'Data Source=RemoteServer\Instance;Integrated Security=SSPI'
).[SalesDB].[dbo].[Customers]
WHERE Region = 'West';

-- Query an Excel file using OPENDATASOURCE
SELECT *
FROM OPENDATASOURCE(
    'Microsoft.ACE.OLEDB.12.0',
    'Data Source=C:\Data\Report.xlsx;Extended Properties="Excel 12.0;HDR=YES"'
)...[Sheet1$];

-- Insert using OPENDATASOURCE
INSERT INTO OPENDATASOURCE(
    'SQLNCLI11',
    'Data Source=RemoteServer;Integrated Security=SSPI'
).[SalesDB].[dbo].[AuditLog] (EventType, EventDate)
VALUES ('Check', GETDATE());
```

### OPENDATASOURCE vs OPENROWSET vs Linked Server

| Feature | Linked Server | OPENQUERY | OPENROWSET | OPENDATASOURCE |
|---------|--------------|-----------|------------|----------------|
| Persistent definition | Yes | Uses linked server | No (ad-hoc) | No (ad-hoc) |
| Pass-through query | No (four-part) | Yes | Yes | No (four-part) |
| Security mapping | Yes | Uses linked server | Inline credentials | Inline credentials |
| Performance control | Limited | Good (remote execution) | Good | Limited |
| Requires configuration | sp_addlinkedserver | Linked server exists | Ad Hoc Queries enabled | Ad Hoc Queries enabled |

---

## Linked Server Security

Security is a critical aspect of linked server configuration. SQL Server provides several methods for mapping local logins to remote credentials.

### Login Mapping with sp_addlinkedsrvlogin

```sql
-- Map all local logins to a single remote SQL login
EXEC sp_addlinkedsrvlogin
    @rmtsrvname = N'REMOTE_SQL',
    @useself = N'FALSE',
    @locallogin = NULL,               -- NULL = applies to all local logins
    @rmtuser = N'remote_reader',
    @rmtpassword = N'R3m0teP@ss!';
GO

-- Map a specific local login to a specific remote login
EXEC sp_addlinkedsrvlogin
    @rmtsrvname = N'REMOTE_SQL',
    @useself = N'FALSE',
    @locallogin = N'DOMAIN\JohnDoe',
    @rmtuser = N'john_remote',
    @rmtpassword = N'J0hnP@ss!';
GO

-- Use the current login's credentials (Windows pass-through / self-mapping)
EXEC sp_addlinkedsrvlogin
    @rmtsrvname = N'REMOTE_SQL',
    @useself = N'TRUE',
    @locallogin = NULL;
GO

-- Remove a login mapping
EXEC sp_droplinkedsrvlogin
    @rmtsrvname = N'REMOTE_SQL',
    @locallogin = NULL;
```

### Security Options Explained

| @useself | Behavior |
|----------|----------|
| `TRUE` | Passes the current Windows credentials to the remote server (Kerberos delegation required for double-hop) |
| `FALSE` | Uses the explicitly provided @rmtuser and @rmtpassword |

### Security Best Practices

- **Avoid `sa` or high-privilege remote logins.** Create dedicated read-only accounts on the remote server.
- **Use Windows Authentication** with constrained Kerberos delegation when possible to avoid storing passwords.
- **The "double-hop" problem**: When a user connects to Server A, which then connects to Server B via a linked server, Kerberos delegation must be configured for credentials to flow. Without it, the connection to Server B uses the SQL Server service account or fails.
- **Audit linked server access** regularly by reviewing `sys.linked_logins`.

```sql
-- View current login mappings
SELECT
    s.name AS LinkedServer,
    ll.remote_name AS RemoteLogin,
    ll.uses_self_credential,
    sp.name AS LocalLogin
FROM sys.linked_logins ll
JOIN sys.servers s ON ll.server_id = s.server_id
LEFT JOIN sys.server_principals sp ON ll.local_principal_id = sp.principal_id;
```

---

## Distributed Transactions (MSDTC)

When a query modifies data on both a local and a linked server (or multiple linked servers) within a single transaction, SQL Server uses the Microsoft Distributed Transaction Coordinator (MSDTC) to coordinate the two-phase commit.

### How Distributed Transactions Work

1. **Phase 1 (Prepare)** - MSDTC asks all participants to prepare to commit. Each participant writes changes to its local log and responds with "prepared."
2. **Phase 2 (Commit)** - If all participants are prepared, MSDTC tells them to commit. If any participant fails, all participants roll back.

### Enabling Distributed Transactions

```sql
-- Enable RPC Out and transaction promotion on the linked server
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'rpc out', @optvalue = N'true';
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'remote proc transaction promotion', @optvalue = N'true';
```

### Using Distributed Transactions

```sql
-- Implicit distributed transaction (automatic when modifying linked server in a transaction)
BEGIN TRANSACTION;

    UPDATE dbo.LocalOrders
    SET Status = 'Synced'
    WHERE OrderID = 5001;

    UPDATE [REMOTE_SQL].[SalesDB].[dbo].[Orders]
    SET Status = 'Received'
    WHERE OrderID = 5001;

COMMIT TRANSACTION;

-- Explicit distributed transaction
BEGIN DISTRIBUTED TRANSACTION;

    INSERT INTO dbo.LocalAudit (Action, ActionDate) VALUES ('Sync', GETDATE());
    INSERT INTO [REMOTE_SQL].[SalesDB].[dbo].[RemoteAudit] (Action, ActionDate) VALUES ('Sync', GETDATE());

COMMIT TRANSACTION;
```

### MSDTC Configuration Requirements

- MSDTC service must be running on both servers.
- Firewall must allow MSDTC traffic (TCP port 135 + dynamic RPC ports).
- MSDTC security settings must allow network transactions:
  - Network DTC Access = Enabled
  - Allow Inbound / Allow Outbound = Enabled
  - Mutual Authentication Required (or lower as needed)
- Both servers must be able to resolve each other's names (DNS or hosts file).

### Disabling Transaction Promotion

If you want to prevent linked server calls from escalating to distributed transactions:

```sql
-- Disable promotion: linked server calls outside explicit distributed transactions
-- will fail if they would require MSDTC
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'remote proc transaction promotion', @optvalue = N'false';
```

---

## Performance Considerations

Linked server queries are one of the most common sources of performance problems in SQL Server. Understanding why and how to optimize them is critical.

### Why Linked Server Queries Are Slow

1. **Remote table scans** - Without proper predicate pushdown, the entire remote table may be transferred to the local server before filtering.
2. **Missing remote statistics** - The local optimizer has no statistics for remote tables, often leading to cardinality estimation errors and poor plans.
3. **Network latency** - Data must travel over the network; large result sets amplify this.
4. **Serialization overhead** - Data is serialized/deserialized through OLE DB, which adds overhead.
5. **No parallelism** - Linked server queries run in a serial zone on the remote leg.

### Performance Optimization Techniques

#### Use OPENQUERY Instead of Four-Part Names

```sql
-- BAD: Four-part name - may pull entire table locally before filtering
SELECT * FROM [REMOTE_SQL].[SalesDB].[dbo].[Customers]
WHERE Region = 'West' AND IsActive = 1;

-- GOOD: OPENQUERY - filter executes on remote server
SELECT * FROM OPENQUERY(REMOTE_SQL,
    'SELECT * FROM SalesDB.dbo.Customers WHERE Region = ''West'' AND IsActive = 1');
```

#### Materialize Remote Data Locally

```sql
-- Pull remote data into a temp table, then join locally
SELECT CustomerID, Name, Region
INTO #RemoteCustomers
FROM OPENQUERY(REMOTE_SQL,
    'SELECT CustomerID, Name, Region FROM SalesDB.dbo.Customers WHERE IsActive = 1');

-- Now join locally with full statistics
SELECT o.OrderID, o.OrderDate, rc.Name
FROM dbo.Orders AS o
INNER JOIN #RemoteCustomers AS rc ON o.CustomerID = rc.CustomerID;

DROP TABLE #RemoteCustomers;
```

#### Provider Options for Better Plan Choices

```sql
-- Enable specific OLE DB provider options
EXEC sp_MSset_oledb_prop N'SQLNCLI11', N'AllowInProcess', 1;
EXEC sp_MSset_oledb_prop N'SQLNCLI11', N'DynamicParameters', 1;

-- Enable lazy schema validation to avoid unnecessary metadata calls
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'lazy schema validation', @optvalue = N'true';

-- Enable collation compatible to avoid implicit conversions
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'collation compatible', @optvalue = N'true';
```

#### Avoid Linked Server Queries in Loops

```sql
-- BAD: Calling linked server in a cursor/loop
DECLARE @id INT;
DECLARE cur CURSOR FOR SELECT CustomerID FROM dbo.CustomerList;
OPEN cur;
FETCH NEXT FROM cur INTO @id;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT * FROM [REMOTE_SQL].[SalesDB].[dbo].[Customers] WHERE CustomerID = @id;
    FETCH NEXT FROM cur INTO @id;
END
CLOSE cur; DEALLOCATE cur;

-- GOOD: Batch the query
SELECT c.*
FROM [REMOTE_SQL].[SalesDB].[dbo].[Customers] AS c
WHERE c.CustomerID IN (SELECT CustomerID FROM dbo.CustomerList);

-- BETTER: Use OPENQUERY with a materialized temp table approach
```

---

## Troubleshooting Linked Servers

### Common Errors and Solutions

#### Error: "Cannot create an instance of OLE DB provider"

```sql
-- Ensure the provider is installed and registered
-- Check provider configuration
EXEC sp_MSset_oledb_prop N'SQLNCLI11', N'AllowInProcess', 1;

-- For 64-bit SQL Server accessing 32-bit providers, this won't work
-- You need a 64-bit provider
```

#### Error: "Login failed for user" on remote server

```sql
-- Verify login mappings
SELECT * FROM sys.linked_logins WHERE server_id = (
    SELECT server_id FROM sys.servers WHERE name = 'REMOTE_SQL'
);

-- Test connectivity
EXEC sp_testlinkedserver N'REMOTE_SQL';

-- Re-create login mapping
EXEC sp_droplinkedsrvlogin @rmtsrvname = N'REMOTE_SQL', @locallogin = NULL;
EXEC sp_addlinkedsrvlogin
    @rmtsrvname = N'REMOTE_SQL',
    @useself = N'FALSE',
    @locallogin = NULL,
    @rmtuser = N'remote_user',
    @rmtpassword = N'NewP@ssword';
```

#### Error: "The operation could not be performed because OLE DB provider... was unable to begin a distributed transaction"

```sql
-- MSDTC is not configured or not running
-- 1. Start MSDTC service on both servers
-- 2. Configure MSDTC for network access:
--    Component Services > Computers > My Computer > Distributed Transaction Coordinator
--    > Local DTC > Properties > Security
--    Enable: Network DTC Access, Allow Inbound, Allow Outbound
-- 3. Open firewall ports (135 + dynamic range)
-- 4. Verify with:
EXEC sp_testlinkedserver N'REMOTE_SQL';
```

#### Timeout Issues

```sql
-- Increase connection and query timeout
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'connect timeout', @optvalue = N'60';
EXEC sp_serveroption @server = N'REMOTE_SQL', @optname = N'query timeout', @optvalue = N'600';
```

### Diagnostic Queries

```sql
-- List all linked servers with configuration
SELECT
    s.name AS LinkedServer,
    s.product,
    s.provider,
    s.data_source,
    s.catalog,
    s.is_linked,
    s.is_remote_login_enabled,
    s.is_rpc_out_enabled,
    s.is_data_access_enabled,
    s.modify_date
FROM sys.servers s
WHERE s.is_linked = 1;

-- Check recent linked server errors in the SQL Server error log
EXEC xp_readerrorlog 0, 1, N'linked';
```

---

## Alternatives to Linked Servers

Given the performance and maintenance challenges of linked servers, consider these alternatives:

### 1. ETL / Data Pipelines (Preferred for Warehousing)

```
-- Use SSIS, Azure Data Factory, or custom scripts to:
-- 1. Extract data from source
-- 2. Stage locally
-- 3. Transform and load
-- Benefits: Full control, better performance, auditing, error handling
```

### 2. Replication

- **Transactional Replication** - Near real-time copy of data to a subscriber.
- **Snapshot Replication** - Periodic full copy.
- **Merge Replication** - Bidirectional sync.

### 3. AlwaysOn Availability Groups (Readable Secondary)

- Offload read queries to a secondary replica with no linked server overhead.

### 4. SQL Server Integration Services (SSIS)

- Purpose-built for data movement between heterogeneous sources.
- Full error handling, logging, and scheduling.

### 5. PolyBase

```sql
-- PolyBase (SQL Server 2016+) for querying external data
CREATE EXTERNAL DATA SOURCE RemoteSQL
WITH (
    TYPE = RDBMS,
    LOCATION = 'RemoteServer',
    DATABASE_NAME = 'SalesDB',
    CREDENTIAL = RemoteSQLCredential
);

CREATE EXTERNAL TABLE dbo.RemoteCustomers (
    CustomerID INT,
    Name NVARCHAR(100),
    Email NVARCHAR(200)
)
WITH (DATA_SOURCE = RemoteSQL, SCHEMA_NAME = 'dbo', OBJECT_NAME = 'Customers');

-- Query like a local table with pushdown optimization
SELECT * FROM dbo.RemoteCustomers WHERE Region = 'West';
```

### 6. Azure Hybrid Solutions

- **Azure SQL Managed Instance** linked servers with better cloud integration.
- **Azure Data Factory** for managed data pipelines.
- **Synapse Link** for analytical workloads.

### 7. CLR or REST API Integration

- For non-relational sources, a CLR stored procedure or external script can call APIs.
- SQL Server 2022+ supports `sp_invoke_external_rest_endpoint` for Azure SQL.

---

## Common Interview Questions

### Q1: What is a linked server and how do you create one?

**A:** A linked server is a SQL Server feature that allows querying remote data sources (other SQL Servers, Oracle, MySQL, Excel, etc.) using OLE DB providers. You create one using `sp_addlinkedserver`, specifying the logical name, OLE DB provider, and data source. After creation, you configure security with `sp_addlinkedsrvlogin` and enable options like RPC Out with `sp_serveroption`. Remote objects can then be accessed via four-part naming or `OPENQUERY`.

### Q2: What is the difference between OPENQUERY, OPENROWSET, and OPENDATASOURCE?

**A:** `OPENQUERY` sends a pass-through query to an existing linked server -- the query executes remotely, which is good for performance. `OPENROWSET` is an ad-hoc mechanism that does not require a linked server definition; it takes a provider, connection string, and query inline. It can also be used with the BULK option for file import. `OPENDATASOURCE` is also ad-hoc but uses four-part naming syntax with an inline connection string instead of a pass-through query. Both `OPENROWSET` and `OPENDATASOURCE` require the "Ad Hoc Distributed Queries" server option to be enabled.

### Q3: Why are linked server queries often slow, and how do you optimize them?

**A:** Linked server queries are slow primarily because: (1) the local optimizer lacks statistics for remote tables, leading to poor execution plans; (2) predicates may not be pushed to the remote server, causing full table scans and large data transfers; (3) network latency amplifies data volume; (4) OLE DB serialization adds overhead. Optimization techniques include: using `OPENQUERY` for pass-through execution, materializing remote data into temp tables before joining, enabling lazy schema validation, and using `collation compatible` to avoid implicit conversions. For recurring patterns, consider replacing linked servers with ETL processes or replication.

### Q4: What is the double-hop problem with linked servers?

**A:** The double-hop problem occurs with Windows Authentication when a user connects to Server A (first hop), and Server A needs to impersonate that user to connect to Server B via a linked server (second hop). By default, Windows credentials cannot be delegated beyond the first hop. The solutions are: (1) Configure Kerberos constrained delegation for the SQL Server service account, (2) Use explicit SQL Server authentication credentials in the login mapping, or (3) Use a fixed remote account via `sp_addlinkedsrvlogin` with `@useself = FALSE`.

### Q5: What is MSDTC and when is it needed with linked servers?

**A:** MSDTC (Microsoft Distributed Transaction Coordinator) manages distributed transactions that span multiple resource managers (servers). It is needed when a single transaction modifies data on both a local and linked server, or across multiple linked servers. MSDTC implements the two-phase commit protocol to ensure atomicity across servers. It requires the MSDTC service running on all participants, proper firewall rules (port 135 + dynamic RPC), and network DTC access enabled in the security configuration. If only reading from linked servers (no writes in transactions), MSDTC is typically not required.

### Q6: How do you troubleshoot a linked server that is returning "Access Denied" or connection failures?

**A:** Systematic troubleshooting: (1) Test basic connectivity with `sp_testlinkedserver`. (2) Verify login mappings in `sys.linked_logins`. (3) Check that RPC and RPC Out are enabled if calling remote procedures. (4) For Windows auth, verify Kerberos delegation and SPNs. (5) For SQL auth, verify the remote account exists and has proper permissions. (6) Check the remote server's error log for login failure details. (7) Verify firewall rules allow the connection. (8) For MSDTC errors, ensure the service is running and configured on both sides. (9) Check that the OLE DB provider is properly installed (64-bit vs 32-bit).

### Q7: What alternatives to linked servers would you recommend for a production data pipeline?

**A:** For production data pipelines, I would recommend: (1) **SSIS or Azure Data Factory** for scheduled ETL jobs with full error handling and logging. (2) **Transactional replication** for near real-time data distribution. (3) **PolyBase** (SQL Server 2016+) for querying external data with pushdown optimization. (4) **AlwaysOn readable secondaries** for read-only reporting offload. (5) **Change Data Capture (CDC)** combined with ETL for incremental loading. Linked servers are acceptable for ad-hoc queries, low-volume lookups, or prototyping, but they are not ideal for high-performance production data pipelines due to their lack of statistics, limited parallelism, and security management overhead.

### Q8: Can you execute a stored procedure on a linked server? What is required?

**A:** Yes. You can execute a remote stored procedure using four-part naming: `EXEC [LinkedServer].[Database].[Schema].[Procedure] @param = value`. This requires the `rpc out` option to be enabled on the linked server (`sp_serveroption @optname = 'rpc out', @optvalue = 'true'`). The remote login must have EXECUTE permission on the procedure. If the remote procedure modifies data and is called within a local transaction, MSDTC may be needed for the distributed transaction.

---

## Tips

- **Prefer OPENQUERY over four-part names** for any query that involves filtering, grouping, or joining on the remote side. This ensures execution happens remotely.
- **Materialize remote data into temp tables** before joining with local tables. This gives the local optimizer proper statistics and cardinality estimates.
- **Never use linked servers in a cursor or loop.** Each iteration opens a new remote connection and round-trip.
- **Use dedicated, low-privilege remote accounts** for linked server login mappings. Avoid mapping to `sa` or `sysadmin` roles.
- **Monitor linked server performance** using `sys.dm_exec_query_stats` and execution plans. Look for "Remote Query" or "Remote Scan" operators.
- **Set appropriate timeouts.** A linked server query with no timeout can hang indefinitely if the remote server is unresponsive.
- **Test MSDTC before going to production.** Distributed transaction failures are notoriously difficult to debug under pressure.
- **Document all linked servers** in your environment. They are often created for "temporary" purposes and become permanent dependencies.
- **Consider PolyBase** as a modern replacement for linked servers when querying heterogeneous data sources -- it provides better optimization and manageability.
- **Security audit regularly**: linked servers with stored passwords represent a security risk. Rotate credentials and review mappings periodically.
