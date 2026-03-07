# dbt with Snowflake

[Back to Snowflake Index](./README.md)

---

## 1. Overview

**dbt (data build tool)** is a transformation framework that enables data engineers and analytics engineers to transform data in the warehouse using SQL and software engineering best practices (version control, testing, documentation, modularity). dbt operates on the **T in ELT** — it assumes data is already loaded into the warehouse and focuses solely on transforming it.

### Why dbt + Snowflake?

- Snowflake's separation of compute and storage aligns perfectly with dbt's SQL-first transformation model
- The `dbt-snowflake` adapter leverages Snowflake-specific features (transient tables, query tags, merge behavior)
- dbt handles dependency resolution, materializations, incremental logic, testing, and documentation generation
- Industry standard pairing for modern data stack

---

## 2. dbt-snowflake Adapter

### Installation

```bash
# dbt Core (open source)
pip install dbt-snowflake

# Verify
dbt --version
```

### Connection Profile (`~/.dbt/profiles.yml`)

```yaml
my_snowflake_project:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: xy12345.us-east-1
      user: DBT_USER
      password: "{{ env_var('DBT_PASSWORD') }}"
      role: DBT_ROLE
      database: ANALYTICS
      warehouse: WH_DBT_DEV
      schema: DEV_JSMITH
      threads: 4
      query_tag: dbt_dev

    prod:
      type: snowflake
      account: xy12345.us-east-1
      user: DBT_PROD_USER
      authenticator: externalbrowser  # or key-pair
      private_key_path: /path/to/rsa_key.p8
      role: DBT_PROD_ROLE
      database: ANALYTICS
      warehouse: WH_DBT_PROD
      schema: PROD
      threads: 8
      query_tag: dbt_prod
```

### Snowflake-Specific Configurations

```yaml
# In dbt_project.yml
models:
  my_project:
    staging:
      +materialized: view
      +transient: false
    marts:
      +materialized: table
      +transient: true           # Snowflake transient table (no Fail-safe)
      +copy_grants: true         # Preserve grants on rebuild
      +query_tag: 'dbt_marts'   # Tag queries in QUERY_HISTORY
```

---

## 3. Project Structure

A well-organized dbt project follows a standard directory layout:

```
my_dbt_project/
├── dbt_project.yml          # Project configuration
├── packages.yml             # External package dependencies
├── profiles.yml             # Connection profiles (or in ~/.dbt/)
├── models/
│   ├── staging/             # 1:1 with source tables, light cleaning
│   │   ├── stg_orders.sql
│   │   ├── stg_customers.sql
│   │   └── _staging__sources.yml
│   ├── intermediate/        # Business logic joining staging models
│   │   └── int_order_items_pivoted.sql
│   └── marts/               # Final consumption-layer tables
│       ├── dim_customers.sql
│       ├── fct_orders.sql
│       └── _marts__models.yml
├── tests/                   # Custom singular tests
│   └── assert_positive_revenue.sql
├── macros/                  # Reusable Jinja macros
│   └── generate_surrogate_key.sql
├── seeds/                   # CSV files loaded as tables
│   └── country_codes.csv
├── snapshots/               # SCD Type 2 tracking
│   └── snap_customers.sql
├── analyses/                # Ad-hoc analytical queries (not materialized)
└── target/                  # Compiled SQL output (git-ignored)
```

---

## 4. Key Concepts

### 4.1 Models

Models are SQL `SELECT` statements that dbt materializes into objects in the warehouse.

```sql
-- models/staging/stg_orders.sql
WITH source AS (
    SELECT * FROM {{ source('raw', 'orders') }}
),

renamed AS (
    SELECT
        order_id,
        customer_id,
        order_date::DATE AS order_date,
        status,
        total_amount_cents / 100.0 AS total_amount,
        _loaded_at
    FROM source
    WHERE order_id IS NOT NULL
)

SELECT * FROM renamed
```

### 4.2 Sources

Sources declare the raw tables that dbt reads from, enabling lineage tracking and freshness checks.

```yaml
# models/staging/_staging__sources.yml
version: 2

sources:
  - name: raw
    database: RAW_DB
    schema: PUBLIC
    freshness:
      warn_after: {count: 12, period: hour}
      error_after: {count: 24, period: hour}
    loaded_at_field: _loaded_at
    tables:
      - name: orders
        description: "Raw orders from the transactional system"
      - name: customers
      - name: products
```

```bash
# Check source freshness
dbt source freshness
```

### 4.3 ref() and source()

These are the two most important Jinja functions in dbt:

- **`{{ ref('model_name') }}`** — References another dbt model. Builds the DAG (dependency graph) and resolves to the correct database.schema.table.
- **`{{ source('source_name', 'table_name') }}`** — References a declared source table.

```sql
-- models/marts/fct_orders.sql
SELECT
    o.order_id,
    o.order_date,
    o.total_amount,
    c.customer_name,
    c.customer_segment
FROM {{ ref('stg_orders') }} o
JOIN {{ ref('stg_customers') }} c
    ON o.customer_id = c.customer_id
```

**Why ref() matters:** It ensures dbt runs models in the correct dependency order, enables environment-aware schema resolution (dev vs prod), and powers the lineage graph.

### 4.4 Jinja Templating

dbt uses Jinja2 for dynamic SQL generation.

```sql
-- Using variables and control structures
{% set payment_methods = ['credit_card', 'bank_transfer', 'gift_card'] %}

SELECT
    order_id,
    {% for method in payment_methods %}
        SUM(CASE WHEN payment_method = '{{ method }}' THEN amount ELSE 0 END)
            AS {{ method }}_amount
        {{ "," if not loop.last }}
    {% endfor %}
FROM {{ ref('stg_payments') }}
GROUP BY order_id
```

```sql
-- Conditional logic
SELECT
    *,
    {% if target.name == 'dev' %}
        -- Limit data in dev for speed
        WHERE order_date >= DATEADD('month', -3, CURRENT_DATE())
    {% endif %}
FROM {{ ref('stg_orders') }}
```

---

## 5. Materializations

Materializations control how dbt persists a model in the warehouse.

| Materialization | What It Creates | When to Use |
|---|---|---|
| **view** | `CREATE VIEW` | Staging models, lightweight transforms, always-fresh data |
| **table** | `CREATE TABLE AS SELECT` | Marts, heavily queried models, complex transforms |
| **incremental** | `MERGE` / `INSERT` into existing table | Large fact tables, append-heavy workloads |
| **ephemeral** | CTE (not materialized) | Helper models used only as subqueries; no warehouse object created |

### Incremental Models (Deep Dive)

Incremental models only process new or changed data, dramatically reducing run time and cost.

```sql
-- models/marts/fct_events.sql
{{
    config(
        materialized='incremental',
        unique_key='event_id',
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

SELECT
    event_id,
    user_id,
    event_type,
    event_timestamp,
    properties
FROM {{ ref('stg_events') }}

{% if is_incremental() %}
    -- Only process new rows since the last run
    WHERE event_timestamp > (SELECT MAX(event_timestamp) FROM {{ this }})
{% endif %}
```

### Incremental Strategies in Snowflake

| Strategy | Mechanism | Best For |
|---|---|---|
| **merge** (default) | `MERGE INTO` using `unique_key` | Upserts — rows can be updated or inserted |
| **delete+insert** | Deletes matching rows then inserts | When merge is too expensive; append-mostly |
| **append** | `INSERT INTO` only | Event/log data that never updates |
| **microbatch** | Processes data in time-based batches | Very large incremental loads with time partitioning |

```sql
-- delete+insert strategy
{{
    config(
        materialized='incremental',
        unique_key='order_id',
        incremental_strategy='delete+insert'
    )
}}
```

### Full Refresh

```bash
# Force a full rebuild of an incremental model
dbt run --select fct_events --full-refresh
```

---

## 6. Testing

dbt supports two types of tests:

### Generic Tests (Schema Tests)

Defined in YAML, applied to columns:

```yaml
# models/marts/_marts__models.yml
version: 2

models:
  - name: fct_orders
    description: "Order fact table"
    columns:
      - name: order_id
        description: "Primary key"
        tests:
          - unique
          - not_null
      - name: customer_id
        tests:
          - not_null
          - relationships:
              to: ref('dim_customers')
              field: customer_id
      - name: status
        tests:
          - accepted_values:
              values: ['pending', 'shipped', 'delivered', 'cancelled']
```

### Singular Tests

Custom SQL queries saved in the `tests/` directory. A test fails if it returns any rows.

```sql
-- tests/assert_no_negative_revenue.sql
SELECT order_id, total_amount
FROM {{ ref('fct_orders') }}
WHERE total_amount < 0
```

### Running Tests

```bash
dbt test                          # Run all tests
dbt test --select fct_orders      # Test a specific model
dbt test --select source:raw      # Test all sources
dbt build                         # Run models + tests together in DAG order
```

---

## 7. Documentation

dbt auto-generates a documentation website from YAML descriptions and the DAG.

```bash
# Generate and serve documentation
dbt docs generate
dbt docs serve      # Opens a browser with interactive DAG and docs
```

Add descriptions in YAML files (as shown in the testing section) and use `doc` blocks for longer descriptions:

```markdown
{% docs dim_customers %}
# Customer Dimension

This table contains one row per customer, enriched with lifetime metrics.

## Business Rules
- `customer_segment` is derived from total lifetime spend
- Customers with no orders are excluded

{% enddocs %}
```

```yaml
models:
  - name: dim_customers
    description: '{{ doc("dim_customers") }}'
```

---

## 8. Snapshots (SCD Type 2)

Snapshots track changes in source data over time, implementing **Slowly Changing Dimension Type 2**.

```sql
-- snapshots/snap_customers.sql
{% snapshot snap_customers %}

{{
    config(
        target_database='ANALYTICS',
        target_schema='SNAPSHOTS',
        unique_key='customer_id',
        strategy='timestamp',
        updated_at='updated_at'
    )
}}

SELECT * FROM {{ source('raw', 'customers') }}

{% endsnapshot %}
```

### Snapshot Strategies

| Strategy | How It Detects Changes |
|---|---|
| **timestamp** | Compares `updated_at` column — more reliable and performant |
| **check** | Compares specified column values — use when no reliable timestamp exists |

```sql
-- check strategy example
{% snapshot snap_products %}
{{
    config(
        unique_key='product_id',
        strategy='check',
        check_cols=['price', 'product_name', 'category']
    )
}}
SELECT * FROM {{ source('raw', 'products') }}
{% endsnapshot %}
```

dbt adds metadata columns: `dbt_scd_id`, `dbt_updated_at`, `dbt_valid_from`, `dbt_valid_to`.

```bash
dbt snapshot    # Run all snapshots
```

---

## 9. Seeds

Seeds are CSV files in your dbt project that get loaded as tables. Best for small, static reference data.

```csv
# seeds/country_codes.csv
country_code,country_name,region
US,United States,North America
GB,United Kingdom,Europe
DE,Germany,Europe
```

```bash
dbt seed                        # Load all seeds
dbt seed --select country_codes # Load specific seed
```

```sql
-- Reference in a model
SELECT * FROM {{ ref('country_codes') }}
```

> **Tip:** Seeds are not for large data loads. Keep them under a few thousand rows. Use COPY INTO or Snowpipe for bulk loading.

---

## 10. Macros

Macros are reusable Jinja functions.

```sql
-- macros/cents_to_dollars.sql
{% macro cents_to_dollars(column_name, precision=2) %}
    ROUND({{ column_name }} / 100.0, {{ precision }})
{% endmacro %}
```

```sql
-- Usage in a model
SELECT
    order_id,
    {{ cents_to_dollars('amount_cents') }} AS amount_dollars
FROM {{ ref('stg_payments') }}
```

### dbt Packages

Reusable macro libraries from the community:

```yaml
# packages.yml
packages:
  - package: dbt-labs/dbt_utils
    version: [">=1.0.0", "<2.0.0"]
  - package: dbt-labs/codegen
    version: [">=0.9.0", "<1.0.0"]
```

```bash
dbt deps    # Install packages
```

```sql
-- Using dbt_utils
SELECT
    {{ dbt_utils.generate_surrogate_key(['order_id', 'line_item_id']) }} AS order_line_sk,
    *
FROM {{ ref('stg_order_items') }}
```

---

## 11. dbt Cloud vs dbt Core

| Feature | dbt Core | dbt Cloud |
|---|---|---|
| **Cost** | Free, open source | Paid SaaS (free developer tier) |
| **Execution** | CLI, self-managed | Managed environment, IDE in browser |
| **Scheduling** | External (Airflow, cron, etc.) | Built-in job scheduler |
| **CI/CD** | Self-configured | Built-in Slim CI (runs only modified models) |
| **IDE** | Local editor (VS Code) | Browser-based IDE |
| **Documentation** | Self-hosted | Auto-hosted with each run |
| **Metadata API** | Not available | Discovery & Admin APIs |
| **Semantic Layer** | Limited (via MetricFlow OSS) | Integrated MetricFlow + partner integrations |

### dbt Cloud Slim CI

dbt Cloud can run only modified models and their downstream dependencies on pull requests:

```yaml
# In dbt Cloud job configuration
dbt build --select state:modified+
```

This compares the current PR against the production manifest and only runs what changed — saving significant time and cost.

---

## 12. Deployment Patterns

### Pattern 1: dbt Core + Airflow

```python
# Airflow DAG using BashOperator
from airflow.operators.bash import BashOperator

dbt_run = BashOperator(
    task_id='dbt_run',
    bash_command='cd /opt/dbt/my_project && dbt run --target prod',
    env={'DBT_PASSWORD': '{{ var.value.dbt_password }}'}
)

dbt_test = BashOperator(
    task_id='dbt_test',
    bash_command='cd /opt/dbt/my_project && dbt test --target prod'
)

dbt_run >> dbt_test
```

### Pattern 2: dbt Cloud + CI/CD

1. Developers work in feature branches
2. PR triggers Slim CI job in dbt Cloud
3. Merge to main triggers production deployment job
4. dbt Cloud handles scheduling for regular runs

### Pattern 3: Environment Promotion

```yaml
# dbt_project.yml — dynamic schema based on target
models:
  my_project:
    staging:
      +schema: "{{ 'STAGING' if target.name == 'prod' else target.schema ~ '_STAGING' }}"
    marts:
      +schema: "{{ 'MARTS' if target.name == 'prod' else target.schema ~ '_MARTS' }}"
```

```bash
# Dev: writes to DEV_JSMITH_STAGING, DEV_JSMITH_MARTS
dbt run --target dev

# Prod: writes to STAGING, MARTS
dbt run --target prod
```

---

## 13. Common Interview Questions & Answers

### Q1: What is dbt and why is it used with Snowflake?

**A:** dbt is a transformation framework that enables SQL-based transformations with software engineering best practices — version control, testing, documentation, and modularity. With Snowflake, it leverages the ELT pattern: data is loaded first (E and L), then dbt handles transformations (T) inside Snowflake using Snowflake compute. The `dbt-snowflake` adapter supports Snowflake-specific features like transient tables, query tags, and merge strategies.

### Q2: Explain the difference between ref() and source().

**A:** `source()` references raw/external tables declared in YAML source definitions — it is the entry point from raw data into dbt. `ref()` references other dbt models — it builds the DAG, ensures correct execution order, and resolves to the appropriate database/schema based on the target environment. You should never hard-code table names; always use `ref()` or `source()`.

### Q3: How do incremental models work, and what strategies are available in Snowflake?

**A:** Incremental models only process new/changed data instead of rebuilding the entire table. On the first run (or `--full-refresh`), the full query runs. On subsequent runs, the `{% if is_incremental() %}` block filters to only new data. Snowflake supports `merge` (default, uses MERGE INTO), `delete+insert`, `append` (INSERT only), and `microbatch` strategies. The choice depends on whether data can update (merge) or is append-only (append).

### Q4: What is a dbt snapshot and when would you use one?

**A:** A snapshot implements SCD Type 2 — it tracks how source rows change over time by adding `dbt_valid_from` and `dbt_valid_to` columns. Use it when you need historical versions of dimension data (e.g., tracking customer address changes). Strategies are `timestamp` (preferred, requires an `updated_at` column) or `check` (compares column values directly).

### Q5: How would you implement CI/CD for a dbt project?

**A:** In dbt Cloud, use Slim CI — on each PR, run `dbt build --select state:modified+` to test only changed models. In dbt Core, integrate with GitHub Actions or similar: install dbt, run `dbt build`, and gate the merge on test results. Use separate targets for dev/staging/prod, and promote code (not data) through environments.

### Q6: What are the four materializations in dbt and when do you use each?

**A:** **View** — lightweight, always fresh, good for staging. **Table** — full rebuild each run, good for marts and complex transforms. **Incremental** — processes only new data, good for large fact tables. **Ephemeral** — compiled as a CTE, never materialized in the warehouse, good for helper/intermediate logic used in only one downstream model.

---

## 14. Tips

- **Use the staging/intermediate/marts pattern** — staging models are 1:1 with sources (rename, cast, filter), intermediate models handle complex joins/logic, marts are the final consumption layer.
- **Always use `ref()` and `source()`** — never hard-code table references. This enables DAG resolution, environment switching, and lineage.
- **Test aggressively** — at minimum, test `unique` and `not_null` on all primary keys and `relationships` on all foreign keys.
- **Use `dbt build`** instead of separate `dbt run` + `dbt test` — it interleaves runs and tests in DAG order, catching issues earlier.
- **Tag and select** — use tags and node selection (`--select tag:daily`, `--select marts+`) to run subsets of your project efficiently.
- **Set `query_tag`** in your profile — this tags all dbt queries in Snowflake's `QUERY_HISTORY`, making it easy to monitor dbt workloads.
- **Use `--full-refresh` sparingly** — it rebuilds incremental models from scratch and can be expensive on large tables.
- **Keep seeds small** — seeds are for static lookup data (hundreds of rows), not data loading.

---
