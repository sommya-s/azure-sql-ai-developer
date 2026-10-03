CREATE PROCEDURE sales.usp_UpdateOrderStatus
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
