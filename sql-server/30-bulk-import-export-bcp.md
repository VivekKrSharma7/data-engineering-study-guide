# Bulk Import/Export & BCP

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Bulk Operations Overview](#bulk-operations-overview)
2. [BCP Utility (Command Line)](#bcp-utility-command-line)
3. [BULK INSERT Statement](#bulk-insert-statement)
4. [OPENROWSET(BULK)](#openrowsetbulk)
5. [Format Files](#format-files)
6. [Minimal Logging and Bulk Operations](#minimal-logging-and-bulk-operations)
7. [TABLOCK Hint](#tablock-hint)
8. [Batch Size Considerations](#batch-size-considerations)
9. [Error Handling](#error-handling)
10. [Bulk Import with Identity Columns](#bulk-import-with-identity-columns)
11. [CSV Handling](#csv-handling)
12. [Bulk Operations and Triggers/Constraints](#bulk-operations-and-triggersconstraints)
13. [Performance Optimization](#performance-optimization)
14. [Common Interview Questions](#common-interview-questions)
15. [Tips](#tips)

---

## Bulk Operations Overview

SQL Server provides several mechanisms for high-performance data import and export:

| Method | Type | Description |
|--------|------|-------------|
| **BCP** | Command-line utility | Bulk Copy Program; imports/exports data between files and SQL Server |
| **BULK INSERT** | T-SQL statement | Server-side bulk import from a data file |
| **OPENROWSET(BULK)** | T-SQL function | Reads data from a file as a rowset; can be used in SELECT/INSERT |
| **SqlBulkCopy** | .NET API | Programmatic bulk copy (C#/VB.NET) |
| **SSIS** | ETL tool | Bulk load via Data Flow tasks |

All bulk methods leverage the same underlying bulk insert API, which bypasses the normal row-by-row INSERT pathway for dramatically better performance.

---

## BCP Utility (Command Line)

BCP (Bulk Copy Program) is a command-line tool that ships with SQL Server. It supports both import and export of data to/from flat files.

### Syntax

```
bcp {table | view | "query"} {in | out | queryout | format} datafile
    [-S server] [-d database] [-U login] [-P password] [-T]
    [-c | -n | -w | -N] [-t field_terminator] [-r row_terminator]
    [-f formatfile] [-F firstrow] [-L lastrow]
    [-b batchsize] [-m maxerrors] [-e errorfile]
    [-h "hints"] [-a packetsize] [-k]
```

### Export Examples

```bash
# Export a table to a file using character mode (tab-delimited)
bcp SalesDB.dbo.Customers out C:\Data\customers.txt -c -T -S localhost\SQL2019

# Export with comma delimiter
bcp SalesDB.dbo.Customers out C:\Data\customers.csv -c -t"," -T -S localhost\SQL2019

# Export with Unicode
bcp SalesDB.dbo.Customers out C:\Data\customers_unicode.txt -w -T -S localhost\SQL2019

# Export using a query (must use queryout)
bcp "SELECT CustomerID, Name, Email FROM SalesDB.dbo.Customers WHERE Region = 'West'" queryout C:\Data\west_customers.csv -c -t"," -T -S localhost\SQL2019

# Export with native format (binary - for SQL Server to SQL Server transfers)
bcp SalesDB.dbo.Customers out C:\Data\customers.bcp -n -T -S localhost\SQL2019

# Export with SQL authentication
bcp SalesDB.dbo.Customers out C:\Data\customers.txt -c -U myuser -P mypassword -S remoteserver
```

### Import Examples

```bash
# Import a tab-delimited file
bcp SalesDB.dbo.Customers in C:\Data\customers.txt -c -T -S localhost\SQL2019

# Import a CSV file
bcp SalesDB.dbo.Customers in C:\Data\customers.csv -c -t"," -T -S localhost\SQL2019

# Import using a format file
bcp SalesDB.dbo.Customers in C:\Data\customers.csv -f C:\Data\customers.fmt -T -S localhost\SQL2019

# Import with batch size and error file
bcp SalesDB.dbo.Customers in C:\Data\customers.csv -c -t"," -b 10000 -m 100 -e C:\Data\errors.txt -T -S localhost\SQL2019

# Import with TABLOCK hint for minimal logging
bcp SalesDB.dbo.Customers in C:\Data\customers.csv -c -t"," -h "TABLOCK" -T -S localhost\SQL2019

# Import starting from row 2 (skip header)
bcp SalesDB.dbo.Customers in C:\Data\customers.csv -c -t"," -F 2 -T -S localhost\SQL2019

# Import with keep-nulls (preserve NULL instead of using column defaults)
bcp SalesDB.dbo.Customers in C:\Data\customers.csv -c -t"," -k -T -S localhost\SQL2019
```

### BCP Mode Switches

| Switch | Mode | Description |
|--------|------|-------------|
| `-c` | Character | Text mode with tab delimiter and newline row terminator |
| `-w` | Unicode character | Wide character mode (UTF-16) |
| `-n` | Native | Binary format; fastest for SQL Server to SQL Server transfers |
| `-N` | Unicode native | Native for non-char columns, Unicode for char columns |

### Generating a Format File

```bash
# Generate a non-XML format file
bcp SalesDB.dbo.Customers format nul -c -t"," -f C:\Data\customers.fmt -T -S localhost\SQL2019

# Generate an XML format file
bcp SalesDB.dbo.Customers format nul -c -t"," -x -f C:\Data\customers.xml -T -S localhost\SQL2019
```

---

## BULK INSERT Statement

`BULK INSERT` is a T-SQL statement that imports data from a file into a table. It runs on the server side, so the file must be accessible from the SQL Server machine (local path, UNC path, or Azure Blob Storage in newer versions).

### Basic Syntax

```sql
BULK INSERT dbo.Customers
FROM 'C:\Data\customers.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FIRSTROW = 2,              -- Skip header row
    CODEPAGE = '65001',        -- UTF-8
    TABLOCK,                   -- Table lock for minimal logging
    BATCHSIZE = 10000,         -- Commit every 10,000 rows
    MAXERRORS = 100,           -- Allow up to 100 errors before failing
    ERRORFILE = 'C:\Data\bulk_errors.txt',
    CHECK_CONSTRAINTS,         -- Enforce CHECK constraints
    FIRE_TRIGGERS              -- Fire INSERT triggers
);
```

### Comprehensive Examples

```sql
-- Basic CSV import
BULK INSERT dbo.Products
FROM 'C:\Data\products.csv'
WITH (
    FORMAT = 'CSV',            -- SQL Server 2017+ CSV format
    FIELDQUOTE = '"',          -- Quote character for CSV
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',    -- LF line ending
    TABLOCK
);

-- Import using a format file
BULK INSERT dbo.Customers
FROM 'C:\Data\customers.dat'
WITH (
    FORMATFILE = 'C:\Data\customers.xml',
    TABLOCK,
    BATCHSIZE = 50000
);

-- Import from a UNC network path
BULK INSERT dbo.SalesData
FROM '\\FileServer\Shares\Data\sales_2026.csv'
WITH (
    FIELDTERMINATOR = '|',
    ROWTERMINATOR = '\n',
    FIRSTROW = 2,
    TABLOCK
);

-- Import from Azure Blob Storage (SQL Server 2017+)
BULK INSERT dbo.SalesData
FROM 'sales_2026.csv'
WITH (
    DATA_SOURCE = 'AzureBlobStorage',  -- External data source
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    FIRSTROW = 2,
    TABLOCK
);

-- Import with keep-nulls and specific code page
BULK INSERT dbo.InternationalData
FROM 'C:\Data\international.csv'
WITH (
    FIELDTERMINATOR = ';',
    ROWTERMINATOR = '\r\n',
    KEEPNULLS,                 -- Preserve NULLs (don't apply defaults)
    CODEPAGE = '1252',         -- Windows Latin-1
    FIRSTROW = 2
);
```

### BULK INSERT Options Reference

| Option | Description |
|--------|-------------|
| `FIELDTERMINATOR` | Column delimiter (default: `\t`) |
| `ROWTERMINATOR` | Row delimiter (default: `\n` or `\r\n`) |
| `FIRSTROW` | First row to import (use 2 to skip header) |
| `LASTROW` | Last row to import |
| `BATCHSIZE` | Rows per batch/commit (0 = entire file as one batch) |
| `MAXERRORS` | Maximum errors before aborting (default: 10) |
| `ERRORFILE` | File to write rejected rows |
| `FORMATFILE` | Path to a format file (XML or non-XML) |
| `FORMAT` | `'CSV'` for proper CSV handling (SQL 2017+) |
| `FIELDQUOTE` | Quote character for CSV fields (default: `"`) |
| `TABLOCK` | Acquire table-level lock (enables minimal logging) |
| `CHECK_CONSTRAINTS` | Evaluate CHECK constraints during import |
| `FIRE_TRIGGERS` | Execute INSERT triggers during import |
| `KEEPNULLS` | Preserve NULL values instead of applying defaults |
| `KEEPIDENTITY` | Preserve identity values from the data file |
| `CODEPAGE` | Character encoding of the data file |
| `DATAFILETYPE` | `'char'`, `'native'`, `'widechar'`, or `'widenative'` |
| `ORDER` | Specify sort order of data (enables optimized insert) |
| `ROWS_PER_BATCH` | Hint for optimizer about total rows (does not control commits) |

---

## OPENROWSET(BULK)

`OPENROWSET` with the `BULK` option reads data from a file as a rowset, which can be used in SELECT, INSERT...SELECT, or as a table source. It provides more flexibility than `BULK INSERT` because you can transform data during import.

```sql
-- Read a file as a rowset and insert into a table
INSERT INTO dbo.Customers (CustomerID, Name, Email)
SELECT CustomerID, Name, Email
FROM OPENROWSET(
    BULK 'C:\Data\customers.csv',
    FORMATFILE = 'C:\Data\customers.xml',
    FIRSTROW = 2
) AS data;

-- Read a file into a variable (useful for reading entire file contents)
DECLARE @jsonData NVARCHAR(MAX);
SELECT @jsonData = BulkColumn
FROM OPENROWSET(
    BULK 'C:\Data\config.json',
    SINGLE_NCLOB   -- Read entire file as a single NVARCHAR(MAX) value
) AS j;

-- Read an XML file
DECLARE @xmlData XML;
SELECT @xmlData = BulkColumn
FROM OPENROWSET(
    BULK 'C:\Data\data.xml',
    SINGLE_BLOB    -- Read entire file as VARBINARY(MAX)
) AS x;

-- Read a CSV with transformations
INSERT INTO dbo.Products (ProductName, Price, Category)
SELECT
    UPPER(data.ProductName),           -- Transform during import
    CAST(data.Price AS DECIMAL(10,2)),
    COALESCE(data.Category, 'Unknown')
FROM OPENROWSET(
    BULK 'C:\Data\products.csv',
    FORMATFILE = 'C:\Data\products.xml',
    FIRSTROW = 2
) AS data;

-- Read from Azure Blob Storage
SELECT *
FROM OPENROWSET(
    BULK 'sales/2026/january.csv',
    DATA_SOURCE = 'AzureBlobStorage',
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    FIRSTROW = 2,
    PARSER_VERSION = '2.0'
) WITH (
    OrderID INT,
    OrderDate DATE,
    Amount DECIMAL(10,2)
) AS sales;
```

### SINGLE_BLOB vs SINGLE_CLOB vs SINGLE_NCLOB

| Option | Return Type | Use Case |
|--------|-------------|----------|
| `SINGLE_BLOB` | VARBINARY(MAX) | Binary files, XML, any encoding |
| `SINGLE_CLOB` | VARCHAR(MAX) | ANSI/ASCII text files |
| `SINGLE_NCLOB` | NVARCHAR(MAX) | Unicode text files, JSON |

---

## Format Files

Format files define the structure of the data file and how it maps to the target table columns. They are essential when the file structure does not match the table structure exactly.

### Non-XML Format File

Generated by BCP or created manually. Structure:

```
14.0              <-- Version
4                 <-- Number of columns
1  SQLCHAR  0  0  ","   1  CustomerID    ""
2  SQLCHAR  0  0  ","   2  Name          SQL_Latin1_General_CP1_CI_AS
3  SQLCHAR  0  0  ","   3  Email         SQL_Latin1_General_CP1_CI_AS
4  SQLCHAR  0  0  "\n"  4  Region        SQL_Latin1_General_CP1_CI_AS
```

Fields in order: Host file field order, host data type, prefix length, max data length, terminator, server column order, server column name, collation.

### XML Format File

More readable and supports advanced mappings:

```xml
<?xml version="1.0"?>
<BCPFORMAT xmlns="http://schemas.microsoft.com/sqlserver/2004/bulkload/format"
           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <RECORD>
    <FIELD ID="1" xsi:type="CharTerm" TERMINATOR="," MAX_LENGTH="12"/>
    <FIELD ID="2" xsi:type="CharTerm" TERMINATOR="," MAX_LENGTH="100"/>
    <FIELD ID="3" xsi:type="CharTerm" TERMINATOR="," MAX_LENGTH="200"/>
    <FIELD ID="4" xsi:type="CharTerm" TERMINATOR="\r\n" MAX_LENGTH="50"/>
  </RECORD>
  <ROW>
    <COLUMN SOURCE="1" NAME="CustomerID" xsi:type="SQLINT"/>
    <COLUMN SOURCE="2" NAME="Name" xsi:type="SQLNVARCHAR"/>
    <COLUMN SOURCE="3" NAME="Email" xsi:type="SQLNVARCHAR"/>
    <COLUMN SOURCE="4" NAME="Region" xsi:type="SQLNVARCHAR"/>
  </ROW>
</BCPFORMAT>
```

### Skipping Columns with Format Files

If the data file has more columns than the target table, or you want to skip certain file columns:

```xml
<?xml version="1.0"?>
<BCPFORMAT xmlns="http://schemas.microsoft.com/sqlserver/2004/bulkload/format"
           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <RECORD>
    <FIELD ID="1" xsi:type="CharTerm" TERMINATOR="," MAX_LENGTH="12"/>
    <FIELD ID="2" xsi:type="CharTerm" TERMINATOR="," MAX_LENGTH="100"/>
    <FIELD ID="3" xsi:type="CharTerm" TERMINATOR="," MAX_LENGTH="200"/>
    <FIELD ID="4" xsi:type="CharTerm" TERMINATOR="," MAX_LENGTH="50"/>
    <FIELD ID="5" xsi:type="CharTerm" TERMINATOR="\r\n" MAX_LENGTH="20"/>
  </RECORD>
  <ROW>
    <COLUMN SOURCE="1" NAME="CustomerID" xsi:type="SQLINT"/>
    <COLUMN SOURCE="2" NAME="Name" xsi:type="SQLNVARCHAR"/>
    <!-- Field 3 (Email) is skipped - no COLUMN mapping for SOURCE="3" -->
    <COLUMN SOURCE="4" NAME="Region" xsi:type="SQLNVARCHAR"/>
    <!-- Field 5 (Phone) is also skipped -->
  </ROW>
</BCPFORMAT>
```

### Reordering Columns with Format Files

```xml
<!-- File order: ID, Email, Name but table order: ID, Name, Email -->
<ROW>
    <COLUMN SOURCE="1" NAME="CustomerID" xsi:type="SQLINT"/>
    <COLUMN SOURCE="3" NAME="Name" xsi:type="SQLNVARCHAR"/>
    <COLUMN SOURCE="2" NAME="Email" xsi:type="SQLNVARCHAR"/>
</ROW>
```

---

## Minimal Logging and Bulk Operations

Minimal logging is a key performance optimization where SQL Server logs only the extent allocations rather than individual row inserts. This can reduce log I/O by 90% or more.

### Requirements for Minimal Logging

All of the following must be true:

1. **Recovery model** is `SIMPLE` or `BULK_LOGGED` (not `FULL`).
2. **TABLOCK** hint is specified (acquires a bulk update lock on the table).
3. **Target table conditions** (depends on table state):

| Table State | Minimal Logging? |
|-------------|-----------------|
| Empty heap, no indexes | Yes with TABLOCK |
| Empty heap with indexes | Yes with TABLOCK |
| Non-empty heap, no indexes | Yes with TABLOCK |
| Non-empty heap with indexes | Yes with TABLOCK (nonclustered indexes still fully logged) |
| Empty B-tree (clustered index) | Yes with TABLOCK |
| Non-empty B-tree | Yes with TABLOCK + ORDER hint + trace flag 610 (or SQL 2016+) |

### Setting Up for Minimal Logging

```sql
-- Option 1: Use BULK_LOGGED recovery during the bulk load
ALTER DATABASE SalesDB SET RECOVERY BULK_LOGGED;

BULK INSERT dbo.StagingTable
FROM 'C:\Data\large_file.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FIRSTROW = 2,
    TABLOCK,                    -- Required for minimal logging
    ORDER (CustomerID ASC),     -- Helps with sorted data into clustered index
    BATCHSIZE = 100000
);

-- Switch back to FULL recovery
ALTER DATABASE SalesDB SET RECOVERY FULL;

-- Take a log backup immediately to re-establish the log chain
BACKUP LOG SalesDB TO DISK = 'C:\Backups\SalesDB_Log.trn';
```

### Important Note on BULK_LOGGED Recovery

- During `BULK_LOGGED` mode, log-based point-in-time recovery is not possible if minimally logged operations occurred since the last log backup.
- Always take a log backup immediately after switching back to `FULL` recovery.
- This is why `BULK_LOGGED` is typically used only during planned bulk load windows.

---

## TABLOCK Hint

The `TABLOCK` hint is one of the most important options for bulk operations.

### What TABLOCK Does

- Acquires a **Bulk Update (BU) lock** on the table for the duration of the bulk operation.
- Enables **parallel bulk inserts** -- multiple `BULK INSERT` statements can run concurrently on the same heap table.
- Enables **minimal logging** (when recovery model allows).
- **Prevents** other sessions from reading or writing to the table during the bulk operation.

### Using TABLOCK

```sql
-- BULK INSERT with TABLOCK
BULK INSERT dbo.FactSales
FROM 'C:\Data\sales_data.csv'
WITH (FIELDTERMINATOR = ',', ROWTERMINATOR = '\n', TABLOCK, FIRSTROW = 2);

-- BCP with TABLOCK
-- bcp SalesDB.dbo.FactSales in C:\Data\sales_data.csv -c -t"," -h "TABLOCK" -T -S localhost

-- INSERT...SELECT with TABLOCK (not bulk API, but enables minimal logging in some cases)
INSERT INTO dbo.FactSales WITH (TABLOCK)
SELECT * FROM dbo.StagingFactSales;
```

### Parallel Bulk Loading

Multiple BCP or BULK INSERT operations can run concurrently against a heap table with TABLOCK:

```bash
# Terminal 1
bcp SalesDB.dbo.FactSales in C:\Data\sales_part1.csv -c -t"," -h "TABLOCK" -T -S localhost

# Terminal 2 (simultaneously)
bcp SalesDB.dbo.FactSales in C:\Data\sales_part2.csv -c -t"," -h "TABLOCK" -T -S localhost

# Terminal 3 (simultaneously)
bcp SalesDB.dbo.FactSales in C:\Data\sales_part3.csv -c -t"," -h "TABLOCK" -T -S localhost
```

Note: Parallel bulk loading into a table with a clustered index requires the data in each file to be sorted by the clustering key, and each file must cover a non-overlapping key range.

---

## Batch Size Considerations

Batch size controls how many rows are committed in a single transaction during bulk import.

### Impact of Batch Size

| Batch Size | Behavior |
|------------|----------|
| `0` or not specified | Entire file is one batch; one commit at the end |
| Small (e.g., 1000) | Frequent commits; less risk of massive rollback; more log usage |
| Large (e.g., 100000) | Fewer commits; better performance; larger rollback risk |

### Choosing the Right Batch Size

```sql
-- Small batch size for safety (restartable loads)
BULK INSERT dbo.LargeTable
FROM 'C:\Data\huge_file.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    BATCHSIZE = 50000,   -- Commit every 50K rows
    TABLOCK
);
```

### Trade-offs

- **No batch size (single batch)**: Fastest for small to medium files. If an error occurs on row 9,999,999 of a 10M row file, the entire import rolls back.
- **Small batches**: Each batch is a separate transaction. If an error occurs in batch 50, batches 1-49 are already committed. However, more commits mean more log flushes and overhead.
- **ROWS_PER_BATCH** (hint, not a commit boundary): Tells the optimizer how many rows to expect, which helps with memory allocation. It does NOT control commit behavior.

```sql
-- ROWS_PER_BATCH is a hint, BATCHSIZE controls commits
BULK INSERT dbo.FactSales
FROM 'C:\Data\sales.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    ROWS_PER_BATCH = 5000000,  -- Hint: expect 5M rows total
    BATCHSIZE = 100000,         -- Commit every 100K rows
    TABLOCK
);
```

---

## Error Handling

### MAXERRORS

Controls how many errors are tolerated before the bulk operation aborts.

```sql
-- Allow up to 500 bad rows before failing
BULK INSERT dbo.Products
FROM 'C:\Data\products.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FIRSTROW = 2,
    MAXERRORS = 500,                         -- Tolerate up to 500 errors
    ERRORFILE = 'C:\Data\product_errors.txt' -- Log rejected rows
);
```

### ERRORFILE

The error file captures rows that could not be imported. SQL Server creates two files:
- `product_errors.txt` - The actual data rows that failed
- `product_errors.txt.Error.Txt` - Error descriptions for each failed row

### ERRORFILE_DATA_SOURCE (SQL Server 2017+)

```sql
-- Write error file to Azure Blob Storage
BULK INSERT dbo.Products
FROM 'products.csv'
WITH (
    DATA_SOURCE = 'AzureBlobStorage',
    FORMAT = 'CSV',
    FIRSTROW = 2,
    MAXERRORS = 100,
    ERRORFILE = 'errors/product_errors.csv',
    ERRORFILE_DATA_SOURCE = 'AzureBlobStorage'
);
```

### BCP Error Handling

```bash
# BCP with error handling
bcp SalesDB.dbo.Products in C:\Data\products.csv -c -t"," -F 2 -m 500 -e C:\Data\bcp_errors.txt -T -S localhost

# -m 500  = MAXERRORS (max 500 errors)
# -e      = error file path
```

### Handling Specific Error Scenarios

```sql
-- Wrap BULK INSERT in TRY/CATCH for error handling
BEGIN TRY
    BULK INSERT dbo.StagingProducts
    FROM 'C:\Data\products.csv'
    WITH (
        FIELDTERMINATOR = ',',
        ROWTERMINATOR = '\n',
        FIRSTROW = 2,
        MAXERRORS = 0,     -- Fail on first error
        TABLOCK
    );

    PRINT 'Bulk insert completed successfully.';
    PRINT 'Rows imported: ' + CAST(@@ROWCOUNT AS VARCHAR(20));
END TRY
BEGIN CATCH
    PRINT 'Bulk insert failed.';
    PRINT 'Error: ' + ERROR_MESSAGE();
    PRINT 'Error Number: ' + CAST(ERROR_NUMBER() AS VARCHAR(10));

    -- Optionally, handle the error (log, alert, etc.)
END CATCH
```

---

## Bulk Import with Identity Columns

### Default Behavior (Auto-Generate Identity Values)

By default, SQL Server ignores identity values in the data file and generates new values:

```sql
-- Data file has: 1,John,john@test.com  2,Jane,jane@test.com
-- Identity values (1, 2) are ignored; new values are auto-assigned

BULK INSERT dbo.Customers
FROM 'C:\Data\customers.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n'
);
-- CustomerID will be auto-generated (e.g., 1001, 1002, ...)
```

### Preserving Identity Values from the File (KEEPIDENTITY)

```sql
-- Preserve the identity values from the data file
BULK INSERT dbo.Customers
FROM 'C:\Data\customers.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    KEEPIDENTITY,     -- Use identity values from the file
    TABLOCK
);
-- CustomerID will be 1, 2 (from the file)
```

```bash
# BCP with KEEPIDENTITY
bcp SalesDB.dbo.Customers in C:\Data\customers.csv -c -t"," -h "TABLOCK" -E -T -S localhost
# -E flag = keep identity values
```

### Skipping the Identity Column in the Data File

If the data file does NOT contain the identity column, use a format file to map only the non-identity columns:

```xml
<?xml version="1.0"?>
<BCPFORMAT xmlns="http://schemas.microsoft.com/sqlserver/2004/bulkload/format"
           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <RECORD>
    <FIELD ID="1" xsi:type="CharTerm" TERMINATOR="," MAX_LENGTH="100"/>
    <FIELD ID="2" xsi:type="CharTerm" TERMINATOR="\r\n" MAX_LENGTH="200"/>
  </RECORD>
  <ROW>
    <!-- CustomerID (column 1) is identity - not mapped -->
    <COLUMN SOURCE="1" NAME="Name" xsi:type="SQLNVARCHAR"/>
    <COLUMN SOURCE="2" NAME="Email" xsi:type="SQLNVARCHAR"/>
  </ROW>
</BCPFORMAT>
```

```sql
BULK INSERT dbo.Customers
FROM 'C:\Data\customers_no_id.csv'
WITH (
    FORMATFILE = 'C:\Data\customers_no_id.xml',
    FIRSTROW = 2
);
```

### Using a View to Skip Identity

```sql
-- Create a view without the identity column
CREATE VIEW dbo.vw_Customers_BulkLoad AS
SELECT Name, Email, Region FROM dbo.Customers;
GO

-- Bulk insert through the view
BULK INSERT dbo.vw_Customers_BulkLoad
FROM 'C:\Data\customers_no_id.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FIRSTROW = 2
);
```

---

## CSV Handling

### SQL Server 2017+ Native CSV Support

```sql
-- Use FORMAT = 'CSV' for proper CSV parsing
BULK INSERT dbo.Products
FROM 'C:\Data\products.csv'
WITH (
    FORMAT = 'CSV',
    FIELDQUOTE = '"',          -- Character used to quote fields
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',    -- LF
    TABLOCK
);
```

### Handling Common CSV Challenges

#### Embedded Commas in Fields

```
-- Data: 1,"Smith, John",john@test.com
-- The FORMAT='CSV' option with FIELDQUOTE handles this automatically (SQL 2017+)
```

#### Embedded Quotes in Fields

```
-- Data: 1,"He said ""hello""",john@test.com
-- Doubled quotes are the CSV standard; FORMAT='CSV' handles this
```

#### Mixed Line Endings

```sql
-- Windows-style CRLF
BULK INSERT dbo.Data FROM 'C:\Data\windows.csv'
WITH (FORMAT = 'CSV', ROWTERMINATOR = '\r\n', FIRSTROW = 2);

-- Unix-style LF
BULK INSERT dbo.Data FROM 'C:\Data\unix.csv'
WITH (FORMAT = 'CSV', ROWTERMINATOR = '0x0a', FIRSTROW = 2);

-- Hex notation is more reliable for line endings
-- \r\n = 0x0d0a (CRLF)
-- \n   = 0x0a (LF)
```

#### Pre-SQL Server 2017 CSV Handling

Without `FORMAT = 'CSV'`, you need a format file or preprocessing to handle quoted fields:

```sql
-- Workaround: Use OPENROWSET with a format file
-- Or preprocess the file to replace commas in quoted fields
-- Or load into a staging table with a single VARCHAR(MAX) column and parse with T-SQL
BULK INSERT dbo.RawStaging
FROM 'C:\Data\complex.csv'
WITH (
    ROWTERMINATOR = '\n',
    FIRSTROW = 2
);
-- Then parse dbo.RawStaging.RawLine using STRING_SPLIT or custom logic
```

#### Tab-Delimited Files (TSV)

```sql
BULK INSERT dbo.Data
FROM 'C:\Data\data.tsv'
WITH (
    FIELDTERMINATOR = '\t',
    ROWTERMINATOR = '\n',
    FIRSTROW = 2,
    TABLOCK
);
```

#### Pipe-Delimited Files

```sql
BULK INSERT dbo.Data
FROM 'C:\Data\data.txt'
WITH (
    FIELDTERMINATOR = '|',
    ROWTERMINATOR = '\n',
    FIRSTROW = 2,
    TABLOCK
);
```

---

## Bulk Operations and Triggers/Constraints

### Default Behavior

By default, bulk operations:
- **Do NOT fire triggers** (INSERT triggers are skipped)
- **Do NOT check CHECK constraints** (constraints are not evaluated)
- **DO enforce** NOT NULL, PRIMARY KEY, UNIQUE, and FOREIGN KEY constraints

### Enabling Triggers

```sql
BULK INSERT dbo.Orders
FROM 'C:\Data\orders.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FIRSTROW = 2,
    FIRE_TRIGGERS     -- Fire INSERT triggers for each batch
);
```

When `FIRE_TRIGGERS` is specified:
- The trigger fires once per batch (not once per row).
- The `inserted` table in the trigger contains all rows in the batch.
- This can have significant performance implications for large loads.

### Enabling CHECK Constraints

```sql
BULK INSERT dbo.Orders
FROM 'C:\Data\orders.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FIRSTROW = 2,
    CHECK_CONSTRAINTS   -- Evaluate CHECK constraints
);
```

### Post-Load Constraint Validation

If you skip constraint checking during load, validate afterward:

```sql
-- Re-enable and check constraints after bulk load
ALTER TABLE dbo.Orders WITH CHECK CHECK CONSTRAINT ALL;

-- Verify constraints are trusted
SELECT
    name AS ConstraintName,
    is_not_trusted,
    is_disabled
FROM sys.check_constraints
WHERE parent_object_id = OBJECT_ID('dbo.Orders');

-- Find rows that violate constraints
DBCC CHECKCONSTRAINTS ('dbo.Orders');
```

### Important: Constraint Trust

When bulk loading without `CHECK_CONSTRAINTS`, existing CHECK and FOREIGN KEY constraints become **untrusted** (`is_not_trusted = 1`). Untrusted constraints are not used by the query optimizer for plan simplification. Always re-check constraints after bulk load:

```sql
-- Make constraints trusted again
ALTER TABLE dbo.Orders WITH CHECK CHECK CONSTRAINT ALL;
```

---

## Performance Optimization

### Summary of Best Practices

```
1. Use TABLOCK for minimal logging
2. Use appropriate recovery model (BULK_LOGGED)
3. Drop/disable indexes before load, rebuild after
4. Use ORDER hint when data is pre-sorted
5. Use appropriate batch size
6. Disable triggers and constraints during load
7. Use native format for SQL-to-SQL transfers
8. Split large files for parallel loading
9. Size the log file appropriately before loading
10. Use a dedicated staging table
```

### Drop Indexes, Load, Rebuild

```sql
-- Step 1: Drop nonclustered indexes
DROP INDEX IX_FactSales_CustomerID ON dbo.FactSales;
DROP INDEX IX_FactSales_ProductID ON dbo.FactSales;
DROP INDEX IX_FactSales_OrderDate ON dbo.FactSales;

-- Step 2: Bulk load with minimal logging
ALTER DATABASE SalesDB SET RECOVERY BULK_LOGGED;

BULK INSERT dbo.FactSales
FROM 'C:\Data\fact_sales.csv'
WITH (
    FORMAT = 'CSV',
    FIRSTROW = 2,
    TABLOCK,
    BATCHSIZE = 500000,
    ORDER (SalesKey ASC)        -- Data is sorted by clustering key
);

ALTER DATABASE SalesDB SET RECOVERY FULL;
BACKUP LOG SalesDB TO DISK = 'C:\Backups\SalesDB_AfterBulk.trn';

-- Step 3: Rebuild indexes (with parallelism)
CREATE NONCLUSTERED INDEX IX_FactSales_CustomerID ON dbo.FactSales (CustomerID)
    WITH (SORT_IN_TEMPDB = ON, MAXDOP = 4, ONLINE = ON);
CREATE NONCLUSTERED INDEX IX_FactSales_ProductID ON dbo.FactSales (ProductID)
    WITH (SORT_IN_TEMPDB = ON, MAXDOP = 4, ONLINE = ON);
CREATE NONCLUSTERED INDEX IX_FactSales_OrderDate ON dbo.FactSales (OrderDate)
    WITH (SORT_IN_TEMPDB = ON, MAXDOP = 4, ONLINE = ON);
```

### Staging Table Pattern

```sql
-- Load into a staging table (heap, no indexes, no constraints)
CREATE TABLE dbo.Staging_FactSales (
    SalesKey      INT,
    CustomerID    INT,
    ProductID     INT,
    OrderDate     DATE,
    Quantity      INT,
    Amount        DECIMAL(12,2)
);

-- Bulk load into staging
BULK INSERT dbo.Staging_FactSales
FROM 'C:\Data\fact_sales.csv'
WITH (
    FORMAT = 'CSV',
    FIRSTROW = 2,
    TABLOCK
);

-- Validate, cleanse, and transform
DELETE FROM dbo.Staging_FactSales WHERE Amount < 0 OR CustomerID IS NULL;

-- Insert into production table
INSERT INTO dbo.FactSales WITH (TABLOCK)
SELECT * FROM dbo.Staging_FactSales
ORDER BY SalesKey;   -- Sorted insert for clustered index

-- Clean up
DROP TABLE dbo.Staging_FactSales;
```

### Network Packet Size

```bash
# Increase packet size for large transfers (default is 4096, max is 65535)
bcp SalesDB.dbo.FactSales in C:\Data\sales.csv -c -t"," -a 65535 -h "TABLOCK" -T -S localhost
```

### Pre-Sizing the Transaction Log

```sql
-- Pre-size the log to avoid autogrow during bulk operations
ALTER DATABASE SalesDB MODIFY FILE (NAME = SalesDB_Log, SIZE = 50GB);
```

### Trace Flag 610 (Minimal Logging into Non-Empty B-Trees)

```sql
-- SQL Server 2016+ handles this automatically in most cases
-- For older versions, enable trace flag 610
DBCC TRACEON(610, -1);

-- Verify
DBCC TRACESTATUS(610);
```

---

## Common Interview Questions

### Q1: What is the difference between BCP, BULK INSERT, and OPENROWSET(BULK)?

**A:** All three use the same underlying bulk insert API, but differ in invocation and flexibility. **BCP** is a command-line utility that can both import and export data, useful for scripted/scheduled operations and is the only option for native format export. **BULK INSERT** is a T-SQL statement that imports data server-side; the file must be accessible from the SQL Server machine. **OPENROWSET(BULK)** reads a file as a rowset in a SELECT statement, allowing transformations during import and the ability to read entire files into variables (SINGLE_BLOB/CLOB/NCLOB). BULK INSERT and OPENROWSET(BULK) run within the SQL Server process, while BCP runs as an external client.

### Q2: How do you achieve minimal logging during bulk operations?

**A:** Minimal logging requires: (1) Database recovery model set to SIMPLE or BULK_LOGGED. (2) TABLOCK hint specified on the bulk operation. (3) The target table must meet certain conditions -- empty tables always qualify; non-empty tables with a clustered index need the data to be sorted by the clustering key (ORDER hint) and, on older SQL Server versions, trace flag 610. Under minimal logging, SQL Server logs only extent allocations rather than individual row inserts, reducing log I/O by up to 90%. After switching back to FULL recovery, always take an immediate log backup.

### Q3: What is a format file and when do you need one?

**A:** A format file defines the mapping between columns in a data file and columns in a target table. You need one when: (1) The file has more or fewer columns than the table. (2) Column order in the file differs from the table. (3) You want to skip columns (like identity columns). (4) Data types in the file need explicit mapping. (5) You need to handle complex delimiters. Format files come in two formats: non-XML (legacy, positional) and XML (more readable, supports advanced mappings). You can generate a starting template using `bcp ... format nul -f filename`.

### Q4: How do you handle errors during bulk import?

**A:** Use `MAXERRORS` to specify the maximum tolerable error count before aborting. Use `ERRORFILE` to capture rejected rows and their error details (SQL Server writes two files: the data file and a corresponding .Error.Txt file). Use `BATCHSIZE` to limit the blast radius -- if a batch fails, only that batch rolls back; prior batches are committed. Wrap BULK INSERT in TRY/CATCH for programmatic error handling. For BCP, use `-m` (max errors) and `-e` (error file) switches.

### Q5: What happens to triggers and constraints during bulk operations?

**A:** By default, bulk operations skip INSERT triggers and CHECK constraint evaluation. NOT NULL, PRIMARY KEY, UNIQUE, and FOREIGN KEY constraints are still enforced. To fire triggers, specify `FIRE_TRIGGERS` (triggers fire once per batch, not per row). To evaluate CHECK constraints, specify `CHECK_CONSTRAINTS`. When constraints are skipped, they become untrusted (`is_not_trusted = 1`), which prevents the optimizer from using them for plan simplification. After loading, run `ALTER TABLE ... WITH CHECK CHECK CONSTRAINT ALL` to revalidate and re-trust constraints.

### Q6: How would you bulk load a very large file (e.g., 100 GB) efficiently?

**A:** Strategy: (1) Pre-size the transaction log and data files to avoid autogrow. (2) Switch to BULK_LOGGED recovery model. (3) Load into a heap staging table (no indexes, no constraints). (4) Split the file into multiple parts and run parallel BCP or BULK INSERT operations with TABLOCK. (5) Use a large packet size (`-a 65535`) for BCP. (6) Use appropriate BATCHSIZE (e.g., 500K rows) for recoverability. (7) After loading staging, validate and cleanse data. (8) INSERT into the production table with TABLOCK, or swap partitions if using partitioning. (9) Rebuild indexes with SORT_IN_TEMPDB and parallel MAXDOP. (10) Switch back to FULL recovery and take a log backup.

### Q7: What is the difference between BATCHSIZE and ROWS_PER_BATCH?

**A:** `BATCHSIZE` controls the actual commit boundary -- rows are committed in groups of this size. If an error occurs, only the current batch rolls back; prior batches are already committed. `ROWS_PER_BATCH` is merely an optimizer hint that tells SQL Server how many total rows to expect in the file. It does NOT control commits. SQL Server uses this hint for memory and sort allocation planning. You can (and often should) specify both: `ROWS_PER_BATCH` for the total expected count and `BATCHSIZE` for the commit interval.

### Q8: How do you handle CSV files with embedded commas or quotes?

**A:** In SQL Server 2017+, use `FORMAT = 'CSV'` with `FIELDQUOTE = '"'`. This correctly handles fields like `"Smith, John"` (embedded commas) and `"He said ""hello"""` (escaped quotes using the CSV standard of doubled quote characters). In earlier versions, you must either preprocess the file (e.g., with PowerShell or Python to replace problematic characters), use a different delimiter, or load each line as a single VARCHAR(MAX) column into a staging table and parse it with T-SQL string functions.

### Q9: Can you bulk import data while preserving identity values? What about skipping the identity column entirely?

**A:** To preserve identity values from the data file, use `KEEPIDENTITY` in BULK INSERT or the `-E` flag in BCP. SQL Server will use the values from the file instead of auto-generating them. To skip the identity column (when the file does not contain it), use a format file that maps only the non-identity columns, or create a view on the table that excludes the identity column and bulk insert through the view.

### Q10: What is the impact of TABLOCK on concurrent access?

**A:** TABLOCK acquires a Bulk Update (BU) lock on the table, which blocks all other readers and writers for the duration of the bulk operation. This is acceptable for dedicated load windows but not for 24/7 OLTP tables. The benefit is that TABLOCK enables minimal logging and allows parallel bulk inserts (multiple BCP/BULK INSERT operations on the same heap table). If concurrent access is required during loading, consider loading into a staging table with TABLOCK, then merging into the production table, or using partition switching.

---

## Tips

- **Always test bulk operations in a non-production environment** first, especially when using MAXERRORS > 0, as partially loaded data can be difficult to reconcile.
- **Pre-size data and log files** before large bulk operations. Autogrow events during bulk loading cause significant performance degradation.
- **Use BULK_LOGGED recovery** only during planned load windows. Switch back to FULL immediately after and take a log backup.
- **FORMAT = 'CSV'** (SQL Server 2017+) is a game-changer for CSV handling. If you are on an older version, consider preprocessing files with external tools.
- **Use format files** for any non-trivial mapping. They document the expected file structure and prevent mapping errors.
- **Monitor bulk operations** using `sys.dm_exec_requests` (look for the BULK INSERT command) and `sys.dm_tran_active_transactions` for transaction size.
- **KEEPNULLS** is important when your data contains legitimate NULL values and the target columns have DEFAULT constraints. Without it, SQL Server substitutes the default value for NULLs.
- **For very large loads, use partition switching**: load data into a staging table that mirrors a single partition, then use `ALTER TABLE ... SWITCH` to instantly move the partition into the production table.
- **Native format (`-n`)** is the fastest for SQL Server to SQL Server transfers because it avoids character conversion. Use it when both source and target are SQL Server.
- **Error files** are invaluable for data quality investigations. Always specify ERRORFILE for production bulk loads so you have a record of rejected rows.
- **After bulk loading without CHECK_CONSTRAINTS**, always run `ALTER TABLE ... WITH CHECK CHECK CONSTRAINT ALL` to re-trust constraints. Untrusted constraints hurt query performance.
