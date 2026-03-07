# Data Classification & Tagging

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Object Tagging Overview](#object-tagging-overview)
2. [Creating and Managing Tags](#creating-and-managing-tags)
3. [Assigning Tags to Objects](#assigning-tags-to-objects)
4. [Allowed Tag Values](#allowed-tag-values)
5. [Tag-Based Masking Policies](#tag-based-masking-policies)
6. [System Tags and Automatic Classification](#system-tags-and-automatic-classification)
7. [The CLASSIFY Function](#the-classify-function)
8. [Querying Tag References](#querying-tag-references)
9. [SYSTEM$GET_TAG Function](#systemget_tag-function)
10. [Tag Lineage](#tag-lineage)
11. [Organizational Governance Patterns](#organizational-governance-patterns)
12. [Common Interview Questions](#common-interview-questions)
13. [Tips](#tips)

---

## Object Tagging Overview

Object tagging in Snowflake allows you to attach metadata (key-value pairs) to Snowflake objects such as databases, schemas, tables, columns, views, warehouses, and more. Tags are first-class schema-level objects that support governance, data discovery, and policy automation.

**Key characteristics:**

- Tags are schema-level objects — they live in a database.schema namespace.
- A tag is a key with an optional set of allowed values.
- Tags can be assigned to virtually any Snowflake object (databases, schemas, tables, columns, views, warehouses, stages, etc.).
- A single object can have multiple tags, but each tag key can only be assigned once per object.
- Tags propagate through lineage (tag inheritance from database to schema to table to column).
- Tags integrate with masking policies for tag-based dynamic data masking.
- Requires Enterprise Edition or higher for full governance features.

---

## Creating and Managing Tags

### Creating a Tag

```sql
CREATE OR REPLACE TAG <tag_name>
  [ ALLOWED_VALUES '<value1>', '<value2>', ... ]
  [ COMMENT = '<description>' ];
```

### Examples

```sql
-- Simple tag with no value restrictions
CREATE OR REPLACE TAG governance.tags.cost_center
  COMMENT = 'Associates objects with a business cost center';

-- Tag with allowed values (enforced enumeration)
CREATE OR REPLACE TAG governance.tags.data_sensitivity
  ALLOWED_VALUES 'PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'RESTRICTED'
  COMMENT = 'Classifies the sensitivity level of data';

-- Tag for PII classification
CREATE OR REPLACE TAG governance.tags.pii_type
  ALLOWED_VALUES 'NAME', 'EMAIL', 'SSN', 'PHONE', 'ADDRESS', 'DOB', 'NONE'
  COMMENT = 'Identifies the type of PII in a column';

-- Tag for data domain
CREATE OR REPLACE TAG governance.tags.data_domain
  ALLOWED_VALUES 'FINANCE', 'HR', 'SALES', 'ENGINEERING', 'MARKETING'
  COMMENT = 'Business domain that owns the data';
```

### Modifying a Tag

```sql
-- Add new allowed values
ALTER TAG governance.tags.data_sensitivity
  ADD ALLOWED_VALUES 'TOP_SECRET';

-- Remove an allowed value
ALTER TAG governance.tags.data_sensitivity
  DROP ALLOWED_VALUES 'TOP_SECRET';

-- Rename a tag
ALTER TAG governance.tags.cost_center
  RENAME TO governance.tags.business_cost_center;
```

### Dropping a Tag

```sql
DROP TAG governance.tags.cost_center;
```

Dropping a tag automatically removes all assignments of that tag across the account.

---

## Assigning Tags to Objects

### Syntax for Assigning Tags

Tags can be set during object creation or afterward using ALTER.

**During creation:**

```sql
CREATE TABLE hr.employees (
    employee_id   NUMBER,
    full_name     STRING WITH TAG (governance.tags.pii_type = 'NAME'),
    email         STRING WITH TAG (governance.tags.pii_type = 'EMAIL'),
    salary        NUMBER WITH TAG (governance.tags.data_sensitivity = 'CONFIDENTIAL'),
    department    STRING
)
WITH TAG (
    governance.tags.data_domain = 'HR',
    governance.tags.data_sensitivity = 'CONFIDENTIAL'
);
```

**After creation with ALTER:**

```sql
-- Tag a table
ALTER TABLE hr.employees
  SET TAG governance.tags.data_domain = 'HR';

-- Tag a column
ALTER TABLE hr.employees
  MODIFY COLUMN email
  SET TAG governance.tags.pii_type = 'EMAIL';

-- Tag a warehouse
ALTER WAREHOUSE analytics_wh
  SET TAG governance.tags.cost_center = 'ANALYTICS_TEAM';

-- Tag a database
ALTER DATABASE raw_db
  SET TAG governance.tags.data_domain = 'ENGINEERING';

-- Tag a schema
ALTER SCHEMA raw_db.public
  SET TAG governance.tags.data_sensitivity = 'INTERNAL';
```

### Removing Tags

```sql
ALTER TABLE hr.employees
  UNSET TAG governance.tags.data_domain;

ALTER TABLE hr.employees
  MODIFY COLUMN email
  UNSET TAG governance.tags.pii_type;
```

---

## Allowed Tag Values

When a tag is created with `ALLOWED_VALUES`, Snowflake enforces that only those values can be assigned. This prevents inconsistent or misspelled values.

```sql
CREATE OR REPLACE TAG governance.tags.environment
  ALLOWED_VALUES 'DEV', 'STAGING', 'PROD';

-- This succeeds
ALTER DATABASE prod_db SET TAG governance.tags.environment = 'PROD';

-- This fails with an error
ALTER DATABASE test_db SET TAG governance.tags.environment = 'TESTING';
-- Error: Invalid value 'TESTING' for tag 'ENVIRONMENT'.
-- Allowed values are: ['DEV', 'STAGING', 'PROD']
```

**Best practices for allowed values:**

- Use uppercase, consistent naming conventions.
- Keep the list of allowed values manageable (not hundreds).
- Plan values carefully — removing an allowed value requires first unassigning it from all objects.

---

## Tag-Based Masking Policies

One of the most powerful features of tagging is the ability to associate masking policies with tags rather than individual columns. When a tag with an associated masking policy is applied to a column, the masking policy is automatically enforced on that column.

### Setting a Masking Policy on a Tag

```sql
-- Step 1: Create the masking policy
CREATE OR REPLACE MASKING POLICY governance.policies.mask_pii_string
  AS (val STRING)
  RETURNS STRING
  ->
    CASE
      WHEN IS_ROLE_IN_SESSION('PII_ALLOWED') THEN val
      ELSE '***MASKED***'
    END;

-- Step 2: Associate the masking policy with the tag
ALTER TAG governance.tags.pii_type
  SET MASKING POLICY governance.policies.mask_pii_string;
```

### How It Works

Once the masking policy is set on the tag, any column that receives the `pii_type` tag is automatically masked:

```sql
-- This column is now automatically masked
ALTER TABLE hr.employees
  MODIFY COLUMN full_name
  SET TAG governance.tags.pii_type = 'NAME';

-- This column is also automatically masked
ALTER TABLE sales.contacts
  MODIFY COLUMN contact_email
  SET TAG governance.tags.pii_type = 'EMAIL';
```

No need to apply the masking policy to each column individually — the tag assignment triggers it.

### Multiple Data Types

Since a masking policy is specific to a data type, you can assign different masking policies to the same tag for different data types:

```sql
-- String masking
ALTER TAG governance.tags.data_sensitivity
  SET MASKING POLICY governance.policies.mask_sensitive_string;

-- Number masking for the same tag
ALTER TAG governance.tags.data_sensitivity
  SET MASKING POLICY governance.policies.mask_sensitive_number;
```

Snowflake automatically selects the correct policy based on the column's data type.

### Precedence Rules

- A **column-level masking policy** (directly assigned via ALTER TABLE) takes precedence over a **tag-based masking policy**.
- If a column has both a direct masking policy and a tag with a masking policy, only the direct policy is applied.

---

## System Tags and Automatic Classification

Snowflake provides system-defined tags for automatic data classification. These are built-in tags in the `SNOWFLAKE` database that identify sensitive data categories.

### System Tag Categories

| System Tag | Description |
|---|---|
| `SNOWFLAKE.CORE.SEMANTIC_CATEGORY` | The high-level semantic category (e.g., NAME, EMAIL, PHONE_NUMBER) |
| `SNOWFLAKE.CORE.PRIVACY_CATEGORY` | The privacy classification (e.g., IDENTIFIER, QUASI_IDENTIFIER, SENSITIVE) |

### Semantic Categories (Examples)

| Category | Examples |
|---|---|
| NAME | First name, last name, full name |
| EMAIL | Email addresses |
| PHONE_NUMBER | Phone/mobile numbers |
| US_SSN | US Social Security Numbers |
| IP_ADDRESS | IPv4, IPv6 addresses |
| PAYMENT_CARD | Credit/debit card numbers |
| IBAN | International Bank Account Numbers |
| US_PASSPORT | US passport numbers |
| DATE_OF_BIRTH | Birth dates |
| GENDER | Gender identifiers |
| LATITUDE / LONGITUDE | Geographic coordinates |

### Privacy Categories

| Category | Description |
|---|---|
| IDENTIFIER | Directly identifies an individual (name, SSN, email) |
| QUASI_IDENTIFIER | Could identify someone when combined with other data (ZIP code, DOB, gender) |
| SENSITIVE | Sensitive but not identifying (salary, health conditions) |

---

## The CLASSIFY Function

The `CLASSIFY` function (also available as `SYSTEM$CLASSIFY`) automatically analyzes table columns and recommends semantic and privacy categories.

### Classifying a Single Table

```sql
-- Classify all columns in a table
SELECT SYSTEM$CLASSIFY('hr.employees');
```

This returns a JSON object with classification recommendations for each column.

### Classifying with Options

```sql
-- Classify and automatically apply system tags
SELECT SYSTEM$CLASSIFY('hr.employees', {'auto_tag': true});
```

When `auto_tag` is set to true, Snowflake automatically assigns the system tags (`SEMANTIC_CATEGORY` and `PRIVACY_CATEGORY`) to the columns based on the classification results.

### Classifying a Single Column

```sql
SELECT SYSTEM$CLASSIFY_COLUMN('hr.employees', 'email');
```

### Reviewing Classification Results

```sql
-- After classification, check what tags were applied
SELECT *
FROM TABLE(
  information_schema.tag_references('hr.employees.email', 'COLUMN')
);
```

### Sample Classification Output

```json
{
  "classification_result": {
    "FULL_NAME": {
      "semantic_category": "NAME",
      "privacy_category": "IDENTIFIER",
      "confidence": "HIGH"
    },
    "EMAIL": {
      "semantic_category": "EMAIL",
      "privacy_category": "IDENTIFIER",
      "confidence": "HIGH"
    },
    "SALARY": {
      "semantic_category": null,
      "privacy_category": "SENSITIVE",
      "confidence": "MEDIUM"
    }
  }
}
```

---

## Querying Tag References

### TAG_REFERENCES (Information Schema Table Function)

Use `TAG_REFERENCES` to find all tags assigned to a specific object:

```sql
-- All tags on a specific table
SELECT *
FROM TABLE(
  information_schema.tag_references('hr.employees', 'TABLE')
);

-- All tags on a specific column
SELECT *
FROM TABLE(
  information_schema.tag_references('hr.employees.email', 'COLUMN')
);
```

### TAG_REFERENCES View (Account Usage)

For account-wide tag analysis, use the Account Usage view:

```sql
SELECT
    tag_name,
    tag_value,
    domain,           -- TABLE, COLUMN, SCHEMA, DATABASE, WAREHOUSE, etc.
    object_database,
    object_schema,
    object_name,
    column_name
FROM snowflake.account_usage.tag_references
WHERE tag_name = 'PII_TYPE'
ORDER BY object_database, object_schema, object_name;
```

### Finding All Columns Tagged as PII

```sql
SELECT
    object_database || '.' || object_schema || '.' || object_name AS table_path,
    column_name,
    tag_value AS pii_type
FROM snowflake.account_usage.tag_references
WHERE tag_name = 'PII_TYPE'
  AND domain = 'COLUMN'
  AND tag_value != 'NONE'
ORDER BY table_path, column_name;
```

### Finding All Objects in a Specific Data Domain

```sql
SELECT
    domain,
    object_database,
    object_schema,
    object_name,
    tag_value AS data_domain
FROM snowflake.account_usage.tag_references
WHERE tag_name = 'DATA_DOMAIN'
ORDER BY domain, object_database;
```

---

## SYSTEM$GET_TAG Function

`SYSTEM$GET_TAG` retrieves the tag value for a specific tag on a specific object at query time.

### Syntax

```sql
SELECT SYSTEM$GET_TAG(
  '<tag_name>',
  '<object_name>',
  '<object_domain>'
);
```

### Examples

```sql
-- Get the data sensitivity tag on a table
SELECT SYSTEM$GET_TAG(
  'governance.tags.data_sensitivity',
  'hr.employees',
  'TABLE'
);
-- Returns: 'CONFIDENTIAL'

-- Get the PII type tag on a column
SELECT SYSTEM$GET_TAG(
  'governance.tags.pii_type',
  'hr.employees.email',
  'COLUMN'
);
-- Returns: 'EMAIL'

-- Get the cost center tag on a warehouse
SELECT SYSTEM$GET_TAG(
  'governance.tags.cost_center',
  'analytics_wh',
  'WAREHOUSE'
);
-- Returns: 'ANALYTICS_TEAM'
```

### Use in Conditional Logic

```sql
-- Only allow queries if the table is not RESTRICTED
SET sensitivity = (
  SELECT SYSTEM$GET_TAG(
    'governance.tags.data_sensitivity',
    'hr.employees',
    'TABLE'
  )
);

-- Use in a script or stored procedure
IF ($sensitivity = 'RESTRICTED') THEN
    RAISE EXCEPTION 'Access to RESTRICTED tables requires approval';
END IF;
```

---

## Tag Lineage

Tags in Snowflake follow an inheritance model. When a tag is set on a parent object, it propagates to child objects unless explicitly overridden.

### Inheritance Hierarchy

```
DATABASE (tagged: data_domain = 'FINANCE')
  └── SCHEMA (inherits: data_domain = 'FINANCE')
        └── TABLE (inherits: data_domain = 'FINANCE')
              └── COLUMN (inherits: data_domain = 'FINANCE')
```

### Override Behavior

If a child object has its own tag assignment, the child's value takes precedence:

```sql
-- Database level
ALTER DATABASE finance_db
  SET TAG governance.tags.data_sensitivity = 'INTERNAL';

-- Schema level override
ALTER SCHEMA finance_db.payroll
  SET TAG governance.tags.data_sensitivity = 'CONFIDENTIAL';

-- Column level override
ALTER TABLE finance_db.payroll.salaries
  MODIFY COLUMN ssn
  SET TAG governance.tags.data_sensitivity = 'RESTRICTED';
```

In this example:
- `finance_db.public.reports.report_name` inherits `INTERNAL` from the database.
- `finance_db.payroll.salaries.department` inherits `CONFIDENTIAL` from the schema.
- `finance_db.payroll.salaries.ssn` is explicitly `RESTRICTED`.

### Checking Effective Tag (Resolved Through Lineage)

```sql
-- SYSTEM$GET_TAG resolves the effective tag value,
-- accounting for inheritance and overrides
SELECT SYSTEM$GET_TAG(
  'governance.tags.data_sensitivity',
  'finance_db.payroll.salaries.department',
  'COLUMN'
);
-- Returns: 'CONFIDENTIAL' (inherited from schema)
```

---

## Organizational Governance Patterns

### Pattern 1: Centralized Tag and Policy Management

```sql
-- Dedicated governance database
CREATE DATABASE governance;
CREATE SCHEMA governance.tags;
CREATE SCHEMA governance.policies;

-- Create all tags in governance.tags
CREATE TAG governance.tags.data_sensitivity
  ALLOWED_VALUES 'PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'RESTRICTED';
CREATE TAG governance.tags.pii_type
  ALLOWED_VALUES 'NAME', 'EMAIL', 'SSN', 'PHONE', 'ADDRESS', 'DOB', 'NONE';
CREATE TAG governance.tags.data_domain
  ALLOWED_VALUES 'FINANCE', 'HR', 'SALES', 'ENGINEERING', 'MARKETING';
CREATE TAG governance.tags.data_owner
  COMMENT = 'Team or individual responsible for data quality';
CREATE TAG governance.tags.retention_days
  COMMENT = 'Number of days to retain data before archival';

-- Create all masking policies in governance.policies
-- Associate masking policies with tags
ALTER TAG governance.tags.pii_type
  SET MASKING POLICY governance.policies.mask_pii_string;
```

### Pattern 2: Classification and Auto-Tagging Pipeline

```sql
-- Step 1: Classify all tables in a schema
CALL classify_all_tables('raw_db', 'public');

-- Step 2: Review classifications in a governance report
SELECT
    object_name,
    column_name,
    tag_name,
    tag_value
FROM snowflake.account_usage.tag_references
WHERE tag_database = 'SNOWFLAKE'
  AND tag_schema = 'CORE'
  AND object_database = 'RAW_DB'
  AND object_schema = 'PUBLIC'
ORDER BY object_name, column_name;

-- Step 3: Map system tags to custom tags (optional)
-- Create a stored procedure that reads system classification results
-- and assigns your custom governance tags accordingly
```

### Pattern 3: Cost Attribution with Tags

```sql
-- Tag all warehouses with their cost center
ALTER WAREHOUSE etl_wh SET TAG governance.tags.cost_center = 'DATA_ENGINEERING';
ALTER WAREHOUSE analytics_wh SET TAG governance.tags.cost_center = 'ANALYTICS';
ALTER WAREHOUSE ml_wh SET TAG governance.tags.cost_center = 'DATA_SCIENCE';

-- Query warehouse usage with cost attribution
SELECT
    tr.tag_value AS cost_center,
    wuh.warehouse_name,
    SUM(wuh.credits_used) AS total_credits
FROM snowflake.account_usage.warehouse_metering_history wuh
JOIN snowflake.account_usage.tag_references tr
  ON tr.object_name = wuh.warehouse_name
  AND tr.tag_name = 'COST_CENTER'
  AND tr.domain = 'WAREHOUSE'
WHERE wuh.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY tr.tag_value, wuh.warehouse_name
ORDER BY total_credits DESC;
```

### Pattern 4: Data Catalog and Discovery

```sql
-- Build a data catalog view using tags
CREATE OR REPLACE VIEW governance.reporting.data_catalog AS
SELECT
    object_database,
    object_schema,
    object_name,
    column_name,
    tag_name,
    tag_value,
    domain
FROM snowflake.account_usage.tag_references
WHERE deleted IS NULL
ORDER BY object_database, object_schema, object_name, column_name;

-- Find all confidential data across the account
SELECT DISTINCT
    object_database || '.' || object_schema || '.' || object_name AS full_path,
    column_name,
    tag_value
FROM governance.reporting.data_catalog
WHERE tag_name = 'DATA_SENSITIVITY'
  AND tag_value IN ('CONFIDENTIAL', 'RESTRICTED');
```

---

## Common Interview Questions

### Q1: What is the difference between a tag and a masking policy in Snowflake?

**Answer:** A tag is a metadata label (key-value pair) attached to Snowflake objects for classification, governance, and discovery. A masking policy is a security object that defines how column data is masked at query time. They work together: a masking policy can be associated with a tag, so any column that receives that tag is automatically masked. Tags categorize data; masking policies protect it.

### Q2: How does tag-based masking differ from direct column masking?

**Answer:** With direct column masking, you explicitly apply a masking policy to each column using ALTER TABLE ... SET MASKING POLICY. With tag-based masking, you associate a masking policy with a tag, and any column that receives that tag is automatically masked. Tag-based masking is more scalable — tag one column and the masking follows automatically. Direct column masking takes precedence if both are present.

### Q3: What does the CLASSIFY function do?

**Answer:** `SYSTEM$CLASSIFY` (or `CLASSIFY`) analyzes the data in a table's columns and recommends semantic categories (e.g., EMAIL, NAME, SSN) and privacy categories (IDENTIFIER, QUASI_IDENTIFIER, SENSITIVE). It uses sampling and pattern matching. With the `auto_tag` option set to true, it automatically assigns Snowflake's built-in system tags (`SNOWFLAKE.CORE.SEMANTIC_CATEGORY` and `SNOWFLAKE.CORE.PRIVACY_CATEGORY`) to the columns.

### Q4: How does tag inheritance work?

**Answer:** Tags propagate from parent objects to child objects in the hierarchy: database to schema to table to column. If a database is tagged with `data_domain = 'FINANCE'`, all schemas, tables, and columns within it inherit that tag unless they explicitly override it with their own value. The most specific (closest to the object) tag assignment wins.

### Q5: Can you restrict what values a tag can have?

**Answer:** Yes. When creating a tag, use the `ALLOWED_VALUES` clause to define an enumeration of permitted values. Any attempt to assign a value not in the allowed list will fail with an error. This ensures consistency and prevents typos or non-standard values.

### Q6: How would you find all PII columns across your entire Snowflake account?

**Answer:** Query the `snowflake.account_usage.tag_references` view, filtering on the relevant tag name:

```sql
SELECT object_database, object_schema, object_name, column_name, tag_value
FROM snowflake.account_usage.tag_references
WHERE tag_name = 'PII_TYPE'
  AND domain = 'COLUMN'
  AND tag_value != 'NONE';
```

Alternatively, if using Snowflake's automatic classification, filter on `SNOWFLAKE.CORE.SEMANTIC_CATEGORY` system tags.

### Q7: What privileges are required to create and assign tags?

**Answer:** To create a tag, you need `CREATE TAG` privilege on the schema. To assign a tag to an object, you need the `APPLY TAG` privilege on the account (or on the specific tag) plus appropriate ownership or modify privileges on the target object. A common pattern is to create a `TAG_ADMIN` role with these privileges.

### Q8: What happens when you drop a tag?

**Answer:** Dropping a tag removes the tag definition and all of its assignments across the entire account. Any tag-based masking policies associated with the tag are also disassociated. This is a significant action — always verify tag usage via `TAG_REFERENCES` before dropping.

### Q9: How would you implement a data governance framework using tags?

**Answer:** Create a centralized governance database with schemas for tags and policies. Define a standard taxonomy of tags (data sensitivity, PII type, data domain, data owner, retention). Use `ALLOWED_VALUES` for consistency. Run `SYSTEM$CLASSIFY` on all tables to auto-discover sensitive data. Associate masking policies with sensitivity tags for automatic protection. Build reporting views on top of `tag_references` for auditing and catalog purposes. Assign a dedicated governance role to manage tags and policies.

### Q10: Can tags be applied to non-table objects like warehouses and stages?

**Answer:** Yes. Tags can be applied to a wide range of Snowflake objects including databases, schemas, tables, columns, views, warehouses, stages, integrations, tasks, streams, pipes, and user/role objects. This makes tags versatile for cost attribution (tagging warehouses), environment identification (tagging databases), and access governance.

---

## Tips

- **Establish a tag taxonomy before you start tagging.** Define your standard tag names, allowed values, and naming conventions in a governance document first. Retrofitting inconsistent tags is painful.
- **Use ALLOWED_VALUES** to enforce consistency. Without them, you will inevitably get `'CONFIDENTAL'`, `'Confidential'`, and `'confidential'` as separate values.
- **Prefer tag-based masking over direct column masking** when you have many columns with the same sensitivity profile. It scales much better — tag the column and the policy follows.
- **Run SYSTEM$CLASSIFY regularly**, especially after new tables are loaded. It catches PII that human reviewers might miss.
- **The Account Usage tag_references view has latency** (up to 2 hours). For real-time tag lookups, use `SYSTEM$GET_TAG` or the Information Schema `TAG_REFERENCES` table function.
- **Be cautious when dropping tags** — all assignments are removed immediately and cannot be recovered.
- **Tag warehouses for cost attribution.** This is one of the easiest wins — join `tag_references` with `warehouse_metering_history` to build cost-by-team reports.
- **Create a TAG_ADMIN role** with centralized privileges for tag management. Do not let individual teams create ad-hoc tags without governance approval.
- **Remember that direct column masking takes precedence** over tag-based masking. If you see unexpected masking behavior, check for both.
