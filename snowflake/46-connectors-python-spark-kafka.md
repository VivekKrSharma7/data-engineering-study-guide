# Snowflake Connectors: Python, Spark, Kafka

[Back to Snowflake Index](./README.md)

---

## Overview

Snowflake provides a rich ecosystem of connectors and drivers that enable applications, data pipelines, and analytics tools to interact with the platform. Understanding these connectors is critical for data engineers who must build robust, performant integrations between Snowflake and the broader data stack.

---

## 1. Snowflake Python Connector

The Snowflake Connector for Python is the most widely used programmatic interface for interacting with Snowflake from Python applications and scripts.

### Installation

```bash
# Basic installation
pip install snowflake-connector-python

# With pandas support (includes write_pandas, fetch_pandas_all, etc.)
pip install "snowflake-connector-python[pandas]"

# With secure local storage for credentials
pip install "snowflake-connector-python[secure-local-storage]"
```

### Establishing a Connection

```python
import snowflake.connector

conn = snowflake.connector.connect(
    user='my_user',
    password='my_password',
    account='xy12345.us-east-1',       # account identifier
    warehouse='COMPUTE_WH',
    database='ANALYTICS_DB',
    schema='PUBLIC',
    role='DATA_ENGINEER'
)
```

**Key parameters:**

| Parameter | Description |
|-----------|-------------|
| `account` | Account identifier (e.g., `xy12345.us-east-1`) |
| `user` / `password` | Credentials (or use key-pair, OAuth, SSO) |
| `warehouse` | Virtual warehouse to use for queries |
| `database` / `schema` | Default context |
| `role` | Active role for the session |
| `login_timeout` | Seconds to wait for login |
| `network_timeout` | Seconds to wait for network operations |
| `authenticator` | `snowflake` (default), `externalbrowser`, `oauth`, `https://<okta_url>` |

### Authentication Methods

```python
# Key-pair authentication
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend

with open("/path/to/rsa_key.p8", "rb") as key_file:
    p_key = serialization.load_pem_private_key(
        key_file.read(),
        password=b'my_passphrase',
        backend=default_backend()
    )

pkb = p_key.private_bytes(
    encoding=serialization.Encoding.DER,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption()
)

conn = snowflake.connector.connect(
    user='my_user',
    account='xy12345.us-east-1',
    private_key=pkb
)

# OAuth authentication
conn = snowflake.connector.connect(
    user='my_user',
    account='xy12345.us-east-1',
    authenticator='oauth',
    token='my_oauth_token'
)

# Browser-based SSO
conn = snowflake.connector.connect(
    user='my_user',
    account='xy12345.us-east-1',
    authenticator='externalbrowser'
)
```

### Cursor and Fetching Data

```python
# Basic query execution
cur = conn.cursor()
try:
    cur.execute("SELECT * FROM customers WHERE region = 'EMEA' LIMIT 100")

    # Fetch one row
    row = cur.fetchone()

    # Fetch all rows
    rows = cur.fetchall()

    # Iterate over results
    for row in cur:
        print(row[0], row[1])
finally:
    cur.close()

# Using DictCursor for named access
from snowflake.connector import DictCursor

cur = conn.cursor(DictCursor)
cur.execute("SELECT customer_id, customer_name FROM customers LIMIT 10")
for row in cur:
    print(row['CUSTOMER_ID'], row['CUSTOMER_NAME'])
```

### Parameterized Queries

```python
# Positional binding (qmark style) -- Snowflake default
cur.execute(
    "SELECT * FROM orders WHERE order_date > %s AND status = %s",
    ('2025-01-01', 'SHIPPED')
)

# Named binding
cur.execute(
    "SELECT * FROM orders WHERE order_date > %(start_date)s AND status = %(status)s",
    {'start_date': '2025-01-01', 'status': 'SHIPPED'}
)

# Server-side binding with :N syntax (prevents SQL injection)
cur.execute(
    "INSERT INTO events (event_name, event_time) VALUES (:1, :2)",
    ('page_view', '2025-06-15 10:30:00')
)
```

### Pandas Integration: write_pandas and fetch_pandas_all

```python
import pandas as pd
from snowflake.connector.pandas_tools import write_pandas, pd_writer

# Fetch results directly into a pandas DataFrame
cur.execute("SELECT * FROM sales_data WHERE year = 2025")
df = cur.fetch_pandas_all()

# Fetch in batches (useful for large result sets)
for batch_df in cur.fetch_pandas_batches():
    process(batch_df)

# Write a DataFrame to Snowflake
df = pd.DataFrame({
    'NAME': ['Alice', 'Bob', 'Charlie'],
    'AGE': [30, 25, 35],
    'CITY': ['NYC', 'LA', 'CHI']
})

success, nchunks, nrows, _ = write_pandas(
    conn=conn,
    df=df,
    table_name='USERS',
    database='ANALYTICS_DB',
    schema='PUBLIC',
    auto_create_table=True,    # auto-create if not exists
    overwrite=False,           # append by default
    quote_identifiers=False
)
print(f"Loaded {nrows} rows in {nchunks} chunks")

# Using pd_writer with pandas to_sql (SQLAlchemy engine)
from sqlalchemy import create_engine
from snowflake.sqlalchemy import URL

engine = create_engine(URL(
    account='xy12345.us-east-1',
    user='my_user',
    password='my_password',
    database='ANALYTICS_DB',
    schema='PUBLIC',
    warehouse='COMPUTE_WH'
))

df.to_sql(
    'users',
    con=engine,
    index=False,
    method=pd_writer,
    if_exists='append'
)
```

### Async Queries and Multi-Statement Execution

```python
# Async (non-blocking) query
cur.execute_async("SELECT * FROM very_large_table")
query_id = cur.sfqid

# Check status later
from snowflake.connector import ProgrammingError
import time

while conn.is_still_running(conn.get_query_status(query_id)):
    time.sleep(5)

cur.get_results_from_sfqid(query_id)
rows = cur.fetchall()

# Multi-statement execution
cur.execute("""
    BEGIN;
    INSERT INTO target SELECT * FROM staging;
    DELETE FROM staging;
    COMMIT;
""", num_statements=4)
```

---

## 2. Snowflake Spark Connector

The Snowflake Connector for Spark allows Apache Spark to read from and write to Snowflake efficiently, leveraging Snowflake's internal optimizations.

### Setup

```bash
# Add to Spark session (Maven coordinates)
spark-submit --packages net.snowflake:spark-snowflake_2.12:2.16.0-spark_3.4,net.snowflake:snowflake-jdbc:3.16.1 my_job.py
```

### Connection Options

```python
sfOptions = {
    "sfURL": "xy12345.us-east-1.snowflakecomputing.com",
    "sfUser": "my_user",
    "sfPassword": "my_password",
    "sfDatabase": "ANALYTICS_DB",
    "sfSchema": "PUBLIC",
    "sfWarehouse": "SPARK_WH",
    "sfRole": "DATA_ENGINEER",
    "sfTimezone": "UTC"
}
```

### Reading Data into a Spark DataFrame

```python
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("SnowflakeIntegration") \
    .getOrCreate()

# Read an entire table
df = spark.read \
    .format("snowflake") \
    .options(**sfOptions) \
    .option("dbtable", "SALES_FACT") \
    .load()

# Read using a custom query
df = spark.read \
    .format("snowflake") \
    .options(**sfOptions) \
    .option("query", """
        SELECT product_id, SUM(revenue) AS total_revenue
        FROM sales_fact
        WHERE sale_date >= '2025-01-01'
        GROUP BY product_id
    """) \
    .load()

df.show()
```

### Writing a Spark DataFrame to Snowflake

```python
result_df.write \
    .format("snowflake") \
    .options(**sfOptions) \
    .option("dbtable", "AGG_SALES") \
    .mode("overwrite") \
    .save()

# Append mode
result_df.write \
    .format("snowflake") \
    .options(**sfOptions) \
    .option("dbtable", "AGG_SALES") \
    .mode("append") \
    .save()
```

### Query Pushdown

Snowflake's Spark Connector supports **automatic query pushdown**: Spark operations like `filter`, `select`, `groupBy`, and `agg` are translated into SQL and executed inside Snowflake rather than pulling all data to Spark.

```python
# This filter is pushed down to Snowflake -- only matching rows are transferred
df_filtered = df.filter(df.region == "US").select("customer_id", "revenue")
df_filtered.show()

# Enable/disable pushdown explicitly
spark.conf.set("spark.snowflake.pushdown.enabled", "true")
```

**What gets pushed down:**
- Projections (column selection)
- Filters (WHERE)
- Aggregations (GROUP BY, COUNT, SUM, etc.)
- Joins (in some cases)
- Sorting (ORDER BY)
- LIMIT

### Important Spark Connector Options

| Option | Description |
|--------|-------------|
| `dbtable` | Table name to read/write |
| `query` | Custom SQL query for reading |
| `truncate_table` | Truncate before overwrite (`on`/`off`) |
| `usestagingtable` | Use staging table for safe overwrites |
| `column_mapping` | `name` (by column name) or `order` |
| `autopushdown` | Enable/disable pushdown (`on`/`off`) |
| `keep_column_case` | Preserve column case (`on`/`off`) |

---

## 3. Snowflake Kafka Connector

The Snowflake Connector for Kafka enables streaming data from Apache Kafka topics directly into Snowflake tables. It is a **Kafka Connect sink connector**.

### Architecture

```
Kafka Topic --> Kafka Connect (Snowflake Sink Connector) --> Internal Stage --> Snowpipe --> Snowflake Table
```

The connector:
1. Reads messages from Kafka topics
2. Buffers them into files (Parquet/JSON)
3. Uploads files to a Snowflake internal stage
4. Triggers **Snowpipe** to ingest the staged files into target tables

### Configuration

```json
{
  "name": "snowflake-kafka-sink",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
    "tasks.max": "8",
    "topics": "orders,events,clickstream",
    "snowflake.url.name": "xy12345.us-east-1.snowflakecomputing.com",
    "snowflake.user.name": "kafka_user",
    "snowflake.private.key": "${file:/secrets/snowflake_key.txt:private_key}",
    "snowflake.database.name": "RAW_DB",
    "snowflake.schema.name": "KAFKA_LANDING",
    "snowflake.role.name": "KAFKA_ROLE",
    "buffer.count.records": "10000",
    "buffer.flush.time": "120",
    "buffer.size.bytes": "5000000",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "com.snowflake.kafka.connector.records.SnowflakeJsonConverter",
    "snowflake.ingestion.method": "SNOWPIPE"
  }
}
```

### Ingestion Methods

| Method | Description |
|--------|-------------|
| `SNOWPIPE` | Uses Snowpipe (file-based, micro-batch). Creates internal stage and pipe. |
| `SNOWPIPE_STREAMING` | Uses Snowpipe Streaming API for lower latency (sub-second). No staging files. |

```json
{
  "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
  "snowflake.streaming.enable.single.buffer": "true"
}
```

### Schema Evolution and Table Structure

By default, the Kafka connector creates tables with two VARIANT columns:

| Column | Description |
|--------|-------------|
| `RECORD_METADATA` | Kafka metadata (topic, partition, offset, timestamp) |
| `RECORD_CONTENT` | The actual message payload as VARIANT |

**Schema evolution** -- when using Snowpipe Streaming with Schematization:

```json
{
  "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
  "snowflake.enable.schematization": "true"
}
```

When enabled, new columns in incoming data are automatically added to the target table. The table must have `ENABLE_SCHEMA_EVOLUTION = TRUE`.

```sql
ALTER TABLE raw_db.kafka_landing.orders SET ENABLE_SCHEMA_EVOLUTION = TRUE;
```

### Topic-to-Table Mapping

```json
{
  "topics": "orders,events",
  "snowflake.topic2table.map": "orders:RAW_ORDERS,events:RAW_EVENTS"
}
```

---

## 4. JDBC and ODBC Drivers

### JDBC

```java
// JDBC connection string
String url = "jdbc:snowflake://xy12345.us-east-1.snowflakecomputing.com";

Properties props = new Properties();
props.put("user", "my_user");
props.put("password", "my_password");
props.put("db", "ANALYTICS_DB");
props.put("schema", "PUBLIC");
props.put("warehouse", "COMPUTE_WH");

Connection conn = DriverManager.getConnection(url, props);
Statement stmt = conn.createStatement();
ResultSet rs = stmt.executeQuery("SELECT COUNT(*) FROM customers");
```

### ODBC

ODBC is used by tools like Tableau, Excel, and Power BI. Configuration involves:
1. Installing the Snowflake ODBC driver
2. Configuring a DSN (Data Source Name) in the ODBC Data Source Administrator (Windows) or `odbc.ini` (Linux/macOS)

```ini
# odbc.ini (Linux example)
[SnowflakeDSN]
Driver      = /opt/snowflake/snowflakeodbc/lib/libSnowflake.so
Server      = xy12345.us-east-1.snowflakecomputing.com
Database    = ANALYTICS_DB
Schema      = PUBLIC
Warehouse   = COMPUTE_WH
Role        = DATA_ENGINEER
```

---

## 5. Other Connectors

### Node.js Connector

```javascript
const snowflake = require('snowflake-sdk');

const connection = snowflake.createConnection({
    account: 'xy12345.us-east-1',
    username: 'my_user',
    password: 'my_password',
    warehouse: 'COMPUTE_WH',
    database: 'ANALYTICS_DB',
    schema: 'PUBLIC'
});

connection.connect((err, conn) => {
    if (err) {
        console.error('Connection failed:', err.message);
        return;
    }
    conn.execute({
        sqlText: 'SELECT * FROM customers LIMIT 10',
        complete: (err, stmt, rows) => {
            if (err) throw err;
            console.log(rows);
        }
    });
});
```

### Go Connector (gosnowflake)

```go
import (
    "database/sql"
    _ "github.com/snowflakedb/gosnowflake"
)

dsn := "my_user:my_password@xy12345.us-east-1/ANALYTICS_DB/PUBLIC?warehouse=COMPUTE_WH"
db, err := sql.Open("snowflake", dsn)
rows, err := db.Query("SELECT customer_id, name FROM customers LIMIT 10")
```

### .NET Connector

```csharp
using Snowflake.Data.Client;

using (var conn = new SnowflakeDbConnection())
{
    conn.ConnectionString =
        "account=xy12345.us-east-1;user=my_user;password=my_password;" +
        "db=ANALYTICS_DB;schema=PUBLIC;warehouse=COMPUTE_WH";
    conn.Open();

    var cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT * FROM customers LIMIT 10";
    var reader = cmd.ExecuteReader();
    while (reader.Read())
    {
        Console.WriteLine(reader.GetString(0));
    }
}
```

---

## 6. Connector Best Practices

### Connection Pooling

Connection pooling reduces overhead by reusing established connections rather than creating new ones for each request.

**Python -- using a connection pool pattern:**

```python
from queue import Queue
import snowflake.connector

class SnowflakeConnectionPool:
    def __init__(self, pool_size=5, **conn_params):
        self.pool = Queue(maxsize=pool_size)
        self.conn_params = conn_params
        for _ in range(pool_size):
            self.pool.put(snowflake.connector.connect(**conn_params))

    def get_connection(self):
        return self.pool.get()

    def return_connection(self, conn):
        self.pool.put(conn)

    def close_all(self):
        while not self.pool.empty():
            conn = self.pool.get()
            conn.close()

# Usage
pool = SnowflakeConnectionPool(
    pool_size=5,
    user='my_user',
    password='my_password',
    account='xy12345.us-east-1',
    warehouse='COMPUTE_WH',
    database='ANALYTICS_DB',
    schema='PUBLIC'
)

conn = pool.get_connection()
try:
    cur = conn.cursor()
    cur.execute("SELECT CURRENT_TIMESTAMP()")
    print(cur.fetchone())
finally:
    pool.return_connection(conn)
```

**SQLAlchemy connection pooling (built-in):**

```python
from sqlalchemy import create_engine
from snowflake.sqlalchemy import URL

engine = create_engine(
    URL(account='xy12345.us-east-1', user='my_user', password='my_password',
        database='ANALYTICS_DB', schema='PUBLIC', warehouse='COMPUTE_WH'),
    pool_size=10,
    max_overflow=5,
    pool_timeout=30,
    pool_recycle=1800  # recycle connections every 30 minutes
)
```

### General Best Practices

| Practice | Details |
|----------|---------|
| **Use key-pair auth for automation** | Avoid embedding passwords in scripts; use RSA key-pair or OAuth tokens |
| **Set session parameters explicitly** | Always set `warehouse`, `database`, `schema`, `role` to avoid ambiguity |
| **Use parameterized queries** | Prevents SQL injection and enables query plan reuse |
| **Close connections and cursors** | Use `try/finally` or context managers to avoid resource leaks |
| **Use `write_pandas` for bulk loads** | It uses PUT + COPY internally and is far faster than row-by-row INSERT |
| **Enable query pushdown in Spark** | Let Snowflake handle filtering/aggregation to minimize data transfer |
| **Right-size Kafka buffer settings** | Balance latency vs. cost -- small buffers = more Snowpipe calls = higher cost |
| **Monitor connector versions** | Keep connectors updated for security patches and performance improvements |
| **Handle retries and timeouts** | Implement exponential backoff for transient network errors |
| **Use `fetch_pandas_batches`** | For large result sets, batch fetching avoids out-of-memory errors |

---

## Common Interview Questions

### Q1: What is the difference between `fetchall()` and `fetch_pandas_all()` in the Python Connector?

**Answer:** `fetchall()` returns a list of tuples -- standard Python objects. `fetch_pandas_all()` returns a pandas DataFrame, leveraging Apache Arrow for efficient columnar data transfer. The pandas variant is significantly faster for large result sets (often 5-10x) because Arrow avoids row-by-row Python object construction. However, it requires the `[pandas]` extra to be installed.

### Q2: How does query pushdown work in the Snowflake Spark Connector?

**Answer:** When pushdown is enabled (default), the connector translates Spark DataFrame operations (filter, select, groupBy, agg, join, etc.) into equivalent SQL and sends them to Snowflake for execution. Only the resulting data is transferred back to Spark. This dramatically reduces data movement and leverages Snowflake's query engine. Without pushdown, Spark would pull all raw data and process it locally. You can verify pushdown by checking the Spark execution plan or Snowflake query history.

### Q3: Explain the two ingestion methods in the Snowflake Kafka Connector.

**Answer:**
- **SNOWPIPE (file-based):** The connector buffers Kafka messages into files, uploads them to a Snowflake internal stage, and triggers Snowpipe to COPY the data. Latency is typically 1-2 minutes. This method is cost-effective for moderate throughput.
- **SNOWPIPE_STREAMING:** Uses the Snowpipe Streaming API to insert rows directly into Snowflake without staging files. Latency is sub-second. This is ideal for real-time use cases but consumes more compute resources.

### Q4: How would you securely manage Snowflake credentials in a production Python application?

**Answer:** In production, avoid hardcoding credentials. Preferred approaches:
1. **Key-pair authentication** with the private key stored in a secrets manager (AWS Secrets Manager, Azure Key Vault, HashiCorp Vault)
2. **OAuth tokens** from an identity provider
3. **Environment variables** (minimum viable approach for CI/CD)
4. **External credential stores** integrated with the connector (e.g., `externalbrowser` for interactive, `oauth` for service accounts)

### Q5: What happens when the Kafka connector encounters a schema change in the incoming data?

**Answer:** By default (without schematization), the connector stores the entire payload as a VARIANT column (`RECORD_CONTENT`), so schema changes are handled transparently -- the JSON/Avro structure simply changes within the VARIANT. With `snowflake.enable.schematization=true` and `ENABLE_SCHEMA_EVOLUTION=TRUE` on the target table, the connector will automatically add new columns to the table when new fields appear in the data. Removed fields result in NULL values for those columns. Type changes may cause ingestion errors and need careful handling.

### Q6: When would you use the Spark Connector vs. the Python Connector?

**Answer:** Use the **Spark Connector** when you are already in a Spark ecosystem (Databricks, EMR, Dataproc) and need distributed processing, complex transformations, or integration with other Spark data sources. Use the **Python Connector** for lightweight scripts, orchestration tasks, Airflow DAGs, API backends, or when pandas-based processing is sufficient. The Python Connector has lower overhead and simpler setup; the Spark Connector excels at large-scale parallel reads/writes with pushdown optimization.

---

## Tips

- When troubleshooting connector issues, enable logging: `logging.getLogger('snowflake.connector').setLevel(logging.DEBUG)`.
- The `write_pandas` function uses PUT + COPY internally -- it compresses data, stages it, and runs COPY INTO. This is the fastest way to load a DataFrame.
- For the Spark Connector, always check the compatibility matrix between your Spark version, Scala version, and the connector version.
- The Kafka Connector requires a dedicated Snowflake user with specific privileges: USAGE on the warehouse, CREATE STAGE and CREATE PIPE on the schema, and INSERT on target tables.
- Use `connection.close()` explicitly in serverless environments (Lambda, Cloud Functions) to avoid connection leaks.
- For very large exports from Snowflake to Spark, consider using COPY INTO a stage (Parquet) and reading the staged files from Spark directly -- this can be faster than the connector for massive datasets.
