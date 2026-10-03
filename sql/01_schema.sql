/* =============================================================================================
   DP-800 · Lab 1 · 01_schema.sql — Design and implement database objects
   ---------------------------------------------------------------------------------------------
   Exam skills: tables (data types, size, columns, indexes, columnstore), specialized tables
   (in-memory, temporal, external, ledger, graph), JSON columns + JSON index, constraints
   (PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK, DEFAULT), SEQUENCES, partitioning.

   Target: Azure SQL Database (free offer) or SQL Server 2025 Developer edition.
   SQL database in Microsoft Fabric: run everything EXCEPT blocks marked [NOT IN FABRIC SQL DB]
   (ledger and in-memory tables are not supported there; partition SWITCH is blocked).

   Re-runnable: drops the lab objects first. Run in a NEW, EMPTY database named TrailheadOps.
   ============================================================================================= */

-- Compatibility level 170 unlocks SQL Server 2025-era T-SQL (REGEXP_*, JSON_ARRAYAGG, vector, ...)
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170;
GO
-- SQL Server 2025: vector indexes, fuzzy-match functions and a few others are preview features.
-- (On Azure SQL Database / Fabric SQL database the GA features don't need this; harmless if accepted.)
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

/* ---------- 0. Clean up (reverse dependency order) ---------- */
-- Objects from later labs that are schema-bound to these tables must be dropped first
DROP SECURITY POLICY IF EXISTS sec.SalesRegionFilter;
DROP VIEW IF EXISTS sales.vw_ProductSalesDaily;
DROP FUNCTION IF EXISTS sales.fn_CustomerOrders, sec.fn_SalesRegionPredicate;
GO
IF OBJECT_ID(N'crm.Customer', N'U') IS NOT NULL AND OBJECTPROPERTY(OBJECT_ID(N'crm.Customer'), N'TableTemporalType') = 2
    ALTER TABLE crm.Customer SET (SYSTEM_VERSIONING = OFF);
GO
DROP TABLE IF EXISTS kg.Referred, kg.BoughtWith, kg.CustomerNode, kg.ProductNode;
DROP TABLE IF EXISTS support.Ticket, catalog.ProductReview, sales.SalesOrderLine, sales.SalesOrder;
DROP TABLE IF EXISTS crm.CustomerPII, crm.Customer, crm.CustomerHistory;
DROP TABLE IF EXISTS catalog.Product, catalog.Category, sales.Store, sales.WebEvent;
DROP TABLE IF EXISTS sales.PriceAudit;   -- dropping a ledger table keeps it as a "dropped ledger table" (by design)
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = N'ps_EventMonth') DROP PARTITION SCHEME ps_EventMonth;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = N'pf_EventMonth') DROP PARTITION FUNCTION pf_EventMonth;
DROP SEQUENCE IF EXISTS sales.OrderIDSeq;
GO

/* ---------- 1. Schemas: group objects by domain, and grant permissions per schema later ---------- */
IF SCHEMA_ID(N'catalog') IS NULL EXEC (N'CREATE SCHEMA catalog');
IF SCHEMA_ID(N'crm')     IS NULL EXEC (N'CREATE SCHEMA crm');
IF SCHEMA_ID(N'sales')   IS NULL EXEC (N'CREATE SCHEMA sales');
IF SCHEMA_ID(N'support') IS NULL EXEC (N'CREATE SCHEMA support');
IF SCHEMA_ID(N'kg')      IS NULL EXEC (N'CREATE SCHEMA kg');      -- graph ("knowledge graph")
IF SCHEMA_ID(N'ai')      IS NULL EXEC (N'CREATE SCHEMA ai');      -- embeddings, search, RAG (labs 7-10)
IF SCHEMA_ID(N'sec')     IS NULL EXEC (N'CREATE SCHEMA sec');     -- security predicates (lab 5)
GO

/* ---------- 2. SEQUENCE: a key generator shared outside a single table (vs IDENTITY) ----------
   Why a sequence here? The app can fetch the next order number BEFORE inserting (e.g., to show it
   to the customer), and CACHE trades gap-free numbering for throughput. Exam: know NEXT VALUE FOR,
   sp_sequence_get_range, CACHE/NO CACHE, CYCLE, and that both IDENTITY and SEQUENCE can have gaps. */
CREATE SEQUENCE sales.OrderIDSeq AS bigint START WITH 100001 INCREMENT BY 1 CACHE 50;
GO

/* ---------- 3. Reference tables ---------- */
CREATE TABLE catalog.Category
(
    CategoryID   int          NOT NULL CONSTRAINT PK_Category PRIMARY KEY CLUSTERED,
    CategoryName nvarchar(60) NOT NULL CONSTRAINT UQ_Category_Name UNIQUE,
    Department   nvarchar(40) NOT NULL
);

CREATE TABLE sales.Store
(
    StoreID   int           NOT NULL CONSTRAINT PK_Store PRIMARY KEY CLUSTERED,
    StoreCode varchar(10)   NOT NULL CONSTRAINT UQ_Store_Code UNIQUE,   -- varchar: codes are ASCII
    StoreName nvarchar(80)  NOT NULL,                                    -- nvarchar: names can hold any script
    City      nvarchar(60)  NOT NULL,
    Country   nvarchar(60)  NOT NULL,
    Region    varchar(20)   NOT NULL CONSTRAINT CK_Store_Region CHECK (Region IN ('Baltics', 'Nordics', 'Central Europe')),
    OpenedOn  date          NOT NULL
);
GO

/* ---------- 4. Product: JSON column + JSON index ----------
   decimal(10,2) for money (exact), never float. The json type validates on write and is stored in
   a binary format; JSON_VALUE / JSON_CONTAINS can use the JSON index below. */
CREATE TABLE catalog.Product
(
    ProductID    int            NOT NULL CONSTRAINT PK_Product PRIMARY KEY CLUSTERED,
    SKU          varchar(20)    NOT NULL CONSTRAINT UQ_Product_SKU UNIQUE,
    ProductName  nvarchar(120)  NOT NULL,
    CategoryID   int            NOT NULL CONSTRAINT FK_Product_Category REFERENCES catalog.Category (CategoryID),
    Brand        nvarchar(60)   NOT NULL,
    ListPrice    decimal(10, 2) NOT NULL CONSTRAINT CK_Product_ListPrice CHECK (ListPrice >= 0),
    StandardCost decimal(10, 2) NOT NULL CONSTRAINT CK_Product_Cost CHECK (StandardCost >= 0),
    Attributes   json           NULL,
    Description  nvarchar(2000) NOT NULL,
    IsActive     bit            NOT NULL CONSTRAINT DF_Product_IsActive DEFAULT (1),
    CreatedAt    datetime2(0)   NOT NULL CONSTRAINT DF_Product_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_Product_Margin CHECK (ListPrice >= StandardCost)          -- table-level CHECK across columns
);
CREATE INDEX IX_Product_Category ON catalog.Product (CategoryID) INCLUDE (ListPrice, IsActive);
GO
-- JSON index (needs a clustered PK and a json column). Paths must not overlap.
-- If your platform version reports it as unsupported, skip it: queries still work, just without the index.
CREATE JSON INDEX JX_Product_Attributes ON catalog.Product (Attributes)
    FOR ('$.waterproof', '$.colors', '$.sizes', '$.season');
GO

/* ---------- 5. Customer: system-versioned TEMPORAL table ----------
   Every UPDATE/DELETE writes the old row version to crm.CustomerHistory automatically.
   Query with FOR SYSTEM_TIME AS OF / BETWEEN / ALL (lab 4). HIDDEN keeps SELECT * clean. */
CREATE TABLE crm.Customer
(
    CustomerID           int           NOT NULL CONSTRAINT PK_Customer PRIMARY KEY CLUSTERED,
    CustomerCode         varchar(12)   NOT NULL CONSTRAINT UQ_Customer_Code UNIQUE,
    FirstName            nvarchar(50)  NOT NULL,
    LastName             nvarchar(50)  NOT NULL,
    Email                nvarchar(254) NULL,
    Phone                varchar(25)   NULL,
    City                 nvarchar(60)  NOT NULL,
    Country              nvarchar(60)  NOT NULL,
    LoyaltyTier          varchar(10)   NOT NULL CONSTRAINT DF_Customer_Tier DEFAULT ('Bronze')
                                       CONSTRAINT CK_Customer_Tier CHECK (LoyaltyTier IN ('Bronze', 'Silver', 'Gold')),
    CreatedAt            datetime2(0)  NOT NULL CONSTRAINT DF_Customer_CreatedAt DEFAULT (SYSUTCDATETIME()),
    ReferredByCustomerID int           NULL CONSTRAINT FK_Customer_ReferredBy REFERENCES crm.Customer (CustomerID),
    ValidFrom            datetime2(2)  GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    ValidTo              datetime2(2)  GENERATED ALWAYS AS ROW END HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = crm.CustomerHistory, HISTORY_RETENTION_PERIOD = 2 YEARS));
CREATE INDEX IX_Customer_Name ON crm.Customer (LastName, FirstName);
GO

/* ---------- 6. Orders: SEQUENCE default, persisted computed column, JSON, rowversion ---------- */
CREATE TABLE sales.SalesOrder
(
    OrderID      bigint       NOT NULL CONSTRAINT DF_SalesOrder_OrderID DEFAULT (NEXT VALUE FOR sales.OrderIDSeq)
                              CONSTRAINT PK_SalesOrder PRIMARY KEY CLUSTERED,
    OrderNumber  AS CONCAT('TH-', RIGHT(CONCAT('00000000', OrderID), 8)) PERSISTED,   -- deterministic -> can be indexed
    CustomerID   int          NOT NULL CONSTRAINT FK_SalesOrder_Customer REFERENCES crm.Customer (CustomerID),
    StoreID      int          NULL     CONSTRAINT FK_SalesOrder_Store REFERENCES sales.Store (StoreID),
    Channel      varchar(10)  NOT NULL CONSTRAINT CK_SalesOrder_Channel CHECK (Channel IN ('Store', 'Online')),
    SalesRegion  varchar(20)  NOT NULL,
    OrderDate    datetime2(0) NOT NULL,
    Status       varchar(12)  NOT NULL CONSTRAINT DF_SalesOrder_Status DEFAULT ('Placed')
                              CONSTRAINT CK_SalesOrder_Status CHECK (Status IN ('Placed', 'Shipped', 'Delivered', 'Cancelled', 'Returned')),
    ShippingInfo json         NULL,
    ModifiedAt   datetime2(0) NOT NULL CONSTRAINT DF_SalesOrder_ModifiedAt DEFAULT (SYSUTCDATETIME()),
    RowVer       rowversion   NOT NULL,                                       -- optimistic concurrency (lab 6)
    CONSTRAINT CK_SalesOrder_StoreChannel CHECK ((Channel = 'Store' AND StoreID IS NOT NULL)
                                              OR (Channel = 'Online' AND StoreID IS NULL))
);
CREATE UNIQUE INDEX UX_SalesOrder_OrderNumber ON sales.SalesOrder (OrderNumber);
CREATE INDEX IX_SalesOrder_Customer ON sales.SalesOrder (CustomerID, OrderDate) INCLUDE (Status);
GO

CREATE TABLE sales.SalesOrderLine
(
    OrderID     bigint         NOT NULL CONSTRAINT FK_SalesOrderLine_Order REFERENCES sales.SalesOrder (OrderID) ON DELETE CASCADE,
    LineNumber  smallint       NOT NULL,
    ProductID   int            NOT NULL CONSTRAINT FK_SalesOrderLine_Product REFERENCES catalog.Product (ProductID),
    Quantity    int            NOT NULL CONSTRAINT CK_SalesOrderLine_Qty CHECK (Quantity > 0),
    UnitPrice   decimal(10, 2) NOT NULL CONSTRAINT CK_SalesOrderLine_Price CHECK (UnitPrice >= 0),
    DiscountPct decimal(4, 2)  NOT NULL CONSTRAINT DF_SalesOrderLine_Discount DEFAULT (0)
                               CONSTRAINT CK_SalesOrderLine_Discount CHECK (DiscountPct BETWEEN 0 AND 0.5),
    LineTotal   AS CAST(Quantity * UnitPrice * (1 - DiscountPct) AS decimal(12, 2)) PERSISTED,
    CONSTRAINT PK_SalesOrderLine PRIMARY KEY CLUSTERED (OrderID, LineNumber)
);
CREATE INDEX IX_SalesOrderLine_Product ON sales.SalesOrderLine (ProductID);
-- Nonclustered columnstore = real-time operational analytics (HTAP): OLTP stays on the rowstore,
-- aggregations scan the compressed column segments in batch mode. Computed columns can't be included.
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_SalesOrderLine
    ON sales.SalesOrderLine (OrderID, ProductID, Quantity, UnitPrice, DiscountPct);
GO

/* ---------- 7. Text-heavy tables used for full-text, vector and RAG labs ---------- */
CREATE TABLE catalog.ProductReview
(
    ReviewID   int            NOT NULL CONSTRAINT PK_ProductReview PRIMARY KEY CLUSTERED,
    ProductID  int            NOT NULL CONSTRAINT FK_ProductReview_Product REFERENCES catalog.Product (ProductID),
    CustomerID int            NOT NULL CONSTRAINT FK_ProductReview_Customer REFERENCES crm.Customer (CustomerID),
    Rating     tinyint        NOT NULL CONSTRAINT CK_ProductReview_Rating CHECK (Rating BETWEEN 1 AND 5),
    Title      nvarchar(120)  NOT NULL,
    ReviewText nvarchar(4000) NOT NULL,
    ReviewDate date           NOT NULL,
    Language   char(2)        NOT NULL CONSTRAINT DF_ProductReview_Language DEFAULT ('en')
);
CREATE INDEX IX_ProductReview_Product ON catalog.ProductReview (ProductID) INCLUDE (Rating);

CREATE TABLE support.Ticket
(
    TicketID   int            NOT NULL CONSTRAINT PK_Ticket PRIMARY KEY CLUSTERED,
    CustomerID int            NOT NULL CONSTRAINT FK_Ticket_Customer REFERENCES crm.Customer (CustomerID),
    ProductID  int            NULL     CONSTRAINT FK_Ticket_Product REFERENCES catalog.Product (ProductID),
    OrderID    bigint         NULL     CONSTRAINT FK_Ticket_Order REFERENCES sales.SalesOrder (OrderID),
    OpenedAt   datetime2(0)   NOT NULL,
    Channel    varchar(10)    NOT NULL CONSTRAINT CK_Ticket_Channel CHECK (Channel IN ('Email', 'Chat', 'Phone')),
    Subject    nvarchar(200)  NOT NULL,
    Body       nvarchar(4000) NOT NULL,
    Status     varchar(10)    NOT NULL CONSTRAINT CK_Ticket_Status CHECK (Status IN ('Open', 'Pending', 'Resolved', 'Closed')),
    Priority   varchar(10)    NOT NULL CONSTRAINT CK_Ticket_Priority CHECK (Priority IN ('Low', 'Medium', 'High', 'Urgent'))
);
GO

/* ---------- 8. LEDGER table [NOT IN FABRIC SQL DB] ----------
   Append-only ledger: rows can only be inserted; every transaction is hashed into a tamper-evident
   chain (verify with sys.sp_verify_database_ledger). Populated by the price-change trigger in lab 3.
   Updatable ledger tables (LEDGER = ON without APPEND_ONLY) keep history like temporal tables. */
CREATE TABLE sales.PriceAudit
(
    ProductID int            NOT NULL,
    OldPrice  decimal(10, 2) NULL,
    NewPrice  decimal(10, 2) NOT NULL,
    ChangedBy sysname        NOT NULL CONSTRAINT DF_PriceAudit_By DEFAULT (SUSER_SNAME()),
    ChangedAt datetime2(0)   NOT NULL CONSTRAINT DF_PriceAudit_At DEFAULT (SYSUTCDATETIME())
)
WITH (LEDGER = ON (APPEND_ONLY = ON));
GO

/* ---------- 9. PARTITIONING + clustered columnstore: web events by month ----------
   RANGE RIGHT: each boundary value belongs to the partition on its right (first day of month).
   Azure SQL Database only has the PRIMARY filegroup, so ALL TO ([PRIMARY]).
   Lab 6 uses this table for partition elimination, SPLIT/MERGE and (outside Fabric) SWITCH. */
CREATE PARTITION FUNCTION pf_EventMonth (date)
    AS RANGE RIGHT FOR VALUES ('2026-07-01', '2026-08-01', '2026-09-01', '2026-10-01');
CREATE PARTITION SCHEME ps_EventMonth AS PARTITION pf_EventMonth ALL TO ([PRIMARY]);
GO
CREATE TABLE sales.WebEvent
(
    EventID    varchar(30)   NOT NULL,
    EventDate  date          NOT NULL,
    EventTime  datetime2(0)  NOT NULL,
    SessionID  varchar(20)   NOT NULL,
    CustomerID int           NULL,
    EventType  varchar(20)   NOT NULL,
    ProductID  int           NULL,
    Device     varchar(10)   NOT NULL,
    DurationMs int           NOT NULL,
    INDEX CCI_WebEvent CLUSTERED COLUMNSTORE
)
ON ps_EventMonth (EventDate);
GO
-- ~300k synthetic events across July-September so partitions and columnstore have real work to do
;WITH n AS (
    SELECT value AS i,
           CAST((CAST(value AS bigint) * 7919) % (92 * 86400) AS int) AS secs   -- bigint math avoids int overflow
    FROM GENERATE_SERIES(1, 300000)
)
INSERT INTO sales.WebEvent (EventID, EventDate, EventTime, SessionID, CustomerID, EventType, ProductID, Device, DurationMs)
SELECT CONCAT('E', i),
       CAST(DATEADD(SECOND, secs, CAST('2026-07-01' AS datetime2(0))) AS date),
       DATEADD(SECOND, secs, CAST('2026-07-01' AS datetime2(0))),
       CONCAT('S', i / 6),
       CASE WHEN i % 5 = 0 THEN NULL ELSE 1 + (i * 31) % 1200 END,
       CHOOSE(1 + i % 6, 'page_view', 'search', 'product_view', 'product_view', 'add_to_cart', 'purchase'),
       CASE WHEN i % 6 IN (2, 3, 4) THEN 1 + (i * 17) % 240 END,
       CHOOSE(1 + i % 3, 'mobile', 'desktop', 'tablet'),
       200 + (i * 13) % 9000
FROM n;
GO

/* ---------- 10. GRAPH tables: who referred whom, which products are bought together ----------
   NODE and EDGE tables get $node_id / $from_id / $to_id pseudo-columns. Populated in lab 4. */
CREATE TABLE kg.CustomerNode (CustomerID int NOT NULL PRIMARY KEY, DisplayName nvarchar(120) NOT NULL) AS NODE;
CREATE TABLE kg.ProductNode (ProductID int NOT NULL PRIMARY KEY, ProductName nvarchar(120) NOT NULL) AS NODE;
CREATE TABLE kg.Referred
(
    ReferredOn date NULL,
    CONSTRAINT EC_Referred CONNECTION (kg.CustomerNode TO kg.CustomerNode)   -- edge constraint
) AS EDGE;
CREATE TABLE kg.BoughtWith
(
    TimesTogether int NOT NULL,
    CONSTRAINT EC_BoughtWith CONNECTION (kg.ProductNode TO kg.ProductNode)
) AS EDGE;
GO

/* ---------- 11. IN-MEMORY OLTP table [NOT IN FABRIC SQL DB; Azure SQL: Premium/Business Critical only] ----------
   Uncomment on SQL Server 2025 (needs a MEMORY_OPTIMIZED_DATA filegroup) or Business Critical.
   Good fit: hot, short-lived rows (session carts), latch contention, tempdb replacement.

-- SQL Server only: ALTER DATABASE CURRENT ADD FILEGROUP imoltp CONTAINS MEMORY_OPTIMIZED_DATA;
--                  ALTER DATABASE CURRENT ADD FILE (NAME = 'imoltp1', FILENAME = '/var/opt/mssql/data/imoltp1') TO FILEGROUP imoltp;
CREATE TABLE sales.CartSession
(
    SessionID  varchar(20)  NOT NULL PRIMARY KEY NONCLUSTERED HASH WITH (BUCKET_COUNT = 1048576),
    CustomerID int          NULL,
    CartJson   nvarchar(4000) NOT NULL,
    UpdatedAt  datetime2(0) NOT NULL INDEX IX_UpdatedAt NONCLUSTERED
)
WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_ONLY);   -- SCHEMA_ONLY: data lost on restart, zero log IO
*/

/* ---------- 12. EXTERNAL table (data virtualization) — optional, needs a storage account ----------
   Query Parquet files in ADLS/OneLake without loading them. On Azure SQL Database:

CREATE DATABASE SCOPED CREDENTIAL StorageMI WITH IDENTITY = 'Managed Identity';
CREATE EXTERNAL DATA SOURCE LakeArchive WITH (LOCATION = 'abfss://archive@<account>.dfs.core.windows.net', CREDENTIAL = StorageMI);
CREATE EXTERNAL FILE FORMAT ParquetFF WITH (FORMAT_TYPE = PARQUET);
CREATE EXTERNAL TABLE sales.OrderArchive
(
    OrderID bigint, CustomerID int, OrderDate datetime2(0), NetAmount decimal(12, 2)
)
WITH (LOCATION = '/orders/2025/', DATA_SOURCE = LakeArchive, FILE_FORMAT = ParquetFF);

-- Ad hoc alternative without creating a table:
SELECT TOP (10) * FROM OPENROWSET(BULK '/orders/2025/*.parquet', DATA_SOURCE = 'LakeArchive', FORMAT = 'parquet') AS o;
*/

/* ---------- 13. Check your work ---------- */
SELECT s.name AS SchemaName, t.name AS TableName,
       t.temporal_type_desc, t.ledger_type_desc, t.is_memory_optimized,
       t.is_node, t.is_edge,
       (SELECT COUNT(*) FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)) AS Partitions
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
ORDER BY s.name, t.name;
GO
