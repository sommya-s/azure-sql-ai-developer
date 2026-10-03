CREATE TABLE catalog.Product
(
    ProductID    int            NOT NULL CONSTRAINT PK_Product PRIMARY KEY CLUSTERED,
    SKU          varchar(20)    NOT NULL CONSTRAINT UQ_Product_SKU UNIQUE,
    ProductName  nvarchar(120)  NOT NULL,
    CategoryID   int            NOT NULL CONSTRAINT FK_Product_Category REFERENCES catalog.Category (CategoryID),
    Brand        nvarchar(60)   NOT NULL,
    ListPrice    decimal(10, 2) NOT NULL CONSTRAINT CK_Product_ListPrice CHECK (ListPrice >= 0),
    StandardCost decimal(10, 2) NOT NULL CONSTRAINT CK_Product_Cost CHECK (StandardCost >= 0),
    Attributes   json           NULL,
    Description  nvarchar(2000) NOT NULL,
    IsActive     bit            NOT NULL CONSTRAINT DF_Product_IsActive DEFAULT (1),
    CreatedAt    datetime2(0)   NOT NULL CONSTRAINT DF_Product_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_Product_Margin CHECK (ListPrice >= StandardCost)
);
GO
CREATE INDEX IX_Product_Category ON catalog.Product (CategoryID) INCLUDE (ListPrice, IsActive);
