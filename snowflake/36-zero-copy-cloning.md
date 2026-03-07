# Zero-Copy Cloning

[Back to Snowflake Index](./README.md)

---

## Overview

Zero-Copy Cloning is one of Snowflake's most powerful features, allowing you to create instant copies of databases, schemas, tables, and other objects **without duplicating the underlying data**. The clone is a metadata-only operation that references the same micro-partitions as the source, making it extremely fast and initially cost-free from a storage perspective.

---

## Key Concepts

### What is Zero-Copy Cloning?

When you clone an object in Snowflake, the system creates a new object with its own metadata that **points to the same underlying micro-partitions** as the source. No physical data is copied at clone time.

```
Source Table (Table A)
  └── Points to micro-partitions: [P1, P2, P3, P4, P5]

Clone (Table B) -- created via CLONE
  └── Points to micro-partitions: [P1, P2, P3, P4, P5]  (same partitions!)
```

### Metadata-Only Operation

- The clone operation copies only the **metadata** (structure, pointers to micro-partitions)
- The actual data files (micro-partitions) are **shared** between source and clone
- Clone creation is nearly **instantaneous** regardless of data size
- A 10 TB table clones in seconds, not hours

### Storage Costs: Pay Only for Changes

After cloning, storage costs are incurred **only for data that diverges** between the source and clone:

```
Initial state: 0 additional storage (shared micro-partitions)

After INSERT into clone:
  - New micro-partitions created → you pay for those new partitions only

After UPDATE on clone:
  - Modified micro-partitions are rewritten as new partitions
  - Original partitions still shared with source
  - You pay only for the new/modified partitions

After DELETE on clone:
  - Micro-partitions with deleted rows are rewritten
  - You pay for the rewritten partitions
```

### Clone Independence

Once cloned, the source and clone are **completely independent**:

- Changes to the clone do NOT affect the source
- Changes to the source do NOT affect the clone
- Dropping the source does NOT drop the clone (data referenced only by the clone is retained)
- Each object maintains its own Time Travel history independently

---

## Cloneable Objects

### Tables

```sql
CREATE TABLE orders_dev CLONE orders;

-- Clone with Time Travel (point-in-time)
CREATE TABLE orders_backup CLONE orders
  AT(TIMESTAMP => '2026-03-01 08:00:00'::TIMESTAMP_LTZ);

-- Clone using offset
CREATE TABLE orders_backup CLONE orders
  AT(OFFSET => -3600);  -- 1 hour ago

-- Clone using statement ID
CREATE TABLE orders_backup CLONE orders
  BEFORE(STATEMENT => '01a1b2c3-0000-1234-0000-00000000abcd');
```

### Schemas

```sql
-- Clones the schema and ALL objects within it
CREATE SCHEMA analytics_dev CLONE analytics;

-- Clone with Time Travel
CREATE SCHEMA analytics_recovery CLONE analytics
  AT(TIMESTAMP => '2026-03-06 12:00:00'::TIMESTAMP_LTZ);
```

### Databases

```sql
-- Clones the entire database: all schemas, tables, views, stages, etc.
CREATE DATABASE production_dev CLONE production;

-- Clone with Time Travel
CREATE DATABASE production_recovery CLONE production
  AT(TIMESTAMP => '2026-03-05 00:00:00'::TIMESTAMP_LTZ);
```

### Other Cloneable Objects

| Object | Cloneable? | Notes |
|--------|-----------|-------|
| Tables | Yes | Including temporary and transient tables |
| Schemas | Yes | Clones all child objects |
| Databases | Yes | Clones all schemas and child objects |
| Internal Stages | Yes | Clones stage definition and staged files |
| File Formats | Yes | As part of schema/database clone |
| Sequences | Yes | Clone gets a separate, independent sequence |
| Streams | Yes | See special behavior below |
| Tasks | Yes | Cloned in suspended state |
| Pipes | Yes | Cloned in paused state |

**Not cloneable individually:** External tables, external stages, shares.

---

## Cloning with Time Travel

One of the most powerful combinations in Snowflake is cloning with Time Travel. This allows you to create a clone of an object **as it existed at a specific point in the past**.

```sql
-- Recover a table that had bad data loaded at a known time
CREATE TABLE customers_clean CLONE customers
  AT(TIMESTAMP => '2026-03-06 09:00:00'::TIMESTAMP_LTZ);

-- Recover from an accidental DELETE
-- Step 1: Clone the table from before the DELETE
CREATE TABLE customers_recovered CLONE customers
  BEFORE(STATEMENT => '<statement-id-of-delete>');

-- Step 2: Swap if needed
ALTER TABLE customers SWAP WITH customers_recovered;
```

### Time Travel + Clone Constraints

- You can only go back as far as your `DATA_RETENTION_TIME_IN_DAYS` setting allows
- Standard edition: up to 1 day
- Enterprise edition and above: up to 90 days
- Transient/temporary tables: up to 1 day regardless of edition

---

## Cloning and Streams

Streams behave specially with cloning:

### Table Cloning with Active Streams

When you clone a **table** that has a stream on it:
- The stream is NOT cloned with the table
- You must create a new stream on the cloned table separately

### Schema/Database Cloning with Streams

When you clone a **schema or database** containing streams:
- Streams are cloned along with the other objects
- The cloned stream references the **cloned table** (not the source table)
- **Important**: If the stream has unconsumed records, the clone of the stream will also have those unconsumed records
- If the source stream's offset is older than the Time Travel retention of the cloned table, the cloned stream becomes **stale**

```sql
-- Clone a schema with streams
CREATE SCHEMA staging_dev CLONE staging;

-- The stream staging_dev.my_stream now tracks changes on staging_dev.my_table
-- NOT on staging.my_table
```

---

## Real-World Use Cases

### 1. Development and Testing Environments

```sql
-- Create a full dev environment from production in seconds
CREATE DATABASE prod_dev CLONE production;

-- Grant access to developers
GRANT USAGE ON DATABASE prod_dev TO ROLE dev_team;
GRANT USAGE ON ALL SCHEMAS IN DATABASE prod_dev TO ROLE dev_team;
GRANT SELECT ON ALL TABLES IN DATABASE prod_dev TO ROLE dev_team;

-- Developers can freely modify without affecting production
-- Drop when done
DROP DATABASE prod_dev;
```

### 2. Backup Before Risky Changes

```sql
-- Before running a large UPDATE or schema migration
CREATE TABLE customers_backup CLONE customers;

-- Run your migration
ALTER TABLE customers ADD COLUMN loyalty_tier STRING;
UPDATE customers SET loyalty_tier =
  CASE
    WHEN total_spend > 10000 THEN 'PLATINUM'
    WHEN total_spend > 5000 THEN 'GOLD'
    ELSE 'SILVER'
  END;

-- If something went wrong:
ALTER TABLE customers SWAP WITH customers_backup;

-- If everything is fine:
DROP TABLE customers_backup;
```

### 3. Data Sandboxing for Analytics

```sql
-- Create a sandbox for a data science team
CREATE SCHEMA analytics_sandbox CLONE analytics_prod;

-- The team can create new tables, modify data, run experiments
-- without impacting production analytics
```

### 4. Reproducible Testing with CI/CD

```sql
-- In a CI/CD pipeline, clone for each test run
CREATE DATABASE test_run_${BUILD_ID} CLONE production;

-- Run integration tests against the clone
-- ...

-- Tear down after tests
DROP DATABASE test_run_${BUILD_ID};
```

### 5. Point-in-Time Snapshots for Auditing

```sql
-- Create monthly snapshots for compliance
CREATE SCHEMA financial_data_2026_02 CLONE financial_data
  AT(TIMESTAMP => '2026-02-28 23:59:59'::TIMESTAMP_LTZ);
```

---

## CREATE ... CLONE Syntax Reference

```sql
-- General syntax
CREATE [ OR REPLACE ] <object_type> [ IF NOT EXISTS ] <object_name>
  CLONE <source_object_name>
  [ { AT | BEFORE } ( { TIMESTAMP => <timestamp> |
                         OFFSET => <time_difference> |
                         STATEMENT => <id> } ) ]
  [ ... ];

-- Table clone
CREATE TABLE <name> CLONE <source_table>
  [AT | BEFORE (...)];

-- Schema clone
CREATE SCHEMA <name> CLONE <source_schema>
  [AT | BEFORE (...)];

-- Database clone
CREATE DATABASE <name> CLONE <source_database>
  [AT | BEFORE (...)];

-- Stage clone (internal named stages only)
CREATE STAGE <name> CLONE <source_stage>;
```

---

## Important Considerations

### Privileges and Cloning

- Cloning a **table**: the clone does NOT inherit grants from the source
- Cloning a **schema or database**: grants on the container are NOT inherited, but grants on child objects within the container ARE cloned
- The user performing the clone must have appropriate privileges on the source object

### Transient and Temporary Tables

- A clone of a permanent table is permanent
- A clone of a transient table is transient
- You can clone a permanent table into a transient one using: `CREATE TRANSIENT TABLE ... CLONE ...`
- You CANNOT clone a transient/temporary table into a permanent one

### Cloning and Data Sharing

- You can clone a shared database that has been shared with your account
- The clone becomes a **local, independent copy** — it is no longer linked to the share

### Monitoring Clone Storage

```sql
-- Check storage usage to see clone-specific costs
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_NAME = 'MY_CLONED_TABLE'
ORDER BY TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME;

-- The ACTIVE_BYTES column shows data owned by this table
-- RETAINED_FOR_CLONE_BYTES shows data kept because a clone references it
```

---

## Common Interview Questions

### Q1: What happens to storage when you clone a table in Snowflake?

**A:** At clone time, no additional storage is consumed because the clone shares the same underlying micro-partitions as the source table. Storage costs only begin when either the source or clone is modified — new or rewritten micro-partitions are charged to the object that caused the change. This is what makes it "zero-copy."

### Q2: If I drop the source table after cloning, what happens to the clone?

**A:** The clone remains fully functional and intact. Snowflake's reference counting ensures that micro-partitions shared between the source and clone are not physically deleted until no object references them. The clone continues to work independently. The storage cost for those shared partitions shifts to the clone.

### Q3: Can you clone a clone?

**A:** Yes. You can clone a clone, creating a chain of clones. Each clone independently references the micro-partitions it needs. The same zero-copy semantics apply — no additional storage until data diverges.

### Q4: How does cloning interact with Time Travel?

**A:** You can create a clone from a historical point in time using the AT or BEFORE clause, effectively restoring data to that point. Additionally, after cloning, the source and clone each maintain their own independent Time Travel history. Time Travel data retention settings are also independent.

### Q5: What are the key differences between cloning and copying data (CTAS)?

**A:**
| Aspect | CLONE | CTAS (CREATE TABLE AS SELECT) |
|--------|-------|-------------------------------|
| Speed | Instant (metadata only) | Proportional to data size |
| Initial Storage | Zero additional | Full copy of data |
| Data Independence | Full independence after clone | Full independence |
| Time Travel Clone | Supported (AT/BEFORE) | Must query with Time Travel in SELECT |
| Schema/DB Level | Can clone entire DB/schema | Table-level only |
| Preserves Clustering | Yes | Must redefine |

### Q6: What objects are NOT cloned when you clone a database?

**A:** External tables, external stages, and shares are not cloned. Also, tasks are cloned in a suspended state and pipes in a paused state — they must be manually resumed.

### Q7: Can you use zero-copy cloning across Snowflake accounts?

**A:** No. Zero-copy cloning works only within the same Snowflake account. For cross-account data sharing, you would use Snowflake's Secure Data Sharing or Replication features instead.

---

## Tips

1. **Use cloning as your first line of backup** before running DDL changes, large DML operations, or schema migrations. It is instant and free until data diverges.

2. **Leverage Time Travel + Clone for recovery** — instead of restoring from external backups, clone the table at the point in time before the issue occurred.

3. **Remember clone storage drift** — over time, as both source and clone are modified, storage costs grow. Monitor and drop clones you no longer need.

4. **Use transient clones for ephemeral environments** — if you are cloning for short-lived dev/test, create transient clones to avoid Fail-safe storage costs.

5. **Be aware of stream staleness** — when cloning schemas or databases with streams, verify that cloned streams have valid offsets and are not stale.

6. **Cloning is recursive for containers** — cloning a database clones all schemas and all objects within them. This is powerful but be mindful of the scope.

7. **In interviews, emphasize the metadata-only nature** — the key insight is that Snowflake's immutable micro-partition architecture makes zero-copy cloning possible. Since micro-partitions are never modified in place, sharing them between objects is safe.

---
