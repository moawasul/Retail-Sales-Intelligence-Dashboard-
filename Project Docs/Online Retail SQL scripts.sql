USE [e-Commerce];

-- Check row counts
SELECT '2009 Data' as Year, COUNT(*) as Rows FROM Staging_2009
UNION ALL
SELECT '2010 Data' as Year, COUNT(*) as Rows FROM Staging_2010;

-- Preview the data
SELECT TOP 10 * FROM Staging_2009;
SELECT TOP 10 * FROM Staging_2010;

--Step 1: Check Column Names
--Before we merge(UNION ALL), we must make sure the columns match exactly
--Are the column headers identical? (e.g., does one say Price and the other UnitPrice?)
SELECT TOP 1 * FROM Staging_2009;
SELECT TOP 1 * FROM Staging_2010;

--Step 2: Create the Master Table
/*If the columns look good, we will run a script to create a new table called 
dbo.tbl_OnlineRetail_All that combines both years*/

USE [e-Commerce];
GO

-- 1. Drop the table if it already exists (so we can re-run this safely)
IF OBJECT_ID('dbo.tbl_OnlineRetail_All', 'U') IS NOT NULL
DROP TABLE dbo.tbl_OnlineRetail_All;
GO

-- 2. Create the new table by combining both staging tables
SELECT *
INTO dbo.tbl_OnlineRetail_All
FROM 
(
    SELECT 
        [Invoice], 
        [StockCode], 
        [Description], 
        [Quantity], 
        [InvoiceDate], 
        [Price], 
        [Customer ID] AS CustomerID, -- Renaming to remove space
        [Country]
    FROM Staging_2009
    
    UNION ALL
    
    SELECT 
        [Invoice], 
        [StockCode], 
        [Description], 
        [Quantity], 
        [InvoiceDate], 
        [Price], 
        [Customer ID] AS CustomerID, -- Renaming to remove space
        [Country]
    FROM Staging_2010
) AS CombinedData;


--Step 3: Verification (The Senior Analyst Check)
--Never trust a query blindly. We expect the total rows to be 1,067,371.

SELECT COUNT(*) as TotalRows FROM dbo.tbl_OnlineRetail_All;


/* Above code gereated this errors and there was no data in the new table dbo.tbl_OnlineRetail_All
Msg 8114, Level 16, State 5, Line 31
Error converting data type nvarchar to float.
Completion time: 2025-11-25T11:49:36.8625626+02:00
COMPELTED with errors and result has 0 records*/


/*
The Problem
The error Error converting data type nvarchar to float means that in one of your tables
(likely the 2010 one), the Import Wizard saw some weird text inside the Price or Quantity column 
and decided to import the whole column as Text (nvarchar).
When you try to UNION (stack) it with the other table (which might be correctly set as numbers), 
SQL Server tries to convert that text back to numbers, hits a value like "Adjust bad debt" or
"Manual," and crashes.

We will use the function TRY_CAST.
It tries to convert the value to a number.
If it fails (e.g., the value is "Abc"), it returns NULL instead of crashing the whole query.
The Fix
Please run this updated script. It explicitly forces the data types to be correct.
*/
USE [e-Commerce];
GO

-- 1. Drop the table if it exists
IF OBJECT_ID('dbo.tbl_OnlineRetail_All', 'U') IS NOT NULL
DROP TABLE dbo.tbl_OnlineRetail_All;
GO

-- 2. Create the new table with Safe Conversions
SELECT *
INTO dbo.tbl_OnlineRetail_All
FROM 
(
    SELECT 
        CAST([Invoice] AS NVARCHAR(50)) AS Invoice, 
        CAST([StockCode] AS NVARCHAR(50)) AS StockCode, 
        CAST([Description] AS NVARCHAR(255)) AS [Description], 
        -- Safely convert Quantity to Integer
        TRY_CAST([Quantity] AS INT) AS Quantity, 
        -- Ensure Date is actually a Date
        TRY_CAST([InvoiceDate] AS DATETIME) AS InvoiceDate, 
        -- Safely convert Price to Float
        TRY_CAST([Price] AS FLOAT) AS Price, 
        CAST([Customer ID] AS NVARCHAR(50)) AS CustomerID, 
        CAST([Country] AS NVARCHAR(100)) AS Country
    FROM Staging_2009
    
    UNION ALL
    
    SELECT 
        CAST([Invoice] AS NVARCHAR(50)) AS Invoice, 
        CAST([StockCode] AS NVARCHAR(50)) AS StockCode, 
        CAST([Description] AS NVARCHAR(255)) AS [Description], 
        TRY_CAST([Quantity] AS INT) AS Quantity, 
        TRY_CAST([InvoiceDate] AS DATETIME) AS InvoiceDate, 
        TRY_CAST([Price] AS FLOAT) AS Price, 
        CAST([Customer ID] AS NVARCHAR(50)) AS CustomerID, 
        CAST([Country] AS NVARCHAR(100)) AS Country
    FROM Staging_2010
) AS CombinedData;

SELECT COUNT(*) as TotalRows FROM dbo.tbl_OnlineRetail_All;

USE [e-Commerce];
GO

/* 
 The Next Step: Data Profiling (The "Detective Work")
Before we delete anything, we must look at what is wrong. A Senior Analyst never blindly deletes data; 
they investigate it first.
   ===================================================================
   SCRIPT PURPOSE: Data Profiling / Health Check
   SCOPE: Identify how many records are "dirty" before we clean them.
   ===================================================================
*/

SELECT 
    -- 1. Count the Total Rows in the table
    COUNT(*) AS [Total Rows],

    -- 2. Check for Data Engineering Errors
    -- Count rows where Price became NULL because the original text was not a number
    SUM(CASE WHEN Price IS NULL THEN 1 ELSE 0 END) AS [Bad Price (Text)],
    
    -- Count rows where Quantity became NULL (e.g., text like "missing")
    SUM(CASE WHEN Quantity IS NULL THEN 1 ELSE 0 END) AS [Bad Qty (Text)],

    -- 3. Check for Business Logic "Features"
    -- Count rows where Customer ID is missing (Guest Checkout or Cash Sale)
    SUM(CASE WHEN CustomerID IS NULL THEN 1 ELSE 0 END) AS [Missing CustomerID],

    -- Count rows representing RETURNS (Negative Quantity)
    -- These reduce revenue, so we must handle them carefully later.
    SUM(CASE WHEN Quantity < 0 THEN 1 ELSE 0 END) AS [Returns (Negative Qty)],

    -- Count rows with Zero Price (Free items, gifts, or errors)
    SUM(CASE WHEN Price = 0 THEN 1 ELSE 0 END) AS [Free Items (Price = 0)]

FROM dbo.tbl_OnlineRetail_All;


USE [e-Commerce];
GO

/*
The Next Step: Creating the "Clean" Table
We are going to take your raw data (tbl_OnlineRetail_All) and create a final, clean table 
(Fact_Transactions).
What this script does (Scope Alignment):
Standardizes IDs: It fills those NULL Customer IDs with a placeholder (0 or Unregistered). 
This ensures our database integrity is strict.
Filters Noise: It removes records where Price is 0 (usually system errors or failed transactions 
in this specific dataset).
Formats Strings: It forces Customer IDs to be clean text, ready for the "Customer" dashboard.
   ===========================================================================
   STEP 3: CLEANING & TRANSFORMATION
   SCOPE: Create the final 'Fact_Transactions' table for Power BI.
   STRATEGY:
     1. Handle NULL CustomerIDs (Assign to 'Guest').
     2. Remove records with 0 Price (Data Quality).
     3. Ensure StockCodes are clean (Trim spaces).
   ===========================================================================
*/

-- 1. Check if the clean table exists, drop if yes
IF OBJECT_ID('dbo.Fact_Transactions', 'U') IS NOT NULL
DROP TABLE dbo.Fact_Transactions;
GO

-- 2. Create and Populate the Clean Table
SELECT 
    -- Keep the Invoice Number for Transaction Counts
    Invoice,
    
    -- Clean the StockCode (Trim removes accidental spaces like ' A' -> 'A')
    TRIM(StockCode) AS StockCode,
    
    -- Clean the Description
    TRIM([Description]) AS [Description],
    
    -- Quantity is already integer from previous step
    Quantity,
    
    -- Create a 'TotalSales' column now to save work in Power BI
    -- Logic: Quantity * Price
    (Quantity * Price) AS SalesAmount,
    
    -- Date formatting (Keep detailed time for now)
    InvoiceDate,
    
    -- Price per unit
    Price,
    
    -- CRITICAL STEP: Handle Missing Customers
    -- Logic: If CustomerID is NULL, call it 'Unknown'. 
    -- This allows us to keep the revenue data without breaking the link.
    CASE 
        WHEN CustomerID IS NULL THEN 'Unknown'
        ELSE CustomerID 
    END AS CustomerID,
    
    -- Clean Country Name
    TRIM(Country) AS Country

INTO dbo.Fact_Transactions -- This creates the new table
FROM dbo.tbl_OnlineRetail_All
WHERE 
    Price > 0 -- Scope: Remove "Free" items or errors
    AND Invoice IS NOT NULL; -- Scope: Ensure transaction exists
GO

/*
   ===========================================================================
   VALIDATION STEP
   Check how many rows we have now.
   ===========================================================================
*/
SELECT COUNT(*) AS [Clean Row Count] FROM dbo.Fact_Transactions;

--============================================================================

USE [e-Commerce];
GO

/*
   ===========================================================================
   STEP 4: DIMENSION MODELING - PRODUCTS
   SCOPE: Create a reference table for all products.
   
   OBJECTIVE: 
   1. Extract unique StockCodes.
   2. Assign the best Description to each code.
   ===========================================================================
   IF OBJECT_ID('dbo.Dim_Product', 'U') IS NOT NULL:
OBJECT_ID('dbo.Dim_Product', 'U') is a SQL Server built-in function that returns the object ID 
of a schema-scoped object.
'dbo.Dim_Product' specifies the object name, including the schema (dbo).
'U' is the object type, indicating a user table. Other object types include 'V' for view, 'P'
for stored procedure, etc.
If the Dim_Product table exists in the dbo schema, OBJECT_ID will return its object ID 
(a non-NULL value). If it does not exist, 
OBJECT_ID will return NULL.
The IF ... IS NOT NULL condition checks if the table exists.
DROP TABLE dbo.Dim_Product;:
If the condition in the IF statement is true (meaning Dim_Product exists), this statement is executed, which removes the Dim_Product table from the database.
*/

-- 1. Check if Dim_Product exists, drop if yes
IF OBJECT_ID('dbo.Dim_Product', 'U') IS NOT NULL
DROP TABLE dbo.Dim_Product;
GO

-- 2. Create the Table
SELECT 
    StockCode,
    -- We use MAX to pick one description per code. 
    -- This handles cases where "Lunchbox" was spelled differently in 2009 vs 2010.
    MAX([Description]) AS [Description] 
INTO dbo.Dim_Product
FROM dbo.Fact_Transactions
GROUP BY StockCode; -- This ensures every StockCode appears only once.
GO

/*
   ===========================================================================
   VALIDATION
   Check how many unique products we sell.
   ===========================================================================
*/
SELECT COUNT(*) AS [Unique Products] FROM dbo.Dim_Product;
SELECT TOP 5 * FROM dbo.Dim_Product;

USE [e-Commerce];
GO

/*
   ===========================================================================
   STEP 5: DIMENSION MODELING - CUSTOMERS
   SCOPE: Create a reference table for unique customers.
   
   ADDED VALUE (The Senior Twist):
   We are pre-calculating 'First_Purchase' and 'Last_Purchase' here.
   This moves complexity from the Reporting Layer (DAX) to the Data Layer (SQL).
   ===========================================================================
*/

-- 1. Drop if exists
IF OBJECT_ID('dbo.Dim_Customer', 'U') IS NOT NULL
DROP TABLE dbo.Dim_Customer;
GO

-- 2. Create the Table
SELECT 
    CustomerID,
    
    -- Pick the Country associated with the customer
    -- (If they moved countries, we take the most recent one or Max)
    MAX(Country) AS Country,
    
    -- When did they first join? (Cohort Analysis)
    MIN(InvoiceDate) AS First_Purchase_Date,
    
    -- When did they last buy? (Churn Analysis)
    MAX(InvoiceDate) AS Last_Purchase_Date

INTO dbo.Dim_Customer
FROM dbo.Fact_Transactions
WHERE CustomerID <> 'Unknown' -- We usually exclude the "Guest" bucket from the CRM list
GROUP BY CustomerID;
GO

/*
   ===========================================================================
   VALIDATION
   Check how many unique identified customers we have.
   ===========================================================================
*/
SELECT COUNT(*) AS [Unique Customers] FROM dbo.Dim_Customer;
SELECT TOP 5 * FROM dbo.Dim_Customer ORDER BY First_Purchase_Date ASC;

SELECT   MAX(Country) AS Country FROM dbo.tbl_OnlineRetail_All
SELECT   Country AS Country FROM dbo.tbl_OnlineRetail_All
SELECT COUNT(Country) AS [Unique COUNTRY] FROM  dbo.tbl_OnlineRetail_All;
SELECT COUNT(DISTINCT Country) AS [Unique COUNTRY] FROM  dbo.tbl_OnlineRetail_All;

SELECT Invoice FROM dbo.tbl_OnlineRetail_All
WHERE Invoice LIKE 'c%';

/* 

This is the exact type of conversation that happens in a Senior Design Review. You are questioning the integrity of the join keys, which is critical.
The "Best Practice" Debate: Natural Keys vs. Surrogate Keys
You suggested: Creating a new column (Surrogate Key) using a window function.
My Verdict:
Ideally (Enterprise Level): You are 100% Correct. In a strict Kimball Data Warehouse, we rarely join 
on text strings (StockCode). We create an Integer ID (ProductKey) using ROW_NUMBER() or IDENTITY. 
It is faster and protects us if the business changes the StockCode format later.
However (The Immediate Problem): Your screenshot reveals a deeper data quality issue that a new 
ID won't fix.
Look closely at your screenshot.
In the Fact_Transactions preview, the StockCode column shows null.
If the StockCode in the Fact table is NULL, we cannot assign it a Product ID, even if we created one.
Power BI is rejecting the relationship because you have "Orphan Rows" in your Fact table 
(transactions with no valid product code).
The Diagnosis
The relationship failed because of Referential Integrity violations.
Nulls: The Fact table has NULL StockCodes.
Orphans: The Fact table might have a StockCode (e.g., "A1") that does not exist in your 
Dim_Product table.
The Fix (Step-by-Step)
We need to fix the data in SQL before we try to model it in Power BI. We will not add a
Surrogate Key yet (to keep the scope manageable), but we will enforce strict Referential Integrity.
Step 1: Investigate the NULLs
   INVESTIGATION: Why do we have NULL StockCodes? 
*/
SELECT TOP 20 * 
FROM dbo.tbl_OnlineRetail_All
WHERE StockCode IS NULL OR StockCode = '';

--Result has 20 recordes with NULL 

USE [e-Commerce];
GO

/*
   ===========================================================================
   RE-RUNNING STEP 3: STRICTER CLEANING
   Reason: Power BI relationship failed due to NULL StockCodes.
   Fix: Added explicit filter to remove rows where StockCode is NULL.
   ===========================================================================
*/

IF OBJECT_ID('dbo.Fact_Transactions', 'U') IS NOT NULL
DROP TABLE dbo.Fact_Transactions;
GO

SELECT 
    Invoice,
    TRIM(StockCode) AS StockCode, -- Ensure no spaces
    TRIM([Description]) AS [Description],
    Quantity,
    (Quantity * Price) AS SalesAmount,
    InvoiceDate,
    Price,
    CASE 
        WHEN CustomerID IS NULL THEN 'Unknown'
        ELSE CustomerID 
    END AS CustomerID,
    TRIM(Country) AS Country
INTO dbo.Fact_Transactions
FROM dbo.tbl_OnlineRetail_All
WHERE 
    Price > 0 
    AND Invoice IS NOT NULL
    AND StockCode IS NOT NULL -- <--- NEW STRICT RULE
    AND LEN(StockCode) > 0;   -- <--- Ensure it's not just an empty string
GO

-- Check the count again
SELECT COUNT(*) as CleanRows FROM dbo.Fact_Transactions;

/*
   ===========================================================================
   RE-RUNNING STEP 4: DIMENSION INTEGRITY
   Reason: Ensure Dim_Product contains EVERY code found in Fact_Transactions.
   ===========================================================================
*/

IF OBJECT_ID('dbo.Dim_Product', 'U') IS NOT NULL
DROP TABLE dbo.Dim_Product;
GO

SELECT 
    StockCode, 
    MAX([Description]) as [Description]
INTO dbo.Dim_Product
FROM dbo.Fact_Transactions -- Source from the CLEAN Fact table, not raw data
WHERE StockCode IS NOT NULL
GROUP BY StockCode;
GO

/* 
   DEBUGGING: Where did the returns go?
*/
SELECT 
    COUNT(*) as Total_Rows,
    COUNT(CASE WHEN Quantity < 0 THEN 1 END) as Return_Rows,
    MIN(Quantity) as Min_Qty,
    MAX(Quantity) as Max_Qty
FROM dbo.Fact_Transactions;

/*
   INVESTIGATION: Why were Returns filtered out?
   Let's look at the Raw Data for negative quantities.
*/
SELECT TOP 10 
    Invoice, 
    StockCode, 
    Description, 
    Quantity, 
    Price 
FROM dbo.tbl_OnlineRetail_All
WHERE Quantity < 0;

USE [e-Commerce];
GO

/*
   ===========================================================================
   FIXED SCRIPT: PERMISSIVE CLEANING
   Reason: Previous script deleted Returns because they had NULL Invoices.
   Fix: 
   1. If Invoice is NULL, replace with 'System_Adj'.
   2. If StockCode is NULL, replace with 'MANUAL'.
   3. Keep the row so we can calculate the Negative Revenue.
   ===========================================================================
*/

IF OBJECT_ID('dbo.Fact_Transactions', 'U') IS NOT NULL
DROP TABLE dbo.Fact_Transactions;
GO

SELECT 
    -- FIX 1: Handle Missing Invoices
    CASE 
        WHEN Invoice IS NULL THEN 'System_Adj' 
        ELSE Invoice 
    END AS Invoice,
    
    -- FIX 2: Handle Missing StockCodes
    CASE 
        WHEN StockCode IS NULL OR LEN(StockCode) = 0 THEN 'MANUAL' 
        ELSE TRIM(StockCode) 
    END AS StockCode,
    
    -- Keep Description Logic
    TRIM([Description]) AS [Description],
    
    Quantity,
    (Quantity * Price) AS SalesAmount,
    InvoiceDate,
    Price,
    
    -- Keep Customer Logic
    CASE 
        WHEN CustomerID IS NULL THEN 'Unknown'
        ELSE CustomerID 
    END AS CustomerID,
    
    TRIM(Country) AS Country

INTO dbo.Fact_Transactions
FROM dbo.tbl_OnlineRetail_All
WHERE 
    Price > 0 -- We still require a valid price
    AND InvoiceDate IS NOT NULL; -- We MUST have a date to show it on a chart
GO

-- FINAL CHECK: Do we have returns now?
SELECT 
    COUNT(*) as Total_Rows,
    COUNT(CASE WHEN Quantity < 0 THEN 1 END) as Return_Rows
FROM dbo.Fact_Transactions;

/* UPDATE DIMENSION TO INCLUDE NEW 'MANUAL' CODE */
IF OBJECT_ID('dbo.Dim_Product', 'U') IS NOT NULL
DROP TABLE dbo.Dim_Product;
GO

SELECT 
    StockCode, 
    MAX([Description]) as [Description]
INTO dbo.Dim_Product
FROM dbo.Fact_Transactions
GROUP BY StockCode;
GO