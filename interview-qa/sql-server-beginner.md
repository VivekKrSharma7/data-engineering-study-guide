# SQL Server - Beginner Q&A (STAR Method)

[Back to Q&A Index](README.md)

---

50 beginner questions with answers using the **STAR methodology** (Situation, Task, Action, Result) plus an **AI Vision** — real-world US secondary mortgage market examples.

---

### Q1. SELECT with WHERE and ORDER BY — querying loan performance data

**Situation:** At a capital markets analytics firm processing Fannie Mae's Single-Family Loan Performance dataset, the risk team needed to review all 30-year fixed-rate loans originated in California that were currently 60+ days delinquent, sorted by unpaid principal balance descending, to prioritize loss mitigation outreach.

**Task:** Write a SQL Server query against the LoanPerformance table to retrieve delinquent California loans with specific filters and ordering, delivering results to the risk analysts within their morning reporting window.

**Action:**
The following query was constructed to extract the targeted loan population:

```sql
SELECT
    LoanID,
    OriginalUPB,
    CurrentUPB,
    InterestRate,
    OriginationDate,
    DelinquencyStatus,
    PropertyState,
    CreditScore
FROM LoanPerformance
WHERE PropertyState = 'CA'
    AND ProductType = '30YR_FIXED'
    AND DelinquencyStatus >= 2
    AND ReportingPeriod = '2025-12-01'
ORDER BY CurrentUPB DESC;
```

Key aspects of this query:
- **WHERE** filters narrowed 22 million rows down to the target population using indexed columns.
- **ORDER BY CurrentUPB DESC** ensured highest-exposure loans appeared first for priority review.
- The `DelinquencyStatus >= 2` condition captured 60-day, 90-day, and 90+ day delinquencies in a single filter.
- The `ReportingPeriod` filter isolated the most recent monthly snapshot.

**Result:** The query returned 14,320 delinquent California loans with a combined UPB of $4.8 billion, executing in under 2 seconds. Risk analysts used the sorted output to prioritize their top 500 highest-balance cases for immediate loss mitigation review, identifying $1.2 billion in at-risk exposure within the first hour.

**AI Vision:** An ML model could predict which of these delinquent loans are most likely to cure versus proceed to foreclosure, allowing the loss mitigation team to dynamically prioritize outreach based on predicted outcomes rather than balance alone.

---

### Q2. INNER JOIN — joining loan and borrower tables

**Situation:** Freddie Mac's data warehouse maintained loan attributes and borrower demographics in separate normalized tables. The compliance team needed a combined view of loan terms alongside borrower credit data to generate Home Mortgage Disclosure Act (HMDA) reports for regulatory submission.

**Task:** Write an INNER JOIN query to combine LoanMaster and BorrowerInfo tables, returning only loans that have matching borrower records, to produce the quarterly HMDA compliance extract.

**Action:**
The join was designed to merge the two core tables on the shared LoanID key:

```sql
SELECT
    lm.LoanID,
    lm.OriginalLoanAmount,
    lm.InterestRate,
    lm.LoanPurpose,
    lm.PropertyType,
    lm.OriginationDate,
    bi.BorrowerCreditScore,
    bi.DebtToIncomeRatio,
    bi.CoBorrowerFlag,
    bi.IncomeLevel
FROM LoanMaster lm
INNER JOIN BorrowerInfo bi
    ON lm.LoanID = bi.LoanID
WHERE lm.OriginationDate BETWEEN '2025-01-01' AND '2025-12-31'
    AND lm.LoanPurpose IN ('PURCHASE', 'REFINANCE');
```

Key design decisions:
- **INNER JOIN** was chosen because HMDA requires both loan and borrower data to be present — incomplete records must be excluded.
- Table aliases `lm` and `bi` improved readability for a query touching two tables.
- The `ON lm.LoanID = bi.LoanID` clause matched on the primary-to-foreign-key relationship.
- WHERE conditions applied post-join to filter to the reporting year and relevant loan purposes.

**Result:** The INNER JOIN returned 1.3 million matched loan-borrower records for 2025 originations, excluding 4,200 orphan loan records that lacked borrower data. The compliance extract was delivered two days ahead of the HMDA filing deadline, and regulators accepted the submission without corrections.

**AI Vision:** NLP models could automatically classify loan purpose from free-text underwriter notes, improving the accuracy of the LoanPurpose field and reducing HMDA reporting errors by an estimated 15%.

---

### Q3. LEFT JOIN — finding loans missing servicer records

**Situation:** Ginnie Mae's monitoring division discovered discrepancies in monthly pool reporting — certain FHA/VA loans in the MBS pools appeared to have no matching records in the ServicerReport table. These orphaned loans could indicate servicing transfer gaps or data submission failures by approved issuers.

**Task:** Identify all loans in active Ginnie Mae pools that do not have a corresponding monthly servicer report for the current reporting period using a LEFT JOIN pattern.

**Action:**
A LEFT JOIN with a NULL check on the right-side table was used to find unmatched loans:

```sql
SELECT
    lm.LoanID,
    lm.PoolNumber,
    lm.CurrentUPB,
    lm.ServicerID,
    lm.LoanType,
    lm.OriginalLoanAmount
FROM LoanMaster lm
LEFT JOIN ServicerReport sr
    ON lm.LoanID = sr.LoanID
    AND sr.ReportingMonth = '2025-12-01'
WHERE lm.PoolStatus = 'ACTIVE'
    AND lm.Agency = 'GNMA'
    AND sr.LoanID IS NULL
ORDER BY lm.ServicerID, lm.CurrentUPB DESC;
```

Important nuances:
- **LEFT JOIN** preserved all LoanMaster rows regardless of whether a ServicerReport match existed.
- The reporting month filter was placed in the **ON** clause, not the WHERE clause — this is critical because putting it in WHERE would convert the LEFT JOIN into an INNER JOIN.
- `sr.LoanID IS NULL` in the WHERE clause isolated only the unmatched loans.
- Results were sorted by ServicerID to group missing reports by the responsible servicer.

**Result:** The query identified 8,740 active Ginnie Mae loans totaling $2.1 billion in UPB that lacked December 2025 servicer reports. Investigation revealed 6,200 of these were from three servicers undergoing system migrations. Ginnie Mae issued cure notices, and all servicers submitted corrected data within 5 business days, bringing pool reporting completeness from 97.2% back to 99.8%.

**AI Vision:** An anomaly detection model trained on historical reporting patterns could proactively flag servicers likely to miss submission deadlines based on their data quality trends and operational indicators, enabling preemptive intervention.

---

### Q4. GROUP BY with COUNT/SUM/AVG — aggregating pool statistics

**Situation:** A portfolio manager at an MBS trading desk needed a summary of Fannie Mae pool-level statistics to evaluate exposure across different product types. The MonthlyRemittance table contained loan-level payment data for 15 million active loans across thousands of pools.

**Task:** Aggregate loan-level data into pool-level summary statistics including loan count, total UPB, average interest rate, and average credit score, grouped by product type and pool number.

**Action:**
Aggregate functions combined with GROUP BY produced the pool-level summary:

```sql
SELECT
    pd.ProductType,
    pd.PoolNumber,
    COUNT(*) AS LoanCount,
    SUM(mr.CurrentUPB) AS TotalPoolUPB,
    AVG(mr.InterestRate) AS AvgCoupon,
    AVG(mr.BorrowerCreditScore) AS AvgCreditScore,
    SUM(mr.ScheduledPrincipal + mr.PrepaidPrincipal) AS TotalPrinPayment,
    MIN(mr.OriginationDate) AS OldestLoanDate,
    MAX(mr.OriginationDate) AS NewestLoanDate
FROM MonthlyRemittance mr
INNER JOIN PoolDetail pd
    ON mr.PoolNumber = pd.PoolNumber
WHERE mr.ReportingMonth = '2025-12-01'
    AND pd.Agency = 'FNMA'
GROUP BY pd.ProductType, pd.PoolNumber
ORDER BY TotalPoolUPB DESC;
```

Key points:
- **COUNT(*)** counted all loans per pool, while **SUM** and **AVG** provided financial aggregates.
- Multiple aggregate functions in one query avoided repeated table scans.
- The GROUP BY included both ProductType and PoolNumber to get granular pool-level details within each product category.
- Combining scheduled and prepaid principal in the SUM gave total principal cash flow per pool.

**Result:** The query collapsed 15 million loan-level rows into 12,400 pool-level summaries across 6 product types. The trading desk identified that 30-year fixed pools had a weighted average coupon of 5.85% with an average FICO of 742, while 15-year pools averaged 5.12% with a FICO of 768, informing a $500 million relative-value trade.

**AI Vision:** A prepayment model could enrich each pool summary with predicted CPR (Conditional Prepayment Rate) based on the pool's coupon, seasoning, and borrower profile, enabling more accurate cash flow projections for MBS valuation.

---

### Q5. HAVING clause — filtering pools by delinquency threshold

**Situation:** Freddie Mac's credit risk division monitored pool-level delinquency rates to identify pools requiring enhanced surveillance. The threshold was any pool where more than 5% of loans by count were 60+ days delinquent — these pools would be placed on a watchlist for potential credit intervention.

**Task:** Write a query that groups loans by pool, calculates each pool's delinquency rate, and filters to return only pools exceeding the 5% delinquency threshold using the HAVING clause.

**Action:**
The HAVING clause was applied after GROUP BY to filter on the computed delinquency rate:

```sql
SELECT
    PoolNumber,
    COUNT(*) AS TotalLoans,
    SUM(CASE WHEN DelinquencyStatus >= 2 THEN 1 ELSE 0 END) AS DelinquentLoans,
    CAST(SUM(CASE WHEN DelinquencyStatus >= 2 THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / COUNT(*) * 100 AS DelinquencyPctByCount,
    SUM(CASE WHEN DelinquencyStatus >= 2 THEN CurrentUPB ELSE 0 END) AS DelinquentUPB,
    SUM(CurrentUPB) AS TotalPoolUPB
FROM LoanPerformance
WHERE ReportingPeriod = '2025-12-01'
    AND Agency = 'FHLMC'
GROUP BY PoolNumber
HAVING SUM(CASE WHEN DelinquencyStatus >= 2 THEN 1 ELSE 0 END) * 100.0
    / COUNT(*) > 5.0
ORDER BY DelinquencyPctByCount DESC;
```

Critical distinctions:
- **WHERE** filters rows before aggregation — used here for the reporting period and agency.
- **HAVING** filters groups after aggregation — required because delinquency rate is a computed aggregate.
- The CASE expression inside SUM created a conditional count of delinquent loans.
- CAST to DECIMAL ensured precise percentage calculation, avoiding integer division truncation.

**Result:** Out of 8,200 active Freddie Mac pools, 187 pools exceeded the 5% delinquency threshold, representing $12.3 billion in total UPB. The highest-delinquency pool showed a 14.2% rate concentrated in hurricane-affected Florida zip codes. These 187 pools were placed on the enhanced surveillance watchlist, triggering servicer outreach within 48 hours.

**AI Vision:** A geospatial ML model correlating FEMA disaster declarations, property values, and employment data could predict which pools will breach delinquency thresholds 3-6 months in advance, enabling proactive risk mitigation before losses crystallize.

---

### Q6. Subqueries — finding loans with above-average balance

**Situation:** An analytics team at a mortgage REIT used Intex Solutions data to identify large-balance loans within their non-agency RMBS holdings. Loans with UPB significantly above the portfolio average were flagged for concentration risk analysis, as default of a single large loan could disproportionately impact tranche cash flows.

**Task:** Use a subquery to identify all loans whose current UPB exceeds the portfolio-wide average by more than two standard deviations, flagging them for concentration risk review.

**Action:**
A subquery in the WHERE clause computed the average and standard deviation for comparison:

```sql
SELECT
    LoanID,
    DealName,
    TrancheID,
    CurrentUPB,
    OriginalLoanAmount,
    InterestRate,
    PropertyState,
    LTV
FROM DealTranche dt
INNER JOIN LoanMaster lm
    ON dt.DealID = lm.DealID
WHERE lm.CurrentUPB > (
    SELECT AVG(CurrentUPB) + 2 * STDEV(CurrentUPB)
    FROM LoanMaster
    WHERE DealID = lm.DealID
        AND LoanStatus = 'ACTIVE'
)
AND lm.LoanStatus = 'ACTIVE'
ORDER BY lm.CurrentUPB DESC;
```

Additionally, a subquery in the SELECT clause provided context:

```sql
SELECT
    LoanID,
    CurrentUPB,
    (SELECT AVG(CurrentUPB) FROM LoanMaster WHERE DealID = lm.DealID) AS DealAvgUPB,
    CurrentUPB - (SELECT AVG(CurrentUPB) FROM LoanMaster WHERE DealID = lm.DealID) AS ExcessOverAvg
FROM LoanMaster lm
WHERE CurrentUPB > (
    SELECT AVG(CurrentUPB) * 2.0
    FROM LoanMaster sub
    WHERE sub.DealID = lm.DealID
);
```

Key design notes:
- The **correlated subquery** recalculated the average per DealID, ensuring each loan was compared against its own deal's average — not the entire portfolio.
- Using `AVG + 2 * STDEV` identified true statistical outliers rather than arbitrary thresholds.
- The subquery approach was chosen over a CTE for simplicity at the beginner level.

**Result:** Across 340 non-agency RMBS deals, the query identified 2,180 concentration-risk loans with balances exceeding $1.5 million each. The total flagged exposure was $4.6 billion, representing 3.8% of the portfolio by loan count but 11.2% by UPB. The risk team implemented per-deal concentration limits that prevented a $200 million potential loss scenario.

**AI Vision:** A default probability model incorporating loan-level features (balance, LTV, FICO, property type) could assign risk scores to these high-balance loans, replacing the static statistical threshold with a dynamic, borrower-specific risk assessment.

---

### Q7. EXISTS — checking loan eligibility for securitization

**Situation:** Fannie Mae's securitization pipeline required loan eligibility screening before loans could be pooled into new MBS. A loan was eligible only if it had a completed appraisal on file, a valid title insurance record, and no outstanding document deficiencies in the QualityControl table.

**Task:** Use EXISTS subqueries to efficiently check multiple eligibility conditions across related tables, identifying loans ready for securitization from the pending pipeline.

**Action:**
EXISTS was used for each eligibility check, providing efficient semi-join lookups:

```sql
SELECT
    lm.LoanID,
    lm.OriginalLoanAmount,
    lm.InterestRate,
    lm.PropertyState,
    lm.BorrowerCreditScore,
    lm.LTV
FROM LoanMaster lm
WHERE lm.PipelineStatus = 'PENDING_SECURITIZATION'
    AND lm.Agency = 'FNMA'
    AND EXISTS (
        SELECT 1
        FROM AppraisalRecord ar
        WHERE ar.LoanID = lm.LoanID
            AND ar.AppraisalStatus = 'COMPLETED'
            AND ar.AppraisalDate >= DATEADD(MONTH, -6, GETDATE())
    )
    AND EXISTS (
        SELECT 1
        FROM TitleInsurance ti
        WHERE ti.LoanID = lm.LoanID
            AND ti.PolicyStatus = 'ACTIVE'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM QualityControl qc
        WHERE qc.LoanID = lm.LoanID
            AND qc.DeficiencyStatus = 'OPEN'
    )
ORDER BY lm.OriginalLoanAmount DESC;
```

Why EXISTS over IN:
- **EXISTS** short-circuits — it stops scanning once the first match is found, making it more efficient than `IN (SELECT ...)` for large tables.
- **NOT EXISTS** cleanly expressed the absence of open deficiencies.
- `SELECT 1` in the subquery was a convention signaling that the column values do not matter — only the existence of matching rows.
- Each EXISTS condition was an independent eligibility gate that had to pass.

**Result:** From a pipeline of 48,000 pending loans, 31,200 passed all three eligibility gates and were cleared for securitization into 85 new MBS pools totaling $9.1 billion in UPB. The 16,800 ineligible loans were routed to exception processing: 8,400 had stale appraisals, 5,100 lacked title insurance, and 3,300 had open QC deficiencies.

**AI Vision:** A document completeness classifier using OCR and NLP could automatically verify appraisal and title documents, reducing the manual review bottleneck and accelerating the securitization pipeline from 5 days to under 24 hours.

---

### Q8. INSERT INTO — loading new monthly remittance records

**Situation:** Each month, Freddie Mac servicers submit remittance data containing payment information for millions of loans. The ETL pipeline needed to load the validated and transformed remittance data from a staging table into the production MonthlyRemittance table for the December 2025 reporting cycle.

**Task:** Write INSERT INTO statements to load new monthly remittance records from the staging area into the production table, handling both direct inserts and INSERT...SELECT patterns.

**Action:**
The production load used INSERT...SELECT from the staging table after validation:

```sql
-- Insert validated records from staging to production
INSERT INTO MonthlyRemittance (
    LoanID,
    ReportingMonth,
    CurrentUPB,
    ScheduledPrincipal,
    PrepaidPrincipal,
    InterestCollected,
    DelinquencyStatus,
    LoanStatus,
    ServicerID,
    LoadTimestamp
)
SELECT
    stg.LoanID,
    stg.ReportingMonth,
    stg.CurrentUPB,
    stg.ScheduledPrincipal,
    stg.PrepaidPrincipal,
    stg.InterestCollected,
    stg.DelinquencyStatus,
    stg.LoanStatus,
    stg.ServicerID,
    GETDATE() AS LoadTimestamp
FROM Staging_Remittance stg
WHERE stg.ValidationFlag = 'PASSED'
    AND stg.ReportingMonth = '2025-12-01'
    AND NOT EXISTS (
        SELECT 1
        FROM MonthlyRemittance mr
        WHERE mr.LoanID = stg.LoanID
            AND mr.ReportingMonth = stg.ReportingMonth
    );

-- Verify the load
SELECT
    COUNT(*) AS RecordsInserted,
    SUM(CurrentUPB) AS TotalUPB
FROM MonthlyRemittance
WHERE ReportingMonth = '2025-12-01'
    AND LoadTimestamp >= CAST(GETDATE() AS DATE);
```

Design considerations:
- **INSERT...SELECT** was preferred over row-by-row inserts for bulk loading millions of records.
- The **NOT EXISTS** guard prevented duplicate inserts if the job was re-run.
- The `ValidationFlag = 'PASSED'` filter ensured only clean data reached production.
- `GETDATE()` captured the actual load timestamp for audit trail purposes.
- A verification query confirmed the load count and total UPB matched expected values.

**Result:** The INSERT...SELECT loaded 8.2 million validated remittance records into production in 3 minutes 42 seconds, representing $1.8 trillion in current UPB. The NOT EXISTS duplicate check prevented 12,400 potential duplicate inserts from a partial prior run. Post-load validation confirmed a 100% reconciliation match against the source file control totals.

**AI Vision:** An ML-based data quality model could replace rule-based validation flags by learning patterns of data anomalies from historical remittance submissions, catching subtle errors like transposed digits in UPB amounts that rule-based checks miss.

---

### Q9. UPDATE with JOIN — updating loan status from servicer feed

**Situation:** CoreLogic provided a daily servicing transfer file indicating loans that had been transferred between servicers. The LoanMaster table needed to be updated with the new servicer assignment, transfer effective date, and updated contact information — all sourced from the CoreLogic feed loaded into a staging table.

**Task:** Write an UPDATE statement with a JOIN to apply servicer transfer information from the staging table to the production LoanMaster table, ensuring only validated transfers are applied.

**Action:**
The UPDATE...FROM...JOIN pattern in SQL Server was used to merge the transfer data:

```sql
UPDATE lm
SET
    lm.CurrentServicerID   = stf.NewServicerID,
    lm.ServicerName         = stf.NewServicerName,
    lm.TransferEffectiveDate = stf.TransferDate,
    lm.PriorServicerID      = lm.CurrentServicerID,
    lm.LastModifiedDate      = GETDATE(),
    lm.LastModifiedBy        = 'CORELOGIC_TRANSFER_FEED'
FROM LoanMaster lm
INNER JOIN Staging_ServicerTransfer stf
    ON lm.LoanID = stf.LoanID
WHERE stf.TransferStatus = 'CONFIRMED'
    AND stf.TransferDate <= GETDATE()
    AND lm.CurrentServicerID <> stf.NewServicerID;
```

Important details:
- The **UPDATE...FROM...JOIN** syntax is SQL Server-specific and allows joining to another table during the update.
- `lm.PriorServicerID = lm.CurrentServicerID` captured the old servicer before overwriting — essential for audit trails.
- The `CurrentServicerID <> NewServicerID` condition prevented no-op updates where the servicer was already correct.
- `TransferStatus = 'CONFIRMED'` ensured only finalized transfers were applied, not pending ones.
- `GETDATE()` and a source identifier tagged every modified row for change tracking.

**Result:** The UPDATE with JOIN applied 24,600 servicer transfers in a single batch operation completing in 8 seconds, affecting $7.3 billion in loan UPB across 14 servicer transfers. The PriorServicerID capture enabled a full audit trail, and downstream systems received the updated servicer routing information within the same business day, maintaining investor reporting continuity.

**AI Vision:** A predictive model could forecast servicing transfers based on servicer financial health indicators and regulatory actions, pre-staging data infrastructure changes before the official CoreLogic transfer notification arrives.

---

### Q10. DELETE with WHERE — purging expired trial modifications

**Situation:** Fannie Mae's loss mitigation system tracked trial modification plans for distressed borrowers. Trial modifications that expired without converting to permanent modifications needed to be purged from the active TrialModification table after a 90-day retention window to maintain system performance and data accuracy.

**Task:** Write a DELETE statement with appropriate WHERE conditions to remove expired trial modification records that have passed the retention window, while preserving an audit trail.

**Action:**
A two-step approach archived then deleted the expired records:

```sql
-- Step 1: Archive expired trials to history table before deletion
INSERT INTO TrialModification_Archive
SELECT
    tm.*,
    GETDATE() AS ArchiveTimestamp,
    'EXPIRED_PURGE' AS ArchiveReason
FROM TrialModification tm
WHERE tm.TrialStatus = 'EXPIRED'
    AND tm.ExpirationDate < DATEADD(DAY, -90, GETDATE())
    AND tm.ConversionFlag = 'N';

-- Step 2: Delete archived records from active table
DELETE FROM TrialModification
WHERE TrialStatus = 'EXPIRED'
    AND ExpirationDate < DATEADD(DAY, -90, GETDATE())
    AND ConversionFlag = 'N';

-- Step 3: Verify deletion
SELECT
    COUNT(*) AS RemainingTrials,
    SUM(CASE WHEN TrialStatus = 'EXPIRED' THEN 1 ELSE 0 END) AS RemainingExpired
FROM TrialModification;
```

Safety considerations:
- **Archive before delete** — expired records were copied to the history table first, ensuring no data was permanently lost.
- The **WHERE clause** used three conditions to precisely target only eligible records: status must be EXPIRED, past the 90-day window, and not converted to permanent.
- `DATEADD(DAY, -90, GETDATE())` calculated the retention cutoff dynamically.
- The verification query confirmed the correct number of records remained.
- In production, this would be wrapped in a transaction (covered in Q25).

**Result:** The purge operation archived and deleted 42,300 expired trial modification records dating back to early 2025. The active TrialModification table shrank from 890,000 to 847,700 rows, improving average query response time by 18%. The archive table preserved full audit trail compliance for regulatory examination, and zero active or converted trial modifications were affected.

**AI Vision:** An ML model analyzing trial modification outcomes could predict at origination which trials are most likely to convert to permanent modifications, helping servicers allocate counseling resources to borrowers with the highest probability of success.

---

### Q11. Primary keys and foreign keys — loan data schema design

**Situation:** A data engineering team was designing the relational schema for a new Ginnie Mae HMBS (Home Equity Conversion Mortgage-Backed Securities) data warehouse. The schema needed to enforce referential integrity across loans, borrowers, pools, and monthly reporting tables while supporting the complex relationships inherent in reverse mortgage securitization.

**Task:** Design a set of CREATE TABLE statements with primary keys and foreign keys that properly model the relationships between loan, borrower, pool, and reporting entities for Ginnie Mae HMBS data.

**Action:**
The schema was designed with clear primary and foreign key constraints:

```sql
-- Parent table: Deal information
CREATE TABLE Deal (
    DealID          INT PRIMARY KEY,
    DealName        VARCHAR(50) NOT NULL,
    IssueDate       DATE NOT NULL,
    OriginalBalance DECIMAL(18,2) NOT NULL,
    Agency          VARCHAR(10) DEFAULT 'GNMA',
    DealStatus      VARCHAR(20) NOT NULL
);

-- Pool table references Deal
CREATE TABLE PoolDetail (
    PoolNumber      VARCHAR(20) PRIMARY KEY,
    DealID          INT NOT NULL,
    PoolType        VARCHAR(30) NOT NULL,
    IssueDate       DATE NOT NULL,
    OriginalUPB     DECIMAL(18,2) NOT NULL,
    CONSTRAINT FK_Pool_Deal
        FOREIGN KEY (DealID) REFERENCES Deal(DealID)
);

-- Loan master references Pool
CREATE TABLE LoanMaster (
    LoanID          BIGINT PRIMARY KEY,
    PoolNumber      VARCHAR(20) NOT NULL,
    OriginalUPB     DECIMAL(18,2) NOT NULL,
    InterestRate    DECIMAL(5,3) NOT NULL,
    OriginationDate DATE NOT NULL,
    MaturityDate    DATE NOT NULL,
    PropertyState   CHAR(2) NOT NULL,
    LoanStatus      VARCHAR(20) NOT NULL,
    CONSTRAINT FK_Loan_Pool
        FOREIGN KEY (PoolNumber) REFERENCES PoolDetail(PoolNumber)
);

-- Borrower info references Loan (one-to-many: co-borrowers)
CREATE TABLE BorrowerInfo (
    BorrowerID      BIGINT PRIMARY KEY,
    LoanID          BIGINT NOT NULL,
    BorrowerAge     INT NOT NULL,
    CreditScore     INT NULL,
    BorrowerType    VARCHAR(15) NOT NULL,  -- 'PRIMARY' or 'CO_BORROWER'
    CONSTRAINT FK_Borrower_Loan
        FOREIGN KEY (LoanID) REFERENCES LoanMaster(LoanID)
);

-- Monthly remittance references Loan (composite key: loan + month)
CREATE TABLE MonthlyRemittance (
    LoanID          BIGINT NOT NULL,
    ReportingMonth  DATE NOT NULL,
    CurrentUPB      DECIMAL(18,2) NOT NULL,
    InterestAccrued DECIMAL(12,2) NOT NULL,
    DrawAmount      DECIMAL(12,2) DEFAULT 0,
    LoanStatus      VARCHAR(20) NOT NULL,
    CONSTRAINT PK_Remittance
        PRIMARY KEY (LoanID, ReportingMonth),
    CONSTRAINT FK_Remittance_Loan
        FOREIGN KEY (LoanID) REFERENCES LoanMaster(LoanID)
);
```

Design principles applied:
- **Primary keys** enforced entity uniqueness — DealID, PoolNumber, LoanID, BorrowerID, and the composite (LoanID, ReportingMonth).
- **Foreign keys** enforced referential integrity in a hierarchy: Deal -> Pool -> Loan -> Borrower and Loan -> Remittance.
- **Named constraints** (e.g., `FK_Loan_Pool`) made error messages actionable during data loads.
- The **composite primary key** on MonthlyRemittance naturally prevented duplicate monthly reports per loan.

**Result:** The schema supported 2.4 million HECM loans across 1,200 Ginnie Mae HMBS pools. Foreign key constraints caught 3,400 orphan loan records during the initial data migration that referenced non-existent pools, preventing data integrity issues. The named constraints reduced debugging time for load failures by 60% because error messages clearly identified which relationship was violated.

**AI Vision:** Schema discovery tools powered by ML could analyze incoming data patterns and automatically recommend optimal primary key selections and foreign key relationships, reducing the manual schema design effort for new data sources from weeks to hours.

---

### Q12. Clustered vs non-clustered indexes — loan lookup optimization

**Situation:** A CoreLogic property analytics platform experienced slow query performance on the LoanMaster table containing 45 million rows. Analysts frequently queried by LoanID for single-loan lookups, by PropertyState and OriginationDate for portfolio analysis, and by ServicerID for servicer performance reports. The DBA team needed to design an indexing strategy.

**Task:** Create appropriate clustered and non-clustered indexes on the LoanMaster table to optimize the three most common access patterns while balancing write performance for daily data loads.

**Action:**
The indexing strategy was designed based on query patterns and cardinality analysis:

```sql
-- Clustered index on the primary key (physical row ordering)
-- LoanID is ideal: unique, narrow (BIGINT = 8 bytes), ever-increasing
CREATE CLUSTERED INDEX CIX_LoanMaster_LoanID
    ON LoanMaster(LoanID);

-- Non-clustered index for state + origination date queries (portfolio analysis)
CREATE NONCLUSTERED INDEX IX_LoanMaster_State_OrigDate
    ON LoanMaster(PropertyState, OriginationDate)
    INCLUDE (CurrentUPB, InterestRate, LoanStatus)
    WHERE LoanStatus = 'ACTIVE';

-- Non-clustered index for servicer performance queries
CREATE NONCLUSTERED INDEX IX_LoanMaster_ServicerID
    ON LoanMaster(ServicerID)
    INCLUDE (CurrentUPB, DelinquencyStatus, LoanStatus);

-- Verify index usage with a sample query
SELECT
    PropertyState,
    COUNT(*) AS LoanCount,
    SUM(CurrentUPB) AS TotalUPB
FROM LoanMaster
WHERE PropertyState = 'TX'
    AND OriginationDate >= '2024-01-01'
    AND LoanStatus = 'ACTIVE'
GROUP BY PropertyState;
```

Key distinctions explained:
- **Clustered index** physically orders the data on disk by LoanID. There can be only one per table. Chosen for LoanID because single-loan lookups were the most frequent operation.
- **Non-clustered indexes** are separate B-tree structures with pointers back to the data rows. Multiple can exist per table.
- **INCLUDE columns** added CurrentUPB, InterestRate, etc. to the leaf level of the non-clustered index, creating a "covering index" that avoided expensive key lookups.
- **Filtered index** (`WHERE LoanStatus = 'ACTIVE'`) reduced the index size by excluding terminated loans, making it smaller and faster.

**Result:** After implementing the indexing strategy: single-loan lookups by LoanID went from 120ms to 2ms (60x improvement); state-based portfolio queries improved from 45 seconds to 1.8 seconds (25x improvement); servicer performance aggregations dropped from 38 seconds to 2.4 seconds (16x improvement). Daily batch load time increased by only 12% due to index maintenance overhead, an acceptable trade-off.

**AI Vision:** ML-powered index advisors like SQL Server's Database Engine Tuning Advisor could analyze actual query workload patterns and recommend optimal index configurations, automatically adapting as query patterns evolve with changing business needs.

---

### Q13. VARCHAR vs NVARCHAR and data types — loan tape field definitions

**Situation:** A data engineering team was defining column data types for a new Fannie Mae loan tape ingestion table. The loan tape specification included fields like CUSIP identifiers, borrower names, loan amounts, interest rates, dates, and yes/no flags. Incorrect data type choices would waste storage on a 50-million-row table or cause data truncation errors.

**Task:** Select appropriate SQL Server data types for each loan tape field, documenting the rationale for each choice, with particular attention to VARCHAR vs NVARCHAR and numeric precision.

**Action:**
The table was defined with carefully chosen data types for each field:

```sql
CREATE TABLE FannieLoanTape (
    -- Fixed-length identifiers: CHAR for exact-length codes
    LoanID              BIGINT NOT NULL,           -- Numeric ID, 8 bytes
    CUSIP               CHAR(9) NOT NULL,          -- Always exactly 9 characters
    PoolNumber          CHAR(6) NOT NULL,          -- Fixed 6-char Fannie pool ID
    PropertyState       CHAR(2) NOT NULL,          -- Two-letter state code

    -- Variable-length text: VARCHAR for ASCII, NVARCHAR for Unicode
    BorrowerLastName    NVARCHAR(100) NULL,        -- Unicode: handles accented names
    PropertyAddress     NVARCHAR(200) NULL,        -- Unicode: special characters
    ServicerName        VARCHAR(100) NOT NULL,     -- ASCII sufficient for company names
    LoanPurpose         VARCHAR(20) NOT NULL,      -- 'PURCHASE', 'REFINANCE', etc.
    PropertyType        VARCHAR(30) NOT NULL,      -- 'SINGLE_FAMILY', 'CONDO', etc.

    -- Monetary amounts: DECIMAL with precision
    OriginalUPB         DECIMAL(14,2) NOT NULL,    -- Up to $999 billion with cents
    CurrentUPB          DECIMAL(14,2) NOT NULL,
    MonthlyPayment      DECIMAL(10,2) NOT NULL,    -- Up to $99 million with cents

    -- Rates and ratios: smaller DECIMAL
    InterestRate        DECIMAL(5,3) NOT NULL,     -- e.g., 6.375
    LTV                 DECIMAL(6,2) NOT NULL,     -- e.g., 95.50
    DTI                 DECIMAL(5,2) NULL,         -- e.g., 43.00

    -- Dates
    OriginationDate     DATE NOT NULL,             -- 3 bytes, no time component
    MaturityDate        DATE NOT NULL,
    LastPaymentDate     DATE NULL,
    LoadTimestamp       DATETIME2(3) NOT NULL,     -- Millisecond precision for ETL audit

    -- Scores and counts: INT variants
    CreditScore         SMALLINT NULL,             -- 300-850 range, 2 bytes vs 4 for INT
    OriginalLoanTerm    SMALLINT NOT NULL,          -- Months (e.g., 360)
    NumberOfUnits       TINYINT NOT NULL,           -- 1-4 units, 1 byte

    -- Flags
    FirstTimeHomeBuyer  BIT NOT NULL DEFAULT 0,    -- 1 byte for up to 8 BIT columns
    RelocationLoan      BIT NOT NULL DEFAULT 0
);
```

Data type rationale:
- **CHAR(9)** for CUSIP: always exactly 9 characters, no storage overhead of variable-length.
- **NVARCHAR** for borrower names: supports characters like accented letters in names (e.g., "Garcia" with accents). Uses 2 bytes per character vs VARCHAR's 1.
- **VARCHAR** for codes like LoanPurpose: ASCII-only values, saves 50% space over NVARCHAR.
- **DECIMAL(14,2)** for money: never use FLOAT for financial data — FLOAT cannot represent $0.01 exactly.
- **DATE** vs DATETIME2: DATE uses 3 bytes for dates-only; DATETIME2(3) provides millisecond precision for audit timestamps.
- **SMALLINT** for CreditScore: 2 bytes is sufficient for values 300-850, saving 2 bytes per row vs INT.

**Result:** The optimized data type selection reduced the average row size from 620 bytes (naive all-NVARCHAR approach) to 340 bytes, a 45% reduction. For 50 million rows, this saved approximately 14 GB of storage and proportionally reduced I/O for full table scans. The NVARCHAR columns correctly handled 2,300 borrower names with non-ASCII characters that would have been corrupted by VARCHAR.

**AI Vision:** Automated schema inference tools could analyze sample loan tape files and recommend optimal data types based on actual data distributions, flagging fields where the chosen type might cause truncation or unnecessary storage overhead.

---

### Q14. NULL handling with ISNULL/COALESCE — handling missing borrower data

**Situation:** Freddie Mac's loan-level disclosure data contained numerous NULL values in optional fields like co-borrower credit score, debt-to-income ratio, and property valuation method. Downstream reporting queries produced incorrect aggregations and display errors when NULLs propagated through calculations, causing investor reports to show blanks instead of meaningful defaults.

**Task:** Implement proper NULL handling using ISNULL and COALESCE functions to provide sensible defaults for missing borrower data in reporting queries, while distinguishing between "data not collected" and "data not applicable."

**Action:**
Multiple NULL handling strategies were applied based on the business context:

```sql
SELECT
    lm.LoanID,
    lm.OriginalUPB,

    -- ISNULL: simple two-value replacement (SQL Server specific)
    ISNULL(bi.CoBorrowerCreditScore, 0) AS CoBorrowerCreditScore,

    -- COALESCE: cascading fallback through multiple sources
    COALESCE(
        bi.ReportedDTI,
        bi.CalculatedDTI,
        bi.EstimatedDTI,
        -1
    ) AS DebtToIncomeRatio,

    -- COALESCE for servicer name from multiple reference tables
    COALESCE(
        sr.CurrentServicerName,
        ss.ServicerLegalName,
        'UNKNOWN_SERVICER'
    ) AS ServicerDisplayName,

    -- NULL-safe aggregation: NULLs are excluded from AVG by default
    -- Use CASE to make the behavior explicit
    CASE
        WHEN bi.CreditScore IS NULL THEN 'NOT_REPORTED'
        WHEN bi.CreditScore >= 740 THEN 'EXCELLENT'
        WHEN bi.CreditScore >= 680 THEN 'GOOD'
        WHEN bi.CreditScore >= 620 THEN 'FAIR'
        ELSE 'BELOW_THRESHOLD'
    END AS CreditCategory,

    -- NULL propagation in math: any NULL operand makes result NULL
    -- Use ISNULL to prevent this
    lm.OriginalUPB * ISNULL(lm.PoolFactor, 1.0) AS AdjustedUPB,

    -- NULLIF to create NULLs (prevent divide-by-zero)
    lm.CurrentUPB / NULLIF(lm.OriginalUPB, 0) AS PaydownFactor

FROM LoanMaster lm
LEFT JOIN BorrowerInfo bi ON lm.LoanID = bi.LoanID
LEFT JOIN ServicerReport sr ON lm.ServicerID = sr.ServicerID
LEFT JOIN ServicerStatic ss ON lm.ServicerID = ss.ServicerID
WHERE lm.ReportingPeriod = '2025-12-01';
```

Key differences and usage:
- **ISNULL(expr, default)**: SQL Server-specific, accepts exactly two arguments, returns the data type of the first argument.
- **COALESCE(expr1, expr2, ..., exprN)**: ANSI standard, accepts multiple arguments, cascades through them returning the first non-NULL. Better for multi-source fallback logic.
- **NULLIF(a, b)**: Returns NULL if a equals b — useful for preventing divide-by-zero errors.
- NULLs in aggregation: `AVG()` excludes NULLs, which is correct for credit score averages but could mislead if not documented.

**Result:** NULL handling corrections fixed 34,000 investor report line items that previously showed blanks or calculation errors. The COALESCE cascade for DTI recovered valid values for 89% of initially-NULL records by falling back to calculated and estimated sources. The NULLIF guard prevented 1,200 divide-by-zero errors per monthly run. Report accuracy improved from 94.6% to 99.8%.

**AI Vision:** An ML imputation model trained on borrower demographics and loan characteristics could predict missing credit scores and DTI ratios with higher accuracy than static defaults, enabling more nuanced risk segmentation even when original data is incomplete.

---

### Q15. UNION ALL — combining agency loan feeds

**Situation:** A fixed-income analytics platform aggregated loan-level data from all three government-sponsored agencies — Fannie Mae, Freddie Mac, and Ginnie Mae — into a unified view for cross-agency portfolio analysis. Each agency provided data in agency-specific tables with slightly different column structures and naming conventions.

**Task:** Write a UNION ALL query that combines loan data from all three agency tables into a standardized format, enabling cross-agency comparison and aggregate reporting.

**Action:**
UNION ALL was used with column aliasing to normalize the three schemas:

```sql
-- Combine all three agency feeds into a standardized format
SELECT
    'FNMA' AS Agency,
    LoanIdentifier AS LoanID,
    OriginalUPB,
    CurrentActualUPB AS CurrentUPB,
    OriginalInterestRate AS InterestRate,
    CreditScoreAtOrigination AS CreditScore,
    OriginalLTV AS LTV,
    OriginalLoanTerm AS LoanTermMonths,
    PropertyState,
    FirstPaymentDate AS OriginationDate,
    CurrentLoanDelinquencyStatus AS DelinquencyStatus
FROM FNMA_LoanPerformance
WHERE ReportingPeriod = '2025-12-01'

UNION ALL

SELECT
    'FHLMC' AS Agency,
    LoanSequenceNumber AS LoanID,
    OrigUPB AS OriginalUPB,
    CurrUPB AS CurrentUPB,
    OrigInterestRate AS InterestRate,
    BorrowerCreditScore AS CreditScore,
    OrigLTV AS LTV,
    OrigLoanTerm AS LoanTermMonths,
    PropertyState,
    FirstPaymentDate AS OriginationDate,
    CurrDelinqStatus AS DelinquencyStatus
FROM FHLMC_LoanPerformance
WHERE ReportingPeriod = '2025-12-01'

UNION ALL

SELECT
    'GNMA' AS Agency,
    GinnieLoanID AS LoanID,
    OriginalBalance AS OriginalUPB,
    RemainingBalance AS CurrentUPB,
    NoteRate AS InterestRate,
    FICOScore AS CreditScore,
    CLTV AS LTV,
    OrigTerm AS LoanTermMonths,
    PropState AS PropertyState,
    FirstPmtDate AS OriginationDate,
    DelinqCode AS DelinquencyStatus
FROM GNMA_LoanPerformance
WHERE ReportingMonth = '2025-12-01'

ORDER BY Agency, CurrentUPB DESC;
```

Why UNION ALL and not UNION:
- **UNION ALL** keeps all rows including duplicates. Since loans should not exist across agencies, duplicates are not expected — and removing them with UNION would add an expensive DISTINCT sort on millions of rows.
- **UNION** (without ALL) eliminates duplicate rows by performing a sort or hash operation, adding significant overhead on large datasets for no benefit here.
- The column count and data types must match across all SELECT statements.
- The ORDER BY applies to the combined result and can only appear once at the end.
- Column aliases are taken from the first SELECT in the UNION.

**Result:** The UNION ALL combined 18.4 million Fannie Mae loans, 12.1 million Freddie Mac loans, and 8.7 million Ginnie Mae loans into a unified 39.2 million row dataset. Cross-agency analysis revealed that Ginnie Mae loans had a 12% higher delinquency rate but 8% lower average balance than GSE loans, informing a $2 billion portfolio rebalancing strategy. Query execution time was 22 seconds versus 65+ seconds that three separate queries plus application-level merging required.

**AI Vision:** A federated learning approach could train a unified prepayment model across all three agencies' data without physically combining the sensitive loan-level records, respecting each agency's data governance requirements while benefiting from the combined statistical power.

---

### Q16. String functions — parsing CUSIP identifiers

**Situation:** An MBS trading desk received trade confirmations from multiple counterparties where CUSIP identifiers were inconsistently formatted — some included the check digit (9 characters), some did not (8 characters), some had leading spaces, and some concatenated the CUSIP with a pool suffix. The trade reconciliation system needed standardized 9-character CUSIPs to match against the master security reference table.

**Task:** Use SQL Server string functions to parse, clean, and standardize CUSIP identifiers from trade confirmations for reliable matching against the security master.

**Action:**
Multiple string functions were combined to handle each formatting variation:

```sql
SELECT
    TradeID,
    RawCUSIP,

    -- Remove leading/trailing whitespace
    LTRIM(RTRIM(RawCUSIP)) AS Trimmed,

    -- Extract base CUSIP (first 6 chars = issuer, next 2 = issue)
    LEFT(LTRIM(RTRIM(RawCUSIP)), 6) AS IssuerCode,
    SUBSTRING(LTRIM(RTRIM(RawCUSIP)), 7, 2) AS IssueCode,

    -- Extract check digit (9th character) if present
    CASE
        WHEN LEN(LTRIM(RTRIM(RawCUSIP))) >= 9
        THEN SUBSTRING(LTRIM(RTRIM(RawCUSIP)), 9, 1)
        ELSE NULL
    END AS CheckDigit,

    -- Standardize: uppercase, trimmed, first 9 characters only
    UPPER(LEFT(LTRIM(RTRIM(RawCUSIP)), 9)) AS StandardizedCUSIP,

    -- Detect if pool suffix was appended (more than 9 chars)
    CASE
        WHEN LEN(LTRIM(RTRIM(RawCUSIP))) > 9
        THEN SUBSTRING(LTRIM(RTRIM(RawCUSIP)), 10, LEN(RawCUSIP))
        ELSE NULL
    END AS PoolSuffix,

    -- Replace common OCR errors: letter O to zero, letter I to one
    REPLACE(REPLACE(
        UPPER(LEFT(LTRIM(RTRIM(RawCUSIP)), 9)),
        'O', '0'),
        'I', '1'
    ) AS OCRCorrectedCUSIP,

    -- Check if CUSIP matches Fannie Mae pattern (starts with 'FN' or '31')
    CASE
        WHEN LEFT(LTRIM(RTRIM(RawCUSIP)), 2) IN ('FN', '31') THEN 'FNMA'
        WHEN LEFT(LTRIM(RTRIM(RawCUSIP)), 2) IN ('FH', '31') THEN 'FHLMC'
        WHEN LEFT(LTRIM(RTRIM(RawCUSIP)), 2) IN ('GN', '36') THEN 'GNMA'
        ELSE 'UNKNOWN'
    END AS IdentifiedAgency,

    -- String length for validation
    LEN(LTRIM(RTRIM(RawCUSIP))) AS CleanLength

FROM TradeConfirmation
WHERE TradeDate = '2025-12-15';
```

String functions used:
- **LEFT / SUBSTRING**: Extract positional components from the CUSIP structure.
- **LTRIM / RTRIM**: Remove whitespace padding from counterparty feeds.
- **UPPER**: Standardize case for consistent matching.
- **LEN**: Determine actual string length for validation logic.
- **REPLACE**: Correct common OCR misreads in scanned confirmations.
- **CHARINDEX** (not shown but available): Locate specific characters within strings.

**Result:** The CUSIP standardization logic cleaned and matched 4,800 daily trade confirmations with a 99.4% auto-match rate against the security master, up from 87% before standardization. The OCR correction alone recovered 340 previously unmatched CUSIPs per month. Unmatched trades requiring manual intervention dropped from 624 per day to 29, saving the operations team 6 hours daily.

**AI Vision:** An OCR correction model trained on known CUSIP patterns could achieve near-100% correction accuracy by learning the visual confusion matrix of scanned characters, combined with a check-digit validation algorithm to verify corrections.

---

### Q17. Date functions — calculating loan age and seasoning

**Situation:** Fannie Mae's prepayment analytics team needed to calculate loan seasoning (months since origination) and remaining term for every active loan in the portfolio. These derived fields were critical inputs to prepayment models — loans exhibit distinct prepayment behaviors based on their seasoning profile (the "S-curve" effect where prepayment speeds ramp up in the first 30 months then plateau).

**Task:** Use SQL Server date functions to calculate loan age, seasoning, remaining term, days since last payment, and other time-based metrics for the active loan portfolio.

**Action:**
Date functions were applied to derive the time-based analytics fields:

```sql
SELECT
    LoanID,
    OriginationDate,
    MaturityDate,
    LastPaymentDate,

    -- Loan age in months (seasoning)
    DATEDIFF(MONTH, OriginationDate, GETDATE()) AS SeasoningMonths,

    -- Remaining term in months
    DATEDIFF(MONTH, GETDATE(), MaturityDate) AS RemainingTermMonths,

    -- Original term derived from dates
    DATEDIFF(MONTH, OriginationDate, MaturityDate) AS OriginalTermMonths,

    -- Days since last payment (for delinquency monitoring)
    DATEDIFF(DAY, LastPaymentDate, GETDATE()) AS DaysSinceLastPayment,

    -- Loan age in years (decimal for precision)
    DATEDIFF(DAY, OriginationDate, GETDATE()) / 365.25 AS LoanAgeYears,

    -- Vintage year and quarter (for cohort analysis)
    YEAR(OriginationDate) AS VintageYear,
    CONCAT(YEAR(OriginationDate), '-Q',
        DATEPART(QUARTER, OriginationDate)) AS VintageQuarter,

    -- First payment date (first of month following origination)
    DATEADD(MONTH, 1, DATEFROMPARTS(
        YEAR(OriginationDate), MONTH(OriginationDate), 1
    )) AS FirstPaymentDate,

    -- Next reporting date (first of next month)
    DATEADD(MONTH, 1, DATEFROMPARTS(
        YEAR(GETDATE()), MONTH(GETDATE()), 1
    )) AS NextReportingDate,

    -- Seasoning bucket for prepayment analysis
    CASE
        WHEN DATEDIFF(MONTH, OriginationDate, GETDATE()) <= 6 THEN '0-6 months'
        WHEN DATEDIFF(MONTH, OriginationDate, GETDATE()) <= 12 THEN '7-12 months'
        WHEN DATEDIFF(MONTH, OriginationDate, GETDATE()) <= 30 THEN '13-30 months (ramp)'
        WHEN DATEDIFF(MONTH, OriginationDate, GETDATE()) <= 60 THEN '31-60 months (peak)'
        ELSE '60+ months (seasoned)'
    END AS SeasoningBucket,

    -- End of month for reporting alignment
    EOMONTH(GETDATE()) AS CurrentReportingEOM,
    EOMONTH(GETDATE(), -1) AS PriorReportingEOM

FROM LoanMaster
WHERE LoanStatus = 'ACTIVE'
    AND Agency = 'FNMA';
```

Key date functions:
- **DATEDIFF**: Calculates the difference between two dates in the specified unit (MONTH, DAY, YEAR).
- **DATEADD**: Adds or subtracts intervals from a date.
- **DATEPART / YEAR / MONTH**: Extracts components from a date.
- **DATEFROMPARTS**: Constructs a date from year, month, and day components.
- **EOMONTH**: Returns the last day of the month (with optional offset).
- **GETDATE()**: Returns the current date and time.

**Result:** The date calculations enabled the prepayment analytics team to assign accurate seasoning values to 18.4 million active Fannie Mae loans. Cohort analysis by VintageQuarter revealed that 2024-Q1 originations (4.2 million loans) had reached the 13-30 month "ramp" phase and were showing 22% higher CPR than the same seasoning bucket historically, signaling a refinancing wave. This insight influenced $3.5 billion in MBS trading decisions.

**AI Vision:** A time-series forecasting model incorporating seasoning curves, rate incentive, and seasonal patterns could predict monthly prepayment speeds at the pool level with greater accuracy than traditional PSA assumptions, improving MBS cash flow projections.

---

### Q18. CASE expressions — categorizing loans by LTV buckets

**Situation:** A Freddie Mac credit risk analyst needed to segment the loan portfolio into Loan-to-Value (LTV) risk buckets for capital adequacy reporting under FHFA guidelines. Loans with LTV above 80% required private mortgage insurance (PMI), and those above 97% faced additional scrutiny. The segmentation needed to feed both regulatory reports and internal risk dashboards.

**Task:** Use CASE expressions to categorize loans into LTV risk buckets and calculate aggregate statistics for each bucket, providing the data foundation for credit risk reporting.

**Action:**
CASE expressions were used in both SELECT and GROUP BY to create multi-dimensional categorization:

```sql
-- LTV risk bucket categorization with aggregated stats
SELECT
    CASE
        WHEN OriginalLTV <= 60 THEN '1. Conservative (<=60%)'
        WHEN OriginalLTV <= 70 THEN '2. Low (61-70%)'
        WHEN OriginalLTV <= 80 THEN '3. Standard (71-80%)'
        WHEN OriginalLTV <= 90 THEN '4. High (81-90%) - PMI Required'
        WHEN OriginalLTV <= 97 THEN '5. Very High (91-97%) - PMI Required'
        WHEN OriginalLTV > 97  THEN '6. Super High (>97%) - Enhanced Review'
        ELSE '7. Unknown LTV'
    END AS LTVBucket,

    -- Combined risk category using nested CASE
    CASE
        WHEN OriginalLTV <= 80 AND CreditScore >= 720
            THEN 'LOW_RISK'
        WHEN OriginalLTV <= 80 AND CreditScore >= 660
            THEN 'MODERATE_RISK'
        WHEN OriginalLTV > 80 AND CreditScore >= 720
            THEN 'ELEVATED_RISK'
        WHEN OriginalLTV > 80 AND CreditScore < 720
            THEN 'HIGH_RISK'
        ELSE 'UNCLASSIFIED'
    END AS CombinedRiskCategory,

    COUNT(*) AS LoanCount,
    SUM(CurrentUPB) AS TotalUPB,
    AVG(CurrentUPB) AS AvgLoanSize,
    AVG(InterestRate) AS AvgRate,
    AVG(CreditScore) AS AvgFICO,
    SUM(CASE WHEN DelinquencyStatus >= 2 THEN 1 ELSE 0 END) AS DelinquentCount,
    CAST(SUM(CASE WHEN DelinquencyStatus >= 2 THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / COUNT(*) * 100 AS DelinquencyRate,

    -- PMI coverage flag using simple CASE
    SUM(CASE WHEN PMIPercentage > 0 THEN 1 ELSE 0 END) AS WithPMI

FROM LoanPerformance
WHERE ReportingPeriod = '2025-12-01'
    AND Agency = 'FHLMC'
    AND LoanStatus = 'ACTIVE'
GROUP BY
    CASE
        WHEN OriginalLTV <= 60 THEN '1. Conservative (<=60%)'
        WHEN OriginalLTV <= 70 THEN '2. Low (61-70%)'
        WHEN OriginalLTV <= 80 THEN '3. Standard (71-80%)'
        WHEN OriginalLTV <= 90 THEN '4. High (81-90%) - PMI Required'
        WHEN OriginalLTV <= 97 THEN '5. Very High (91-97%) - PMI Required'
        WHEN OriginalLTV > 97  THEN '6. Super High (>97%) - Enhanced Review'
        ELSE '7. Unknown LTV'
    END,
    CASE
        WHEN OriginalLTV <= 80 AND CreditScore >= 720
            THEN 'LOW_RISK'
        WHEN OriginalLTV <= 80 AND CreditScore >= 660
            THEN 'MODERATE_RISK'
        WHEN OriginalLTV > 80 AND CreditScore >= 720
            THEN 'ELEVATED_RISK'
        WHEN OriginalLTV > 80 AND CreditScore < 720
            THEN 'HIGH_RISK'
        ELSE 'UNCLASSIFIED'
    END
ORDER BY LTVBucket, CombinedRiskCategory;
```

CASE expression features:
- **Searched CASE** (CASE WHEN condition THEN result): Evaluates conditions in order, returns the first TRUE match.
- CASE in **GROUP BY**: The same expression must be repeated in GROUP BY since SQL Server does not allow aliases in GROUP BY.
- **Nested classification**: The CombinedRiskCategory CASE uses both LTV and credit score to create a two-dimensional risk matrix.
- CASE inside **aggregate functions**: Used to create conditional counts (e.g., delinquent loan count within each bucket).

**Result:** The LTV segmentation revealed that 23% of the Freddie Mac portfolio ($680 billion) fell in the "High LTV with PMI Required" buckets, with those loans showing a 3.8% delinquency rate versus 1.2% for loans at or below 80% LTV. The combined risk matrix identified 1.4 million "HIGH_RISK" loans (high LTV plus sub-720 FICO) totaling $340 billion that required $4.2 billion in additional capital reserves under FHFA guidelines.

**AI Vision:** A gradient-boosted classification model could replace static LTV/FICO buckets with continuous default probability scores, providing more granular risk segmentation and more efficient capital allocation by eliminating the information loss inherent in bucket-based approaches.

---

### Q19. Basic stored procedure — monthly pool factor calculation

**Situation:** Fannie Mae's MBS operations team calculated monthly pool factors — the ratio of a pool's current UPB to its original UPB — for every active pool. This factor is published to investors and used in settlement calculations. The calculation ran on the 5th business day of each month and needed to be a repeatable, parameterized, auditable operation.

**Task:** Create a stored procedure that calculates pool factors for a given reporting month, updates the PoolDetail table, and logs the calculation for audit purposes.

**Action:**
A stored procedure encapsulated the monthly pool factor calculation logic:

```sql
CREATE PROCEDURE dbo.usp_CalculateMonthlyPoolFactors
    @ReportingMonth DATE,
    @Agency         VARCHAR(10) = 'FNMA'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RowsUpdated INT;
    DECLARE @StartTime DATETIME2 = SYSDATETIME();

    -- Validate input parameter
    IF DAY(@ReportingMonth) <> 1
    BEGIN
        RAISERROR('ReportingMonth must be the first of the month.', 16, 1);
        RETURN -1;
    END

    -- Calculate current pool UPB from loan-level data
    -- and update pool factors in PoolDetail
    UPDATE pd
    SET
        pd.CurrentPoolUPB  = agg.SumCurrentUPB,
        pd.PoolFactor       = CASE
                                WHEN pd.OriginalPoolUPB > 0
                                THEN CAST(agg.SumCurrentUPB / pd.OriginalPoolUPB
                                     AS DECIMAL(12,10))
                                ELSE 0
                              END,
        pd.ActiveLoanCount  = agg.ActiveLoans,
        pd.WACoupon          = agg.WeightedAvgCoupon,
        pd.FactorDate        = @ReportingMonth,
        pd.LastCalculated    = SYSDATETIME()
    FROM PoolDetail pd
    INNER JOIN (
        SELECT
            PoolNumber,
            SUM(CurrentUPB) AS SumCurrentUPB,
            COUNT(*) AS ActiveLoans,
            SUM(InterestRate * CurrentUPB) / NULLIF(SUM(CurrentUPB), 0)
                AS WeightedAvgCoupon
        FROM MonthlyRemittance
        WHERE ReportingMonth = @ReportingMonth
            AND LoanStatus = 'ACTIVE'
        GROUP BY PoolNumber
    ) agg
        ON pd.PoolNumber = agg.PoolNumber
    WHERE pd.Agency = @Agency
        AND pd.PoolStatus = 'ACTIVE';

    SET @RowsUpdated = @@ROWCOUNT;

    -- Log the calculation for audit trail
    INSERT INTO PoolFactorAuditLog (
        ReportingMonth,
        Agency,
        PoolsUpdated,
        ExecutionStartTime,
        ExecutionEndTime,
        ExecutedBy
    )
    VALUES (
        @ReportingMonth,
        @Agency,
        @RowsUpdated,
        @StartTime,
        SYSDATETIME(),
        SYSTEM_USER
    );

    -- Return summary
    SELECT
        @RowsUpdated AS PoolsUpdated,
        MIN(pd.PoolFactor) AS MinFactor,
        MAX(pd.PoolFactor) AS MaxFactor,
        AVG(pd.PoolFactor) AS AvgFactor
    FROM PoolDetail pd
    WHERE pd.Agency = @Agency
        AND pd.FactorDate = @ReportingMonth;

    RETURN 0;
END;
GO

-- Execute the procedure
EXEC dbo.usp_CalculateMonthlyPoolFactors
    @ReportingMonth = '2025-12-01',
    @Agency = 'FNMA';
```

Stored procedure features:
- **Parameters** with defaults make the procedure flexible and reusable across agencies.
- **SET NOCOUNT ON** prevents row count messages from interfering with application result sets.
- **Input validation** with RAISERROR rejects invalid parameters early.
- **@@ROWCOUNT** captures the number of affected rows for audit logging.
- **Weighted average coupon** (WACoupon) was calculated using the UPB-weighted formula in the subquery.
- The **audit log insert** provided a complete execution history for regulatory examination.

**Result:** The stored procedure processed pool factors for 12,400 active Fannie Mae pools in 47 seconds, down from the 25-minute manual process it replaced. Pool factors ranged from 0.0234 (nearly paid-off vintage 2005 pools) to 0.9876 (newly issued 2025 pools), with an average of 0.6123. The audit log enabled regulators to verify that factors were calculated on schedule for all 12 months of the year, supporting Fannie Mae's SOC 2 compliance certification.

**AI Vision:** A scheduled ML pipeline could automatically detect anomalous pool factor changes — such as unexpectedly large month-over-month drops indicating a data error or a mass prepayment event — and flag them for review before factors are published to investors.

---

### Q20. Creating views — servicer performance dashboard

**Situation:** Ginnie Mae's issuer oversight division needed a performance dashboard for their 300+ approved issuers (servicers). The dashboard required metrics spanning multiple tables — loan performance, payment remittance, delinquency data, and loss mitigation outcomes. Analysts needed a simplified interface that hid the complex multi-table joins while ensuring consistent metric definitions across all reports.

**Task:** Create SQL Server views that encapsulate complex servicer performance queries, providing a reusable, maintainable layer for the performance dashboard and regulatory reports.

**Action:**
A view was created to pre-join and calculate servicer-level KPIs:

```sql
CREATE VIEW dbo.vw_ServicerPerformanceDashboard
AS
SELECT
    sr.ServicerID,
    sr.ServicerName,
    sr.ApprovalStatus,
    rpt.ReportingMonth,

    -- Portfolio size metrics
    rpt.ActiveLoanCount,
    rpt.TotalCurrentUPB,
    rpt.AvgLoanBalance,

    -- Delinquency metrics
    rpt.DQ30Count,
    rpt.DQ60Count,
    rpt.DQ90PlusCount,
    CAST(rpt.DQ60Count + rpt.DQ90PlusCount AS DECIMAL(10,4))
        / NULLIF(rpt.ActiveLoanCount, 0) * 100 AS SeriousDelinquencyRate,

    -- Loss mitigation effectiveness
    lm_stats.TrialModsStarted,
    lm_stats.TrialModsConverted,
    CAST(lm_stats.TrialModsConverted AS DECIMAL(10,4))
        / NULLIF(lm_stats.TrialModsStarted, 0) * 100 AS ModConversionRate,

    -- Payment processing
    rpt.TotalPrincipalCollected,
    rpt.TotalInterestCollected,
    rpt.AvgDaysToReport

FROM ServicerReport sr
INNER JOIN (
    SELECT
        ServicerID,
        ReportingMonth,
        COUNT(*) AS ActiveLoanCount,
        SUM(CurrentUPB) AS TotalCurrentUPB,
        AVG(CurrentUPB) AS AvgLoanBalance,
        SUM(CASE WHEN DelinquencyStatus = 1 THEN 1 ELSE 0 END) AS DQ30Count,
        SUM(CASE WHEN DelinquencyStatus = 2 THEN 1 ELSE 0 END) AS DQ60Count,
        SUM(CASE WHEN DelinquencyStatus >= 3 THEN 1 ELSE 0 END) AS DQ90PlusCount,
        SUM(ScheduledPrincipal + PrepaidPrincipal) AS TotalPrincipalCollected,
        SUM(InterestCollected) AS TotalInterestCollected,
        AVG(DATEDIFF(DAY, PaymentDueDate, PaymentReceivedDate)) AS AvgDaysToReport
    FROM MonthlyRemittance
    WHERE LoanStatus = 'ACTIVE'
    GROUP BY ServicerID, ReportingMonth
) rpt
    ON sr.ServicerID = rpt.ServicerID
LEFT JOIN (
    SELECT
        ServicerID,
        ReportingMonth,
        COUNT(*) AS TrialModsStarted,
        SUM(CASE WHEN ConversionFlag = 'Y' THEN 1 ELSE 0 END) AS TrialModsConverted
    FROM TrialModification
    GROUP BY ServicerID, ReportingMonth
) lm_stats
    ON sr.ServicerID = lm_stats.ServicerID
    AND rpt.ReportingMonth = lm_stats.ReportingMonth;
GO

-- Query the view as if it were a simple table
SELECT
    ServicerName,
    ActiveLoanCount,
    TotalCurrentUPB,
    SeriousDelinquencyRate,
    ModConversionRate
FROM dbo.vw_ServicerPerformanceDashboard
WHERE ReportingMonth = '2025-12-01'
    AND ActiveLoanCount > 1000
ORDER BY SeriousDelinquencyRate DESC;
```

View benefits:
- **Abstraction**: Analysts query a single "table" instead of writing complex multi-table joins.
- **Consistency**: Metric definitions (e.g., Serious Delinquency = DQ60 + DQ90+) are defined once and used everywhere.
- **Security**: Views can restrict which columns and rows users see via GRANT permissions.
- **Maintainability**: If the underlying table structure changes, only the view definition needs updating — all downstream queries remain unchanged.

**Result:** The servicer performance view was used by 45 analysts across three divisions, eliminating 120+ duplicate query definitions that previously had inconsistent metric calculations. The dashboard identified 12 servicers with serious delinquency rates above 8% and modification conversion rates below 30%, triggering corrective action plans. Standardized metrics reduced regulatory reporting discrepancies by 95% and saved 200+ analyst-hours per month.

**AI Vision:** A servicer scoring model could integrate dashboard metrics into a composite performance index, using anomaly detection to automatically flag servicers whose performance trajectory is deteriorating before they breach regulatory thresholds.

---

### Q21. Temp tables — staging loan tape transformations

**Situation:** A monthly ETL pipeline at a mortgage analytics firm processed Intex Solutions non-agency RMBS loan tape files. The raw data required multiple transformation steps — data type conversions, deduplication, business rule application, and enrichment with reference data — before loading into the production data warehouse. Each step needed to be observable for debugging.

**Task:** Use temporary tables to stage intermediate transformation results in the ETL pipeline, enabling step-by-step debugging, row count validation, and clean separation of transformation logic.

**Action:**
Temp tables staged each transformation phase:

```sql
-- Step 1: Load raw data into temp table with initial type conversions
CREATE TABLE #RawLoanTape (
    RawLoanID       VARCHAR(50),
    DealName        VARCHAR(100),
    CurrentUPB      DECIMAL(14,2),
    InterestRate    DECIMAL(5,3),
    LTV             DECIMAL(6,2),
    CreditScore     INT NULL,
    PropertyState   CHAR(2),
    OriginationDate DATE,
    LoanStatus      VARCHAR(20),
    RowHash         VARBINARY(32) NULL
);

INSERT INTO #RawLoanTape (
    RawLoanID, DealName, CurrentUPB, InterestRate,
    LTV, CreditScore, PropertyState, OriginationDate, LoanStatus
)
SELECT
    LoanID,
    DealName,
    CAST(UPBAmount AS DECIMAL(14,2)),
    CAST(NoteRate AS DECIMAL(5,3)),
    CAST(OrigLTV AS DECIMAL(6,2)),
    CASE WHEN FICOScore = '   ' THEN NULL ELSE CAST(FICOScore AS INT) END,
    StateCode,
    CAST(OrigDate AS DATE),
    StatusCode
FROM Staging_IntexRawFile
WHERE FileLoadDate = '2025-12-05';

-- Add hash for deduplication
UPDATE #RawLoanTape
SET RowHash = HASHBYTES('SHA2_256',
    CONCAT(RawLoanID, '|', DealName, '|', CAST(CurrentUPB AS VARCHAR)));

-- Step 2: Deduplicate into a clean temp table
SELECT *
INTO #DeduplicatedLoans
FROM (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY RawLoanID, DealName
            ORDER BY CurrentUPB DESC
        ) AS RowRank
    FROM #RawLoanTape
) ranked
WHERE RowRank = 1;

-- Verify dedup counts
SELECT
    'Raw' AS Stage, COUNT(*) AS RowCount FROM #RawLoanTape
UNION ALL
SELECT
    'Deduped', COUNT(*) FROM #DeduplicatedLoans;

-- Step 3: Enrich with reference data into final staging temp table
SELECT
    dl.RawLoanID AS LoanID,
    dl.DealName,
    dd.DealID,
    dl.CurrentUPB,
    dl.InterestRate,
    dl.LTV,
    COALESCE(dl.CreditScore, ref.MedianFICO) AS CreditScore,
    dl.PropertyState,
    dl.OriginationDate,
    dl.LoanStatus,
    ref.MSACode,
    ref.MedianHomePrice,
    GETDATE() AS TransformTimestamp
INTO #EnrichedLoans
FROM #DeduplicatedLoans dl
INNER JOIN DealDirectory dd
    ON dl.DealName = dd.DealName
LEFT JOIN PropertyReference ref
    ON dl.PropertyState = ref.StateCode;

-- Step 4: Load to production from final temp table
INSERT INTO LoanMaster (
    LoanID, DealID, CurrentUPB, InterestRate, LTV,
    CreditScore, PropertyState, OriginationDate,
    LoanStatus, MSACode, LoadTimestamp
)
SELECT
    LoanID, DealID, CurrentUPB, InterestRate, LTV,
    CreditScore, PropertyState, OriginationDate,
    LoanStatus, MSACode, TransformTimestamp
FROM #EnrichedLoans;

-- Cleanup (happens automatically when session ends, but explicit is clearer)
DROP TABLE IF EXISTS #RawLoanTape;
DROP TABLE IF EXISTS #DeduplicatedLoans;
DROP TABLE IF EXISTS #EnrichedLoans;
```

Temp table characteristics:
- **#TableName** (single hash): Session-scoped — visible only to the creating session, automatically dropped when the session ends.
- **##TableName** (double hash): Global temp table — visible to all sessions, dropped when the last referencing session ends. Rarely used in ETL.
- **SELECT...INTO**: Creates a temp table and populates it in one statement, inheriting column definitions from the SELECT.
- Temp tables support indexes, constraints, and statistics — unlike table variables which have limited optimization.
- Each step can be independently verified with COUNT(*) checks before proceeding.

**Result:** The temp-table-based ETL pipeline processed 3.2 million Intex loan tape records through four transformation stages. Deduplication removed 18,400 duplicate rows (0.6%). COALESCE enrichment filled 42,000 missing credit scores with state-level medians. The step-by-step approach reduced ETL debugging time from 4 hours to 30 minutes per issue because analysts could inspect intermediate results at each stage. Total pipeline execution: 6 minutes 15 seconds.

**AI Vision:** An intelligent ETL orchestrator could learn from historical pipeline failures and automatically suggest data quality checks between stages, predicting which transformation steps are most likely to produce errors based on source file characteristics.

---

### Q22. Normalization (1NF, 2NF, 3NF) — loan database design

**Situation:** A startup building a Fannie Mae data platform initially stored all loan data in a single denormalized Excel-to-SQL table with 180 columns. The table contained repeating groups (multiple borrower columns like Borrower1Name, Borrower2Name), partial dependencies (property city determined by zip code, not by loan ID), and transitive dependencies (servicer name determined by servicer ID, not by loan). The table had grown to 40 million rows and suffered from update anomalies and data inconsistencies.

**Task:** Normalize the denormalized loan table from its current state through First, Second, and Third Normal Form, creating a clean relational schema that eliminates data anomalies while maintaining query performance for common access patterns.

**Action:**
The normalization was applied progressively through each normal form:

**Before normalization (denormalized flat table):**
```sql
-- Original flat table (problematic)
CREATE TABLE LoanFlat (
    LoanID              BIGINT,
    Borrower1Name       VARCHAR(100),
    Borrower1FICO       INT,
    Borrower2Name       VARCHAR(100),  -- Repeating group!
    Borrower2FICO       INT,           -- Repeating group!
    PropertyAddress     VARCHAR(200),
    PropertyCity        VARCHAR(50),
    PropertyState       CHAR(2),
    PropertyZip         CHAR(5),
    ServicerID          INT,
    ServicerName        VARCHAR(100),  -- Transitive dependency!
    ServicerPhone       VARCHAR(15),   -- Transitive dependency!
    LoanAmount          DECIMAL(14,2),
    InterestRate        DECIMAL(5,3),
    LoanPurpose         VARCHAR(20)
);
```

**1NF — Eliminate repeating groups:**
```sql
-- 1NF: Each column holds atomic values, no repeating groups
-- Move borrowers to a separate table with one row per borrower
CREATE TABLE Loan_1NF (
    LoanID          BIGINT PRIMARY KEY,
    PropertyAddress VARCHAR(200),
    PropertyCity    VARCHAR(50),
    PropertyState   CHAR(2),
    PropertyZip     CHAR(5),
    ServicerID      INT,
    ServicerName    VARCHAR(100),
    ServicerPhone   VARCHAR(15),
    LoanAmount      DECIMAL(14,2),
    InterestRate    DECIMAL(5,3),
    LoanPurpose     VARCHAR(20)
);

CREATE TABLE Borrower_1NF (
    BorrowerID   BIGINT PRIMARY KEY,
    LoanID       BIGINT NOT NULL REFERENCES Loan_1NF(LoanID),
    BorrowerName VARCHAR(100),
    BorrowerFICO INT,
    BorrowerType VARCHAR(15)  -- 'PRIMARY' or 'CO_BORROWER'
);
```

**2NF — Eliminate partial dependencies:**
```sql
-- 2NF: All non-key columns depend on the ENTIRE primary key
-- PropertyCity depends on PropertyZip, not on LoanID -> extract Property
CREATE TABLE Property_2NF (
    PropertyID      BIGINT PRIMARY KEY,
    PropertyAddress VARCHAR(200),
    PropertyZip     CHAR(5),
    PropertyCity    VARCHAR(50),   -- Depends on Zip, moved here
    PropertyState   CHAR(2)        -- Depends on Zip, moved here
);

CREATE TABLE Loan_2NF (
    LoanID       BIGINT PRIMARY KEY,
    PropertyID   BIGINT NOT NULL REFERENCES Property_2NF(PropertyID),
    ServicerID   INT,
    ServicerName VARCHAR(100),     -- Still has transitive dependency
    ServicerPhone VARCHAR(15),     -- Still has transitive dependency
    LoanAmount   DECIMAL(14,2),
    InterestRate DECIMAL(5,3),
    LoanPurpose  VARCHAR(20)
);
```

**3NF — Eliminate transitive dependencies:**
```sql
-- 3NF: No non-key column depends on another non-key column
-- ServicerName/Phone depend on ServicerID, not LoanID -> extract Servicer
CREATE TABLE Servicer_3NF (
    ServicerID    INT PRIMARY KEY,
    ServicerName  VARCHAR(100) NOT NULL,
    ServicerPhone VARCHAR(15)
);

CREATE TABLE ZipCodeRef (
    ZipCode   CHAR(5) PRIMARY KEY,
    City      VARCHAR(50) NOT NULL,
    StateCode CHAR(2) NOT NULL
);

CREATE TABLE Property_3NF (
    PropertyID      BIGINT PRIMARY KEY,
    PropertyAddress VARCHAR(200),
    ZipCode         CHAR(5) NOT NULL REFERENCES ZipCodeRef(ZipCode)
);

CREATE TABLE Loan_3NF (
    LoanID       BIGINT PRIMARY KEY,
    PropertyID   BIGINT NOT NULL REFERENCES Property_3NF(PropertyID),
    ServicerID   INT NOT NULL REFERENCES Servicer_3NF(ServicerID),
    LoanAmount   DECIMAL(14,2) NOT NULL,
    InterestRate DECIMAL(5,3) NOT NULL,
    LoanPurpose  VARCHAR(20) NOT NULL
);

CREATE TABLE Borrower_3NF (
    BorrowerID   BIGINT PRIMARY KEY,
    LoanID       BIGINT NOT NULL REFERENCES Loan_3NF(LoanID),
    BorrowerName VARCHAR(100) NOT NULL,
    BorrowerFICO INT NULL,
    BorrowerType VARCHAR(15) NOT NULL
);
```

Normalization summary:
- **1NF**: Atomic values, no repeating groups — borrower columns became rows in a separate table.
- **2NF**: No partial dependencies — every non-key attribute depends on the whole key.
- **3NF**: No transitive dependencies — ServicerName depends on ServicerID (not LoanID), so Servicer was extracted.

**Result:** Normalization reduced the storage footprint from 82 GB to 54 GB (34% reduction) by eliminating redundant servicer and zip code data replicated across millions of rows. Servicer name updates (which previously required updating 40 million rows) now required updating a single row in the Servicer table. Data inconsistencies dropped from 12,000 per month to zero, and the ETL team reported that data quality issues decreased by 85%.

**AI Vision:** Automated schema normalization tools using dependency detection algorithms could analyze existing denormalized tables and recommend optimal normalization levels, balancing data integrity with query performance requirements specific to the workload.

---

### Q23. IDENTITY columns — auto-generating surrogate keys for deals

**Situation:** A Freddie Mac securitization platform needed to assign unique internal identifiers to new MBS deals as they were created. The natural key (DealName) was a complex string like "FHLMC-2025-DNA-005" that was unsuitable for foreign key relationships due to its length, potential for typos, and possible changes during the deal structuring process. A surrogate key strategy was needed.

**Task:** Implement IDENTITY columns to auto-generate surrogate keys for new deal records, ensuring unique, sequential, compact integer identifiers that serve as reliable foreign keys throughout the data model.

**Action:**
IDENTITY was configured on the deal table with appropriate settings:

```sql
-- Create deal table with IDENTITY surrogate key
CREATE TABLE DealMaster (
    DealID          INT IDENTITY(1000, 1) NOT NULL,  -- Start at 1000, increment by 1
    DealName        VARCHAR(50) NOT NULL,
    Agency          VARCHAR(10) NOT NULL,
    IssueDate       DATE NOT NULL,
    OriginalBalance DECIMAL(18,2) NOT NULL,
    DealStatus      VARCHAR(20) NOT NULL DEFAULT 'STRUCTURING',
    CreatedDate     DATETIME2 DEFAULT SYSDATETIME(),
    CONSTRAINT PK_DealMaster PRIMARY KEY (DealID),
    CONSTRAINT UQ_DealName UNIQUE (DealName)
);

-- Insert new deals — DealID is auto-generated
INSERT INTO DealMaster (DealName, Agency, IssueDate, OriginalBalance)
VALUES
    ('FHLMC-2025-DNA-005', 'FHLMC', '2025-12-15', 1500000000.00),
    ('FHLMC-2025-DNA-006', 'FHLMC', '2025-12-20', 2200000000.00),
    ('FHLMC-2025-HQA-003', 'FHLMC', '2025-12-22', 1800000000.00);

-- Retrieve the last generated IDENTITY value
SELECT SCOPE_IDENTITY() AS LastDealID;

-- Verify the auto-generated IDs
SELECT DealID, DealName, Agency, OriginalBalance
FROM DealMaster
ORDER BY DealID DESC;
-- Returns:
-- 1002  FHLMC-2025-HQA-003  FHLMC  1800000000.00
-- 1001  FHLMC-2025-DNA-006  FHLMC  2200000000.00
-- 1000  FHLMC-2025-DNA-005  FHLMC  1500000000.00

-- Use the surrogate key as FK in related tables
CREATE TABLE DealTranche (
    TrancheID       INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DealID          INT NOT NULL,
    TrancheName     VARCHAR(10) NOT NULL,   -- e.g., 'A1', 'M1', 'B1'
    TrancheBalance  DECIMAL(18,2) NOT NULL,
    CouponRate      DECIMAL(5,3) NOT NULL,
    Rating          VARCHAR(5) NULL,
    CONSTRAINT FK_Tranche_Deal
        FOREIGN KEY (DealID) REFERENCES DealMaster(DealID)
);

-- Insert tranches referencing the deal
INSERT INTO DealTranche (DealID, TrancheName, TrancheBalance, CouponRate, Rating)
VALUES
    (1000, 'A1', 1200000000.00, 4.500, 'AAA'),
    (1000, 'M1',  200000000.00, 5.250, 'AA'),
    (1000, 'B1',  100000000.00, 6.750, 'BBB');
```

IDENTITY considerations:
- **IDENTITY(seed, increment)**: seed=1000 reserves IDs below 1000 for system or test records; increment=1 generates sequential values.
- **SCOPE_IDENTITY()**: Returns the last IDENTITY value generated in the current scope — safer than @@IDENTITY which can return values from triggered inserts in other tables.
- **UNIQUE constraint on DealName**: The natural key is still enforced for data integrity, but the surrogate key (DealID) is used for all foreign key relationships.
- IDENTITY values are not reused after deletes — gaps can occur but are acceptable.
- For high-concurrency inserts, IDENTITY is thread-safe and will not generate duplicates.

**Result:** The IDENTITY-based surrogate key strategy assigned compact 4-byte INT identifiers to 3,400 deals, replacing 50-character VARCHAR natural keys in all foreign key relationships. Join performance on DealID (INT) was 3.5x faster than joins on DealName (VARCHAR(50)). The UNIQUE constraint on DealName prevented 23 duplicate deal creation attempts during the first quarter. Storage savings from the smaller FK columns across 12 related tables totaled 2.1 GB.

**AI Vision:** A deal identification system using NLP could parse unstructured deal term sheets and automatically populate the DealMaster table with structured attributes, reducing manual deal setup time from 2 hours to 15 minutes per deal.

---

### Q24. TOP and OFFSET-FETCH — paginating large loan result sets

**Situation:** A web-based portal for Ginnie Mae issuers displayed loan-level data for their servicing portfolios. Some issuers serviced over 500,000 loans, and returning all results at once caused application timeouts and excessive memory consumption. The portal needed server-side pagination to return manageable pages of 50 loans at a time.

**Task:** Implement efficient pagination using both TOP and OFFSET-FETCH approaches, enabling the portal to retrieve specific pages of loan data without loading the entire result set.

**Action:**
Two pagination approaches were implemented:

```sql
-- Approach 1: TOP for retrieving just the first N rows
-- "Show me the top 50 largest loans by balance"
SELECT TOP 50
    LoanID,
    CurrentUPB,
    InterestRate,
    BorrowerCreditScore,
    PropertyState,
    DelinquencyStatus
FROM LoanMaster
WHERE ServicerID = 4521
    AND LoanStatus = 'ACTIVE'
ORDER BY CurrentUPB DESC;

-- TOP with PERCENT
SELECT TOP 1 PERCENT
    LoanID,
    CurrentUPB
FROM LoanMaster
WHERE Agency = 'GNMA'
ORDER BY CurrentUPB DESC;

-- Approach 2: OFFSET-FETCH for true pagination
-- Page 1 (rows 1-50)
SELECT
    LoanID,
    CurrentUPB,
    InterestRate,
    BorrowerCreditScore,
    PropertyState,
    DelinquencyStatus
FROM LoanMaster
WHERE ServicerID = 4521
    AND LoanStatus = 'ACTIVE'
ORDER BY LoanID  -- Deterministic ordering required
OFFSET 0 ROWS
FETCH NEXT 50 ROWS ONLY;

-- Page 2 (rows 51-100)
SELECT
    LoanID,
    CurrentUPB,
    InterestRate,
    BorrowerCreditScore,
    PropertyState,
    DelinquencyStatus
FROM LoanMaster
WHERE ServicerID = 4521
    AND LoanStatus = 'ACTIVE'
ORDER BY LoanID
OFFSET 50 ROWS
FETCH NEXT 50 ROWS ONLY;

-- Dynamic pagination with variables
DECLARE @PageNumber INT = 5;
DECLARE @PageSize INT = 50;

SELECT
    LoanID,
    CurrentUPB,
    InterestRate,
    BorrowerCreditScore,
    PropertyState,
    DelinquencyStatus
FROM LoanMaster
WHERE ServicerID = 4521
    AND LoanStatus = 'ACTIVE'
ORDER BY LoanID
OFFSET (@PageNumber - 1) * @PageSize ROWS
FETCH NEXT @PageSize ROWS ONLY;

-- Include total count for UI pagination controls
SELECT
    COUNT(*) AS TotalLoans,
    CEILING(COUNT(*) * 1.0 / 50) AS TotalPages
FROM LoanMaster
WHERE ServicerID = 4521
    AND LoanStatus = 'ACTIVE';
```

Key differences:
- **TOP N**: Returns the first N rows from the ordered result. Simple but cannot skip rows — only useful for "first page" scenarios.
- **OFFSET-FETCH**: Part of the ORDER BY clause (SQL Server 2012+). OFFSET skips a specified number of rows, FETCH NEXT limits the return count. Enables true random-page access.
- **ORDER BY is required** for OFFSET-FETCH — without deterministic ordering, the same page could return different rows on repeated calls.
- **Performance note**: Deep pagination (e.g., OFFSET 400000) can be slow because SQL Server must still sort and skip all preceding rows. For very deep pages, a keyset pagination approach using WHERE LoanID > @LastSeenID is more efficient.

**Result:** Server-side pagination reduced the portal's average API response time from 12 seconds (full result set) to 180 milliseconds (single page of 50 rows). Memory consumption per request dropped from 450 MB to 2 MB. The largest issuer's portfolio of 520,000 loans was navigable across 10,400 pages with consistent sub-200ms response times. Portal timeout errors dropped from 340 per day to zero.

**AI Vision:** A smart pagination system could use ML to predict which pages users are most likely to visit next based on their navigation patterns, pre-fetching those pages into cache for instant display, and dynamically reordering results based on the user's likely intent.

---

### Q25. BEGIN TRAN/COMMIT/ROLLBACK — safe batch loan updates

**Situation:** Fannie Mae's monthly reconciliation process required updating loan statuses, balances, and delinquency codes for millions of loans in a single batch operation. If any part of the update failed — due to a constraint violation, data type error, or deadlock — the entire batch needed to roll back to prevent the database from entering an inconsistent state where some loans were updated and others were not.

**Task:** Implement explicit transaction management with BEGIN TRAN, COMMIT, and ROLLBACK to ensure atomic batch loan updates, with proper error handling using TRY...CATCH to guarantee data consistency.

**Action:**
A transaction-wrapped batch update with error handling was implemented:

```sql
DECLARE @BatchID INT = 20251201;
DECLARE @RowsAffected INT = 0;
DECLARE @ErrorMessage NVARCHAR(4000);
DECLARE @ErrorSeverity INT;

BEGIN TRY
    BEGIN TRANSACTION;

    -- Step 1: Update loan statuses from servicer feed
    UPDATE lm
    SET
        lm.LoanStatus       = sf.NewStatus,
        lm.CurrentUPB        = sf.ReportedUPB,
        lm.DelinquencyStatus = sf.DelinquencyCode,
        lm.LastModifiedDate  = GETDATE()
    FROM LoanMaster lm
    INNER JOIN ServicerFeed sf
        ON lm.LoanID = sf.LoanID
    WHERE sf.BatchID = @BatchID
        AND sf.ValidationStatus = 'PASSED';

    SET @RowsAffected = @@ROWCOUNT;

    -- Step 2: Mark paid-off loans
    UPDATE LoanMaster
    SET LoanStatus = 'PAID_OFF',
        TerminationDate = GETDATE()
    WHERE LoanID IN (
        SELECT LoanID
        FROM ServicerFeed
        WHERE BatchID = @BatchID
            AND NewStatus = 'PAID_OFF'
            AND ReportedUPB = 0
    );

    SET @RowsAffected = @RowsAffected + @@ROWCOUNT;

    -- Step 3: Insert audit trail records
    INSERT INTO LoanUpdateAudit (
        BatchID, UpdateTimestamp, RowsAffected,
        UpdatedBy, UpdateType
    )
    VALUES (
        @BatchID, GETDATE(), @RowsAffected,
        SYSTEM_USER, 'MONTHLY_RECONCILIATION'
    );

    -- Step 4: Validate totals match control file
    DECLARE @UpdatedUPBTotal DECIMAL(18,2);
    SELECT @UpdatedUPBTotal = SUM(CurrentUPB)
    FROM LoanMaster
    WHERE LoanID IN (
        SELECT LoanID FROM ServicerFeed WHERE BatchID = @BatchID
    );

    DECLARE @ExpectedUPBTotal DECIMAL(18,2);
    SELECT @ExpectedUPBTotal = ControlTotalUPB
    FROM BatchControl
    WHERE BatchID = @BatchID;

    -- If totals don't match within tolerance, roll back
    IF ABS(@UpdatedUPBTotal - @ExpectedUPBTotal) > 1000.00
    BEGIN
        RAISERROR('UPB reconciliation failed. Expected: %s, Got: %s',
            16, 1,
            @ExpectedUPBTotal, @UpdatedUPBTotal);
    END

    -- All steps succeeded — make changes permanent
    COMMIT TRANSACTION;

    PRINT 'Batch ' + CAST(@BatchID AS VARCHAR) +
          ' committed successfully. Rows affected: ' +
          CAST(@RowsAffected AS VARCHAR);

END TRY
BEGIN CATCH
    -- Something went wrong — undo ALL changes
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    -- Capture error details
    SET @ErrorMessage = ERROR_MESSAGE();
    SET @ErrorSeverity = ERROR_SEVERITY();

    -- Log the failure
    INSERT INTO BatchErrorLog (
        BatchID, ErrorTimestamp, ErrorMessage,
        ErrorSeverity, ErrorProcedure, ErrorLine
    )
    VALUES (
        @BatchID, GETDATE(), @ErrorMessage,
        @ErrorSeverity, ERROR_PROCEDURE(), ERROR_LINE()
    );

    -- Re-raise the error for the calling application
    RAISERROR(@ErrorMessage, @ErrorSeverity, 1);
END CATCH;
```

Transaction concepts:
- **BEGIN TRANSACTION**: Marks the start of an explicit transaction. All subsequent changes are pending until COMMIT or ROLLBACK.
- **COMMIT TRANSACTION**: Makes all pending changes permanent — once committed, changes survive system crashes.
- **ROLLBACK TRANSACTION**: Undoes all pending changes since BEGIN TRANSACTION — the database returns to its pre-transaction state.
- **@@TRANCOUNT**: Tracks the nesting level of transactions — checked before ROLLBACK to avoid errors when no transaction is active.
- **TRY...CATCH**: SQL Server's structured error handling. If any statement in the TRY block raises an error with severity 11+, control jumps to the CATCH block.
- **ACID properties**: Transactions guarantee Atomicity (all or nothing), Consistency (constraints enforced), Isolation (concurrent transactions don't interfere), and Durability (committed changes persist).

**Result:** The transaction-managed batch update processed 8.2 million loan updates atomically in 4 minutes 18 seconds. During the first month of deployment, the UPB reconciliation check caught a $340 million discrepancy in a corrupted servicer feed, triggering a ROLLBACK that prevented 8.2 million loans from being updated with incorrect data. The error was logged, the servicer resubmitted corrected data, and the reprocessed batch committed successfully. Over 12 months, the transaction safety net prevented 3 data corruption incidents that would have required multi-day recovery efforts.

**AI Vision:** An ML-powered anomaly detection system could analyze the batch data before the transaction begins, comparing current-month values against predicted ranges based on historical trends, flagging suspicious values (e.g., UPB increases on amortizing loans) and potentially preventing errors before they enter the transaction pipeline.

---

### Q26. BETWEEN and IN operators — filtering loans by rate ranges and states

**Situation:** Ginnie Mae's surveillance team needed to identify Government National Mortgage Association (GNMA) pools containing FHA and VA loans with interest rates in the 5.5% to 7.25% range, originated in states with historically high default rates (Florida, Nevada, Arizona, Michigan). This targeted population fed into a quarterly stress-testing model that simulated elevated prepayment and default scenarios for these higher-risk cohorts.

**Task:** Write queries demonstrating BETWEEN for continuous range filtering and IN for discrete value matching against the LoanPerformance table, combining both operators to isolate the target loan population efficiently.

**Action:**
The following queries demonstrated both operators independently and in combination:

```sql
-- BETWEEN for continuous range: interest rates from 5.50% to 7.25%
SELECT
    LoanID,
    PoolID,
    InterestRate,
    CurrentUPB,
    PropertyState,
    LoanProgram
FROM LoanPerformance
WHERE InterestRate BETWEEN 5.50 AND 7.25
    AND ReportingPeriod = '2025-12-01'
    AND Agency = 'GNMA';

-- IN for discrete values: specific high-risk states
SELECT
    LoanID,
    PoolID,
    InterestRate,
    CurrentUPB,
    PropertyState,
    DelinquencyStatus
FROM LoanPerformance
WHERE PropertyState IN ('FL', 'NV', 'AZ', 'MI')
    AND Agency = 'GNMA'
    AND ReportingPeriod = '2025-12-01';

-- Combined: BETWEEN and IN together for precise targeting
SELECT
    LoanID,
    PoolID,
    InterestRate,
    CurrentUPB,
    PropertyState,
    LoanProgram,
    DelinquencyStatus,
    BorrowerCreditScore
FROM LoanPerformance
WHERE InterestRate BETWEEN 5.50 AND 7.25
    AND PropertyState IN ('FL', 'NV', 'AZ', 'MI')
    AND LoanProgram IN ('FHA', 'VA')
    AND Agency = 'GNMA'
    AND ReportingPeriod = '2025-12-01'
ORDER BY PropertyState, InterestRate DESC;
```

Key distinctions:
- **BETWEEN** is inclusive on both ends — `BETWEEN 5.50 AND 7.25` includes both 5.50 and 7.25. Equivalent to `>= 5.50 AND <= 7.25`.
- **IN** replaces multiple OR conditions — `PropertyState IN ('FL', 'NV', 'AZ', 'MI')` is cleaner than four OR clauses.
- **NOT BETWEEN** and **NOT IN** negate the conditions, useful for exclusion-based filtering.
- Both operators leverage indexes effectively when the filtered columns are part of a covering or composite index.

**Result:** The combined query returned 187,400 GNMA loans across 2,340 pools with a total UPB of $42.3 billion. The stress-testing model consumed this population and projected a 14% conditional default rate under adverse scenarios, prompting Ginnie Mae to increase loss reserves by $890 million for the quarter.

**AI Vision:** An intelligent query optimizer could learn from historical query patterns to automatically suggest the most selective filter order, placing the most restrictive condition first (e.g., LoanProgram IN ('FHA','VA') before PropertyState IN (...)) to minimize intermediate result sets and accelerate execution.

---

### Q27. CREATE INDEX basics — adding indexes to speed up loan queries

**Situation:** Freddie Mac's loan-level disclosure database contained 45 million active loan records. Analysts frequently queried by PropertyState, InterestRate, and DelinquencyStatus, but these columns lacked indexes. Report queries that should have completed in seconds were taking 3-5 minutes due to full table scans, creating bottlenecks during the morning reporting window.

**Task:** Create appropriate nonclustered indexes on the most frequently queried columns of the LoanMaster table to bring query response times below 5 seconds without significantly impacting insert/update performance during nightly ETL loads.

**Action:**
The following indexes were created to support the most common query patterns:

```sql
-- Simple nonclustered index on a single column
CREATE NONCLUSTERED INDEX IX_LoanMaster_PropertyState
ON LoanMaster (PropertyState);

-- Composite index for multi-column filter patterns
CREATE NONCLUSTERED INDEX IX_LoanMaster_State_Rate_Delinq
ON LoanMaster (PropertyState, InterestRate, DelinquencyStatus);

-- Index with INCLUDE columns to create a covering index
-- Avoids key lookups for frequently selected columns
CREATE NONCLUSTERED INDEX IX_LoanMaster_Agency_Status
ON LoanMaster (Agency, LoanStatus)
INCLUDE (CurrentUPB, LoanID, OriginationDate);

-- Filtered index for a common subset (active loans only)
CREATE NONCLUSTERED INDEX IX_LoanMaster_Active_Rate
ON LoanMaster (InterestRate)
WHERE LoanStatus = 'ACTIVE';

-- Check existing indexes on a table
EXEC sp_helpindex 'LoanMaster';
```

Key indexing concepts:
- **Nonclustered index**: A separate B-tree structure that stores pointers back to the base table rows. A table can have up to 999 nonclustered indexes.
- **Composite index**: Column order matters — put the most selective (highest cardinality) column first for equality filters, and range-filter columns last.
- **INCLUDE columns**: Added to the leaf level of the index without being part of the key, enabling covering index behavior without increasing key size.
- **Filtered index**: Contains only rows matching a WHERE predicate, resulting in a smaller, faster index for common query subsets.

**Result:** After creating the three targeted indexes, the state-based delinquency query dropped from 4 minutes 12 seconds to 1.8 seconds — a 140x improvement. The covering index on Agency/LoanStatus eliminated 100% of key lookups for the daily portfolio summary report. Nightly ETL insert times increased by only 8% (acceptable trade-off), and overall index storage added 12 GB across the three indexes.

**AI Vision:** An AI-driven index advisor could continuously monitor query execution plans, correlate slow queries with missing index DMV recommendations, simulate the impact of proposed indexes on both read and write workloads, and automatically create or drop indexes during maintenance windows based on evolving query patterns.

---

### Q28. ALTER TABLE — adding new columns for regulatory fields

**Situation:** The Consumer Financial Protection Bureau (CFPB) issued a new regulation requiring all mortgage servicers to track and report a Qualified Mortgage (QM) status flag and a Debt-to-Income (DTI) ratio cap category for every loan. Fannie Mae's LoanMaster table, which held 28 million active loans, needed two new columns added without disrupting the 24/7 operational queries running against the table.

**Task:** Use ALTER TABLE to add the required regulatory columns with appropriate data types, constraints, and default values, ensuring zero downtime for concurrent read and write operations on the production LoanMaster table.

**Action:**
The following ALTER TABLE statements were executed to add the new regulatory columns:

```sql
-- Add a QM status flag with a default value
ALTER TABLE LoanMaster
ADD QMStatus VARCHAR(20) NOT NULL
    CONSTRAINT DF_LoanMaster_QMStatus DEFAULT 'PENDING_REVIEW';

-- Add a DTI cap category column (nullable initially for backfill)
ALTER TABLE LoanMaster
ADD DTICapCategory VARCHAR(15) NULL;

-- Add a regulatory effective date column
ALTER TABLE LoanMaster
ADD RegulatoryEffectiveDate DATE NULL;

-- Modify an existing column (widen a field for longer descriptions)
ALTER TABLE LoanMaster
ALTER COLUMN ServicerName VARCHAR(200);

-- Add a computed column for combined regulatory flag
ALTER TABLE LoanMaster
ADD IsQMCompliant AS CASE
    WHEN QMStatus = 'QUALIFIED' AND DTICapCategory IN ('STANDARD', 'SEASONED')
    THEN 1 ELSE 0
END;

-- Rename a column using sp_rename
EXEC sp_rename 'LoanMaster.OldFieldName', 'NewFieldName', 'COLUMN';

-- Drop a column that is no longer needed
ALTER TABLE LoanMaster
DROP COLUMN ObsoleteField;
```

Key ALTER TABLE considerations:
- **Adding NOT NULL columns** requires a DEFAULT constraint — SQL Server applies the default to all existing rows as a metadata-only operation (in Enterprise Edition with runtime default).
- **Adding NULL columns** is a metadata-only operation and completes instantly regardless of table size.
- **ALTER COLUMN** can change data type, nullability, or length — but narrowing a column's type may fail if existing data doesn't fit.
- **Computed columns** are virtual by default (calculated at query time) and don't consume storage unless marked PERSISTED.

**Result:** The two regulatory columns were added to the 28-million-row LoanMaster table in under 3 seconds (metadata-only operations). A subsequent backfill UPDATE populated QMStatus for 28 million rows in 6 minutes using batched updates of 500,000 rows each. The new columns enabled Fannie Mae to generate CFPB-compliant extracts starting the following reporting cycle, meeting the 90-day regulatory implementation deadline with 3 weeks to spare.

**AI Vision:** An AI-powered schema evolution system could analyze incoming regulatory requirements, automatically propose the optimal data types and constraints for new columns, predict the impact on downstream ETL pipelines and reports, and generate migration scripts with rollback plans — reducing the manual effort of regulatory schema changes from days to minutes.

---

### Q29. DROP TABLE safely with IF EXISTS — cleanup of staging tables

**Situation:** CoreLogic's nightly ETL pipeline created dozens of temporary staging tables each run — staging tables for property valuations, loan acquisitions, and borrower data feeds. If the pipeline failed mid-run and was restarted, the DROP TABLE statements at the beginning of the pipeline would fail with "Cannot drop the table because it does not exist" errors, halting the entire restart sequence and requiring manual intervention.

**Task:** Implement safe DROP TABLE patterns using IF EXISTS to ensure the ETL pipeline's cleanup phase runs without errors regardless of whether staging tables exist from a previous failed run or have already been dropped.

**Action:**
The following patterns were implemented for safe table cleanup:

```sql
-- Modern syntax (SQL Server 2016+): DROP IF EXISTS
DROP TABLE IF EXISTS staging.PropertyValuations;
DROP TABLE IF EXISTS staging.LoanAcquisitions;
DROP TABLE IF EXISTS staging.BorrowerDataFeed;

-- Pre-2016 pattern using OBJECT_ID check
IF OBJECT_ID('staging.MonthlyPaymentFeed', 'U') IS NOT NULL
    DROP TABLE staging.MonthlyPaymentFeed;

-- Drop multiple staging tables in a cleanup block
DROP TABLE IF EXISTS staging.IntexDealData;
DROP TABLE IF EXISTS staging.IntexCashflows;
DROP TABLE IF EXISTS staging.IntexCollateral;
DROP TABLE IF EXISTS staging.IntexTrancheSummary;

-- Full ETL pattern: drop, recreate, load
DROP TABLE IF EXISTS staging.CoreLogicHPI;

CREATE TABLE staging.CoreLogicHPI (
    CBSA_Code       VARCHAR(10),
    StateFIPS       VARCHAR(2),
    CountyFIPS      VARCHAR(3),
    ReportMonth     DATE,
    HPIValue        DECIMAL(10,2),
    MonthOverMonth  DECIMAL(8,4),
    YearOverYear    DECIMAL(8,4),
    LoadTimestamp   DATETIME2 DEFAULT GETDATE()
);

-- Load fresh data from source file
BULK INSERT staging.CoreLogicHPI
FROM '\\fileserver\feeds\corelogic\hpi_202512.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FIRSTROW = 2
);
```

Key concepts:
- **DROP TABLE IF EXISTS** (SQL Server 2016+): A single atomic statement that silently succeeds whether the table exists or not — no error, no warning.
- **OBJECT_ID check**: The pre-2016 equivalent. `OBJECT_ID('schema.table', 'U')` returns NULL if the table does not exist ('U' = user table).
- **Staging table lifecycle**: In ETL pipelines, staging tables are typically dropped at the start of each run, recreated with the current schema, loaded with fresh data, then consumed by merge/upsert operations into permanent tables.
- **Schema separation**: Placing staging tables in a dedicated `staging` schema aids in security, cleanup scripts, and organizational clarity.

**Result:** After implementing IF EXISTS patterns across all 34 staging table operations, ETL pipeline restarts after failures became fully automated — zero manual intervention required. Over 6 months, this prevented 47 manual restart incidents that previously required an on-call DBA to clean up orphaned tables. Average pipeline recovery time dropped from 45 minutes (manual) to 2 minutes (automatic restart).

**AI Vision:** An intelligent ETL orchestrator could track staging table lineage, automatically identify orphaned staging tables from failed pipeline runs, determine which tables are safe to drop based on dependency analysis, and proactively clean up resources before the next scheduled run.

---

### Q30. TRUNCATE vs DELETE — clearing monthly staging data

**Situation:** Freddie Mac's data warehouse used a staging area that was loaded with 15 million loan records every month from servicer feeds. At the start of each monthly cycle, all staging tables needed to be emptied before loading the new month's data. The operations team had been using DELETE statements, but the process was taking 25 minutes and generating massive transaction log growth that occasionally filled the log drive.

**Task:** Replace DELETE with TRUNCATE TABLE for staging table cleanup where appropriate, and document the scenarios where DELETE is still necessary, to reduce cleanup time and transaction log impact.

**Action:**
The following comparison and implementation was performed:

```sql
-- SLOW: DELETE generates a log entry for every row
-- Takes 25 minutes for 15 million rows, log grows by 18 GB
DELETE FROM staging.ServicerLoanFeed;
-- @@ROWCOUNT returns 15,000,000

-- FAST: TRUNCATE deallocates pages, minimal logging
-- Takes 2 seconds for 15 million rows, log grows by 8 KB
TRUNCATE TABLE staging.ServicerLoanFeed;
-- @@ROWCOUNT always returns 0 (pages deallocated, not row-by-row)

-- DELETE is required when you need a WHERE clause
-- Keep current month, delete older months
DELETE FROM staging.LoanPaymentHistory
WHERE ReportingMonth < '2025-12-01';

-- DELETE fires triggers; TRUNCATE does not
-- Use DELETE when audit triggers must capture deletions
DELETE FROM LoanMaster
WHERE LoanStatus = 'TERMINATED'
    AND TerminationDate < DATEADD(YEAR, -7, GETDATE());

-- TRUNCATE resets IDENTITY seed; DELETE does not
-- After TRUNCATE, next IDENTITY value restarts from seed
CREATE TABLE staging.BatchLog (
    BatchLogID INT IDENTITY(1,1),
    BatchDate DATE,
    RecordCount INT
);
-- After TRUNCATE, next insert gets BatchLogID = 1
TRUNCATE TABLE staging.BatchLog;

-- Full monthly cleanup script
TRUNCATE TABLE staging.ServicerLoanFeed;
TRUNCATE TABLE staging.PropertyValuations;
TRUNCATE TABLE staging.BorrowerCreditScores;
TRUNCATE TABLE staging.DelinquencyUpdates;
PRINT 'All staging tables truncated for new monthly load.';
```

Key differences between TRUNCATE and DELETE:
- **Logging**: DELETE logs each row individually (fully logged). TRUNCATE logs only page deallocations (minimally logged).
- **Speed**: TRUNCATE is dramatically faster for large tables — O(1) vs O(n).
- **WHERE clause**: DELETE supports WHERE; TRUNCATE removes ALL rows unconditionally.
- **Triggers**: DELETE fires DELETE triggers; TRUNCATE does not fire any triggers.
- **IDENTITY**: TRUNCATE resets the IDENTITY counter to the seed; DELETE preserves the current counter.
- **Permissions**: TRUNCATE requires ALTER TABLE permission; DELETE requires DELETE permission.
- **Rollback**: Both can be rolled back within an explicit transaction.

**Result:** Replacing DELETE with TRUNCATE for the four main staging tables reduced the monthly cleanup phase from 25 minutes to 8 seconds — a 187x improvement. Transaction log growth during cleanup dropped from 18 GB to 32 KB, completely eliminating the log-full incidents that had caused 3 pipeline failures in the previous quarter. The DBA team reclaimed 45 minutes of the nightly maintenance window for other operations.

**AI Vision:** A smart storage optimizer could analyze table usage patterns and automatically recommend TRUNCATE vs DELETE based on whether the operation targets all rows or a subset, whether triggers exist on the table, and whether downstream processes depend on IDENTITY continuity — presenting a risk assessment before execution.

---

### Q31. Database creation and filegroups — setting up a mortgage database

**Situation:** Fannie Mae's data engineering team was building a new SQL Server data warehouse dedicated to mortgage-backed securities (MBS) analytics. The database needed to store 500+ million loan records, historical cashflow data, and deal-level Intex model outputs. Proper filegroup design was critical to distribute I/O across multiple storage arrays and enable partial backup/restore of the most volatile data.

**Task:** Create a new SQL Server database with multiple filegroups to separate loan data, cashflow data, and indexes onto different storage volumes, enabling optimized I/O performance and granular backup strategies.

**Action:**
The following database creation script was implemented:

```sql
-- Create the database with PRIMARY and additional filegroups
CREATE DATABASE MBS_Analytics
ON PRIMARY (
    NAME = 'MBS_Primary',
    FILENAME = 'D:\SQLData\MBS_Analytics.mdf',
    SIZE = 10GB,
    MAXSIZE = 50GB,
    FILEGROWTH = 1GB
),
FILEGROUP FG_LoanData (
    NAME = 'MBS_LoanData',
    FILENAME = 'E:\SQLData\MBS_LoanData.ndf',
    SIZE = 100GB,
    MAXSIZE = 500GB,
    FILEGROWTH = 10GB
),
FILEGROUP FG_Cashflows (
    NAME = 'MBS_Cashflows',
    FILENAME = 'F:\SQLData\MBS_Cashflows.ndf',
    SIZE = 200GB,
    MAXSIZE = 1TB,
    FILEGROWTH = 20GB
),
FILEGROUP FG_Indexes (
    NAME = 'MBS_Indexes',
    FILENAME = 'G:\SQLData\MBS_Indexes.ndf',
    SIZE = 50GB,
    MAXSIZE = 200GB,
    FILEGROWTH = 5GB
)
LOG ON (
    NAME = 'MBS_Log',
    FILENAME = 'H:\SQLLogs\MBS_Analytics.ldf',
    SIZE = 20GB,
    MAXSIZE = 100GB,
    FILEGROWTH = 5GB
);

-- Set the default filegroup for new tables
ALTER DATABASE MBS_Analytics
MODIFY FILEGROUP FG_LoanData DEFAULT;

-- Set recovery model to SIMPLE for a data warehouse
ALTER DATABASE MBS_Analytics
SET RECOVERY SIMPLE;

-- Create a table on a specific filegroup
USE MBS_Analytics;
CREATE TABLE dbo.LoanMaster (
    LoanID BIGINT NOT NULL,
    PoolID VARCHAR(20),
    CurrentUPB DECIMAL(14,2),
    InterestRate DECIMAL(5,3)
) ON FG_LoanData;

-- Create an index on a separate filegroup
CREATE NONCLUSTERED INDEX IX_LoanMaster_PoolID
ON dbo.LoanMaster (PoolID)
ON FG_Indexes;
```

Key filegroup concepts:
- **PRIMARY filegroup**: Required, contains system tables and any objects not explicitly assigned to another filegroup.
- **User filegroups**: Distribute I/O by placing data files on separate physical drives.
- **FILEGROWTH**: Defines how much the file expands when full — percentage or fixed size. Fixed sizes prevent unpredictable growth spikes.
- **Recovery model**: SIMPLE truncates the log automatically; FULL supports point-in-time recovery but requires log backups.

**Result:** The multi-filegroup design distributed read I/O across four storage arrays, achieving 2.4 GB/s aggregate throughput compared to 800 MB/s on a single-drive design. The FG_Cashflows filegroup, which held the most volatile data, could be backed up independently in 45 minutes versus 4 hours for a full database backup. The database successfully scaled to 580 million loan records and 2.1 TB total size within the first year.

**AI Vision:** An AI capacity planner could monitor filegroup growth rates, predict when each filegroup will reach its MAXSIZE based on historical data ingestion trends, and proactively recommend adding new data files or expanding limits — preventing out-of-space failures before they impact production ETL loads.

---

### Q32. Schema creation — organizing objects by business domain

**Situation:** Ginnie Mae's enterprise data warehouse had accumulated over 600 tables, 200 stored procedures, and 150 views — all residing in the default `dbo` schema. Developers spent significant time searching for the right objects, naming collisions were frequent, and granting permissions was an all-or-nothing proposition because every object shared the same security boundary.

**Task:** Implement a schema-based organizational strategy to group database objects by business domain (loan servicing, deal analytics, regulatory reporting, and staging), enabling clearer object discovery, reduced naming conflicts, and granular permission management.

**Action:**
The following schema design was implemented:

```sql
-- Create schemas for each business domain
CREATE SCHEMA servicing AUTHORIZATION dbo;
CREATE SCHEMA deals AUTHORIZATION dbo;
CREATE SCHEMA regulatory AUTHORIZATION dbo;
CREATE SCHEMA staging AUTHORIZATION dbo;
CREATE SCHEMA archive AUTHORIZATION dbo;

-- Move existing tables to appropriate schemas
ALTER SCHEMA servicing TRANSFER dbo.LoanMaster;
ALTER SCHEMA servicing TRANSFER dbo.PaymentHistory;
ALTER SCHEMA servicing TRANSFER dbo.DelinquencyTracking;

ALTER SCHEMA deals TRANSFER dbo.PoolSummary;
ALTER SCHEMA deals TRANSFER dbo.IntexDealModel;
ALTER SCHEMA deals TRANSFER dbo.TrancheCashflows;

ALTER SCHEMA regulatory TRANSFER dbo.HMDAExtract;
ALTER SCHEMA regulatory TRANSFER dbo.CFPBReporting;

-- Create new tables directly in schemas
CREATE TABLE staging.ServicerFeedRaw (
    FeedID          INT IDENTITY(1,1),
    LoanNumber      VARCHAR(20),
    RawPayload      NVARCHAR(MAX),
    ReceivedDate    DATETIME2 DEFAULT GETDATE()
);

CREATE TABLE archive.LoanMaster_2024 (
    LoanID          BIGINT,
    CurrentUPB      DECIMAL(14,2),
    InterestRate    DECIMAL(5,3),
    ArchiveDate     DATE DEFAULT GETDATE()
);

-- Grant schema-level permissions
-- Analysts can read servicing and deals data
GRANT SELECT ON SCHEMA::servicing TO AnalystRole;
GRANT SELECT ON SCHEMA::deals TO AnalystRole;

-- ETL service account has full control on staging
GRANT CONTROL ON SCHEMA::staging TO ETLServiceAccount;

-- Regulatory team gets exclusive access to regulatory schema
GRANT SELECT, INSERT, UPDATE ON SCHEMA::regulatory TO RegulatoryTeam;

-- Query objects by schema
SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    TABLE_TYPE
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'servicing'
ORDER BY TABLE_NAME;
```

Key schema concepts:
- **Schema as namespace**: Schemas prevent naming collisions — `servicing.LoanMaster` and `archive.LoanMaster` can coexist.
- **Schema as security boundary**: Permissions granted at the schema level apply to all objects within, simplifying access management.
- **ALTER SCHEMA TRANSFER**: Moves objects between schemas — a metadata-only operation that completes instantly.
- **Default schema**: Each database user has a default schema. Unqualified object references resolve to the user's default schema first, then dbo.

**Result:** After reorganizing 600+ objects into 5 schemas, developer onboarding time decreased by 60% — new team members could locate relevant objects by schema name rather than deciphering naming conventions. Permission management was simplified from 600+ individual GRANT statements to 15 schema-level grants. Two naming collisions between servicing and deals objects were resolved naturally through schema separation.

**AI Vision:** A schema recommendation engine could analyze query logs, object dependencies, and user access patterns to automatically suggest optimal schema groupings, identify misplaced objects that are queried alongside objects in a different schema, and propose reorganization plans with impact assessments.

---

### Q33. Basic backup and restore concepts — protecting loan data

**Situation:** Freddie Mac's loan data warehouse contained $2.8 trillion in mortgage portfolio data that was updated nightly by ETL processes. A failed storage controller caused data file corruption, and the recovery process revealed that backups had not been verified in months. Management mandated a documented backup strategy with regular restore testing to ensure recoverability of the mission-critical loan data.

**Task:** Implement a backup strategy for the MortgageDB database including full, differential, and transaction log backups, and demonstrate a restore sequence to recover the database to a specific point in time.

**Action:**
The following backup and restore scripts were implemented:

```sql
-- Full backup: complete copy of the database
-- Run weekly on Sunday at 2:00 AM
BACKUP DATABASE MortgageDB
TO DISK = 'D:\Backups\MortgageDB_FULL_20251207.bak'
WITH
    COMPRESSION,
    CHECKSUM,
    STATS = 10,
    NAME = 'MortgageDB Full Backup',
    DESCRIPTION = 'Weekly full backup - Sunday';

-- Differential backup: changes since last full backup
-- Run nightly Monday-Saturday at 2:00 AM
BACKUP DATABASE MortgageDB
TO DISK = 'D:\Backups\MortgageDB_DIFF_20251210.bak'
WITH
    DIFFERENTIAL,
    COMPRESSION,
    CHECKSUM,
    STATS = 10;

-- Transaction log backup: changes since last log backup
-- Run every 15 minutes during business hours
BACKUP LOG MortgageDB
TO DISK = 'D:\Backups\MortgageDB_LOG_20251210_0915.trn'
WITH
    COMPRESSION,
    CHECKSUM,
    STATS = 10;

-- Verify backup integrity
RESTORE VERIFYONLY
FROM DISK = 'D:\Backups\MortgageDB_FULL_20251207.bak'
WITH CHECKSUM;

-- Restore sequence: Full -> Differential -> Log(s)
-- Step 1: Restore full backup with NORECOVERY
RESTORE DATABASE MortgageDB
FROM DISK = 'D:\Backups\MortgageDB_FULL_20251207.bak'
WITH NORECOVERY, REPLACE;

-- Step 2: Restore most recent differential with NORECOVERY
RESTORE DATABASE MortgageDB
FROM DISK = 'D:\Backups\MortgageDB_DIFF_20251210.bak'
WITH NORECOVERY;

-- Step 3: Restore log backups in sequence with NORECOVERY
RESTORE LOG MortgageDB
FROM DISK = 'D:\Backups\MortgageDB_LOG_20251210_0900.trn'
WITH NORECOVERY;

-- Step 4: Final log restore with RECOVERY to bring database online
RESTORE LOG MortgageDB
FROM DISK = 'D:\Backups\MortgageDB_LOG_20251210_0915.trn'
WITH RECOVERY;
```

Key backup concepts:
- **Full backup**: Complete copy of all data. Serves as the base for differential and log restore chains.
- **Differential backup**: Contains only pages changed since the last full backup. Grows larger each day until the next full backup.
- **Transaction log backup**: Captures all log records since the previous log backup. Required for point-in-time recovery and also truncates the inactive portion of the log.
- **NORECOVERY**: Leaves the database in a restoring state so additional backups can be applied. RECOVERY brings it online.
- **CHECKSUM**: Validates page integrity during backup and restore operations.

**Result:** The new backup strategy achieved a Recovery Point Objective (RPO) of 15 minutes (maximum data loss) and a Recovery Time Objective (RTO) of 45 minutes (time to restore). Quarterly restore testing confirmed the backups were valid, and when a disk failure occurred 4 months later, the database was fully recovered in 38 minutes with zero data loss — the 15-minute log backup interval captured all transactions up to the point of failure.

**AI Vision:** An AI-driven backup manager could predict storage growth to optimize backup schedules, automatically adjust log backup frequency based on transaction volume patterns, detect backup chain gaps before they become critical, and simulate restore scenarios to continuously validate RTO/RPO targets.

---

### Q34. CHECK constraints — validating loan data ranges (LTV 0-200, rate > 0)

**Situation:** Fannie Mae's loan acquisition system received data feeds from 1,200 mortgage originators. Despite upstream validation, malformed records occasionally entered the database — loans with negative interest rates, LTV ratios exceeding 200%, or UPB values of zero. These invalid records caused downstream analytics to produce incorrect risk metrics, triggering a regulatory audit finding.

**Task:** Implement CHECK constraints on the LoanMaster table to enforce valid data ranges at the database level, creating a last line of defense that prevents invalid mortgage data from being stored regardless of the source application.

**Action:**
The following CHECK constraints were added to enforce business rules:

```sql
-- Interest rate must be positive and reasonable (0.01% to 15%)
ALTER TABLE LoanMaster
ADD CONSTRAINT CK_LoanMaster_InterestRate
CHECK (InterestRate > 0 AND InterestRate <= 15.0);

-- LTV ratio must be between 0 and 200 (inclusive)
ALTER TABLE LoanMaster
ADD CONSTRAINT CK_LoanMaster_LTV
CHECK (LTV >= 0 AND LTV <= 200);

-- Current UPB must be non-negative
ALTER TABLE LoanMaster
ADD CONSTRAINT CK_LoanMaster_CurrentUPB
CHECK (CurrentUPB >= 0);

-- Original UPB must be positive (at least $1,000)
ALTER TABLE LoanMaster
ADD CONSTRAINT CK_LoanMaster_OriginalUPB
CHECK (OriginalUPB >= 1000);

-- Credit score must be in valid FICO range (300-850) or NULL
ALTER TABLE LoanMaster
ADD CONSTRAINT CK_LoanMaster_CreditScore
CHECK (BorrowerCreditScore BETWEEN 300 AND 850
       OR BorrowerCreditScore IS NULL);

-- Loan term must be one of the standard terms
ALTER TABLE LoanMaster
ADD CONSTRAINT CK_LoanMaster_LoanTerm
CHECK (OriginalLoanTerm IN (60, 120, 180, 240, 360));

-- Property state must be a 2-character code
ALTER TABLE LoanMaster
ADD CONSTRAINT CK_LoanMaster_PropertyState
CHECK (LEN(PropertyState) = 2);

-- Test the constraint: this INSERT will fail
BEGIN TRY
    INSERT INTO LoanMaster (LoanID, InterestRate, LTV, CurrentUPB)
    VALUES (999999, -1.5, 250, 0);
END TRY
BEGIN CATCH
    PRINT 'CHECK constraint violation: ' + ERROR_MESSAGE();
END CATCH;
```

Key CHECK constraint concepts:
- **Declarative validation**: CHECK constraints enforce rules without application code — every INSERT and UPDATE is validated automatically.
- **NULL handling**: CHECK constraints evaluate to TRUE when the expression involves NULL (three-valued logic). Use `IS NOT NULL` explicitly if NULLs should be rejected.
- **Adding to existing data**: By default, ALTER TABLE...ADD CONSTRAINT validates existing rows. Use `WITH NOCHECK` to skip validation of existing data (not recommended).
- **Performance**: CHECK constraints add negligible overhead to INSERT/UPDATE operations since they are evaluated row-by-row.

**Result:** Within the first month after deploying CHECK constraints, 1,247 invalid records were rejected at insert time — records that would have previously entered the database and corrupted downstream analytics. The constraint violation errors were logged and traced to two originators with faulty data export configurations. After those originators fixed their systems, the rejection rate dropped to near zero. The next regulatory audit found zero data quality findings.

**AI Vision:** An AI data quality engine could analyze historical constraint violations to identify patterns — such as specific originators, time periods, or data fields that produce the most errors — and proactively flag incoming feeds for review before they hit the database, shifting from reactive rejection to predictive quality assurance.

---

### Q35. DEFAULT constraints — setting default values for loan status

**Situation:** Ginnie Mae's loan onboarding system inserted new loan records from multiple intake channels — bulk file uploads, API feeds, and manual entry. Not all channels provided every field; for example, the bulk upload rarely included LoanStatus, ReviewFlag, or LoadTimestamp. Without default values, these columns were stored as NULL, causing downstream reports to miscount active loans and creating confusion about when records were loaded.

**Task:** Add DEFAULT constraints to the LoanMaster table so that commonly omitted columns receive meaningful default values at insert time, ensuring data completeness without requiring every intake channel to supply every field.

**Action:**
The following DEFAULT constraints were implemented:

```sql
-- Default loan status to 'CURRENT' for new acquisitions
ALTER TABLE LoanMaster
ADD CONSTRAINT DF_LoanMaster_LoanStatus
DEFAULT 'CURRENT' FOR LoanStatus;

-- Default review flag to 'N' (not yet reviewed)
ALTER TABLE LoanMaster
ADD CONSTRAINT DF_LoanMaster_ReviewFlag
DEFAULT 'N' FOR ReviewFlag;

-- Default load timestamp to current date/time
ALTER TABLE LoanMaster
ADD CONSTRAINT DF_LoanMaster_LoadTimestamp
DEFAULT GETDATE() FOR LoadTimestamp;

-- Default reporting period to first of current month
ALTER TABLE LoanMaster
ADD CONSTRAINT DF_LoanMaster_ReportingPeriod
DEFAULT DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)
FOR ReportingPeriod;

-- Default agency to 'GNMA' since this is a Ginnie Mae database
ALTER TABLE LoanMaster
ADD CONSTRAINT DF_LoanMaster_Agency
DEFAULT 'GNMA' FOR Agency;

-- Default data source to 'BULK_UPLOAD'
ALTER TABLE LoanMaster
ADD CONSTRAINT DF_LoanMaster_DataSource
DEFAULT 'BULK_UPLOAD' FOR DataSource;

-- Insert without specifying defaulted columns — defaults apply
INSERT INTO LoanMaster (LoanID, CurrentUPB, InterestRate, PropertyState)
VALUES (12345678, 250000.00, 5.75, 'TX');
-- LoanStatus='CURRENT', ReviewFlag='N', LoadTimestamp=GETDATE(), etc.

-- Explicit values override defaults
INSERT INTO LoanMaster (LoanID, CurrentUPB, InterestRate, PropertyState, LoanStatus)
VALUES (12345679, 180000.00, 6.25, 'FL', 'DELINQUENT_30');
-- LoanStatus='DELINQUENT_30' (explicit), ReviewFlag='N' (default)

-- View default constraints on a table
SELECT
    dc.name AS ConstraintName,
    c.name AS ColumnName,
    dc.definition AS DefaultValue
FROM sys.default_constraints dc
INNER JOIN sys.columns c
    ON dc.parent_object_id = c.object_id
    AND dc.parent_column_id = c.column_id
WHERE dc.parent_object_id = OBJECT_ID('LoanMaster');
```

Key DEFAULT constraint concepts:
- **Automatic population**: DEFAULT values are applied when an INSERT statement omits the column or explicitly inserts DEFAULT.
- **Expressions allowed**: Defaults can be constants, built-in functions (GETDATE(), NEWID()), or expressions — but not subqueries.
- **Named constraints**: Always name constraints explicitly (DF_Table_Column) for easier maintenance and scripting.
- **Override behavior**: An explicit value in the INSERT always takes precedence over the default, including explicit NULL.

**Result:** After implementing defaults across 6 key columns, the percentage of NULL values in LoanStatus dropped from 12% to 0%. Downstream reports that counted active loans saw a 12% increase in accuracy as previously NULL-status loans were now correctly categorized as CURRENT. The three intake channels continued operating without code changes, and the audit team confirmed that all 14,000 monthly new acquisitions carried complete metadata.

**AI Vision:** An intelligent default system could learn from historical insert patterns to suggest context-aware defaults — for example, if loans from a specific originator are predominantly VA loans, the system could default LoanProgram to 'VA' for that originator's feed, reducing manual corrections by 85%.

---

### Q36. UNIQUE constraints — enforcing unique CUSIP identifiers

**Situation:** Freddie Mac's securities database tracked mortgage-backed securities using CUSIP identifiers — 9-character codes that uniquely identify each security in the financial markets. A data quality audit discovered 23 cases where duplicate CUSIPs had been inserted, causing trade settlement failures and incorrect position reporting. The root cause was that multiple ETL processes loaded deal data concurrently without uniqueness enforcement.

**Task:** Add UNIQUE constraints to prevent duplicate CUSIP identifiers in the SecurityMaster table and the DealTranche table, ensuring that each security has exactly one record regardless of how many concurrent processes attempt to insert data.

**Action:**
The following UNIQUE constraints were implemented:

```sql
-- Add UNIQUE constraint on CUSIP in SecurityMaster
ALTER TABLE SecurityMaster
ADD CONSTRAINT UQ_SecurityMaster_CUSIP
UNIQUE (CUSIP);

-- Composite UNIQUE constraint: DealID + TrancheID must be unique
ALTER TABLE DealTranche
ADD CONSTRAINT UQ_DealTranche_Deal_Tranche
UNIQUE (DealID, TrancheID);

-- UNIQUE constraint allowing one NULL (SQL Server allows one NULL)
ALTER TABLE LoanMaster
ADD CONSTRAINT UQ_LoanMaster_SellerLoanNumber
UNIQUE (SellerLoanNumber);

-- Create table with UNIQUE constraint inline
CREATE TABLE deals.IntexDealMapping (
    MappingID       INT IDENTITY(1,1) PRIMARY KEY,
    IntexDealID     VARCHAR(30) NOT NULL,
    AgencyDealID    VARCHAR(20) NOT NULL,
    CUSIP           CHAR(9) NOT NULL,
    EffectiveDate   DATE NOT NULL,
    CONSTRAINT UQ_IntexDealMapping_CUSIP UNIQUE (CUSIP),
    CONSTRAINT UQ_IntexDealMapping_IntexDeal UNIQUE (IntexDealID)
);

-- Test: duplicate CUSIP insertion fails
BEGIN TRY
    INSERT INTO SecurityMaster (CUSIP, SecurityType, IssueDate, OriginalBalance)
    VALUES ('31329XAB3', 'MBS_PASSTHRU', '2025-01-15', 500000000.00);

    -- This will fail — duplicate CUSIP
    INSERT INTO SecurityMaster (CUSIP, SecurityType, IssueDate, OriginalBalance)
    VALUES ('31329XAB3', 'MBS_PASSTHRU', '2025-01-15', 500000000.00);
END TRY
BEGIN CATCH
    PRINT 'Duplicate CUSIP rejected: ' + ERROR_MESSAGE();
END CATCH;

-- Find existing duplicates before adding constraint
SELECT CUSIP, COUNT(*) AS DuplicateCount
FROM SecurityMaster
GROUP BY CUSIP
HAVING COUNT(*) > 1
ORDER BY DuplicateCount DESC;
```

Key UNIQUE constraint concepts:
- **Enforcement**: SQL Server creates a unique nonclustered index behind the scenes to enforce the constraint. This index also improves query performance on the constrained columns.
- **NULL handling**: SQL Server's UNIQUE constraint allows only one NULL value per column (or one NULL combination for composite constraints).
- **vs PRIMARY KEY**: A table can have only one PRIMARY KEY (which is also unique and not null), but can have multiple UNIQUE constraints. UNIQUE columns can allow NULL.
- **Concurrent safety**: UNIQUE constraints prevent race conditions in concurrent INSERT operations — the underlying unique index uses row-level locking to serialize duplicate attempts.

**Result:** After adding the UNIQUE constraint and resolving the 23 existing duplicates, duplicate CUSIP insertions dropped to zero over the next 12 months. Trade settlement failures attributed to duplicate securities decreased from an average of 8 per month to zero. The ETL team implemented MERGE statements with the CUSIP as the match key, and the UNIQUE constraint served as a safety net guaranteeing no duplicates could bypass the application logic.

**AI Vision:** A data integrity monitor could use pattern recognition to detect near-duplicates (CUSIPs differing by one character due to typos) that pass UNIQUE constraint checks but still represent data quality issues, alerting analysts to potential miskeyed securities before they cause settlement errors.

---

### Q37. WHILE loops — processing loan batches

**Situation:** Fannie Mae's monthly data reconciliation required updating credit scores for 22 million active loans from a third-party credit bureau feed. Executing a single UPDATE statement for 22 million rows caused tempdb contention, lock escalation to a table-level lock, and blocked all concurrent queries for 45 minutes. The DBA team mandated that large updates be processed in manageable batches.

**Task:** Implement a WHILE loop to process the credit score update in batches of 100,000 rows, reducing lock contention and allowing concurrent read queries to execute between batches.

**Action:**
The following batched update using a WHILE loop was implemented:

```sql
DECLARE @BatchSize INT = 100000;
DECLARE @RowsUpdated INT = 1;  -- Initialize to enter loop
DECLARE @TotalUpdated INT = 0;
DECLARE @BatchNumber INT = 0;

-- Process in batches until no more rows to update
WHILE @RowsUpdated > 0
BEGIN
    SET @BatchNumber = @BatchNumber + 1;

    UPDATE TOP (@BatchSize) lm
    SET
        lm.BorrowerCreditScore = cb.LatestFICO,
        lm.CreditScoreDate     = cb.ScoreDate,
        lm.LastModifiedDate     = GETDATE()
    FROM LoanMaster lm
    INNER JOIN CreditBureauFeed cb
        ON lm.LoanID = cb.LoanID
    WHERE lm.BorrowerCreditScore <> cb.LatestFICO
        OR lm.BorrowerCreditScore IS NULL;

    SET @RowsUpdated = @@ROWCOUNT;
    SET @TotalUpdated = @TotalUpdated + @RowsUpdated;

    -- Log progress every batch
    PRINT 'Batch ' + CAST(@BatchNumber AS VARCHAR(10)) +
          ': Updated ' + CAST(@RowsUpdated AS VARCHAR(10)) +
          ' rows. Total: ' + CAST(@TotalUpdated AS VARCHAR(10));

    -- Brief pause to allow other queries to acquire locks
    WAITFOR DELAY '00:00:01';
END

PRINT 'Complete. Total rows updated: ' + CAST(@TotalUpdated AS VARCHAR(10));

-- Alternative: WHILE loop with an explicit batch key range
DECLARE @MinLoanID BIGINT, @MaxLoanID BIGINT, @CurrentMin BIGINT;

SELECT @MinLoanID = MIN(LoanID), @MaxLoanID = MAX(LoanID)
FROM LoanMaster WHERE LoanStatus = 'ACTIVE';

SET @CurrentMin = @MinLoanID;

WHILE @CurrentMin <= @MaxLoanID
BEGIN
    UPDATE lm
    SET lm.BorrowerCreditScore = cb.LatestFICO
    FROM LoanMaster lm
    INNER JOIN CreditBureauFeed cb ON lm.LoanID = cb.LoanID
    WHERE lm.LoanID >= @CurrentMin
        AND lm.LoanID < @CurrentMin + @BatchSize;

    SET @CurrentMin = @CurrentMin + @BatchSize;
END
```

Key WHILE loop concepts:
- **Loop condition**: The WHILE block executes as long as the condition evaluates to TRUE. Set `@RowsUpdated = 1` initially to ensure the first iteration runs.
- **TOP (@variable)**: Limits the UPDATE to the specified number of rows per iteration. SQL Server picks any qualifying rows (no guaranteed order without ORDER BY in a subquery).
- **@@ROWCOUNT**: Returns the number of rows affected by the previous statement — the loop exit condition when it returns 0.
- **WAITFOR DELAY**: Optional pause between batches to reduce contention on shared resources.
- **Key-range approach**: The second pattern uses explicit LoanID ranges for deterministic, non-overlapping batches — preferable when resumability after failure is needed.

**Result:** The batched WHILE loop processed 22 million credit score updates in 220 batches over 32 minutes. Lock escalation was eliminated — locks were held only during each 100,000-row batch (approximately 8 seconds per batch). Concurrent read queries experienced zero blocking, with average response times of 200ms during the update process versus 45-minute complete blockage under the old single-statement approach.

**AI Vision:** An adaptive batch processor could dynamically adjust batch sizes based on real-time server metrics — increasing batch size when system load is low and decreasing it when concurrent activity spikes — optimizing throughput while maintaining a configurable maximum blocking threshold.

---

### Q38. @@ROWCOUNT and @@ERROR — checking DML operation results

**Situation:** CoreLogic's ETL pipeline performed a series of INSERT, UPDATE, and DELETE operations to synchronize property valuation data from county assessor feeds. The pipeline had no verification after each DML statement — if an UPDATE affected zero rows due to a missing join key, or if a DELETE encountered an error, the pipeline continued silently, producing incomplete datasets that were not discovered until downstream reports showed missing valuations days later.

**Task:** Add @@ROWCOUNT and @@ERROR checks after every critical DML operation in the ETL pipeline to detect zero-row operations and errors immediately, logging results and halting the pipeline when expected row counts are not met.

**Action:**
The following verification pattern was implemented across the ETL pipeline:

```sql
DECLARE @RowsAffected INT;
DECLARE @ErrorCode INT;
DECLARE @StepName VARCHAR(100);

-- Step 1: Insert new property records
SET @StepName = 'Insert New Properties';

INSERT INTO PropertyValuation (PropertyID, AppraisedValue, AssessmentDate, County)
SELECT
    src.PropertyID,
    src.AppraisedValue,
    src.AssessmentDate,
    src.County
FROM staging.CountyAssessorFeed src
LEFT JOIN PropertyValuation pv ON src.PropertyID = pv.PropertyID
WHERE pv.PropertyID IS NULL;

-- Capture immediately — @@ROWCOUNT resets after ANY statement
SET @RowsAffected = @@ROWCOUNT;
SET @ErrorCode = @@ERROR;

-- Validate results
IF @ErrorCode <> 0
BEGIN
    RAISERROR('Step [%s] failed with error code %d', 16, 1,
              @StepName, @ErrorCode);
    RETURN;
END

IF @RowsAffected = 0
BEGIN
    PRINT 'WARNING: Step [' + @StepName + '] affected 0 rows.';
END

-- Log the operation result
INSERT INTO ETLOperationLog (StepName, RowsAffected, ErrorCode, ExecutedAt)
VALUES (@StepName, @RowsAffected, @ErrorCode, GETDATE());

-- Step 2: Update existing property valuations
SET @StepName = 'Update Existing Valuations';

UPDATE pv
SET
    pv.AppraisedValue  = src.AppraisedValue,
    pv.AssessmentDate  = src.AssessmentDate,
    pv.LastModifiedDate = GETDATE()
FROM PropertyValuation pv
INNER JOIN staging.CountyAssessorFeed src
    ON pv.PropertyID = src.PropertyID
WHERE pv.AppraisedValue <> src.AppraisedValue;

SET @RowsAffected = @@ROWCOUNT;
SET @ErrorCode = @@ERROR;

IF @ErrorCode <> 0
BEGIN
    RAISERROR('Step [%s] failed with error code %d', 16, 1,
              @StepName, @ErrorCode);
    RETURN;
END

INSERT INTO ETLOperationLog (StepName, RowsAffected, ErrorCode, ExecutedAt)
VALUES (@StepName, @RowsAffected, @ErrorCode, GETDATE());

PRINT 'Step [' + @StepName + ']: ' +
      CAST(@RowsAffected AS VARCHAR) + ' rows updated.';
```

Key concepts:
- **@@ROWCOUNT**: Returns the number of rows affected by the last statement. Must be captured immediately — even a SET or IF statement resets it.
- **@@ERROR**: Returns the error number of the last statement (0 = success). Also resets after every statement, so capture it alongside @@ROWCOUNT.
- **Capture pattern**: Always use `SET @Var = @@ROWCOUNT` as the very first statement after the DML — before any IF, PRINT, or other statement.
- **Modern alternative**: TRY...CATCH with ERROR_MESSAGE() is preferred for new code, but @@ROWCOUNT remains essential for row-count verification since TRY...CATCH only catches errors, not zero-row conditions.

**Result:** Within the first week of deploying @@ROWCOUNT checks, the pipeline detected 3 zero-row UPDATE operations caused by a schema change in the county assessor feed that altered the join key format. The immediate detection allowed the data engineering team to fix the key mapping within 2 hours, versus the previous 3-day discovery cycle. Over 6 months, the verification logic caught 12 anomalies — 8 zero-row operations and 4 error conditions — all resolved within the same business day.

**AI Vision:** An ML-based ETL monitor could learn expected row count ranges for each pipeline step based on historical patterns (day of week, month, data source), and automatically flag operations where @@ROWCOUNT deviates significantly from predicted values — catching subtle data loss that raw zero-row checks would miss.

---

### Q39. PRINT and RAISERROR for debugging — troubleshooting ETL

**Situation:** Fannie Mae's nightly ETL pipeline comprised 40+ stored procedures that ran sequentially over 6 hours. When a failure occurred at 3:00 AM, the on-call DBA had only the final error message — no visibility into which step was running, how far the pipeline progressed, or what data conditions led to the failure. Debugging required re-running the pipeline step by step, adding hours to incident resolution.

**Task:** Add structured PRINT and RAISERROR statements throughout the ETL stored procedures to create a runtime execution log that provides step-by-step progress, timing, row counts, and contextual data for rapid debugging of failures.

**Action:**
The following debugging instrumentation was added to the ETL pipeline:

```sql
CREATE OR ALTER PROCEDURE etl.LoadMonthlyLoanData
    @ReportingMonth DATE,
    @DebugMode BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @StepStart DATETIME2;
    DECLARE @Msg NVARCHAR(500);
    DECLARE @RowCnt INT;

    -- PRINT: simple message output (severity 0, informational)
    PRINT '================================================';
    PRINT 'ETL Pipeline: LoadMonthlyLoanData';
    PRINT 'Reporting Month: ' + CONVERT(VARCHAR, @ReportingMonth, 120);
    PRINT 'Start Time: ' + CONVERT(VARCHAR, GETDATE(), 120);
    PRINT '================================================';

    -- Step 1: Validate staging data
    SET @StepStart = GETDATE();
    PRINT 'Step 1: Validating staging data...';

    DECLARE @StagingCount INT;
    SELECT @StagingCount = COUNT(*) FROM staging.ServicerLoanFeed;

    IF @StagingCount = 0
    BEGIN
        -- RAISERROR with severity 16: terminates execution in TRY block
        RAISERROR('FATAL: Staging table is empty. No data to process.', 16, 1);
        RETURN;
    END

    -- RAISERROR with severity 10 (informational, like PRINT but with formatting)
    RAISERROR('Step 1 complete: %d records in staging. Duration: %d ms.',
        10, 1, @StagingCount, DATEDIFF(MILLISECOND, @StepStart, GETDATE()))
    WITH NOWAIT;

    -- Step 2: Load new loans
    SET @StepStart = GETDATE();
    RAISERROR('Step 2: Loading new loans...', 10, 1) WITH NOWAIT;

    INSERT INTO servicing.LoanMaster (LoanID, CurrentUPB, InterestRate)
    SELECT LoanID, CurrentUPB, InterestRate
    FROM staging.ServicerLoanFeed
    WHERE LoanID NOT IN (SELECT LoanID FROM servicing.LoanMaster);

    SET @RowCnt = @@ROWCOUNT;

    SET @Msg = 'Step 2 complete: ' + CAST(@RowCnt AS NVARCHAR) +
               ' new loans inserted. Duration: ' +
               CAST(DATEDIFF(MILLISECOND, @StepStart, GETDATE()) AS NVARCHAR) + ' ms.';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    -- Debug mode: show sample data for verification
    IF @DebugMode = 1
    BEGIN
        PRINT '--- DEBUG: Sample of inserted loans ---';
        SELECT TOP 5 LoanID, CurrentUPB, InterestRate
        FROM servicing.LoanMaster
        ORDER BY LoadTimestamp DESC;
    END

    -- Step 3: Update existing loans
    SET @StepStart = GETDATE();
    RAISERROR('Step 3: Updating existing loan balances...', 10, 1) WITH NOWAIT;

    UPDATE lm
    SET lm.CurrentUPB = sf.CurrentUPB,
        lm.LastModifiedDate = GETDATE()
    FROM servicing.LoanMaster lm
    INNER JOIN staging.ServicerLoanFeed sf ON lm.LoanID = sf.LoanID
    WHERE lm.CurrentUPB <> sf.CurrentUPB;

    SET @RowCnt = @@ROWCOUNT;
    RAISERROR('Step 3 complete: %d loans updated. Duration: %d ms.',
        10, 1, @RowCnt, DATEDIFF(MILLISECOND, @StepStart, GETDATE()))
    WITH NOWAIT;

    PRINT '================================================';
    PRINT 'Pipeline complete: ' + CONVERT(VARCHAR, GETDATE(), 120);
    PRINT '================================================';
END;
```

Key debugging concepts:
- **PRINT**: Outputs messages to the Messages tab. Buffered — may not appear in real time during long-running operations.
- **RAISERROR with severity 10**: Informational message, equivalent to PRINT but supports printf-style formatting (%d, %s) and the WITH NOWAIT option.
- **WITH NOWAIT**: Flushes the message immediately to the client — critical for real-time monitoring of long-running procedures.
- **RAISERROR with severity 11-16**: Generates an error that is caught by TRY...CATCH blocks. Severity 16 = user-defined error.
- **@DebugMode parameter**: A common pattern that enables verbose output during development but runs silently in production.

**Result:** After instrumenting all 40 stored procedures with structured PRINT/RAISERROR output, average incident debugging time dropped from 3.5 hours to 25 minutes. The on-call DBA could immediately identify the failing step, the row counts leading up to the failure, and the elapsed time per step. The @DebugMode flag enabled developers to trace pipeline logic during testing without modifying production code.

**AI Vision:** An AI log analyzer could parse the structured ETL output in real time, correlate step durations with historical baselines, detect anomalous slowdowns before they cause timeouts, and automatically recommend remediation actions based on patterns from previous incidents.

---

### Q40. SET NOCOUNT ON — optimizing stored procedure performance

**Situation:** Freddie Mac's loan servicing application called a stored procedure that performed 15 DML operations (INSERTs, UPDATEs, DELETEs) in sequence to process a single loan payment. Each DML statement generated a "N rows affected" message sent back to the application over the network. The application's ORM framework misinterpreted some of these row-count messages as additional result sets, causing sporadic "expected 1 result set but received 16" errors.

**Task:** Add SET NOCOUNT ON to all stored procedures to suppress the row-count messages, eliminating the spurious result-set errors and reducing network traffic between the application tier and the database server.

**Action:**
The following pattern was implemented across all stored procedures:

```sql
CREATE OR ALTER PROCEDURE servicing.ProcessLoanPayment
    @LoanID BIGINT,
    @PaymentAmount DECIMAL(14,2),
    @PaymentDate DATE
AS
BEGIN
    -- Suppress "N rows affected" messages
    SET NOCOUNT ON;

    DECLARE @CurrentUPB DECIMAL(14,2);
    DECLARE @InterestRate DECIMAL(5,3);
    DECLARE @MonthlyInterest DECIMAL(14,2);
    DECLARE @PrincipalApplied DECIMAL(14,2);

    -- Step 1: Get current loan details
    SELECT @CurrentUPB = CurrentUPB,
           @InterestRate = InterestRate
    FROM servicing.LoanMaster
    WHERE LoanID = @LoanID;

    -- Step 2: Calculate payment allocation
    SET @MonthlyInterest = @CurrentUPB * (@InterestRate / 100.0 / 12.0);
    SET @PrincipalApplied = @PaymentAmount - @MonthlyInterest;

    -- Step 3: Insert payment record (no "1 row affected" sent)
    INSERT INTO servicing.PaymentHistory (
        LoanID, PaymentDate, PaymentAmount,
        InterestPortion, PrincipalPortion
    )
    VALUES (
        @LoanID, @PaymentDate, @PaymentAmount,
        @MonthlyInterest, @PrincipalApplied
    );

    -- Step 4: Update loan balance (no "1 row affected" sent)
    UPDATE servicing.LoanMaster
    SET CurrentUPB = CurrentUPB - @PrincipalApplied,
        LastPaymentDate = @PaymentDate,
        DelinquencyStatus = 0,
        LastModifiedDate = GETDATE()
    WHERE LoanID = @LoanID;

    -- Step 5: Update delinquency tracking (no message sent)
    UPDATE servicing.DelinquencyTracking
    SET MonthsMissed = 0,
        LastPaymentReceived = @PaymentDate
    WHERE LoanID = @LoanID;

    -- Step 6: Log the transaction (no message sent)
    INSERT INTO servicing.TransactionLog (
        LoanID, TransactionType, Amount, TransactionDate
    )
    VALUES (@LoanID, 'PAYMENT', @PaymentAmount, GETDATE());

    -- Only return the one result set the application expects
    SELECT
        @LoanID AS LoanID,
        @CurrentUPB - @PrincipalApplied AS NewBalance,
        @PrincipalApplied AS PrincipalApplied,
        @MonthlyInterest AS InterestApplied,
        'SUCCESS' AS Status;

    -- Optionally re-enable at the end (not required — scope is procedure)
    SET NOCOUNT OFF;
END;
```

Key SET NOCOUNT concepts:
- **Default behavior (OFF)**: Every INSERT, UPDATE, DELETE, and SELECT sends a "N rows affected" message to the client. For a procedure with 15 DML statements, that is 15 extra network round-trips.
- **SET NOCOUNT ON**: Suppresses these messages, reducing network traffic and preventing ORM frameworks from misinterpreting row-count messages as result sets.
- **Scope**: SET NOCOUNT is scoped to the current procedure or batch. It does not affect calling procedures or subsequent batches.
- **@@ROWCOUNT unaffected**: SET NOCOUNT ON does not affect @@ROWCOUNT — you can still capture row counts with @@ROWCOUNT even when messages are suppressed.
- **Best practice**: Include SET NOCOUNT ON as the first statement in every stored procedure.

**Result:** Adding SET NOCOUNT ON to all 85 stored procedures eliminated 100% of the "unexpected result set" errors — from an average of 340 errors per day to zero. Network traffic between the application and database tiers decreased by 18% for payment processing operations. The loan payment processing procedure's average execution time dropped from 12ms to 9ms (25% improvement) due to the eliminated message round-trips.

**AI Vision:** An automated code review system could scan all stored procedures for missing SET NOCOUNT ON statements, flag procedures that generate multiple result sets unintentionally, and suggest optimizations based on the ratio of DML operations to actual result sets returned.

---

### Q41. sp_help and sp_helptext — exploring existing loan database objects

**Situation:** A new data engineer joining Ginnie Mae's analytics team was tasked with modifying an existing stored procedure that generated monthly pool-level performance reports. The database contained hundreds of objects with limited documentation, and the engineer needed to quickly understand the structure of tables involved and the logic of the existing procedure before making changes.

**Task:** Use sp_help and sp_helptext system procedures to explore the database schema, understand table structures, and examine existing stored procedure code — enabling rapid onboarding without relying on external documentation that might be outdated.

**Action:**
The following exploration commands were used to understand the database objects:

```sql
-- sp_help with no parameters: list all objects in the database
EXEC sp_help;

-- sp_help on a table: columns, data types, indexes, constraints
EXEC sp_help 'servicing.LoanMaster';
-- Returns:
--   Column names, data types, nullable, default values
--   Identity column information
--   All indexes (clustered and nonclustered)
--   All constraints (PK, FK, CHECK, DEFAULT, UNIQUE)

-- sp_help on a stored procedure: parameter list
EXEC sp_help 'servicing.GeneratePoolReport';
-- Returns: parameter names, data types, lengths, default values

-- sp_helptext: view the source code of a stored procedure
EXEC sp_helptext 'servicing.GeneratePoolReport';
-- Returns the CREATE PROCEDURE statement line by line

-- sp_helptext works on views too
EXEC sp_helptext 'deals.vw_ActivePoolSummary';

-- sp_helptext on functions
EXEC sp_helptext 'dbo.fn_CalculateWAC';

-- sp_helpindex: view indexes on a table
EXEC sp_helpindex 'servicing.LoanMaster';

-- sp_depends: view object dependencies (deprecated but still useful)
EXEC sp_depends 'servicing.LoanMaster';
-- Shows which procedures, views, and functions reference this table

-- Practical example: exploring before modifying
-- Step 1: What columns does the table have?
EXEC sp_help 'servicing.PoolSummary';

-- Step 2: What does the current procedure do?
EXEC sp_helptext 'servicing.GeneratePoolReport';

-- Step 3: What indexes exist for performance?
EXEC sp_helpindex 'servicing.PoolSummary';

-- Step 4: What other objects depend on this procedure?
EXEC sp_depends 'servicing.GeneratePoolReport';
```

Key system procedure concepts:
- **sp_help**: A multipurpose exploration tool — returns different result sets depending on the object type (table, view, procedure, function).
- **sp_helptext**: Returns the source code (definition) of programmable objects. Returns NULL for encrypted objects (created WITH ENCRYPTION).
- **sp_helpindex**: Specifically designed for index information — more focused than sp_help for index analysis.
- **sp_depends**: Shows dependency chains (what references what). Being replaced by sys.dm_sql_referencing_entities and sys.dm_sql_referenced_entities.
- **Schema qualification**: Always use two-part names (schema.object) to avoid ambiguity.

**Result:** Using the sp_help family of procedures, the new engineer mapped out the 12-table schema used by the pool report procedure, identified 3 missing indexes that explained performance complaints, and understood the existing procedure logic — all within 2 hours. The subsequent modification to add a new reporting metric was completed in half the estimated time because the engineer had a thorough understanding of the data model and existing logic before writing any code.

**AI Vision:** An AI-powered database documentation generator could continuously run sp_help and sp_helptext across all objects, compare results against previous snapshots to detect schema drift, and automatically maintain a living data dictionary with ERD diagrams — making onboarding instantaneous and eliminating stale documentation.

---

### Q42. System catalog views — querying metadata about loan tables

**Situation:** Fannie Mae's data governance team needed to audit the MBS_Analytics database to catalog all tables, their column counts, row counts, data types used, and storage consumption. Manual inspection of 400+ tables using SSMS was impractical, and the team needed a repeatable, queryable approach to metadata collection for their annual data governance certification.

**Task:** Query SQL Server's system catalog views (sys.tables, sys.columns, sys.indexes, sys.dm_db_partition_stats) to programmatically extract comprehensive metadata about all loan-related tables in the database.

**Action:**
The following metadata queries were developed:

```sql
-- List all tables with row counts and storage size
SELECT
    s.name AS SchemaName,
    t.name AS TableName,
    p.rows AS RowCount,
    SUM(a.total_pages) * 8 / 1024 AS TotalSizeMB,
    SUM(a.used_pages) * 8 / 1024 AS UsedSizeMB,
    t.create_date AS CreatedDate,
    t.modify_date AS LastModifiedDate
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
INNER JOIN sys.indexes i ON t.object_id = i.object_id
INNER JOIN sys.partitions p ON i.object_id = p.object_id
    AND i.index_id = p.index_id
INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE i.index_id <= 1  -- Clustered index or heap
GROUP BY s.name, t.name, p.rows, t.create_date, t.modify_date
ORDER BY p.rows DESC;

-- List all columns with data types for a specific table
SELECT
    c.column_id AS Position,
    c.name AS ColumnName,
    ty.name AS DataType,
    c.max_length AS MaxLength,
    c.precision AS Precision,
    c.scale AS Scale,
    c.is_nullable AS IsNullable,
    dc.definition AS DefaultValue,
    c.is_identity AS IsIdentity
FROM sys.columns c
INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
LEFT JOIN sys.default_constraints dc
    ON c.default_object_id = dc.object_id
WHERE c.object_id = OBJECT_ID('servicing.LoanMaster')
ORDER BY c.column_id;

-- Find all tables that have a LoanID column
SELECT
    s.name + '.' + t.name AS FullTableName,
    c.name AS ColumnName,
    ty.name AS DataType
FROM sys.columns c
INNER JOIN sys.tables t ON c.object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
WHERE c.name = 'LoanID'
ORDER BY s.name, t.name;

-- Count of tables per schema
SELECT
    s.name AS SchemaName,
    COUNT(*) AS TableCount
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
GROUP BY s.name
ORDER BY TableCount DESC;

-- Find all constraints on a table
SELECT
    o.name AS ConstraintName,
    o.type_desc AS ConstraintType,
    OBJECT_NAME(o.parent_object_id) AS TableName
FROM sys.objects o
WHERE o.parent_object_id = OBJECT_ID('servicing.LoanMaster')
    AND o.type IN ('PK', 'UQ', 'C', 'D', 'F')
ORDER BY o.type_desc;
```

Key system catalog views:
- **sys.tables**: One row per user table. Contains creation date, modification date, and object_id.
- **sys.columns**: One row per column across all tables. Joins to sys.types for data type information.
- **sys.indexes**: One row per index. index_id 0 = heap, 1 = clustered, 2+ = nonclustered.
- **sys.partitions**: Row counts per index per partition.
- **sys.allocation_units**: Storage allocation details — total_pages and used_pages for size calculations.
- **INFORMATION_SCHEMA views**: ANSI-standard alternative (TABLES, COLUMNS, etc.) that is portable across database platforms.

**Result:** The metadata queries cataloged 412 tables across 5 schemas, identified 3,847 columns, and calculated total storage of 2.4 TB. The audit revealed 23 tables with zero rows (candidates for cleanup), 15 columns with deprecated data types (TEXT instead of VARCHAR(MAX)), and 8 tables missing primary keys. The governance team used the output to generate their annual data certification report in 2 hours instead of the previous 3-week manual effort.

**AI Vision:** An AI metadata analyzer could continuously profile the database catalog, detect schema anomalies (unused tables, inconsistent naming, missing constraints), track schema evolution over time, and generate impact assessments when DDL changes are proposed — serving as an intelligent data steward.

---

### Q43. CROSS JOIN — generating all loan-month combinations for reporting

**Situation:** Freddie Mac's regulatory reporting team needed to produce a complete time-series grid showing every active pool's performance for every month in a 24-month reporting window — even months where a pool had no activity. A standard INNER JOIN between pool data and monthly performance data produced gaps (missing rows) for months with no transactions, causing the CFPB's validation scripts to reject the submission for incomplete time coverage.

**Task:** Use a CROSS JOIN to generate the complete Cartesian product of all active pools and all reporting months, then LEFT JOIN the actual performance data to fill in values — ensuring every pool-month combination has a row in the output.

**Action:**
The following CROSS JOIN approach was implemented:

```sql
-- Step 1: Generate all reporting months using a CTE
;WITH ReportingMonths AS (
    SELECT CAST('2024-01-01' AS DATE) AS ReportMonth
    UNION ALL
    SELECT DATEADD(MONTH, 1, ReportMonth)
    FROM ReportingMonths
    WHERE ReportMonth < '2025-12-01'
),

-- Step 2: Get all active pools
ActivePools AS (
    SELECT DISTINCT PoolID, CUSIP, SecurityType
    FROM deals.PoolSummary
    WHERE PoolStatus = 'ACTIVE'
)

-- Step 3: CROSS JOIN to create all pool-month combinations
SELECT
    ap.PoolID,
    ap.CUSIP,
    ap.SecurityType,
    rm.ReportMonth,
    COALESCE(pp.CurrentBalance, 0) AS CurrentBalance,
    COALESCE(pp.ScheduledPayment, 0) AS ScheduledPayment,
    COALESCE(pp.PrepaymentAmount, 0) AS PrepaymentAmount,
    COALESCE(pp.DefaultAmount, 0) AS DefaultAmount,
    CASE WHEN pp.PoolID IS NULL THEN 'NO_ACTIVITY' ELSE 'REPORTED' END AS DataStatus
FROM ActivePools ap
CROSS JOIN ReportingMonths rm
LEFT JOIN deals.PoolPerformance pp
    ON ap.PoolID = pp.PoolID
    AND rm.ReportMonth = pp.ReportMonth
ORDER BY ap.PoolID, rm.ReportMonth
OPTION (MAXRECURSION 100);

-- Simpler example: Generate all state-product combinations
SELECT
    s.StateCode,
    s.StateName,
    p.ProductType,
    p.ProductDescription
FROM ref.States s
CROSS JOIN ref.ProductTypes p
ORDER BY s.StateCode, p.ProductType;
-- 50 states x 6 product types = 300 rows
```

Key CROSS JOIN concepts:
- **Cartesian product**: CROSS JOIN returns every combination of rows from both tables. If Table A has M rows and Table B has N rows, the result has M x N rows.
- **No ON clause**: CROSS JOIN does not use a join condition — every row pairs with every row.
- **Use case**: Generating reference grids, time-series scaffolding, and complete dimensional combinations where gaps must be filled.
- **Performance caution**: CROSS JOIN of two large tables produces an enormous result set. Only use with small reference sets or controlled CTEs.
- **COALESCE with LEFT JOIN**: After generating the complete grid, LEFT JOIN the actual data and use COALESCE to fill gaps with defaults.

**Result:** The CROSS JOIN produced 86,400 pool-month combinations (3,600 active pools x 24 months), of which 81,200 had actual performance data and 5,200 were filled with zeros for no-activity months. The CFPB validation scripts passed with zero errors on the first submission — previously, the team had spent 2 days manually patching gap rows. The complete grid also revealed 12 pools that had no activity for 6+ consecutive months, triggering a review that identified terminated pools not yet flagged in the system.

**AI Vision:** An AI-driven data completeness engine could automatically detect dimensional gaps in reporting datasets, generate the missing combinations using CROSS JOIN logic, and apply intelligent imputation (carrying forward last known values, interpolating trends) rather than simple zero-fills — improving both completeness and analytical accuracy.

---

### Q44. Self JOIN — comparing loan records across time periods

**Situation:** Fannie Mae's credit risk team needed to analyze how loan delinquency status changed between consecutive reporting months. They wanted to identify loans that transitioned from current (status 0) to 30-days delinquent (status 1), or from 60-days to 90-days delinquent — these transition rates were critical inputs to the enterprise loss forecasting model. The data was stored in a single LoanMonthly table with one row per loan per month.

**Task:** Write a self-join query to compare each loan's current-month record with its prior-month record, calculating delinquency transitions and identifying loans whose status worsened, improved, or remained unchanged.

**Action:**
The following self-join analysis was implemented:

```sql
-- Self JOIN: compare current month to prior month for the same loan
SELECT
    curr.LoanID,
    curr.ReportingMonth AS CurrentMonth,
    prev.ReportingMonth AS PriorMonth,
    prev.DelinquencyStatus AS PriorStatus,
    curr.DelinquencyStatus AS CurrentStatus,
    prev.CurrentUPB AS PriorUPB,
    curr.CurrentUPB AS CurrentUPB,
    CASE
        WHEN curr.DelinquencyStatus > prev.DelinquencyStatus THEN 'WORSENED'
        WHEN curr.DelinquencyStatus < prev.DelinquencyStatus THEN 'IMPROVED'
        ELSE 'UNCHANGED'
    END AS TransitionType
FROM servicing.LoanMonthly curr
INNER JOIN servicing.LoanMonthly prev
    ON curr.LoanID = prev.LoanID
    AND curr.ReportingMonth = DATEADD(MONTH, 1, prev.ReportingMonth)
WHERE curr.ReportingMonth = '2025-12-01';

-- Transition matrix: count loans in each from-to status bucket
SELECT
    prev.DelinquencyStatus AS FromStatus,
    curr.DelinquencyStatus AS ToStatus,
    COUNT(*) AS LoanCount,
    SUM(curr.CurrentUPB) AS TotalUPB
FROM servicing.LoanMonthly curr
INNER JOIN servicing.LoanMonthly prev
    ON curr.LoanID = prev.LoanID
    AND curr.ReportingMonth = DATEADD(MONTH, 1, prev.ReportingMonth)
WHERE curr.ReportingMonth = '2025-12-01'
GROUP BY prev.DelinquencyStatus, curr.DelinquencyStatus
ORDER BY prev.DelinquencyStatus, curr.DelinquencyStatus;

-- Compare interest rates: find loans with rate changes
SELECT
    curr.LoanID,
    prev.InterestRate AS PriorRate,
    curr.InterestRate AS CurrentRate,
    curr.InterestRate - prev.InterestRate AS RateChange
FROM servicing.LoanMonthly curr
INNER JOIN servicing.LoanMonthly prev
    ON curr.LoanID = prev.LoanID
    AND curr.ReportingMonth = DATEADD(MONTH, 1, prev.ReportingMonth)
WHERE curr.ReportingMonth = '2025-12-01'
    AND curr.InterestRate <> prev.InterestRate;
```

Key self-join concepts:
- **Self JOIN**: A table joined to itself using different aliases (curr and prev). Each alias represents a different "copy" of the same table.
- **Temporal comparison**: The join condition `curr.ReportingMonth = DATEADD(MONTH, 1, prev.ReportingMonth)` links each month's record to the prior month's record for the same loan.
- **Aliases are required**: Without aliases, SQL Server cannot distinguish between the two references to the same table.
- **Performance**: Self-joins on large tables benefit from a composite index on (LoanID, ReportingMonth) to enable efficient seek operations.

**Result:** The self-join transition analysis processed 22 million loan-month pairs in 48 seconds. The transition matrix revealed that 2.3% of current loans rolled to 30-day delinquent status (a 0.4% increase from the prior month), signaling an emerging credit deterioration trend. The loss forecasting model consumed the transition rates and projected an additional $1.8 billion in expected losses over the next 4 quarters, prompting a portfolio strategy review.

**AI Vision:** A predictive transition model could use the self-join output as training data to learn temporal patterns in delinquency progression, predicting which currently-current loans are most likely to roll delinquent next month based on feature vectors (credit score trends, payment patterns, local unemployment rates) — enabling proactive intervention.

---

### Q45. String concatenation (+ and CONCAT) — building loan identifiers

**Situation:** CoreLogic's property analytics platform needed to generate composite identifiers for each property record by combining State FIPS code, County FIPS code, and Census Tract into a single GEOID key. Additionally, Intex deal reports required a formatted deal identifier combining the agency prefix, deal year, and sequence number. The legacy system used the + operator, which produced NULL results when any component was NULL — causing 8% of property records to lose their GEOID.

**Task:** Replace the + concatenation operator with CONCAT() where NULL safety is required, and demonstrate both approaches with proper NULL handling for generating composite loan and property identifiers.

**Action:**
The following string concatenation patterns were implemented:

```sql
-- Problem: + operator returns NULL if any operand is NULL
SELECT
    PropertyID,
    StateFIPS + CountyFIPS + CensusTract AS GEOID_Plus
    -- If CensusTract is NULL, entire GEOID is NULL!
FROM CoreLogicProperty;

-- Solution: CONCAT() treats NULL as empty string
SELECT
    PropertyID,
    CONCAT(StateFIPS, CountyFIPS, CensusTract) AS GEOID_Concat
    -- If CensusTract is NULL, result is StateFIPS + CountyFIPS
FROM CoreLogicProperty;

-- Building formatted deal identifiers
SELECT
    DealID,
    CONCAT(AgencyPrefix, '-', DealYear, '-',
           RIGHT('0000' + CAST(SequenceNumber AS VARCHAR), 4)) AS FormattedDealID
    -- Example: 'FNM-2025-0042'
FROM deals.IntexDealMaster;

-- CONCAT_WS: concatenate with separator (SQL Server 2017+)
SELECT
    LoanID,
    CONCAT_WS('-', AgencyCode, PoolID,
              CAST(LoanSequence AS VARCHAR)) AS CompositeKey,
    -- Example: 'GNMA-MA4521-00127'
    CONCAT_WS(', ', BorrowerCity, BorrowerState, BorrowerZip) AS FullAddress
    -- Example: 'Dallas, TX, 75201'
FROM servicing.LoanMaster;

-- Mixed approach: + for guaranteed NOT NULL, CONCAT for nullable
SELECT
    LoanID,
    -- These columns have NOT NULL constraints: safe to use +
    Agency + '-' + CAST(LoanID AS VARCHAR(20)) AS AgencyLoanKey,
    -- These columns may be NULL: use CONCAT
    CONCAT(PropertyStreet, ', ', PropertyCity, ', ',
           PropertyState, ' ', PropertyZip) AS PropertyAddress
FROM servicing.LoanMaster;

-- Building a formatted report string
SELECT
    CONCAT('Loan ', LoanID, ' | Balance: $',
           FORMAT(CurrentUPB, 'N2'),
           ' | Rate: ', FORMAT(InterestRate, 'N3'), '%',
           ' | State: ', PropertyState) AS LoanSummary
FROM servicing.LoanMaster
WHERE Agency = 'FNMA'
    AND DelinquencyStatus >= 3;
```

Key concatenation concepts:
- **+ operator**: Standard string concatenation. Returns NULL if any operand is NULL (NULL propagation). Requires explicit CAST/CONVERT for non-string types.
- **CONCAT()**: Implicitly converts all arguments to strings and treats NULL as empty string. Available from SQL Server 2012+.
- **CONCAT_WS()**: "Concatenate With Separator" — inserts a separator between arguments automatically, and skips NULL values. Available from SQL Server 2017+.
- **Performance**: All three approaches have similar performance. CONCAT is marginally slower due to implicit type conversion but the difference is negligible.

**Result:** Replacing + with CONCAT for the GEOID generation fixed 8% of property records (1.2 million) that previously had NULL GEOIDs. The formatted Intex deal identifiers improved readability in regulatory reports and reduced manual lookup errors by 35%. CONCAT_WS simplified the address formatting code from 15 lines of ISNULL/COALESCE wrappers to a single function call.

**AI Vision:** An intelligent data profiling system could analyze concatenation patterns across the codebase, identify all instances where + is used with nullable columns (potential NULL propagation bugs), and automatically suggest CONCAT replacements — preventing silent data loss from NULL concatenation.

---

### Q46. CHARINDEX and PATINDEX — searching within loan descriptions

**Situation:** Freddie Mac's loan documentation database stored free-text property descriptions, servicer notes, and modification narratives in VARCHAR(MAX) columns. Analysts needed to search these text fields for specific patterns — property addresses containing "Condo" or "PUD" designations, servicer notes mentioning "forbearance," and loan modification descriptions containing specific dollar amounts or percentage patterns.

**Task:** Use CHARINDEX for exact substring searches and PATINDEX for pattern-based searches within text columns, enabling the analytics team to extract structured insights from unstructured loan documentation fields.

**Action:**
The following text search queries were implemented:

```sql
-- CHARINDEX: find exact substring position (case-insensitive by default)
-- Returns 0 if not found, starting position (1-based) if found
SELECT
    LoanID,
    PropertyDescription,
    CHARINDEX('CONDO', PropertyDescription) AS CondoPosition
FROM servicing.LoanDocumentation
WHERE CHARINDEX('CONDO', PropertyDescription) > 0;

-- CHARINDEX with start position: find second occurrence
SELECT
    LoanID,
    ServicerNotes,
    CHARINDEX('forbearance', ServicerNotes) AS FirstOccurrence,
    CHARINDEX('forbearance', ServicerNotes,
              CHARINDEX('forbearance', ServicerNotes) + 1) AS SecondOccurrence
FROM servicing.LoanDocumentation
WHERE CHARINDEX('forbearance', ServicerNotes) > 0;

-- Extract a substring between two delimiters
SELECT
    LoanID,
    SUBSTRING(
        ModificationNarrative,
        CHARINDEX('Rate:', ModificationNarrative) + 5,
        CHARINDEX('%', ModificationNarrative,
                  CHARINDEX('Rate:', ModificationNarrative))
        - CHARINDEX('Rate:', ModificationNarrative) - 5
    ) AS ExtractedRate
FROM servicing.LoanModifications
WHERE CHARINDEX('Rate:', ModificationNarrative) > 0;

-- PATINDEX: pattern-based search using wildcards (% and _)
-- Find notes containing a dollar amount pattern ($NNN,NNN.NN)
SELECT
    LoanID,
    ServicerNotes,
    PATINDEX('%$[0-9][0-9][0-9],[0-9][0-9][0-9]%', ServicerNotes) AS AmountPosition
FROM servicing.LoanDocumentation
WHERE PATINDEX('%$[0-9][0-9][0-9],[0-9][0-9][0-9]%', ServicerNotes) > 0;

-- Find property descriptions with ZIP code patterns
SELECT
    LoanID,
    PropertyDescription,
    PATINDEX('%[0-9][0-9][0-9][0-9][0-9]%', PropertyDescription) AS ZipPosition
FROM servicing.LoanDocumentation
WHERE PATINDEX('%[0-9][0-9][0-9][0-9][0-9]%', PropertyDescription) > 0;

-- Combine CHARINDEX with CASE for classification
SELECT
    LoanID,
    CASE
        WHEN CHARINDEX('CONDO', UPPER(PropertyDescription)) > 0 THEN 'Condominium'
        WHEN CHARINDEX('PUD', UPPER(PropertyDescription)) > 0 THEN 'Planned Unit Dev'
        WHEN CHARINDEX('CO-OP', UPPER(PropertyDescription)) > 0 THEN 'Cooperative'
        WHEN CHARINDEX('MH', UPPER(PropertyDescription)) > 0 THEN 'Manufactured Housing'
        ELSE 'Single Family'
    END AS PropertyCategory
FROM servicing.LoanDocumentation;
```

Key text search concepts:
- **CHARINDEX(substring, string [, start])**: Returns the 1-based position of a substring. Returns 0 if not found. Case sensitivity depends on the column's collation.
- **PATINDEX('%pattern%', string)**: Like CHARINDEX but supports wildcard patterns (%, _, [a-z], [0-9]). The pattern must be wrapped in % wildcards.
- **Performance**: Both functions perform full scans on VARCHAR columns. For large tables, consider Full-Text Search indexes for better performance.
- **Three-argument CHARINDEX**: The third argument specifies the starting position — useful for finding the Nth occurrence by chaining calls.

**Result:** The text search queries identified 42,000 condominium properties that were miscategorized as single-family in the structured PropertyType column — a data quality issue affecting risk-weight calculations. The forbearance search flagged 8,700 loans with multiple forbearance mentions, enabling the loss mitigation team to prioritize repeat-forbearance borrowers. The pattern-based dollar amount extraction automated a manual review process that previously required 3 analysts working 2 weeks each quarter.

**AI Vision:** A natural language processing (NLP) system could replace CHARINDEX/PATINDEX searches with semantic understanding — recognizing that "condo," "condominium unit," and "attached dwelling" all refer to the same property type, and extracting structured data from free-text fields with 95%+ accuracy regardless of phrasing variations.

---

### Q47. ROUND, CEILING, FLOOR — rounding financial calculations

**Situation:** Ginnie Mae's MBS payment processing system calculated monthly interest distributions to bondholders, principal allocations across tranches, and servicing fees. Different financial rules required different rounding behaviors — interest payments rounded to the nearest cent (ROUND), minimum guarantee fees rounded up to the next cent (CEILING), and principal allocations rounded down to prevent over-distribution (FLOOR). Inconsistent rounding had caused a cumulative $12,000 discrepancy over 6 months.

**Task:** Implement standardized rounding functions across all payment calculation queries, using ROUND for standard two-decimal rounding, CEILING for upward rounding of fees, and FLOOR for downward rounding of distributions, to eliminate rounding discrepancies.

**Action:**
The following rounding patterns were applied to payment calculations:

```sql
-- ROUND: standard banker's rounding to N decimal places
-- Round interest payments to 2 decimal places (nearest cent)
SELECT
    PoolID,
    TrancheID,
    CurrentBalance,
    CouponRate,
    CurrentBalance * (CouponRate / 100.0 / 12.0) AS RawMonthlyInterest,
    ROUND(CurrentBalance * (CouponRate / 100.0 / 12.0), 2) AS RoundedInterest
FROM deals.TrancheCashflows
WHERE PaymentDate = '2025-12-25';

-- ROUND with third parameter: truncation mode
-- 0 (default) = round, 1 = truncate
SELECT
    ROUND(1234.5678, 2, 0) AS Rounded,    -- 1234.57 (rounded)
    ROUND(1234.5678, 2, 1) AS Truncated;   -- 1234.56 (truncated)

-- CEILING: always rounds UP to next integer (or next cent with math)
-- Use for minimum fee calculations
SELECT
    LoanID,
    CurrentUPB,
    CurrentUPB * 0.0025 / 12.0 AS RawServicingFee,
    CEILING(CurrentUPB * 0.0025 / 12.0 * 100) / 100.0 AS CeilingFee
    -- Multiply by 100, CEILING, divide by 100 to round up to nearest cent
FROM servicing.LoanMaster
WHERE ServicerID = 7890;

-- FLOOR: always rounds DOWN to next integer (or next cent with math)
-- Use for principal distributions to prevent over-allocation
SELECT
    PoolID,
    TrancheID,
    ScheduledPrincipal,
    FLOOR(ScheduledPrincipal * 100) / 100.0 AS FloorPrincipal,
    PrepaymentAmount,
    FLOOR(PrepaymentAmount * 100) / 100.0 AS FloorPrepay
FROM deals.TrancheCashflows
WHERE PaymentDate = '2025-12-25';

-- Combined: penny-rounding reconciliation
SELECT
    PoolID,
    SUM(ROUND(TrancheInterest, 2)) AS TotalDistributed,
    ROUND(PoolInterest, 2) AS PoolTotal,
    ROUND(PoolInterest, 2) - SUM(ROUND(TrancheInterest, 2)) AS PennyVariance
FROM deals.TrancheCashflows
WHERE PaymentDate = '2025-12-25'
GROUP BY PoolID, PoolInterest
HAVING ABS(ROUND(PoolInterest, 2) - SUM(ROUND(TrancheInterest, 2))) > 0;

-- ROUND to negative places: round to nearest thousand
SELECT
    Agency,
    SUM(CurrentUPB) AS ExactTotal,
    ROUND(SUM(CurrentUPB), -3) AS RoundedToThousand,
    ROUND(SUM(CurrentUPB), -6) AS RoundedToMillion
FROM servicing.LoanMaster
GROUP BY Agency;
```

Key rounding function concepts:
- **ROUND(value, precision)**: Rounds to the specified decimal places. Positive precision = decimal places; negative precision = positions left of decimal (e.g., -3 rounds to thousands).
- **CEILING(value)**: Returns the smallest integer greater than or equal to the value. Always rounds toward positive infinity.
- **FLOOR(value)**: Returns the largest integer less than or equal to the value. Always rounds toward negative infinity.
- **Penny rounding**: For cent-level rounding with CEILING/FLOOR, multiply by 100, apply the function, divide by 100.
- **Financial rule**: Typically, distributed amounts use FLOOR to prevent over-distribution; the penny remainder is allocated to a designated "residual" tranche.

**Result:** Standardizing rounding functions eliminated the cumulative $12,000 discrepancy. Monthly reconciliation now shows zero variance between pool-level totals and the sum of tranche-level distributions. CEILING on servicing fees ensured Ginnie Mae never under-collected fees (average $0.003 per loan increase, totaling $180,000 annually). FLOOR on principal distributions prevented 47 instances per month where tranches would have received $0.01 more than available.

**AI Vision:** A financial reconciliation AI could analyze rounding patterns across millions of transactions, detect systematic biases introduced by rounding (e.g., consistently rounding up causing fee overcharges), and recommend the optimal rounding strategy for each calculation type based on regulatory requirements and historical variance analysis.

---

### Q48. Mathematical functions for mortgage math — calculating monthly payment

**Situation:** Fannie Mae's loan pricing team needed to calculate monthly mortgage payments, remaining balances after N payments, and total interest paid over the life of each loan. These calculations used standard amortization formulas involving powers, logarithms, and absolute values. The team was performing these calculations in Excel for individual loans but needed a SQL-based solution to compute values for millions of loans in batch.

**Task:** Implement mortgage amortization calculations using SQL Server's mathematical functions (POWER, LOG, ABS, SQRT) to compute monthly payments, remaining balances, and total interest for the entire loan portfolio.

**Action:**
The following mortgage math queries were implemented:

```sql
-- Monthly payment formula: M = P * [r(1+r)^n] / [(1+r)^n - 1]
-- Where P = principal, r = monthly rate, n = total months
SELECT
    LoanID,
    OriginalUPB AS Principal,
    InterestRate,
    OriginalLoanTerm AS TotalMonths,
    InterestRate / 100.0 / 12.0 AS MonthlyRate,

    -- Monthly payment calculation using POWER
    ROUND(
        OriginalUPB *
        (InterestRate / 100.0 / 12.0 *
         POWER(1 + InterestRate / 100.0 / 12.0, OriginalLoanTerm))
        /
        (POWER(1 + InterestRate / 100.0 / 12.0, OriginalLoanTerm) - 1),
        2
    ) AS MonthlyPayment

FROM servicing.LoanMaster
WHERE OriginalLoanTerm = 360  -- 30-year fixed
    AND InterestRate > 0
    AND LoanStatus = 'ACTIVE';

-- Remaining balance after K payments
-- Balance = P * [(1+r)^n - (1+r)^k] / [(1+r)^n - 1]
DECLARE @PaymentsMade INT = 60;  -- 5 years of payments

SELECT
    LoanID,
    OriginalUPB,
    InterestRate,
    @PaymentsMade AS PaymentsMade,
    ROUND(
        OriginalUPB *
        (POWER(1 + InterestRate / 100.0 / 12.0, OriginalLoanTerm)
         - POWER(1 + InterestRate / 100.0 / 12.0, @PaymentsMade))
        /
        (POWER(1 + InterestRate / 100.0 / 12.0, OriginalLoanTerm) - 1),
        2
    ) AS RemainingBalance
FROM servicing.LoanMaster
WHERE OriginalLoanTerm = 360
    AND InterestRate > 0;

-- Total interest paid over life of loan
SELECT
    LoanID,
    OriginalUPB,
    InterestRate,
    ROUND(
        OriginalUPB *
        (InterestRate / 100.0 / 12.0 *
         POWER(1 + InterestRate / 100.0 / 12.0, OriginalLoanTerm))
        /
        (POWER(1 + InterestRate / 100.0 / 12.0, OriginalLoanTerm) - 1),
        2
    ) * OriginalLoanTerm - OriginalUPB AS TotalInterestPaid
FROM servicing.LoanMaster
WHERE OriginalLoanTerm = 360
    AND InterestRate > 0;

-- Other useful math functions
SELECT
    LoanID,
    ABS(CurrentUPB - ExpectedUPB) AS BalanceVariance,
    SQRT(POWER(ActualCPR - ProjectedCPR, 2)) AS CPRDeviation,
    LOG(CurrentUPB) AS LogBalance,  -- Natural logarithm
    LOG10(CurrentUPB) AS Log10Balance,  -- Base-10 logarithm
    SIGN(CurrentUPB - PriorMonthUPB) AS BalanceDirection
    -- -1 = decreased, 0 = unchanged, 1 = increased
FROM servicing.LoanMonthly
WHERE ReportingMonth = '2025-12-01';
```

Key mathematical function concepts:
- **POWER(base, exponent)**: Raises a number to a power. Essential for compound interest formulas — `POWER(1 + r, n)` computes (1+r)^n.
- **LOG(value)**: Natural logarithm (base e). LOG10(value) for base-10 logarithm.
- **ABS(value)**: Absolute value — useful for variance calculations where direction doesn't matter.
- **SQRT(value)**: Square root — used in statistical calculations like standard deviation.
- **SIGN(value)**: Returns -1, 0, or 1 based on the sign of the value.
- **Precision note**: Use DECIMAL(18,10) or FLOAT for intermediate calculations to avoid rounding errors in multi-step mortgage formulas.

**Result:** The SQL-based amortization calculations processed 18 million active loans in 3 minutes, replacing a manual Excel process that could handle only 500 loans at a time. The batch calculation revealed 23,000 loans where the servicer-reported UPB differed from the mathematically expected balance by more than $100 — triggering data quality investigations. The total interest analysis showed $847 billion in expected future interest income across the portfolio, informing Fannie Mae's interest rate risk hedging strategy.

**AI Vision:** A mortgage pricing AI could use these mathematical building blocks to build Monte Carlo simulations that model thousands of interest rate scenarios simultaneously, predicting portfolio cash flows under stress conditions and optimizing hedging strategies in real time.

---

### Q49. NEWID and UNIQUEIDENTIFIER — generating GUIDs for loan tracking

**Situation:** Freddie Mac's loan exchange system needed to assign globally unique identifiers to loan transfer records shared between servicers, investors, and government agencies. Integer-based IDs were problematic because each system maintained its own ID sequences, causing collisions when records were merged. The system needed identifiers that were guaranteed unique across all participating systems without requiring a centralized ID authority.

**Task:** Implement UNIQUEIDENTIFIER columns with NEWID() and NEWSEQUENTIALID() to generate GUIDs for loan transfer records, ensuring global uniqueness across distributed systems while considering the performance implications of each approach.

**Action:**
The following GUID-based identification was implemented:

```sql
-- Create a table with a UNIQUEIDENTIFIER primary key
CREATE TABLE servicing.LoanTransfer (
    TransferID      UNIQUEIDENTIFIER NOT NULL
                    DEFAULT NEWID(),
    SourceServicerID INT NOT NULL,
    TargetServicerID INT NOT NULL,
    LoanID          BIGINT NOT NULL,
    TransferDate    DATE NOT NULL,
    TransferUPB     DECIMAL(14,2),
    TransferStatus  VARCHAR(20) DEFAULT 'PENDING',
    CreatedDate     DATETIME2 DEFAULT GETDATE(),
    CONSTRAINT PK_LoanTransfer PRIMARY KEY NONCLUSTERED (TransferID)
);

-- Insert without specifying TransferID — NEWID() generates automatically
INSERT INTO servicing.LoanTransfer
    (SourceServicerID, TargetServicerID, LoanID, TransferDate, TransferUPB)
VALUES
    (4521, 7890, 100234567, '2025-12-15', 245000.00);

-- Generate GUIDs explicitly
SELECT
    NEWID() AS RandomGUID1,
    NEWID() AS RandomGUID2,
    NEWID() AS RandomGUID3;
-- Each call produces a different value:
-- 6F9619FF-8B86-D011-B42D-00CF4FC964FF (example)

-- NEWSEQUENTIALID(): generates sequential GUIDs (better for clustered indexes)
-- Can only be used as a DEFAULT constraint, not in queries
CREATE TABLE servicing.LoanEvent (
    EventID     UNIQUEIDENTIFIER NOT NULL
                DEFAULT NEWSEQUENTIALID(),
    LoanID      BIGINT NOT NULL,
    EventType   VARCHAR(30),
    EventDate   DATETIME2 DEFAULT GETDATE(),
    CONSTRAINT PK_LoanEvent PRIMARY KEY CLUSTERED (EventID)
);

-- Query using GUID values
SELECT *
FROM servicing.LoanTransfer
WHERE TransferID = '6F9619FF-8B86-D011-B42D-00CF4FC964FF';

-- Generate a batch of transfer records with GUIDs
INSERT INTO servicing.LoanTransfer
    (TransferID, SourceServicerID, TargetServicerID, LoanID, TransferDate, TransferUPB)
SELECT
    NEWID(),
    lm.CurrentServicerID,
    ts.NewServicerID,
    lm.LoanID,
    ts.EffectiveDate,
    lm.CurrentUPB
FROM servicing.LoanMaster lm
INNER JOIN staging.TransferSchedule ts
    ON lm.LoanID = ts.LoanID
WHERE ts.TransferBatch = 'BATCH_202512';

-- Convert GUID to string for external system interfaces
SELECT
    TransferID,
    CONVERT(VARCHAR(36), TransferID) AS TransferID_String,
    UPPER(CONVERT(VARCHAR(36), TransferID)) AS TransferID_Upper
FROM servicing.LoanTransfer;
```

Key UNIQUEIDENTIFIER concepts:
- **NEWID()**: Generates a random version-4 GUID. Guaranteed unique across all computers worldwide. 16 bytes (128 bits) storage.
- **NEWSEQUENTIALID()**: Generates GUIDs that are sequential on the local machine — dramatically better for clustered index inserts because new values are always appended (no page splits).
- **Clustered index warning**: Random GUIDs (NEWID()) as clustered index keys cause severe page splits and fragmentation. Use NEWSEQUENTIALID() or make the GUID a nonclustered key with an INT IDENTITY clustered key.
- **Storage**: 16 bytes per GUID vs 4 bytes for INT — wider keys mean larger indexes and more I/O.
- **Use case**: Ideal for distributed systems, cross-database merges, and external interfaces where integer collisions are possible.

**Result:** The GUID-based transfer system processed 340,000 loan transfers across 45 servicers in Q4 2025 with zero ID collisions — compared to 23 collisions per quarter under the previous integer-based system. Using NEWSEQUENTIALID() for the clustered index reduced page splits by 98% compared to an initial NEWID() implementation. The 16-byte storage overhead was acceptable given the 340,000-row table size (5.2 MB additional vs billions in managed assets).

**AI Vision:** An intelligent ID management system could analyze cross-system data flows and recommend the optimal identifier strategy for each table — GUID for distributed data, IDENTITY for local-only data, and composite natural keys for dimensional data — balancing uniqueness guarantees against storage and performance costs.

---

### Q50. Basic permissions (GRANT, REVOKE, DENY) — securing loan data access

**Situation:** Ginnie Mae's mortgage database contained sensitive borrower information (Social Security numbers, credit scores, income) alongside non-sensitive pool-level analytics data. A security audit found that all 150 database users had db_datareader access — meaning analysts who only needed pool summary data could also query borrower PII. The audit mandated role-based access controls with least-privilege principles, separating read access by business function.

**Task:** Implement a granular permission model using GRANT, REVOKE, and DENY to create role-based access — granting analysts access only to the schemas and tables relevant to their business function, while explicitly denying access to sensitive borrower data.

**Action:**
The following permission model was implemented:

```sql
-- Step 1: Create roles for each business function
CREATE ROLE PoolAnalyst;
CREATE ROLE RiskAnalyst;
CREATE ROLE ServicingManager;
CREATE ROLE ComplianceAuditor;
CREATE ROLE ETLOperator;

-- Step 2: GRANT schema-level permissions to roles
-- Pool analysts: read access to deals schema only
GRANT SELECT ON SCHEMA::deals TO PoolAnalyst;

-- Risk analysts: read access to deals and servicing, but not PII columns
GRANT SELECT ON SCHEMA::deals TO RiskAnalyst;
GRANT SELECT ON SCHEMA::servicing TO RiskAnalyst;

-- Servicing managers: full read/write on servicing schema
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::servicing TO ServicingManager;

-- Compliance auditors: read everything including regulatory
GRANT SELECT ON SCHEMA::deals TO ComplianceAuditor;
GRANT SELECT ON SCHEMA::servicing TO ComplianceAuditor;
GRANT SELECT ON SCHEMA::regulatory TO ComplianceAuditor;

-- ETL operators: full control on staging, insert on servicing
GRANT CONTROL ON SCHEMA::staging TO ETLOperator;
GRANT INSERT, UPDATE ON SCHEMA::servicing TO ETLOperator;

-- Step 3: DENY sensitive data access
-- Deny risk analysts access to borrower PII table
DENY SELECT ON servicing.BorrowerPII TO RiskAnalyst;

-- Deny column-level access to SSN even for servicing managers
DENY SELECT ON servicing.BorrowerPII (SSN) TO ServicingManager;

-- DENY overrides GRANT — even if a user is in multiple roles,
-- DENY on any role prevents access

-- Step 4: REVOKE previously granted permissions
-- Remove a permission that was granted in error
REVOKE INSERT ON SCHEMA::servicing FROM PoolAnalyst;

-- Step 5: Add users to roles
ALTER ROLE PoolAnalyst ADD MEMBER [DOMAIN\jsmith];
ALTER ROLE RiskAnalyst ADD MEMBER [DOMAIN\mjones];
ALTER ROLE ServicingManager ADD MEMBER [DOMAIN\kpatel];
ALTER ROLE ComplianceAuditor ADD MEMBER [DOMAIN\lchen];
ALTER ROLE ETLOperator ADD MEMBER [SVC_ETL_Account];

-- Step 6: Verify effective permissions for a user
SELECT
    dp.name AS PrincipalName,
    dp.type_desc AS PrincipalType,
    o.name AS ObjectName,
    p.permission_name AS Permission,
    p.state_desc AS PermissionState  -- GRANT, DENY, REVOKE
FROM sys.database_permissions p
INNER JOIN sys.database_principals dp
    ON p.grantee_principal_id = dp.principal_id
LEFT JOIN sys.objects o
    ON p.major_id = o.object_id
WHERE dp.name = 'RiskAnalyst'
ORDER BY o.name, p.permission_name;

-- Check what a specific user can do
EXECUTE AS USER = 'DOMAIN\jsmith';
SELECT * FROM fn_my_permissions('servicing.LoanMaster', 'OBJECT');
REVERT;
```

Key permission concepts:
- **GRANT**: Gives a permission to a principal. Multiple GRANTs are cumulative — permissions from all roles a user belongs to are combined.
- **DENY**: Explicitly blocks a permission. DENY always wins over GRANT — if any role DENYs a permission, the user cannot access the object even if another role GRANTs it.
- **REVOKE**: Removes a previously GRANTed or DENYed permission, returning to the default (no access). REVOKE is not the same as DENY — REVOKE removes a statement, DENY adds a blocking statement.
- **Role-based access**: Always grant permissions to roles, not individual users. Add/remove users from roles as responsibilities change.
- **Principle of least privilege**: Start with no access and add only what each role needs.

**Result:** The role-based permission model reduced the number of users with access to borrower PII from 150 to 12 (the compliance and servicing teams only). The security audit finding was resolved with zero business impact — all 150 users retained access to the data they needed through their assigned roles. Permission management time dropped from 4 hours per new-hire onboarding (individual GRANTs) to 5 minutes (single role assignment). A follow-up penetration test confirmed that no unauthorized access paths to PII existed.

**AI Vision:** An AI-powered access governance system could analyze actual query patterns against granted permissions, identify users with excessive privileges (permissions granted but never used), recommend role reassignments based on observed behavior, and automatically flag anomalous access patterns that may indicate compromised credentials or insider threats.

---

[Back to Q&A Index](README.md)
