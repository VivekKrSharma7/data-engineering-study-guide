# Advanced T-SQL Programming

[Back to SQL Server Index](./README.md)

---

## Overview

Beyond basic SELECT, INSERT, UPDATE, and DELETE, T-SQL offers a rich set of advanced constructs that enable elegant, performant, and maintainable code. Mastering these features is essential for a senior Data Engineer -- they appear frequently in interview questions and are indispensable in production ETL pipelines, reporting queries, and data transformations.

---

## MERGE Statement

The MERGE statement (sometimes called "upsert") performs INSERT, UPDATE, and DELETE operations in a single atomic statement based on the results of a join between a source and target table.

```sql
MERGE INTO dbo.DimCustomer AS target
USING dbo.StagingCustomer AS source
    ON target.CustomerKey = source.CustomerKey
WHEN MATCHED AND (
    target.CustomerName <> source.CustomerName OR
    target.Email <> source.Email
) THEN
    UPDATE SET
        target.CustomerName = source.CustomerName,
        target.Email = source.Email,
        target.ModifiedDate = SYSDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CustomerKey, CustomerName, Email, CreatedDate)
    VALUES (source.CustomerKey, source.CustomerName, source.Email, SYSDATETIME())
WHEN NOT MATCHED BY SOURCE THEN
    DELETE
OUTPUT
    $action AS merge_action,
    INSERTED.CustomerKey,
    DELETED.CustomerKey;
-- IMPORTANT: MERGE must end with a semicolon
```

**Key points:**
- `WHEN MATCHED` -- source row matches target; typically UPDATE
- `WHEN NOT MATCHED BY TARGET` -- source row has no match in target; typically INSERT
- `WHEN NOT MATCHED BY SOURCE` -- target row has no match in source; typically DELETE or soft-delete
- You can have up to two `WHEN MATCHED` clauses (with different conditions)
- The statement **must** end with a semicolon

**Known issues and cautions:**
- MERGE has had numerous bugs over the years (race conditions, incorrect results under concurrency). Microsoft has fixed many, but some practitioners prefer explicit INSERT/UPDATE/DELETE for critical workloads.
- Always use a `HOLDLOCK` hint on the target when concurrent access is possible to prevent race conditions: `MERGE INTO dbo.Target WITH (HOLDLOCK) AS t`.
- The `ON` clause must not be ambiguous -- it should uniquely identify rows.

---

## OUTPUT Clause

The OUTPUT clause returns data from rows affected by INSERT, UPDATE, DELETE, or MERGE. It uses the `INSERTED` and `DELETED` pseudo-tables (same concept as triggers).

```sql
-- Capture inserted identity values
DECLARE @InsertedIDs TABLE (ID INT, Name NVARCHAR(100));

INSERT INTO dbo.Products (ProductName, Price)
OUTPUT INSERTED.ProductID, INSERTED.ProductName INTO @InsertedIDs
VALUES ('Widget A', 19.99), ('Widget B', 29.99);

SELECT * FROM @InsertedIDs;
```

```sql
-- Capture old and new values during UPDATE
DECLARE @Changes TABLE (
    ProductID INT,
    OldPrice DECIMAL(10,2),
    NewPrice DECIMAL(10,2)
);

UPDATE dbo.Products
SET Price = Price * 1.10
OUTPUT INSERTED.ProductID, DELETED.Price, INSERTED.Price INTO @Changes
WHERE Category = 'Electronics';

SELECT * FROM @Changes;
```

```sql
-- Capture deleted rows for auditing
DELETE FROM dbo.ExpiredSessions
OUTPUT DELETED.SessionID, DELETED.UserName, DELETED.ExpiryDate
    INTO dbo.SessionArchive
WHERE ExpiryDate < DATEADD(DAY, -30, GETDATE());
```

**Use cases:** Audit logging, capturing identity values from inserts, building change data capture (CDC) logic, debugging MERGE operations.

---

## APPLY Operator (CROSS APPLY and OUTER APPLY)

The APPLY operator allows you to invoke a table-valued function (or correlated subquery) for each row from the left table expression.

- **CROSS APPLY** -- like INNER JOIN; excludes left rows where the right side returns no rows
- **OUTER APPLY** -- like LEFT JOIN; includes left rows with NULLs when the right side returns no rows

### With Table-Valued Functions

```sql
-- Inline TVF: Get top 3 orders per customer
CREATE OR ALTER FUNCTION dbo.fnGetTopOrders(@CustomerID INT, @TopN INT)
RETURNS TABLE
AS
RETURN (
    SELECT TOP (@TopN) OrderID, OrderDate, TotalAmount
    FROM dbo.Orders
    WHERE CustomerID = @CustomerID
    ORDER BY TotalAmount DESC
);
GO

-- CROSS APPLY: only customers who have orders
SELECT c.CustomerID, c.CustomerName, o.OrderID, o.TotalAmount
FROM dbo.Customers c
CROSS APPLY dbo.fnGetTopOrders(c.CustomerID, 3) o;

-- OUTER APPLY: all customers, NULLs if no orders
SELECT c.CustomerID, c.CustomerName, o.OrderID, o.TotalAmount
FROM dbo.Customers c
OUTER APPLY dbo.fnGetTopOrders(c.CustomerID, 3) o;
```

### With Subqueries (No Function Needed)

```sql
-- Top N per group without a function
SELECT d.DepartmentName, e.EmployeeName, e.Salary
FROM dbo.Departments d
CROSS APPLY (
    SELECT TOP 3 EmployeeName, Salary
    FROM dbo.Employees
    WHERE DepartmentID = d.DepartmentID
    ORDER BY Salary DESC
) e;
```

### Unpivoting Columns

```sql
-- Unpivot multiple columns using CROSS APPLY + VALUES
SELECT p.ProductID, p.ProductName, x.Period, x.Revenue
FROM dbo.ProductRevenue p
CROSS APPLY (VALUES
    ('Q1', p.Q1_Revenue),
    ('Q2', p.Q2_Revenue),
    ('Q3', p.Q3_Revenue),
    ('Q4', p.Q4_Revenue)
) x(Period, Revenue);
```

---

## PIVOT and UNPIVOT

### PIVOT

Rotates rows into columns, aggregating values.

```sql
-- Sales by product per quarter
SELECT ProductName, [Q1], [Q2], [Q3], [Q4]
FROM (
    SELECT ProductName, Quarter, SalesAmount
    FROM dbo.Sales
) src
PIVOT (
    SUM(SalesAmount) FOR Quarter IN ([Q1], [Q2], [Q3], [Q4])
) pvt;
```

**Limitation:** PIVOT requires hardcoded column names. For dynamic columns, use dynamic SQL:

```sql
DECLARE @columns NVARCHAR(MAX), @sql NVARCHAR(MAX);

SELECT @columns = STRING_AGG(QUOTENAME(Quarter), ', ')
FROM (SELECT DISTINCT Quarter FROM dbo.Sales) q;

SET @sql = N'
SELECT ProductName, ' + @columns + N'
FROM (SELECT ProductName, Quarter, SalesAmount FROM dbo.Sales) src
PIVOT (SUM(SalesAmount) FOR Quarter IN (' + @columns + N')) pvt;';

EXEC sp_executesql @sql;
```

### UNPIVOT

Rotates columns into rows.

```sql
SELECT ProductName, Quarter, SalesAmount
FROM dbo.ProductSalesPivoted
UNPIVOT (
    SalesAmount FOR Quarter IN ([Q1], [Q2], [Q3], [Q4])
) unpvt;
```

> **Note:** UNPIVOT eliminates NULLs by default. If you need to preserve NULLs, use the `CROSS APPLY` + `VALUES` approach shown above instead.

---

## GROUPING SETS, CUBE, and ROLLUP

These extensions to `GROUP BY` allow you to compute multiple levels of aggregation in a single query.

### GROUPING SETS

Explicitly define which grouping combinations to compute.

```sql
SELECT
    ISNULL(Region, '(All Regions)') AS Region,
    ISNULL(Category, '(All Categories)') AS Category,
    SUM(SalesAmount) AS TotalSales,
    GROUPING(Region) AS IsRegionAggregated,
    GROUPING(Category) AS IsCategoryAggregated
FROM dbo.Sales
GROUP BY GROUPING SETS (
    (Region, Category),   -- detail level
    (Region),             -- subtotal by region
    (Category),           -- subtotal by category
    ()                    -- grand total
);
```

### ROLLUP

Produces a hierarchical set of subtotals from left to right, plus a grand total.

```sql
-- Hierarchical: Year > Quarter > Month
SELECT Year, Quarter, Month, SUM(Revenue) AS Revenue
FROM dbo.SalesData
GROUP BY ROLLUP (Year, Quarter, Month);
-- Produces: (Year, Quarter, Month), (Year, Quarter), (Year), ()
```

### CUBE

Produces subtotals for every possible combination of the grouped columns.

```sql
SELECT Region, Category, SUM(SalesAmount) AS TotalSales
FROM dbo.Sales
GROUP BY CUBE (Region, Category);
-- Produces: (Region, Category), (Region), (Category), ()
```

**The `GROUPING()` and `GROUPING_ID()` functions** help distinguish NULL values from actual data versus aggregated rows:

```sql
SELECT
    Region,
    Category,
    SUM(SalesAmount) AS TotalSales,
    GROUPING_ID(Region, Category) AS GroupingLevel
    -- 0 = detail, 1 = Category aggregated, 2 = Region aggregated, 3 = grand total
FROM dbo.Sales
GROUP BY CUBE (Region, Category);
```

---

## IIF and CHOOSE

### IIF

Shorthand for a simple two-outcome CASE expression.

```sql
SELECT
    OrderID,
    IIF(Quantity > 100, 'Bulk', 'Standard') AS OrderType,
    IIF(ShipDate <= DueDate, 'On Time', 'Late') AS DeliveryStatus
FROM dbo.Orders;
```

### CHOOSE

Returns the item at a specified index from a list of values (1-based).

```sql
SELECT
    OrderID,
    CHOOSE(DATEPART(QUARTER, OrderDate), 'Q1', 'Q2', 'Q3', 'Q4') AS OrderQuarter,
    CHOOSE(PriorityLevel, 'Low', 'Medium', 'High', 'Critical') AS PriorityName
FROM dbo.Orders;
```

---

## TRY_CAST, TRY_CONVERT, and TRY_PARSE

Safe conversion functions that return NULL instead of raising an error on failure.

```sql
-- TRY_CAST: ANSI-standard style
SELECT
    TRY_CAST('abc' AS INT) AS fails_returns_null,     -- NULL
    TRY_CAST('123' AS INT) AS succeeds_returns_int;    -- 123

-- TRY_CONVERT: SQL Server-specific with style parameter
SELECT
    TRY_CONVERT(DATE, '13/25/2025', 101) AS bad_date,  -- NULL
    TRY_CONVERT(DATE, '03/25/2025', 101) AS good_date;  -- 2025-03-25

-- TRY_PARSE: uses .NET cultures for parsing strings
SELECT
    TRY_PARSE('$1,234.56' AS MONEY USING 'en-US') AS parsed_money;
```

**Best practice for ETL:** Use `TRY_CAST`/`TRY_CONVERT` when loading data from staging tables to catch and handle bad data without failing the entire batch.

---

## STRING_AGG (SQL Server 2017+)

Concatenates string values with a separator. Replaces the old `FOR XML PATH` hack.

```sql
-- Comma-separated list of products per category
SELECT
    Category,
    STRING_AGG(ProductName, ', ') WITHIN GROUP (ORDER BY ProductName) AS Products
FROM dbo.Products
GROUP BY Category;
```

**Old approach (pre-2017):**

```sql
SELECT
    c.Category,
    STUFF((
        SELECT ', ' + p.ProductName
        FROM dbo.Products p
        WHERE p.Category = c.Category
        ORDER BY p.ProductName
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS Products
FROM dbo.Categories c;
```

---

## STRING_SPLIT (SQL Server 2016+)

Splits a string into rows based on a separator. In SQL Server 2022+, the optional `ordinal` parameter provides position information.

```sql
-- Basic split
SELECT value
FROM STRING_SPLIT('alpha,beta,gamma,delta', ',');

-- SQL Server 2022+: with ordinal
SELECT value, ordinal
FROM STRING_SPLIT('alpha,beta,gamma,delta', ',', 1)
ORDER BY ordinal;

-- Practical use: filter by a comma-separated parameter
DECLARE @CategoryFilter NVARCHAR(200) = 'Electronics,Clothing,Books';

SELECT p.*
FROM dbo.Products p
INNER JOIN STRING_SPLIT(@CategoryFilter, ',') s
    ON p.Category = s.value;
```

---

## OFFSET-FETCH (SQL Server 2012+)

Standard SQL pagination syntax, replacing the `ROW_NUMBER()` pattern for simple cases.

```sql
-- Page 3 of results (25 rows per page)
SELECT CustomerID, CustomerName, City
FROM dbo.Customers
ORDER BY CustomerName
OFFSET 50 ROWS          -- skip first 50 rows (pages 1-2)
FETCH NEXT 25 ROWS ONLY; -- return 25 rows (page 3)

-- Dynamic pagination
DECLARE @PageNumber INT = 3, @PageSize INT = 25;

SELECT CustomerID, CustomerName, City
FROM dbo.Customers
ORDER BY CustomerName
OFFSET (@PageNumber - 1) * @PageSize ROWS
FETCH NEXT @PageSize ROWS ONLY;
```

**Note:** `OFFSET-FETCH` requires an `ORDER BY` clause. For complex pagination needs (e.g., including total count), the `ROW_NUMBER()` approach or `COUNT(*) OVER()` may still be preferred.

---

## TOP WITH TIES

Returns additional rows that tie with the last row in the TOP result set based on the ORDER BY.

```sql
-- Top 5 salaries, including ties
SELECT TOP 5 WITH TIES
    EmployeeName, Department, Salary
FROM dbo.Employees
ORDER BY Salary DESC;
-- If 3 employees share the 5th-highest salary, this returns 7 rows
```

---

## CROSS JOIN Patterns

CROSS JOIN produces the Cartesian product of two tables. While often avoided, it has legitimate uses.

```sql
-- Generate a calendar/number table
WITH Numbers AS (
    SELECT TOP 365
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
    FROM sys.all_objects
)
SELECT DATEADD(DAY, n, '2026-01-01') AS CalendarDate
FROM Numbers;

-- Generate all combinations (e.g., all product-store combinations for inventory)
SELECT p.ProductID, s.StoreID
FROM dbo.Products p
CROSS JOIN dbo.Stores s;

-- Fill gaps: show zero sales for product-date combinations with no transactions
SELECT c.CalendarDate, p.ProductID, ISNULL(s.Quantity, 0) AS Quantity
FROM dbo.Calendar c
CROSS JOIN dbo.Products p
LEFT JOIN dbo.Sales s
    ON s.SaleDate = c.CalendarDate
    AND s.ProductID = p.ProductID;
```

---

## EXCEPT and INTERSECT

Set operators that work on entire row comparisons (treating NULLs as equal).

```sql
-- EXCEPT: rows in first query but not in second (like anti-join)
-- Find customers who placed orders but never made a return
SELECT CustomerID FROM dbo.Orders
EXCEPT
SELECT CustomerID FROM dbo.Returns;

-- INTERSECT: rows common to both queries
-- Find customers who both ordered and returned
SELECT CustomerID FROM dbo.Orders
INTERSECT
SELECT CustomerID FROM dbo.Returns;
```

**Key difference from JOIN-based equivalents:** EXCEPT and INTERSECT compare all columns and treat NULLs as equal. They also return distinct results (no duplicates).

---

## Error Handling: TRY...CATCH, THROW, and RAISERROR

### TRY...CATCH

```sql
BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO dbo.Orders (CustomerID, OrderDate, Amount)
    VALUES (999, GETDATE(), 100.00);

    UPDATE dbo.Inventory
    SET Quantity = Quantity - 1
    WHERE ProductID = 42;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    -- Capture error details
    DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
    DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
    DECLARE @ErrorState INT = ERROR_STATE();
    DECLARE @ErrorNumber INT = ERROR_NUMBER();
    DECLARE @ErrorLine INT = ERROR_LINE();
    DECLARE @ErrorProcedure NVARCHAR(200) = ERROR_PROCEDURE();

    -- Log to error table
    INSERT INTO dbo.ErrorLog (ErrorNumber, ErrorMessage, ErrorSeverity,
                              ErrorState, ErrorLine, ErrorProcedure, ErrorDate)
    VALUES (@ErrorNumber, @ErrorMessage, @ErrorSeverity,
            @ErrorState, @ErrorLine, @ErrorProcedure, SYSDATETIME());

    -- Re-throw or raise
    THROW;  -- re-throws the original error (SQL Server 2012+)
END CATCH;
```

### THROW vs. RAISERROR

```sql
-- THROW (SQL Server 2012+): recommended for new code
-- Re-throws original error when used without parameters in CATCH
THROW;

-- Throws a custom error
THROW 50001, 'Custom error: Order amount exceeds credit limit.', 1;

-- RAISERROR: older syntax, still used for specific scenarios
RAISERROR('Error in procedure %s: %s', 16, 1, @ProcName, @ErrorMessage);

-- RAISERROR with WITH LOG (writes to SQL Server error log and Windows event log)
RAISERROR('Critical failure in ETL pipeline', 20, 1) WITH LOG;
```

**Key differences:**

| Feature | THROW | RAISERROR |
|---|---|---|
| Introduced | SQL Server 2012 | Legacy |
| Severity | Always 16 (custom) or original (re-throw) | Configurable 0-25 |
| Message formatting | No printf-style formatting | Supports %s, %d, etc. |
| Requires semicolon before | Yes (in CATCH block) | No |
| Re-throw original error | Yes (parameterless) | No (must reconstruct) |
| Fires on `msg_id` from `sys.messages` | Yes (`THROW msg_id, ...`) | Yes |

---

## Transaction Management

### BEGIN TRAN, COMMIT, ROLLBACK

```sql
BEGIN TRANSACTION;

    UPDATE dbo.Accounts SET Balance = Balance - 500 WHERE AccountID = 1;
    UPDATE dbo.Accounts SET Balance = Balance + 500 WHERE AccountID = 2;

    IF @@ERROR <> 0
    BEGIN
        ROLLBACK TRANSACTION;
        RETURN;
    END

COMMIT TRANSACTION;
```

### SAVE TRAN (Savepoints)

Savepoints allow partial rollback within a transaction.

```sql
BEGIN TRANSACTION;

    INSERT INTO dbo.OrderHeader (OrderDate, CustomerID)
    VALUES (GETDATE(), 100);

    SAVE TRANSACTION SavePoint_Items;

    BEGIN TRY
        INSERT INTO dbo.OrderItems (OrderID, ProductID, Quantity)
        VALUES (SCOPE_IDENTITY(), 999, 1);  -- might fail (bad ProductID)
    END TRY
    BEGIN CATCH
        -- Roll back only the items insert, not the header
        ROLLBACK TRANSACTION SavePoint_Items;

        -- Log the partial failure
        PRINT 'Item insert failed, but order header preserved.';
    END CATCH;

COMMIT TRANSACTION;
```

### @@TRANCOUNT

Tracks nesting level of transactions. Critical for writing reusable stored procedures.

```sql
CREATE OR ALTER PROCEDURE dbo.usp_TransferFunds
    @FromAccount INT,
    @ToAccount INT,
    @Amount DECIMAL(18,2)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @TranStarted BIT = 0;

    -- Only start a transaction if one isn't already active
    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @TranStarted = 1;
    END

    BEGIN TRY
        UPDATE dbo.Accounts SET Balance = Balance - @Amount WHERE AccountID = @FromAccount;
        UPDATE dbo.Accounts SET Balance = Balance + @Amount WHERE AccountID = @ToAccount;

        IF @TranStarted = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @TranStarted = 1 AND @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
```

**Key behavior:** `COMMIT` decrements `@@TRANCOUNT` by 1. Only when it reaches 0 is the transaction actually committed. `ROLLBACK` (without a savepoint name) always rolls back to `@@TRANCOUNT = 0`, regardless of nesting depth.

---

## SET vs. SELECT for Variable Assignment

Both can assign values to variables, but they behave differently.

```sql
-- SET: assigns one variable at a time
DECLARE @Name NVARCHAR(100), @City NVARCHAR(100);
SET @Name = (SELECT CustomerName FROM dbo.Customers WHERE CustomerID = 1);
SET @City = (SELECT City FROM dbo.Customers WHERE CustomerID = 1);

-- SELECT: can assign multiple variables in one statement (more efficient)
SELECT @Name = CustomerName, @City = City
FROM dbo.Customers
WHERE CustomerID = 1;
```

**Critical difference when the query returns no rows:**

```sql
DECLARE @Val INT = 42;

-- SET: variable becomes NULL if no rows returned
SET @Val = (SELECT Value FROM dbo.T WHERE 1 = 0);
-- @Val is now NULL

-- SELECT: variable RETAINS its previous value if no rows returned
DECLARE @Val2 INT = 42;
SELECT @Val2 = Value FROM dbo.T WHERE 1 = 0;
-- @Val2 is still 42!
```

**Critical difference when the query returns multiple rows:**

```sql
-- SET: raises an error if subquery returns more than one row
SET @Val = (SELECT Value FROM dbo.T);  -- ERROR if multiple rows

-- SELECT: silently assigns the LAST value (non-deterministic without ORDER BY)
SELECT @Val = Value FROM dbo.T;  -- no error, unpredictable result
```

**Best practice:** Use `SET` for single-variable assignments where you want predictable NULL behavior. Use `SELECT` when assigning multiple variables from the same row for efficiency, but be mindful of multi-row results.

---

## NULL Handling: ISNULL, COALESCE, and NULLIF

### ISNULL

Replaces NULL with a specified value. SQL Server-specific.

```sql
SELECT ISNULL(MiddleName, '') AS MiddleName FROM dbo.Employees;
```

### COALESCE

Returns the first non-NULL value in the list. ANSI-standard.

```sql
SELECT COALESCE(MobilePhone, HomePhone, OfficePhone, 'No Phone') AS ContactPhone
FROM dbo.Employees;
```

### Key Differences Between ISNULL and COALESCE

| Aspect | ISNULL | COALESCE |
|---|---|---|
| Standard | SQL Server only | ANSI SQL |
| Parameters | Exactly 2 | 2 or more |
| Return type | Type of first argument | Highest precedence type |
| Nullability in expressions | May affect computed column nullability | Follows standard rules |

```sql
-- Data type difference example
SELECT
    ISNULL(CAST(NULL AS VARCHAR(5)), 'Hello World'),   -- truncated to 'Hello' (VARCHAR(5))
    COALESCE(CAST(NULL AS VARCHAR(5)), 'Hello World');  -- returns 'Hello World' (VARCHAR(11))
```

### NULLIF

Returns NULL if the two arguments are equal; otherwise returns the first argument. Useful for avoiding divide-by-zero.

```sql
-- Avoid divide by zero
SELECT
    TotalRevenue / NULLIF(TotalOrders, 0) AS AvgRevenuePerOrder
FROM dbo.Summary;

-- Replace empty strings with NULL
SELECT NULLIF(PhoneNumber, '') AS PhoneNumber
FROM dbo.Contacts;
```

---

## Common Interview Questions and Answers

### Q1: What are the risks of using the MERGE statement?

**A:** MERGE has had a history of bugs in SQL Server, including race conditions under concurrent access, incorrect results with filtered indexes, and issues with triggers. To mitigate: always end MERGE with a semicolon, use `HOLDLOCK` on the target for concurrency safety, ensure the ON clause uniquely identifies rows, test thoroughly, and be aware of known Microsoft Connect bugs. Some teams avoid MERGE entirely in favor of separate INSERT/UPDATE/DELETE statements for critical workloads.

### Q2: Explain the difference between CROSS APPLY and OUTER APPLY.

**A:** Both evaluate the right table expression for each row of the left table. CROSS APPLY excludes left rows where the right expression returns no rows (like INNER JOIN). OUTER APPLY includes all left rows, producing NULLs for the right-side columns when no rows are returned (like LEFT JOIN). APPLY is especially useful with table-valued functions, TOP-N-per-group queries, and column unpivoting via VALUES.

### Q3: How does OFFSET-FETCH differ from using ROW_NUMBER for pagination?

**A:** OFFSET-FETCH is simpler syntax for basic pagination and is the ANSI-standard approach. However, ROW_NUMBER offers more flexibility: you can include the total count via `COUNT(*) OVER()`, apply multiple orderings, and use it in CTEs for more complex scenarios. Performance-wise, both require scanning/sorting up to the requested row; for deep pages (high OFFSET values), both perform poorly and a keyset pagination approach is better.

### Q4: What happens to @@TRANCOUNT with nested transactions?

**A:** Each `BEGIN TRANSACTION` increments `@@TRANCOUNT` by 1. Each `COMMIT` decrements it by 1. The transaction is only truly committed when `@@TRANCOUNT` reaches 0. However, `ROLLBACK` (without a savepoint) always rolls back everything and resets `@@TRANCOUNT` to 0, regardless of nesting level. This means inner transactions cannot independently commit -- the outermost transaction controls the actual commit. Use `SAVE TRANSACTION` with named savepoints for partial rollback capability.

### Q5: Why would you use COALESCE over ISNULL?

**A:** COALESCE is ANSI-standard (portable), accepts multiple parameters (first non-NULL from a list), and determines return type based on data type precedence. ISNULL is SQL Server-specific, takes exactly two parameters, and uses the data type of the first parameter (which can cause silent truncation). However, ISNULL can be slightly faster in some scenarios since it evaluates the replacement expression only once, while COALESCE may evaluate the first expression twice.

### Q6: How would you handle errors inside a stored procedure that might be called within an existing transaction?

**A:** Check `@@TRANCOUNT` at the start to determine if a transaction already exists. If no transaction is active, start one. In the CATCH block, only roll back if you started the transaction. Use `THROW` to re-raise the error so the calling code can handle it. This pattern ensures the procedure works correctly both standalone and nested within a larger transaction.

### Q7: Explain GROUPING SETS and when you would use them.

**A:** GROUPING SETS allow you to define multiple grouping levels in a single GROUP BY clause, producing subtotals and grand totals in one query pass. ROLLUP is a shortcut for hierarchical groupings (Year > Quarter > Month), and CUBE generates all combinations. These replace the need for multiple queries with UNION ALL to get different aggregation levels. Use the `GROUPING()` function to distinguish real NULLs from aggregated-level NULLs.

### Q8: What is the difference between EXCEPT and NOT EXISTS?

**A:** Both find rows in one set that are not in another, but EXCEPT compares all columns across the full row, treats NULLs as equal, and returns distinct results. NOT EXISTS requires you to specify the join condition explicitly. EXCEPT is more concise for whole-row comparisons, while NOT EXISTS is more flexible (can join on specific columns, does not deduplicate, handles NULLs per your logic). Performance can differ depending on the query; check execution plans.

---

## Tips for Interviews and Real-World Practice

1. **Know when MERGE is appropriate and when it is not.** In interviews, demonstrate awareness of both its power and its pitfalls. This shows maturity.

2. **CROSS APPLY is your Swiss Army knife.** Use it for TOP-N per group, unpivoting, invoking table-valued functions, and replacing correlated subqueries. It is one of the most versatile T-SQL features.

3. **Always handle errors and transactions together.** In production code, every transaction should be inside TRY...CATCH, and every CATCH block should check `@@TRANCOUNT` before rolling back.

4. **Prefer THROW over RAISERROR for new code.** THROW re-raises the original error faithfully and is simpler. Use RAISERROR only when you need formatted messages or severity control.

5. **Understand SET vs. SELECT variable behavior with no rows.** This is a classic interview gotcha. SET nullifies the variable; SELECT preserves the old value.

6. **Use TRY_CAST/TRY_CONVERT in ETL pipelines.** Never let a data type conversion failure crash an entire data load. Catch bad data gracefully and route it to an error table.

7. **STRING_AGG replaces FOR XML PATH.** If you are on SQL Server 2017+, use STRING_AGG for string concatenation. It is cleaner, faster, and handles special XML characters automatically.

8. **GROUPING SETS can replace complex UNION ALL queries.** A single pass with GROUPING SETS is typically more efficient than multiple GROUP BY queries combined with UNION ALL.

9. **For pagination at scale, consider keyset pagination** (WHERE PrimaryKey > @LastSeen ORDER BY PrimaryKey FETCH NEXT 25 ROWS ONLY) instead of OFFSET-FETCH with large offsets.

10. **Remember NULLIF for divide-by-zero.** `x / NULLIF(y, 0)` returns NULL instead of an error. Simple and elegant.

---
