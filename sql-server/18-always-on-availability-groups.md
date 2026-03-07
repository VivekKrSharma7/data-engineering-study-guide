# Always On Availability Groups

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Introduction](#introduction)
2. [AG Architecture](#ag-architecture)
3. [Primary and Secondary Replicas](#primary-and-secondary-replicas)
4. [Synchronous vs Asynchronous Commit](#synchronous-vs-asynchronous-commit)
5. [Automatic vs Manual Failover](#automatic-vs-manual-failover)
6. [Readable Secondary Replicas](#readable-secondary-replicas)
7. [Listener Configuration](#listener-configuration)
8. [Connection Routing](#connection-routing)
9. [Seeding (Automatic vs Manual)](#seeding-automatic-vs-manual)
10. [Distributed Availability Groups](#distributed-availability-groups)
11. [Basic Availability Groups](#basic-availability-groups)
12. [Monitoring Availability Groups](#monitoring-availability-groups)
13. [Common Issues and Troubleshooting](#common-issues-and-troubleshooting)
14. [AG vs FCI Comparison](#ag-vs-fci-comparison)
15. [Quorum and Cluster Configuration](#quorum-and-cluster-configuration)
16. [Common Interview Questions](#common-interview-questions)
17. [Tips](#tips)

---

## Introduction

Always On Availability Groups (AGs) are SQL Server's premier high availability and disaster recovery solution, introduced in SQL Server 2012. An AG is a group of databases that fail over together as a single unit, providing automatic failover, readable secondary replicas, and data redundancy across multiple servers.

AGs are built on top of Windows Server Failover Clustering (WSFC) infrastructure (or, starting with SQL Server 2017, on Linux using Pacemaker). They provide database-level protection, unlike Failover Cluster Instances (FCIs) which provide instance-level protection.

---

## AG Architecture

### Core Components

1. **Availability Group**: A logical container for one or more user databases that fail over together.
2. **Availability Replicas**: SQL Server instances hosting copies of the AG databases. One primary, up to eight secondaries (SQL Server 2019+; earlier versions support up to four synchronous + four asynchronous).
3. **Availability Databases**: The user databases participating in the group.
4. **Availability Group Listener**: A virtual network name (VNN) and IP address that clients use to connect, abstracting the actual server hosting the primary.
5. **Windows Server Failover Cluster (WSFC)**: The underlying cluster infrastructure providing health monitoring, quorum, and failover orchestration.

### Data Flow

```
Client Application
       |
       v
 AG Listener (VNN)
       |
       v
 Primary Replica -----> Log blocks sent -----> Secondary Replica(s)
 (Read/Write)           via database           (Redo applied)
                        mirroring endpoint
```

All data changes occur on the primary replica. The transaction log records are shipped to secondary replicas via a dedicated **database mirroring endpoint** (TCP port 5022 by default). Secondaries continuously apply (redo) the received log records to keep their copies of the databases synchronized.

---

## Primary and Secondary Replicas

### Primary Replica

- The single replica that accepts read-write operations.
- All INSERT, UPDATE, DELETE operations must go through the primary.
- Sends log blocks to all configured secondary replicas.
- Only one primary exists at any time per AG.

### Secondary Replicas

- Receive and apply log records from the primary.
- Can be configured as readable (for read-only workloads) or non-readable.
- Can serve as failover targets (automatic or manual).
- Each secondary maintains its own copy of the databases on its own storage (no shared storage required).

### Replica States

| State          | Description                                                    |
|----------------|----------------------------------------------------------------|
| SYNCHRONIZED   | Secondary has received and hardened all log records from primary |
| SYNCHRONIZING  | Secondary is catching up; some log records are pending          |
| NOT SYNCHRONIZING | Communication or redo problem; secondary is falling behind   |
| RESOLVING      | Replica is in a transitional state during failover              |

---

## Synchronous vs Asynchronous Commit

### Synchronous Commit Mode

- The primary waits for the secondary to harden (write to disk) the log records before acknowledging the commit to the client.
- **Zero data loss** is guaranteed -- no committed transaction can be lost during failover.
- Adds latency to write operations due to the round-trip wait.
- Best for replicas in the same data center or connected via low-latency networks.

```
Transaction Commit Flow (Synchronous):

1. Client issues COMMIT
2. Primary writes log record to its log file
3. Primary sends log block to secondary
4. Secondary writes log block to its log file (hardens)
5. Secondary sends acknowledgment to primary
6. Primary acknowledges COMMIT to client
```

### Asynchronous Commit Mode

- The primary does not wait for the secondary to harden the log before acknowledging the commit.
- Transactions are committed as soon as the primary hardens its own log.
- **Potential data loss** during failover -- transactions committed on the primary but not yet hardened on the secondary are lost.
- Minimal impact on write latency.
- Best for disaster recovery replicas in remote data centers with higher network latency.

```
Transaction Commit Flow (Asynchronous):

1. Client issues COMMIT
2. Primary writes log record to its log file
3. Primary acknowledges COMMIT to client (immediately)
4. Primary sends log block to secondary (in background)
5. Secondary writes log block to its log file (at its own pace)
```

### Configuring Commit Mode

```sql
-- Set a replica to synchronous commit
ALTER AVAILABILITY GROUP [MyAG]
MODIFY REPLICA ON N'Server2'
WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);

-- Set a replica to asynchronous commit
ALTER AVAILABILITY GROUP [MyAG]
MODIFY REPLICA ON N'Server3'
WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);
```

---

## Automatic vs Manual Failover

### Automatic Failover

- Only available with **synchronous commit** replicas.
- Requires the secondary to be in the SYNCHRONIZED state.
- The WSFC detects that the primary is unavailable and automatically promotes a synchronous secondary.
- Maximum of **two replicas** can be configured for automatic failover (the primary and one secondary).
- **No data loss** (since synchronous commit guarantees all log records are hardened on the secondary).

```sql
-- Enable automatic failover on a synchronous replica
ALTER AVAILABILITY GROUP [MyAG]
MODIFY REPLICA ON N'Server2'
WITH (
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    FAILOVER_MODE = AUTOMATIC
);
```

### Manual Failover (Planned)

- Initiated by an administrator, typically for maintenance.
- Can be performed on synchronous replicas without data loss.
- On asynchronous replicas, it becomes a **forced failover** with potential data loss.

```sql
-- Planned manual failover (run on the target secondary)
ALTER AVAILABILITY GROUP [MyAG] FAILOVER;

-- Forced failover with potential data loss (run on the target secondary)
ALTER AVAILABILITY GROUP [MyAG] FORCE_FAILOVER_ALLOW_DATA_LOSS;
```

### Failover Conditions for Automatic Failover

Automatic failover is triggered when:
1. The primary replica becomes unavailable (crash, network isolation).
2. The WSFC determines the primary node has failed.
3. The secondary is in SYNCHRONIZED state and configured for automatic failover.

SQL Server also has **flexible failover policy** conditions:

| Level | Condition                                                          |
|-------|--------------------------------------------------------------------|
| 1     | Server is down (OS crash, SQL Service stopped)                     |
| 2     | Server is unresponsive (default)                                   |
| 3     | Critical SQL Server errors (out of memory, severe internal errors) |
| 4     | Moderate SQL Server errors (persistent resource waits)             |
| 5     | Any qualified failure condition                                    |

```sql
-- Set the failure condition level
ALTER AVAILABILITY GROUP [MyAG]
SET (FAILURE_CONDITION_LEVEL = 3);

-- Set health check timeout (milliseconds)
ALTER AVAILABILITY GROUP [MyAG]
SET (HEALTH_CHECK_TIMEOUT = 30000);
```

---

## Readable Secondary Replicas

Secondary replicas can be configured to accept read-only workloads, offloading reporting and analytics from the primary.

### Configuration Options

| Setting              | Description                                           |
|----------------------|-------------------------------------------------------|
| NO                   | No read access allowed (connections are rejected)     |
| READ_ONLY            | Only explicit read-intent connections are accepted    |
| ALL                  | All connections are accepted (read-only is enforced)  |

```sql
ALTER AVAILABILITY GROUP [MyAG]
MODIFY REPLICA ON N'Server2'
WITH (SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY));
```

### How Readable Secondaries Work

- Queries on readable secondaries use **snapshot isolation** automatically (even if the database uses READ COMMITTED on the primary). Row versioning is used to prevent reader-redo conflicts.
- Redo continues to apply log records while reads are happening -- they do not block each other.
- Data on the secondary may be slightly behind the primary (especially with asynchronous commit), so queries reflect a "near real-time" view.

### Use Cases

- Reporting and dashboards
- Backup offloading (BACKUP DATABASE and BACKUP LOG can run on a secondary)
- Read-scale workloads (distributing reads across multiple secondaries)

### Latency Considerations

```sql
-- Check data latency on a secondary
SELECT
    ag.name AS ag_name,
    drs.database_id,
    DB_NAME(drs.database_id) AS database_name,
    drs.last_commit_time,
    drs.last_hardened_time,
    drs.last_redone_time,
    DATEDIFF(SECOND, drs.last_commit_time, GETDATE()) AS data_latency_seconds
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_groups ag
    ON drs.group_id = ag.group_id
WHERE drs.is_local = 1;
```

---

## Listener Configuration

The AG Listener provides a single, stable connection point for client applications, regardless of which replica is currently the primary.

### Listener Components

- **Virtual Network Name (VNN)**: A DNS name (e.g., `MyAG-Listener`).
- **IP Address(es)**: One or more static IP addresses (one per subnet for multi-subnet deployments).
- **Port**: Typically 1433, but configurable.

### Creating a Listener

```sql
ALTER AVAILABILITY GROUP [MyAG]
ADD LISTENER N'MyAG-Listener' (
    WITH IP (
        (N'10.0.1.100', N'255.255.255.0'),  -- Subnet 1
        (N'10.0.2.100', N'255.255.255.0')   -- Subnet 2
    ),
    PORT = 1433
);
```

### Connection Strings

```
-- Basic connection through the listener
Server=MyAG-Listener,1433;Database=MyDatabase;...

-- With ApplicationIntent for read-only routing
Server=MyAG-Listener,1433;Database=MyDatabase;ApplicationIntent=ReadOnly;...

-- With MultiSubnetFailover for faster failover in multi-subnet deployments
Server=MyAG-Listener,1433;Database=MyDatabase;MultiSubnetFailover=True;...
```

### MultiSubnetFailover

In multi-subnet AG deployments, the `MultiSubnetFailover=True` connection string property causes the client driver to attempt connections to all listener IP addresses in parallel, connecting to whichever responds first. Without this, the client tries each IP sequentially, leading to slow failover detection.

---

## Connection Routing

### Read-Only Routing

Read-only routing allows connections with `ApplicationIntent=ReadOnly` to be automatically redirected from the listener to a readable secondary.

```sql
-- Step 1: Set the read-only routing URL for each replica
ALTER AVAILABILITY GROUP [MyAG]
MODIFY REPLICA ON N'Server1'
WITH (SECONDARY_ROLE (
    READ_ONLY_ROUTING_URL = N'TCP://Server1.domain.com:1433'
));

ALTER AVAILABILITY GROUP [MyAG]
MODIFY REPLICA ON N'Server2'
WITH (SECONDARY_ROLE (
    READ_ONLY_ROUTING_URL = N'TCP://Server2.domain.com:1433'
));

-- Step 2: Define the routing list for when each server is primary
ALTER AVAILABILITY GROUP [MyAG]
MODIFY REPLICA ON N'Server1'
WITH (PRIMARY_ROLE (
    READ_ONLY_ROUTING_LIST = (N'Server2', N'Server3')
));

ALTER AVAILABILITY GROUP [MyAG]
MODIFY REPLICA ON N'Server2'
WITH (PRIMARY_ROLE (
    READ_ONLY_ROUTING_LIST = (N'Server1', N'Server3')
));
```

### Load-Balanced Read-Only Routing (SQL Server 2016+)

You can define groups within the routing list for round-robin load balancing.

```sql
-- Load balance across Server2 and Server3
ALTER AVAILABILITY GROUP [MyAG]
MODIFY REPLICA ON N'Server1'
WITH (PRIMARY_ROLE (
    READ_ONLY_ROUTING_LIST = ((N'Server2', N'Server3'), N'Server1')
));
-- Server2 and Server3 are in a load-balanced group (inner parentheses)
-- Server1 is a fallback if both are unavailable
```

---

## Seeding (Automatic vs Manual)

Seeding is the process of initializing the database on a secondary replica.

### Manual Seeding (Traditional)

1. Take a full backup of the database on the primary.
2. Take a log backup.
3. Restore both on the secondary WITH NORECOVERY.
4. Join the database to the AG on the secondary.

```sql
-- On the primary
BACKUP DATABASE [MyDatabase] TO DISK = '\\Share\MyDatabase.bak'
WITH INIT, COMPRESSION;
BACKUP LOG [MyDatabase] TO DISK = '\\Share\MyDatabase_log.trn'
WITH INIT, COMPRESSION;

-- On the secondary
RESTORE DATABASE [MyDatabase] FROM DISK = '\\Share\MyDatabase.bak'
WITH NORECOVERY, MOVE N'MyDatabase' TO N'D:\Data\MyDatabase.mdf',
     MOVE N'MyDatabase_log' TO N'E:\Log\MyDatabase_log.ldf';
RESTORE LOG [MyDatabase] FROM DISK = '\\Share\MyDatabase_log.trn'
WITH NORECOVERY;

-- Join the database to the AG on the secondary
ALTER DATABASE [MyDatabase] SET HADR AVAILABILITY GROUP = [MyAG];
```

### Automatic Seeding (SQL Server 2016+)

SQL Server handles the initial data transfer automatically over the database mirroring endpoint. No manual backup/restore is needed.

```sql
-- Enable automatic seeding on the AG
ALTER AVAILABILITY GROUP [MyAG]
MODIFY REPLICA ON N'Server2'
WITH (SEEDING_MODE = AUTOMATIC);

-- Grant the AG permission to create databases on the secondary
-- (Run on the secondary)
ALTER AVAILABILITY GROUP [MyAG] GRANT CREATE ANY DATABASE;
```

### Automatic Seeding Considerations

- Uses the database mirroring endpoint, so bandwidth is shared with log shipping.
- For very large databases, manual seeding with backup/restore to a shared location is typically faster.
- Seeding progress can be monitored:

```sql
-- Monitor automatic seeding progress
SELECT
    ag.name AS ag_name,
    drs.database_name,
    drs.current_state,
    drs.performed_seeding,
    drs.failure_state_desc,
    drs.number_of_attempts
FROM sys.dm_hadr_automatic_seeding drs
JOIN sys.availability_groups ag
    ON drs.ag_id = ag.group_id;
```

---

## Distributed Availability Groups

Distributed AGs span two separate WSFC clusters (or two separate AG implementations), providing a way to implement cross-data-center or cross-region DR without requiring a single WSFC to span both sites.

### Architecture

```
WSFC Cluster 1                    WSFC Cluster 2
+-----------------+               +-----------------+
| AG1 (Primary)   | -- DAG ----> | AG2 (Forwarder)  |
|  Server1 (P)    |              |  Server3 (P)     |
|  Server2 (S)    |              |  Server4 (S)     |
+-----------------+               +-----------------+
```

- AG1 is the primary AG; AG2 is the secondary AG.
- The primary replica of AG2 acts as a "forwarder" -- it receives log records from AG1 and redistributes them to its own secondaries.
- Each AG has its own listener, quorum, and independent management.

### Creating a Distributed AG

```sql
-- On the primary cluster (AG1's primary)
CREATE AVAILABILITY GROUP [DistributedAG]
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
    N'AG1' WITH (
        LISTENER_URL = N'TCP://AG1-Listener:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    ),
    N'AG2' WITH (
        LISTENER_URL = N'TCP://AG2-Listener:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    );

-- On the secondary cluster (AG2's primary)
ALTER AVAILABILITY GROUP [DistributedAG] JOIN
AVAILABILITY GROUP ON
    N'AG1' WITH (
        LISTENER_URL = N'TCP://AG1-Listener:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    ),
    N'AG2' WITH (
        LISTENER_URL = N'TCP://AG2-Listener:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    );
```

### Use Cases

- Cross-data-center disaster recovery
- Database migration between clusters with minimal downtime
- Multi-region deployments for global applications

---

## Basic Availability Groups

Introduced in SQL Server 2016 Standard Edition, Basic AGs provide a limited but valuable HA solution for Standard Edition customers.

### Limitations of Basic AGs

| Feature                    | Enterprise AG          | Basic AG (Standard)    |
|----------------------------|------------------------|------------------------|
| Number of databases        | Unlimited per AG       | **One** per AG         |
| Number of replicas         | Up to 9                | **2** (one primary, one secondary) |
| Readable secondary         | Yes                    | **No**                 |
| Backup on secondary        | Yes                    | **No**                 |
| Automatic seeding          | Yes (2016+)            | No (2016), Yes (2017+) |

Basic AGs are essentially a replacement for database mirroring, which was deprecated in SQL Server 2012.

```sql
-- Create a Basic AG (Standard Edition)
CREATE AVAILABILITY GROUP [BasicAG]
WITH (BASIC, DB_FAILOVER = ON)
FOR DATABASE [MyDatabase]
REPLICA ON
    N'Server1' WITH (
        ENDPOINT_URL = N'TCP://Server1:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = AUTOMATIC
    ),
    N'Server2' WITH (
        ENDPOINT_URL = N'TCP://Server2:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = AUTOMATIC
    );
```

---

## Monitoring Availability Groups

### Key DMVs

#### sys.dm_hadr_availability_replica_states

Shows the state and health of each replica.

```sql
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.operational_state_desc,
    ars.connected_state_desc,
    ars.synchronization_health_desc,
    ars.last_connect_error_number,
    ars.last_connect_error_timestamp
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar
    ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag
    ON ar.group_id = ag.group_id;
```

#### sys.dm_hadr_database_replica_states

Shows per-database synchronization state.

```sql
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    DB_NAME(drs.database_id) AS database_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.log_send_queue_size,         -- KB of log not yet sent
    drs.log_send_rate,               -- KB/s
    drs.redo_queue_size,             -- KB of log not yet redone
    drs.redo_rate,                   -- KB/s
    drs.last_commit_time,
    drs.last_hardened_time,
    drs.last_redone_time,
    DATEDIFF(SECOND, drs.last_redone_time, drs.last_commit_time) AS redo_lag_seconds
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar
    ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag
    ON ar.group_id = ag.group_id;
```

#### sys.dm_hadr_availability_group_states

Overall AG health.

```sql
SELECT
    ag.name AS ag_name,
    ags.primary_replica,
    ags.primary_recovery_health_desc,
    ags.secondary_recovery_health_desc,
    ags.synchronization_health_desc
FROM sys.dm_hadr_availability_group_states ags
JOIN sys.availability_groups ag
    ON ags.group_id = ag.group_id;
```

### SSMS Dashboard

The Always On Availability Groups Dashboard in SSMS provides a visual overview of AG health, synchronization state, and failover readiness. Right-click the AG in Object Explorer and select "Show Dashboard."

### Alerting on Key Metrics

```sql
-- Alert if redo queue exceeds threshold (potential data loss window)
SELECT
    ar.replica_server_name,
    DB_NAME(drs.database_id) AS database_name,
    drs.redo_queue_size AS redo_queue_kb,
    drs.log_send_queue_size AS send_queue_kb
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar
    ON drs.replica_id = ar.replica_id
WHERE drs.redo_queue_size > 102400  -- > 100 MB
   OR drs.log_send_queue_size > 102400;
```

---

## Common Issues and Troubleshooting

### Issue 1: Secondary Falling Behind (Large Send/Redo Queue)

**Symptoms**: `log_send_queue_size` or `redo_queue_size` growing steadily.

**Causes**:
- Network bandwidth saturation between primary and secondary.
- Redo thread bottleneck on the secondary (disk I/O, CPU).
- Large transactions generating massive amounts of log.

**Solutions**:
- Check network throughput between replicas.
- Ensure secondary storage can handle redo I/O (place log and data on separate fast disks).
- Consider using asynchronous commit for remote secondaries to avoid primary latency impact.
- For redo bottleneck on SQL Server 2016+, enable parallel redo (automatic for databases with multiple file groups).

### Issue 2: Automatic Failover Not Occurring

**Causes**:
- Secondary is not in SYNCHRONIZED state.
- Failover mode is set to MANUAL, not AUTOMATIC.
- WSFC quorum is lost.
- Cluster health check timeout not exceeded yet.
- Flexible failover policy condition level not met.

**Troubleshooting**:

```sql
-- Check replica configuration
SELECT
    ar.replica_server_name,
    ar.availability_mode_desc,
    ar.failover_mode_desc,
    ars.synchronization_health_desc,
    ars.connected_state_desc
FROM sys.availability_replicas ar
JOIN sys.dm_hadr_availability_replica_states ars
    ON ar.replica_id = ars.replica_id;
```

### Issue 3: Listener Connection Failures

**Causes**:
- DNS resolution failure for the listener name.
- Listener IP not online in the cluster.
- Firewall blocking the listener port.
- Client not using `MultiSubnetFailover=True` in multi-subnet scenarios.

**Troubleshooting**:
- Verify listener status: `Get-ClusterResource` in PowerShell.
- Test connectivity: `Test-NetConnection -ComputerName MyAG-Listener -Port 1433`.
- Check DNS: `nslookup MyAG-Listener`.

### Issue 4: Data Movement Suspended

**Symptoms**: Database shows "Not Synchronizing" and data movement is suspended.

**Causes**:
- Manual suspension (someone ran `ALTER DATABASE ... SET HADR SUSPEND`).
- Disk space exhaustion on the secondary.
- Redo error (corrupt log record, missing filegroup).

**Solutions**:

```sql
-- Resume data movement
ALTER DATABASE [MyDatabase] SET HADR RESUME;

-- Check for errors in the SQL Server error log on the secondary
EXEC xp_readerrorlog 0, 1, N'AlwaysOn';
```

### Issue 5: Split-Brain Scenario

A split-brain occurs when network partitioning causes both replicas to believe they are the primary. WSFC quorum prevents this -- only the partition with quorum can host the primary.

**Prevention**: Proper quorum configuration (see Quorum section below).

---

## AG vs FCI Comparison

| Feature                           | Availability Groups           | Failover Cluster Instances    |
|-----------------------------------|-------------------------------|-------------------------------|
| **Protection level**              | Database level                | Instance level                |
| **Shared storage required**       | No (each replica has its own) | Yes (SAN, S2D)               |
| **Number of databases**           | Selective (choose which DBs)  | All databases in the instance |
| **Readable secondaries**          | Yes                           | No                            |
| **Failover scope**                | Database(s) in the AG         | Entire SQL Server instance    |
| **Automatic failover**            | Yes (synchronous replicas)    | Yes                           |
| **Multiple copies of data**       | Yes (each replica)            | No (single copy on shared storage) |
| **Network name**                  | AG Listener                   | FCI Virtual Network Name      |
| **System databases replicated**   | No (logins, jobs, etc. must be synced manually) | Yes (shared storage)  |
| **Can combine both**              | Yes (AG on top of FCI)        | Yes (FCI as an AG replica)    |

### When to Use Each

- **AG**: When you need database-level HA/DR, readable secondaries, or cross-data-center DR without shared storage.
- **FCI**: When you need instance-level protection and have shared storage infrastructure, or when you want system databases (logins, Agent jobs) to fail over automatically.
- **Both**: Use FCI for local HA (automatic instance failover) and AG for DR (database-level replication to a remote site).

---

## Quorum and Cluster Configuration

### What Is Quorum?

Quorum is the voting mechanism that determines whether a WSFC cluster has enough members online to function. A cluster must have a majority of votes to remain operational. Without quorum, the cluster stops hosting resources (including AGs).

### Quorum Models

| Model                     | Description                                               |
|---------------------------|-----------------------------------------------------------|
| Node Majority             | Majority of cluster nodes must be online                  |
| Node and Disk Majority    | Majority of nodes + a shared disk witness                 |
| Node and File Share Majority | Majority of nodes + a file share witness              |
| Cloud Witness             | Majority of nodes + an Azure Blob storage witness (2016+) |

### Quorum Math

- With **3 nodes**: 2 must be online (can tolerate 1 failure).
- With **4 nodes + 1 witness**: 3 of 5 votes must be online (can tolerate 2 failures).
- With **2 nodes + 1 witness**: 2 of 3 votes must be online (can tolerate 1 failure).

### Cloud Witness (Recommended for Modern Deployments)

```powershell
# Configure a Cloud Witness using PowerShell
Set-ClusterQuorum -CloudWitness `
    -AccountName "mystorageaccount" `
    -AccessKey "storage-account-access-key" `
    -Endpoint "core.windows.net"
```

Cloud Witness is a neutral third-party vote in Azure Blob storage, ideal for:
- Two-node clusters.
- Multi-site deployments where you do not want the witness in either data center.

### Best Practices for Quorum

- Always use an odd number of total votes (nodes + witness).
- For two-node clusters, always configure a witness.
- Use Cloud Witness for simplicity and site neutrality.
- Do not remove quorum votes from nodes hosting AG replicas.

---

## Common Interview Questions

### Q1: Explain the architecture of Always On Availability Groups.

An AG consists of a group of user databases that fail over as a unit. There is one primary replica (accepting read-write workloads) and up to eight secondary replicas. Data synchronization occurs by shipping transaction log records from the primary to secondaries via a database mirroring endpoint. Secondaries continuously apply (redo) these log records. An AG Listener provides a virtual network name for client connections, abstracting the physical primary server. The whole system is built on top of Windows Server Failover Clustering (WSFC), which provides health monitoring, quorum, and failover orchestration.

### Q2: What is the difference between synchronous and asynchronous commit?

**Synchronous commit**: The primary waits for the secondary to harden (write to disk) the log records before acknowledging the commit to the client. This guarantees zero data loss but adds network round-trip latency to every commit. Best for local HA replicas with low-latency connections.

**Asynchronous commit**: The primary acknowledges the commit as soon as it hardens its own log, without waiting for the secondary. Log records are sent to the secondary in the background. This provides better write performance but risks data loss during failover (committed transactions on the primary may not have reached the secondary). Best for remote DR replicas.

### Q3: How does automatic failover work?

Automatic failover requires: (1) the secondary to be in synchronous commit mode, (2) the secondary to be in SYNCHRONIZED state, (3) the failover mode set to AUTOMATIC, and (4) WSFC quorum to be intact. When the cluster detects the primary is unavailable (based on the health check timeout and failure condition level), it promotes the synchronous secondary to primary. Since the secondary is guaranteed to have all committed transactions (synchronous commit), there is zero data loss. The AG Listener is updated to point to the new primary.

### Q4: What is a readable secondary and how does it work?

A readable secondary accepts read-only connections and serves queries against a near-real-time copy of the primary's data. It uses snapshot isolation internally to prevent redo (log apply) from blocking reads. Data may be slightly behind the primary depending on redo throughput. Readable secondaries are useful for offloading reporting, analytics, and backup operations from the primary. Configuration options are NO (no connections), READ_ONLY (only read-intent connections), or ALL (all connections, enforced as read-only).

### Q5: Explain read-only routing.

Read-only routing automatically redirects connections with `ApplicationIntent=ReadOnly` from the AG Listener to a readable secondary. The primary acts as a router: it receives the connection, detects the read-only intent, and redirects the client to a secondary in the read-only routing list. In SQL Server 2016+, you can configure load-balanced routing lists to distribute read-only connections across multiple secondaries using round-robin.

### Q6: What is the difference between an AG and an FCI?

AGs provide **database-level** protection without shared storage -- each replica has its own copy of the data. AGs support readable secondaries and can replicate across data centers. FCIs provide **instance-level** protection using shared storage -- all databases, logins, and jobs fail over together, but there is only one copy of the data. FCIs require SAN or shared storage infrastructure. AGs and FCIs can be combined (an FCI can be a replica in an AG).

### Q7: How do you monitor AG health and synchronization lag?

Key DMVs include `sys.dm_hadr_database_replica_states` (check `log_send_queue_size`, `redo_queue_size`, `synchronization_state_desc`), `sys.dm_hadr_availability_replica_states` (check `connected_state_desc`, `synchronization_health_desc`), and `sys.dm_hadr_availability_group_states` (overall AG health). The SSMS Always On Dashboard provides a visual overview. Key metrics to alert on: redo queue size exceeding a threshold, synchronization state changing to NOT SYNCHRONIZING, and log send queue growth.

### Q8: What is a Distributed AG and when would you use it?

A Distributed AG connects two separate AGs across two independent WSFC clusters. The primary of the second AG acts as a "forwarder," receiving log records from the first AG and distributing them to its own secondaries. Use cases include cross-data-center DR (where a single WSFC cannot span both sites), database migration between clusters with minimal downtime, and multi-region deployments. Distributed AGs always use asynchronous commit between the two AGs.

### Q9: Describe the seeding process for adding a new secondary replica.

**Manual seeding**: Take a full backup and log backup of the database on the primary, restore them on the secondary WITH NORECOVERY, then join the database to the AG. This is faster for large databases as you can use backup compression and a fast network share.

**Automatic seeding** (SQL Server 2016+): SQL Server streams the database data directly from the primary to the secondary over the mirroring endpoint. No manual backup/restore is needed. You enable it by setting `SEEDING_MODE = AUTOMATIC` and granting `CREATE ANY DATABASE` on the secondary. Automatic seeding is simpler but slower for very large databases.

### Q10: What prevents split-brain in an AG deployment?

WSFC quorum prevents split-brain. Only the cluster partition that maintains quorum (a majority of votes) can host AG resources. If a network partition splits the cluster into two halves, only the half with quorum continues operating. The other half takes its AG resources offline. A Cloud Witness or file share witness provides a tie-breaking vote for even-numbered node clusters.

---

## Tips

- **Always configure a witness (Cloud Witness, file share, or disk) for your WSFC cluster.** Without a witness, a two-node cluster loses quorum if either node fails, defeating the purpose of HA.

- **Use synchronous commit only when network latency is low** (same data center, < 1ms round trip). Synchronous commit across a WAN adds commit latency equal to the network round-trip time and can severely impact OLTP throughput.

- **Monitor `log_send_queue_size` and `redo_queue_size` continuously.** The send queue size for asynchronous replicas represents your potential data loss window (RPO). The redo queue size represents how far behind the secondary's readable data is.

- **Synchronize logins, Agent jobs, linked servers, and other server-level objects manually.** AGs only replicate database-level objects. Use DBATools (`Copy-DbaLogin`, `Copy-DbaAgentJob`) or custom scripts to keep server-level objects in sync across replicas.

- **Use `MultiSubnetFailover=True` in all connection strings** for multi-subnet AG deployments. This enables parallel connection attempts to all listener IPs, reducing failover detection time from ~20 seconds to under 1 second.

- **Test failover regularly.** A planned manual failover during a maintenance window validates that your HA configuration works correctly. Automate this testing if possible.

- **For large database initial seeding, manual backup/restore is almost always faster than automatic seeding.** Use backup compression and a high-speed network share or direct attached storage to minimize seeding time.

- **Consider using contained databases or partially contained databases** to reduce the dependency on server-level logins. Contained database users authenticate at the database level and are automatically available on all replicas.

- **AG databases cannot be dropped while they are part of the AG.** You must first remove the database from the AG (`ALTER AVAILABILITY GROUP ... REMOVE DATABASE`), then drop it on each replica individually.

- **Plan your AG topology carefully.** Having too many synchronous replicas adds latency. A common pattern is: 1 synchronous replica for local HA (automatic failover), 1-2 asynchronous replicas for DR and/or read scale.
