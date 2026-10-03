CREATE TABLE catalog.Category
(
    CategoryID   int          NOT NULL CONSTRAINT PK_Category PRIMARY KEY CLUSTERED,
    CategoryName nvarchar(60) NOT NULL CONSTRAINT UQ_Category_Name UNIQUE,
    Department   nvarchar(40) NOT NULL
);
