# Migration to Azure SQL / Cloud Strategies

[Back to SQL Server Index](./README.md)

---

## Overview

Migrating SQL Server workloads to Azure is one of the most critical initiatives organizations undertake today. As a senior Data Engineer, you must understand the target deployment options, assessment tooling, migration methods, pricing models, and post-migration optimization strategies. This guide covers everything you need for interview preparation on cloud migration topics.

---

## 1. Azure SQL Deployment Options

### Azure SQL Database (PaaS - Single Database / Elastic Pool)

Azure SQL Database is a fully managed Platform-as-a-Service (PaaS) offering built on the latest stable SQL Server engine. It abstracts away OS and infrastructure management entirely.

**Key Characteristics:**
- Fully managed: automated patching, backups, high availability
- Built-in intelligence (auto-tuning, threat detection)
- Supports single databases and elastic pools
- No SQL Server Agent (use Azure Automation, Logic Apps, or Elastic Jobs)
- No cross-database queries (unless using Elastic Query)
- No CLR assemblies, Service Broker (limited), or linked servers
- Maximum database size up to 100 TB (Hyperscale tier)

**Best For:**
- New cloud-native applications
- SaaS applications with per-tenant database isolation
- Workloads that can tolerate feature restrictions for full PaaS benefits

### Azure SQL Managed Instance (PaaS - Near 100% Compatibility)

Managed Instance provides near-complete compatibility with the on-premises SQL Server engine while still being a managed service.

**Key Characteristics:**
- Supports cross-database queries within the same instance
- SQL Server Agent is available
- CLR, Service Broker, Database Mail, linked servers supported
- Native backup/restore for migration (from Azure Blob Storage)
- Instance-scoped features (server-level collation, logins, tempdb configuration)
- VNet-native deployment for network isolation
- Up to 100 databases per instance, 16 TB max per database (General Purpose), 4 TB (Business Critical)

**Best For:**
- Lift-and-shift migrations with minimal code changes
- Applications relying on instance-scoped features (Agent jobs, cross-DB queries, CLR)
- Organizations needing SQL Server parity in a managed environment

### SQL Server on Azure Virtual Machines (IaaS)

Full SQL Server installed on an Azure VM, giving you complete control over the OS and SQL Server instance.

**Key Characteristics:**
- 100% feature parity with on-premises SQL Server
- Full OS-level access
- You manage patching, backups, HA/DR (though Azure provides tooling)
- Supports all SQL Server editions and versions
- Can leverage Azure Hybrid Benefit for licensing savings
- Supports failover cluster instances (FCI) and traditional Always On AGs

**Best For:**
- Applications requiring OS-level access or unsupported features in PaaS
- Legacy SQL Server versions that cannot be upgraded
- Third-party applications certified only on specific SQL Server configurations
- Workloads requiring SSIS, SSRS, SSAS on the same server

### Comparison Matrix

| Feature | SQL Database | Managed Instance | SQL Server on VM |
|---|---|---|---|
| Management Level | Fully managed | Fully managed | Self-managed |
| Compatibility | ~95% | ~99% | 100% |
| SQL Agent | No | Yes | Yes |
| Cross-DB Queries | No (Elastic Query) | Yes | Yes |
| CLR | No | Yes | Yes |
| Linked Servers | No | Yes | Yes |
| Max DB Size | 100 TB (Hyperscale) | 16 TB | Disk-limited |
| SSIS/SSRS/SSAS | No (use ADF, Power BI) | No (SSIS via ADF) | Yes |
| Cost Model | DTU or vCore | vCore | Pay-as-you-go or Reserved |

---

## 2. Migration Assessment Tools

### Data Migration Assistant (DMA)

DMA is a standalone tool that assesses SQL Server instances for migration readiness.

**Capabilities:**
- Detects compatibility issues and breaking changes
- Identifies unsupported features, partially supported features, and behavior changes
- Provides feature parity analysis for target Azure SQL platforms
- Recommends Azure SQL Database or Managed Instance SKU sizing
- Generates assessment reports in JSON or CSV

**Typical Workflow:**
1. Install DMA on a machine with connectivity to the source SQL Server
2. Create a new Assessment project
3. Select target type (Azure SQL Database, Managed Instance, or SQL Server on VM)
4. Run assessment and review blocking issues vs. warnings
5. Address blockers before migration

### Azure Migrate

Azure Migrate is a centralized hub for discovering, assessing, and migrating on-premises workloads to Azure.

**For SQL Server Migrations:**
- Discovers SQL Server instances across your environment
- Provides Azure SQL readiness assessments at scale
- Recommends target deployment options and SKU sizing
- Estimates monthly Azure costs
- Integrates with Azure Database Migration Service (DMS)

### Azure Database Migration Service (DMS)

DMS is a fully managed service designed to perform migrations with minimal downtime.

**Key Features:**
- Online (continuous sync) and offline migration modes
- Supports SQL Server to Azure SQL Database, Managed Instance, and SQL Server on VM
- Handles schema migration, data migration, and cutover
- Online mode uses change data capture for near-zero downtime

### Other Useful Tools

- **Azure SQL Migration Extension for Azure Data Studio** - Modern assessment and migration experience
- **Database Experimentation Assistant (DEA)** - Compares query performance between source and target
- **MAP Toolkit** - Agentless inventory and assessment for large estates
- **SKU Recommender** - Analyzes performance counters to recommend optimal Azure SQL SKU

---

## 3. Compatibility Levels

Compatibility levels control how the database engine processes T-SQL and query optimization.

```sql
-- Check current compatibility level
SELECT name, compatibility_level
FROM sys.databases;

-- Change compatibility level
ALTER DATABASE [MyDatabase] SET COMPATIBILITY_LEVEL = 160; -- SQL Server 2022

-- Common levels:
-- 100 = SQL Server 2008
-- 110 = SQL Server 2012
-- 120 = SQL Server 2014
-- 130 = SQL Server 2016
-- 140 = SQL Server 2017
-- 150 = SQL Server 2019
-- 160 = SQL Server 2022
```

**Migration Strategy for Compatibility Levels:**
1. Migrate first at the **current** compatibility level to reduce risk
2. Validate application functionality
3. Upgrade compatibility level incrementally
4. Test query performance at each level using Query Store
5. Use Query Store hints or plan guides to fix regressions

```sql
-- Enable Query Store before changing compatibility level
ALTER DATABASE [MyDatabase] SET QUERY_STORE = ON;

-- Capture baseline at old compat level
-- Then change level and compare plans
ALTER DATABASE [MyDatabase] SET COMPATIBILITY_LEVEL = 150;

-- Force a previous plan if regression found
EXEC sp_query_store_force_plan @query_id = 42, @plan_id = 17;
```

---

## 4. Feature Parity Gaps

Understanding what is **not** available in PaaS targets is critical for migration planning.

### Features NOT Available in Azure SQL Database
- SQL Server Agent (use Elastic Jobs, Azure Automation, Azure Functions)
- Cross-database queries (use Elastic Query or redesign)
- CLR assemblies
- Service Broker (limited)
- Linked Servers
- Filestream / FileTable
- Database mirroring (built-in HA replaces this)
- Distributed transactions (limited support added recently)
- BULK INSERT from local file paths (use Azure Blob Storage)
- Extended stored procedures
- Server-level triggers, audits (use database-level)

### Features NOT Available in Azure SQL Managed Instance
- Failover Cluster Instances (built-in HA handles this)
- SSRS / SSAS / SSIS natively (use Power BI, Azure Analysis Services, ADF)
- SQL Server on Linux features
- Stretch Database
- PolyBase (available in SQL Server on VM)

### Common Code Changes Required

```sql
-- REPLACE: USE [OtherDatabase] with three-part names (Managed Instance)
-- or Elastic Query (SQL Database)

-- ON-PREMISES:
USE [ReportingDB];
SELECT * FROM dbo.SalesReport;

-- MANAGED INSTANCE (cross-database within same instance):
SELECT * FROM [ReportingDB].[dbo].[SalesReport];

-- SQL DATABASE (requires Elastic Query or redesign):
-- Option 1: Consolidate into a single database
-- Option 2: Use external tables via Elastic Query

-- REPLACE: SQL Agent Jobs
-- Azure SQL Database alternative using Elastic Jobs:
-- Create job agent, credentials, target group, then define job steps

-- REPLACE: BULK INSERT from local path
-- On-premises:
BULK INSERT dbo.Staging FROM 'C:\Data\import.csv';

-- Azure SQL Database:
BULK INSERT dbo.Staging
FROM 'import.csv'
WITH (
    DATA_SOURCE = 'MyAzureBlobStorage',
    FORMAT = 'CSV',
    FIRSTROW = 2
);
```

---

## 5. Migration Methods

### Method 1: Backup and Restore (Managed Instance)

The simplest lift-and-shift approach for Managed Instance.

```sql
-- Step 1: Take a backup and upload to Azure Blob Storage
BACKUP DATABASE [MyDatabase]
TO URL = 'https://mystorageaccount.blob.core.windows.net/backups/MyDatabase.bak'
WITH CREDENTIAL = 'MyAzureCredential', COMPRESSION;

-- Step 2: Restore on Managed Instance
RESTORE DATABASE [MyDatabase]
FROM URL = 'https://mystorageaccount.blob.core.windows.net/backups/MyDatabase.bak';
```

**Considerations:**
- Native backup/restore only works with Managed Instance (not Azure SQL Database)
- Copy-only backups recommended for production
- Striped backups supported for large databases (up to 64 stripes)
- Backup must be in `.bak` format, maximum 195 GB per stripe (use multiple files for large DBs)

### Method 2: Azure Database Migration Service (DMS)

**Offline Migration:**
1. Create DMS instance in Azure
2. Create a migration project (source: SQL Server, target: Azure SQL)
3. Map source databases to target
4. Run schema migration, then data migration
5. Cutover (application downtime required)

**Online Migration (Minimal Downtime):**
1. Same setup as offline
2. DMS performs initial full load
3. Continuous sync captures changes via CDC/log reading
4. When ready, stop writes to source, wait for sync to complete
5. Cutover to target (seconds to minutes of downtime)

### Method 3: Transactional Replication

Use SQL Server transactional replication with Azure SQL as the subscriber.

```sql
-- On-premises Publisher setup (simplified)
-- 1. Configure distribution
-- 2. Create publication
-- 3. Add articles (tables)
-- 4. Create subscription pointing to Azure SQL Database

-- Azure SQL Database acts as a push subscription endpoint
-- Once in sync, cutover application connection strings
-- Then remove replication
```

**Advantages:**
- Minimal downtime during migration
- Familiar technology for experienced DBAs
- Can migrate table-by-table for phased approach

**Limitations:**
- Tables must have primary keys
- Some data types not supported (hierarchyid, spatial, etc. may need workarounds)
- Additional complexity in setup and monitoring

### Method 4: BACPAC Export/Import

```sql
-- Export BACPAC using SqlPackage.exe
SqlPackage.exe /Action:Export /SourceServerName:myserver
    /SourceDatabaseName:MyDB /TargetFile:MyDB.bacpac

-- Import BACPAC to Azure SQL Database
SqlPackage.exe /Action:Import /TargetServerName:myserver.database.windows.net
    /TargetDatabaseName:MyDB /SourceFile:MyDB.bacpac
    /TargetUser:admin /TargetPassword:***
```

**Best For:** Small to medium databases (< 200 GB), dev/test environments.

### Method 5: Data-tier Application (dacpac) with Schema + Data

For schema-only migrations or controlled deployments using dacpac with publish profiles.

### Migration Method Selection Guide

| Scenario | Recommended Method |
|---|---|
| Large DB, minimal downtime, to MI | Backup/Restore + Log Shipping or DMS Online |
| Large DB, minimal downtime, to SQL DB | DMS Online or Transactional Replication |
| Small DB, downtime acceptable | BACPAC or DMS Offline |
| Phased table-by-table migration | Transactional Replication |
| Multiple databases at scale | DMS with Azure Migrate orchestration |

---

## 6. DTU vs vCore Pricing Models

### DTU (Database Transaction Unit) Model

DTUs represent a blended measure of CPU, memory, and I/O.

**Tiers:**
- **Basic:** Up to 5 DTUs, 2 GB max size. For light, intermittent workloads.
- **Standard:** 10-3000 DTUs, up to 1 TB. For most production OLTP workloads.
- **Premium:** 125-4000 DTUs, up to 4 TB. For high-performance, I/O-intensive workloads.

**Pros:**
- Simple, predictable pricing
- Easy to understand for small workloads
- Good for applications with consistent resource usage

**Cons:**
- Cannot independently scale CPU, memory, or I/O
- Harder to map to on-premises SQL Server specs
- Limited transparency into actual resource allocation

### vCore (Virtual Core) Model

vCore lets you independently choose compute, storage, and memory.

**Service Tiers:**
- **General Purpose:** Budget-friendly, remote storage, 5-9ms latency. Equivalent to Standard Edition.
- **Business Critical:** Local SSD storage, sub-millisecond latency, built-in read replicas. Equivalent to Enterprise Edition.
- **Hyperscale:** Rapidly scalable storage up to 100 TB, near-instant backups, fast scaling.

**Pros:**
- Transparent resource allocation (vCores, memory, IOPS)
- Easy to compare with on-premises SQL Server sizing
- Azure Hybrid Benefit eligible (save up to 55% with existing licenses)
- Independent storage scaling
- Reserved capacity discounts (1-year or 3-year)

**Cons:**
- More complex pricing decisions
- Requires understanding of workload resource profiles

```
-- Rough DTU to vCore mapping:
-- 100 DTU (Standard S3)  ~  2 vCores General Purpose
-- 200 DTU (Standard S4)  ~  4 vCores General Purpose
-- 400 DTU (Standard S6)  ~  6 vCores General Purpose
-- 800 DTU (Standard S9)  ~  8 vCores General Purpose
-- 125 DTU (Premium P1)   ~  2 vCores Business Critical
-- 500 DTU (Premium P4)   ~  8 vCores Business Critical
```

---

## 7. Elastic Pools

Elastic pools allow multiple databases to share a pool of resources, ideal for multi-tenant SaaS scenarios.

**Key Concepts:**
- Databases in the pool share eDTUs or vCores
- Each database can burst up to the pool maximum
- Per-database min/max settings control resource guarantees and caps
- Cost-effective when databases have varying, unpredictable usage patterns

```sql
-- Monitor elastic pool resource utilization
SELECT
    elastic_pool_name,
    avg_cpu_percent,
    avg_data_io_percent,
    avg_log_write_percent,
    avg_storage_percent,
    max_worker_percent,
    max_session_percent
FROM sys.elastic_pool_resource_stats
ORDER BY end_time DESC;
```

**When to Use Elastic Pools:**
- Multiple databases with low average but high peak utilization
- SaaS multi-tenant patterns where tenants each have their own database
- Total peak utilization across databases is well below the sum of individual peaks

**When NOT to Use:**
- Single database with consistent high utilization
- Databases that all peak simultaneously
- Databases with vastly different SLA requirements

---

## 8. Serverless Tier

Azure SQL Database Serverless automatically scales compute based on workload demand and pauses when inactive.

**Key Features:**
- Auto-scales between min and max configured vCores
- Auto-pauses after configurable idle period (minimum 1 hour)
- Billed per second of compute used
- Storage is always billed regardless of pause state
- Resume from pause takes a few seconds (cold start)

```sql
-- Create a serverless database
-- (via Azure CLI or Portal; T-SQL doesn't control the tier)
-- az sql db create --resource-group myRG --server myServer
--   --name myDB --edition GeneralPurpose
--   --compute-model Serverless --family Gen5
--   --min-capacity 0.5 --capacity 4
--   --auto-pause-delay 60
```

**Best For:**
- Development and test environments
- Intermittent, unpredictable workloads
- Applications with idle periods (nights, weekends)
- Cost optimization for low-utilization databases

**Not Ideal For:**
- Latency-sensitive applications (cold start delay)
- Consistently active workloads (always-on is cheaper)
- Elastic pools (serverless is per-database only)

---

## 9. Hybrid Scenarios

### Azure Arc-enabled SQL Server

- Extends Azure management to on-premises SQL Server instances
- Provides Azure Portal visibility, Azure Defender, and Azure policies
- Enables pay-as-you-go licensing for on-premises SQL Server

### Distributed Availability Groups

```sql
-- Connect on-premises AG to Azure SQL Managed Instance
-- Create a distributed AG spanning both environments
CREATE AVAILABILITY GROUP [DistributedAG]
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
    'OnPremAG' WITH (
        LISTENER_URL = 'tcp://OnPremListener:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    ),
    'AzureAG' WITH (
        LISTENER_URL = 'tcp://AzureMIListener:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    );
```

### Azure SQL Managed Instance Link

- Real-time data replication from SQL Server 2016+ to Managed Instance
- Use for disaster recovery, read-scale offloading, or phased migration
- Supports one-way replication with the ability to fail over and break the link

### ExpressRoute / VPN Connectivity

- ExpressRoute for dedicated private connectivity (higher bandwidth, lower latency)
- Site-to-Site VPN for encrypted connectivity over internet
- Required for Managed Instance VNet integration with on-premises networks

---

## 10. Azure SQL Hyperscale

Hyperscale is a storage tier in Azure SQL Database designed for large databases.

**Architecture:**
- Separates compute, log, and storage into independent layers
- Page servers cache data locally for fast reads
- Log service provides durable, fast log writes
- Multiple compute replicas can be added for read scale-out

**Key Benefits:**
- Database size up to 100 TB
- Near-instant backups regardless of database size (snapshot-based)
- Fast database restores (minutes, not hours)
- Rapid scale-up/down of compute (under 2 minutes)
- Up to 4 named read replicas and 1 HA replica
- Fast scaling of storage (no data copy required)

**Considerations:**
- Cannot revert to General Purpose or Business Critical (one-way migration to Hyperscale; reversibility is now supported for databases up to 40 TB in certain regions)
- Geo-replication now supported
- Point-in-time restore within configured retention

```sql
-- Check if database is Hyperscale
SELECT name, edition, service_objective
FROM sys.database_service_objectives;

-- Hyperscale-specific DMVs
SELECT * FROM sys.dm_db_page_info(DB_ID(), 1, 0, 'DETAILED');
```

---

## 11. Post-Migration Optimization

### Immediate Post-Migration Steps

```sql
-- 1. Update statistics on all tables
EXEC sp_updatestats;

-- 2. Rebuild indexes (if not done during migration)
-- Use Ola Hallengren's scripts or:
ALTER INDEX ALL ON [dbo].[LargeTable] REBUILD;

-- 3. Verify compatibility level
ALTER DATABASE [MyDatabase] SET COMPATIBILITY_LEVEL = 150;

-- 4. Enable Query Store
ALTER DATABASE [MyDatabase] SET QUERY_STORE = ON
(
    OPERATION_MODE = READ_WRITE,
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    INTERVAL_LENGTH_MINUTES = 30,
    MAX_STORAGE_SIZE_MB = 1024,
    QUERY_CAPTURE_MODE = AUTO,
    SIZE_BASED_CLEANUP_MODE = AUTO
);

-- 5. Enable automatic tuning
ALTER DATABASE [MyDatabase]
SET AUTOMATIC_TUNING (
    FORCE_LAST_GOOD_PLAN = ON,
    CREATE_INDEX = ON,
    DROP_INDEX = OFF
);
```

### Performance Monitoring

```sql
-- Monitor DTU/vCore consumption
SELECT
    end_time,
    avg_cpu_percent,
    avg_data_io_percent,
    avg_log_write_percent,
    avg_memory_usage_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;

-- Identify top resource-consuming queries
SELECT TOP 20
    qs.query_id,
    qt.query_sql_text,
    rs.avg_cpu_time,
    rs.avg_logical_io_reads,
    rs.count_executions,
    rs.avg_duration
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_plan qp ON rs.plan_id = qp.plan_id
JOIN sys.query_store_query qs ON qp.query_id = qs.query_id
JOIN sys.query_store_query_text qt ON qs.query_text_id = qt.query_text_id
ORDER BY rs.avg_cpu_time * rs.count_executions DESC;
```

### Connection String and Application Changes

```
-- Update connection strings
-- On-premises:
Server=MyOnPremServer;Database=MyDB;Trusted_Connection=True;

-- Azure SQL Database:
Server=myserver.database.windows.net;Database=MyDB;
User ID=myadmin;Password=***;Encrypt=True;
TrustServerCertificate=False;Connection Timeout=30;

-- Add retry logic for transient faults (mandatory in cloud)
-- Use SqlConnection with ConnectRetryCount and ConnectRetryInterval
-- Or use Polly / Enterprise Library for application-level retry
```

### Cost Optimization

- **Reserved Capacity:** Commit to 1 or 3 years for up to 65% savings
- **Azure Hybrid Benefit:** Use existing SQL Server licenses for up to 55% savings
- **Right-sizing:** Monitor resource usage and scale down over-provisioned databases
- **Auto-pause:** Use serverless for dev/test environments
- **Elastic Pools:** Consolidate low-usage databases

---

## Common Interview Questions and Answers

### Q1: How would you decide between Azure SQL Database, Managed Instance, and SQL Server on VM?

**Answer:** The decision depends on several factors:
- **Azure SQL Database** when building cloud-native applications or when the application uses single-database features only, with no dependency on SQL Agent, CLR, cross-database queries, or linked servers. It offers the lowest management overhead and strongest PaaS benefits.
- **Managed Instance** for lift-and-shift migrations requiring near-100% compatibility. Choose this when the application depends on instance-scoped features like SQL Agent, cross-database queries, Service Broker, or CLR. It provides managed HA, backups, and patching while preserving SQL Server surface area.
- **SQL Server on Azure VM** when 100% feature parity is required, such as for legacy applications on older SQL Server versions, workloads needing SSIS/SSRS/SSAS co-located, or third-party applications certified only on specific configurations. You accept full management responsibility.

Always start assessment with DMA/Azure Migrate to identify blockers for each target platform.

### Q2: Describe a migration strategy for a 5 TB OLTP database with a 30-minute downtime window.

**Answer:** For such a tight downtime window with a large database, I would use DMS Online Migration or the Managed Instance Link:

1. **Assessment Phase:** Run DMA to identify compatibility issues. Fix blockers.
2. **Pre-Migration:** Set up DMS in online mode. Perform initial full data load (which takes hours but happens while the application is live).
3. **Continuous Sync:** DMS captures ongoing changes via log reading and applies them to the target.
4. **Cutover Window:** When the sync lag is minimal (seconds), stop application writes, let DMS complete the final sync, verify data consistency, update connection strings, and bring the application up on Azure.

Alternatively, for Managed Instance, use the MI Link feature for continuous replication, then break the link during the cutover window.

### Q3: How do you handle performance regression after migrating to Azure SQL?

**Answer:** I follow a structured approach:
1. **Baseline First:** Ensure Query Store was enabled before migration to capture on-premises query performance baselines.
2. **Compare Plans:** Use Query Store reports to identify regressed queries.
3. **Force Good Plans:** Use `sp_query_store_force_plan` for immediate relief.
4. **Check Resource Limits:** Verify the Azure SQL tier provides sufficient CPU, memory, and IOPS using `sys.dm_db_resource_stats`.
5. **Compatibility Level:** If I migrated at the original compat level, test raising it incrementally.
6. **Update Statistics:** Ensure statistics are current after migration.
7. **Index Tuning:** Review missing index DMVs and Azure SQL automatic tuning recommendations.
8. **Scale Up if Needed:** Temporarily scale to a higher tier to isolate resource bottlenecks.

### Q4: What is the difference between DTU and vCore, and when would you choose each?

**Answer:** DTU is a blended, opaque measure of CPU, memory, and I/O bundled together. vCore exposes individual compute cores and memory, allowing independent storage scaling. I recommend vCore for most production workloads because it provides transparent resource allocation that maps directly to on-premises server specs, supports Azure Hybrid Benefit for significant license savings, offers reserved capacity pricing, and gives flexibility to scale compute and storage independently. DTU is acceptable for simple, small workloads where pricing simplicity is valued.

### Q5: Explain Azure SQL Hyperscale architecture and its advantages.

**Answer:** Hyperscale separates the storage engine into distinct layers: compute nodes handle query processing, page servers cache and serve data pages, and a dedicated log service manages transaction log durability. This decoupled architecture enables databases up to 100 TB, near-instant backups (snapshot-based regardless of size), fast point-in-time restore, rapid compute scaling without data movement, and up to four named read replicas for read scale-out. It is ideal for large databases that are difficult to manage in General Purpose or Business Critical tiers.

---

## Tips for Interview Success

1. **Know the migration decision tree cold.** Interviewers frequently ask "how would you choose between the three Azure SQL deployment options" -- have a structured framework ready.

2. **Emphasize minimal-downtime migration.** Always lead with online/near-zero-downtime migration methods. Suggesting a full-downtime approach for a large production database signals inexperience.

3. **Discuss cost optimization proactively.** Mentioning Azure Hybrid Benefit, reserved capacity, and right-sizing shows you think about total cost of ownership, not just technical feasibility.

4. **Highlight assessment and testing rigor.** Describe a structured approach: assess with DMA, test with DEA, migrate with DMS, validate with Query Store. This demonstrates methodical execution.

5. **Understand networking.** Be prepared to discuss VNet integration, private endpoints, ExpressRoute vs VPN, and firewall rules for Azure SQL -- these are common follow-up questions.

6. **Know the limitations.** Being able to articulate what does NOT work in Azure SQL Database vs Managed Instance is more impressive than listing what does. It shows real hands-on experience.

7. **Stay current.** Azure SQL evolves rapidly. Features like Managed Instance Link, Hyperscale named replicas, and ledger tables are recent additions that demonstrate you keep your skills current.

---
