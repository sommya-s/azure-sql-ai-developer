CREATE TABLE sales.Store
(
    StoreID   int          NOT NULL CONSTRAINT PK_Store PRIMARY KEY CLUSTERED,
    StoreCode varchar(10)  NOT NULL CONSTRAINT UQ_Store_Code UNIQUE,
    StoreName nvarchar(80) NOT NULL,
    City      nvarchar(60) NOT NULL,
    Country   nvarchar(60) NOT NULL,
    Region    varchar(20)  NOT NULL CONSTRAINT CK_Store_Region CHECK (Region IN ('Baltics', 'Nordics', 'Central Europe')),
    OpenedOn  date         NOT NULL
);
