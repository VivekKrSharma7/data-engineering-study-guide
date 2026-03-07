# SQL Server Agent & Job Scheduling

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [SQL Server Agent Architecture](#sql-server-agent-architecture)
2. [Jobs: The Core Unit of Automation](#jobs-the-core-unit-of-automation)
3. [Job Steps and Step Types](#job-steps-and-step-types)
4. [Schedules](#schedules)
5. [Operators and Notifications](#operators-and-notifications)
6. [Alerts](#alerts)
7. [Proxy Accounts](#proxy-accounts)
8. [Job Categories](#job-categories)
9. [Multi-Server Jobs (MSX/TSX)](#multi-server-jobs)
10. [Monitoring Job Execution](#monitoring-job-execution)
11. [Key msdb System Tables](#key-msdb-system-tables)
12. [Common Interview Questions](#common-interview-questions)
13. [Tips](#tips)

---

## SQL Server Agent Architecture

SQL Server Agent is a Windows service (`SQLSERVERAGENT`) that executes scheduled administrative tasks called **jobs**. It is tightly integrated with the SQL Server Database Engine and stores all its metadata in the **msdb** system database.

### Key Architectural Components

| Component | Purpose |
|-----------|---------|
| **SQL Server Agent Service** | Windows service that hosts the job scheduler and execution engine |
| **msdb Database** | Stores job definitions, schedules, history, alerts, operators, and proxy accounts |
| **Job Scheduler** | Internal component that evaluates schedules and queues jobs for execution |
| **Alert Engine** | Monitors the Windows Application Event Log and SQL Server error log for alert conditions |
| **Mail Subsystem** | Sends notifications via Database Mail (replaces the deprecated SQLMail) |

### Service Account Considerations

- The SQL Server Agent service runs under a Windows service account.
- This account needs appropriate permissions on the OS and SQL Server instance.
- Best practice: use a dedicated domain service account with least-privilege or a Group Managed Service Account (gMSA).
- The Agent service account is automatically mapped to the `sysadmin` fixed server role.

### Starting and Stopping

```sql
-- Check if SQL Server Agent is running (from within SQL Server)
SELECT servicename, status_desc, startup_type_desc
FROM sys.dm_server_services
WHERE servicename LIKE '%Agent%';
```

- The Agent service can be configured to **auto-start** with the SQL Server service.
- If it stops unexpectedly, SQL Server continues running but no scheduled jobs will fire.

---

## Jobs: The Core Unit of Automation

A **job** is a specified series of actions (steps) that SQL Server Agent performs. Jobs can run on a schedule, in response to an alert, or be started manually.

### Job Properties

| Property | Description |
|----------|-------------|
| **Name** | Unique identifier for the job within the instance |
| **Owner** | The login that owns the job; affects security context |
| **Category** | Logical grouping for organizational purposes |
| **Description** | Free-text description of what the job does |
| **Steps** | Ordered list of actions the job performs |
| **Schedules** | When the job should run automatically |
| **Notifications** | What happens when the job succeeds, fails, or completes |
| **Targets** | Which server(s) the job runs on (local or multi-server) |

### Creating a Basic Job with T-SQL

```sql
USE msdb;
GO

-- Step 1: Create the job
EXEC sp_add_job
    @job_name = N'Daily_ETL_Load',
    @description = N'Runs the nightly ETL pipeline to load the data warehouse.',
    @owner_login_name = N'sa',
    @category_name = N'Data Collector',
    @enabled = 1;

-- Step 2: Add a job step
EXEC sp_add_jobstep
    @job_name = N'Daily_ETL_Load',
    @step_name = N'Execute ETL Stored Procedure',
    @step_id = 1,
    @subsystem = N'TSQL',
    @command = N'EXEC dbo.usp_RunDailyETL;',
    @database_name = N'StagingDB',
    @on_success_action = 1,  -- Quit with success
    @on_fail_action = 2,     -- Quit with failure
    @retry_attempts = 2,
    @retry_interval = 5;     -- 5 minutes between retries

-- Step 3: Create a schedule (daily at 2:00 AM)
EXEC sp_add_jobschedule
    @job_name = N'Daily_ETL_Load',
    @name = N'Nightly_2AM',
    @freq_type = 4,           -- Daily
    @freq_interval = 1,       -- Every 1 day
    @active_start_time = 020000;  -- 2:00:00 AM

-- Step 4: Set the target server (local)
EXEC sp_add_jobserver
    @job_name = N'Daily_ETL_Load',
    @server_name = N'(LOCAL)';
GO
```

---

## Job Steps and Step Types

Each job consists of one or more **steps**. Steps execute in order, and you can define branching logic based on success or failure of each step.

### Step Flow Control

Each step has two critical properties:

- **On Success Action**: What to do if the step succeeds (go to next step, go to a specific step, quit with success, quit with failure).
- **On Failure Action**: What to do if the step fails (same options as above).

This allows building complex workflows with conditional branching.

### Job Step Types (Subsystems)

| Subsystem | Description |
|-----------|-------------|
| **T-SQL (TSQL)** | Executes Transact-SQL statements against a database |
| **Operating System (CmdExec)** | Runs an operating system command or executable |
| **PowerShell** | Executes a PowerShell script in the SQL Server Agent PowerShell subsystem |
| **SSIS Package** | Runs a SQL Server Integration Services package |
| **Replication** | Steps for Snapshot, Log Reader, Distribution, Merge, and Queue Reader Agents |
| **Analysis Services Command** | Executes an XMLA command against SSAS |
| **Analysis Services Query** | Runs an MDX query against SSAS |

### T-SQL Step Example

```sql
EXEC sp_add_jobstep
    @job_name = N'Daily_ETL_Load',
    @step_name = N'Truncate Staging Tables',
    @step_id = 1,
    @subsystem = N'TSQL',
    @command = N'
        TRUNCATE TABLE dbo.Staging_Customers;
        TRUNCATE TABLE dbo.Staging_Orders;
        TRUNCATE TABLE dbo.Staging_Products;
    ',
    @database_name = N'StagingDB',
    @on_success_action = 3,  -- Go to next step
    @on_fail_action = 2;     -- Quit with failure
```

### PowerShell Step Example

```sql
EXEC sp_add_jobstep
    @job_name = N'Daily_ETL_Load',
    @step_name = N'Archive Source Files',
    @step_id = 3,
    @subsystem = N'PowerShell',
    @command = N'
        $sourceDir = "D:\DataFeed\Incoming"
        $archiveDir = "D:\DataFeed\Archive\$(Get-Date -Format ''yyyyMMdd'')"
        if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir }
        Move-Item -Path "$sourceDir\*.csv" -Destination $archiveDir -Force
    ',
    @on_success_action = 1,
    @on_fail_action = 2;
```

### SSIS Package Step Example

```sql
EXEC sp_add_jobstep
    @job_name = N'Daily_ETL_Load',
    @step_name = N'Run SSIS ETL Package',
    @step_id = 2,
    @subsystem = N'SSIS',
    @command = N'/ISSERVER "\SSISDB\ETL_Project\ETL_Project\MainPackage.dtsx" /SERVER "." /ENVREFERENCE 5',
    @database_name = N'master',
    @on_success_action = 3,
    @on_fail_action = 2;
```

### CmdExec Step Example

```sql
EXEC sp_add_jobstep
    @job_name = N'Daily_ETL_Load',
    @step_name = N'Run External Batch Script',
    @step_id = 4,
    @subsystem = N'CmdExec',
    @command = N'D:\Scripts\post_etl_validation.bat',
    @on_success_action = 1,
    @on_fail_action = 2;
```

---

## Schedules

Schedules define **when** a job should be triggered automatically. A single schedule can be shared across multiple jobs, and a single job can have multiple schedules.

### Schedule Frequency Types

| freq_type Value | Meaning |
|-----------------|---------|
| 1 | Once |
| 4 | Daily |
| 8 | Weekly |
| 16 | Monthly |
| 32 | Monthly relative (e.g., second Tuesday) |
| 64 | Starts when SQL Server Agent service starts |
| 128 | Runs when the computer is idle |

### Common Schedule Patterns

```sql
-- Every 15 minutes during business hours (Mon-Fri, 8 AM - 6 PM)
EXEC sp_add_jobschedule
    @job_name = N'Incremental_Data_Refresh',
    @name = N'Every_15min_Business_Hours',
    @freq_type = 8,                -- Weekly
    @freq_interval = 62,           -- Mon(2)+Tue(4)+Wed(8)+Thu(16)+Fri(32) = 62
    @freq_subday_type = 4,         -- Minutes
    @freq_subday_interval = 15,    -- Every 15 minutes
    @active_start_time = 080000,   -- Start at 8:00 AM
    @active_end_time = 180000;     -- End at 6:00 PM

-- First Sunday of every month at midnight
EXEC sp_add_jobschedule
    @job_name = N'Monthly_Full_Reindex',
    @name = N'First_Sunday_Monthly',
    @freq_type = 32,               -- Monthly relative
    @freq_interval = 1,            -- Sunday
    @freq_relative_interval = 1,   -- First
    @freq_recurrence_factor = 1,   -- Every 1 month
    @active_start_time = 000000;   -- Midnight
```

---

## Operators and Notifications

**Operators** are aliases for people or groups that can receive notifications about job outcomes. They are not SQL Server logins; they are contact definitions.

### Creating an Operator

```sql
EXEC msdb.dbo.sp_add_operator
    @name = N'DBA_Team',
    @enabled = 1,
    @email_address = N'dba-team@company.com',
    @pager_email_address = N'dba-oncall@company.com',
    @weekday_pager_start_time = 080000,
    @weekday_pager_end_time = 180000;
```

### Adding Notifications to a Job

```sql
EXEC msdb.dbo.sp_update_job
    @job_name = N'Daily_ETL_Load',
    @notify_level_email = 2,           -- On failure
    @notify_email_operator_name = N'DBA_Team';

-- Notification level values:
-- 0 = Never
-- 1 = On success
-- 2 = On failure
-- 3 = On completion (always)
```

### Prerequisites

- **Database Mail** must be configured and a default mail profile must be set for SQL Server Agent.
- Configure the Agent mail profile: Right-click SQL Server Agent > Properties > Alert System > Enable Mail Profile.

---

## Alerts

Alerts are automatic responses to events in the SQL Server environment. SQL Server Agent monitors the Windows Application Event Log for entries matching alert conditions.

### Alert Types

| Type | Trigger |
|------|---------|
| **SQL Server Event Alerts** | Based on error number or severity level in the error log |
| **SQL Server Performance Condition Alerts** | Based on performance counter thresholds |
| **WMI Event Alerts** | Based on WMI (Windows Management Instrumentation) events |

### Severity-Based Alert (Critical Errors)

```sql
-- Create alerts for severity 17-25 (critical errors)
DECLARE @severity INT = 17;
WHILE @severity <= 25
BEGIN
    DECLARE @alert_name NVARCHAR(100) = N'Severity ' + CAST(@severity AS NVARCHAR(3)) + N' Error Alert';

    EXEC msdb.dbo.sp_add_alert
        @name = @alert_name,
        @message_id = 0,
        @severity = @severity,
        @enabled = 1,
        @delay_between_responses = 300,  -- 5-minute delay to avoid flooding
        @include_event_description_in = 1,
        @notification_message = N'A critical error has occurred. Investigate immediately.';

    EXEC msdb.dbo.sp_add_notification
        @alert_name = @alert_name,
        @operator_name = N'DBA_Team',
        @notification_method = 1;  -- 1=Email, 2=Pager, 4=Net Send

    SET @severity += 1;
END
```

### Performance Condition Alert

```sql
-- Alert when data file reaches 90% full
EXEC msdb.dbo.sp_add_alert
    @name = N'Data File Nearly Full',
    @enabled = 1,
    @performance_condition = N'SQLServer:Databases|Percent Log Used|SalesDB|>|90',
    @delay_between_responses = 600;

EXEC msdb.dbo.sp_add_notification
    @alert_name = N'Data File Nearly Full',
    @operator_name = N'DBA_Team',
    @notification_method = 1;
```

### WMI Event Alert

```sql
-- Alert when a database is created
EXEC msdb.dbo.sp_add_alert
    @name = N'Database Created Alert',
    @enabled = 1,
    @wmi_namespace = N'\\.\root\Microsoft\SqlServer\ServerEvents\MSSQLSERVER',
    @wmi_query = N'SELECT * FROM CREATE_DATABASE';

EXEC msdb.dbo.sp_add_notification
    @alert_name = N'Database Created Alert',
    @operator_name = N'DBA_Team',
    @notification_method = 1;
```

### Alerts That Execute Jobs

An alert can respond to a condition by running a job, sending a notification, or both:

```sql
EXEC msdb.dbo.sp_update_alert
    @name = N'Data File Nearly Full',
    @job_name = N'Emergency_Log_Backup';
```

---

## Proxy Accounts

By default, job steps run under the security context of the SQL Server Agent service account (which is `sysadmin`). **Proxy accounts** allow non-sysadmin users to run job steps under a different Windows credential, following the principle of least privilege.

### How Proxies Work

1. A **Credential** is created that maps to a Windows identity (domain account).
2. A **Proxy** is created that references that credential.
3. The proxy is associated with one or more **subsystems** (e.g., CmdExec, PowerShell, SSIS).
4. Users granted access to the proxy can use it in their job steps.

### Creating a Proxy

```sql
-- Step 1: Create a credential
CREATE CREDENTIAL ETL_Credential
WITH IDENTITY = N'DOMAIN\ETL_ServiceAccount',
SECRET = N'P@ssw0rd!';
GO

-- Step 2: Create a proxy using the credential
EXEC msdb.dbo.sp_add_proxy
    @proxy_name = N'ETL_Proxy',
    @credential_name = N'ETL_Credential',
    @description = N'Proxy for running ETL-related job steps under the ETL service account.';

-- Step 3: Grant the proxy access to subsystems
EXEC msdb.dbo.sp_grant_proxy_to_subsystem
    @proxy_name = N'ETL_Proxy',
    @subsystem_id = 3;   -- CmdExec

EXEC msdb.dbo.sp_grant_proxy_to_subsystem
    @proxy_name = N'ETL_Proxy',
    @subsystem_id = 11;  -- SSIS

EXEC msdb.dbo.sp_grant_proxy_to_subsystem
    @proxy_name = N'ETL_Proxy',
    @subsystem_id = 12;  -- PowerShell

-- Step 4: Grant a login access to use the proxy
EXEC msdb.dbo.sp_grant_login_to_proxy
    @proxy_name = N'ETL_Proxy',
    @login_name = N'DOMAIN\DataEngineer';
```

### Using a Proxy in a Job Step

```sql
EXEC sp_add_jobstep
    @job_name = N'Daily_ETL_Load',
    @step_name = N'Run External Script',
    @subsystem = N'CmdExec',
    @command = N'D:\Scripts\extract_data.exe',
    @proxy_name = N'ETL_Proxy';
```

### Subsystem IDs Reference

| ID | Subsystem |
|----|-----------|
| 1 | ActiveScripting (deprecated) |
| 2 | CmdExec |
| 3 | Snapshot Replication |
| 4 | Log Reader |
| 5 | Distribution |
| 6 | Merge |
| 7 | Queue Reader |
| 8 | Analysis Services Command |
| 9 | Analysis Services Query |
| 10 | SSIS |
| 11 | PowerShell |

> **Note**: T-SQL steps always run in the context of the job owner's SQL Server login and do not use proxies.

---

## Job Categories

Job categories are used to organize jobs into logical groups. They are purely for organizational purposes and do not affect functionality.

### Built-In Categories

SQL Server comes with several built-in categories such as `[Uncategorized (Local)]`, `Database Maintenance`, `Data Collector`, `Full-Text`, and `REPL-*` (replication categories).

### Creating Custom Categories

```sql
EXEC msdb.dbo.sp_add_category
    @class = N'JOB',
    @type = N'LOCAL',
    @name = N'ETL - Data Warehouse';

EXEC msdb.dbo.sp_add_category
    @class = N'JOB',
    @type = N'LOCAL',
    @name = N'ETL - Data Lake';

-- Assign a job to a category
EXEC msdb.dbo.sp_update_job
    @job_name = N'Daily_ETL_Load',
    @category_name = N'ETL - Data Warehouse';
```

---

## Multi-Server Jobs

Multi-server jobs allow you to administer jobs across multiple SQL Server instances from a single **Master Server (MSX)**. Target servers (**TSX**) poll the master for job definitions.

### Architecture

- **MSX (Master Server)**: Central server that defines and distributes jobs.
- **TSX (Target Server)**: Servers that receive and execute jobs from the MSX.
- Target servers periodically **poll** the MSX for new or updated instructions.

### Setup

```sql
-- On the master server: enlist a target
EXEC msdb.dbo.sp_msx_enlist
    @server_name = N'TARGET_SERVER_01',
    @location = N'East Data Center';

-- Create a multi-server job
EXEC msdb.dbo.sp_add_job
    @job_name = N'Multi_Server_Maintenance',
    @description = N'Runs on all target servers';

-- Target the job to specific servers
EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'Multi_Server_Maintenance',
    @server_name = N'TARGET_SERVER_01';

EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'Multi_Server_Maintenance',
    @server_name = N'TARGET_SERVER_02';
```

### Polling Interval

The default polling interval is **60 seconds**. Target servers download job instructions and upload execution results during each poll.

---

## Monitoring Job Execution

### Starting a Job Manually

```sql
-- Start a job by name
EXEC msdb.dbo.sp_start_job @job_name = N'Daily_ETL_Load';

-- Start a job at a specific step
EXEC msdb.dbo.sp_start_job
    @job_name = N'Daily_ETL_Load',
    @step_name = N'Run SSIS ETL Package';
```

### Stopping a Running Job

```sql
EXEC msdb.dbo.sp_stop_job @job_name = N'Daily_ETL_Load';
```

### Checking Current Job Activity

```sql
-- View currently running jobs
SELECT
    j.name AS job_name,
    ja.start_execution_date,
    DATEDIFF(MINUTE, ja.start_execution_date, GETDATE()) AS running_minutes,
    ja.last_executed_step_id,
    js.step_name AS current_step
FROM msdb.dbo.sysjobactivity ja
INNER JOIN msdb.dbo.sysjobs j ON ja.job_id = j.job_id
LEFT JOIN msdb.dbo.sysjobsteps js
    ON ja.job_id = js.job_id
    AND ja.last_executed_step_id + 1 = js.step_id
WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
    AND ja.start_execution_date IS NOT NULL
    AND ja.stop_execution_date IS NULL;
```

### Viewing Job History

```sql
-- Recent job history (last 24 hours, failures only)
SELECT
    j.name AS job_name,
    h.step_id,
    h.step_name,
    h.run_date,
    h.run_time,
    h.run_duration,
    CASE h.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Canceled'
        WHEN 4 THEN 'In Progress'
    END AS run_status,
    h.message
FROM msdb.dbo.sysjobhistory h
INNER JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
WHERE h.run_status = 0  -- Failed
    AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(HOUR, -24, GETDATE())
ORDER BY h.run_date DESC, h.run_time DESC;
```

### Helper Function: agent_datetime

The `run_date` and `run_time` columns in `sysjobhistory` are stored as integers (e.g., `20260307` and `143000`). Use the undocumented `msdb.dbo.agent_datetime()` function to convert them:

```sql
SELECT msdb.dbo.agent_datetime(20260307, 143000);
-- Returns: 2026-03-07 14:30:00.000
```

---

## Key msdb System Tables

| Table | Description |
|-------|-------------|
| `sysjobs` | One row per job; contains job-level properties |
| `sysjobsteps` | One row per step per job; contains step definitions |
| `sysjobschedules` | Junction table linking jobs to schedules |
| `sysschedules` | Schedule definitions (can be shared across jobs) |
| `sysjobhistory` | Execution history for each step and overall outcome |
| `sysjobactivity` | Current activity including running status |
| `syssessions` | Agent service start sessions |
| `sysjobservers` | Target servers for each job |
| `sysoperators` | Operator definitions |
| `sysalerts` | Alert definitions |
| `sysproxies` | Proxy account definitions |
| `syscategories` | Job category definitions |

### Comprehensive Job Inventory Query

```sql
SELECT
    j.name AS job_name,
    j.enabled,
    c.name AS category,
    j.description,
    SUSER_SNAME(j.owner_sid) AS owner,
    j.date_created,
    j.date_modified,
    COUNT(DISTINCT js.step_id) AS step_count,
    COUNT(DISTINCT sch.schedule_id) AS schedule_count,
    MAX(CASE WHEN h.step_id = 0 THEN msdb.dbo.agent_datetime(h.run_date, h.run_time) END) AS last_run_datetime,
    MAX(CASE WHEN h.step_id = 0 THEN
        CASE h.run_status WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded'
             WHEN 2 THEN 'Retry' WHEN 3 THEN 'Canceled' END
    END) AS last_run_status
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON j.category_id = c.category_id
LEFT JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
LEFT JOIN msdb.dbo.sysjobschedules sch ON j.job_id = sch.job_id
LEFT JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id AND h.step_id = 0
GROUP BY j.name, j.enabled, c.name, j.description, j.owner_sid, j.date_created, j.date_modified
ORDER BY j.name;
```

---

## Common Interview Questions

### Q1: What is SQL Server Agent and why is it important for a Data Engineer?

**A:** SQL Server Agent is a job scheduling and automation service built into SQL Server. For Data Engineers, it is essential because it orchestrates ETL pipelines, schedules data loads, automates maintenance tasks, and provides alerting when data processes fail. It is the primary mechanism for automating recurring T-SQL scripts, SSIS package executions, and operational tasks without human intervention.

---

### Q2: A job has 5 steps. Step 3 fails. What happens by default?

**A:** By default, each step's "On Failure" action is set to **"Quit the job reporting failure."** So if Step 3 fails, Steps 4 and 5 do not execute, and the overall job outcome is recorded as failed. However, you can customize this behavior: set the on-failure action to skip to another step, retry the step a specified number of times, or continue to the next step regardless of failure.

---

### Q3: How do proxy accounts improve security?

**A:** Without proxies, non-T-SQL job steps (CmdExec, PowerShell, SSIS) run under the SQL Server Agent service account, which is typically `sysadmin`. Proxies allow you to define a least-privilege Windows credential for specific subsystems. For example, an ETL job step that reads files from a network share can use a proxy that only has access to that share, rather than running with full sysadmin rights. This limits the blast radius if a job step is compromised or misconfigured.

---

### Q4: What is the difference between a schedule and a job? Can they be shared?

**A:** A **job** defines *what* to do (steps, actions). A **schedule** defines *when* to do it. They have a many-to-many relationship: one job can have multiple schedules (e.g., run daily at 2 AM and also every hour on Mondays), and one schedule can be attached to multiple jobs (e.g., a "Daily 2AM" schedule used by several maintenance jobs). This decoupling reduces duplication.

---

### Q5: How would you troubleshoot a failing SQL Server Agent job?

**A:** Follow this systematic approach:

1. **Check job history** (`sysjobhistory`) -- the `message` column often contains the exact error.
2. **Check the specific step** that failed -- note which step_id failed and examine its command.
3. **Run the step manually** -- execute the T-SQL, PowerShell, or SSIS package outside the Agent to isolate whether the issue is the command or the Agent configuration.
4. **Check permissions** -- verify the job owner and proxy account have necessary permissions.
5. **Check SQL Server Agent Error Log** -- found in Management > SQL Server Agent Error Logs in SSMS.
6. **Check Windows Event Log** -- Application log may have additional Agent errors.
7. **Check for blocking/deadlocks** -- if the step involves T-SQL, it may be a contention issue.

---

### Q6: How do you prevent a job from running if a previous instance is still executing?

**A:** SQL Server Agent will not start a new instance of a job if the same job is already running. This is the default behavior -- there is no built-in parallel execution of the same job. If you need additional control, you can implement a custom locking mechanism using an application lock (`sp_getapplock`) or a control table that the job checks at the beginning of its first step.

---

### Q7: What happens to running jobs if the SQL Server Agent service is restarted?

**A:** Running jobs are terminated when the Agent service stops. When the service restarts, jobs scheduled with `@freq_type = 64` (AutoStart) will run automatically. Other jobs will not re-run missed executions unless you have configured logic to detect and handle missed runs. The Agent does record the service restart in `syssessions`.

---

### Q8: How do you manage job history retention?

**A:** Job history can accumulate rapidly. Configure retention in SQL Server Agent Properties > History:

- **Maximum job history log size (rows)**: Total rows across all jobs (default: 1000).
- **Maximum job history rows per job**: Per-job limit (default: 100).

For production systems, increase these significantly or implement a custom purge process:

```sql
-- Purge job history older than 30 days
EXEC msdb.dbo.sp_purge_jobhistory
    @oldest_date = '2026-02-05';
```

---

## Tips

- **Always test jobs manually** using `sp_start_job` before relying on the schedule. Verify all steps complete successfully under the expected security context.

- **Set up a "fail-safe operator"** in SQL Server Agent Properties > Alert System. This operator receives notifications when the designated operator cannot be reached.

- **Use meaningful job and step names.** When you have 200+ jobs on a production server, names like "Job1" or "New Job" become a maintenance nightmare.

- **Log job step output to files** by configuring the output file path on each job step. This provides detailed error information beyond what the job history message stores.

- **Be cautious with `sp_start_job` in application code.** It is asynchronous -- it returns immediately after queuing the job, not after the job completes. If your application needs to know when the job finishes, you must poll `sysjobactivity`.

- **Monitor for disabled jobs.** It is common for someone to disable a job temporarily for troubleshooting and forget to re-enable it:

```sql
SELECT name, date_modified
FROM msdb.dbo.sysjobs
WHERE enabled = 0
ORDER BY date_modified DESC;
```

- **Document job dependencies.** If Job B depends on Job A completing first, make this explicit -- either by chaining them (Job A's last step starts Job B) or by implementing a job dependency framework with a control table.

- **Avoid running too many jobs at the same time.** SQL Server Agent has a limited number of worker threads. If many jobs overlap, some may be queued waiting for a thread. Stagger schedules to distribute load.

---
