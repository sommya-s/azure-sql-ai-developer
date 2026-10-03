CREATE TABLE catalog.ProductReview
(
    ReviewID   int            NOT NULL CONSTRAINT PK_ProductReview PRIMARY KEY CLUSTERED,
    ProductID  int            NOT NULL CONSTRAINT FK_ProductReview_Product REFERENCES catalog.Product (ProductID),
    CustomerID int            NOT NULL CONSTRAINT FK_ProductReview_Customer REFERENCES crm.Customer (CustomerID),
    Rating     tinyint        NOT NULL CONSTRAINT CK_ProductReview_Rating CHECK (Rating BETWEEN 1 AND 5),
    Title      nvarchar(120)  NOT NULL,
    ReviewText nvarchar(4000) NOT NULL,
    ReviewDate date           NOT NULL,
    Language   char(2)        NOT NULL CONSTRAINT DF_ProductReview_Language DEFAULT ('en')
);
GO
CREATE INDEX IX_ProductReview_Product ON catalog.ProductReview (ProductID) INCLUDE (Rating);
