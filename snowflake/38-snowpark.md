# Snowpark (Python, Java, Scala)

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### What is Snowpark?

Snowpark is Snowflake's **developer framework** that allows you to write data processing logic in **Python, Java, or Scala** using a DataFrame API. The critical feature is **pushdown processing**: all operations are translated into SQL and executed **inside Snowflake's compute engine**, not on the client machine.

This means you get the expressiveness of Python/Java/Scala with the scalability and performance of Snowflake's execution engine.

```
+----------------------------+       +-----------------------+
| Client / Dev Environment   |       | Snowflake Engine      |
|                            |       |                       |
|  Python/Java/Scala code    | ----> |  SQL execution plan   |
|  DataFrame operations      |       |  Runs on warehouse    |
|  (lazy, builds query plan) |       |  (data never leaves)  |
+----------------------------+       +-----------------------+
```

### Supported Languages

| Language | Package | Status |
|---|---|---|
| Python | `snowflake-snowpark-python` | Most popular, GA |
| Scala | Built into Snowflake Spark connector lineage | GA |
| Java | `snowpark` Java library | GA |

---

## Session Object

The `Session` object is the entry point for all Snowpark operations. It establishes a connection to Snowflake and provides methods to create DataFrames, call SQL, and manage context.

### Creating a Session (Python)

```python
from snowflake.snowpark import Session

connection_params = {
    "account": "myorg-myaccount",
    "user": "my_user",
    "password": "my_password",
    "role": "DATA_ENGINEER",
    "warehouse": "ETL_WH",
    "database": "ANALYTICS",
    "schema": "PUBLIC"
}

session = Session.builder.configs(connection_params).create()

# Verify connection
print(session.sql("SELECT CURRENT_WAREHOUSE()").collect())
```

### Key Session Methods

```python
# Create DataFrame from table
df = session.table("customers")

# Create DataFrame from SQL
df = session.sql("SELECT * FROM orders WHERE amount > 100")

# Create DataFrame from values
df = session.create_dataframe([[1, "Alice"], [2, "Bob"]], schema=["id", "name"])

# Create DataFrame from stage files
df = session.read.parquet("@my_stage/data/")
df = session.read.csv("@my_stage/csv_data/")

# Close session
session.close()
```

---

## Snowpark for Python Setup

### Installation

```bash
pip install snowflake-snowpark-python
# With pandas support
pip install "snowflake-snowpark-python[pandas]"
```

### Supported Python Versions

Snowpark for Python requires a specific Python version range (typically 3.8 to 3.11 — check the latest docs for your Snowpark version). Use a virtual environment:

```bash
conda create -n snowpark python=3.11
conda activate snowpark
pip install snowflake-snowpark-python[pandas]
```

---

## DataFrame API

### Core Philosophy

Snowpark DataFrames are **lazily evaluated**. Operations like `select()`, `filter()`, and `join()` build a query plan but do **not** execute anything. Only **action methods** trigger execution.

### Lazy Transformations vs Actions

| Transformations (Lazy) | Actions (Trigger Execution) |
|---|---|
| `select()` | `collect()` |
| `filter()` / `where()` | `show()` |
| `join()` | `count()` |
| `group_by()` | `first()` |
| `sort()` / `order_by()` | `to_pandas()` |
| `with_column()` | `save_as_table()` |
| `drop()` | `copy_into_location()` |
| `distinct()` | `to_local_iterator()` |
| `union()` / `union_all()` | |
| `limit()` | |

---

## DataFrame Operations

### Select

```python
from snowflake.snowpark.functions import col, lit, upper

df = session.table("customers")

# Select specific columns
df1 = df.select("customer_id", "name", "email")

# Select with transformations
df2 = df.select(
    col("customer_id"),
    upper(col("name")).alias("name_upper"),
    col("email"),
    lit("active").alias("status")
)
```

### Filter / Where

```python
from snowflake.snowpark.functions import col
from snowflake.snowpark.types import IntegerType

df = session.table("orders")

# Simple filter
df_filtered = df.filter(col("amount") > 1000)

# Multiple conditions
df_filtered = df.filter(
    (col("amount") > 1000) &
    (col("status") == "COMPLETED") &
    (col("order_date") >= "2025-01-01")
)

# Using where (alias for filter)
df_filtered = df.where(col("region").isin(["US", "EU", "APAC"]))
```

### Join

```python
orders = session.table("orders")
customers = session.table("customers")
products = session.table("products")

# Inner join
df_joined = orders.join(
    customers,
    orders["customer_id"] == customers["customer_id"],
    join_type="inner"
)

# Left join
df_left = orders.join(
    customers,
    orders["customer_id"] == customers["customer_id"],
    join_type="left"
)

# Multi-table join
df_full = (
    orders
    .join(customers, orders["customer_id"] == customers["customer_id"])
    .join(products, orders["product_id"] == products["product_id"])
    .select(
        orders["order_id"],
        customers["name"].alias("customer_name"),
        products["product_name"],
        orders["amount"]
    )
)
```

### Group By and Aggregate

```python
from snowflake.snowpark.functions import (
    col, sum as sum_, avg, count, max as max_, min as min_
)

df = session.table("orders")

# Simple aggregation
df_agg = (
    df.group_by("customer_id")
    .agg(
        count("order_id").alias("total_orders"),
        sum_("amount").alias("total_amount"),
        avg("amount").alias("avg_amount"),
        max_("order_date").alias("last_order_date")
    )
)

# Multiple grouping columns
df_agg2 = (
    df.group_by("region", "product_category")
    .agg(
        sum_("amount").alias("revenue"),
        count("*").alias("order_count")
    )
    .sort(col("revenue").desc())
)
```

### With Column / Rename / Drop

```python
from snowflake.snowpark.functions import col, when, year, current_timestamp

df = session.table("orders")

# Add a new column
df = df.with_column("order_year", year(col("order_date")))

# Conditional column
df = df.with_column(
    "size_category",
    when(col("amount") > 10000, lit("LARGE"))
    .when(col("amount") > 1000, lit("MEDIUM"))
    .otherwise(lit("SMALL"))
)

# Rename
df = df.rename(col("amount"), "order_amount")

# Drop columns
df = df.drop("internal_notes", "temp_flag")
```

### Window Functions

```python
from snowflake.snowpark.functions import col, row_number, sum as sum_
from snowflake.snowpark import Window

df = session.table("orders")

# Row number per customer
window_spec = Window.partition_by("customer_id").order_by(col("order_date").desc())

df_ranked = df.with_column("row_num", row_number().over(window_spec))

# Running total
running_window = (
    Window.partition_by("customer_id")
    .order_by("order_date")
    .rows_between(Window.UNBOUNDED_PRECEDING, Window.CURRENT_ROW)
)
df_running = df.with_column("running_total", sum_("amount").over(running_window))
```

---

## Writing Results

```python
# Save as a new table
df_result.write.mode("overwrite").save_as_table("analytics.public.order_summary")

# Append to existing table
df_result.write.mode("append").save_as_table("analytics.public.order_summary")

# Write to stage as Parquet
df_result.write.copy_into_location(
    "@my_stage/output/",
    file_format_type="parquet",
    header=True,
    overwrite=True
)

# Collect to local Python (small results only)
rows = df_result.collect()  # List of Row objects
pdf = df_result.to_pandas()  # Pandas DataFrame
```

---

## UDFs in Snowpark

User-Defined Functions (UDFs) allow you to write custom scalar logic in Python and register it for use inside Snowflake SQL or DataFrames.

### Inline UDF (Anonymous)

```python
from snowflake.snowpark.functions import udf
from snowflake.snowpark.types import StringType, IntegerType

# Register an anonymous UDF
categorize = udf(
    lambda amount: "HIGH" if amount > 10000 else "LOW",
    return_type=StringType(),
    input_types=[IntegerType()]
)

df = session.table("orders")
df_categorized = df.with_column("category", categorize(col("amount")))
```

### Named / Permanent UDF

```python
from snowflake.snowpark.functions import udf
from snowflake.snowpark.types import StringType, FloatType

@udf(
    name="calculate_discount",
    is_permanent=True,
    stage_location="@my_udf_stage",
    replace=True,
    return_type=FloatType(),
    input_types=[FloatType(), StringType()]
)
def calculate_discount(amount: float, tier: str) -> float:
    discount_map = {"GOLD": 0.20, "SILVER": 0.10, "BRONZE": 0.05}
    discount = discount_map.get(tier, 0.0)
    return round(amount * (1 - discount), 2)
```

Once registered permanently, this UDF can be called from SQL:

```sql
SELECT order_id, amount, calculate_discount(amount, customer_tier) AS discounted
FROM orders;
```

### Vectorized UDFs (Batch API)

For better performance with large datasets, use **vectorized UDFs** that operate on pandas Series:

```python
from snowflake.snowpark.functions import pandas_udf
from snowflake.snowpark.types import FloatType, PandasSeriesType, PandasDataFrameType
import pandas as pd

@pandas_udf(
    name="normalize_score",
    is_permanent=True,
    stage_location="@my_udf_stage",
    replace=True,
    return_type=PandasSeriesType(FloatType()),
    input_types=[PandasDataFrameType([FloatType(), FloatType(), FloatType()])]
)
def normalize_score(df: pd.DataFrame) -> pd.Series:
    # df columns: score, min_score, max_score
    return (df.iloc[:, 0] - df.iloc[:, 1]) / (df.iloc[:, 2] - df.iloc[:, 1])
```

---

## UDTFs (User-Defined Table Functions)

UDTFs return **multiple rows** per input, acting as table generators.

```python
from snowflake.snowpark.functions import udtf
from snowflake.snowpark.types import StructType, StructField, StringType, IntegerType

class SplitWords:
    def process(self, text: str):
        for i, word in enumerate(text.split()):
            yield (word.lower(), i)

# Register the UDTF
split_words_udtf = session.udtf.register(
    SplitWords,
    output_schema=StructType([
        StructField("word", StringType()),
        StructField("position", IntegerType())
    ]),
    input_types=[StringType()],
    name="split_words",
    is_permanent=True,
    stage_location="@my_udf_stage",
    replace=True
)

# Use in a query
result = session.table("documents").join_table_function(split_words_udtf(col("content")))
result.show()
```

### UDTF with State (init / end_partition)

```python
class RunningStats:
    def __init__(self):
        self.values = []

    def process(self, value: float):
        self.values.append(value)
        # Don't yield here — accumulate

    def end_partition(self):
        import statistics
        if self.values:
            yield (
                len(self.values),
                round(statistics.mean(self.values), 2),
                round(statistics.stdev(self.values), 2) if len(self.values) > 1 else 0.0
            )
```

---

## Stored Procedures in Snowpark

Stored procedures allow you to encapsulate complex logic as callable routines. Unlike UDFs, stored procedures can perform **side effects** (DDL, DML, multi-statement logic).

```python
from snowflake.snowpark import Session
from snowflake.snowpark.functions import col, sum as sum_

def rebuild_summary(session: Session, source_table: str, target_table: str) -> str:
    """Rebuild a summary table from source data."""
    source_df = session.table(source_table)

    summary_df = (
        source_df
        .group_by("region", "product_category")
        .agg(
            sum_("amount").alias("total_revenue"),
            sum_("quantity").alias("total_quantity")
        )
    )

    summary_df.write.mode("overwrite").save_as_table(target_table)

    row_count = session.table(target_table).count()
    return f"Summary rebuilt with {row_count} rows"

# Register as a permanent stored procedure
session.sproc.register(
    func=rebuild_summary,
    name="rebuild_summary_sp",
    is_permanent=True,
    stage_location="@my_sproc_stage",
    replace=True,
    return_type=StringType(),
    input_types=[StringType(), StringType()]
)
```

Call from SQL:

```sql
CALL rebuild_summary_sp('raw_orders', 'order_summary');
```

---

## Snowpark ML

Snowpark ML provides a set of APIs for **machine learning** workflows entirely within Snowflake.

### Key Components

| Component | Purpose |
|---|---|
| `snowflake.ml.modeling` | Scikit-learn compatible preprocessing and modeling |
| `snowflake.ml.feature_store` | Feature engineering and management |
| `snowflake.ml.registry` | Model versioning and deployment |
| `snowflake.ml.dataset` | Dataset management for training |

### Example: Training a Model

```python
from snowflake.ml.modeling.preprocessing import StandardScaler, OneHotEncoder
from snowflake.ml.modeling.pipeline import Pipeline
from snowflake.ml.modeling.xgboost import XGBClassifier
from snowflake.ml.registry import Registry

# Prepare data
train_df = session.table("training_data")

# Build pipeline
pipeline = Pipeline(
    steps=[
        ("scaler", StandardScaler(input_cols=["age", "income"], output_cols=["age_scaled", "income_scaled"])),
        ("encoder", OneHotEncoder(input_cols=["region"], output_cols=["region_encoded"])),
        ("model", XGBClassifier(
            input_cols=["age_scaled", "income_scaled", "region_encoded"],
            label_cols=["churn_flag"]
        ))
    ]
)

# Train — runs on Snowflake warehouse
pipeline.fit(train_df)

# Predict
predictions = pipeline.predict(session.table("scoring_data"))

# Register model
registry = Registry(session=session)
mv = registry.log_model(
    pipeline,
    model_name="churn_predictor",
    version_name="v1"
)
```

---

## Pushdown Processing

**Pushdown** is the core principle of Snowpark. Every DataFrame operation is converted to a SQL query plan that runs on Snowflake's engine.

```python
# This Python code:
df = (
    session.table("orders")
    .filter(col("amount") > 1000)
    .group_by("region")
    .agg(sum_("amount").alias("total"))
    .sort(col("total").desc())
)

# Generates this SQL (approximately):
# SELECT region, SUM(amount) AS total
# FROM orders
# WHERE amount > 1000
# GROUP BY region
# ORDER BY total DESC
```

### Viewing the Generated SQL

```python
# See the query plan without executing
print(df.queries)

# See the explain plan
df.explain()
```

This is fundamentally different from pulling data to the client and processing with pandas — **data never leaves Snowflake**.

---

## Lazy Evaluation and Action Methods

### How Lazy Evaluation Works

```python
# These lines build a plan but execute NOTHING
df1 = session.table("orders")                    # Plan: scan orders
df2 = df1.filter(col("amount") > 1000)           # Plan: scan + filter
df3 = df2.select("order_id", "customer_id")      # Plan: scan + filter + project
df4 = df3.sort("order_id")                        # Plan: scan + filter + project + sort

# This triggers execution of the entire plan
result = df4.collect()  # NOW the SQL runs on the warehouse
```

### Why Lazy Evaluation Matters

1. **Query optimization** — Snowflake's optimizer sees the full plan and can optimize (predicate pushdown, projection pruning, join reordering).
2. **No intermediate materialization** — intermediate DataFrames don't create temp tables.
3. **Efficient resource use** — only the final optimized query uses warehouse compute.

### Caching DataFrames

If you reuse a DataFrame multiple times, consider caching to avoid redundant computation:

```python
# cache_result() materializes the DataFrame into a temporary table
df_cached = expensive_df.cache_result()

# Now both of these read from the temp table, not recompute
summary1 = df_cached.group_by("region").agg(sum_("amount"))
summary2 = df_cached.group_by("category").agg(count("*"))
```

---

## Snowpark vs Client-Side Processing

| Aspect | Snowpark (Pushdown) | Client-Side (pandas) |
|---|---|---|
| **Where data is processed** | Snowflake warehouse | Local machine |
| **Data movement** | None (stays in Snowflake) | Full dataset pulled to client |
| **Scalability** | Scales with warehouse size | Limited by local RAM/CPU |
| **Performance on large data** | Excellent (distributed) | Poor (single-machine) |
| **Library ecosystem** | Limited to Snowpark functions | Full Python ecosystem |
| **Use case** | Production pipelines, large data | Prototyping, small data, niche libraries |

### When to Use Each

- **Snowpark**: Production data pipelines, transformations on millions/billions of rows, scheduled jobs.
- **pandas**: Quick local analysis, small result sets, leveraging specialized libraries not available in Snowpark.
- **Hybrid**: Use Snowpark for heavy lifting, then `.to_pandas()` for final visualization or niche processing on small aggregated results.

---

## Deploying Snowpark Code

### As Stored Procedures

Most common deployment pattern for scheduled pipelines:

```python
# Register as permanent stored procedure
session.sproc.register(
    func=my_pipeline_function,
    name="daily_etl_pipeline",
    is_permanent=True,
    stage_location="@deployment_stage",
    packages=["snowflake-snowpark-python", "pandas"],
    replace=True
)
```

Then schedule with a Snowflake Task:

```sql
CREATE OR REPLACE TASK daily_etl
  WAREHOUSE = ETL_WH
  SCHEDULE = 'USING CRON 0 6 * * * America/New_York'
AS
  CALL daily_etl_pipeline();
```

### As UDFs for Reusable Logic

Register functions as permanent UDFs callable from SQL and other Snowpark code.

### Via CI/CD

```
Git Repo --> CI/CD Pipeline --> PUT to Stage --> CREATE OR REPLACE PROCEDURE
```

Use `snowflake-cli` (snow CLI) or SnowSQL in your CI/CD pipeline:

```bash
# Upload code to stage
snow stage put ./src/*.py @deployment_stage/src/ --overwrite

# Deploy stored procedure
snow sql -q "CREATE OR REPLACE PROCEDURE ..."
```

---

## Snowpark Container Services Overview

Snowpark Container Services (SPCS) allows you to run **OCI-compliant containers** (Docker) directly inside Snowflake's infrastructure.

### Key Concepts

| Concept | Description |
|---|---|
| **Compute Pool** | A set of GPU/CPU nodes allocated for running containers |
| **Service** | A long-running container application (e.g., REST API, ML serving) |
| **Job** | A short-lived container execution (e.g., batch training) |
| **Image Repository** | Snowflake-hosted container registry for your images |
| **Service Function** | A SQL function that calls a running container service |
| **Ingress** | Public endpoint to expose a service to the internet |

### Example: Deploying a Container Service

```sql
-- Create a compute pool
CREATE COMPUTE POOL ml_serving_pool
  MIN_NODES = 1
  MAX_NODES = 3
  INSTANCE_FAMILY = GPU_NV_S;

-- Create a service from a spec file
CREATE SERVICE ml_serving_service
  IN COMPUTE POOL ml_serving_pool
  FROM @specs_stage
  SPECIFICATION_FILE = 'ml_service.yaml';

-- Create a function that calls the service
CREATE FUNCTION predict_churn(features OBJECT)
  RETURNS OBJECT
  SERVICE = ml_serving_service
  ENDPOINT = 'predict'
  AS '/predict';

-- Use in SQL
SELECT customer_id, predict_churn(feature_object) AS prediction
FROM customer_features;
```

### Use Cases for SPCS

- Serving custom ML models (PyTorch, TensorFlow) with GPU support.
- Running applications that need arbitrary dependencies or OS-level packages.
- Hosting web applications (Streamlit, Flask) with secure access to Snowflake data.
- Running LLM inference inside Snowflake's security perimeter.

---

## Common Interview Questions & Answers

### Q1: What is Snowpark and how does it differ from using a Snowflake connector with pandas?

**A:** Snowpark is a developer framework that provides a DataFrame API in Python, Java, or Scala with **pushdown processing** — all operations are translated to SQL and executed on Snowflake's compute engine. With a connector + pandas, you pull data to the client and process locally. Snowpark keeps data inside Snowflake, scales with the warehouse, and avoids network transfer bottlenecks. pandas is limited by local machine resources and requires moving potentially massive datasets over the network.

### Q2: Explain lazy evaluation in Snowpark. Why does it matter?

**A:** Snowpark DataFrames use lazy evaluation — transformation operations (select, filter, join, etc.) build a logical query plan but don't execute until an **action method** (collect, show, count, save_as_table) is called. This matters because it allows Snowflake's optimizer to see the entire query plan and apply optimizations like predicate pushdown, projection pruning, and join reordering. It also avoids materializing intermediate results, reducing compute and storage costs.

### Q3: What is the difference between a UDF and a stored procedure in Snowpark?

**A:** A **UDF** is a scalar or tabular function that takes input values and returns output values — it is used within queries (SELECT, WHERE, etc.) and cannot perform side effects like DDL or DML. A **stored procedure** encapsulates multi-step logic, can perform DDL/DML (CREATE, INSERT, MERGE), manage transactions, and orchestrate complex workflows. Stored procedures are called with `CALL` and receive a `Session` object. UDFs receive only the input column values.

### Q4: How would you deploy a Snowpark pipeline to production?

**A:** (1) Package the code and register it as a **permanent stored procedure** on a Snowflake stage. (2) Schedule it with a **Snowflake Task** using a CRON expression. (3) Use **CI/CD** (GitHub Actions, Azure DevOps) to automate uploads to the stage and procedure creation. (4) Monitor with Task History and Query History. (5) Use version-specific stage paths for rollback capability.

### Q5: When would you use Snowpark Container Services instead of regular Snowpark?

**A:** Use SPCS when you need: (1) arbitrary dependencies not available in Snowpark's sandbox (custom C libraries, CUDA, etc.), (2) GPU-accelerated workloads (deep learning inference/training), (3) long-running services like REST APIs or web apps, (4) full control over the runtime environment via Docker containers. Use regular Snowpark for standard data transformations and simpler ML workflows that fit within Snowpark's supported packages.

### Q6: What is a vectorized UDF and when should you use one?

**A:** A vectorized UDF (pandas UDF) processes data in **batches** as pandas Series/DataFrames rather than row-by-row. It uses Apache Arrow for efficient data transfer between Snowflake and the Python runtime. Use it when: (1) your logic benefits from vectorized numpy/pandas operations, (2) you're processing large volumes of data where per-row overhead matters, (3) you need to apply pandas/numpy functions that are inherently batch-oriented. Vectorized UDFs can be **10-100x faster** than scalar UDFs for large datasets.

---

## Tips

- **Always check `.queries`** on your DataFrame during development to see what SQL Snowpark generates — this helps debug performance issues.
- **Use `cache_result()`** when you reference the same expensive DataFrame multiple times in your pipeline.
- **Import Snowpark functions carefully** — `sum`, `min`, `max` conflict with Python builtins. Use `from snowflake.snowpark.functions import sum as sum_` or `F.sum()` pattern.
- **Prefer permanent UDFs/procedures** for production. Temporary ones exist only for the session.
- **Specify packages explicitly** when registering UDFs/procedures to ensure the correct versions are used.
- **Use the `@` decorator syntax** for cleaner UDF/procedure registration.
- **Keep Python UDF logic lightweight** — heavy computation should be expressed as DataFrame operations (pushdown) whenever possible.
- **Test locally first** using `session.create_dataframe()` with sample data before running against full production tables.
- **Use Snowpark ML** instead of manually pulling data to train sklearn models — it pushes preprocessing to the warehouse.

---
