# Row-Level Security & Dynamic Data Masking

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Row-Level Security (RLS)](#row-level-security-rls)
2. [Security Predicates](#security-predicates)
3. [Filter Predicates vs Block Predicates](#filter-predicates-vs-block-predicates)
4. [Creating Security Policies](#creating-security-policies)
5. [Inline Table-Valued Functions for RLS](#inline-table-valued-functions-for-rls)
6. [RLS Performance Considerations](#rls-performance-considerations)
7. [Dynamic Data Masking (DDM)](#dynamic-data-masking-ddm)
8. [DDM Mask Functions](#ddm-mask-functions)
9. [Limitations of DDM](#limitations-of-ddm)
10. [DDM vs RLS vs Column Encryption Comparison](#ddm-vs-rls-vs-column-encryption-comparison)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips](#tips)

---

## Row-Level Security (RLS)

Row-Level Security (RLS), introduced in SQL Server 2016, enables fine-grained access control over rows in a database table based on the characteristics of the user executing a query. Rather than filtering data in application code or views, RLS enforces access restrictions transparently at the database engine level.

### Key Characteristics

- **Transparent to the application**: Queries do not need modification; the security policy is applied automatically.
- **Centralized logic**: Access control lives in the database, not scattered across application tiers.
- **Works with all access paths**: Whether data is accessed through ad-hoc queries, stored procedures, or reporting tools, RLS is enforced.
- **Schema-bound**: The predicate function and security policy are schema-bound objects.

### How It Works

RLS uses two components:

1. **Predicate Function** - An inline table-valued function (iTVF) that returns 1 (allow) or 0 (deny) for each row.
2. **Security Policy** - Binds the predicate function to a table and specifies the type of predicate.

```sql
-- Basic architecture flow:
-- User executes SELECT on Table
--   -> Security Policy intercepts
--     -> Predicate Function evaluates each row
--       -> Only rows returning 1 are visible
```

---

## Security Predicates

Security predicates are the inline table-valued functions that define the logic for row-level filtering. They accept parameters that correspond to columns in the protected table and return a table with a single row (allowing access) or no rows (denying access).

```sql
-- Example: Predicate function that filters by SalesRegion
CREATE FUNCTION Security.fn_SalesRegionPredicate
(
    @SalesRegion NVARCHAR(50)
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT 1 AS fn_result
    WHERE @SalesRegion = USER_NAME()
       OR USER_NAME() = 'Manager'       -- Managers see all regions
       OR IS_MEMBER('db_owner') = 1     -- db_owner bypasses RLS
);
```

### Common Predicate Patterns

| Pattern | Description |
|---------|-------------|
| User-based | Filter by `USER_NAME()`, `SUSER_SNAME()`, or `SESSION_CONTEXT` |
| Role-based | Use `IS_MEMBER()` to check role membership |
| Tenant-based | Multi-tenant isolation using a `TenantId` column |
| Hierarchical | Managers see their subordinates' data using recursive lookups |

---

## Filter Predicates vs Block Predicates

RLS supports two types of predicates that serve different purposes:

### Filter Predicates

Filter predicates **silently exclude** rows that do not satisfy the predicate from `SELECT` results and `UPDATE`/`DELETE` operations. The user never receives an error; they simply do not see unauthorized rows.

```sql
-- Filter predicate: Users only see their own orders
CREATE SECURITY POLICY Sales.OrdersPolicy
ADD FILTER PREDICATE Security.fn_OrdersPredicate(SalesRepId)
ON Sales.Orders
WITH (STATE = ON);
```

**Behavior:**
- `SELECT` - Unauthorized rows are invisible.
- `UPDATE` - Cannot update rows the user cannot see.
- `DELETE` - Cannot delete rows the user cannot see.
- `INSERT` - Filter predicates do NOT restrict inserts.

### Block Predicates

Block predicates **explicitly block** write operations that violate the predicate, raising an error.

```sql
-- Block predicate: Prevent inserting rows for other regions
CREATE SECURITY POLICY Sales.OrdersPolicy
ADD FILTER PREDICATE Security.fn_OrdersPredicate(SalesRepId)
    ON Sales.Orders,
ADD BLOCK PREDICATE Security.fn_OrdersPredicate(SalesRepId)
    ON Sales.Orders AFTER INSERT,
ADD BLOCK PREDICATE Security.fn_OrdersPredicate(SalesRepId)
    ON Sales.Orders AFTER UPDATE
WITH (STATE = ON);
```

**Block Predicate Sub-Types:**

| Type | Applies To | Behavior |
|------|-----------|----------|
| `AFTER INSERT` | INSERT | Prevents inserting rows that would be invisible to the user |
| `AFTER UPDATE` | UPDATE | Prevents updating rows to values that would become invisible |
| `BEFORE UPDATE` | UPDATE | Prevents updating rows that are currently invisible (redundant with filter) |
| `BEFORE DELETE` | DELETE | Prevents deleting rows matching the predicate |

### Key Difference Summary

| Aspect | Filter Predicate | Block Predicate |
|--------|-----------------|-----------------|
| Applies to reads | Yes | No |
| Applies to writes | Indirectly (through invisibility) | Yes, explicitly |
| Error on violation | No (silent filtering) | Yes (raises error) |
| Typical use | Restricting visibility | Preventing unauthorized data modification |

---

## Creating Security Policies

### Step-by-Step Implementation

#### Step 1: Create a Schema for Security Objects

```sql
CREATE SCHEMA Security;
GO
```

#### Step 2: Create the Predicate Function

```sql
-- Multi-tenant isolation example
CREATE FUNCTION Security.fn_TenantPredicate
(
    @TenantId INT
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT 1 AS fn_result
    WHERE @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT)
);
GO
```

#### Step 3: Create the Security Policy

```sql
CREATE SECURITY POLICY Security.TenantPolicy
ADD FILTER PREDICATE Security.fn_TenantPredicate(TenantId)
    ON dbo.Customers,
ADD FILTER PREDICATE Security.fn_TenantPredicate(TenantId)
    ON dbo.Orders,
ADD BLOCK PREDICATE Security.fn_TenantPredicate(TenantId)
    ON dbo.Customers AFTER INSERT,
ADD BLOCK PREDICATE Security.fn_TenantPredicate(TenantId)
    ON dbo.Orders AFTER INSERT
WITH (STATE = ON, SCHEMABINDING = ON);
GO
```

#### Step 4: Set Session Context in Application

```sql
-- Application sets tenant context on connection
EXEC sp_set_session_context @key = N'TenantId', @value = 42;

-- Now all queries against Customers and Orders are automatically
-- filtered to TenantId = 42
SELECT * FROM dbo.Customers;  -- Only sees TenantId = 42 rows
```

### Managing Security Policies

```sql
-- Disable a policy (for maintenance or debugging)
ALTER SECURITY POLICY Security.TenantPolicy WITH (STATE = OFF);

-- Re-enable
ALTER SECURITY POLICY Security.TenantPolicy WITH (STATE = ON);

-- Add a predicate to an additional table
ALTER SECURITY POLICY Security.TenantPolicy
ADD FILTER PREDICATE Security.fn_TenantPredicate(TenantId)
    ON dbo.Invoices;

-- Remove a predicate from a table
ALTER SECURITY POLICY Security.TenantPolicy
DROP FILTER PREDICATE ON dbo.Invoices;

-- Drop the policy entirely
DROP SECURITY POLICY Security.TenantPolicy;

-- View existing policies
SELECT * FROM sys.security_policies;
SELECT * FROM sys.security_predicates;
```

---

## Inline Table-Valued Functions for RLS

The predicate function **must** be an inline table-valued function (iTVF). Multi-statement TVFs and scalar functions are not supported.

### Why Inline TVFs?

- They are inlined into the query plan, allowing the optimizer to treat the predicate as part of the overall query.
- They enable better performance because the engine can push predicates down and combine them with existing filters.

### Advanced Predicate Function Examples

#### Hierarchical Access (Manager Sees Team Data)

```sql
CREATE FUNCTION Security.fn_ManagerHierarchyPredicate
(
    @EmployeeId INT
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT 1 AS fn_result
    WHERE @EmployeeId = (
        SELECT EmployeeId FROM dbo.Employees
        WHERE LoginName = USER_NAME()
    )
    OR @EmployeeId IN (
        SELECT EmployeeId FROM dbo.Employees
        WHERE ManagerId = (
            SELECT EmployeeId FROM dbo.Employees
            WHERE LoginName = USER_NAME()
        )
    )
    OR IS_MEMBER('db_owner') = 1
);
```

#### Time-Based Access (Only Current Period Data)

```sql
CREATE FUNCTION Security.fn_CurrentPeriodPredicate
(
    @EffectiveDate DATE,
    @ExpirationDate DATE
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT 1 AS fn_result
    WHERE GETDATE() BETWEEN @EffectiveDate AND @ExpirationDate
       OR IS_MEMBER('HistoricalDataViewers') = 1
);
```

#### Lookup Table-Based Access

```sql
-- Access controlled via a mapping table
CREATE FUNCTION Security.fn_RegionAccessPredicate
(
    @RegionId INT
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT 1 AS fn_result
    FROM dbo.UserRegionAccess ura
    WHERE ura.RegionId = @RegionId
      AND ura.UserName = USER_NAME()
);
```

---

## RLS Performance Considerations

RLS adds a predicate evaluation to every query against the protected table. Understanding the performance implications is critical for a senior engineer.

### Performance Impact Areas

1. **Predicate Complexity**: Simple equality checks are cheap; joins to lookup tables add overhead.
2. **Index Support**: Ensure the filtered column is indexed. Without an index, the predicate forces a table scan.
3. **Plan Cache**: RLS predicates are embedded in the query plan. Different users may get different plans if parameter sniffing is involved.
4. **Cardinality Estimation**: The optimizer may struggle to estimate selectivity for predicate functions, especially with `SESSION_CONTEXT`.

### Best Practices for Performance

```sql
-- DO: Keep predicate functions simple
CREATE FUNCTION Security.fn_SimplePredicate(@TenantId INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN (
    SELECT 1 AS fn_result
    WHERE @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT)
);

-- AVOID: Complex subqueries or multi-join predicates
-- If you must use a lookup table, ensure it is small and well-indexed
```

**Performance Tips:**

| Tip | Explanation |
|-----|-------------|
| Index the predicate column | Critical for filter pushdown; e.g., index on `TenantId` |
| Minimize predicate function complexity | Every row evaluation calls the function |
| Use `SESSION_CONTEXT` over `USER_NAME()` | `SESSION_CONTEXT` is cheaper and more flexible |
| Test with execution plans | Check for unexpected scans or spools |
| Consider statistics on the predicate column | Helps the optimizer with cardinality estimates |
| Avoid cross-database references | Not supported and would break schemabinding |
| Beware of side-channel attacks | Users can infer hidden data through error messages or timing |

### Monitoring RLS Impact

```sql
-- Check execution plans for the predicate function
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT * FROM dbo.Orders;  -- RLS is transparently applied

-- Look for the predicate in the XML plan
-- The filter will appear as a nested loop or filter operator
```

---

## Dynamic Data Masking (DDM)

Dynamic Data Masking (DDM), also introduced in SQL Server 2016, provides a way to limit sensitive data exposure by masking it to non-privileged users. Unlike encryption, the data is stored in clear text; the mask is applied at query time in the presentation layer.

### Key Characteristics

- **No storage impact**: Data is stored unmasked; masking is applied on read.
- **Transparent to applications**: Existing queries work without modification.
- **Column-level**: Applied to specific columns.
- **Reversible**: Users with `UNMASK` permission see the real data.
- **Not a security boundary**: DDM is an obfuscation feature, not a true security control.

### Granting and Revoking UNMASK Permission

```sql
-- Grant UNMASK to a specific user
GRANT UNMASK TO DataAnalyst;

-- Revoke UNMASK
REVOKE UNMASK FROM DataAnalyst;

-- SQL Server 2022+: Granular UNMASK at column/table/schema level
GRANT UNMASK ON dbo.Employees(SSN) TO HRUser;
GRANT UNMASK ON SCHEMA::HR TO HRManager;
```

---

## DDM Mask Functions

SQL Server provides four built-in mask functions:

### 1. Default Mask

Applies full masking according to the data type.

| Data Type | Masked Value |
|-----------|-------------|
| String types | `XXXX` (or fewer X's if length < 4) |
| Numeric types | `0` |
| Date/Time types | `1900-01-01 00:00:00.0000000` |
| Binary types | `0x00` |

```sql
-- Apply default mask
ALTER TABLE dbo.Employees
ALTER COLUMN SSN NVARCHAR(11) MASKED WITH (FUNCTION = 'default()');

-- Result for non-privileged user:
-- SSN: 'XXXX'
```

### 2. Email Mask

Exposes the first character, replaces the middle with `XXX`, and preserves the domain suffix.

```sql
ALTER TABLE dbo.Employees
ALTER COLUMN Email NVARCHAR(100) MASKED WITH (FUNCTION = 'email()');

-- Input:  'john.doe@company.com'
-- Output: 'jXXX@XXXX.com'
```

### 3. Random Mask

Replaces numeric values with a random number within a specified range.

```sql
ALTER TABLE dbo.Transactions
ALTER COLUMN Amount DECIMAL(18,2) MASKED WITH (FUNCTION = 'random(1, 1000)');

-- Input:  49872.50
-- Output: 347.00  (random value between 1 and 1000)
```

### 4. Custom (Partial) Mask

Allows control over how many characters to expose at the beginning and end, and what padding string to use in the middle.

```sql
-- Syntax: partial(prefix_count, padding, suffix_count)
ALTER TABLE dbo.Employees
ALTER COLUMN PhoneNumber NVARCHAR(15)
    MASKED WITH (FUNCTION = 'partial(3, "XXX-XXXX", 0)');

-- Input:  '555-867-5309'
-- Output: '555XXX-XXXX'

-- Show last 4 digits of SSN
ALTER TABLE dbo.Employees
ALTER COLUMN SSN NVARCHAR(11)
    MASKED WITH (FUNCTION = 'partial(0, "XXX-XX-", 4)');

-- Input:  '123-45-6789'
-- Output: 'XXX-XX-6789'
```

### Creating a Table with Masks

```sql
CREATE TABLE dbo.Customers
(
    CustomerId    INT IDENTITY(1,1) PRIMARY KEY,
    FirstName     NVARCHAR(50),
    LastName      NVARCHAR(50),
    Email         NVARCHAR(100) MASKED WITH (FUNCTION = 'email()'),
    PhoneNumber   NVARCHAR(15)  MASKED WITH (FUNCTION = 'partial(0, "XXX-XXX-", 4)'),
    CreditScore   INT           MASKED WITH (FUNCTION = 'random(300, 850)'),
    AccountNumber NVARCHAR(20)  MASKED WITH (FUNCTION = 'default()')
);
```

### Removing a Mask

```sql
ALTER TABLE dbo.Customers
ALTER COLUMN Email NVARCHAR(100);
-- Simply redefine the column without the MASKED clause
```

### Querying Masked Column Metadata

```sql
SELECT
    t.name AS TableName,
    c.name AS ColumnName,
    mc.masking_function
FROM sys.masked_columns mc
JOIN sys.columns c ON mc.object_id = c.object_id AND mc.column_id = c.column_id
JOIN sys.tables t ON c.object_id = t.object_id;
```

---

## Limitations of DDM

Understanding DDM limitations is critical for interviews, as it helps demonstrate deep knowledge:

1. **Not a true security feature**: Users can potentially infer masked values through brute-force queries, `WHERE` clause filtering, or `CASE` expressions.

    ```sql
    -- An attacker can infer the value by iterating:
    SELECT * FROM dbo.Customers WHERE Email LIKE 'a%';
    SELECT * FROM dbo.Customers WHERE Email LIKE 'b%';
    -- The actual data is used in filtering, not the masked version
    ```

2. **Cannot mask computed columns**: DDM cannot be applied to computed columns.

3. **Cannot mask columns with FILESTREAM**: FILESTREAM columns are not supported.

4. **Cannot mask columns used in full-text index**: Full-text indexed columns cannot be masked.

5. **Masked columns can be part of indexes**: But the index does not mask the data in internal structures.

6. **SELECT INTO and INSERT ... SELECT copy unmasked values**: If a user with UNMASK runs `SELECT INTO`, the destination table contains unmasked data.

7. **Bulk operations bypass masking**: `BULK INSERT` and `bcp` work with the raw data.

8. **No support for Always Encrypted columns**: Cannot combine DDM with Always Encrypted on the same column.

9. **DBCC SHOW_STATISTICS reveals unmasked data**: Statistics histograms may expose actual values.

---

## DDM vs RLS vs Column Encryption Comparison

| Feature | Dynamic Data Masking | Row-Level Security | Always Encrypted / TDE |
|---------|--------------------|--------------------|----------------------|
| **Granularity** | Column-level (presentation) | Row-level (access) | Column-level (storage) or Database-level (TDE) |
| **Data at rest** | Unmasked (clear text) | Unaffected (all rows stored) | Encrypted |
| **Data in transit** | Masked at presentation layer | Filtered before transmission | Encrypted (Always Encrypted) |
| **Bypass risk** | High (WHERE clause inference) | Low (engine-enforced) | Very low (keys required) |
| **Performance impact** | Minimal | Moderate (predicate eval per row) | Significant (encrypt/decrypt ops) |
| **Use case** | Obfuscation for ad-hoc users | Multi-tenant isolation, role-based row access | Regulatory compliance, sensitive PII |
| **DBA can see data?** | Yes (DBA has UNMASK by default) | Depends on policy design | No (Always Encrypted); Yes (TDE) |
| **Application changes** | None | None (or minimal for SESSION_CONTEXT) | Driver changes required (Always Encrypted) |
| **SQL Server version** | 2016+ | 2016+ | TDE: 2008+; Always Encrypted: 2016+ |
| **Security level** | Low (obfuscation) | High (access control) | Very high (cryptographic) |

### When to Use Each

- **DDM**: Quick obfuscation for non-technical users, demo environments, limiting casual exposure.
- **RLS**: Multi-tenant applications, role-based data isolation, regulatory row-level access control.
- **Always Encrypted**: Protecting data from DBAs, meeting strict compliance requirements (PCI-DSS, HIPAA).
- **TDE**: Protecting against physical media theft; encrypts the entire database at rest.

**They are complementary**: You can use RLS + DDM + TDE together for defense in depth.

---

## Common Interview Questions

### Q1: What is the difference between RLS Filter Predicates and Block Predicates?

**A:** Filter predicates silently exclude rows from `SELECT`, `UPDATE`, and `DELETE` results without raising errors -- the user simply does not see unauthorized rows. Block predicates explicitly prevent write operations (`INSERT`, `UPDATE`, `DELETE`) that would violate the security policy, raising an error when a violation is attempted. You typically use both together: a filter predicate to limit visibility and block predicates to prevent users from inserting or updating data they should not own.

### Q2: Can a user with db_owner role bypass RLS?

**A:** By default, no. RLS is enforced even for `db_owner` unless the predicate function explicitly grants access to `db_owner` (e.g., via `IS_MEMBER('db_owner') = 1`). However, `sysadmin` members can alter or drop the security policy. This is a common point of confusion in interviews.

### Q3: Is Dynamic Data Masking a security feature?

**A:** DDM is officially categorized as an obfuscation feature, not a security boundary. A determined user can infer masked data through `WHERE` clause probing, aggregate functions, or by using `SELECT INTO` to create a copy. For true data protection, Always Encrypted or column-level encryption should be used. DDM is best suited for limiting casual exposure to non-technical users.

### Q4: How would you implement multi-tenant row isolation in SQL Server?

**A:** Use RLS with `SESSION_CONTEXT`:
1. Create an inline TVF that compares the table's `TenantId` column against `SESSION_CONTEXT(N'TenantId')`.
2. Create a security policy with both filter and block predicates on all tenant-scoped tables.
3. In the application connection layer, call `sp_set_session_context @key = N'TenantId', @value = <id>` immediately after connection open.
4. Index the `TenantId` column on every table for performance.

This approach is transparent to application queries and centralizes access control in the database.

### Q5: What are the performance implications of RLS, and how do you mitigate them?

**A:** RLS adds a predicate evaluation on every row access. Performance concerns include:
- **Predicate function complexity**: Keep functions simple; avoid joins to large tables.
- **Missing indexes**: Always index the column used in the predicate.
- **Cardinality estimation**: The optimizer may underestimate filtered row counts. Use statistics and test with actual execution plans.
- **Plan cache bloat**: If using `USER_NAME()`, different users can generate different plans. `SESSION_CONTEXT` can help since the optimizer treats it as a runtime constant.

Mitigation: benchmark with realistic data volumes, monitor execution plans, and keep the predicate function as a simple equality check where possible.

### Q6: Can you use DDM and RLS together on the same table?

**A:** Yes. They serve different purposes and are fully compatible. RLS controls which rows a user can see, while DDM controls how column values appear. For example, a sales representative might see only their region's customers (RLS) with credit card numbers partially masked (DDM).

### Q7: How does SQL Server 2022 improve DDM?

**A:** SQL Server 2022 introduced **granular UNMASK permissions**, allowing administrators to grant `UNMASK` at the column, table, or schema level instead of the database-wide permission available in earlier versions. This significantly improves the usefulness of DDM in multi-role environments.

---

## Tips

- **Always test RLS with multiple user contexts** using `EXECUTE AS USER` and `REVERT` to validate predicate behavior before deploying.
- **Document your predicate functions** clearly. Since RLS is transparent, it can be confusing to troubleshoot when developers do not realize it is active.
- **Do not rely on DDM for security-sensitive data**. Treat it as a UI convenience, not a security control. Pair it with other measures.
- **Use SESSION_CONTEXT over USER_NAME() for multi-tenant RLS**. It is more flexible (works with connection pooling) and better for performance.
- **Remember that RLS does not protect against side-channel attacks**. A user might infer row existence through error messages, timing, or foreign key violations.
- **Index the predicate column**. This single action has the largest impact on RLS performance.
- **When upgrading to SQL Server 2022**, review DDM configurations to take advantage of granular UNMASK permissions.
- **Combine RLS + DDM + TDE** for a layered security approach: row isolation, column obfuscation, and encryption at rest.

---
