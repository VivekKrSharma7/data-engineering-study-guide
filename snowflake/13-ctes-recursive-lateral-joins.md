# CTEs, Recursive Queries & Lateral Joins

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Common Table Expressions (CTEs)](#common-table-expressions-ctes)
2. [Multiple CTEs](#multiple-ctes)
3. [Recursive CTEs](#recursive-ctes-with-recursive)
4. [CONNECT BY (Legacy Syntax)](#connect-by-legacy-syntax)
5. [LATERAL Joins](#lateral-joins)
6. [LATERAL FLATTEN Pattern](#lateral-flatten-pattern)
7. [Table Functions with LATERAL](#table-functions-with-lateral)
8. [Practical Examples](#practical-examples)
9. [CTE vs Subquery vs Temp Table Performance](#cte-vs-subquery-vs-temp-table-performance)
10. [Common Interview Questions](#common-interview-questions)
11. [Tips](#tips)

---

## Common Table Expressions (CTEs)

A **Common Table Expression (CTE)** is a named, temporary result set defined within a `WITH` clause. It exists only for the duration of the query it belongs to. CTEs improve readability by breaking complex queries into logical, named blocks.

### Basic Syntax

```sql
WITH cte_name AS (
    SELECT column1, column2
    FROM some_table
    WHERE condition
)
SELECT *
FROM cte_name;
```

### Key Characteristics

- CTEs are **not materialized** by default in Snowflake -- the optimizer may inline them or evaluate them once depending on cost.
- They can reference tables, views, and other CTEs defined earlier in the same `WITH` clause.
- They exist only for the scope of the single SQL statement.
- They can be used in `SELECT`, `INSERT`, `UPDATE`, `DELETE`, and `MERGE` statements.

### Simple Example

```sql
WITH active_customers AS (
    SELECT customer_id, customer_name, region
    FROM customers
    WHERE status = 'ACTIVE'
)
SELECT region, COUNT(*) AS customer_count
FROM active_customers
GROUP BY region
ORDER BY customer_count DESC;
```

---

## Multiple CTEs

You can chain multiple CTEs in a single `WITH` clause, separated by commas. Later CTEs can reference earlier ones.

```sql
WITH
raw_orders AS (
    SELECT order_id, customer_id, order_date, total_amount
    FROM orders
    WHERE order_date >= '2025-01-01'
),
customer_totals AS (
    SELECT
        customer_id,
        COUNT(*) AS order_count,
        SUM(total_amount) AS total_spent
    FROM raw_orders
    GROUP BY customer_id
),
high_value_customers AS (
    SELECT customer_id, order_count, total_spent
    FROM customer_totals
    WHERE total_spent > 10000
)
SELECT
    c.customer_name,
    h.order_count,
    h.total_spent
FROM high_value_customers h
JOIN customers c ON h.customer_id = c.customer_id
ORDER BY h.total_spent DESC;
```

This layered approach makes complex analytical queries much easier to read, debug, and maintain.

---

## Recursive CTEs (WITH RECURSIVE)

Recursive CTEs allow a query to reference itself, enabling traversal of hierarchical or graph-like data structures. Snowflake supports the `WITH RECURSIVE` syntax per the SQL standard.

### Syntax

```sql
WITH RECURSIVE cte_name (col1, col2, ...) AS (
    -- Anchor member: the starting point (non-recursive)
    SELECT col1, col2, ...
    FROM base_table
    WHERE start_condition

    UNION ALL

    -- Recursive member: references the CTE itself
    SELECT t.col1, t.col2, ...
    FROM base_table t
    JOIN cte_name c ON t.parent_col = c.child_col
)
SELECT * FROM cte_name;
```

### How It Works

1. **Anchor member** executes first and produces the initial result set (iteration 0).
2. **Recursive member** executes repeatedly, joining back to the CTE's own output from the previous iteration.
3. Recursion terminates when the recursive member returns zero rows.
4. The final result is the `UNION ALL` of all iterations.

### Important Constraints

- Snowflake enforces a default maximum recursion depth. You can control it with the `MAX_RECURSIONS` parameter (session-level) or rely on the default limit to prevent infinite loops.
- The recursive member cannot contain aggregate functions, window functions, `LIMIT`, or `DISTINCT` (applied to the recursive reference).
- Use `UNION ALL` (not `UNION`) between anchor and recursive members.

### Org Chart Example

```sql
-- Table: employees (employee_id, employee_name, manager_id)

WITH RECURSIVE org_chart (employee_id, employee_name, manager_id, level, path) AS (
    -- Anchor: CEO / top-level (no manager)
    SELECT
        employee_id,
        employee_name,
        manager_id,
        0 AS level,
        employee_name::VARCHAR AS path
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    -- Recursive: find direct reports of current level
    SELECT
        e.employee_id,
        e.employee_name,
        e.manager_id,
        oc.level + 1,
        oc.path || ' > ' || e.employee_name
    FROM employees e
    JOIN org_chart oc ON e.manager_id = oc.employee_id
)
SELECT
    REPEAT('  ', level) || employee_name AS indented_name,
    level,
    path
FROM org_chart
ORDER BY path;
```

**Sample Output:**

| indented_name | level | path |
|---|---|---|
| Alice | 0 | Alice |
| &nbsp;&nbsp;Bob | 1 | Alice > Bob |
| &nbsp;&nbsp;&nbsp;&nbsp;Diana | 2 | Alice > Bob > Diana |
| &nbsp;&nbsp;Carol | 1 | Alice > Carol |

---

## CONNECT BY (Legacy Syntax)

Snowflake also supports Oracle-style `CONNECT BY` syntax for hierarchical queries. While functional, **recursive CTEs are preferred** as they are SQL-standard and more flexible.

### Syntax

```sql
SELECT
    employee_id,
    employee_name,
    manager_id,
    LEVEL AS depth
FROM employees
START WITH manager_id IS NULL
CONNECT BY PRIOR employee_id = manager_id
ORDER BY depth, employee_name;
```

### Key Keywords

| Keyword | Description |
|---|---|
| `START WITH` | Defines the root rows (anchor condition) |
| `CONNECT BY` | Defines the parent-child join relationship |
| `PRIOR` | Refers to the parent row in the hierarchy |
| `LEVEL` | Pseudo-column indicating the depth (1-based) |
| `SYS_CONNECT_BY_PATH(col, sep)` | Builds the full path from root to current node |
| `CONNECT_BY_ROOT col` | Returns the value of `col` for the root ancestor |

### Example with Path

```sql
SELECT
    employee_id,
    employee_name,
    LEVEL AS depth,
    SYS_CONNECT_BY_PATH(employee_name, ' / ') AS full_path
FROM employees
START WITH manager_id IS NULL
CONNECT BY PRIOR employee_id = manager_id;
```

### When to Use CONNECT BY vs Recursive CTE

| Aspect | CONNECT BY | Recursive CTE |
|---|---|---|
| SQL Standard | No (Oracle extension) | Yes |
| Flexibility | Limited to simple hierarchies | Handles graphs, multi-join recursion |
| Cycle detection | `NOCYCLE` keyword | Manual (track visited nodes in path) |
| Portability | Snowflake, Oracle only | Most modern databases |
| Recommendation | Legacy compatibility | **Preferred approach** |

---

## LATERAL Joins

A **LATERAL join** allows the right-hand side of a join to reference columns from the left-hand side. This is conceptually like a correlated subquery, but it can return multiple columns and rows.

### Syntax

```sql
SELECT t1.col, t2.col
FROM table1 t1,
    LATERAL (
        SELECT col
        FROM table2
        WHERE table2.fk = t1.pk  -- references left-hand side
        ORDER BY some_col DESC
        LIMIT 3
    ) t2;
```

### Key Points

- The subquery inside `LATERAL` is evaluated **once per row** from the left-hand table.
- If the lateral subquery returns zero rows, the left-hand row is excluded (like an inner join). Use `LEFT JOIN LATERAL ... ON TRUE` to preserve all left rows.

### Example: Top 3 Orders per Customer

```sql
SELECT
    c.customer_id,
    c.customer_name,
    recent.order_id,
    recent.order_date,
    recent.total_amount
FROM customers c,
    LATERAL (
        SELECT order_id, order_date, total_amount
        FROM orders o
        WHERE o.customer_id = c.customer_id
        ORDER BY o.order_date DESC
        LIMIT 3
    ) recent
ORDER BY c.customer_id, recent.order_date DESC;
```

### LEFT JOIN LATERAL

```sql
SELECT
    c.customer_id,
    c.customer_name,
    recent.order_id
FROM customers c
LEFT JOIN LATERAL (
    SELECT order_id
    FROM orders o
    WHERE o.customer_id = c.customer_id
    ORDER BY o.order_date DESC
    LIMIT 1
) recent ON TRUE;
```

This preserves customers who have no orders (with `NULL` for `order_id`).

---

## LATERAL FLATTEN Pattern

The most common use of `LATERAL` in Snowflake is pairing it with `FLATTEN` to explode arrays or objects stored in semi-structured data (VARIANT, ARRAY, OBJECT columns).

### Basic Pattern

```sql
SELECT
    t.id,
    f.value AS element
FROM my_table t,
    LATERAL FLATTEN(input => t.array_column) f;
```

### FLATTEN Output Columns

| Column | Description |
|---|---|
| `SEQ` | Sequence number for the row from the source |
| `KEY` | Key name (for objects) or index (for arrays) |
| `PATH` | Full path to the element |
| `INDEX` | Array index (0-based) |
| `VALUE` | The element value (VARIANT) |
| `THIS` | The input value that was flattened |

### Nested Flatten

```sql
-- JSON: {"order_id": 1, "items": [{"sku": "A", "qty": 2}, {"sku": "B", "qty": 1}]}
SELECT
    raw.id,
    raw.data:order_id::INT AS order_id,
    item.value:sku::STRING AS sku,
    item.value:qty::INT AS qty
FROM raw_json_table raw,
    LATERAL FLATTEN(input => raw.data:items) item;
```

### OUTER => TRUE

By default, `FLATTEN` skips rows where the input is `NULL` or an empty array. Use `OUTER => TRUE` to preserve those rows (similar to an outer join).

```sql
SELECT
    t.id,
    f.value AS tag
FROM products t,
    LATERAL FLATTEN(input => t.tags, OUTER => TRUE) f;
```

### Recursive Flatten

To flatten deeply nested structures in one pass, use the `RECURSIVE` parameter:

```sql
SELECT
    f.key,
    f.path,
    f.value
FROM my_table t,
    LATERAL FLATTEN(input => t.nested_json, RECURSIVE => TRUE) f
WHERE TYPEOF(f.value) != 'OBJECT'
  AND TYPEOF(f.value) != 'ARRAY';
```

This recursively descends into all nested objects and arrays, producing a leaf-level row for every scalar value.

---

## Table Functions with LATERAL

LATERAL is also used to call table functions that depend on columns from the left-hand table. Snowflake has several built-in table functions that benefit from this.

### SPLIT_TO_TABLE

```sql
SELECT
    t.id,
    s.value AS tag
FROM my_table t,
    LATERAL SPLIT_TO_TABLE(t.csv_tags, ',') s;
```

### GENERATOR with LATERAL

```sql
-- Generate a row for each day in a range per record
SELECT
    r.id,
    r.start_date,
    DATEADD('day', g.seq4(), r.start_date) AS generated_date
FROM ranges r,
    LATERAL (
        SELECT SEQ4() AS seq4
        FROM TABLE(GENERATOR(ROWCOUNT => DATEDIFF('day', r.start_date, r.end_date) + 1))
    ) g;
```

### User-Defined Table Functions (UDTFs) with LATERAL

```sql
SELECT
    o.order_id,
    details.*
FROM orders o,
    LATERAL my_udtf(o.order_id, o.data) details;
```

---

## Practical Examples

### Bill of Materials (BOM) Explosion

A bill of materials is a classic recursive structure where assemblies contain sub-assemblies and raw parts.

```sql
-- Table: bom (parent_part_id, child_part_id, quantity)
-- Table: parts (part_id, part_name, unit_cost)

WITH RECURSIVE bom_explosion (part_id, part_name, quantity, level, root_assembly) AS (
    -- Anchor: top-level assemblies
    SELECT
        b.child_part_id AS part_id,
        p.part_name,
        b.quantity,
        1 AS level,
        b.parent_part_id AS root_assembly
    FROM bom b
    JOIN parts p ON b.child_part_id = p.part_id
    WHERE b.parent_part_id = 'ASSEMBLY-001'  -- starting assembly

    UNION ALL

    -- Recursive: explode sub-assemblies
    SELECT
        b.child_part_id,
        p.part_name,
        be.quantity * b.quantity,  -- accumulated quantity
        be.level + 1,
        be.root_assembly
    FROM bom b
    JOIN bom_explosion be ON b.parent_part_id = be.part_id
    JOIN parts p ON b.child_part_id = p.part_id
)
SELECT
    REPEAT('  ', level) || part_name AS indented_part,
    quantity AS total_qty,
    level
FROM bom_explosion
ORDER BY level, part_name;
```

### Category Tree (Breadcrumb Generation)

```sql
WITH RECURSIVE category_tree AS (
    SELECT
        category_id,
        category_name,
        parent_category_id,
        category_name::VARCHAR(1000) AS breadcrumb
    FROM categories
    WHERE parent_category_id IS NULL

    UNION ALL

    SELECT
        c.category_id,
        c.category_name,
        c.parent_category_id,
        ct.breadcrumb || ' > ' || c.category_name
    FROM categories c
    JOIN category_tree ct ON c.parent_category_id = ct.category_id
)
SELECT category_id, category_name, breadcrumb
FROM category_tree
ORDER BY breadcrumb;
```

### Running Totals via Recursive CTE (Illustrative)

While window functions are better for running totals, this shows CTE flexibility:

```sql
WITH RECURSIVE running AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY txn_date) AS rn,
        txn_date,
        amount,
        amount AS running_total
    FROM transactions
    WHERE rn = 1  -- pseudo; actual implementation would use a numbered CTE

    UNION ALL

    SELECT
        t.rn,
        t.txn_date,
        t.amount,
        r.running_total + t.amount
    FROM numbered_txns t
    JOIN running r ON t.rn = r.rn + 1
)
SELECT * FROM running;
```

> **Note:** In practice, use `SUM(...) OVER (ORDER BY ...)` for running totals. This example is for understanding recursion mechanics.

---

## CTE vs Subquery vs Temp Table Performance

### Comparison

| Aspect | CTE | Inline Subquery | Temporary Table |
|---|---|---|---|
| **Materialization** | Optimizer decides (usually inlined) | Optimizer decides | Always materialized to storage |
| **Reuse** | Referenced multiple times by name | Must duplicate SQL text | Referenced multiple times |
| **Readability** | High | Low for complex queries | High (separate statements) |
| **Performance (single use)** | Same as subquery | Same as CTE | Overhead of write + read |
| **Performance (multi-use)** | May re-evaluate per reference | N/A (must copy text) | Evaluated once, read many |
| **Scope** | Single statement | Single statement | Session or transaction |
| **Statistics** | No dedicated stats | No dedicated stats | Has micro-partition metadata |

### When CTEs Re-Evaluate

In Snowflake, if a CTE is referenced multiple times in the same query, the optimizer **may** evaluate it once and cache the result, or it **may** inline it into each reference point. You cannot force materialization. If you need guaranteed single evaluation:

```sql
-- Use a temp table for guaranteed single evaluation
CREATE TEMPORARY TABLE tmp_expensive_calc AS
SELECT ...
FROM ...
WHERE <expensive filter>;

SELECT * FROM tmp_expensive_calc WHERE ...
UNION ALL
SELECT * FROM tmp_expensive_calc WHERE ...;
```

### Best Practices

- **Use CTEs** for readability and when referenced 1-2 times in a statement.
- **Use temp tables** when the result set is expensive to compute and referenced many times, or across multiple statements.
- **Avoid deeply nested subqueries** -- refactor into CTEs for clarity.
- **Profile with EXPLAIN** (`EXPLAIN USING TEXT`) or the Query Profile in the Snowflake UI to see if a CTE is being re-evaluated.

---

## Common Interview Questions

### Q1: What is a CTE and how does it differ from a subquery?

**A:** A CTE (Common Table Expression) is a named temporary result set defined in a `WITH` clause. Unlike a subquery, a CTE can be referenced multiple times by name within the same statement, improving readability and reducing code duplication. Performance-wise, Snowflake's optimizer typically treats single-reference CTEs identically to subqueries. The key difference is organizational -- CTEs break complex logic into named, sequential steps.

### Q2: Explain the two parts of a recursive CTE.

**A:** A recursive CTE has two parts joined by `UNION ALL`:
1. **Anchor member** -- the base case that runs once and provides the initial row set (e.g., root nodes in a hierarchy).
2. **Recursive member** -- references the CTE itself and runs repeatedly. Each iteration operates on the rows produced by the previous iteration. Recursion stops when the recursive member returns zero new rows.

### Q3: How would you prevent infinite loops in a recursive CTE?

**A:** Several strategies:
- **Snowflake's built-in limit** -- there is a default maximum recursion depth.
- **Depth counter** -- add a `level` column and include `WHERE level < N` in the recursive member.
- **Path tracking** -- accumulate visited node IDs in a string/array and add a condition like `WHERE POSITION(node_id IN path) = 0` to skip already-visited nodes.
- **CONNECT BY** syntax offers a `NOCYCLE` keyword for automatic cycle detection.

### Q4: What is a LATERAL join and when would you use it?

**A:** A LATERAL join allows the right-hand subquery to reference columns from the left-hand table, similar to a correlated subquery but capable of returning multiple rows and columns. Common use cases:
- Top-N per group (e.g., latest 3 orders per customer)
- Flattening semi-structured data (`LATERAL FLATTEN`)
- Calling table functions that need per-row input

### Q5: What is the difference between FLATTEN with and without OUTER => TRUE?

**A:** Without `OUTER => TRUE`, if the input to FLATTEN is NULL or an empty array/object, the corresponding row from the left table is excluded from results (inner join semantics). With `OUTER => TRUE`, the left row is preserved and the FLATTEN output columns are NULL (outer join semantics).

### Q6: Can a CTE be used in an UPDATE or DELETE statement?

**A:** Yes. In Snowflake, CTEs can precede `UPDATE`, `DELETE`, and `MERGE` statements:

```sql
WITH duplicates AS (
    SELECT id, ROW_NUMBER() OVER (PARTITION BY email ORDER BY created_at) AS rn
    FROM users
)
DELETE FROM users
WHERE id IN (SELECT id FROM duplicates WHERE rn > 1);
```

### Q7: How does CONNECT BY differ from WITH RECURSIVE?

**A:** `CONNECT BY` is an Oracle-compatible syntax with built-in pseudo-columns (`LEVEL`, `SYS_CONNECT_BY_PATH`, `CONNECT_BY_ROOT`, `NOCYCLE`). `WITH RECURSIVE` is the SQL standard and is more flexible -- it supports arbitrary recursive logic beyond simple parent-child traversals. Snowflake supports both, but `WITH RECURSIVE` is recommended for new development and portability.

### Q8: When should you use a temp table instead of a CTE?

**A:** Use a temp table when:
- The result set is expensive to compute and referenced multiple times (guarantees single evaluation).
- You need to use the result across multiple SQL statements within a session.
- You want Snowflake to gather micro-partition statistics for better downstream join optimization.
- The intermediate result is very large and you want explicit control over its lifecycle.

---

## Tips

1. **Name CTEs descriptively** -- treat them like well-named functions. Names like `active_customers` or `daily_revenue` make the query self-documenting.

2. **Limit recursion depth explicitly** -- always add a safety `level < MAX` condition in recursive CTEs to prevent runaway queries, even if you trust the data.

3. **Use LATERAL FLATTEN for semi-structured data** -- this is the idiomatic Snowflake pattern. Master it, as it appears in nearly every real-world Snowflake pipeline dealing with JSON.

4. **Check the Query Profile** -- when you suspect a CTE is being evaluated multiple times, inspect the Query Profile in the Snowflake UI. Look for duplicate operator subtrees.

5. **CONNECT BY is fine for simple hierarchies** -- if you are migrating Oracle code, `CONNECT BY` works well. For new Snowflake-native development, prefer `WITH RECURSIVE`.

6. **LATERAL is not just for FLATTEN** -- remember you can use LATERAL with any subquery or table function. The "top-N per group" pattern is a powerful and frequently tested use case.

7. **Recursive CTEs have overhead** -- for very deep or wide hierarchies (millions of nodes), consider materializing the hierarchy into a closure table or path-enumeration table for better query performance.

8. **Column naming in recursive CTEs** -- explicitly list column names after the CTE name (`WITH RECURSIVE cte (col1, col2) AS (...)`) to avoid ambiguity between anchor and recursive members.

---
