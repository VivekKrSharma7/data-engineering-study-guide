# Dynamic Data Masking & Row Access Policies

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Dynamic Data Masking Overview](#dynamic-data-masking-overview)
2. [Masking Policy Syntax](#masking-policy-syntax)
3. [Role-Based Masking](#role-based-masking)
4. [Column-Based and Conditional Masking](#column-based-and-conditional-masking)
5. [Masking Policies on VARIANT Data](#masking-policies-on-variant-data)
6. [Column-Level Security with Masking](#column-level-security-with-masking)
7. [Row Access Policies](#row-access-policies)
8. [Row Access Policy Syntax](#row-access-policy-syntax)
9. [Mapping Tables for Row Filtering](#mapping-tables-for-row-filtering)
10. [Combining Masking and Row Access Policies](#combining-masking-and-row-access-policies)
11. [Policy Administration](#policy-administration)
12. [POLICY_REFERENCES Function](#policy_references-function)
13. [Testing Policies](#testing-policies)
14. [Common Interview Questions](#common-interview-questions)
15. [Tips](#tips)

---

## Dynamic Data Masking Overview

Dynamic Data Masking (DDM) is a column-level security feature in Snowflake that uses masking policies to selectively mask data at query time. The underlying data in the table is never modified — masking is applied dynamically when query results are returned.

**Key characteristics:**

- Data at rest remains unchanged; masking happens on read.
- Policies are schema-level objects that can be reused across tables and views.
- Masking is transparent to the querying user — they simply see masked or unmasked values depending on their context.
- Supports all Snowflake data types including VARIANT, OBJECT, and ARRAY.
- Requires Enterprise Edition or higher.

**How it fits into governance:**

Dynamic Data Masking is one pillar of Snowflake's column-level security. Combined with Row Access Policies (row-level security), it enables fine-grained access control without duplicating data or maintaining separate views for different audiences.

---

## Masking Policy Syntax

### Creating a Masking Policy

```sql
CREATE OR REPLACE MASKING POLICY <policy_name>
  AS (val <data_type>)
  RETURNS <data_type>
  -> <masking_expression>;
```

- The input parameter `val` represents the column value being evaluated.
- The `RETURNS` type must match the input data type exactly.
- The `masking_expression` is a CASE/IFF expression that determines what value to return.

### Basic Example — Mask an Email Column

```sql
CREATE OR REPLACE MASKING POLICY email_mask
  AS (val STRING)
  RETURNS STRING
  ->
    CASE
      WHEN CURRENT_ROLE() IN ('DATA_ENGINEER', 'DATA_ADMIN')
        THEN val
      ELSE '***MASKED***'
    END;
```

### Applying a Masking Policy to a Column

```sql
ALTER TABLE customers
  MODIFY COLUMN email
  SET MASKING POLICY email_mask;
```

### Removing a Masking Policy from a Column

```sql
ALTER TABLE customers
  MODIFY COLUMN email
  UNSET MASKING POLICY;
```

### Replacing a Policy (without unset first)

```sql
ALTER TABLE customers
  MODIFY COLUMN email
  SET MASKING POLICY new_email_mask FORCE;
```

The `FORCE` keyword allows replacing an existing policy in a single statement.

---

## Role-Based Masking

Role-based masking is the most common pattern. The policy inspects the current role (or role hierarchy) and returns different values accordingly.

### Using CURRENT_ROLE()

```sql
CREATE OR REPLACE MASKING POLICY ssn_mask
  AS (val STRING)
  RETURNS STRING
  ->
    CASE
      WHEN CURRENT_ROLE() IN ('HR_ADMIN', 'COMPLIANCE_OFFICER')
        THEN val
      WHEN CURRENT_ROLE() = 'HR_ANALYST'
        THEN 'XXX-XX-' || RIGHT(val, 4)   -- partial mask
      ELSE '***-**-****'
    END;
```

### Using IS_ROLE_IN_SESSION (Role Hierarchy Aware)

`CURRENT_ROLE()` checks only the primary active role. To respect the role hierarchy (i.e., a parent role inherits child role privileges), use `IS_ROLE_IN_SESSION`:

```sql
CREATE OR REPLACE MASKING POLICY salary_mask
  AS (val NUMBER)
  RETURNS NUMBER
  ->
    CASE
      WHEN IS_ROLE_IN_SESSION('FINANCE_ADMIN') THEN val
      ELSE 0
    END;
```

`IS_ROLE_IN_SESSION` returns TRUE if the specified role is the current role or any role below it in the hierarchy that the current role inherits. This is the recommended approach for most production use cases.

---

## Column-Based and Conditional Masking

### Conditional Masking (Multi-Column)

A masking policy can accept additional columns as conditional arguments to make masking decisions based on other column values in the same row.

```sql
CREATE OR REPLACE MASKING POLICY conditional_email_mask
  AS (val STRING, region STRING)
  RETURNS STRING
  ->
    CASE
      WHEN CURRENT_ROLE() = 'GLOBAL_ADMIN' THEN val
      WHEN region = 'EU' THEN '***GDPR_MASKED***'
      ELSE val
    END;
```

**Applying with conditional columns:**

```sql
ALTER TABLE customers
  MODIFY COLUMN email
  SET MASKING POLICY conditional_email_mask
  USING (email, region);
```

The `USING` clause maps table columns to the policy's input parameters. The first argument always maps to the column the policy is set on.

### Partial Masking Examples

```sql
-- Phone number: show last 4 digits
CREATE OR REPLACE MASKING POLICY phone_partial_mask
  AS (val STRING)
  RETURNS STRING
  ->
    CASE
      WHEN IS_ROLE_IN_SESSION('SUPPORT_LEAD') THEN val
      ELSE CONCAT('(***) ***-', RIGHT(val, 4))
    END;

-- Credit card: show first 4 and last 4
CREATE OR REPLACE MASKING POLICY cc_mask
  AS (val STRING)
  RETURNS STRING
  ->
    CASE
      WHEN IS_ROLE_IN_SESSION('PAYMENT_ADMIN') THEN val
      ELSE LEFT(val, 4) || '-XXXX-XXXX-' || RIGHT(val, 4)
    END;
```

---

## Masking Policies on VARIANT Data

Snowflake supports masking VARIANT, OBJECT, and ARRAY columns. The policy input and return types must both be VARIANT.

### Masking an Entire VARIANT Column

```sql
CREATE OR REPLACE MASKING POLICY variant_full_mask
  AS (val VARIANT)
  RETURNS VARIANT
  ->
    CASE
      WHEN IS_ROLE_IN_SESSION('DATA_ADMIN') THEN val
      ELSE TO_VARIANT('***MASKED***')
    END;
```

### Masking Specific Keys Inside a VARIANT

To selectively mask individual fields within a JSON object, reconstruct the object:

```sql
CREATE OR REPLACE MASKING POLICY variant_selective_mask
  AS (val VARIANT)
  RETURNS VARIANT
  ->
    CASE
      WHEN IS_ROLE_IN_SESSION('DATA_ADMIN')
        THEN val
      ELSE
        OBJECT_INSERT(
          OBJECT_INSERT(
            OBJECT_INSERT(
              OBJECT_CONSTRUCT(), 'name', '***MASKED***'::VARIANT
            ), 'age', val:age
          ), 'city', val:city
        )
    END;
```

In this example, the `name` field is masked while `age` and `city` remain visible.

---

## Column-Level Security with Masking

Column-level security in Snowflake is implemented through masking policies. Unlike traditional RBAC which controls access to entire tables or views, masking policies provide per-column control.

**Design patterns:**

| Pattern | Description |
|---|---|
| One policy per data type | A single STRING masking policy reused on all sensitive string columns |
| One policy per sensitivity level | Different policies for PII, financial, health data |
| Conditional policies | A single policy with USING clause adapts behavior by column context |

### Centralized Policy Management

```sql
-- Create a dedicated database for governance objects
CREATE DATABASE IF NOT EXISTS governance;
CREATE SCHEMA IF NOT EXISTS governance.policies;

-- Policies live in the governance schema
CREATE OR REPLACE MASKING POLICY governance.policies.pii_string_mask
  AS (val STRING)
  RETURNS STRING
  ->
    CASE
      WHEN IS_ROLE_IN_SESSION('PII_ALLOWED') THEN val
      ELSE '***PII_MASKED***'
    END;

-- Apply across different databases/schemas
ALTER TABLE raw_db.public.customers
  MODIFY COLUMN first_name
  SET MASKING POLICY governance.policies.pii_string_mask;

ALTER TABLE raw_db.public.customers
  MODIFY COLUMN last_name
  SET MASKING POLICY governance.policies.pii_string_mask;

ALTER TABLE analytics_db.reporting.user_profiles
  MODIFY COLUMN full_name
  SET MASKING POLICY governance.policies.pii_string_mask;
```

---

## Row Access Policies

Row Access Policies (RAP) provide row-level security by filtering rows returned to users based on conditions evaluated at query time. Like masking policies, the underlying data is unchanged — rows are simply excluded from query results.

**Key characteristics:**

- A table or view can have only one row access policy at a time.
- Row access policies are evaluated before masking policies.
- The policy returns a boolean: TRUE means the row is visible, FALSE means it is filtered out.
- Requires Enterprise Edition or higher.

---

## Row Access Policy Syntax

### Creating a Row Access Policy

```sql
CREATE OR REPLACE ROW ACCESS POLICY <policy_name>
  AS (<binding_columns>)
  RETURNS BOOLEAN
  -> <filter_expression>;
```

### Basic Example — Region-Based Filtering

```sql
CREATE OR REPLACE ROW ACCESS POLICY region_filter
  AS (region_col STRING)
  RETURNS BOOLEAN
  ->
    CASE
      WHEN IS_ROLE_IN_SESSION('GLOBAL_ADMIN') THEN TRUE
      WHEN IS_ROLE_IN_SESSION('NA_ANALYST') AND region_col = 'NA' THEN TRUE
      WHEN IS_ROLE_IN_SESSION('EU_ANALYST') AND region_col = 'EU' THEN TRUE
      ELSE FALSE
    END;
```

### Applying a Row Access Policy

```sql
ALTER TABLE sales_data
  ADD ROW ACCESS POLICY region_filter ON (region);
```

### Removing a Row Access Policy

```sql
ALTER TABLE sales_data
  DROP ROW ACCESS POLICY region_filter;
```

### Multi-Column Binding

Row access policies can reference multiple columns:

```sql
CREATE OR REPLACE ROW ACCESS POLICY dept_and_level_filter
  AS (department STRING, sensitivity_level NUMBER)
  RETURNS BOOLEAN
  ->
    IS_ROLE_IN_SESSION('EXECUTIVE')
    OR
    (IS_ROLE_IN_SESSION('MANAGER') AND sensitivity_level <= 3)
    OR
    (department = 'ENGINEERING' AND IS_ROLE_IN_SESSION('ENGINEERING_READ'));

ALTER TABLE employee_records
  ADD ROW ACCESS POLICY dept_and_level_filter ON (department, sensitivity_level);
```

---

## Mapping Tables for Row Filtering

A common production pattern is to use a **mapping table** (also called an entitlement table) that maps roles or users to the data they are allowed to see. This avoids hardcoding role names in the policy.

### Step 1: Create the Mapping Table

```sql
CREATE OR REPLACE TABLE governance.policies.row_access_mapping (
    role_name   STRING,
    region      STRING
);

INSERT INTO governance.policies.row_access_mapping VALUES
  ('NA_SALES',   'NA'),
  ('EU_SALES',   'EU'),
  ('APAC_SALES', 'APAC'),
  ('GLOBAL_SALES', 'NA'),
  ('GLOBAL_SALES', 'EU'),
  ('GLOBAL_SALES', 'APAC');
```

### Step 2: Create the Policy Using the Mapping Table

```sql
CREATE OR REPLACE ROW ACCESS POLICY region_mapping_policy
  AS (region_col STRING)
  RETURNS BOOLEAN
  ->
    EXISTS (
      SELECT 1
      FROM governance.policies.row_access_mapping m
      WHERE m.region = region_col
        AND IS_ROLE_IN_SESSION(m.role_name)
    );
```

### Step 3: Apply the Policy

```sql
ALTER TABLE sales_transactions
  ADD ROW ACCESS POLICY region_mapping_policy ON (region);
```

**Advantages of mapping tables:**

- Adding or removing access requires only DML (INSERT/DELETE) on the mapping table, not DDL changes to the policy.
- Auditable: you can query the mapping table to see who has access to what.
- Scalable: works well with hundreds of roles and regions.

**Performance consideration:** Snowflake recommends keeping mapping tables small and clustered, since the subquery runs for every row evaluated.

---

## Combining Masking and Row Access Policies

Both policy types can coexist on the same table. Snowflake evaluates them in this order:

1. **Row Access Policy** is evaluated first — rows that do not satisfy the policy are filtered out.
2. **Masking Policy** is applied to columns of the remaining (visible) rows.

### Example: Combined Setup

```sql
-- Row Access Policy: analysts only see their department
ALTER TABLE hr.employees
  ADD ROW ACCESS POLICY dept_filter ON (department);

-- Masking Policy: salary is masked unless you are in FINANCE
ALTER TABLE hr.employees
  MODIFY COLUMN salary
  SET MASKING POLICY salary_mask;
```

A user with role `SALES_ANALYST` would:
1. Only see rows where `department = 'SALES'` (row access).
2. See `salary` as `0` instead of the actual value (masking).

---

## Policy Administration

### Required Privileges

| Action | Required Privilege |
|---|---|
| CREATE MASKING POLICY | CREATE MASKING POLICY on the schema |
| CREATE ROW ACCESS POLICY | CREATE ROW ACCESS POLICY on the schema |
| Apply/unset a masking policy on a column | APPLY MASKING POLICY on the account + ownership or APPLY on the table |
| Apply/unset a row access policy on a table | APPLY ROW ACCESS POLICY on the account + ownership or APPLY on the table |

### Recommended Governance Roles

```sql
-- Create a policy admin role
CREATE ROLE policy_admin;

-- Grant policy creation privileges
GRANT CREATE MASKING POLICY ON SCHEMA governance.policies TO ROLE policy_admin;
GRANT CREATE ROW ACCESS POLICY ON SCHEMA governance.policies TO ROLE policy_admin;

-- Grant global apply privileges
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE policy_admin;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE policy_admin;
```

### Listing Existing Policies

```sql
-- All masking policies
SHOW MASKING POLICIES;
SHOW MASKING POLICIES IN SCHEMA governance.policies;

-- All row access policies
SHOW ROW ACCESS POLICIES;
SHOW ROW ACCESS POLICIES IN SCHEMA governance.policies;

-- Describe a policy to see its definition
DESCRIBE MASKING POLICY email_mask;
DESCRIBE ROW ACCESS POLICY region_filter;
```

---

## POLICY_REFERENCES Function

`POLICY_REFERENCES` is an Information Schema table function that shows all objects (tables, views, columns) that a given policy is attached to, or all policies attached to a given object.

### Find All Objects Using a Specific Policy

```sql
SELECT *
FROM TABLE(
  information_schema.policy_references(
    policy_name => 'governance.policies.email_mask'
  )
);
```

### Find All Policies on a Specific Table

```sql
SELECT *
FROM TABLE(
  information_schema.policy_references(
    ref_entity_name   => 'raw_db.public.customers',
    ref_entity_domain => 'TABLE'
  )
);
```

### Key Columns Returned

| Column | Description |
|---|---|
| POLICY_DB | Database where the policy resides |
| POLICY_SCHEMA | Schema where the policy resides |
| POLICY_NAME | Name of the policy |
| POLICY_KIND | MASKING_POLICY or ROW_ACCESS_POLICY |
| REF_DATABASE_NAME | Database of the object the policy is applied to |
| REF_SCHEMA_NAME | Schema of the object |
| REF_ENTITY_NAME | Table or view name |
| REF_COLUMN_NAME | Column name (for masking policies) |

---

## Testing Policies

### Using EXECUTE AS to Simulate Roles

```sql
-- Test as a specific role
USE ROLE analyst_role;
SELECT email, ssn, salary FROM customers LIMIT 10;

-- Switch back
USE ROLE sysadmin;
```

### Using POLICY_CONTEXT (Simulated Policy Evaluation)

`SYSTEM$GET_POLICY_CONTEXT` is not yet available in all editions. The practical approach is:

```sql
-- 1. Create a test role and grant minimal access
CREATE ROLE test_masking_role;
GRANT USAGE ON DATABASE raw_db TO ROLE test_masking_role;
GRANT USAGE ON SCHEMA raw_db.public TO ROLE test_masking_role;
GRANT SELECT ON TABLE raw_db.public.customers TO ROLE test_masking_role;

-- 2. Test the policy
USE ROLE test_masking_role;
SELECT * FROM raw_db.public.customers LIMIT 5;
-- Verify that sensitive columns show masked values

-- 3. Cleanup
USE ROLE sysadmin;
DROP ROLE test_masking_role;
```

### Validating Row Access Policies

```sql
-- Count total rows as admin
USE ROLE global_admin;
SELECT COUNT(*) FROM sales_data;
-- Returns: 1,000,000

-- Count rows as regional analyst
USE ROLE na_analyst;
SELECT COUNT(*) FROM sales_data;
-- Should return fewer rows (only NA region)
```

### Checking for Policy Conflicts

Before applying policies, verify no existing policies conflict:

```sql
SELECT *
FROM TABLE(
  information_schema.policy_references(
    ref_entity_name   => 'raw_db.public.customers',
    ref_entity_domain => 'TABLE'
  )
)
WHERE policy_kind = 'ROW_ACCESS_POLICY';
-- A table can have only ONE row access policy
```

---

## Common Interview Questions

### Q1: What is the difference between Dynamic Data Masking and Static Data Masking?

**Answer:** Dynamic Data Masking masks data at query time without altering the stored data. Different users see different results from the same query depending on their role. Static Data Masking permanently alters data (e.g., in a copy of the database) and is irreversible. Snowflake provides Dynamic Data Masking natively; static masking would require external ETL processes.

### Q2: Can a column have more than one masking policy at the same time?

**Answer:** No. A column can have at most one masking policy. To replace a policy, either UNSET the current policy first and then SET the new one, or use the `FORCE` keyword: `ALTER TABLE t MODIFY COLUMN c SET MASKING POLICY new_policy FORCE;`.

### Q3: Can a table have more than one row access policy?

**Answer:** No. A table or view can have only one row access policy at a time. If you need complex filtering logic, consolidate it into a single policy, potentially using a mapping table.

### Q4: How does IS_ROLE_IN_SESSION differ from CURRENT_ROLE()?

**Answer:** `CURRENT_ROLE()` returns the name of the currently active primary role and does not account for role hierarchy. `IS_ROLE_IN_SESSION('ROLE_NAME')` returns TRUE if the specified role is the current primary role OR is inherited by the current primary role through the role hierarchy. For governance policies, `IS_ROLE_IN_SESSION` is the recommended function because it respects role inheritance.

### Q5: What happens when both a masking policy and a row access policy are applied to the same table?

**Answer:** The row access policy is evaluated first. Rows that fail the row access policy condition are excluded from the result set entirely. Then, masking policies are applied to the columns of the remaining visible rows. A user will never see masked data for a row they cannot access — the row simply does not appear.

### Q6: How do you mask specific fields inside a VARIANT column?

**Answer:** You create a masking policy with input and return type VARIANT. Inside the policy, use functions like `OBJECT_INSERT`, `OBJECT_DELETE`, and `OBJECT_CONSTRUCT` to reconstruct the JSON with certain fields masked or removed while leaving other fields intact.

### Q7: What is the recommended approach for managing row access across many roles and data segments?

**Answer:** Use a mapping table (entitlement table) that stores the relationship between roles and the data segments they can access. The row access policy performs an EXISTS subquery against this mapping table. This decouples access management from policy DDL — adding or changing access only requires DML on the mapping table.

### Q8: What privileges are needed to apply a masking policy to a table you do not own?

**Answer:** You need the `APPLY MASKING POLICY` privilege at the account level, plus appropriate privileges on the table (such as ownership or a specific APPLY grant). Simply having ownership of the policy is not sufficient — you must also have permission to modify the target table's column.

### Q9: How can you audit which policies are applied across your account?

**Answer:** Use the `POLICY_REFERENCES` Information Schema table function. You can query it by policy name to find all objects using that policy, or by object name to find all policies applied to that object. Additionally, `SHOW MASKING POLICIES` and `SHOW ROW ACCESS POLICIES` list all policies in a given scope.

### Q10: Can masking policies be applied to views?

**Answer:** Yes. Masking policies can be applied to columns in both tables and views. When applied to a view, the policy is evaluated when the view is queried. If the underlying table also has a masking policy on the same column, only the view-level policy is applied (the view's policy takes precedence for queries through that view).

---

## Tips

- **Always use IS_ROLE_IN_SESSION** instead of CURRENT_ROLE() in production policies unless you specifically need to ignore role hierarchy.
- **Centralize policies** in a dedicated governance database/schema. This makes management, auditing, and privilege grants consistent.
- **Use mapping tables** for row access policies when you have more than a handful of role-to-data-segment mappings. Hardcoded role names become unmaintainable.
- **Test with multiple roles** before deploying. Create temporary test roles that mirror production role hierarchies and verify the expected behavior.
- **Monitor performance** of row access policies that use subqueries against mapping tables. Large mapping tables or complex joins can slow down queries. Keep mapping tables small and consider clustering them.
- **Document every policy**: which columns or tables it protects, the intended behavior for each role, and who owns the policy. This is critical for compliance audits.
- **Remember the one-policy-per-column and one-RAP-per-table limits.** Design policies to be flexible (using conditional logic or mapping tables) rather than creating many narrow policies.
- **Use the FORCE keyword** when replacing a masking policy to avoid the two-step UNSET/SET process, which leaves a brief window where the column is unprotected.
- **Be careful with ACCOUNTADMIN**: by default, even ACCOUNTADMIN is subject to masking and row access policies unless the policy explicitly allows it. Always include your admin roles in the policy's allowlist.
