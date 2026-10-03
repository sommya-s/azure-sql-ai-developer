CREATE TABLE sales.PriceAudit
(
    ProductID int            NOT NULL,
    OldPrice  decimal(10, 2) NULL,
    NewPrice  decimal(10, 2) NOT NULL,
    ChangedBy sysname        NOT NULL CONSTRAINT DF_PriceAudit_By DEFAULT (SUSER_SNAME()),
    ChangedAt datetime2(0)   NOT NULL CONSTRAINT DF_PriceAudit_At DEFAULT (SYSUTCDATETIME())
)
WITH (LEDGER = ON (APPEND_ONLY = ON));
