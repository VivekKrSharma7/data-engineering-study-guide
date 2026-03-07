# Sequences, Identity & Auto-Increment

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Sequences Overview](#sequences-overview)
2. [Creating and Configuring Sequences](#creating-and-configuring-sequences)
3. [Using Sequences in SQL](#using-sequences-in-sql)
4. [AUTOINCREMENT / IDENTITY Column Property](#autoincrement--identity-column-property)
5. [DEFAULT with Sequence NEXTVAL](#default-with-sequence-nextval)
6. [Sequence Gaps](#sequence-gaps)
7. [Sequences vs Identity: Comparison](#sequences-vs-identity-comparison)
8. [UUID Generation (UUID_STRING)](#uuid-generation-uuid_string)
9. [Unique Key Generation Strategies](#unique-key-generation-strategies)
10. [Distributed Sequence Considerations](#distributed-sequence-considerations)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips](#tips)

---

## Sequences Overview

A **sequence** in Snowflake is a schema-level object that generates unique numeric values. Sequences are commonly used to produce surrogate keys, unique identifiers, and auto-incrementing values for tables.

Key characteristics:

- Sequences generate **integer** values.
- They are **not tied** to any specific table — a single sequence can be shared across multiple tables.
- Snowflake sequences do **not guarantee** gap-free or strictly ordered values (due to the distributed architecture).
- Sequences are independent objects with their own lifecycle (CREATE, ALTER, DROP).

```sql
-- Basic sequence creation
CREATE OR REPLACE SEQUENCE my_sequence;

-- Generate the next value
SELECT my_sequence.NEXTVAL;
```

---

## Creating and Configuring Sequences

### CREATE SEQUENCE Syntax

```sql
CREATE [ OR REPLACE ] SEQUENCE [ IF NOT EXISTS ] <name>
  [ START [ WITH ] = <initial_value> ]
  [ INCREMENT [ BY ] = <step_value> ]
  [ ORDER | NOORDER ]
  [ COMMENT = '<string>' ];
```

### Sequence Properties

#### START (default: 1)

The initial value of the sequence. The first call to `NEXTVAL` returns this value.

```sql
CREATE OR REPLACE SEQUENCE order_seq START = 1000;
-- First NEXTVAL returns 1000
```

#### INCREMENT (default: 1)

The step between consecutive values.

```sql
CREATE OR REPLACE SEQUENCE even_seq START = 2 INCREMENT = 2;
-- Generates: 2, 4, 6, 8, ...

CREATE OR REPLACE SEQUENCE reverse_seq START = 100 INCREMENT = -1;
-- Generates: 100, 99, 98, 97, ...
```

#### ORDER vs NOORDER

- **ORDER**: Guarantees that sequence values are generated in an increasing (or decreasing) order across all concurrent sessions. This comes with a **performance cost** due to synchronization overhead.
- **NOORDER** (default): Values are unique but **not necessarily ordered** across concurrent sessions. Much better performance in distributed environments.

```sql
-- When strict ordering matters (rare)
CREATE OR REPLACE SEQUENCE strict_seq ORDER;

-- When only uniqueness matters (common, default behavior)
CREATE OR REPLACE SEQUENCE fast_seq NOORDER;
```

### Managing Sequences

```sql
-- View sequence details
SHOW SEQUENCES IN SCHEMA my_schema;
DESCRIBE SEQUENCE my_sequence;

-- Alter a sequence
ALTER SEQUENCE my_sequence SET INCREMENT = 5;

-- Drop a sequence
DROP SEQUENCE my_sequence;
```

---

## Using Sequences in SQL

### In INSERT Statements

```sql
CREATE OR REPLACE SEQUENCE customer_seq START = 1 INCREMENT = 1;

CREATE OR REPLACE TABLE customers (
    customer_id   INT,
    name          VARCHAR(100),
    email         VARCHAR(200)
);

-- Single row insert
INSERT INTO customers (customer_id, name, email)
VALUES (customer_seq.NEXTVAL, 'Alice Johnson', 'alice@example.com');

-- Multiple row insert (each row gets a unique value)
INSERT INTO customers (customer_id, name, email)
VALUES
    (customer_seq.NEXTVAL, 'Bob Smith', 'bob@example.com'),
    (customer_seq.NEXTVAL, 'Carol White', 'carol@example.com');
```

### In INSERT ... SELECT

```sql
-- Each row from the SELECT gets a unique sequence value
INSERT INTO customers (customer_id, name, email)
SELECT customer_seq.NEXTVAL, name, email
FROM staging_customers;
```

### In SELECT Statements

```sql
-- Generate sequence values inline
SELECT
    customer_seq.NEXTVAL AS new_id,
    name,
    email
FROM staging_customers;
```

### NEXTVAL vs Repeated Calls

Each reference to `sequence.NEXTVAL` within a single row returns the **same value**. Across rows, it returns **different values**.

```sql
-- Both columns get the SAME value per row
SELECT
    my_seq.NEXTVAL AS id1,
    my_seq.NEXTVAL AS id2
FROM TABLE(GENERATOR(ROWCOUNT => 3));
-- Row 1: id1=1, id2=1
-- Row 2: id1=2, id2=2
-- Row 3: id1=3, id2=3
```

---

## AUTOINCREMENT / IDENTITY Column Property

`AUTOINCREMENT` (alias: `IDENTITY`) is a column-level property that automatically generates unique numeric values when rows are inserted. Unlike sequences, it is **bound to a specific column** in a specific table.

### Syntax

```sql
CREATE OR REPLACE TABLE orders (
    order_id    INT AUTOINCREMENT,
    -- or equivalently:
    -- order_id INT IDENTITY,
    product     VARCHAR(100),
    quantity    INT,
    order_date  DATE
);

-- With custom start and increment
CREATE OR REPLACE TABLE invoices (
    invoice_id  INT AUTOINCREMENT START 1000 INCREMENT 1,
    amount      DECIMAL(10,2),
    created_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

### Inserting with AUTOINCREMENT

```sql
-- Omit the AUTOINCREMENT column; it is populated automatically
INSERT INTO orders (product, quantity, order_date)
VALUES ('Widget A', 10, '2026-01-15');

INSERT INTO orders (product, quantity, order_date)
VALUES ('Widget B', 5, '2026-01-16');

-- Result:
-- order_id=1, product='Widget A', quantity=10
-- order_id=2, product='Widget B', quantity=5
```

### ORDER and NOORDER with IDENTITY

Similar to sequences, you can specify ordering behavior:

```sql
CREATE OR REPLACE TABLE events (
    event_id   INT IDENTITY(1, 1) ORDER,     -- strictly ordered (slower)
    event_name VARCHAR(200)
);

CREATE OR REPLACE TABLE logs (
    log_id     INT IDENTITY(1, 1) NOORDER,   -- unique but not ordered (faster, default)
    message    VARCHAR(1000)
);
```

---

## DEFAULT with Sequence NEXTVAL

You can set a column's DEFAULT value to a sequence, giving you the flexibility of a shared sequence with the convenience of auto-population.

```sql
CREATE OR REPLACE SEQUENCE global_id_seq START = 1 INCREMENT = 1;

CREATE OR REPLACE TABLE products (
    product_id   INT DEFAULT global_id_seq.NEXTVAL,
    product_name VARCHAR(200),
    category     VARCHAR(100)
);

CREATE OR REPLACE TABLE suppliers (
    supplier_id  INT DEFAULT global_id_seq.NEXTVAL,
    supplier_name VARCHAR(200),
    country       VARCHAR(100)
);

-- Insert without specifying the ID — the sequence provides it
INSERT INTO products (product_name, category)
VALUES ('Laptop', 'Electronics');

INSERT INTO suppliers (supplier_name, country)
VALUES ('Acme Corp', 'USA');

-- Both tables share the same sequence, so IDs are globally unique across them
```

### Difference from AUTOINCREMENT

| Aspect | DEFAULT seq.NEXTVAL | AUTOINCREMENT |
|---|---|---|
| Sequence ownership | External, shared | Internal, per-column |
| Cross-table uniqueness | Yes (shared sequence) | No (each table independent) |
| Explicit override | Can INSERT a manual value | Can INSERT a manual value |
| Sequence management | Manual (CREATE/ALTER/DROP) | Automatic |

---

## Sequence Gaps

Gaps in generated sequence values are **expected and normal** in Snowflake. Understanding why is critical for interviews.

### Why Gaps Occur

1. **Rolled-back transactions:** If a transaction obtains a sequence value but then rolls back, that value is consumed and will not be reused.

2. **Batch allocation:** Snowflake pre-allocates blocks of sequence values to nodes in the distributed cluster for performance. If a node doesn't use all allocated values, those are lost.

3. **NOORDER mode:** Different nodes may generate values from different ranges concurrently, leading to non-contiguous values.

4. **Failed inserts:** If an INSERT fails after obtaining a sequence value, the value is still consumed.

### Example

```sql
CREATE OR REPLACE SEQUENCE test_seq START = 1 INCREMENT = 1;

-- Transaction 1: succeeds
INSERT INTO my_table (id, val) VALUES (test_seq.NEXTVAL, 'A');  -- id = 1

-- Transaction 2: rolls back
BEGIN;
INSERT INTO my_table (id, val) VALUES (test_seq.NEXTVAL, 'B');  -- id = 2 (consumed)
ROLLBACK;  -- Value 2 is gone

-- Transaction 3: succeeds
INSERT INTO my_table (id, val) VALUES (test_seq.NEXTVAL, 'C');  -- id = 3 (not 2)
```

### Key Rule

**Never rely on sequences for gap-free numbering.** If you need gap-free numbers (e.g., invoice numbers for regulatory compliance), use a separate approach such as `ROW_NUMBER()` at query time or a controlled stored procedure with locking.

---

## Sequences vs Identity: Comparison

| Feature | Sequence | AUTOINCREMENT / IDENTITY |
|---|---|---|
| Object type | Schema-level object | Column property |
| Scope | Can be shared across tables | Bound to one column in one table |
| Creation | `CREATE SEQUENCE` | Defined in `CREATE TABLE` |
| Custom start/increment | Yes | Yes |
| ORDER/NOORDER | Yes | Yes |
| Can be used in SELECT | Yes (seq.NEXTVAL) | No (only on INSERT) |
| Can be altered independently | Yes (`ALTER SEQUENCE`) | Limited |
| Gap-free | No | No |
| Cross-table unique IDs | Yes | No |
| Default column integration | Yes (DEFAULT seq.NEXTVAL) | Automatic |

### When to Use Which

- **Use AUTOINCREMENT** when: You need a simple, per-table surrogate key and don't need to share the sequence across tables. It's simpler and requires no additional object management.

- **Use Sequences** when: You need globally unique IDs across multiple tables, want to use the same ID generator in complex logic, or need finer control (e.g., sharing across procedures, SELECT generation).

---

## UUID Generation (UUID_STRING)

For universally unique identifiers that don't depend on numeric sequences, Snowflake provides the `UUID_STRING()` function.

### Basic Usage

```sql
-- Generate a random UUID (version 4)
SELECT UUID_STRING();
-- Example: '5e7b9a1c-4d3f-4a2b-8c1e-9f6d3a2b1c0e'

-- Generate a UUID with a specific name and namespace (version 5)
SELECT UUID_STRING('6ba7b810-9dad-11d1-80b4-00c04fd430c8', 'my_unique_name');
-- Deterministic: same inputs always produce the same UUID
```

### Using UUID as a Primary Key

```sql
CREATE OR REPLACE TABLE api_events (
    event_id    VARCHAR(36) DEFAULT UUID_STRING(),
    event_type  VARCHAR(100),
    payload     VARIANT,
    created_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO api_events (event_type, payload)
SELECT 'page_view', PARSE_JSON('{"page": "/home", "user": "u123"}');
-- event_id is automatically populated with a UUID
```

### UUID Pros and Cons

| Advantage | Disadvantage |
|---|---|
| Globally unique without coordination | 36 characters, larger storage than INT |
| No sequence object needed | Not human-readable |
| Safe for distributed/multi-region | Cannot be sorted chronologically (v4) |
| No gaps issue (every generation is unique) | Slower joins compared to INT keys |
| Can be generated client-side | Random distribution may affect clustering |

---

## Unique Key Generation Strategies

### Strategy 1: AUTOINCREMENT (Simplest)

```sql
CREATE TABLE dim_product (
    product_key INT AUTOINCREMENT,
    product_id  VARCHAR(50),  -- natural key
    product_name VARCHAR(200)
);
```

Best for: Simple dimension tables, single-table surrogate keys.

### Strategy 2: Shared Sequence (Cross-Table Uniqueness)

```sql
CREATE SEQUENCE global_surrogate_seq START = 1 INCREMENT = 1;

CREATE TABLE dim_customer (
    surrogate_key INT DEFAULT global_surrogate_seq.NEXTVAL,
    customer_id   VARCHAR(50)
);

CREATE TABLE dim_product (
    surrogate_key INT DEFAULT global_surrogate_seq.NEXTVAL,
    product_id    VARCHAR(50)
);
```

Best for: Data vault or unified key strategies where no two surrogate keys should collide.

### Strategy 3: UUID (Distributed / External Integration)

```sql
CREATE TABLE events (
    event_id   VARCHAR(36) DEFAULT UUID_STRING(),
    event_data VARIANT
);
```

Best for: Event-driven architectures, microservices, data that originates from multiple systems.

### Strategy 4: Hash-Based Keys (Deterministic)

```sql
-- MD5 hash of natural key columns
CREATE TABLE hub_customer (
    customer_hash_key VARCHAR(32) AS (MD5(UPPER(TRIM(customer_id)))),
    customer_id       VARCHAR(50),
    load_date         TIMESTAMP_NTZ
);

-- SHA-256 for better collision resistance
SELECT SHA2(CONCAT(customer_id, '|', order_id), 256) AS composite_key
FROM staging_data;
```

Best for: Data Vault 2.0 hash keys, idempotent loading, deterministic key generation.

### Strategy 5: ROW_NUMBER for Gap-Free Numbering

```sql
-- Generate gap-free numbers at query time
SELECT
    ROW_NUMBER() OVER (ORDER BY created_at) AS row_num,
    customer_id,
    name
FROM customers;
```

Best for: Reporting, display numbering, regulatory requirements.

---

## Distributed Sequence Considerations

Snowflake's architecture is massively parallel and distributed. This fundamentally affects how sequences behave.

### Why Ordering Is Expensive

When `ORDER` is specified, Snowflake must coordinate sequence value generation across all nodes. This introduces a **serialization bottleneck** that significantly reduces throughput for high-volume inserts.

```sql
-- This is SLOW for bulk inserts
CREATE SEQUENCE ordered_seq ORDER;

-- This is FAST for bulk inserts (default)
CREATE SEQUENCE unordered_seq NOORDER;
```

### Block Allocation

With `NOORDER`, Snowflake allocates **blocks** of sequence values to each compute node. For example:
- Node 1 gets values 1-1000
- Node 2 gets values 1001-2000
- Node 3 gets values 2001-3000

If Node 1 only uses 500 values, values 501-1000 are never assigned. This is why gaps appear.

### Multi-Cluster Warehouse Impact

When using multi-cluster warehouses, each cluster may independently allocate sequence blocks, increasing the likelihood of gaps and out-of-order values.

### Best Practices for Distributed Environments

1. **Use NOORDER** unless you have a strict requirement for ordering.
2. **Accept gaps** as a normal part of distributed sequence generation.
3. **Use UUIDs** if you need guaranteed uniqueness across systems without central coordination.
4. **Use hash keys** (MD5/SHA) for deterministic key generation that is idempotent and does not depend on a centralized counter.

---

## Common Interview Questions

### Q1: What is the difference between a sequence and an AUTOINCREMENT/IDENTITY column in Snowflake?

**A:** A sequence is an independent schema-level object that generates unique numbers and can be shared across multiple tables and SQL statements. AUTOINCREMENT (or IDENTITY) is a column-level property tied to a specific table column that automatically generates values on INSERT. Sequences offer more flexibility (shared IDs, use in SELECT), while AUTOINCREMENT is simpler for single-table surrogate keys.

### Q2: Are sequences gap-free in Snowflake? Why or why not?

**A:** No. Gaps occur due to rolled-back transactions (consumed values are not recycled), block allocation to distributed nodes (unused values in allocated blocks are lost), and failed operations. This is by design in a distributed system to maintain performance. For gap-free numbering, use `ROW_NUMBER()` at query time or a controlled procedure.

### Q3: What is the difference between ORDER and NOORDER in a sequence?

**A:** ORDER guarantees that generated values are in increasing (or decreasing) order across all concurrent sessions, but requires cross-node coordination that reduces performance. NOORDER (default) guarantees uniqueness but not ordering, allowing parallel generation with much higher throughput. Use NOORDER unless strict ordering is explicitly required.

### Q4: How would you generate globally unique keys across multiple tables?

**A:** Several approaches: (1) Use a single shared sequence with `DEFAULT seq.NEXTVAL` across tables. (2) Use `UUID_STRING()` for UUID-based keys that require no coordination. (3) Use hash-based keys (MD5/SHA2) on natural key columns for deterministic, repeatable key generation. The choice depends on requirements around readability, storage, and determinism.

### Q5: When would you use UUID_STRING() instead of a sequence?

**A:** UUIDs are preferred when: data originates from multiple distributed systems and needs pre-generation before reaching Snowflake; you need globally unique identifiers without a centralized counter; you want idempotent data loading (version 5 UUIDs with deterministic inputs); or for integration with external systems that expect UUID format. Sequences are better when you need compact integer keys and operate solely within Snowflake.

### Q6: How do you use a sequence as a default column value?

**A:** Define the column with `DEFAULT sequence_name.NEXTVAL`:

```sql
CREATE SEQUENCE my_seq;
CREATE TABLE my_table (
    id INT DEFAULT my_seq.NEXTVAL,
    name VARCHAR(100)
);
INSERT INTO my_table (name) VALUES ('test');  -- id auto-populated
```

This combines the flexibility of a shared sequence with the convenience of automatic value generation.

### Q7: Can you reset a sequence in Snowflake?

**A:** There is no direct RESET command. You can recreate the sequence with `CREATE OR REPLACE SEQUENCE` using the desired START value. Alternatively, you can use `ALTER SEQUENCE ... SET INCREMENT = <negative_value>` to move the counter back, but this is not a clean reset. The simplest approach is `CREATE OR REPLACE`.

### Q8: How does AUTOINCREMENT behave with multi-cluster warehouses?

**A:** Similar to NOORDER sequences, each cluster node may independently generate values, leading to non-contiguous sequences. The values are guaranteed unique but may appear out of order and with gaps. For strictly ordered inserts, use a single-cluster warehouse with an ORDER identity, though this impacts throughput.

---

## Tips

1. **Default to NOORDER.** Unless you have a documented requirement for strict ordering, always use NOORDER (the default) for both sequences and IDENTITY columns. The performance difference is substantial.

2. **Never assume gap-free sequences.** Design your application and business logic to tolerate gaps. Use `ROW_NUMBER()` for display/report numbering if consecutive values are needed.

3. **Choose the right key strategy early.** Switching from AUTOINCREMENT to UUID or hash keys later in a project is expensive. Align your strategy with your data architecture (star schema, Data Vault, etc.) from the beginning.

4. **Use hash keys for Data Vault.** MD5 or SHA-256 hash keys on business keys are standard practice in Data Vault 2.0. They are deterministic, idempotent, and perform well in Snowflake.

5. **Shared sequences need careful management.** If multiple tables share a sequence, dropping or altering the sequence affects all dependent tables. Document dependencies and use naming conventions like `seq_global_surrogate`.

6. **UUID storage considerations.** Store UUIDs as `VARCHAR(36)` or use `REPLACE(UUID_STRING(), '-', '')` for a 32-character hex string. Consider the join performance impact compared to integer keys on very large tables.

7. **Test sequence behavior under concurrency.** In interviews, demonstrate awareness that concurrent sessions can observe different sequence behaviors (especially with NOORDER) and that this is a trade-off for distributed performance.
