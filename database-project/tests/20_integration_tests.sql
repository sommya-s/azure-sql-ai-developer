/* INTEGRATION tests: several objects together against a deployed database (CI container).
   Each test runs in a transaction and rolls back, so tests don't affect each other.            */
CREATE OR ALTER PROCEDURE test.test_reference_data_is_deployed
AS
BEGIN
    DECLARE @c int = (SELECT COUNT(*) FROM catalog.Category), @s int = (SELECT COUNT(*) FROM sales.Store);
    EXEC test.AssertEquals 19, @c, N'categories from post-deployment MERGE';
    EXEC test.AssertEquals 12, @s, N'stores from post-deployment MERGE';
END;
GO
CREATE OR ALTER PROCEDURE test.test_order_lifecycle
AS
BEGIN
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
        INSERT catalog.Product (ProductID, SKU, ProductName, CategoryID, Brand, ListPrice, StandardCost, Description)
        VALUES (-1, 'TEST-1', N'Test boot', 1, N'Test', 100, 50, N'test');
        INSERT crm.Customer (CustomerID, CustomerCode, FirstName, LastName, City, Country, LoyaltyTier)
        VALUES (-1, 'CTEST', N'Test', N'User', N'Riga', N'Latvia', 'Gold');

        DECLARE @id bigint;
        DECLARE @ignore TABLE (OrderID bigint, SalesRegion varchar(20));
        INSERT @ignore EXEC sales.usp_PlaceOrder @CustomerID = -1, @Channel = 'Online',
             @Lines = N'[{"productId":-1,"qty":2}]';
        SET @id = (SELECT OrderID FROM @ignore);

        DECLARE @total decimal(12, 2) = (SELECT SUM(LineTotal) FROM sales.SalesOrderLine WHERE OrderID = @id);
        EXEC test.AssertEquals 180.00, @total, N'Gold tier gets 10% off 2 x 100';
        DECLARE @region varchar(20) = (SELECT SalesRegion FROM sales.SalesOrder WHERE OrderID = @id);
        EXEC test.AssertEquals 'Baltics', @region, N'online order region from customer country';

        DECLARE @rv binary(8) = (SELECT RowVer FROM sales.SalesOrder WHERE OrderID = @id);
        EXEC sales.usp_UpdateOrderStatus @OrderID = @id, @NewStatus = 'Shipped', @ExpectedRowVer = @rv;
        DECLARE @st varchar(12) = (SELECT Status FROM sales.SalesOrder WHERE OrderID = @id);
        EXEC test.AssertEquals 'Shipped', @st, N'status transition';
    ROLLBACK TRANSACTION;
END;
GO
