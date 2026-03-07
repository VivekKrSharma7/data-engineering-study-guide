# SQL Server Security Model & Authentication

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Authentication Modes](#authentication-modes)
2. [Logins vs Users](#logins-vs-users)
3. [Server Roles vs Database Roles](#server-roles-vs-database-roles)
4. [Schemas](#schemas)
5. [Permissions Hierarchy](#permissions-hierarchy)
6. [GRANT, DENY, and REVOKE](#grant-deny-and-revoke)
7. [Contained Databases and Contained Users](#contained-databases-and-contained-users)
8. [Service Accounts and SQL Server Agent Security](#service-accounts-and-sql-server-agent-security)
9. [Proxy Accounts and Credential Objects](#proxy-accounts-and-credential-objects)
10. [Certificate-Based Authentication](#certificate-based-authentication)
11. [Azure AD (Entra ID) Authentication](#azure-ad-entra-id-authentication)
12. [Common Interview Questions](#common-interview-questions)
13. [Tips](#tips)

---

## Authentication Modes

SQL Server supports two authentication modes, configured at the instance level.

### Windows Authentication Mode (Recommended)

- Uses Windows/Active Directory credentials (Kerberos or NTLM).
- No passwords stored in SQL Server.
- Supports group-based access (grant a Windows group login to SQL Server, and all members inherit access).
- Kerberos delegation enables double-hop scenarios.

### Mixed Mode (Windows + SQL Server Authentication)

- Enables both Windows logins and SQL Server logins (username/password stored in SQL Server).
- Required for applications that cannot pass Windows tokens (e.g., some legacy apps, cross-domain scenarios, Linux-based clients).
- The `sa` account is enabled in mixed mode -- **always rename or disable it in production**.

```sql
-- Check current authentication mode
-- 1 = Windows only, 2 = Mixed
SELECT SERVERPROPERTY('IsIntegratedSecurityOnly') AS AuthMode;

-- Note: Changing auth mode requires a SQL Server restart.
-- It is configured via SQL Server Configuration Manager or registry.
```

### Security Best Practices for Authentication

- Prefer Windows Authentication whenever possible.
- If Mixed Mode is required, enforce strong password policies on SQL logins.
- Disable or rename the `sa` account.
- Audit failed login attempts.

```sql
-- Create a SQL login with password policy enforcement
CREATE LOGIN [AppServiceLogin]
WITH PASSWORD = 'C0mpl3x!P@ssw0rd',
     CHECK_POLICY = ON,
     CHECK_EXPIRATION = ON,
     DEFAULT_DATABASE = [YourDatabase];
```

---

## Logins vs Users

This is one of the most fundamental distinctions in SQL Server security and a frequent interview topic.

### Logins (Server Level)

A **login** is a server-level principal that allows connection to the SQL Server instance.

```sql
-- Windows login
CREATE LOGIN [DOMAIN\JohnDoe] FROM WINDOWS;

-- SQL Server login
CREATE LOGIN [AppLogin] WITH PASSWORD = 'Str0ng!Pass';

-- View all logins
SELECT name, type_desc, is_disabled
FROM sys.server_principals
WHERE type IN ('S', 'U', 'G');
-- S = SQL login, U = Windows login, G = Windows group
```

### Users (Database Level)

A **user** is a database-level principal mapped to a login. A login without a corresponding user in a database cannot access that database (with some exceptions like sysadmin members).

```sql
-- Create a user mapped to a login
USE [YourDatabase];
CREATE USER [JohnDoe] FOR LOGIN [DOMAIN\JohnDoe];

-- Create a user mapped to a SQL login
CREATE USER [AppUser] FOR LOGIN [AppLogin]
WITH DEFAULT_SCHEMA = [dbo];

-- View all users in the current database
SELECT name, type_desc, default_schema_name
FROM sys.database_principals
WHERE type IN ('S', 'U', 'G');
```

### The Relationship

```
Instance Level              Database Level
+------------------+        +------------------+
| LOGIN            | -----> | USER             |
| (server_principal)|       | (database_principal)|
| SID: 0xABCD...  |        | SID: 0xABCD...   |
+------------------+        +------------------+
```

A login and its mapped user share the same **SID**. When you restore or attach a database to a different server, the SIDs may not match, creating **orphaned users**.

```sql
-- Find orphaned users
SELECT dp.name AS OrphanedUser
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type IN ('S', 'U')
  AND sp.sid IS NULL
  AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys');

-- Fix orphaned users
ALTER USER [AppUser] WITH LOGIN = [AppLogin];
```

---

## Server Roles vs Database Roles

### Fixed Server Roles

| Role | Purpose |
|---|---|
| **sysadmin** | Full control over the entire instance |
| **serveradmin** | Server-wide configuration (sp_configure, shutdown) |
| **securityadmin** | Manage logins and permissions; can GRANT server permissions |
| **processadmin** | Kill processes |
| **setupadmin** | Manage linked servers |
| **bulkadmin** | Run BULK INSERT |
| **diskadmin** | Manage disk files |
| **dbcreator** | Create, alter, drop, restore databases |
| **public** | Every login belongs to this; default minimal permissions |

```sql
-- Check server role membership
SELECT
    sp.name AS LoginName,
    sr.name AS RoleName
FROM sys.server_role_members srm
JOIN sys.server_principals sp ON srm.member_principal_id = sp.principal_id
JOIN sys.server_principals sr ON srm.role_principal_id = sr.principal_id;

-- Add a login to a server role
ALTER SERVER ROLE [dbcreator] ADD MEMBER [DOMAIN\JohnDoe];
```

### User-Defined Server Roles (SQL Server 2012+)

```sql
-- Create a custom server role for monitoring
CREATE SERVER ROLE [MonitorRole];
GRANT VIEW SERVER STATE TO [MonitorRole];
GRANT VIEW ANY DATABASE TO [MonitorRole];
ALTER SERVER ROLE [MonitorRole] ADD MEMBER [DOMAIN\MonitoringService];
```

### Fixed Database Roles

| Role | Purpose |
|---|---|
| **db_owner** | Full control within the database |
| **db_datareader** | SELECT on all tables/views |
| **db_datawriter** | INSERT, UPDATE, DELETE on all tables/views |
| **db_ddladmin** | Run DDL (CREATE, ALTER, DROP) |
| **db_securityadmin** | Manage role membership and permissions |
| **db_backupoperator** | Back up the database |
| **db_denydatareader** | Cannot SELECT (overrides db_datareader) |
| **db_denydatawriter** | Cannot INSERT/UPDATE/DELETE |
| **public** | Default role for all users |

```sql
-- Add user to database roles
ALTER ROLE [db_datareader] ADD MEMBER [AppUser];
ALTER ROLE [db_datawriter] ADD MEMBER [AppUser];

-- Create a custom database role
CREATE ROLE [ReportReader];
GRANT SELECT ON SCHEMA::[Reports] TO [ReportReader];
ALTER ROLE [ReportReader] ADD MEMBER [DOMAIN\ReportService];
```

---

## Schemas

A **schema** is a namespace container for database objects. Schemas provide a powerful way to organize objects and manage permissions.

### Key Concepts

- Every database object belongs to exactly one schema.
- The default schema for new users is `dbo` unless specified otherwise.
- Permissions granted at the schema level apply to **all objects in that schema**, including future objects.

```sql
-- Create schemas for logical separation
CREATE SCHEMA [Sales] AUTHORIZATION [dbo];
CREATE SCHEMA [HR] AUTHORIZATION [dbo];
CREATE SCHEMA [Reporting] AUTHORIZATION [dbo];

-- Create a table in a specific schema
CREATE TABLE [Sales].[Orders] (
    OrderID INT PRIMARY KEY,
    CustomerID INT,
    OrderDate DATETIME2
);

-- Grant SELECT on all current and future objects in the schema
GRANT SELECT ON SCHEMA::[Reporting] TO [ReportReader];
```

### Schema-Level Security Pattern

This is a powerful real-world pattern: instead of granting permissions on individual tables, organize tables into schemas and grant permissions at the schema level.

```
Schema: [Sales]       -> Tables: Orders, Customers, Products
Schema: [HR]          -> Tables: Employees, Salaries, Benefits
Schema: [Reporting]   -> Views: vw_SalesReport, vw_HRReport

Role: SalesTeam       -> GRANT SELECT, INSERT, UPDATE ON SCHEMA::[Sales]
Role: HRTeam          -> GRANT SELECT, INSERT, UPDATE ON SCHEMA::[HR]
Role: ReportViewers   -> GRANT SELECT ON SCHEMA::[Reporting]
```

New tables added to the `Sales` schema automatically inherit the permissions -- no manual grants needed.

---

## Permissions Hierarchy

SQL Server permissions follow a strict hierarchy. Understanding this hierarchy is critical for troubleshooting access issues and designing secure systems.

### The Hierarchy (Top to Bottom)

```
Server Level
  |
  +-- Server Permissions (VIEW SERVER STATE, ALTER ANY DATABASE, etc.)
  |
  +-- Database Level
        |
        +-- Database Permissions (CREATE TABLE, BACKUP DATABASE, etc.)
        |
        +-- Schema Level
              |
              +-- Schema Permissions (SELECT, INSERT on all objects in schema)
              |
              +-- Object Level
                    |
                    +-- Object Permissions (SELECT, INSERT on specific table)
                    |
                    +-- Column Level
                          |
                          +-- Column Permissions (SELECT on specific columns)
```

### Permission Inheritance

A permission granted at a higher level flows down. `GRANT SELECT ON SCHEMA::[Sales]` means SELECT on every table, view, and function in that schema.

### Effective Permissions

```sql
-- Check effective permissions for the current user
SELECT * FROM fn_my_permissions(NULL, 'SERVER');
SELECT * FROM fn_my_permissions(NULL, 'DATABASE');
SELECT * FROM fn_my_permissions('Sales.Orders', 'OBJECT');

-- Check permissions for a specific user
EXECUTE AS USER = 'AppUser';
SELECT * FROM fn_my_permissions('Sales.Orders', 'OBJECT');
REVERT;
```

---

## GRANT, DENY, and REVOKE

These three statements control all permissions in SQL Server.

### How They Interact

| Statement | Effect |
|---|---|
| **GRANT** | Gives permission |
| **DENY** | Explicitly blocks permission (overrides GRANT) |
| **REVOKE** | Removes a previous GRANT or DENY (returns to neutral) |

### The Critical Rule: DENY Wins

If a user is a member of multiple roles and one role has GRANT SELECT while another has DENY SELECT, the **DENY wins**. This is the single most important permission rule in SQL Server.

```sql
-- Example: DENY overrides GRANT
CREATE ROLE [CanRead];
CREATE ROLE [CannotReadSalary];

GRANT SELECT ON SCHEMA::[HR] TO [CanRead];
DENY SELECT ON [HR].[Salaries] TO [CannotReadSalary];

-- User in both roles: can read all HR tables EXCEPT Salaries
ALTER ROLE [CanRead] ADD MEMBER [JohnDoe];
ALTER ROLE [CannotReadSalary] ADD MEMBER [JohnDoe];
```

### Granular Permission Examples

```sql
-- Server-level permissions
GRANT VIEW SERVER STATE TO [MonitorLogin];
GRANT ALTER ANY DATABASE TO [DeployLogin];

-- Database-level permissions
USE [YourDatabase];
GRANT CREATE TABLE TO [DevUser];
GRANT EXECUTE ON SCHEMA::[dbo] TO [AppUser];

-- Object-level permissions
GRANT SELECT, INSERT, UPDATE ON [Sales].[Orders] TO [SalesApp];
DENY DELETE ON [Sales].[Orders] TO [SalesApp];

-- Column-level permissions
GRANT SELECT ON [HR].[Employees] (EmployeeID, FirstName, LastName, Department)
TO [ManagerRole];
-- Note: Salary column is NOT listed, so it cannot be selected.

-- Revoke a previous grant
REVOKE SELECT ON [HR].[Salaries] FROM [CanRead];
```

### Permission Chains and Ownership Chaining

When a stored procedure owned by `dbo` accesses a table also owned by `dbo`, SQL Server skips the permission check on the table. This is **ownership chaining**.

```sql
-- Ownership chaining example
-- Both the proc and table are in dbo schema (same owner)
CREATE PROCEDURE dbo.GetOrders AS
    SELECT * FROM dbo.Orders;  -- No separate SELECT permission needed
GO

GRANT EXECUTE ON dbo.GetOrders TO [AppUser];
-- AppUser can execute the proc and see the data,
-- even without direct SELECT on dbo.Orders.
```

This breaks when the proc and table have different owners or are in different databases (unless cross-database ownership chaining is enabled).

---

## Contained Databases and Contained Users

Introduced in SQL Server 2012, contained databases reduce dependencies on the SQL Server instance.

### What Is a Contained Database?

A contained database stores all metadata and settings within itself, making it more portable across instances. The key security benefit is **contained users** -- users who authenticate directly at the database level without needing a server-level login.

```sql
-- Enable contained database authentication at the instance level
EXEC sp_configure 'contained database authentication', 1;
RECONFIGURE;

-- Create a contained database
CREATE DATABASE [PortableDB] CONTAINMENT = PARTIAL;

-- Create a contained user (no login required)
USE [PortableDB];
CREATE USER [AppUser] WITH PASSWORD = 'C0mpl3x!P@ss';
```

### Benefits

- **Portability:** When you move or restore the database to another server, the users come with it. No orphaned users.
- **Isolation:** Authentication is self-contained; no dependency on server-level logins.
- **Azure SQL Database:** All users in Azure SQL Database are effectively contained users.

### Caveats

- Contained users with passwords cannot benefit from Windows Group membership or Kerberos.
- Some features (cross-database queries, certain system catalog views) have limitations.
- Password policies for contained users are enforced by the database, not Active Directory.

---

## Service Accounts and SQL Server Agent Security

### SQL Server Service Accounts

SQL Server services run under Windows accounts. The choice of service account impacts security and functionality.

| Account Type | Use Case | Notes |
|---|---|---|
| **Domain User Account** | Production environments | Preferred; follow principle of least privilege |
| **Group Managed Service Account (gMSA)** | Modern AD environments | Password managed by AD automatically; most secure option |
| **Virtual Account** (NT Service\MSSQLSERVER) | Default for named instances | Limited network access |
| **Local System** | Never use in production | Excessive privileges; security risk |

### SQL Server Agent Security

SQL Server Agent runs jobs, schedules, alerts, and SSIS packages. Its security model includes:

- **Agent Service Account:** The Windows account under which the Agent service runs.
- **Job Owner:** Each job has an owner (a SQL login). The job runs with the permissions of its owner for T-SQL steps.
- **Job Step Run-As:** You can specify a different security context for specific job step types.

```sql
-- View job owners
SELECT
    j.name AS JobName,
    l.name AS OwnerLogin
FROM msdb.dbo.sysjobs j
JOIN sys.server_principals l ON j.owner_sid = l.sid;

-- Change job owner to sa (common practice for system jobs)
EXEC msdb.dbo.sp_update_job
    @job_name = 'YourJob',
    @owner_login_name = 'sa';
```

---

## Proxy Accounts and Credential Objects

### Credential Objects

A **credential** maps a SQL Server identity to an external (Windows) identity. It stores the Windows username and password securely.

```sql
-- Create a credential
CREATE CREDENTIAL [ETLCredential]
WITH IDENTITY = 'DOMAIN\ETLServiceAccount',
     SECRET = 'P@ssw0rd!';
```

### Proxy Accounts

A **proxy** wraps a credential and makes it available for SQL Server Agent job steps. Non-sysadmin users cannot run CmdExec, PowerShell, or SSIS job steps without a proxy.

```sql
-- Create a proxy
EXEC msdb.dbo.sp_add_proxy
    @proxy_name = 'ETL_Proxy',
    @credential_name = 'ETLCredential',
    @description = 'Runs ETL packages as the ETL service account';

-- Associate the proxy with a subsystem (SSIS)
EXEC msdb.dbo.sp_grant_proxy_to_subsystem
    @proxy_name = 'ETL_Proxy',
    @subsystem_id = 11;  -- 11 = SSIS

-- Grant a login permission to use the proxy
EXEC msdb.dbo.sp_grant_login_to_proxy
    @proxy_name = 'ETL_Proxy',
    @login_name = 'DOMAIN\ETLDeveloper';
```

### Real-World Pattern

```
SQL Agent Job: "Nightly ETL"
  Step 1: T-SQL (runs as job owner)         -> Truncate staging tables
  Step 2: SSIS Package (runs via proxy)     -> Load data from files using
                                               DOMAIN\ETLServiceAccount
  Step 3: T-SQL (runs as job owner)         -> Execute merge procedures
```

The proxy allows the SSIS step to access network file shares using the ETL service account's credentials, even though the SQL Agent service itself runs under a different account.

---

## Certificate-Based Authentication

Certificates enable cross-database and cross-server permission delegation without sharing passwords.

### Common Use Case: Allowing a Stored Procedure to Access Another Database

```sql
-- Step 1: Create a certificate in the source database
USE [SourceDB];
CREATE CERTIFICATE [CrossDBCert]
WITH SUBJECT = 'Certificate for cross-database access';

-- Step 2: Sign the stored procedure with the certificate
ADD SIGNATURE TO [dbo].[CrossDBProc]
BY CERTIFICATE [CrossDBCert];

-- Step 3: Back up the certificate
BACKUP CERTIFICATE [CrossDBCert]
TO FILE = 'C:\Certs\CrossDBCert.cer'
WITH PRIVATE KEY (
    FILE = 'C:\Certs\CrossDBCert.pvk',
    ENCRYPTION BY PASSWORD = 'CertP@ss!'
);

-- Step 4: Create the certificate in the target database
USE [TargetDB];
CREATE CERTIFICATE [CrossDBCert]
FROM FILE = 'C:\Certs\CrossDBCert.cer'
WITH PRIVATE KEY (
    FILE = 'C:\Certs\CrossDBCert.pvk',
    DECRYPTION BY PASSWORD = 'CertP@ss!'
);

-- Step 5: Create a user from the certificate in the target database
CREATE USER [CrossDBCertUser] FROM CERTIFICATE [CrossDBCert];

-- Step 6: Grant necessary permissions to the certificate user
GRANT SELECT ON [dbo].[TargetTable] TO [CrossDBCertUser];
```

Now when `CrossDBProc` in SourceDB is executed, it has SELECT access to TargetDB's TargetTable through the certificate, without enabling cross-database ownership chaining or using `TRUSTWORTHY`.

### Module Signing

Module signing (signing procedures, functions, or triggers with certificates) is the **recommended alternative** to `TRUSTWORTHY ON` and `EXECUTE AS` for privilege escalation scenarios.

---

## Azure AD (Entra ID) Authentication

For SQL Server 2022+ and Azure SQL, Microsoft Entra ID (formerly Azure AD) authentication provides modern identity management.

### Azure SQL Database

```sql
-- Create a user from Azure AD
CREATE USER [john@contoso.com] FROM EXTERNAL PROVIDER;

-- Create a user from an Azure AD group
CREATE USER [DataEngineers] FROM EXTERNAL PROVIDER;

-- Grant permissions normally
ALTER ROLE [db_datareader] ADD MEMBER [DataEngineers];
```

### SQL Server 2022 with Azure AD

```sql
-- Requires Azure Arc or Azure extension for SQL Server
-- Configure Azure AD admin in the Azure portal

-- Then create a login from Azure AD
CREATE LOGIN [john@contoso.com] FROM EXTERNAL PROVIDER;

-- Map to a database user
USE [YourDatabase];
CREATE USER [john@contoso.com] FOR LOGIN [john@contoso.com];
```

### Benefits

- Single sign-on with corporate identity.
- Multi-factor authentication (MFA) support.
- Centralized access management through Azure AD groups.
- Token-based authentication (no passwords stored in SQL Server).
- Conditional Access policies apply.

---

## Common Interview Questions

### Q1: What is the difference between a login and a user in SQL Server?

**A:** A login is a server-level security principal that controls access to the SQL Server instance. A user is a database-level principal mapped to a login that controls access within a specific database. A login can exist without any database users (it can connect but not access any user database). A user must be mapped to a login (or be a contained user) to function. They are linked by their SID, and when a database is moved to a different server, the SID mismatch creates orphaned users.

### Q2: Explain what happens when a user has both GRANT and DENY on the same object.

**A:** DENY always takes precedence over GRANT. If a user has SELECT granted through one role membership and SELECT denied through another role, the DENY wins and the user cannot SELECT from that object. The only way to override a DENY is to remove it (REVOKE the DENY). This is a foundational rule of SQL Server's security model and cannot be bypassed except by being a member of sysadmin (which bypasses all permission checks).

### Q3: What are orphaned users and how do you fix them?

**A:** Orphaned users occur when a database user's SID does not match any login's SID on the server. This commonly happens after restoring a database to a different server or after detaching/attaching databases. You can find them by joining `sys.database_principals` with `sys.server_principals` on SID and looking for mismatches. Fix them with `ALTER USER [username] WITH LOGIN = [loginname]`, which re-maps the SID.

### Q4: Explain ownership chaining. When does it break?

**A:** Ownership chaining occurs when a user executes an object (e.g., a stored procedure) that references other objects, and the referencing and referenced objects have the same owner. SQL Server skips the permission check on the referenced object, relying instead on the permissions check on the calling object. It breaks when the objects have different owners, when they are in different databases (unless cross-database ownership chaining is enabled), or when dynamic SQL is used inside the procedure (because dynamic SQL is evaluated as the caller, not the owner).

### Q5: What is a contained database and when would you use one?

**A:** A contained database authenticates users at the database level without requiring server-level logins. Users and their credentials are stored within the database itself. This is useful for portability (moving databases between servers without login re-creation), multi-tenant scenarios, and aligns with Azure SQL Database's model where all users are effectively contained. The tradeoff is that contained users cannot leverage Windows integrated authentication or group memberships.

### Q6: How would you implement least-privilege access for an ETL application?

**A:** I would create a dedicated SQL login for the ETL application. In each target database, I would create a user mapped to that login. Rather than adding it to broad roles like `db_owner` or `db_datawriter`, I would create a custom database role (e.g., `ETLRole`) and grant only the specific permissions needed: INSERT and TRUNCATE (via ALTER) on staging tables, EXECUTE on the merge/load procedures, and SELECT on lookup tables. For SSIS packages running through SQL Agent, I would use a proxy account backed by a credential, so the package runs under a controlled Windows identity with access to only the required file shares and network resources.

### Q7: What is the difference between `EXECUTE AS` and module signing with certificates? When would you choose each?

**A:** `EXECUTE AS` changes the security context of a module to a specified user, and when used with `EXECUTE AS OWNER`, it requires `TRUSTWORTHY ON` for cross-database access, which is a security risk because it grants the database owner elevated server-level trust. Module signing with certificates is more secure: you sign the procedure with a certificate, create a user from that certificate in the target database, and grant only the specific permissions needed. The certificate-based user has no login and cannot be used interactively. I would always choose module signing over `TRUSTWORTHY` in production environments.

### Q8: A developer says they need sysadmin access to do their job. How do you handle this?

**A:** I would ask what specific tasks they need to perform and find the minimal permissions required. For example:
- Need to create databases? Grant `dbcreator` server role.
- Need to see query plans and server stats? Grant `VIEW SERVER STATE`.
- Need to manage their own database? Grant `db_owner` on that specific database.
- Need to run profiler/extended events? Grant `ALTER TRACE`.

The principle of least privilege means granting only what is necessary. Sysadmin bypasses all security checks and should be restricted to DBAs who manage the instance itself.

---

## Tips

- **Never use the `sa` account for application connections.** Rename it, disable it, and create specific service accounts instead.
- **Use Windows Groups for access management** rather than individual logins. When someone leaves the team, disabling their AD account automatically revokes SQL Server access.
- **Schema-based permissions are your best friend.** They scale far better than object-level grants and automatically cover new objects.
- **Audit regularly.** Use SQL Server Audit or Extended Events to track login failures, permission changes, and privileged operations.
- **DENY is a blunt instrument.** Use it sparingly and document it, because it overrides all GRANTs and can create confusing access patterns.
- **Test permissions with `EXECUTE AS`.** Before deploying, switch context to the target user and verify they can do exactly what they need -- no more, no less.
- **Contained databases are the future.** Azure SQL Database uses this model exclusively, so understanding it is essential for cloud migration.
- **In interviews, always emphasize the principle of least privilege.** Every security answer should come back to granting the minimum permissions required for the task.
