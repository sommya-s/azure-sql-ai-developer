CREATE TABLE dbo.ErrorLog
(
    ErrorLogID    int IDENTITY(1, 1) CONSTRAINT PK_ErrorLog PRIMARY KEY,
    LoggedAt      datetime2(0)   NOT NULL CONSTRAINT DF_ErrorLog_At DEFAULT (SYSUTCDATETIME()),
    UserName      sysname        NOT NULL CONSTRAINT DF_ErrorLog_User DEFAULT (SUSER_SNAME()),
    ProcedureName sysname        NULL,
    ErrorNumber   int            NULL,
    ErrorSeverity int            NULL,
    ErrorState    int            NULL,
    ErrorLine     int            NULL,
    ErrorMessage  nvarchar(4000) NULL
);
