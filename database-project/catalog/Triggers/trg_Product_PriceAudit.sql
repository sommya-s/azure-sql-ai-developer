CREATE TRIGGER catalog.trg_Product_PriceAudit
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
