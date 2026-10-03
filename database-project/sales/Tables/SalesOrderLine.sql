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
GO
CREATE INDEX IX_SalesOrderLine_Product ON sales.SalesOrderLine (ProductID);
GO
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_SalesOrderLine
    ON sales.SalesOrderLine (OrderID, ProductID, Quantity, UnitPrice, DiscountPct);
