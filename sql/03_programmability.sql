/* =============================================================================================
   DP-800 · Lab 3 · 03_programmability.sql — Implement programmability objects
   ---------------------------------------------------------------------------------------------
   Exam skills: create views, scalar functions, table-valued functions, stored procedures, triggers.
   Also practised: error handling with TRY/CATCH + THROW, XACT_ABORT, OPENJSON input,
   optimistic concurrency with rowversion, indexed views, INSTEAD OF triggers.
   Prerequisite: 01_schema.sql and 02_seed_data.sql.
   ============================================================================================= */

/* ---------- 0. Error log used by the procedures ---------- */
IF OBJECT_ID(N'dbo.ErrorLog', N'U') IS NULL
CREATE TABLE dbo.ErrorLog
(
    ErrorLogID    int IDENTITY(1, 1) CONSTRAINT PK_ErrorLog PRIMARY KEY,
    LoggedAt      datetime2(0)   NOT NULL CONSTRAINT DF_ErrorLog_At DEFAULT (SYSUTCDATETIME()),
    UserName      sysname        NOT NULL CONSTRAINT DF_ErrorLog_User DEFAULT (SUSER_SNAME()),
    ProcedureName sysname        NULL,
    ErrorNumber   int            NULL,
    ErrorSeverity int            NULL,
    ErrorState    int            NULL,
    ErrorLine     int            NULL,
    ErrorMessage  nvarchar(4000) NULL
);
GO

/* =============================================================================================
   1. VIEWS
   ============================================================================================= */

-- 1a. A plain view: hides joins, exposes a stable contract to apps (and to Data API builder in lab 10b)
CREATE OR ALTER VIEW sales.vw_OrderSummary
AS
SELECT o.OrderID,
       o.OrderNumber,
       o.OrderDate,
       o.Channel,
       o.SalesRegion,
       o.Status,
       c.CustomerID,
       CONCAT(c.FirstName, N' ', c.LastName) AS CustomerName,
       s.StoreName,
       COUNT(l.LineNumber)                    AS LineCount,
       SUM(l.LineTotal)                       AS OrderTotal
FROM sales.SalesOrder AS o
JOIN crm.Customer AS c ON c.CustomerID = o.CustomerID
LEFT JOIN sales.Store AS s ON s.StoreID = o.StoreID
LEFT JOIN sales.SalesOrderLine AS l ON l.OrderID = o.OrderID
GROUP BY o.OrderID, o.OrderNumber, o.OrderDate, o.Channel, o.SalesRegion, o.Status,
         c.CustomerID, c.FirstName, c.LastName, s.StoreName;
GO

-- 1b. An INDEXED view: the aggregate is materialized and maintained on every write.
--     Rules: SCHEMABINDING, two-part names, COUNT_BIG(*) with GROUP BY, deterministic expressions,
--     SUM over non-nullable expressions. Great for hot dashboards; costs extra write overhead.
CREATE OR ALTER VIEW sales.vw_ProductSalesDaily
WITH SCHEMABINDING
AS
SELECT l.ProductID,
       CAST(o.OrderDate AS date)                             AS SalesDate,
       SUM(l.Quantity)                                       AS Units,
       SUM(l.Quantity * l.UnitPrice * (1 - l.DiscountPct))   AS NetSales,
       COUNT_BIG(*)                                          AS LineCount
FROM sales.SalesOrderLine AS l
JOIN sales.SalesOrder AS o ON o.OrderID = l.OrderID
WHERE o.Status <> 'Cancelled'
GROUP BY l.ProductID, CAST(o.OrderDate AS date);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UCX_vw_ProductSalesDaily')
    CREATE UNIQUE CLUSTERED INDEX UCX_vw_ProductSalesDaily ON sales.vw_ProductSalesDaily (ProductID, SalesDate);
GO

-- 1c. A view used as an updatable facade: deleting through it becomes a soft delete (trigger 5c)
CREATE OR ALTER VIEW catalog.vw_ActiveProduct
AS
SELECT ProductID, SKU, ProductName, CategoryID, Brand, ListPrice, Description
FROM catalog.Product
WHERE IsActive = 1;
GO

/* =============================================================================================
   2. SCALAR FUNCTION
   Scalar UDFs used to be row-by-row performance killers. Since SQL Server 2019 (compat >= 150)
   many are inlined automatically. Check sys.sql_modules.is_inlineable below.
   ============================================================================================= */
CREATE OR ALTER FUNCTION sales.fn_NetPrice (@UnitPrice decimal(10, 2), @Quantity int, @DiscountPct decimal(4, 2))
RETURNS decimal(12, 2)
WITH SCHEMABINDING, RETURNS NULL ON NULL INPUT
AS
BEGIN
    RETURN CAST(@Quantity * @UnitPrice * (1 - @DiscountPct) AS decimal(12, 2));
END;
GO

/* =============================================================================================
   3. TABLE-VALUED FUNCTIONS
   Inline TVF  = a parameterized view; the optimizer expands it into the outer query (good estimates).
   Multi-statement TVF = table variable filled procedurally; historically a fixed estimate of 1/100
   rows (interleaved execution helps in compat >= 140). Prefer inline when you can.
   ============================================================================================= */
CREATE OR ALTER FUNCTION sales.fn_CustomerOrders (@CustomerID int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT o.OrderID, o.OrderNumber, o.OrderDate, o.Status,
           SUM(l.LineTotal) AS OrderTotal,
           COUNT_BIG(*)     AS LineCount
    FROM sales.SalesOrder AS o
    JOIN sales.SalesOrderLine AS l ON l.OrderID = o.OrderID
    WHERE o.CustomerID = @CustomerID
    GROUP BY o.OrderID, o.OrderNumber, o.OrderDate, o.Status;
GO

CREATE OR ALTER FUNCTION catalog.fn_TopRatedProducts (@CategoryID int, @MinReviews int)
RETURNS @result TABLE
(
    ProductID   int           NOT NULL PRIMARY KEY,
    ProductName nvarchar(120) NOT NULL,
    AvgRating   decimal(3, 2) NOT NULL,
    Reviews     int           NOT NULL
)
AS
BEGIN
    INSERT @result (ProductID, ProductName, AvgRating, Reviews)
    SELECT p.ProductID, p.ProductName, CAST(AVG(CAST(r.Rating AS decimal(3, 2))) AS decimal(3, 2)), COUNT(*)
    FROM catalog.Product AS p
    JOIN catalog.ProductReview AS r ON r.ProductID = p.ProductID
    WHERE p.CategoryID = @CategoryID
    GROUP BY p.ProductID, p.ProductName
    HAVING COUNT(*) >= @MinReviews;
    RETURN;
END;
GO

/* =============================================================================================
   4. STORED PROCEDURES
   ============================================================================================= */

-- 4a. Place an order from a JSON payload. Shows: input validation, THROW, XACT_ABORT, a transaction,
--     sequence use, TRY/CATCH that logs and re-throws, OUTPUT parameter.
CREATE OR ALTER PROCEDURE sales.usp_PlaceOrder
    @CustomerID int,
    @Channel    varchar(10),
    @StoreID    int = NULL,
    @Lines      nvarchar(max),          -- '[{"productId":12,"qty":2},{"productId":40,"qty":1}]'
    @OrderID    bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;      -- any runtime error dooms and rolls back the transaction

    IF ISJSON(@Lines, ARRAY) = 0
        THROW 50010, N'@Lines must be a JSON array like [{"productId":1,"qty":1}].', 1;
    IF NOT EXISTS (SELECT 1 FROM crm.Customer WHERE CustomerID = @CustomerID)
        THROW 50011, N'Unknown customer.', 1;

    DECLARE @lines TABLE (LineNumber smallint IDENTITY(1, 1) PRIMARY KEY, ProductID int, Quantity int);
    INSERT @lines (ProductID, Quantity)
    SELECT productId, qty
    FROM OPENJSON(@Lines) WITH (productId int '$.productId', qty int '$.qty');

    IF EXISTS (SELECT 1 FROM @lines AS l
               LEFT JOIN catalog.Product AS p ON p.ProductID = l.ProductID
               WHERE p.ProductID IS NULL OR p.IsActive = 0)
        THROW 50012, N'One or more products are unknown or inactive.', 1;

    DECLARE @region varchar(20) =
        CASE WHEN @Channel = 'Store'
             THEN (SELECT Region FROM sales.Store WHERE StoreID = @StoreID)
             ELSE (SELECT TOP (1) s.Region FROM crm.Customer AS c JOIN sales.Store AS s ON s.Country = c.Country
                   WHERE c.CustomerID = @CustomerID)
        END;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @OrderID = NEXT VALUE FOR sales.OrderIDSeq;

        INSERT sales.SalesOrder (OrderID, CustomerID, StoreID, Channel, SalesRegion, OrderDate, Status)
        VALUES (@OrderID, @CustomerID, @StoreID, @Channel, @region, SYSUTCDATETIME(), 'Placed');

        INSERT sales.SalesOrderLine (OrderID, LineNumber, ProductID, Quantity, UnitPrice, DiscountPct)
        SELECT @OrderID, l.LineNumber, l.ProductID, l.Quantity, p.ListPrice,
               CASE c.LoyaltyTier WHEN 'Gold' THEN 0.10 WHEN 'Silver' THEN 0.05 ELSE 0 END
        FROM @lines AS l
        JOIN catalog.Product AS p ON p.ProductID = l.ProductID
        CROSS JOIN (SELECT LoyaltyTier FROM crm.Customer WHERE CustomerID = @CustomerID) AS c;

        COMMIT TRANSACTION;

        -- Also return the key as a result set: Data API builder exposes the FIRST result set of a
        -- procedure (OUTPUT parameters aren't returned by DAB).
        SELECT @OrderID AS OrderID, @region AS SalesRegion;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;     -- -1 = doomed, 1 = committable; roll back either way

        INSERT dbo.ErrorLog (ProcedureName, ErrorNumber, ErrorSeverity, ErrorState, ErrorLine, ErrorMessage)
        VALUES (ERROR_PROCEDURE(), ERROR_NUMBER(), ERROR_SEVERITY(), ERROR_STATE(), ERROR_LINE(), ERROR_MESSAGE());

        SET @OrderID = NULL;
        THROW;                                          -- re-raise the original error to the caller
    END CATCH;
END;
GO

-- 4b. Optimistic concurrency: the caller sends the rowversion it read; the update only succeeds
--     if nobody changed the row in between. No locks are held while the user is "thinking".
CREATE OR ALTER PROCEDURE sales.usp_UpdateOrderStatus
    @OrderID        bigint,
    @NewStatus      varchar(12),
    @ExpectedRowVer binary(8)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @current varchar(12) = (SELECT Status FROM sales.SalesOrder WHERE OrderID = @OrderID);

    IF @current IS NULL
        THROW 50020, N'Order not found.', 1;
    IF NOT ((@current = 'Placed'    AND @NewStatus IN ('Shipped', 'Cancelled'))
         OR (@current = 'Shipped'   AND @NewStatus = 'Delivered')
         OR (@current = 'Delivered' AND @NewStatus = 'Returned'))
        THROW 50021, N'Invalid status transition.', 1;

    UPDATE sales.SalesOrder
    SET Status = @NewStatus, ModifiedAt = SYSUTCDATETIME()
    WHERE OrderID = @OrderID AND RowVer = @ExpectedRowVer;

    IF @@ROWCOUNT = 0
        THROW 50022, N'The order was changed by someone else. Reload it and try again.', 1;
END;
GO

/* =============================================================================================
   5. TRIGGERS
   Always write triggers set-based: inserted/deleted can hold many rows.
   ============================================================================================= */

-- 5a. AFTER UPDATE: every price change is written to the append-only LEDGER table (tamper-evident audit)
--     Fabric SQL database has no ledger tables: point the INSERT at a normal table there.
CREATE OR ALTER TRIGGER catalog.trg_Product_PriceAudit
ON catalog.Product
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(ListPrice) RETURN;

    INSERT sales.PriceAudit (ProductID, OldPrice, NewPrice)
    SELECT i.ProductID, d.ListPrice, i.ListPrice
    FROM inserted AS i
    JOIN deleted AS d ON d.ProductID = i.ProductID
    WHERE i.ListPrice <> d.ListPrice;
END;
GO

-- 5b. AFTER UPDATE: keep ModifiedAt honest even when an app forgets to set it.
--     RECURSIVE_TRIGGERS is OFF by default, so the UPDATE inside does not re-fire this trigger.
CREATE OR ALTER TRIGGER sales.trg_SalesOrder_ModifiedAt
ON sales.SalesOrder
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(ModifiedAt) RETURN;
    UPDATE o SET ModifiedAt = SYSUTCDATETIME()
    FROM sales.SalesOrder AS o
    JOIN inserted AS i ON i.OrderID = o.OrderID;
END;
GO

-- 5c. INSTEAD OF DELETE on a view: DELETE through the view becomes a soft delete.
CREATE OR ALTER TRIGGER catalog.trg_vw_ActiveProduct_SoftDelete
ON catalog.vw_ActiveProduct
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE p SET IsActive = 0
    FROM catalog.Product AS p
    JOIN deleted AS d ON d.ProductID = p.ProductID;
END;
GO

/* =============================================================================================
   6. TRY IT — run these one block at a time and read the results/messages
   ============================================================================================= */

-- 6a. Views and functions
SELECT TOP (5) * FROM sales.vw_OrderSummary ORDER BY OrderTotal DESC;
SELECT TOP (5) * FROM sales.vw_ProductSalesDaily WITH (NOEXPAND) ORDER BY NetSales DESC;  -- read the index directly
SELECT * FROM sales.fn_CustomerOrders(42) ORDER BY OrderDate;
SELECT * FROM catalog.fn_TopRatedProducts(1, 3) ORDER BY AvgRating DESC;
SELECT sales.fn_NetPrice(100.00, 3, 0.10) AS NetPrice;
SELECT OBJECT_NAME(object_id) AS FunctionName, is_inlineable
FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'sales.fn_NetPrice');
GO

-- 6b. Place a valid order
DECLARE @id bigint;
EXEC sales.usp_PlaceOrder @CustomerID = 42, @Channel = 'Online',
     @Lines = N'[{"productId":1,"qty":1},{"productId":14,"qty":2}]', @OrderID = @id OUTPUT;
SELECT * FROM sales.vw_OrderSummary WHERE OrderID = @id;
GO

-- 6c. Place an INVALID order (qty = 0 violates CK_SalesOrderLine_Qty). The error is logged, then re-thrown.
DECLARE @id bigint;
BEGIN TRY
    EXEC sales.usp_PlaceOrder @CustomerID = 42, @Channel = 'Online',
         @Lines = N'[{"productId":1,"qty":0}]', @OrderID = @id OUTPUT;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrNo, ERROR_MESSAGE() AS ErrMsg;
END CATCH;
SELECT TOP (3) * FROM dbo.ErrorLog ORDER BY ErrorLogID DESC;
-- Question: why is there no half-inserted order header left behind?
GO

-- 6d. Optimistic concurrency: read the rowversion, then update twice with the SAME value
DECLARE @id bigint = (SELECT MAX(OrderID) FROM sales.SalesOrder WHERE Status = 'Placed');
DECLARE @rv binary(8) = (SELECT RowVer FROM sales.SalesOrder WHERE OrderID = @id);
EXEC sales.usp_UpdateOrderStatus @OrderID = @id, @NewStatus = 'Shipped', @ExpectedRowVer = @rv;    -- succeeds
BEGIN TRY
    EXEC sales.usp_UpdateOrderStatus @OrderID = @id, @NewStatus = 'Delivered', @ExpectedRowVer = @rv; -- stale -> 50022
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrNo, ERROR_MESSAGE() AS ErrMsg;
END CATCH;
GO

-- 6e. Triggers: change a price, look at the ledger; soft-delete through the view
UPDATE catalog.Product SET ListPrice = ListPrice + 5 WHERE ProductID IN (3, 4);
SELECT * FROM sales.PriceAudit ORDER BY ChangedAt DESC;
-- Ledger tables are append-only: this fails with an error. Try it.
-- UPDATE sales.PriceAudit SET NewPrice = 1;
SELECT ledger_start_transaction_id, ProductID, NewPrice FROM sales.PriceAudit;   -- hidden ledger columns
GO
DELETE FROM catalog.vw_ActiveProduct WHERE ProductID = 239;
SELECT ProductID, IsActive FROM catalog.Product WHERE ProductID = 239;
UPDATE catalog.Product SET IsActive = 1 WHERE ProductID = 239;   -- undo
GO
