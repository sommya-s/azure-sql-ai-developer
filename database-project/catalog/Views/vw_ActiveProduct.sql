CREATE VIEW catalog.vw_ActiveProduct
AS
SELECT ProductID, SKU, ProductName, CategoryID, Brand, ListPrice, Description
FROM catalog.Product
WHERE IsActive = 1;
