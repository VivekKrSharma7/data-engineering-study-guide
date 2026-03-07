# Failover Cluster Instances (FCI)

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Introduction](#introduction)
2. [Windows Server Failover Clustering (WSFC)](#windows-server-failover-clustering-wsfc)
3. [FCI Architecture](#fci-architecture)
4. [Quorum Modes](#quorum-modes)
5. [Storage Options](#storage-options)
6. [Active-Passive vs Active-Active](#active-passive-vs-active-active)
7. [SQL Server FCI Installation](#sql-server-fci-installation)
8. [Multi-Subnet Failover](#multi-subnet-failover)
9. [FCI vs Availability Groups](#fci-vs-availability-groups)
10. [FCI + AG Combined Topology](#fci--ag-combined-topology)
11. [FCI Limitations](#fci-limitations)
12. [Monitoring and Maintenance](#monitoring-and-maintenance)
13. [Common Interview Questions](#common-interview-questions)
14. [Tips](#tips)

---

## Introduction

A **Failover Cluster Instance (FCI)** is an instance of SQL Server that is installed across the nodes of a Windows Server Failover Cluster (WSFC). At any given time, only one node in the cluster owns the SQL Server resource group. If the active node experiences a hardware failure, operating system crash, or planned maintenance, ownership of the resource group moves to another node in the cluster — a process called **failover**.

FCI provides **instance-level high availability** with automatic failover. Clients connect using a single **Virtual Network Name (VNN)**, making failover transparent to applications.

---

## Windows Server Failover Clustering (WSFC)

WSFC is the underlying Windows infrastructure that FCI relies upon. It manages cluster membership, heartbeat detection, resource groups, and failover orchestration.

### Key WSFC Concepts

| Concept | Description |
|---|---|
| **Node** | A server (physical or VM) that is a member of the cluster |
| **Resource Group** | A collection of cluster resources that fail over together |
| **Heartbeat** | Network signal between nodes to verify health |
| **Cluster Network** | Dedicated network(s) for intra-cluster communication |
| **Virtual IP (VIP)** | Shared IP address that clients use to connect |
| **Virtual Network Name (VNN)** | DNS name mapped to the VIP |

### WSFC Requirements

- All nodes must be joined to the same Active Directory domain (or use a workgroup cluster in newer versions).
- All nodes must run the same Windows Server edition and version.
- The Failover Clustering feature must be installed on every node.
- Cluster validation must pass before creating the cluster.

```powershell
-- Install the Failover Clustering feature (PowerShell)
Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools

-- Validate cluster configuration
Test-Cluster -Node Node1, Node2 -Include "Storage","Network","System Configuration"

-- Create the cluster
New-Cluster -Name "SQLCluster" -Node Node1, Node2 -StaticAddress 10.0.0.10
```

---

## FCI Architecture

### How FCI Works

1. SQL Server is installed as a clustered instance across two or more WSFC nodes.
2. All nodes share access to the same storage (databases, tempdb, binaries can vary by version).
3. Only one node runs the SQL Server instance at a time (the **active** node).
4. If the active node fails, WSFC detects the failure via heartbeat and transfers the resource group to a surviving node.
5. The surviving node starts the SQL Server service, mounts the shared storage, and runs crash recovery on databases.

### What Fails Over

- SQL Server service
- SQL Server Agent
- Shared disk resources
- Virtual IP and Virtual Network Name
- Full-Text Search service (if installed)

### What Does NOT Fail Over

- In-flight transactions (they are rolled back during recovery)
- Client connections (they must reconnect)
- tempdb contents (tempdb is recreated on failover)
- SSIS packages (unless stored in msdb)
- Linked server logins (stored locally in memory)

---

## Quorum Modes

The quorum determines how many failures the cluster can sustain while still remaining online. A cluster must have a **majority of voting members** to maintain quorum.

### Quorum Models

| Model | Description | Best For |
|---|---|---|
| **Node Majority** | Quorum is maintained as long as a majority of nodes are online | Clusters with an odd number of nodes |
| **Node and Disk Majority** | Nodes plus a witness disk vote; majority required | Even number of nodes with shared storage |
| **Node and File Share Majority** | Nodes plus a file share witness vote | Even number of nodes, especially multi-site |
| **Cloud Witness** | Uses an Azure Blob Storage account as the witness | Multi-site clusters, modern deployments |

### Dynamic Quorum

Starting with Windows Server 2012, **dynamic quorum** automatically adjusts voting weights as nodes go offline. This prevents a situation where a cluster loses quorum due to sequential failures.

```powershell
-- Configure a cloud witness
Set-ClusterQuorum -CloudWitness `
    -AccountName "mystorageaccount" `
    -AccessKey "base64key..." `
    -Endpoint "core.windows.net"

-- Check current quorum configuration
Get-ClusterQuorum | Format-List *
```

---

## Storage Options

FCI requires shared storage accessible by all nodes. The storage holds the database files (.mdf, .ndf, .ldf) and is the single point of data ownership.

### Storage Technologies

| Technology | Description | Pros | Cons |
|---|---|---|---|
| **SAN (Fibre Channel / iSCSI)** | Traditional shared block storage | Proven, high performance | Expensive, SAN is a single point of failure |
| **Storage Spaces Direct (S2D)** | Software-defined storage using local disks across nodes | No SAN required, cost-effective | Requires Windows Server 2016+, more complex setup |
| **Azure Shared Disks** | Managed disks that can be attached to multiple Azure VMs | Native cloud support, easy provisioning | Limited IOPS scaling, regional availability |
| **SMB 3.0 File Share** | Databases stored on a continuously available SMB share | No shared block storage needed | Requires robust network, SMB Multichannel recommended |
| **SIOS DataKeeper** | Third-party replication that mirrors local storage between nodes | No shared storage needed, works cross-subnet | Third-party cost and complexity |

### Configuring Shared Storage

```sql
-- After FCI installation, verify storage is accessible
-- Check database file locations
SELECT
    db.name AS DatabaseName,
    mf.name AS LogicalName,
    mf.physical_name AS PhysicalPath,
    mf.type_desc AS FileType,
    mf.size * 8 / 1024 AS SizeMB
FROM sys.master_files mf
JOIN sys.databases db ON mf.database_id = db.database_id
ORDER BY db.name, mf.type;
```

---

## Active-Passive vs Active-Active

### Active-Passive

- **One instance** of SQL Server is installed across the cluster.
- One node is active; the other node(s) are passive (idle, standing by).
- On failover, the passive node takes over.
- The passive node is not running SQL Server and is essentially idle.

**Pros:** Simple, full resources available after failover.
**Cons:** Passive node is underutilized (wasted hardware investment).

### Active-Active

- **Two or more separate FCI instances** are installed, each active on a different node.
- Each node is the active owner for one instance and the passive standby for another.
- On failover, one node may temporarily host both instances.

**Pros:** Better hardware utilization.
**Cons:** After failover, one node runs two instances, potentially causing resource contention. Requires careful resource governance (Resource Governor, CPU affinity, memory caps).

```sql
-- When running active-active, set max memory for each instance
-- to avoid memory contention after failover

-- Instance 1 (on Node A normally)
EXEC sp_configure 'max server memory', 65536; -- 64 GB
RECONFIGURE;

-- Instance 2 (on Node B normally)
EXEC sp_configure 'max server memory', 65536; -- 64 GB
RECONFIGURE;

-- Ensure total memory allocation does not exceed
-- the physical memory on a single node minus OS overhead
```

---

## SQL Server FCI Installation

### Installation Steps (High-Level)

1. **Prepare the WSFC** — install the Failover Clustering feature, create and validate the cluster.
2. **Configure shared storage** — present shared disks to all nodes, format, and assign drive letters.
3. **Run SQL Server setup on the first node** — choose "New SQL Server failover cluster installation."
4. **Add nodes** — on each additional node, run SQL Server setup and choose "Add node to a SQL Server failover cluster."

### Key Setup Decisions

| Decision | Recommendation |
|---|---|
| **Instance name** | Use a named instance or default; this becomes the VNN |
| **Service accounts** | Use domain accounts; the same account must be used on all nodes |
| **tempdb location** | Place on local SSD if possible (SQL Server 2012+ supports local tempdb for FCI) |
| **Data/Log directories** | Must be on shared storage |
| **Cluster network** | Dedicate a network for cluster heartbeat |

### Post-Installation Validation

```sql
-- Confirm the FCI is running and which node is active
SELECT
    SERVERPROPERTY('MachineName') AS ActiveNode,
    SERVERPROPERTY('InstanceName') AS InstanceName,
    SERVERPROPERTY('IsClustered') AS IsClustered,
    SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS PhysicalNode;

-- List all cluster nodes
SELECT * FROM sys.dm_os_cluster_nodes;

-- Check cluster properties
SELECT * FROM sys.dm_os_cluster_properties;
```

---

## Multi-Subnet Failover

In a multi-subnet FCI, each node resides in a different subnet. When failover occurs, the VIP changes to the IP of the surviving node's subnet.

### How It Works

- Each subnet has its own IP address registered to the VNN.
- Only the IP for the active node's subnet is brought online at any time.
- After failover, DNS is updated with the new IP; the old IP goes offline.

### Client Configuration

Clients must use the `MultiSubnetFailover=True` connection string parameter to enable parallel connection attempts to all IPs simultaneously, reducing failover detection time.

```csharp
// .NET connection string for multi-subnet FCI
"Server=SQLClusterVNN;Database=MyDB;
 Integrated Security=True;
 MultiSubnetFailover=True;"
```

```sql
-- Check registered cluster IP addresses
SELECT * FROM sys.dm_os_cluster_nodes;

-- Verify listener IPs (if combined with AG)
SELECT
    ag.name AS AGName,
    agl.dns_name AS ListenerName,
    lip.ip_address,
    lip.ip_subnet_mask
FROM sys.availability_group_listener_ip_addresses lip
JOIN sys.availability_group_listeners agl ON lip.listener_id = agl.listener_id
JOIN sys.availability_groups ag ON agl.group_id = ag.group_id;
```

---

## FCI vs Availability Groups

| Feature | FCI | Availability Groups |
|---|---|---|
| **Protection level** | Instance-level | Database-level |
| **Shared storage required** | Yes (traditional) | No |
| **Data copies** | One copy on shared storage | Multiple copies (replicas) |
| **Failover granularity** | Entire instance | Per-availability group |
| **Readable secondary** | No | Yes (sync/async) |
| **Protects against storage failure** | No (shared storage is SPOF) | Yes (each replica has its own storage) |
| **Protects against node failure** | Yes | Yes |
| **DTC support** | Yes | Limited (SQL 2016+) |
| **System database failover** | Yes (msdb, model, master config) | No |
| **Max nodes/replicas** | Up to 16 nodes | Up to 9 replicas |
| **Edition** | Standard (2 nodes) / Enterprise | Standard (2 replicas, basic AG) / Enterprise |

---

## FCI + AG Combined Topology

You can combine FCI and AG to achieve both instance-level and database-level protection. In this topology, the FCI serves as one (or more) replicas within an Availability Group.

### Architecture

```
  [FCI (Node1 <-> Node2)]  ──── AG Replication ────  [Standalone Instance (Node3)]
       Primary Replica                                   Secondary Replica
       (instance-level HA)                               (database-level DR)
```

### Benefits

- **Instance-level HA** via FCI — protects against node failure.
- **Database-level DR** via AG — protects against storage failure and provides geographic redundancy.
- **Readable secondary** on the standalone replica.
- **Offloaded backups** from the secondary.

### Considerations

- The AG listener and FCI VNN are separate network names; applications should connect to the AG listener.
- Failover within the FCI is transparent to the AG — the AG does not need to fail over.
- If the entire FCI fails (both nodes + storage), the AG must fail over to the standalone replica.

---

## FCI Limitations

1. **Shared storage is a single point of failure** — if the SAN fails, all nodes lose access to data.
2. **No readable secondary** — the passive node does not run SQL Server and cannot serve read traffic.
3. **Failover time** — includes SQL Server startup and crash recovery; can take minutes for large databases.
4. **tempdb is recreated on failover** — any temporary data is lost.
5. **In-flight transactions are lost** — open transactions are rolled back during recovery.
6. **Client connections are dropped** — applications must reconnect after failover.
7. **No protection against database-level corruption** — corrupted data on shared storage affects all nodes.
8. **Cross-datacenter FCI is complex** — requires stretched VLANs or multi-subnet configuration with high-speed, low-latency links.
9. **System databases are on shared storage** — all nodes share the same jobs, logins, configurations.
10. **Patching requires failover** — rolling updates cause brief outage as the instance moves between nodes.

---

## Monitoring and Maintenance

### Cluster Health Checks

```sql
-- Check if the current instance is clustered
SELECT SERVERPROPERTY('IsClustered') AS IsClustered;

-- View cluster node status
SELECT
    NodeName,
    status,
    status_description,
    is_current_owner
FROM sys.dm_os_cluster_nodes;

-- Check cluster shared drives
SELECT
    DriveName,
    is_current_owner
FROM sys.dm_io_cluster_shared_drives;
```

### Monitoring Failover Events

```sql
-- Check SQL Server error log for failover events
EXEC xp_readerrorlog 0, 1, 'failover';
EXEC xp_readerrorlog 0, 1, 'cluster';

-- Windows cluster log (run from PowerShell on cluster node)
-- Get-ClusterLog -Destination C:\Temp -TimeSpan 60
```

### Maintenance Best Practices

| Task | Recommendation |
|---|---|
| **Patching OS** | Patch passive node first, fail over, then patch the other node |
| **Patching SQL Server** | Apply CU/SP to passive node, fail over, apply to other node |
| **Validating cluster** | Run `Test-Cluster` regularly, especially before patching |
| **Monitoring disk health** | Monitor shared storage latency, throughput, and free space |
| **Testing failover** | Perform planned failovers periodically to validate the process |
| **Backup strategy** | Back up databases as usual; FCI does not change backup behavior |

### Planned Manual Failover

```powershell
# Move SQL Server resource group to another node (PowerShell)
Move-ClusterGroup -Name "SQL Server (MSSQLSERVER)" -Node "Node2"

# Verify the move
Get-ClusterGroup -Name "SQL Server (MSSQLSERVER)" | Format-List OwnerNode, State
```

---

## Common Interview Questions

### Q1: What is a Failover Cluster Instance, and how does it differ from an Availability Group?

**Answer:** An FCI is an instance of SQL Server installed across multiple WSFC nodes that share storage. It provides instance-level high availability — if the active node fails, the entire instance (all databases, jobs, logins) fails over to a passive node. An Availability Group, on the other hand, provides database-level high availability. Each AG replica maintains its own copy of the data, does not require shared storage, and supports readable secondaries. FCI protects against node failure but not storage failure, while AG protects against both.

---

### Q2: What happens during an FCI failover? Walk through the process.

**Answer:**
1. WSFC detects the active node is unresponsive (via heartbeat timeout or resource failure).
2. WSFC transfers ownership of the SQL Server resource group to a surviving node.
3. The surviving node brings the shared disk resources online.
4. SQL Server service starts on the new node.
5. SQL Server performs crash recovery — committed transactions are rolled forward (redo), uncommitted transactions are rolled back (undo).
6. The VIP comes online on the new node's network interface.
7. Clients can now reconnect using the same VNN.

Typical failover time: 30 seconds to several minutes, depending on recovery time.

---

### Q3: What is quorum, and why is a witness important?

**Answer:** Quorum is the minimum number of voting members that must agree for the cluster to remain operational. It prevents "split-brain" scenarios where two partitions of the cluster both think they are authoritative. A witness (disk witness, file share witness, or cloud witness) acts as a tie-breaking vote, which is critical in clusters with an even number of nodes. For example, in a 2-node cluster without a witness, losing one node means losing quorum (1 of 2 is not a majority). With a file share witness, losing one node still leaves 2 of 3 votes (node + witness), maintaining quorum.

---

### Q4: Can you have tempdb on local storage in an FCI?

**Answer:** Yes, starting with SQL Server 2012, you can place tempdb on local SSD storage on each node. Since tempdb is recreated every time SQL Server starts, there is no need for it to be on shared storage. Placing tempdb on local SSD improves performance significantly because local I/O is faster than SAN I/O, and tempdb workloads are often heavy. Each node must have the same drive letter and path available for the local tempdb files.

---

### Q5: What is the difference between active-passive and active-active FCI?

**Answer:** In active-passive, one SQL Server FCI runs on one node, and the other node is idle, waiting to take over on failover. In active-active, two separate SQL Server FCI instances are installed, each active on a different node. Each node is passive for the other's instance. The risk with active-active is that after failover, one node may host both instances, potentially causing resource contention. Proper memory caps and CPU governance must be configured to handle this scenario.

---

### Q6: How would you design a solution that protects against both node failure and storage failure?

**Answer:** Combine FCI with Availability Groups. The FCI protects against node failure (if one node goes down, the instance fails over to the other node using shared storage). The AG protects against storage failure by maintaining a separate copy of the data on a standalone replica (or another FCI) in a different location. If the entire FCI fails, including its shared storage, the AG can fail over to the secondary replica.

---

### Q7: What is a multi-subnet FCI, and how does client connectivity work?

**Answer:** A multi-subnet FCI has nodes in different subnets, typically in different datacenters. Each subnet has its own IP registered to the cluster VNN. Only the IP for the active node's subnet is online at any time. After failover to a node in a different subnet, the old IP goes offline, and the new IP comes online. Clients should use `MultiSubnetFailover=True` in their connection string so the client driver attempts connections to all registered IPs in parallel, reducing failover detection time from potentially 20+ seconds to under a second.

---

### Q8: What are the storage options for FCI, and which would you recommend for a cloud deployment?

**Answer:** Traditional options include SAN (Fibre Channel or iSCSI) and SMB 3.0 file shares. For software-defined storage, Storage Spaces Direct (S2D) uses local disks across nodes. For Azure deployments, Azure Shared Disks allow a managed disk to be attached to multiple VMs, making them ideal for FCI in the cloud. For Azure, I would recommend Azure Shared Disks (Premium SSD or Ultra Disk) for simplicity, or S2D for maximum performance and control. Third-party options like SIOS DataKeeper can replicate local storage between nodes, eliminating the need for shared storage entirely.

---

## Tips

- **Always configure a witness** — even with 2 nodes, a file share witness or cloud witness prevents quorum loss from a single node failure.
- **Test failover regularly** — do not wait for a real failure to discover problems. Schedule quarterly failover tests.
- **Monitor cluster events** — set up alerts on WSFC events (Event ID 1135 for node removal, 1177 for quorum loss).
- **Use local tempdb** — placing tempdb on local SSD is one of the biggest performance wins for FCI.
- **Size for failover** — in active-active configurations, ensure each node can handle the combined workload of both instances.
- **Document the failover process** — even though FCI failover is automatic, have runbooks for manual failover, post-failover validation, and failback.
- **Keep nodes in sync** — OS patches, drivers, SQL Server builds, and configurations must be identical across all nodes.
- **Cloud witness for modern deployments** — cloud witness is simpler than a file share witness and does not require a third server.
- **Understand FCI limitations before choosing it** — if you need readable secondaries, protection against storage failure, or database-level granularity, you need AG (possibly combined with FCI).

---

[Back to SQL Server Index](./README.md)
