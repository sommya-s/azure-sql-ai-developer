CREATE TABLE sales.SalesOrder
(
    OrderID      bigint       NOT NULL CONSTRAINT DF_SalesOrder_OrderID DEFAULT (NEXT VALUE FOR sales.OrderIDSeq)
                              CONSTRAINT PK_SalesOrder PRIMARY KEY CLUSTERED,
    OrderNumber  AS CONCAT('TH-', RIGHT(CONCAT('00000000', OrderID), 8)) PERSISTED,
    CustomerID   int          NOT NULL CONSTRAINT FK_SalesOrder_Customer REFERENCES crm.Customer (CustomerID),
    StoreID      int          NULL     CONSTRAINT FK_SalesOrder_Store REFERENCES sales.Store (StoreID),
    Channel      varchar(10)  NOT NULL CONSTRAINT CK_SalesOrder_Channel CHECK (Channel IN ('Store', 'Online')),
    SalesRegion  varchar(20)  NOT NULL,
    OrderDate    datetime2(0) NOT NULL,
    Status       varchar(12)  NOT NULL CONSTRAINT DF_SalesOrder_Status DEFAULT ('Placed')
                              CONSTRAINT CK_SalesOrder_Status CHECK (Status IN ('Placed', 'Shipped', 'Delivered', 'Cancelled', 'Returned')),
    ShippingInfo json         NULL,
    ModifiedAt   datetime2(0) NOT NULL CONSTRAINT DF_SalesOrder_ModifiedAt DEFAULT (SYSUTCDATETIME()),
    RowVer       rowversion   NOT NULL,
    CONSTRAINT CK_SalesOrder_StoreChannel CHECK ((Channel = 'Store' AND StoreID IS NOT NULL)
                                              OR (Channel = 'Online' AND StoreID IS NULL))
);
GO
CREATE UNIQUE INDEX UX_SalesOrder_OrderNumber ON sales.SalesOrder (OrderNumber);
GO
CREATE INDEX IX_SalesOrder_Customer_Cover ON sales.SalesOrder (CustomerID, OrderDate) INCLUDE (Status, Channel, ModifiedAt);
