# Snowflake & CI/CD — Schemachange, Terraform, and Pipeline Design

[Back to Snowflake Index](./README.md)

---

## 1. Overview

Managing Snowflake infrastructure and schema changes through CI/CD pipelines is a cornerstone of production-grade data engineering. This involves:

- **Database Change Management (DCM)** — versioned, repeatable, and auditable schema migrations
- **Infrastructure as Code (IaC)** — managing Snowflake objects (warehouses, roles, grants) declaratively
- **Automated Pipelines** — testing and promoting changes across environments without manual intervention

Key tools in this space:
| Tool | Purpose |
|---|---|
| **Schemachange** | Database migration tool (versioned & repeatable SQL scripts) |
| **Terraform** (Snowflake provider) | Infrastructure as Code for Snowflake objects |
| **Snowflake CLI (SnowCLI / snow)** | Command-line interface for Snowflake operations |
| **GitHub Actions / Azure DevOps** | CI/CD orchestration |

---

## 2. Database Change Management Concepts

### The Problem

Without DCM:
- Schema changes are applied manually and inconsistently across environments
- No audit trail of what changed, when, or by whom
- Rollbacks are ad-hoc and error-prone
- Dev, staging, and production environments drift apart

### The Solution

Apply the same principles used in application development:
1. All schema changes are stored as SQL scripts in version control
2. Scripts are applied in order by an automated tool
3. A tracking table records which scripts have been applied
4. CI/CD pipelines enforce the process

---

## 3. Schemachange

[Schemachange](https://github.com/Snowflake-Labs/schemachange) is a lightweight Python-based database change management tool, purpose-built for Snowflake. It follows the Flyway-style migration pattern.

### Installation

```bash
pip install schemachange
```

### Script Types

Schemachange supports three types of scripts:

| Type | Naming Convention | Behavior |
|---|---|---|
| **Versioned** | `V1.0.0__description.sql` | Run once, in order. Never modified after deployment. |
| **Repeatable** | `R__description.sql` | Run every time the content changes (checksum-based). |
| **Always** | `A__description.sql` | Run on every deployment, regardless of changes. |

### Directory Structure

```
migrations/
├── V1.0.0__create_raw_database.sql
├── V1.1.0__create_staging_schema.sql
├── V1.2.0__create_orders_table.sql
├── V1.3.0__add_status_column_to_orders.sql
├── R__grant_permissions.sql           # Repeatable — reapply on change
├── R__create_views.sql
└── A__refresh_tasks.sql               # Always — run every time
```

### Versioned Scripts

Versioned scripts run exactly once and must never be modified after being applied. They represent a point-in-time migration.

```sql
-- V1.2.0__create_orders_table.sql
CREATE TABLE IF NOT EXISTS RAW.PUBLIC.ORDERS (
    order_id NUMBER PRIMARY KEY,
    customer_id NUMBER NOT NULL,
    order_date DATE NOT NULL,
    status VARCHAR(50) DEFAULT 'pending',
    total_amount NUMBER(12,2),
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

```sql
-- V1.3.0__add_status_column_to_orders.sql
ALTER TABLE RAW.PUBLIC.ORDERS
    ADD COLUMN updated_at TIMESTAMP_NTZ;
```

### Repeatable Scripts

Repeatable scripts are re-executed whenever their content changes (detected via checksum). Ideal for objects that are fully replaced on each run.

```sql
-- R__grant_permissions.sql
USE ROLE SECURITYADMIN;

GRANT USAGE ON DATABASE RAW TO ROLE DATA_ENGINEER;
GRANT USAGE ON SCHEMA RAW.PUBLIC TO ROLE DATA_ENGINEER;
GRANT SELECT ON ALL TABLES IN SCHEMA RAW.PUBLIC TO ROLE DATA_ENGINEER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW.PUBLIC TO ROLE DATA_ENGINEER;
```

### Jinja Templating in Schemachange

Schemachange supports Jinja2 templates for dynamic scripts:

```sql
-- V2.0.0__create_environment_schema.sql
CREATE SCHEMA IF NOT EXISTS {{ env }}_ANALYTICS;

CREATE TABLE IF NOT EXISTS {{ env }}_ANALYTICS.METRICS (
    metric_id NUMBER AUTOINCREMENT,
    metric_name VARCHAR(255),
    metric_value FLOAT,
    recorded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

### Running Schemachange

```bash
# Basic execution
schemachange deploy \
    --snowflake-account xy12345.us-east-1 \
    --snowflake-user DEPLOY_USER \
    --snowflake-role SYSADMIN \
    --snowflake-warehouse WH_DEPLOY \
    --snowflake-database METADATA \
    --snowflake-schema SCHEMACHANGE \
    --root-folder migrations/ \
    --change-history-table METADATA.SCHEMACHANGE.CHANGE_HISTORY

# With Jinja variables
schemachange deploy \
    --vars '{"env": "PROD"}' \
    --root-folder migrations/ \
    ...

# Dry run — shows what would be applied without executing
schemachange deploy --dry-run ...
```

### Change History Table

Schemachange automatically creates and maintains a tracking table:

```
CHANGE_HISTORY
├── VERSION          -- e.g., "1.2.0"
├── DESCRIPTION      -- e.g., "create_orders_table"
├── SCRIPT           -- Full script name
├── SCRIPT_TYPE      -- V, R, or A
├── CHECKSUM         -- MD5 hash of script content
├── EXECUTION_TIME   -- Duration in seconds
├── STATUS           -- Success/Failure
├── INSTALLED_BY     -- User who ran it
├── INSTALLED_ON     -- Timestamp
```

---

## 4. Terraform Snowflake Provider

Terraform manages Snowflake infrastructure declaratively — you define the desired state, and Terraform makes it so.

### Setup

```hcl
# providers.tf
terraform {
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.90"
    }
  }
}

provider "snowflake" {
  organization_name = "MYORG"
  account_name      = "MYACCOUNT"
  user              = var.snowflake_user
  private_key       = var.snowflake_private_key
  role              = "SYSADMIN"
}
```

### Managing Snowflake Objects

```hcl
# databases.tf
resource "snowflake_database" "analytics" {
  name                        = "ANALYTICS"
  data_retention_time_in_days = 7
  comment                     = "Analytics consumption database"
}

resource "snowflake_schema" "staging" {
  database = snowflake_database.analytics.name
  name     = "STAGING"
  comment  = "Staging schema for intermediate transforms"
}

resource "snowflake_schema" "marts" {
  database = snowflake_database.analytics.name
  name     = "MARTS"
  comment  = "Business-facing data marts"
}
```

```hcl
# warehouses.tf
resource "snowflake_warehouse" "etl" {
  name                = "WH_ETL"
  warehouse_size      = "MEDIUM"
  auto_suspend        = 120
  auto_resume         = true
  min_cluster_count   = 1
  max_cluster_count   = 3
  scaling_policy      = "STANDARD"
  initially_suspended = true
  comment             = "ETL processing warehouse"
}

resource "snowflake_warehouse" "analytics" {
  name                = "WH_ANALYTICS"
  warehouse_size      = "SMALL"
  auto_suspend        = 60
  auto_resume         = true
  initially_suspended = true
}
```

```hcl
# roles_and_grants.tf
resource "snowflake_account_role" "data_engineer" {
  name    = "DATA_ENGINEER"
  comment = "Role for data engineering team"
}

resource "snowflake_grant_privileges_to_account_role" "de_db_usage" {
  account_role_name = snowflake_account_role.data_engineer.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.analytics.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "de_wh_usage" {
  account_role_name = snowflake_account_role.data_engineer.name
  privileges        = ["USAGE", "OPERATE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.analytics.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "de_schema_all" {
  account_role_name = snowflake_account_role.data_engineer.name
  privileges        = ["SELECT"]
  on_schema_object {
    all {
      object_type_plural = "TABLES"
      in_schema          = "\"${snowflake_database.analytics.name}\".\"${snowflake_schema.marts.name}\""
    }
  }
}
```

### Terraform Workflow

```bash
terraform init      # Initialize providers
terraform plan      # Preview changes
terraform apply     # Apply changes
terraform destroy   # Tear down (use with caution!)
```

### When to Use Terraform vs Schemachange

| Use Case | Tool |
|---|---|
| Databases, schemas, warehouses, roles, grants, integrations | **Terraform** |
| Tables, views, stored procedures, UDFs, data migrations | **Schemachange** |
| Row-level data, DML operations | **dbt / custom scripts** |
| Network policies, resource monitors, account parameters | **Terraform** |

**General rule:** Terraform for infrastructure/RBAC, Schemachange for DDL/schema evolution, dbt for data transformations.

---

## 5. CI/CD Pipeline Design

### Pipeline Stages

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Commit   │───>│  Build   │───>│  Test    │───>│  Deploy  │
│  (PR)     │    │  & Lint  │    │  (Dev)   │    │  (Prod)  │
└──────────┘    └──────────┘    └──────────┘    └──────────┘
```

1. **Commit** — Developer pushes changes to a feature branch and opens a PR
2. **Build & Lint** — Validate SQL syntax, lint with SQLFluff, run Terraform plan
3. **Test (Dev)** — Apply migrations to a dev/staging environment, run dbt tests
4. **Deploy (Prod)** — On merge to main, apply changes to production

### GitHub Actions Example

```yaml
# .github/workflows/snowflake-cicd.yml
name: Snowflake CI/CD

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

env:
  SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
  SNOWFLAKE_USER: ${{ secrets.SNOWFLAKE_USER }}
  SNOWFLAKE_PASSWORD: ${{ secrets.SNOWFLAKE_PASSWORD }}
  SNOWFLAKE_ROLE: SYSADMIN
  SNOWFLAKE_WAREHOUSE: WH_DEPLOY

jobs:
  # ---------- PR Checks ----------
  validate:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install dependencies
        run: |
          pip install schemachange sqlfluff dbt-snowflake

      - name: Lint SQL
        run: sqlfluff lint migrations/ --dialect snowflake

      - name: Dry-run Schemachange
        run: |
          schemachange deploy \
            --snowflake-account $SNOWFLAKE_ACCOUNT \
            --snowflake-user $SNOWFLAKE_USER \
            --snowflake-role $SNOWFLAKE_ROLE \
            --snowflake-warehouse $SNOWFLAKE_WAREHOUSE \
            --snowflake-database METADATA \
            --root-folder migrations/ \
            --dry-run

      - name: Terraform Plan
        working-directory: terraform/
        run: |
          terraform init
          terraform plan -no-color

  # ---------- Deploy to Dev ----------
  deploy-dev:
    if: github.event_name == 'pull_request'
    needs: validate
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: pip install schemachange dbt-snowflake

      - name: Run Schemachange (Dev)
        run: |
          schemachange deploy \
            --snowflake-account $SNOWFLAKE_ACCOUNT \
            --snowflake-user $SNOWFLAKE_USER \
            --snowflake-role $SNOWFLAKE_ROLE \
            --snowflake-warehouse $SNOWFLAKE_WAREHOUSE \
            --snowflake-database DEV_METADATA \
            --root-folder migrations/ \
            --vars '{"env": "DEV"}'

      - name: Run dbt (Dev)
        run: |
          cd dbt_project/
          dbt deps
          dbt build --target dev

  # ---------- Deploy to Prod ----------
  deploy-prod:
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: pip install schemachange dbt-snowflake

      - name: Terraform Apply
        working-directory: terraform/
        run: |
          terraform init
          terraform apply -auto-approve

      - name: Run Schemachange (Prod)
        run: |
          schemachange deploy \
            --snowflake-account $SNOWFLAKE_ACCOUNT \
            --snowflake-user $SNOWFLAKE_USER \
            --snowflake-role $SNOWFLAKE_ROLE \
            --snowflake-warehouse $SNOWFLAKE_WAREHOUSE \
            --snowflake-database METADATA \
            --root-folder migrations/ \
            --vars '{"env": "PROD"}'

      - name: Run dbt (Prod)
        run: |
          cd dbt_project/
          dbt deps
          dbt build --target prod
```

### Azure DevOps Pipeline Example

```yaml
# azure-pipelines.yml
trigger:
  branches:
    include:
      - main

pool:
  vmImage: 'ubuntu-latest'

stages:
  - stage: Validate
    jobs:
      - job: LintAndPlan
        steps:
          - task: UsePythonVersion@0
            inputs:
              versionSpec: '3.11'

          - script: pip install schemachange sqlfluff
            displayName: Install tools

          - script: sqlfluff lint migrations/ --dialect snowflake
            displayName: Lint SQL

          - script: |
              schemachange deploy --dry-run \
                --snowflake-account $(SNOWFLAKE_ACCOUNT) \
                --snowflake-user $(SNOWFLAKE_USER) \
                --snowflake-role SYSADMIN \
                --snowflake-warehouse WH_DEPLOY \
                --snowflake-database METADATA \
                --root-folder migrations/
            displayName: Dry Run Schemachange
            env:
              SNOWFLAKE_PASSWORD: $(SNOWFLAKE_PASSWORD)

  - stage: DeployProd
    dependsOn: Validate
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
    jobs:
      - deployment: DeployProduction
        environment: production
        strategy:
          runOnce:
            deploy:
              steps:
                - script: pip install schemachange
                  displayName: Install Schemachange

                - script: |
                    schemachange deploy \
                      --snowflake-account $(SNOWFLAKE_ACCOUNT) \
                      --snowflake-user $(SNOWFLAKE_USER) \
                      --snowflake-role SYSADMIN \
                      --snowflake-warehouse WH_DEPLOY \
                      --snowflake-database METADATA \
                      --root-folder migrations/ \
                      --vars '{"env": "PROD"}'
                  displayName: Deploy Schema Changes
                  env:
                    SNOWFLAKE_PASSWORD: $(SNOWFLAKE_PASSWORD)
```

---

## 6. Environment Promotion Strategy

### Multi-Environment Architecture

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│     DEV      │───>│   STAGING    │───>│  PRODUCTION  │
│              │    │              │    │              │
│ DEV_RAW      │    │ STG_RAW      │    │ RAW          │
│ DEV_ANALYTICS│    │ STG_ANALYTICS│    │ ANALYTICS    │
│ WH_DEV       │    │ WH_STG       │    │ WH_PROD      │
└──────────────┘    └──────────────┘    └──────────────┘
```

### Best Practices

1. **Promote code, not data** — The same SQL scripts run in each environment against environment-specific databases
2. **Use Jinja variables** for environment-specific naming (`{{ env }}_RAW`)
3. **Separate Snowflake accounts** for production (strongest isolation) or separate databases within one account (simpler)
4. **Service accounts** for CI/CD — never use personal credentials in pipelines
5. **Key-pair authentication** — avoid passwords in CI/CD; use RSA key pairs
6. **Approval gates** — require manual approval before production deployments

---

## 7. Snowflake CLI

The Snowflake CLI (`snow`) provides command-line access to Snowflake operations.

```bash
# Install
pip install snowflake-cli

# Configure connection
snow connection add

# Execute SQL
snow sql -q "SELECT CURRENT_WAREHOUSE(), CURRENT_ROLE();"

# Deploy Snowpark projects
snow snowpark deploy

# Manage Streamlit apps
snow streamlit deploy

# Stage file operations
snow stage copy local_file.csv @MY_STAGE/
snow stage list @MY_STAGE/
```

The CLI is particularly useful for:
- Interactive development and testing
- Scripting one-off administrative tasks
- Deploying Snowpark and Streamlit applications
- Integration with CI/CD for specialized operations

---

## 8. Schema Migration Best Practices

1. **Never modify a versioned script after it has been applied** — create a new version instead
2. **Make migrations idempotent** where possible — use `CREATE IF NOT EXISTS`, `ALTER IF EXISTS`
3. **One logical change per migration** — keep scripts focused and small
4. **Include rollback scripts** (even if manual) — document how to reverse each migration
5. **Test migrations against a clone** before production:

```sql
-- Create a zero-copy clone to test migrations safely
CREATE DATABASE ANALYTICS_MIGRATION_TEST CLONE ANALYTICS;
-- Run schemachange against the clone
-- Validate
-- Drop the clone
DROP DATABASE ANALYTICS_MIGRATION_TEST;
```

6. **Version your scripts semantically** — `V1.0.0` for major schema changes, `V1.1.0` for additions, `V1.1.1` for fixes
7. **Store Terraform state remotely** — use S3, Azure Blob, or Terraform Cloud (never local state in CI/CD)
8. **Use `terraform plan` output in PR comments** — reviewers should see exactly what infrastructure changes will occur

---

## 9. Common Interview Questions & Answers

### Q1: What is Schemachange and how does it work?

**A:** Schemachange is a Snowflake-specific database change management tool that applies versioned SQL migration scripts. It maintains a change history table that tracks which scripts have been applied (by version and checksum). Versioned scripts (V) run once in order, repeatable scripts (R) re-run when their content changes, and always scripts (A) run on every deployment. It supports Jinja templating for dynamic SQL.

### Q2: How would you design a CI/CD pipeline for Snowflake?

**A:** The pipeline should have: (1) **Validation** on PR — SQL linting with SQLFluff, Schemachange dry-run, Terraform plan. (2) **Dev deployment** — apply schema changes and run dbt in a dev environment. (3) **Production deployment** on merge to main — Terraform apply for infrastructure, Schemachange deploy for schema changes, dbt build for transformations. Use key-pair authentication for service accounts, store secrets in the CI/CD platform's vault, and require approval gates for production.

### Q3: When would you use Terraform vs Schemachange for Snowflake?

**A:** Terraform is best for infrastructure objects that are declarative — databases, schemas, warehouses, roles, grants, network policies, resource monitors, and integrations. Schemachange is best for DDL that evolves over time — table creation, ALTER statements, stored procedures, and UDFs. dbt handles data transformations (DML). The three tools complement each other and are often used together.

### Q4: What are versioned vs repeatable scripts in Schemachange?

**A:** Versioned scripts (prefix `V`) run exactly once, in version order, and must never be modified after deployment — they represent a point-in-time schema migration. Repeatable scripts (prefix `R`) re-run whenever their content changes (detected by checksum) — ideal for views, grants, and stored procedures that are fully replaced on each run. There are also always scripts (prefix `A`) that run on every deployment.

### Q5: How do you handle environment promotion in Snowflake CI/CD?

**A:** Promote code, not data. The same migration scripts and dbt models run in each environment (dev, staging, prod) against environment-specific databases. Use Jinja variables or Terraform workspaces to parameterize environment names. Separate environments using different databases within an account or, for stronger isolation, separate Snowflake accounts. Require manual approval gates before production deployments.

### Q6: How do you securely manage Snowflake credentials in CI/CD?

**A:** Use **key-pair authentication** (RSA) instead of passwords for service accounts. Store the private key in the CI/CD platform's secret manager (GitHub Secrets, Azure Key Vault). Never commit credentials to version control. Use dedicated service accounts with minimal required privileges. Rotate keys regularly and audit access via `LOGIN_HISTORY`.

---

## 10. Tips

- **Start simple** — You do not need all three tools on day one. Begin with Schemachange for schema management, then add Terraform for infrastructure, and dbt for transformations.
- **Use zero-copy clones for testing** — Clone production databases for migration testing at near-zero cost.
- **Lint everything** — SQLFluff with the Snowflake dialect catches syntax errors and enforces style before deployment.
- **Terraform state is sacred** — Use remote backends with state locking. Lost or corrupted state can cause infrastructure drift.
- **Pin provider versions** — Always pin Terraform provider and Schemachange versions to avoid breaking changes.
- **Separate infrastructure and data concerns** — Terraform manages the "container" (databases, warehouses, roles), Schemachange manages the "structure" (tables, views), dbt manages the "content" (transformations).
- **Document your pipeline** — Ensure the team understands the full flow from commit to production deployment.

---
