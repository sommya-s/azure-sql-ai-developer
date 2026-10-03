CREATE FUNCTION sales.fn_NetPrice (@UnitPrice decimal(10, 2), @Quantity int, @DiscountPct decimal(4, 2))
RETURNS decimal(12, 2)
WITH SCHEMABINDING, RETURNS NULL ON NULL INPUT
AS
BEGIN
    RETURN CAST(@Quantity * @UnitPrice * (1 - @DiscountPct) AS decimal(12, 2));
END;
