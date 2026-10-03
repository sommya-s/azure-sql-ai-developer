CREATE TABLE crm.Customer
(
    CustomerID           int           NOT NULL CONSTRAINT PK_Customer PRIMARY KEY CLUSTERED,
    CustomerCode         varchar(12)   NOT NULL CONSTRAINT UQ_Customer_Code UNIQUE,
    FirstName            nvarchar(50)  NOT NULL,
    LastName             nvarchar(50)  NOT NULL,
    Email                nvarchar(254) MASKED WITH (FUNCTION = 'email()') NULL,
    Phone                varchar(25)   MASKED WITH (FUNCTION = 'partial(4, "XXXXXXX", 2)') NULL,
    City                 nvarchar(60)  NOT NULL,
    Country              nvarchar(60)  NOT NULL,
    LoyaltyTier          varchar(10)   NOT NULL CONSTRAINT DF_Customer_Tier DEFAULT ('Bronze')
                                       CONSTRAINT CK_Customer_Tier CHECK (LoyaltyTier IN ('Bronze', 'Silver', 'Gold')),
    CreatedAt            datetime2(0)  NOT NULL CONSTRAINT DF_Customer_CreatedAt DEFAULT (SYSUTCDATETIME()),
    ReferredByCustomerID int           NULL CONSTRAINT FK_Customer_ReferredBy REFERENCES crm.Customer (CustomerID),
    ValidFrom            datetime2(2)  GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    ValidTo              datetime2(2)  GENERATED ALWAYS AS ROW END HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = crm.CustomerHistory, HISTORY_RETENTION_PERIOD = 2 YEARS));
GO
CREATE INDEX IX_Customer_Name ON crm.Customer (LastName, FirstName);
