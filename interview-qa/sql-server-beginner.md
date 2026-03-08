# SQL Server - Beginner Q&A (STAR Method)

[Back to Q&A Index](README.md)

---

25 beginner questions with answers using the **STAR methodology** (Situation, Task, Action, Result) plus an **AI Vision** — real-world US secondary mortgage market examples.

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

[Back to Q&A Index](README.md)
