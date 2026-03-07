# SQL Server on Linux & Containers

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [SQL Server on Linux Architecture](#sql-server-on-linux-architecture)
2. [Supported Linux Distributions](#supported-linux-distributions)
3. [Installation and mssql-conf Tool](#installation-and-mssql-conf-tool)
4. [SQL Server Docker Containers](#sql-server-docker-containers)
5. [Kubernetes Deployment](#kubernetes-deployment)
6. [Persistent Storage for Containers](#persistent-storage-for-containers)
7. [Availability Groups on Linux and Containers](#availability-groups-on-linux-and-containers)
8. [SQL Server Big Data Clusters](#sql-server-big-data-clusters)
9. [Limitations vs Windows](#limitations-vs-windows)
10. [Migration Considerations](#migration-considerations)
11. [Development vs Production Use Cases](#development-vs-production-use-cases)
12. [Common Interview Questions](#common-interview-questions)
13. [Tips](#tips)

---

## SQL Server on Linux Architecture

Starting with SQL Server 2017, Microsoft brought SQL Server to Linux. This was made possible by the **Platform Abstraction Layer (SQLPAL)**, which sits between the SQL Server engine and the host operating system.

### How SQLPAL Works

```
+----------------------------------------------+
|          SQL Server Engine (SQLOS)            |
|   Query Processor, Storage Engine, Buffer    |
|   Pool, Lock Manager, etc.                   |
+----------------------------------------------+
|          SQLPAL (Platform Abstraction Layer)  |
|   - Derived from Drawbridge (Library OS)     |
|   - Translates OS API calls                  |
|   - Manages memory, I/O, networking          |
+----------------------------------------------+
|          Host Operating System               |
|   Windows  |  Linux (Ubuntu, RHEL, SUSE)     |
+----------------------------------------------+
```

Key architectural points:

- **SQLPAL replaces the Windows API layer.** SQL Server was originally built entirely on Windows APIs. Rather than rewriting the engine, Microsoft built SQLPAL as a compatibility layer.
- **SQLOS remains the same.** The SQL Server Operating System (SQLOS) -- which handles scheduling, memory management, and I/O -- runs identically on both platforms.
- **Same SQL Engine binary.** The query processor, optimizer, and storage engine are the same code on Windows and Linux.
- **Feature parity goal.** The engine capabilities are virtually identical; differences are in OS-level tooling and some features that depend on Windows infrastructure.

---

## Supported Linux Distributions

SQL Server supports the following Linux distributions (as of SQL Server 2022):

| Distribution | Supported Versions | Notes |
|-------------|-------------------|-------|
| Ubuntu | 20.04, 22.04 | Most popular for development and containers |
| Red Hat Enterprise Linux (RHEL) | 8.x, 9.x | Preferred for enterprise production |
| SUSE Linux Enterprise Server (SLES) | 15 SP3+ | Common in European enterprises |

**Container base image:** The official Docker images are based on Ubuntu.

### System Requirements

- Minimum 2 GB RAM (4 GB+ recommended for production)
- XFS or EXT4 file system (XFS recommended for data files)
- At least 6 GB disk space
- x64 processor with 2 GHz or faster

---

## Installation and mssql-conf Tool

### Installation on Ubuntu (Example)

```bash
# Import the Microsoft GPG key
curl https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc

# Register the SQL Server repository
sudo add-apt-repository "$(curl https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list)"

# Install SQL Server
sudo apt-get update
sudo apt-get install -y mssql-server

# Run the setup configuration
sudo /opt/mssql/bin/mssql-conf setup

# Verify the service is running
systemctl status mssql-server

# Install command-line tools
sudo apt-get install -y mssql-tools18 unixodbc-dev

# Add tools to PATH
echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
source ~/.bashrc

# Connect
sqlcmd -S localhost -U SA -P 'YourPassword123!'
```

### The mssql-conf Tool

`mssql-conf` is the Linux equivalent of SQL Server Configuration Manager on Windows. It manages SQL Server settings via the command line.

```bash
# View current settings
sudo /opt/mssql/bin/mssql-conf list

# Set memory limit (e.g., 8 GB)
sudo /opt/mssql/bin/mssql-conf set memory.memorylimitmb 8192

# Set default data directory
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultdatadir /var/opt/mssql/data

# Set default log directory
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultlogdir /var/opt/mssql/log

# Set default backup directory
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultbackupdir /var/opt/mssql/backup

# Enable SQL Server Agent
sudo /opt/mssql/bin/mssql-conf set sqlagent.enabled true

# Set TLS certificate
sudo /opt/mssql/bin/mssql-conf set network.tlscert /etc/ssl/certs/mssql.pem
sudo /opt/mssql/bin/mssql-conf set network.tlskey /etc/ssl/private/mssql.key

# Set trace flags
sudo /opt/mssql/bin/mssql-conf traceflag 1222 on

# Apply changes (most require restart)
sudo systemctl restart mssql-server

# Reset a setting to default
sudo /opt/mssql/bin/mssql-conf unset memory.memorylimitmb
```

Configuration is stored in `/var/opt/mssql/mssql.conf`.

---

## SQL Server Docker Containers

Docker is one of the most popular ways to run SQL Server on Linux, especially for development and testing.

### Running a Basic Container

```bash
# Pull the SQL Server 2022 image
docker pull mcr.microsoft.com/mssql/server:2022-latest

# Run a container
docker run -e "ACCEPT_EULA=Y" \
           -e "MSSQL_SA_PASSWORD=YourStrong!Password123" \
           -e "MSSQL_PID=Developer" \
           -p 1433:1433 \
           --name sql2022 \
           --hostname sql2022 \
           -d mcr.microsoft.com/mssql/server:2022-latest
```

### Environment Variables

| Variable | Description | Values |
|----------|-------------|--------|
| `ACCEPT_EULA` | Required to accept the license | `Y` |
| `MSSQL_SA_PASSWORD` | SA password (must meet complexity requirements) | Strong password |
| `MSSQL_PID` | Edition/Product Key | `Developer`, `Express`, `Standard`, `Enterprise`, or a product key |
| `MSSQL_COLLATION` | Server collation | e.g., `SQL_Latin1_General_CP1_CI_AS` |
| `MSSQL_MEMORY_LIMIT_MB` | Max memory in MB | e.g., `4096` |
| `MSSQL_AGENT_ENABLED` | Enable SQL Server Agent | `true` or `false` |
| `TZ` | Timezone | e.g., `America/New_York` |
| `MSSQL_LCID` | Language ID | e.g., `1033` for US English |

### Custom Dockerfile

```dockerfile
FROM mcr.microsoft.com/mssql/server:2022-latest

# Switch to root to install packages
USER root

# Install additional tools
RUN apt-get update && apt-get install -y curl apt-transport-https

# Copy initialization scripts
COPY ./init-scripts/ /docker-entrypoint-initdb.d/
COPY ./startup.sh /opt/startup.sh
RUN chmod +x /opt/startup.sh

# Switch back to mssql user
USER mssql

# Set environment variables
ENV ACCEPT_EULA=Y
ENV MSSQL_PID=Developer

CMD ["/opt/startup.sh"]
```

### Docker Compose Example

```yaml
version: '3.8'
services:
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: sql2022-dev
    environment:
      - ACCEPT_EULA=Y
      - MSSQL_SA_PASSWORD=YourStrong!Password123
      - MSSQL_PID=Developer
      - MSSQL_AGENT_ENABLED=true
      - TZ=America/Chicago
    ports:
      - "1433:1433"
    volumes:
      - sqldata:/var/opt/mssql
    networks:
      - app-network
    healthcheck:
      test: /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$$MSSQL_SA_PASSWORD" -Q "SELECT 1" -C || exit 1
      interval: 30s
      timeout: 10s
      retries: 5

volumes:
  sqldata:
    driver: local

networks:
  app-network:
    driver: bridge
```

---

## Kubernetes Deployment

SQL Server can be deployed on Kubernetes for orchestrated, scalable environments.

### Basic Deployment Manifest

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mssql-secret
type: Opaque
data:
  SA_PASSWORD: WW91clN0cm9uZyFQYXNzd29yZDEyMw==  # base64 encoded

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mssql-data-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: managed-premium  # Azure example

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mssql-deployment
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mssql
  strategy:
    type: Recreate  # Important: SQL Server cannot share data files
  template:
    metadata:
      labels:
        app: mssql
    spec:
      terminationGracePeriodSeconds: 30
      containers:
        - name: mssql
          image: mcr.microsoft.com/mssql/server:2022-latest
          ports:
            - containerPort: 1433
          env:
            - name: ACCEPT_EULA
              value: "Y"
            - name: MSSQL_PID
              value: "Developer"
            - name: SA_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mssql-secret
                  key: SA_PASSWORD
          resources:
            requests:
              memory: "4Gi"
              cpu: "2"
            limits:
              memory: "8Gi"
              cpu: "4"
          volumeMounts:
            - name: mssql-data
              mountPath: /var/opt/mssql
      volumes:
        - name: mssql-data
          persistentVolumeClaim:
            claimName: mssql-data-pvc

---
apiVersion: v1
kind: Service
metadata:
  name: mssql-service
spec:
  selector:
    app: mssql
  ports:
    - port: 1433
      targetPort: 1433
  type: LoadBalancer  # or ClusterIP for internal-only access
```

### Key Kubernetes Considerations

| Concern | Guidance |
|---------|----------|
| Strategy | Use `Recreate` (not `RollingUpdate`) -- SQL Server cannot have two instances accessing the same data files |
| Storage | Always use persistent volumes; container local storage is ephemeral |
| StatefulSet vs Deployment | Use StatefulSet for stable network identities and ordered operations, especially with AGs |
| Resource limits | Set both requests and limits; SQL Server will use all available memory by default |
| Health checks | Use `sqlcmd` to verify SQL Server is responsive, not just that the port is open |
| Secrets | Never put passwords in plain text in manifests; use Kubernetes Secrets or external secret managers |

---

## Persistent Storage for Containers

Data persistence is the most critical concern when running SQL Server in containers.

### Docker Volumes

```bash
# Named volume (Docker manages the storage location)
docker run -v sqldata:/var/opt/mssql ...

# Bind mount (you control the host directory)
docker run -v /host/path/sqldata:/var/opt/mssql ...
```

### Storage Best Practices

| Practice | Reason |
|----------|--------|
| Always use volumes or bind mounts | Container file system is ephemeral; data is lost when the container is removed |
| Separate data, log, and tempdb volumes | Allows different performance tiers (SSD for logs, etc.) |
| Use XFS file system on Linux hosts | Better performance for SQL Server I/O patterns |
| Set proper file permissions | The `mssql` user (UID 10001) must own the mounted directories |
| Back up regularly | Container orchestration does not replace backup strategy |

### Separating Data and Log Directories

```bash
docker run -e "ACCEPT_EULA=Y" \
           -e "MSSQL_SA_PASSWORD=YourStrong!Password123" \
           -e "MSSQL_DATA_DIR=/var/opt/mssql/data" \
           -e "MSSQL_LOG_DIR=/var/opt/mssql/log" \
           -e "MSSQL_BACKUP_DIR=/var/opt/mssql/backup" \
           -v sqldata:/var/opt/mssql/data \
           -v sqllog:/var/opt/mssql/log \
           -v sqlbackup:/var/opt/mssql/backup \
           -p 1433:1433 \
           -d mcr.microsoft.com/mssql/server:2022-latest
```

---

## Availability Groups on Linux and Containers

SQL Server supports Always On Availability Groups on Linux without requiring Windows Server Failover Clustering (WSFC). Instead, it uses **Pacemaker** as the cluster manager on Linux.

### AG on Linux Architecture

```
+------------------+     +------------------+     +------------------+
|  Node 1 (Primary)|     |  Node 2 (Secondary)|   |  Node 3 (Secondary)|
|  SQL Server      |<--->|  SQL Server        |<->|  SQL Server        |
|  Pacemaker Agent |     |  Pacemaker Agent   |   |  Pacemaker Agent   |
+------------------+     +------------------+     +------------------+
         |                        |                        |
         +------------ Pacemaker Cluster ------------------+
```

### Key Differences from Windows AGs

| Aspect | Windows | Linux |
|--------|---------|-------|
| Cluster manager | WSFC | Pacemaker |
| Cluster type | WSFC | EXTERNAL (Pacemaker) or NONE |
| DTC support | Yes | No (as of SQL Server 2022) |
| Listener | WSFC VNN | Pacemaker virtual IP resource |
| Configuration tools | SSMS, Failover Cluster Manager | T-SQL, Pacemaker CLI (pcs) |

### AG on Kubernetes

On Kubernetes, AGs can be configured using the `CLUSTER_TYPE = NONE` option (read-scale) or with an operator that manages failover.

```sql
-- Creating an AG on Linux
CREATE AVAILABILITY GROUP [AG1]
WITH (CLUSTER_TYPE = EXTERNAL)  -- Managed by Pacemaker
FOR DATABASE [SalesDB]
REPLICA ON
    N'Node1' WITH (
        ENDPOINT_URL = N'TCP://node1:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = EXTERNAL),  -- Pacemaker handles failover
    N'Node2' WITH (
        ENDPOINT_URL = N'TCP://node2:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = EXTERNAL),
    N'Node3' WITH (
        ENDPOINT_URL = N'TCP://node3:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL);
```

---

## SQL Server Big Data Clusters

**Note:** SQL Server Big Data Clusters were deprecated in SQL Server 2022 CU13 and removed from future development. This section covers them for historical context, as they may appear in interview questions.

### What They Were

Big Data Clusters (BDC) combined SQL Server, Apache Spark, and HDFS into a single integrated platform deployed on Kubernetes.

### Architecture Components

| Component | Purpose |
|-----------|---------|
| Master instance | SQL Server instance acting as the control point |
| Compute pool | SQL Server instances for scale-out computation |
| Data pool | SQL Server instances for caching and distributing data |
| Storage pool | HDFS + Spark for big data analytics |
| Controller | Management service for the cluster |

### Why They Were Deprecated

- Complexity of deployment and management was significant
- Kubernetes expertise requirements were high
- Microsoft shifted strategy toward Azure Synapse, Fabric, and other cloud-native analytics
- The market moved toward decoupled, purpose-built services rather than monolithic clusters

### What Replaced BDC Features

| BDC Feature | Modern Alternative |
|------------|-------------------|
| Data virtualization (PolyBase) | PolyBase remains available standalone in SQL Server |
| Spark integration | Azure Synapse, Azure Databricks, Fabric |
| HDFS storage | Azure Data Lake Storage, S3-compatible storage with PolyBase |
| Scale-out compute | Azure SQL Managed Instance, Synapse |

---

## Limitations vs Windows

While SQL Server on Linux has near-complete feature parity with Windows, some differences remain.

### Features Not Available on Linux

| Feature | Status |
|---------|--------|
| SQL Server Reporting Services (SSRS) | Not available on Linux |
| SQL Server Analysis Services (SSAS) | Not available on Linux |
| SQL Server Integration Services (SSIS) | Not available on Linux |
| Distributed Transaction Coordinator (DTC) | Not supported |
| Machine Learning Services (R/Python) | Supported starting SQL Server 2019 |
| Replication (as Subscriber) | Not supported; Publisher/Distributor only |
| Stretch Database | Not available (also deprecated on Windows) |
| PolyBase scale-out groups | Not available on Linux |
| FileTable | Not available |
| Change Data Capture (CDC) | Supported starting SQL Server 2017 CU3 |
| AD Authentication | Supported (requires domain join or adutil) |
| Buffer Pool Extension | Not available |

### Operational Differences

| Area | Windows | Linux |
|------|---------|-------|
| Configuration | SQL Server Configuration Manager, Registry | `mssql-conf`, config files |
| Service management | Windows Services (SCM) | systemd (`systemctl`) |
| Scheduled jobs | SQL Server Agent (full) | SQL Server Agent (supported but cron is an alternative) |
| File paths | `C:\Program Files\Microsoft SQL Server\...` | `/opt/mssql/`, `/var/opt/mssql/` |
| Authentication | Windows Auth native, AD, SQL Auth | SQL Auth, AD Auth (with configuration) |
| Performance Monitor | PerfMon counters | DMVs, `sys.dm_os_performance_counters` |
| Backup to URL | Azure Blob Storage | Azure Blob Storage (same) |

---

## Migration Considerations

### Migrating from Windows to Linux

**What transfers seamlessly:**
- Database backup and restore (full compatibility)
- Database detach/attach
- Log shipping
- Availability Groups (cross-platform AG for migration)
- All T-SQL code, stored procedures, functions, views

**What needs attention:**

| Concern | Details |
|---------|---------|
| File paths | Update any hardcoded Windows paths in jobs, scripts, maintenance plans |
| Windows Authentication | Configure AD authentication using `adutil` or realm join |
| Linked servers | Reconfigure; ODBC drivers may differ |
| SQL Server Agent jobs | Review and test; CmdExec steps may reference Windows-specific commands |
| SSIS packages | Must run from a separate Windows server or migrate to Azure Data Factory |
| Extended stored procedures | Not supported on Linux (xp_cmdshell works but use `bash` syntax) |
| Collation | Linux is case-sensitive by default at the OS level; SQL Server collation is independent but ensure consistency |
| File system | Use XFS for best performance; avoid NFS for data files |

### Cross-Platform AG Migration Strategy

```
1. Set up Linux SQL Server instance
2. Create AG between Windows (primary) and Linux (secondary)
3. Wait for synchronization
4. Planned failover to Linux secondary
5. Linux becomes the new primary
6. Remove old Windows replica
```

---

## Development vs Production Use Cases

### Development and Testing

Containers excel for development scenarios:

```bash
# Spin up a test instance in seconds
docker run -e "ACCEPT_EULA=Y" \
           -e "MSSQL_SA_PASSWORD=Dev!Password123" \
           -e "MSSQL_PID=Developer" \
           -p 1433:1433 \
           --name sql-dev \
           -d mcr.microsoft.com/mssql/server:2022-latest

# Run multiple versions side by side
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=Dev!Password123" \
           -p 1433:1433 --name sql2022 \
           -d mcr.microsoft.com/mssql/server:2022-latest

docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=Dev!Password123" \
           -p 1434:1433 --name sql2019 \
           -d mcr.microsoft.com/mssql/server:2019-latest

# Restore a production backup for testing
docker cp /backups/proddb.bak sql-dev:/var/opt/mssql/backup/
docker exec sql-dev /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA \
    -P "Dev!Password123" -C \
    -Q "RESTORE DATABASE ProdDB FROM DISK='/var/opt/mssql/backup/proddb.bak' WITH MOVE 'ProdDB' TO '/var/opt/mssql/data/ProdDB.mdf', MOVE 'ProdDB_log' TO '/var/opt/mssql/log/ProdDB_log.ldf'"

# Tear it all down when done
docker rm -f sql-dev sql2022 sql2019
```

**Benefits for development:**
- Instant provisioning (no install wizard)
- Disposable environments
- Consistent configuration across team members
- CI/CD integration (spin up DB for integration tests, tear down after)
- No impact on host system

### Production Considerations

Running SQL Server containers in production is supported but requires careful planning:

| Area | Requirement |
|------|------------|
| Storage | Persistent volumes with appropriate IOPS; never use container-local storage |
| High availability | AGs with Pacemaker (Linux VMs) or Kubernetes operators |
| Monitoring | Integrate with Prometheus/Grafana, or use traditional SQL monitoring tools |
| Backup | Regular automated backups to external storage (Azure Blob, NFS, etc.) |
| Resource management | Set CPU/memory limits to prevent noisy-neighbor issues |
| Patching | Build updated images with CU patches; roll out via image tag updates |
| Security | Run as non-root, use secrets management, encrypt connections with TLS |
| Licensing | Enterprise or Standard license required; Developer edition is not for production |

### When to Use Linux vs Windows in Production

| Choose Linux When | Choose Windows When |
|-------------------|---------------------|
| Standardizing on Linux infrastructure | You need SSRS, SSAS, or SSIS on the same host |
| Running on Kubernetes/containers | Existing Windows ecosystem and tooling |
| Cost savings (no Windows Server license) | DTC/distributed transactions required |
| Team has Linux expertise | Team primarily has Windows expertise |
| Cloud-native/microservices architecture | Legacy applications with Windows dependencies |

---

## Common Interview Questions

### Q1: How does SQL Server run on Linux if it was built for Windows?

**A:** Microsoft created the Platform Abstraction Layer (SQLPAL), derived from the Drawbridge research project. SQLPAL acts as a compatibility layer that translates Windows API calls to Linux system calls. The SQL Server engine itself (SQLOS, query processor, storage engine) is the same binary on both platforms. This means features, query behavior, and performance characteristics are nearly identical.

### Q2: What is the difference between `mssql-conf` and SQL Server Configuration Manager?

**A:** `mssql-conf` is the Linux command-line tool for configuring SQL Server settings that would be managed by SQL Server Configuration Manager on Windows. It handles memory limits, file paths, network settings, trace flags, TLS configuration, and enabling features like SQL Server Agent. Settings are stored in `/var/opt/mssql/mssql.conf` and most changes require a service restart.

### Q3: How do you ensure data persistence with SQL Server containers?

**A:** Use Docker volumes or bind mounts to map the `/var/opt/mssql` directory (or specific subdirectories for data, log, and backup) to persistent storage outside the container. In Kubernetes, use PersistentVolumeClaims backed by appropriate storage classes. Never rely on the container's writable layer for database files -- it is ephemeral and will be lost when the container is removed.

### Q4: What are the limitations of SQL Server on Linux compared to Windows?

**A:** The main limitations are: SSRS, SSAS, and SSIS are not available on Linux; DTC (distributed transactions) is not supported; FileTable is not available; Buffer Pool Extension is not available; and replication as a subscriber is not supported. Active Directory authentication requires additional configuration. The core database engine features (T-SQL, AGs, In-Memory OLTP, columnstore, etc.) have full parity.

### Q5: How do Availability Groups work on Linux without WSFC?

**A:** On Linux, Pacemaker replaces WSFC as the cluster resource manager. SQL Server communicates with Pacemaker through a resource agent. The AG is created with `CLUSTER_TYPE = EXTERNAL` and `FAILOVER_MODE = EXTERNAL`, delegating failover decisions to Pacemaker. The listener is implemented as a Pacemaker virtual IP resource rather than a WSFC Virtual Network Name.

### Q6: Should you run SQL Server containers in production?

**A:** Yes, it is supported, but it requires the same rigor as any production SQL Server deployment -- persistent storage with appropriate IOPS, high availability (AGs or Kubernetes operators), proper backup strategy, monitoring, security hardening (TLS, secrets management, non-root execution), and resource governance. Containers do not eliminate operational complexity; they shift it to infrastructure-as-code and orchestration tooling. Production containers must use a properly licensed edition (Standard or Enterprise).

### Q7: How would you migrate a SQL Server database from Windows to Linux?

**A:** The simplest method is backup and restore -- take a full backup on Windows and restore it on Linux, updating file paths with the MOVE option. For minimal downtime, set up a cross-platform Availability Group between the Windows primary and Linux secondary, synchronize, and perform a planned failover. After migration, review all hardcoded file paths, SQL Agent jobs (replace Windows commands with Linux equivalents), and test AD authentication if used.

### Q8: What is SQL Server Big Data Clusters and what happened to it?

**A:** Big Data Clusters (BDC) was introduced in SQL Server 2019 as a Kubernetes-deployed platform combining SQL Server, Apache Spark, and HDFS. It was deprecated because of deployment complexity and Microsoft's strategic shift toward cloud-native analytics services (Azure Synapse, Fabric). The data virtualization feature (PolyBase) that was part of BDC continues to be available as a standalone feature in SQL Server. Interviewers may ask about BDC to test your awareness of the evolving SQL Server ecosystem.

---

## Tips

- **Use containers for development and CI/CD** even if your production environment runs on VMs. The speed of provisioning and teardown is invaluable for testing.
- **Always mount persistent volumes** when running SQL Server in containers. Even for development, losing a database you spent hours configuring is frustrating.
- **Use `Developer` edition** for non-production containers -- it has all Enterprise features at no cost.
- **Set memory limits explicitly.** SQL Server will consume all available memory by default, which can starve other containers or processes on the same host.
- **Use XFS file system** on Linux for data files. It provides better performance for SQL Server I/O patterns than EXT4.
- **Health checks matter.** In Docker Compose and Kubernetes, implement health checks using `sqlcmd` rather than just checking if port 1433 is open -- the port may be open before SQL Server is ready to accept queries.
- **Understand the SQLPAL architecture** for interviews. Being able to explain how SQL Server runs on Linux (without a full rewrite) demonstrates deep product knowledge.
- **Practice deploying AGs on Linux.** The Pacemaker-based setup is different enough from WSFC that hands-on experience is valuable.
- **Keep container images updated.** Apply Cumulative Updates by pulling newer image tags rather than patching running containers.
- **For production Kubernetes deployments**, consider using a SQL Server operator (such as the DH2i DxOperator or community operators) to manage lifecycle operations, failover, and scaling.
