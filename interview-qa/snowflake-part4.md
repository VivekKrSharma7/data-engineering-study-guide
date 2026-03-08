# Advanced Snowflake - Q&A (Part 4: Security, Data Sharing and Governance)

[Back to Index](README.md)

---

### Q31. How did you implement Dynamic Data Masking for PII fields (SSN, income, credit score) in a multi-tenant loan analytics platform?

**Situation:** Our mortgage analytics platform served 15+ servicers and investors on a shared Snowflake instance. Loan-level tables contained borrower SSN, income, credit scores, and property addresses -- all classified as PII under GLBA and CCPA. Compliance mandated that only authorized underwriting and compliance roles could view unmasked data, while analytics teams and external-facing dashboards needed obfuscated values.

**Task:** Implement dynamic data masking that adapts based on the querying user's role, without duplicating tables or maintaining separate views per tenant. The solution had to pass SOC 2 Type II audit scrutiny and not degrade query performance on our 2B+ row loan fact table.

**Action:**
```sql
-- Full masking policy for SSN: show last 4 digits to semi-privileged, fully mask otherwise
CREATE OR REPLACE MASKING POLICY pii_ssn_mask AS (val STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_FULL_ACCESS')    THEN val
    WHEN IS_ROLE_IN_SESSION('PII_PARTIAL_ACCESS')  THEN CONCAT('***-**-', RIGHT(val, 4))
    ELSE '***-**-****'
  END;

-- Numeric masking for income and credit score: bucket ranges for analysts
CREATE OR REPLACE MASKING POLICY pii_income_mask AS (val NUMBER) RETURNS NUMBER ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_FULL_ACCESS') THEN val
    WHEN IS_ROLE_IN_SESSION('PII_PARTIAL_ACCESS') THEN ROUND(val, -4) -- round to nearest 10K
    ELSE NULL
  END;

CREATE OR REPLACE MASKING POLICY pii_credit_score_mask AS (val NUMBER) RETURNS NUMBER ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_FULL_ACCESS') THEN val
    WHEN IS_ROLE_IN_SESSION('PII_PARTIAL_ACCESS') THEN FLOOR(val / 50) * 50 -- bucket by 50-point bands
    ELSE NULL
  END;

-- Apply policies at column level
ALTER TABLE LOAN_MASTER SET MASKING POLICY pii_ssn_mask ON COLUMN borrower_ssn;
ALTER TABLE LOAN_MASTER SET MASKING POLICY pii_income_mask ON COLUMN borrower_income;
ALTER TABLE LOAN_MASTER SET MASKING POLICY pii_credit_score_mask ON COLUMN credit_score;
```
We also built a centralized `PII_POLICY_REGISTRY` table to track which policies were applied to which columns, enabling automated compliance reporting. Unit tests validated each role saw the correct masking level using `EXECUTE AS` in stored procedures.

**Result:** Passed SOC 2 Type II audit with zero PII findings. Eliminated 12 redundant secure views that had previously been maintained per-tenant. Query performance was unaffected -- masking policies added < 2ms overhead even on full table scans. Onboarding a new servicer tenant dropped from 2 days to 30 minutes since masking was role-based, not view-based.

**AI Vision:** An ML classifier could auto-detect PII columns in newly ingested loan files (using pattern recognition on SSN formats, income distributions) and auto-recommend or auto-apply the appropriate masking policy, creating a self-governing data catalog.

---

### Q32. Describe your Secure Data Sharing architecture for providing loan-level analytics to external investors without data movement.

**Situation:** As part of our MBS issuance platform, we needed to provide institutional investors (pension funds, insurance companies, hedge funds) with monthly loan-level performance data for Fannie Mae and Freddie Mac pools they held. Previously, this was done via encrypted SFTP of CSV files -- error-prone, delayed by 3-5 days, and required each investor to build their own analytics stack. Some investors held positions in 500+ pools representing millions of loans.

**Task:** Replace SFTP delivery with real-time, governed access to loan performance analytics through Snowflake Secure Data Sharing. Each investor should see only the pools they own, with PII masked, and with no data physically leaving our account.

**Action:**
```sql
-- Create a dedicated share per investor class (or per investor for large accounts)
CREATE OR REPLACE SHARE investor_loan_analytics_share;

-- Build a secure view enforcing pool-level entitlement
CREATE OR REPLACE SECURE VIEW vw_investor_loan_performance AS
SELECT
    l.pool_id, l.loan_id, l.current_upb, l.delinquency_status,
    l.scheduled_principal, l.actual_principal, l.prepayment_speed_cpr,
    l.loss_severity, l.modification_flag, l.reporting_period,
    p.agency, p.coupon_rate, p.weighted_avg_maturity, p.factor
FROM loan_performance l
JOIN pool_master p ON l.pool_id = p.pool_id
JOIN investor_entitlements ie ON p.pool_id = ie.pool_id
WHERE ie.investor_account = CURRENT_ACCOUNT();

-- Grant to share
GRANT USAGE ON DATABASE mortgage_analytics TO SHARE investor_loan_analytics_share;
GRANT USAGE ON SCHEMA mortgage_analytics.investor_facing TO SHARE investor_loan_analytics_share;
GRANT SELECT ON VIEW mortgage_analytics.investor_facing.vw_investor_loan_performance
  TO SHARE investor_loan_analytics_share;

-- Add consumer accounts
ALTER SHARE investor_loan_analytics_share ADD ACCOUNTS = 'INVESTOR_ORG1.ACCT1', 'INVESTOR_ORG2.ACCT2';
```
We layered masking policies on the secure view so borrower-level PII was never exposed. A Snowflake Task refreshed the `investor_entitlements` mapping nightly from our custody/trustee system. We also published a Snowflake Marketplace listing for aggregated pool-level metrics available to any subscriber.

**Result:** Investor data access went from T+5 days to real-time. SFTP infrastructure costs eliminated ($45K/year). Three major investors consolidated their own Snowflake analytics on top of our shared data, reducing support tickets by 80%. Zero data exfiltration incidents since no data physically moved.

**AI Vision:** Layer an LLM-powered natural language query interface on the shared data so investor analysts can ask questions like "Show me the 60+ day delinquency trend for my Fannie Mae 4.5% pools originated in 2022" without writing SQL.

---

### Q33. How would you design a Row Access Policy to enforce servicer-level data isolation in a shared loan database?

**Situation:** Our enterprise mortgage platform hosted loan data for 8 mortgage servicers in a single Snowflake database. Each servicer's analysts could query loan performance, delinquency, and loss mitigation tables, but regulatory and contractual obligations required strict data isolation -- Servicer A must never see Servicer B's loans. Previous isolation via filtered views had become unmanageable with 40+ tables and frequent schema changes.

**Task:** Implement row-level security using Snowflake Row Access Policies that automatically filter data by servicer context, applied uniformly across all loan tables without modifying existing queries or dashboards.

**Action:**
```sql
-- Mapping table: which roles map to which servicer codes
CREATE OR REPLACE TABLE security.servicer_role_mapping (
    role_name       STRING,
    servicer_code   STRING,
    access_level    STRING  -- 'FULL', 'READONLY', 'AGGREGATED'
);

-- Row access policy using mapping table lookup
CREATE OR REPLACE ROW ACCESS POLICY security.servicer_isolation_policy
AS (servicer_code_col STRING) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION('PLATFORM_ADMIN')
  OR EXISTS (
    SELECT 1 FROM security.servicer_role_mapping m
    WHERE m.role_name = CURRENT_ROLE()
      AND m.servicer_code = servicer_code_col
  );

-- Apply to all loan tables (automated via stored procedure for 40+ tables)
ALTER TABLE loan_master ADD ROW ACCESS POLICY security.servicer_isolation_policy
  ON (servicer_code);
ALTER TABLE loan_performance ADD ROW ACCESS POLICY security.servicer_isolation_policy
  ON (servicer_code);
ALTER TABLE loss_mitigation ADD ROW ACCESS POLICY security.servicer_isolation_policy
  ON (servicer_code);
ALTER TABLE delinquency_detail ADD ROW ACCESS POLICY security.servicer_isolation_policy
  ON (servicer_code);

-- Stored procedure to apply policy to all tables with servicer_code column
CREATE OR REPLACE PROCEDURE security.apply_servicer_policy_to_all()
RETURNS STRING
LANGUAGE SQL
AS
$$
  FOR rec IN (
    SELECT table_schema, table_name FROM information_schema.columns
    WHERE column_name = 'SERVICER_CODE' AND table_schema != 'SECURITY'
  ) DO
    EXECUTE IMMEDIATE
      'ALTER TABLE ' || rec.table_schema || '.' || rec.table_name ||
      ' ADD ROW ACCESS POLICY security.servicer_isolation_policy ON (servicer_code)';
  END FOR;
  RETURN 'Policies applied successfully';
$$;
```
We tested isolation by running cross-servicer queries under each role and validating zero row leakage. A nightly reconciliation job compared row counts per servicer against source system totals to detect any policy misconfiguration.

**Result:** Eliminated 120+ filtered views (3 per table per servicer). New table onboarding went from half a day of view creation to a single stored procedure call. Passed FFIEC examination with the examiner specifically praising the row-level isolation design. Dashboard migration required zero query changes since policies are transparent to the SQL layer.

**AI Vision:** Build an anomaly detection model that monitors query patterns per servicer role and alerts if a user's access pattern deviates from their historical baseline, potentially indicating compromised credentials or insider threat.

---

### Q34. Explain your implementation of column-level data classification and tagging for GLBA/CCPA compliance on mortgage data.

**Situation:** Our mortgage data warehouse held 300+ tables with borrower financial data subject to GLBA (Gramm-Leach-Bliley Act) and CCPA. During a compliance audit, we could not quickly produce an inventory of all columns containing NPI (Non-Public Information) -- SSN, account numbers, income, credit data, property addresses. The auditor flagged this as a material finding requiring remediation within 90 days.

**Task:** Implement a comprehensive data classification framework using Snowflake's Object Tagging to catalog every NPI column, link tags to masking policies, and generate on-demand compliance reports for auditors and the privacy team.

**Action:**
```sql
-- Create tag hierarchy for data classification
CREATE OR REPLACE TAG governance.data_sensitivity
  ALLOWED_VALUES 'PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'RESTRICTED';
CREATE OR REPLACE TAG governance.pii_category
  ALLOWED_VALUES 'SSN', 'INCOME', 'CREDIT_SCORE', 'ACCOUNT_NUMBER',
                 'ADDRESS', 'DOB', 'PHONE', 'EMAIL', 'NONE';
CREATE OR REPLACE TAG governance.regulation
  ALLOWED_VALUES 'GLBA', 'CCPA', 'ECOA', 'HMDA', 'FCRA', 'NONE';
CREATE OR REPLACE TAG governance.retention_period
  ALLOWED_VALUES '3_YEARS', '5_YEARS', '7_YEARS', '10_YEARS', 'PERMANENT';

-- Apply tags to columns (example for LOAN_APPLICATION table)
ALTER TABLE loan_application MODIFY COLUMN borrower_ssn
  SET TAG governance.data_sensitivity = 'RESTRICTED',
      TAG governance.pii_category = 'SSN',
      TAG governance.regulation = 'GLBA';

ALTER TABLE loan_application MODIFY COLUMN annual_income
  SET TAG governance.data_sensitivity = 'CONFIDENTIAL',
      TAG governance.pii_category = 'INCOME',
      TAG governance.regulation = 'GLBA';

-- Automated classification using Snowflake's CLASSIFY function
-- Identifies potential PII columns across all tables
SELECT * FROM TABLE(
  INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LOAN_APPLICATION', 'TABLE')
);

-- Link tags to masking policies via tag-based masking
ALTER TAG governance.pii_category SET MASKING POLICY pii_ssn_mask;

-- Compliance report: all GLBA-regulated columns with their masking status
SELECT
    tr.object_name AS table_name,
    tr.column_name,
    tr.tag_value AS regulation,
    mp.policy_name AS masking_policy,
    CASE WHEN mp.policy_name IS NOT NULL THEN 'PROTECTED' ELSE 'UNPROTECTED' END AS status
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('MORTGAGE_DB', 'DATABASE')) tr
LEFT JOIN INFORMATION_SCHEMA.MASKING_POLICIES mp
  ON tr.column_name = mp.ref_column_name
WHERE tr.tag_name = 'REGULATION' AND tr.tag_value = 'GLBA';
```
We built a Snowflake Task that ran the `EXTRACT_SEMANTIC_CATEGORIES` function weekly on newly created tables and auto-suggested tags for review. A Streamlit dashboard gave the privacy team a real-time view of classification coverage.

**Result:** Tagged 1,200+ columns across 300 tables within 60 days -- 30 days ahead of the audit deadline. Achieved 100% masking coverage on all RESTRICTED columns. Follow-up audit resulted in zero findings. The tagging framework became the foundation for automated CCPA "right to know" and "right to delete" request fulfillment, reducing response time from 15 days to 2 days.

**AI Vision:** Use Snowflake's built-in `CLASSIFY` with a custom ML model trained on mortgage-specific data patterns (loan numbers, MERS IDs, FHA case numbers) to auto-classify industry-specific sensitive fields that generic classifiers miss.

---

### Q35. How did you set up cross-account replication for disaster recovery of a mission-critical loan analytics platform?

**Situation:** Our loan analytics platform processed daily remittance data for $200B in MBS across Fannie Mae, Freddie Mac, and Ginnie Mae pools. A Snowflake regional outage in our primary AWS us-east-1 account would halt investor reporting and breach SLA commitments with 20+ institutional clients. Our RPO requirement was 1 hour, RTO was 4 hours, and the board demanded a tested DR capability after an industry peer suffered a prolonged outage.

**Task:** Implement cross-region, cross-account database replication with automated failover and failback, ensuring referential integrity across replicated databases and minimal cost overhead during steady state.

**Action:**
```sql
-- PRIMARY ACCOUNT (us-east-1): Enable replication on critical databases
ALTER DATABASE mortgage_analytics ENABLE REPLICATION TO ACCOUNTS
  org_name.dr_account_west2;
ALTER DATABASE reference_data ENABLE REPLICATION TO ACCOUNTS
  org_name.dr_account_west2;

-- DR ACCOUNT (us-west-2): Create replica databases
CREATE DATABASE mortgage_analytics_replica
  AS REPLICA OF org_name.primary_account.mortgage_analytics;
CREATE DATABASE reference_data_replica
  AS REPLICA OF org_name.primary_account.reference_data;

-- Automated refresh every 30 minutes (within 1-hour RPO)
ALTER DATABASE mortgage_analytics_replica SET
  REPLICATION_SCHEDULE = 'USING CRON 0,30 * * * * America/New_York';
ALTER DATABASE reference_data_replica SET
  REPLICATION_SCHEDULE = 'USING CRON 5,35 * * * * America/New_York';

-- Replication group for coordinated failover of multiple databases
CREATE REPLICATION GROUP mortgage_platform_rg
  OBJECT_TYPES = DATABASES, ROLES, WAREHOUSES, NETWORK_POLICIES
  ALLOWED_DATABASES = mortgage_analytics, reference_data, staging_db
  ALLOWED_ACCOUNTS = org_name.dr_account_west2
  REPLICATION_SCHEDULE = 'USING CRON 0,30 * * * * America/New_York';

-- Monitor replication lag
SELECT DATABASE_NAME, PRIMARY_SNAPSHOT_TIMESTAMP, SECONDARY_SNAPSHOT_TIMESTAMP,
       TIMESTAMPDIFF('MINUTE', PRIMARY_SNAPSHOT_TIMESTAMP, CURRENT_TIMESTAMP()) AS lag_minutes
FROM TABLE(INFORMATION_SCHEMA.DATABASE_REPLICATION_USAGE_HISTORY(
  DATE_RANGE_START => DATEADD('HOUR', -24, CURRENT_TIMESTAMP())
));

-- Failover procedure (executed in DR account)
-- ALTER DATABASE mortgage_analytics_replica PRIMARY;
```
We implemented a Snowflake Alert that triggered a PagerDuty notification when replication lag exceeded 45 minutes. Quarterly DR drills included a full failover, validation of row counts and checksums against the primary, execution of critical investor reports, and controlled failback. Application connection strings used a DNS CNAME that could be swung to the DR account in under 5 minutes.

**Result:** Achieved measured RPO of 28 minutes and RTO of 2.5 hours during DR drills -- both well within targets. Replication cost was only $1,800/month (storage differential + refresh compute). Successfully executed an unplanned failover during an AWS us-east-1 degradation event with zero data loss and investor reports delivered on schedule. Board and regulators signed off on the DR capability.

**AI Vision:** Use time-series forecasting on replication lag metrics to predict potential replication failures before they breach RPO thresholds, enabling preemptive intervention and automated failover triggering.

---

### Q36. Describe your approach to building a Data Clean Room for sharing aggregated loan performance metrics with counterparties.

**Situation:** Our firm needed to share prepayment and default analytics with a counterparty bank for joint MBS pricing model development. Both parties had proprietary loan-level data they could not expose -- our Fannie/Freddie servicing portfolio and their correspondent origination pipeline. Regulators and legal required that no loan-level records cross organizational boundaries, yet the data science teams needed to compute joint statistics like conditional prepayment rates by vintage, LTV band, and geography.

**Task:** Build a Snowflake Data Clean Room that allows both parties to run approved analytical queries on combined data while ensuring no party can extract the other's raw records.

**Action:**
```sql
-- Provider side: set up clean room database with approved templates
CREATE OR REPLACE DATABASE clean_room_mbs_analytics;
CREATE OR REPLACE SCHEMA clean_room_mbs_analytics.templates;

-- Approved query template: aggregated CPR by cohort (minimum aggregation = 50 loans)
CREATE OR REPLACE SECURE FUNCTION templates.compute_joint_cpr(
    vintage_year INT, ltv_band STRING, state STRING
) RETURNS TABLE (
    vintage INT, ltv_range STRING, geography STRING,
    avg_cpr FLOAT, avg_default_rate FLOAT, loan_count INT
)
AS
$$
  SELECT
      vintage_year, ltv_band, state,
      AVG(cpr_1m) AS avg_cpr,
      AVG(default_rate_12m) AS avg_default_rate,
      COUNT(*) AS loan_count
  FROM (
      SELECT loan_id, cpr_1m, default_rate_12m FROM provider_data.loan_metrics
      WHERE vintage = vintage_year AND ltv_range = ltv_band AND prop_state = state
      UNION ALL
      SELECT loan_id, cpr_1m, default_rate_12m FROM consumer_overlap.loan_metrics
      WHERE vintage = vintage_year AND ltv_range = ltv_band AND prop_state = state
  )
  GROUP BY 1, 2, 3
  HAVING COUNT(*) >= 50  -- k-anonymity threshold
$$;

-- Share the clean room with counterparty
CREATE SHARE clean_room_share;
GRANT USAGE ON DATABASE clean_room_mbs_analytics TO SHARE clean_room_share;
GRANT USAGE ON SCHEMA clean_room_mbs_analytics.templates TO SHARE clean_room_share;
GRANT USAGE ON FUNCTION templates.compute_joint_cpr(INT, STRING, STRING)
  TO SHARE clean_room_share;

-- Audit: log all clean room query executions
CREATE OR REPLACE TABLE clean_room_mbs_analytics.audit.query_log AS
SELECT query_id, user_name, role_name, query_text, start_time, rows_produced
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE database_name = 'CLEAN_ROOM_MBS_ANALYTICS'
  AND start_time > DATEADD('DAY', -30, CURRENT_TIMESTAMP());
```
Both parties agreed on query templates, minimum aggregation thresholds (k-anonymity of 50), and a governance committee that reviewed and approved new templates quarterly. Differential privacy noise was added to small-cohort results to prevent inference attacks.

**Result:** Joint pricing model achieved 15% better prepayment prediction accuracy by combining both portfolios' data. Neither party exposed a single loan-level record. Legal and compliance on both sides approved the framework. The clean room was stood up in 3 weeks versus an estimated 4 months for a traditional secure computation approach. The model improvement translated to approximately $8M in better MBS pricing over 12 months.

**AI Vision:** Integrate federated learning where both parties train ML models locally on their own data and share only model gradients through the clean room, enabling joint model development without even aggregated data exposure.

---

### Q37. How would you implement a comprehensive audit framework using ACCESS_HISTORY for regulatory compliance on loan data access?

**Situation:** FFIEC examiners and our internal audit team required full traceability of who accessed borrower NPI data, when, from which application, and what columns were read. Our previous audit approach relied on QUERY_HISTORY, which showed query text but not the specific columns or rows touched. With 500+ daily users running 50K+ queries against loan data, the examiners wanted proof that access controls were effective and that no unauthorized data access occurred.

**Task:** Build an automated audit framework using Snowflake's ACCESS_HISTORY view that tracks column-level read/write access, generates daily compliance reports, detects anomalous access patterns, and retains audit logs for 7 years per FFIEC guidelines.

**Action:**
```sql
-- Core audit materialization: daily snapshot of sensitive column access
CREATE OR REPLACE TABLE audit.daily_access_log AS
SELECT
    ah.query_id,
    ah.query_start_time,
    ah.user_name,
    ah.role_name,
    ah.warehouse_name,
    dc.value:objectName::STRING AS table_name,
    col.value:columnName::STRING AS column_name,
    bc.value:objectName::STRING AS base_table,
    bc_col.value:columnName::STRING AS base_column
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
    LATERAL FLATTEN(ah.direct_objects_accessed) dc,
    LATERAL FLATTEN(dc.value:columns) col,
    LATERAL FLATTEN(ah.base_objects_accessed) bc,
    LATERAL FLATTEN(bc.value:columns) bc_col
WHERE ah.query_start_time >= DATEADD('DAY', -1, CURRENT_DATE())
  AND bc.value:objectName::STRING IN ('LOAN_MASTER','LOAN_APPLICATION','BORROWER_PROFILE');

-- Join with tag metadata to identify sensitive column access
CREATE OR REPLACE VIEW audit.sensitive_data_access_report AS
SELECT
    dal.query_start_time, dal.user_name, dal.role_name,
    dal.base_table, dal.base_column,
    tr.tag_value AS sensitivity_level,
    CASE WHEN tr.tag_value IN ('RESTRICTED','CONFIDENTIAL') THEN 'SENSITIVE' ELSE 'STANDARD' END AS access_type
FROM audit.daily_access_log dal
LEFT JOIN TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('MORTGAGE_DB','DATABASE')) tr
  ON dal.base_column = tr.column_name AND dal.base_table = tr.object_name
  AND tr.tag_name = 'DATA_SENSITIVITY';

-- Anomaly detection: users accessing unusual columns or high volume
CREATE OR REPLACE ALERT audit.unusual_access_alert
  WAREHOUSE = audit_wh
  SCHEDULE = 'USING CRON 0 * * * * America/New_York'
  IF (EXISTS (
    SELECT user_name, COUNT(DISTINCT base_column) AS col_count
    FROM audit.daily_access_log
    WHERE query_start_time >= DATEADD('HOUR', -1, CURRENT_TIMESTAMP())
    GROUP BY user_name
    HAVING col_count > 50  -- threshold: accessing 50+ distinct sensitive columns in 1 hour
  ))
  THEN CALL audit.send_alert_notification();

-- Long-term retention: copy to external stage for 7-year archival
COPY INTO @audit.s3_archive/access_history/
FROM audit.daily_access_log
FILE_FORMAT = (TYPE = PARQUET)
HEADER = TRUE;
```
A Streamlit dashboard gave compliance officers real-time visibility into sensitive data access with drill-down by user, role, table, and time window. Monthly reports were auto-generated and distributed to the CISO and audit committee.

**Result:** Reduced FFIEC audit preparation from 3 weeks to 2 days. Detected and remediated 3 cases of over-provisioned roles accessing borrower SSN columns they did not need for their function. Achieved 100% audit trail coverage for all NPI columns. The framework satisfied both internal audit and two external regulatory examinations without findings.

**AI Vision:** Train an unsupervised anomaly detection model (isolation forest) on historical access patterns to automatically flag suspicious data access -- such as a servicing analyst suddenly querying trading desk data or a spike in SSN column reads -- enabling real-time insider threat detection.

---

### Q38. Explain your RBAC hierarchy design for a mortgage analytics platform with 200+ users across origination, servicing, and trading.

**Situation:** Our mortgage company had 200+ Snowflake users spanning origination analysts, underwriters, loan servicers, capital markets traders, risk managers, IT operations, and external auditors. Roles had grown organically -- 80+ custom roles with overlapping grants, making it impossible to answer "who has access to what." New hire provisioning took 3+ days, and terminated employee deprovisioning was inconsistent, creating regulatory risk.

**Task:** Redesign the RBAC hierarchy into a clean, auditable structure aligned with business functions and the principle of least privilege. Integrate with our Azure AD identity provider for automated provisioning/deprovisioning via SCIM.

**Action:**
```sql
-- Functional role hierarchy (bottom-up)
-- Layer 1: Object access roles (granular, assigned to schemas/tables)
CREATE ROLE obj_loan_master_read;
CREATE ROLE obj_loan_master_write;
CREATE ROLE obj_loan_performance_read;
CREATE ROLE obj_trading_positions_read;
CREATE ROLE obj_trading_positions_write;

-- Layer 2: Functional roles (business-aligned, inherit object roles)
CREATE ROLE func_origination_analyst;
GRANT ROLE obj_loan_master_read TO ROLE func_origination_analyst;

CREATE ROLE func_underwriter;
GRANT ROLE obj_loan_master_read TO ROLE func_underwriter;
GRANT ROLE obj_loan_master_write TO ROLE func_underwriter;

CREATE ROLE func_servicer_analyst;
GRANT ROLE obj_loan_performance_read TO ROLE func_servicer_analyst;

CREATE ROLE func_trader;
GRANT ROLE obj_trading_positions_read TO ROLE func_trader;
GRANT ROLE obj_trading_positions_write TO ROLE func_trader;
GRANT ROLE obj_loan_performance_read TO ROLE func_trader;

CREATE ROLE func_risk_manager;
GRANT ROLE obj_loan_master_read TO ROLE func_risk_manager;
GRANT ROLE obj_loan_performance_read TO ROLE func_risk_manager;
GRANT ROLE obj_trading_positions_read TO ROLE func_risk_manager;

-- Layer 3: Business unit roles (for warehouse and resource governance)
CREATE ROLE bu_origination;
GRANT ROLE func_origination_analyst TO ROLE bu_origination;
GRANT ROLE func_underwriter TO ROLE bu_origination;
GRANT USAGE ON WAREHOUSE origination_wh TO ROLE bu_origination;

CREATE ROLE bu_capital_markets;
GRANT ROLE func_trader TO ROLE bu_capital_markets;
GRANT USAGE ON WAREHOUSE trading_wh TO ROLE bu_capital_markets;

-- Layer 4: Admin roles
CREATE ROLE platform_admin;  -- DDL, no data access
CREATE ROLE security_admin;  -- role/policy management
GRANT ROLE bu_origination TO ROLE security_admin;
GRANT ROLE bu_capital_markets TO ROLE security_admin;

-- SCIM integration: map Azure AD groups to Snowflake roles
-- Azure AD Group "SG-Snowflake-Origination" -> ROLE bu_origination
-- Azure AD Group "SG-Snowflake-CapMarkets" -> ROLE bu_capital_markets
-- Provisioning/deprovisioning handled automatically by SCIM

-- Audit: role grant lineage
SELECT grantee_name, role, granted_by, created_on
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE deleted_on IS NULL
ORDER BY grantee_name, role;
```
We documented the hierarchy in a visual diagram reviewed quarterly by security and business leads. A Snowflake Task ran weekly access reviews, flagging users whose roles didn't align with their HR department code.

**Result:** Consolidated 80+ roles down to 35 with a clean 4-layer hierarchy. New hire provisioning dropped from 3+ days to 15 minutes (automated via SCIM). Terminated employee access revocation became instant. Quarterly access reviews that previously took 2 weeks were completed in 1 day using automated role-to-department reconciliation. Passed FFIEC and SOC 2 audits with commendation on the RBAC design.

**AI Vision:** Implement a role-mining algorithm that analyzes actual query patterns from ACCESS_HISTORY and recommends optimal role assignments -- identifying users who have permissions they never use (over-provisioned) or who frequently request ad-hoc access to resources their role lacks (under-provisioned).

---

### Q39. How did you use Network Policies and Private Link to secure Snowflake connectivity for a financial services mortgage platform?

**Situation:** Our mortgage analytics platform processed borrower NPI and was subject to FFIEC cybersecurity guidelines requiring that all data-in-transit be encrypted and network access be restricted to known, trusted endpoints. The security team identified that Snowflake's public endpoint was accessible from any IP, creating an unacceptable attack surface. Additionally, data traversing the public internet (even TLS-encrypted) did not meet our security posture for handling borrower financial data.

**Task:** Implement a zero-trust network architecture for Snowflake access: Private Link for all production traffic, network policies restricting access by IP, and elimination of all public internet connectivity to Snowflake.

**Action:**
```sql
-- Step 1: Enable AWS PrivateLink for Snowflake
-- Snowflake side: authorize our AWS account for Private Link
SELECT SYSTEM$AUTHORIZE_PRIVATELINK('arn:aws:iam::123456789012:root');

-- AWS side (via Terraform, summarized):
-- Create VPC endpoint for Snowflake's PrivateLink service
-- DNS: create CNAME from account.privatelink.snowflakecomputing.com to VPC endpoint

-- Step 2: Network policies - restrict to known corporate and VPC CIDR ranges
CREATE OR REPLACE NETWORK POLICY mortgage_platform_network_policy
  ALLOWED_IP_LIST = (
    '10.0.0.0/8',          -- corporate VPC ranges
    '172.16.0.0/12',       -- Private Link traffic
    '203.0.113.0/24'       -- corporate office egress IPs (VPN)
  )
  BLOCKED_IP_LIST = (
    '0.0.0.0/0'            -- block everything else by implication
  );

-- Apply at account level
ALTER ACCOUNT SET NETWORK_POLICY = mortgage_platform_network_policy;

-- Step 3: Separate policies for service accounts vs interactive users
CREATE NETWORK POLICY etl_service_policy
  ALLOWED_IP_LIST = ('10.100.0.0/16');  -- ETL subnet only
ALTER USER etl_service_account SET NETWORK_POLICY = etl_service_policy;

CREATE NETWORK POLICY bi_tool_policy
  ALLOWED_IP_LIST = ('10.200.0.0/16');  -- BI server subnet
ALTER USER tableau_service_account SET NETWORK_POLICY = bi_tool_policy;

-- Step 4: Verify no public access and monitor
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE client_ip NOT LIKE '10.%' AND client_ip NOT LIKE '172.%'
  AND event_timestamp > DATEADD('DAY', -7, CURRENT_TIMESTAMP());

-- Alert on any non-private-link connection attempt
CREATE OR REPLACE ALERT security.public_access_alert
  WAREHOUSE = security_wh
  SCHEDULE = 'USING CRON */15 * * * * America/New_York'
  IF (EXISTS (
    SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
    WHERE IS_SUCCESS = 'YES'
      AND client_ip NOT LIKE '10.%' AND client_ip NOT LIKE '172.%'
      AND event_timestamp > DATEADD('MINUTE', -15, CURRENT_TIMESTAMP())
  ))
  THEN CALL security.notify_soc_team();
```
We configured the BI tools (Tableau, Power BI) and ETL pipelines (Airflow, dbt) to connect exclusively through the Private Link endpoint. VPN split-tunnel was disabled for Snowflake traffic, forcing all interactive users through the corporate network.

**Result:** Eliminated 100% of public internet traffic to Snowflake. Penetration test confirmed the Snowflake public endpoint was unreachable from outside the VPC. Login audit showed zero connections from unauthorized IPs post-implementation. Met FFIEC cybersecurity maturity level "Advanced" for network security controls. Latency actually improved by 12% since Private Link traffic stays on the AWS backbone.

**AI Vision:** Deploy a network traffic analysis model that learns normal connectivity patterns (source IPs, connection times, query volumes) and flags deviations in real-time -- such as connections from unusual subnets or at abnormal hours -- feeding into a SIEM for automated incident response.

---

### Q40. Describe your strategy for implementing data retention and purge policies on loan data to meet regulatory and storage requirements.

**Situation:** Our Snowflake warehouse had grown to 85TB with 7 years of historical loan data. Regulatory requirements varied by data type: HMDA data required 5-year retention, general loan servicing records 7 years after payoff, and litigation-hold loans indefinite. Storage costs were $2,800/month and growing 30% annually. Additionally, CCPA "right to delete" requests needed to purge borrower data within 45 days while preserving aggregate analytics and not breaking referential integrity in the star schema.

**Task:** Implement automated, policy-driven data retention and purge that respects heterogeneous regulatory requirements, handles litigation holds, supports CCPA deletion, optimizes storage costs, and maintains data integrity across the 50+ table star schema.

**Action:**
```sql
-- Tag tables/columns with retention requirements
ALTER TABLE loan_master SET TAG governance.retention_period = '7_YEARS';
ALTER TABLE hmda_lar SET TAG governance.retention_period = '5_YEARS';
ALTER TABLE loan_documents SET TAG governance.retention_period = '7_YEARS';

-- Litigation hold registry
CREATE OR REPLACE TABLE governance.litigation_hold (
    loan_id         STRING,
    hold_start_date DATE,
    hold_reason     STRING,
    hold_status     STRING DEFAULT 'ACTIVE',
    legal_case_id   STRING
);

-- Retention policy execution: soft delete first, hard purge after grace period
CREATE OR REPLACE PROCEDURE governance.execute_retention_policy()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  -- Mark loans eligible for purge (past retention, not on litigation hold)
  MERGE INTO loan_master lm
  USING (
    SELECT l.loan_id
    FROM loan_master l
    LEFT JOIN governance.litigation_hold lh
      ON l.loan_id = lh.loan_id AND lh.hold_status = 'ACTIVE'
    WHERE lh.loan_id IS NULL
      AND DATEDIFF('YEAR', COALESCE(l.payoff_date, l.liquidation_date), CURRENT_DATE()) > 7
      AND l.purge_status IS NULL
  ) eligible ON lm.loan_id = eligible.loan_id
  WHEN MATCHED THEN UPDATE SET
    lm.purge_status = 'PENDING',
    lm.purge_eligible_date = DATEADD('DAY', 90, CURRENT_DATE());

  -- Archive to low-cost external stage before purge
  COPY INTO @governance.archive_stage/purged_loans/
  FROM (SELECT * FROM loan_master WHERE purge_status = 'APPROVED');

  -- Hard delete from all related tables (cascade through star schema)
  DELETE FROM loan_performance WHERE loan_id IN
    (SELECT loan_id FROM loan_master WHERE purge_status = 'APPROVED');
  DELETE FROM borrower_profile WHERE loan_id IN
    (SELECT loan_id FROM loan_master WHERE purge_status = 'APPROVED');
  DELETE FROM loan_documents WHERE loan_id IN
    (SELECT loan_id FROM loan_master WHERE purge_status = 'APPROVED');
  DELETE FROM loan_master WHERE purge_status = 'APPROVED';

  RETURN 'Retention policy executed successfully';
END;
$$;

-- CCPA right-to-delete: anonymize borrower data while preserving loan analytics
CREATE OR REPLACE PROCEDURE governance.ccpa_delete_borrower(borrower_id_param STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  -- Anonymize PII but preserve loan performance metrics for analytics
  UPDATE loan_master SET
    borrower_ssn = SHA2(borrower_ssn || 'salt_key'),
    borrower_name = 'REDACTED',
    borrower_email = NULL,
    borrower_phone = NULL,
    property_address = CONCAT(property_zip, ' - REDACTED'),
    ccpa_deletion_date = CURRENT_DATE()
  WHERE borrower_id = :borrower_id_param;

  UPDATE borrower_profile SET
    annual_income = NULL, employer_name = 'REDACTED',
    date_of_birth = NULL, credit_score = NULL
  WHERE borrower_id = :borrower_id_param;

  INSERT INTO governance.ccpa_deletion_log VALUES
    (:borrower_id_param, CURRENT_TIMESTAMP(), CURRENT_USER(), 'COMPLETED');

  RETURN 'CCPA deletion completed for borrower ' || :borrower_id_param;
END;
$$;

-- Schedule retention policy monthly
CREATE OR REPLACE TASK governance.monthly_retention_task
  WAREHOUSE = governance_wh
  SCHEDULE = 'USING CRON 0 2 1 * * America/New_York'
AS CALL governance.execute_retention_policy();
```
We implemented a 90-day grace period between soft delete and hard purge, during which business users could request a hold. All purged data was archived to S3 Glacier via external stage before deletion. A reconciliation report tracked record counts pre- and post-purge.

**Result:** Reduced active storage from 85TB to 52TB (39% reduction), saving $1,100/month in storage costs. CCPA deletion requests processed within 48 hours versus the 45-day regulatory maximum. Zero litigation-hold violations -- every held loan was preserved correctly. Archived data remained accessible for legal discovery via external tables at a fraction of active storage cost. Annual storage growth rate dropped from 30% to 12%.

**AI Vision:** Build a predictive model that forecasts storage growth by data category and recommends optimal retention thresholds balancing regulatory minimums, analytics value, and cost. An NLP model could also parse legal hold notices and automatically apply or release litigation holds on the correct loan populations.

---
