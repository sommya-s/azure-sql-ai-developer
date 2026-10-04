CREATE PROCEDURE sales.usp_PlaceOrder
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

    DECLARE @items TABLE (LineNumber smallint IDENTITY(1, 1) PRIMARY KEY, ProductID int, Quantity int);
    INSERT @items (ProductID, Quantity)
    SELECT productId, qty
    FROM OPENJSON(@Lines) WITH (productId int '$.productId', qty int '$.qty');

    IF EXISTS (SELECT 1 FROM @items AS l
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
        FROM @items AS l
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
