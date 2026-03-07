# Auditing & Compliance

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [SQL Server Audit Overview](#sql-server-audit-overview)
2. [Server Audit and Database Audit Specification](#server-audit-and-database-audit-specification)
3. [Audit to File vs Windows Event Log](#audit-to-file-vs-windows-event-log)
4. [C2 Audit Mode](#c2-audit-mode)
5. [Common Compliance Audit Actions](#common-compliance-audit-actions)
6. [Change Data Tracking Approaches for Audit](#change-data-tracking-approaches-for-audit)
7. [DDL Triggers for Schema Change Tracking](#ddl-triggers-for-schema-change-tracking)
8. [Login Auditing](#login-auditing)
9. [SQL Server Audit vs Extended Events for Auditing](#sql-server-audit-vs-extended-events-for-auditing)
10. [Regulatory Compliance (SOX, GDPR)](#regulatory-compliance-sox-gdpr)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips](#tips)

---

## SQL Server Audit Overview

SQL Server Audit is a feature built on Extended Events that provides a formal, structured mechanism for auditing server and database-level events. It was introduced in SQL Server 2008 and has been the primary auditing framework since.

### Architecture

```
SQL Server Audit (Target Definition)
    |
    |-- Server Audit Specification
    |       (server-level events: logins, permission changes, server config)
    |
    |-- Database Audit Specification(s)
            (database-level events: SELECT, INSERT, UPDATE, DELETE, EXECUTE, schema changes)
```

The architecture has three layers:

1. **SQL Server Audit Object** (the target): Defines where audit records are written (file, Windows Security Log, or Windows Application Log).
2. **Server Audit Specification**: Defines which server-level actions to audit. Only one per audit object.
3. **Database Audit Specification**: Defines which database-level actions to audit. One per database per audit object.

### Creating an Audit - Complete Example

```sql
-- Step 1: Create the audit object (defines the target)
CREATE SERVER AUDIT ProdAudit
TO FILE
(
    FILEPATH = N'D:\SQLAudit\',
    MAXSIZE = 256 MB,
    MAX_ROLLOVER_FILES = 20,
    RESERVE_DISK_SPACE = OFF
)
WITH
(
    QUEUE_DELAY = 1000,              -- ms delay before flushing to target
    ON_FAILURE = CONTINUE            -- CONTINUE or SHUTDOWN
);
GO

-- Step 2: Enable the audit
ALTER SERVER AUDIT ProdAudit WITH (STATE = ON);
GO

-- Step 3: Create a server audit specification
CREATE SERVER AUDIT SPECIFICATION ServerAuditSpec
FOR SERVER AUDIT ProdAudit
ADD (FAILED_LOGIN_GROUP),
ADD (LOGIN_CHANGE_PASSWORD_GROUP),
ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
ADD (DATABASE_CHANGE_GROUP)
WITH (STATE = ON);
GO

-- Step 4: Create a database audit specification
USE SalesDB;
GO

CREATE DATABASE AUDIT SPECIFICATION SalesDBSpec
FOR SERVER AUDIT ProdAudit
ADD (SELECT, INSERT, UPDATE, DELETE
     ON SCHEMA::dbo BY public),
ADD (EXECUTE ON SCHEMA::dbo BY public),
ADD (SCHEMA_OBJECT_CHANGE_GROUP)
WITH (STATE = ON);
GO
```

---

## Server Audit and Database Audit Specification

### Server Audit Specification

Captures server-scoped events. You can have **one** server audit specification per audit object.

**Common Server-Level Action Groups:**

| Action Group | What It Captures |
|-------------|-----------------|
| `FAILED_LOGIN_GROUP` | Failed login attempts |
| `SUCCESSFUL_LOGIN_GROUP` | Successful logins |
| `LOGIN_CHANGE_PASSWORD_GROUP` | Password changes |
| `SERVER_ROLE_MEMBER_CHANGE_GROUP` | Adding/removing members from server roles |
| `SERVER_PERMISSION_CHANGE_GROUP` | GRANT, DENY, REVOKE at server level |
| `DATABASE_CHANGE_GROUP` | CREATE, ALTER, DROP DATABASE |
| `SERVER_STATE_CHANGE_GROUP` | SQL Server service state changes |
| `SERVER_OBJECT_CHANGE_GROUP` | CREATE, ALTER, DROP for server objects |
| `AUDIT_CHANGE_GROUP` | Changes to audit objects themselves |
| `SERVER_OPERATION_GROUP` | Server-level operations (DBCC, backup, restore) |

```sql
CREATE SERVER AUDIT SPECIFICATION CriticalServerEvents
FOR SERVER AUDIT ProdAudit
ADD (FAILED_LOGIN_GROUP),
ADD (SUCCESSFUL_LOGIN_GROUP),
ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
ADD (SERVER_PERMISSION_CHANGE_GROUP),
ADD (AUDIT_CHANGE_GROUP)
WITH (STATE = ON);
GO
```

### Database Audit Specification

Captures database-scoped events. You can have **one** database audit specification per database per audit object.

**Common Database-Level Action Groups:**

| Action Group | What It Captures |
|-------------|-----------------|
| `SELECT` | SELECT on specified objects |
| `INSERT` | INSERT on specified objects |
| `UPDATE` | UPDATE on specified objects |
| `DELETE` | DELETE on specified objects |
| `EXECUTE` | EXECUTE on specified objects |
| `SCHEMA_OBJECT_CHANGE_GROUP` | CREATE, ALTER, DROP on schema objects |
| `DATABASE_PERMISSION_CHANGE_GROUP` | GRANT, DENY, REVOKE at database level |
| `DATABASE_ROLE_MEMBER_CHANGE_GROUP` | Adding/removing database role members |
| `DATABASE_OBJECT_CHANGE_GROUP` | CREATE, ALTER, DROP on database objects |
| `SCHEMA_OBJECT_ACCESS_GROUP` | Any object access in the database |
| `BACKUP_RESTORE_GROUP` | Backup and restore operations |

```sql
-- Audit SELECT on a specific table by a specific user
CREATE DATABASE AUDIT SPECIFICATION FinanceTableAudit
FOR SERVER AUDIT ProdAudit
ADD (SELECT ON OBJECT::dbo.FinancialTransactions BY public),
ADD (INSERT ON OBJECT::dbo.FinancialTransactions BY public),
ADD (UPDATE ON OBJECT::dbo.FinancialTransactions BY public),
ADD (DELETE ON OBJECT::dbo.FinancialTransactions BY public)
WITH (STATE = ON);
GO
```

---

## Audit to File vs Windows Event Log

### Audit to File

```sql
CREATE SERVER AUDIT FileAudit
TO FILE
(
    FILEPATH = N'D:\SQLAudit\',
    MAXSIZE = 512 MB,
    MAX_ROLLOVER_FILES = 50,
    RESERVE_DISK_SPACE = OFF
);
```

**Advantages:**
- Higher throughput; can handle large volumes of events.
- Files can be read with `fn_get_audit_file()` for analysis.
- Retention is controllable via `MAX_ROLLOVER_FILES` and `MAXSIZE`.
- Files can be archived, backed up, or shipped to a SIEM.

**Disadvantages:**
- Requires disk space management.
- Files can potentially be tampered with if not protected at the OS level.
- Not natively integrated with centralized Windows event monitoring.

**Reading Audit Files:**

```sql
-- Read all audit records from audit files
SELECT
    event_time,
    action_id,
    succeeded,
    server_principal_name,
    database_name,
    schema_name,
    object_name,
    statement
FROM sys.fn_get_audit_file('D:\SQLAudit\ProdAudit_*.sqlaudit', DEFAULT, DEFAULT)
ORDER BY event_time DESC;

-- Filter for specific events
SELECT *
FROM sys.fn_get_audit_file('D:\SQLAudit\ProdAudit_*.sqlaudit', DEFAULT, DEFAULT)
WHERE action_id = 'SL'           -- SELECT
  AND database_name = 'SalesDB'
  AND object_name = 'Customers'
  AND event_time > DATEADD(DAY, -7, GETUTCDATE());
```

### Audit to Windows Event Log

```sql
-- Windows Security Log (requires special configuration)
CREATE SERVER AUDIT SecurityLogAudit
TO SECURITY_LOG;

-- Windows Application Log
CREATE SERVER AUDIT AppLogAudit
TO APPLICATION_LOG;
```

**Security Log Requirements:**
- The SQL Server service account must have the "Generate security audits" privilege in Local Security Policy.
- On Windows Server 2008+, you need to add the `audit` keyword to the machine's audit policy.

**Advantages:**
- Centralized with Windows event infrastructure.
- Can be forwarded to SIEM tools (Splunk, Azure Sentinel) via Windows Event Forwarding.
- Security Log events are tamper-resistant (protected by Windows security).
- Integrates with Group Policy and Windows auditing framework.

**Disadvantages:**
- Lower throughput than file-based auditing.
- Security Log has size limits and can overflow, potentially causing audit loss.
- Application Log is less secure (any admin can clear it).

### Comparison Table

| Aspect | File | Security Log | Application Log |
|--------|------|-------------|----------------|
| Throughput | High | Medium | Medium |
| Tamper resistance | Low (OS-level) | High | Low |
| Centralized monitoring | Manual | Native | Native |
| Configuration complexity | Low | Medium | Low |
| Recommended for | High-volume auditing | Compliance/regulatory | Development/testing |

---

## C2 Audit Mode

C2 Audit Mode is a legacy auditing feature from the C2 security evaluation criteria (predecessor to Common Criteria). It logs all access attempts to SQL Server objects.

```sql
-- Enable C2 Audit Mode (requires restart)
EXEC sp_configure 'c2 audit mode', 1;
RECONFIGURE;
-- Restart SQL Server service

-- Check status
EXEC sp_configure 'c2 audit mode';
```

### Important Characteristics

- **Deprecated**: Microsoft recommends using SQL Server Audit instead. C2 audit mode is deprecated since SQL Server 2016.
- **Common Criteria Compliance**: Replaced by Common Criteria Compliance Enabled (`common criteria compliance enabled` sp_configure option).
- **Logs to trace files**: Writes to `\MSSQL\Data` directory as `.trc` files.
- **ON_FAILURE = SHUTDOWN**: If the audit file cannot be written, SQL Server shuts down.
- **Performance impact**: Significant, as it logs all statement-level events.

```sql
-- Modern replacement: Common Criteria Compliance
EXEC sp_configure 'common criteria compliance enabled', 1;
RECONFIGURE;
-- Requires restart

-- This enables:
-- 1. Residual Information Protection (RIP) - memory overwrite on deallocation
-- 2. Login statistics viewable by individual logins
-- 3. Column GRANT does not override table DENY
```

---

## Common Compliance Audit Actions

For compliance purposes, the following audit action groups cover the most critical areas:

### Access Auditing

```sql
-- Who accessed what data and when
CREATE DATABASE AUDIT SPECIFICATION DataAccessAudit
FOR SERVER AUDIT ComplianceAudit
ADD (SELECT ON SCHEMA::dbo BY public),
ADD (INSERT ON SCHEMA::dbo BY public),
ADD (UPDATE ON SCHEMA::dbo BY public),
ADD (DELETE ON SCHEMA::dbo BY public)
WITH (STATE = ON);
```

### Privilege Escalation Auditing

```sql
-- Track all permission and role changes
CREATE SERVER AUDIT SPECIFICATION PrivilegeAudit
FOR SERVER AUDIT ComplianceAudit
ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
ADD (SERVER_PERMISSION_CHANGE_GROUP),
ADD (DATABASE_PERMISSION_CHANGE_GROUP)
WITH (STATE = ON);
```

### Schema Change Auditing

```sql
-- Track all DDL changes
CREATE DATABASE AUDIT SPECIFICATION SchemaChangeAudit
FOR SERVER AUDIT ComplianceAudit
ADD (SCHEMA_OBJECT_CHANGE_GROUP),
ADD (DATABASE_OBJECT_CHANGE_GROUP)
WITH (STATE = ON);
```

### Authentication Auditing

```sql
CREATE SERVER AUDIT SPECIFICATION AuthAudit
FOR SERVER AUDIT ComplianceAudit
ADD (FAILED_LOGIN_GROUP),
ADD (SUCCESSFUL_LOGIN_GROUP),
ADD (LOGIN_CHANGE_PASSWORD_GROUP),
ADD (SERVER_PRINCIPAL_CHANGE_GROUP)
WITH (STATE = ON);
```

### Comprehensive Compliance Template

```sql
-- A production-ready audit combining common compliance requirements
CREATE SERVER AUDIT ComplianceAudit
TO FILE
(
    FILEPATH = N'D:\SQLAudit\Compliance\',
    MAXSIZE = 1 GB,
    MAX_ROLLOVER_FILES = 100,
    RESERVE_DISK_SPACE = OFF
)
WITH
(
    QUEUE_DELAY = 1000,
    ON_FAILURE = CONTINUE
);
GO

ALTER SERVER AUDIT ComplianceAudit WITH (STATE = ON);
GO

CREATE SERVER AUDIT SPECIFICATION ComplianceServerSpec
FOR SERVER AUDIT ComplianceAudit
ADD (FAILED_LOGIN_GROUP),
ADD (SUCCESSFUL_LOGIN_GROUP),
ADD (LOGIN_CHANGE_PASSWORD_GROUP),
ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
ADD (SERVER_PERMISSION_CHANGE_GROUP),
ADD (AUDIT_CHANGE_GROUP),
ADD (DATABASE_CHANGE_GROUP),
ADD (SERVER_OBJECT_CHANGE_GROUP)
WITH (STATE = ON);
GO
```

---

## Change Data Tracking Approaches for Audit

While SQL Server Audit captures who did what, sometimes you need to track the actual data changes for audit trails. Several approaches exist:

### 1. Change Data Capture (CDC)

```sql
-- Enable CDC on the database
EXEC sys.sp_cdc_enable_db;

-- Enable CDC on a specific table
EXEC sys.sp_cdc_enable_table
    @source_schema = N'dbo',
    @source_name = N'Customers',
    @role_name = N'cdc_reader',
    @supports_net_changes = 1;

-- Query change data
SELECT *
FROM cdc.fn_cdc_get_all_changes_dbo_Customers(
    @from_lsn, @to_lsn, N'all update old'
);
```

**Characteristics:**
- Captures INSERT, UPDATE, DELETE with before/after images.
- Asynchronous (reads from the transaction log via SQL Agent jobs).
- Does not record who made the change (no user context).
- Suitable for ETL and data warehouse incremental loads.

### 2. Change Tracking

```sql
-- Enable at database level
ALTER DATABASE SalesDB SET CHANGE_TRACKING = ON
(CHANGE_RETENTION = 7 DAYS, AUTO_CLEANUP = ON);

-- Enable on a table
ALTER TABLE dbo.Customers ENABLE CHANGE_TRACKING
WITH (TRACK_COLUMNS_UPDATED = ON);

-- Query changes since a version
SELECT ct.CustomerId, ct.SYS_CHANGE_OPERATION, ct.SYS_CHANGE_VERSION
FROM CHANGETABLE(CHANGES dbo.Customers, @last_sync_version) AS ct;
```

**Characteristics:**
- Lightweight; only tracks which rows changed, not the values.
- Synchronous (recorded during the transaction).
- Best for sync scenarios (e.g., occasionally connected clients).

### 3. Temporal Tables (System-Versioned)

```sql
-- Create a temporal table
CREATE TABLE dbo.Employees
(
    EmployeeId    INT PRIMARY KEY,
    Name          NVARCHAR(100),
    Salary        DECIMAL(18,2),
    Department    NVARCHAR(50),
    SysStartTime  DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime    DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.EmployeesHistory));

-- Query historical data
SELECT * FROM dbo.Employees
FOR SYSTEM_TIME AS OF '2025-06-15T12:00:00';

-- Query all changes in a range
SELECT * FROM dbo.Employees
FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2025-12-31';
```

**Characteristics:**
- Automatic history tracking with full before-images.
- Point-in-time queries with temporal syntax.
- No user context captured (add a `ModifiedBy` column manually if needed).
- Best for data versioning and audit trails of data values.

### 4. Custom Audit Triggers

```sql
CREATE TRIGGER trg_Customers_Audit
ON dbo.Customers
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AuditLog (
        TableName, Action, RecordId, OldValues, NewValues,
        ModifiedBy, ModifiedDate
    )
    SELECT
        'Customers',
        CASE
            WHEN EXISTS(SELECT 1 FROM inserted) AND EXISTS(SELECT 1 FROM deleted) THEN 'UPDATE'
            WHEN EXISTS(SELECT 1 FROM inserted) THEN 'INSERT'
            ELSE 'DELETE'
        END,
        COALESCE(i.CustomerId, d.CustomerId),
        (SELECT d.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
        (SELECT i.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
        SUSER_SNAME(),
        GETUTCDATE()
    FROM inserted i
    FULL OUTER JOIN deleted d ON i.CustomerId = d.CustomerId;
END;
```

### Comparison of Data Change Tracking Methods

| Feature | CDC | Change Tracking | Temporal Tables | Triggers |
|---------|-----|----------------|----------------|----------|
| Before/after values | Yes | No | Before (history) | Yes |
| User context | No | No | No (custom column) | Yes |
| Performance impact | Low (async) | Low (sync) | Low (sync) | Medium (sync) |
| Retention management | Manual/Agent | Auto cleanup | Manual | Manual |
| SQL Server version | 2008+ | 2008+ | 2016+ | All versions |
| Best for | ETL, warehousing | Sync scenarios | Data versioning | Full audit with user |

---

## DDL Triggers for Schema Change Tracking

DDL triggers fire on Data Definition Language events and are essential for tracking schema changes in audited environments.

### Server-Level DDL Trigger

```sql
CREATE TRIGGER trg_ServerDDLAudit
ON ALL SERVER
FOR DDL_SERVER_LEVEL_EVENTS
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @EventData XML = EVENTDATA();

    INSERT INTO master.dbo.ServerDDLAuditLog (
        EventType,
        EventTime,
        LoginName,
        DatabaseName,
        SchemaName,
        ObjectName,
        ObjectType,
        TSQLCommand,
        EventDataXml
    )
    VALUES (
        @EventData.value('(/EVENT_INSTANCE/EventType)[1]', 'NVARCHAR(100)'),
        @EventData.value('(/EVENT_INSTANCE/PostTime)[1]', 'DATETIME'),
        @EventData.value('(/EVENT_INSTANCE/LoginName)[1]', 'NVARCHAR(256)'),
        @EventData.value('(/EVENT_INSTANCE/DatabaseName)[1]', 'NVARCHAR(256)'),
        @EventData.value('(/EVENT_INSTANCE/SchemaName)[1]', 'NVARCHAR(256)'),
        @EventData.value('(/EVENT_INSTANCE/ObjectName)[1]', 'NVARCHAR(256)'),
        @EventData.value('(/EVENT_INSTANCE/ObjectType)[1]', 'NVARCHAR(100)'),
        @EventData.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'NVARCHAR(MAX)'),
        @EventData
    );
END;
GO
```

### Database-Level DDL Trigger

```sql
CREATE TRIGGER trg_DatabaseDDLAudit
ON DATABASE
FOR DDL_DATABASE_LEVEL_EVENTS
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @EventData XML = EVENTDATA();

    INSERT INTO dbo.DatabaseDDLAuditLog (
        EventType, PostTime, LoginName, UserName,
        SchemaName, ObjectName, ObjectType, CommandText
    )
    VALUES (
        @EventData.value('(/EVENT_INSTANCE/EventType)[1]', 'NVARCHAR(100)'),
        @EventData.value('(/EVENT_INSTANCE/PostTime)[1]', 'DATETIME'),
        @EventData.value('(/EVENT_INSTANCE/LoginName)[1]', 'NVARCHAR(256)'),
        @EventData.value('(/EVENT_INSTANCE/UserName)[1]', 'NVARCHAR(256)'),
        @EventData.value('(/EVENT_INSTANCE/SchemaName)[1]', 'NVARCHAR(256)'),
        @EventData.value('(/EVENT_INSTANCE/ObjectName)[1]', 'NVARCHAR(256)'),
        @EventData.value('(/EVENT_INSTANCE/ObjectType)[1]', 'NVARCHAR(100)'),
        @EventData.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'NVARCHAR(MAX)')
    );
END;
GO
```

### Common DDL Event Groups

| Event Group | Covers |
|------------|--------|
| `DDL_TABLE_EVENTS` | CREATE, ALTER, DROP TABLE |
| `DDL_VIEW_EVENTS` | CREATE, ALTER, DROP VIEW |
| `DDL_PROCEDURE_EVENTS` | CREATE, ALTER, DROP PROCEDURE |
| `DDL_FUNCTION_EVENTS` | CREATE, ALTER, DROP FUNCTION |
| `DDL_INDEX_EVENTS` | CREATE, ALTER, DROP INDEX |
| `DDL_TRIGGER_EVENTS` | CREATE, ALTER, DROP TRIGGER |
| `DDL_USER_EVENTS` | CREATE, ALTER, DROP USER |
| `DDL_ROLE_EVENTS` | CREATE, ALTER, DROP ROLE |
| `DDL_DATABASE_LEVEL_EVENTS` | All database-level DDL events |
| `DDL_SERVER_LEVEL_EVENTS` | All server-level DDL events |

---

## Login Auditing

### Built-In Login Auditing

SQL Server has a basic built-in login auditing feature configurable through SQL Server Management Studio or the registry.

```sql
-- Check current login audit level via registry
-- 0 = None, 1 = Successful logins only, 2 = Failed logins only, 3 = Both
EXEC xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'AuditLevel';
```

**Levels:**
- **None**: No login auditing.
- **Failed logins only**: Logs failed login attempts to the SQL Server error log.
- **Successful logins only**: Logs successful logins.
- **Both**: Logs all login attempts.

### Comprehensive Login Auditing with SQL Server Audit

```sql
CREATE SERVER AUDIT LoginAudit
TO FILE (FILEPATH = N'D:\SQLAudit\Logins\', MAXSIZE = 256 MB, MAX_ROLLOVER_FILES = 30);
GO

ALTER SERVER AUDIT LoginAudit WITH (STATE = ON);
GO

CREATE SERVER AUDIT SPECIFICATION LoginAuditSpec
FOR SERVER AUDIT LoginAudit
ADD (FAILED_LOGIN_GROUP),
ADD (SUCCESSFUL_LOGIN_GROUP),
ADD (LOGOUT_GROUP)
WITH (STATE = ON);
GO
```

### Analyzing Login Patterns

```sql
-- Find brute-force login attempts (more than 5 failures in 10 minutes)
;WITH LoginFailures AS (
    SELECT
        server_principal_name,
        CAST(event_time AS SMALLDATETIME) AS attempt_window,
        COUNT(*) AS failure_count
    FROM sys.fn_get_audit_file('D:\SQLAudit\Logins\*.sqlaudit', DEFAULT, DEFAULT)
    WHERE action_id = 'LGFL'  -- Login Failed
    GROUP BY server_principal_name, CAST(event_time AS SMALLDATETIME)
)
SELECT *
FROM LoginFailures
WHERE failure_count > 5
ORDER BY attempt_window DESC;

-- Find logins outside business hours
SELECT
    event_time,
    server_principal_name,
    client_ip,
    application_name
FROM sys.fn_get_audit_file('D:\SQLAudit\Logins\*.sqlaudit', DEFAULT, DEFAULT)
WHERE action_id = 'LGIS'  -- Login Succeeded
  AND (DATEPART(HOUR, event_time) < 6 OR DATEPART(HOUR, event_time) > 22)
  AND DATEPART(WEEKDAY, event_time) IN (1, 7)  -- weekends
ORDER BY event_time DESC;
```

---

## SQL Server Audit vs Extended Events for Auditing

Both SQL Server Audit and Extended Events (XEvents) can capture events, but they serve different purposes.

### SQL Server Audit

- **Purpose-built for compliance**: Structured output with standardized fields.
- **Tamper evidence**: Audit records are designed to be tamper-resistant.
- **Built on Extended Events**: Internally uses XEvents as the transport mechanism.
- **Predefined action groups**: Easy to configure without deep knowledge of events.
- **Guaranteed delivery** (with `ON_FAILURE = SHUTDOWN`): Can ensure no events are lost.
- **Standard output format**: `.sqlaudit` files readable by `fn_get_audit_file()`.

### Extended Events

- **General-purpose diagnostics**: Performance tuning, query analysis, debugging.
- **Highly granular**: Hundreds of events with fine-grained filtering.
- **Flexible targets**: Ring buffer, file, event counter, histogram, pair matching.
- **Lower overhead**: Can be more precisely targeted than audit specifications.
- **No compliance guarantee**: No built-in tamper evidence or delivery guarantee.

### When to Use Which

| Scenario | Recommended |
|----------|------------|
| Regulatory compliance (SOX, HIPAA, GDPR) | SQL Server Audit |
| Failed login monitoring for security | SQL Server Audit |
| DML auditing on sensitive tables | SQL Server Audit |
| Query performance investigation | Extended Events |
| Deadlock analysis | Extended Events |
| Wait statistics collection | Extended Events |
| Custom event correlation | Extended Events |
| Schema change tracking with DDL detail | SQL Server Audit + DDL Triggers |

### Using Extended Events for Security Monitoring

```sql
-- XEvent session for monitoring specific security events
CREATE EVENT SESSION SecurityMonitor ON SERVER
ADD EVENT sqlserver.login_failed
(
    ACTION (sqlserver.client_hostname, sqlserver.client_app_name, sqlserver.nt_username)
    WHERE sqlserver.client_hostname <> N'MonitoringServer'
),
ADD EVENT sqlserver.sql_statement_completed
(
    ACTION (sqlserver.username, sqlserver.database_name, sqlserver.sql_text)
    WHERE sqlserver.database_name = N'FinanceDB'
      AND sqlserver.username <> N'svc_etl'
)
ADD TARGET package0.event_file
(
    SET filename = N'D:\XEvents\SecurityMonitor.xel',
    max_file_size = 256,
    max_rollover_files = 10
)
WITH (
    MAX_MEMORY = 8192 KB,
    STARTUP_STATE = ON
);
GO

ALTER EVENT SESSION SecurityMonitor ON SERVER STATE = START;
```

---

## Regulatory Compliance (SOX, GDPR)

### Sarbanes-Oxley (SOX) Compliance

SOX focuses on the integrity and accuracy of financial reporting. Key SQL Server audit requirements:

**What SOX Requires:**
- Audit trail of all changes to financial data.
- Access control documentation and monitoring.
- Change management tracking for database schema.
- Segregation of duties (DBAs should not have unrestricted access to financial data).

**SQL Server Implementation:**

```sql
-- SOX: Audit all access to financial tables
CREATE DATABASE AUDIT SPECIFICATION SOX_FinancialDataAudit
FOR SERVER AUDIT SOXAudit
ADD (SELECT ON OBJECT::Finance.GeneralLedger BY public),
ADD (INSERT ON OBJECT::Finance.GeneralLedger BY public),
ADD (UPDATE ON OBJECT::Finance.GeneralLedger BY public),
ADD (DELETE ON OBJECT::Finance.GeneralLedger BY public),
ADD (SELECT ON OBJECT::Finance.AccountsPayable BY public),
ADD (INSERT ON OBJECT::Finance.AccountsPayable BY public),
ADD (UPDATE ON OBJECT::Finance.AccountsPayable BY public),
ADD (DELETE ON OBJECT::Finance.AccountsPayable BY public)
WITH (STATE = ON);

-- SOX: Track schema changes
CREATE DATABASE AUDIT SPECIFICATION SOX_SchemaChangeAudit
FOR SERVER AUDIT SOXAudit
ADD (SCHEMA_OBJECT_CHANGE_GROUP),
ADD (DATABASE_PERMISSION_CHANGE_GROUP),
ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP)
WITH (STATE = ON);
```

**SOX Best Practices:**
- Enable temporal tables on financial data for full version history.
- Use RLS to enforce segregation of duties.
- Archive audit logs for at least 7 years.
- Implement change management procedures for all DDL changes.
- Regularly review audit logs (automate alerting).

### General Data Protection Regulation (GDPR)

GDPR focuses on the protection of personal data for EU citizens. It affects data storage, access, and retention.

**Key GDPR Requirements for SQL Server:**

| Requirement | SQL Server Feature |
|------------|-------------------|
| Data discovery and classification | SQL Data Discovery & Classification |
| Right to be forgotten | DELETE with cascade + audit trail |
| Data portability | Export queries, JSON/XML output |
| Access logging | SQL Server Audit |
| Data minimization | DDM, RLS, views |
| Encryption at rest | TDE |
| Encryption in transit | TLS/SSL |
| Pseudonymization | Always Encrypted, DDM |
| Breach notification | Audit + alerting pipeline |

**SQL Server Implementation:**

```sql
-- GDPR: Classify sensitive columns (SQL Server 2019+)
ADD SENSITIVITY CLASSIFICATION TO dbo.Customers.Email
WITH (LABEL = 'Confidential - GDPR', INFORMATION_TYPE = 'Contact Info');

ADD SENSITIVITY CLASSIFICATION TO dbo.Customers.SSN
WITH (LABEL = 'Highly Confidential - GDPR', INFORMATION_TYPE = 'National ID');

-- Query classifications
SELECT
    t.name AS TableName,
    c.name AS ColumnName,
    sc.label,
    sc.information_type
FROM sys.sensitivity_classifications sc
JOIN sys.columns c ON sc.major_id = c.object_id AND sc.minor_id = c.column_id
JOIN sys.tables t ON c.object_id = t.object_id;

-- GDPR: Audit access to PII columns
CREATE DATABASE AUDIT SPECIFICATION GDPR_PIIAccessAudit
FOR SERVER AUDIT GDPRAudit
ADD (SELECT ON OBJECT::dbo.Customers BY public),
ADD (UPDATE ON OBJECT::dbo.Customers BY public)
WITH (STATE = ON);
```

**GDPR Right to Be Forgotten Implementation:**

```sql
-- Procedure to handle data erasure requests
CREATE PROCEDURE dbo.usp_GDPR_EraseCustomerData
    @CustomerId INT,
    @RequestId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Log the erasure request
        INSERT INTO dbo.GDPRErasureLog (RequestId, CustomerId, RequestDate, Status)
        VALUES (@RequestId, @CustomerId, GETUTCDATE(), 'Processing');

        -- Anonymize rather than delete (preserves referential integrity)
        UPDATE dbo.Customers
        SET FirstName = 'REDACTED',
            LastName = 'REDACTED',
            Email = 'redacted_' + CAST(@CustomerId AS NVARCHAR) + '@removed.com',
            PhoneNumber = NULL,
            Address = NULL,
            SSN = NULL,
            DateOfBirth = NULL,
            IsAnonymized = 1,
            AnonymizedDate = GETUTCDATE()
        WHERE CustomerId = @CustomerId;

        -- Update erasure log
        UPDATE dbo.GDPRErasureLog
        SET Status = 'Completed', CompletionDate = GETUTCDATE()
        WHERE RequestId = @RequestId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        UPDATE dbo.GDPRErasureLog
        SET Status = 'Failed', ErrorMessage = ERROR_MESSAGE()
        WHERE RequestId = @RequestId;

        THROW;
    END CATCH;
END;
```

### Audit Log Retention and Archival

```sql
-- Automated audit file archival process
-- Create a SQL Agent job that runs daily:

-- 1. Load audit files into a staging table
INSERT INTO dbo.AuditArchive (
    event_time, action_id, succeeded, server_principal_name,
    database_name, schema_name, object_name, statement
)
SELECT
    event_time, action_id, succeeded, server_principal_name,
    database_name, schema_name, object_name, statement
FROM sys.fn_get_audit_file('D:\SQLAudit\*.sqlaudit', DEFAULT, DEFAULT)
WHERE event_time < DATEADD(DAY, -1, GETUTCDATE())
  AND event_time >= DATEADD(DAY, -2, GETUTCDATE());

-- 2. Partition the archive table by month for efficient retention management
-- 3. Drop partitions older than retention period (e.g., 7 years for SOX)
```

---

## Common Interview Questions

### Q1: What is the difference between SQL Server Audit and SQL Trace/Profiler?

**A:** SQL Server Audit is built on Extended Events and is the recommended auditing framework from SQL Server 2008 onward. SQL Trace (and its GUI, Profiler) is a legacy tracing mechanism deprecated since SQL Server 2012. Key differences:
- Audit provides structured, compliance-ready output; Trace provides raw event streams.
- Audit has lower overhead because it uses the XEvents infrastructure.
- Audit supports tamper-evident logging (especially to the Windows Security Log).
- Audit has predefined action groups aligned with compliance requirements.
- Trace is still useful for ad-hoc query diagnostics but should not be used for production auditing.

### Q2: How would you set up auditing for a SOX-compliant financial database?

**A:** I would implement a multi-layered approach:
1. **SQL Server Audit** to file with `ON_FAILURE = SHUTDOWN` for critical financial tables (all DML and permission changes).
2. **Temporal tables** on core financial tables for full data version history.
3. **DDL triggers** to capture all schema changes with the exact DDL statement.
4. **RLS** to enforce segregation of duties (developers cannot access production financial data).
5. **TDE** for encryption at rest.
6. **Automated audit log review** via SQL Agent jobs that alert on anomalous patterns.
7. **Retention policy** of at least 7 years with partitioned archive tables and offsite backup.

### Q3: Explain the ON_FAILURE options for SQL Server Audit and when you would use each.

**A:** `ON_FAILURE` determines what happens when audit records cannot be written:
- **CONTINUE**: SQL Server continues operating even if audit records are lost. Use this for non-critical auditing where availability is more important than audit completeness.
- **SHUTDOWN**: SQL Server shuts down if audit records cannot be written. Use this for high-compliance environments (SOX, PCI-DSS) where losing audit records is unacceptable. Be aware that this can cause unplanned downtime if the audit target (disk) fails.

In practice, use `SHUTDOWN` only for the most critical compliance scenarios and ensure the audit target has redundant storage.

### Q4: How do you audit who accessed a specific table without impacting performance?

**A:** Use a Database Audit Specification scoped to the specific table rather than the entire schema:
```sql
CREATE DATABASE AUDIT SPECIFICATION TableAccessAudit
FOR SERVER AUDIT ProdAudit
ADD (SELECT ON OBJECT::dbo.SensitiveTable BY public)
WITH (STATE = ON);
```
This is more efficient than auditing all tables. Additionally:
- Write to file (higher throughput than event log).
- Set `QUEUE_DELAY` appropriately (higher values batch writes, reducing I/O).
- Avoid auditing service accounts that perform high-frequency reads unless required.

### Q5: What approaches exist for tracking data changes for audit purposes in SQL Server?

**A:** Four primary approaches:
1. **CDC** (Change Data Capture): Asynchronous, captures full before/after values from the transaction log. Best for ETL but lacks user context.
2. **Change Tracking**: Lightweight, synchronous, tracks which rows changed but not the values. Best for sync scenarios.
3. **Temporal Tables**: Automatic versioning with point-in-time queries. Best for data history and regulatory requirements.
4. **Custom triggers**: Maximum flexibility with user context capture. Best for full audit trails but has the highest performance impact.

The choice depends on whether you need data values (CDC/temporal), user context (triggers), or just change flags (Change Tracking).

### Q6: How do you handle GDPR "Right to be Forgotten" while maintaining audit trail integrity?

**A:** This is a tension in GDPR compliance. The approach is:
- **Anonymize rather than delete**: Replace PII with generic values while keeping the record structure intact for referential integrity.
- **Maintain an erasure log**: Document when and why data was erased (the erasure itself must be audited).
- **Exclude PII from audit logs**: Configure audit specifications to avoid capturing statement text that contains PII, or implement a process to redact PII from archived audit logs.
- **Separate retention policies**: Audit metadata (who accessed what) may have different retention requirements than the PII itself.

---

## Tips

- **Always use file-based auditing for production** environments with high event volumes. Windows Event Log has throughput limitations that can cause event loss under load.
- **Test ON_FAILURE = SHUTDOWN carefully**. Simulate audit target failures in a non-production environment to understand the behavior before using this in production.
- **Automate audit log review**. Unreviewed audit logs provide no security value. Build SQL Agent jobs or SIEM integrations that alert on suspicious patterns (failed logins, off-hours access, privilege escalation).
- **Use temporal tables for data versioning** in compliance scenarios. They are lower maintenance than CDC and provide natural point-in-time query support.
- **Partition audit archive tables** by date. This allows efficient retention management (drop old partitions) and faster queries against recent data.
- **Document your audit configuration** as part of your compliance documentation. Auditors will ask what is being captured and how it is protected.
- **Protect audit files at the OS level**. Use NTFS permissions to prevent SQL Server service accounts and DBAs from deleting or modifying audit files.
- **Remember that SQL Server Audit is built on Extended Events**. If you need more granular or custom event capture beyond predefined action groups, use XEvents directly.
- **For GDPR, use SQL Data Discovery and Classification** (available in SSMS 17.5+ and SQL Server 2019+) to inventory PII columns. This is often the first step auditors request.
- **Consider separation of audit administration**. The principal managing audit objects should ideally not be the same principal with access to audited data (segregation of duties).

---
