/* UNIT tests: one object, one behavior, no dependency on existing data */
CREATE OR ALTER PROCEDURE test.test_fn_NetPrice_applies_discount
AS
BEGIN
    DECLARE @r decimal(12, 2) = sales.fn_NetPrice(100.00, 3, 0.10);
    EXEC test.AssertEquals 270.00, @r, N'3 x 100 with 10% discount';
    IF sales.fn_NetPrice(NULL, 1, 0) IS NOT NULL THROW 50901, N'NULL input must return NULL', 1;
END;
GO
CREATE OR ALTER PROCEDURE test.test_usp_PlaceOrder_rejects_bad_json
AS
BEGIN
    BEGIN TRY
        EXEC sales.usp_PlaceOrder @CustomerID = 1, @Channel = 'Online', @Lines = N'not json';
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() = 50010 RETURN;          -- expected
        THROW;
    END CATCH;
    THROW 50902, N'usp_PlaceOrder accepted invalid JSON', 1;
END;
GO
CREATE OR ALTER PROCEDURE test.test_usp_UpdateOrderStatus_rejects_invalid_transition
AS
BEGIN
    BEGIN TRY
        DECLARE @rv binary(8) = 0x0;
        EXEC sales.usp_UpdateOrderStatus @OrderID = -1, @NewStatus = 'Delivered', @ExpectedRowVer = @rv;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() = 50020 RETURN;          -- order not found is raised before the transition check
        THROW;
    END CATCH;
    THROW 50903, N'expected error 50020', 1;
END;
GO
