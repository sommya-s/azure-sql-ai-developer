/* =============================================================================================
   DP-800 · Lab 5 · 05_security.sql — Implement data security and compliance
   ---------------------------------------------------------------------------------------------
   Exam skills: encryption (Always Encrypted, column-level encryption), Dynamic Data Masking,
   Row-Level Security, object-level permissions, secure/passwordless access, auditing.
   (Secure model endpoints -> lab 7; secure REST/GraphQL/MCP endpoints -> data-api-builder lab.)
   You test everything with users WITHOUT LOGIN + EXECUTE AS USER, so no extra accounts needed.
   ============================================================================================= */

/* =============================================================================================
   1. PRINCIPALS AND ROLES — grant to roles, never to individual users
   ============================================================================================= */
IF DATABASE_PRINCIPAL_ID(N'role_sales_analyst') IS NULL CREATE ROLE role_sales_analyst;
IF DATABASE_PRINCIPAL_ID(N'role_support_agent') IS NULL CREATE ROLE role_support_agent;
IF DATABASE_PRINCIPAL_ID(N'role_api')           IS NULL CREATE ROLE role_api;

-- Test users (no login = can't connect; perfect for EXECUTE AS testing)
IF DATABASE_PRINCIPAL_ID(N'analyst_baltics') IS NULL CREATE USER analyst_baltics WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID(N'analyst_nordics') IS NULL CREATE USER analyst_nordics WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID(N'support_agent1')  IS NULL CREATE USER support_agent1  WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID(N'api_user')        IS NULL CREATE USER api_user        WITHOUT LOGIN;
ALTER ROLE role_sales_analyst ADD MEMBER analyst_baltics;
ALTER ROLE role_sales_analyst ADD MEMBER analyst_nordics;
ALTER ROLE role_support_agent ADD MEMBER support_agent1;
ALTER ROLE role_api            ADD MEMBER api_user;
GO

/* PASSWORDLESS ACCESS (do this for real apps). With Microsoft Entra-only authentication enabled on the
   server, there are no SQL passwords to leak. Create contained users for Entra identities:

   CREATE USER [trailhead-dab-api]   FROM EXTERNAL PROVIDER;   -- managed identity of the Container App running DAB
   CREATE USER [sales-analysts@contoso.com] FROM EXTERNAL PROVIDER;   -- an Entra group
   ALTER ROLE role_api ADD MEMBER [trailhead-dab-api];

   Client connection string (no secret!):
     Server=tcp:<server>.database.windows.net;Database=TrailheadOps;Authentication=Active Directory Default;Encrypt=True;
   SQL database in Fabric supports only Microsoft Entra principals (no SQL logins at all).          */

/* =============================================================================================
   2. OBJECT-LEVEL AND COLUMN-LEVEL PERMISSIONS
   ============================================================================================= */
GRANT SELECT ON SCHEMA::sales   TO role_sales_analyst;
GRANT SELECT ON SCHEMA::catalog TO role_sales_analyst;
GRANT SELECT ON crm.Customer    TO role_sales_analyst;
DENY  SELECT ON crm.Customer (Email, Phone) TO role_sales_analyst;   -- column-level DENY beats the table GRANT

GRANT SELECT ON SCHEMA::support TO role_support_agent;
GRANT SELECT, UPDATE ON crm.Customer TO role_support_agent;
GRANT SELECT ON sales.vw_OrderSummary TO role_support_agent;

-- The API role can only run procedures: ownership chaining means it does NOT need rights on the tables
GRANT EXECUTE ON sales.usp_PlaceOrder        TO role_api;
GRANT EXECUTE ON sales.usp_UpdateOrderStatus TO role_api;
GRANT SELECT  ON sales.vw_OrderSummary       TO role_api;
GRANT SELECT  ON catalog.vw_ActiveProduct    TO role_api;
GO

-- Test: analyst can read customers but not the contact columns
EXECUTE AS USER = 'analyst_baltics';
    SELECT TOP (3) CustomerID, FirstName, City FROM crm.Customer;   -- works
    BEGIN TRY SELECT TOP (3) CustomerID, Email FROM crm.Customer; END TRY
    BEGIN CATCH SELECT ERROR_MESSAGE() AS ExpectedError; END CATCH;  -- permission denied on column
REVERT;
GO

/* =============================================================================================
   3. DYNAMIC DATA MASKING — obfuscates results for non-privileged users. It is NOT encryption and
      NOT an access control: masked values can still be inferred with WHERE clauses (demo below).
   ============================================================================================= */
ALTER TABLE crm.Customer ALTER COLUMN Email ADD MASKED WITH (FUNCTION = 'email()');
ALTER TABLE crm.Customer ALTER COLUMN Phone ADD MASKED WITH (FUNCTION = 'partial(4, "XXXXXXX", 2)');
GO
-- Granular UNMASK (column level): support agents see e-mail, but not phone
GRANT UNMASK ON crm.Customer (Email) TO role_support_agent;
GO

EXECUTE AS USER = 'support_agent1';
    SELECT TOP (3) CustomerID, Email, Phone FROM crm.Customer;              -- Email clear, Phone masked
    -- Inference: masked data can still be probed. This returns the row even though Phone is masked.
    SELECT CustomerID, Phone FROM crm.Customer WHERE CustomerID = 2 AND Phone LIKE '+371%';
REVERT;
GO
SELECT OBJECT_SCHEMA_NAME(object_id) + '.' + OBJECT_NAME(object_id) AS TableName, name, masking_function
FROM sys.masked_columns;
GO

/* =============================================================================================
   4. ROW-LEVEL SECURITY — analysts only see orders of their region
      Two ways to identify the "current region":
        a) database user -> mapping table (direct connections)
        b) SESSION_CONTEXT('SalesRegion') set by a trusted middle tier (connection pooling, DAB)
   ============================================================================================= */
IF OBJECT_ID(N'sec.UserRegion', N'U') IS NULL
CREATE TABLE sec.UserRegion (UserName sysname NOT NULL PRIMARY KEY, SalesRegion varchar(20) NOT NULL);
MERGE sec.UserRegion AS t
USING (VALUES (N'analyst_baltics', 'Baltics'), (N'analyst_nordics', 'Nordics')) AS s (UserName, SalesRegion)
ON t.UserName = s.UserName
WHEN MATCHED THEN UPDATE SET SalesRegion = s.SalesRegion
WHEN NOT MATCHED THEN INSERT (UserName, SalesRegion) VALUES (s.UserName, s.SalesRegion);
GO

DROP SECURITY POLICY IF EXISTS sec.SalesRegionFilter;
GO
CREATE OR ALTER FUNCTION sec.fn_SalesRegionPredicate (@SalesRegion varchar(20))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS allowed
    WHERE IS_MEMBER(N'db_owner') = 1                                                     -- admins/ETL
       OR @SalesRegion = CAST(SESSION_CONTEXT(N'SalesRegion') AS varchar(20))            -- app tier
       OR EXISTS (SELECT 1 FROM sec.UserRegion AS ur                                     -- direct users
                  WHERE ur.UserName = USER_NAME() AND ur.SalesRegion = @SalesRegion);
GO
CREATE SECURITY POLICY sec.SalesRegionFilter
    ADD FILTER PREDICATE sec.fn_SalesRegionPredicate(SalesRegion) ON sales.SalesOrder,
    ADD BLOCK  PREDICATE sec.fn_SalesRegionPredicate(SalesRegion) ON sales.SalesOrder AFTER INSERT,
    ADD BLOCK  PREDICATE sec.fn_SalesRegionPredicate(SalesRegion) ON sales.SalesOrder AFTER UPDATE
WITH (STATE = ON, SCHEMABINDING = ON);
GO

-- Test: same query, different users, different rows
EXECUTE AS USER = 'analyst_baltics';
    SELECT SalesRegion, COUNT(*) AS Orders FROM sales.SalesOrder GROUP BY SalesRegion;
REVERT;
EXECUTE AS USER = 'analyst_nordics';
    SELECT SalesRegion, COUNT(*) AS Orders FROM sales.SalesOrder GROUP BY SalesRegion;
REVERT;
-- App tier pattern: set the context once per request (read_only = 1 so the caller can't change it later)
EXEC sys.sp_set_session_context @key = N'SalesRegion', @value = 'Central Europe', @read_only = 0;
EXECUTE AS USER = 'api_user';           -- not in the mapping table: relies on session context only.
    -- api_user may only read the VIEW; RLS on the underlying table still applies through it.
    SELECT SalesRegion, COUNT(*) AS Orders FROM sales.vw_OrderSummary GROUP BY SalesRegion;
REVERT;
EXEC sys.sp_set_session_context @key = N'SalesRegion', @value = NULL;
GO
-- Question: why does the predicate function need SCHEMABINDING, and why must it be an inline TVF?
-- Side-channel: RLS filters rows but divide-by-zero tricks can still leak values to users who can
-- run ad hoc queries. Restrict ad hoc access for highly sensitive data.

/* =============================================================================================
   5. COLUMN-LEVEL ENCRYPTION (symmetric key) — data encrypted in the database, decrypted by T-SQL
      for principals that can open the key. Protects data at rest and in backups/exports.
   ============================================================================================= */
IF OBJECT_ID(N'crm.CustomerPII', N'U') IS NULL
CREATE TABLE crm.CustomerPII
(
    CustomerID     int            NOT NULL CONSTRAINT PK_CustomerPII PRIMARY KEY
                                  CONSTRAINT FK_CustomerPII_Customer REFERENCES crm.Customer (CustomerID),
    NationalIDEnc  varbinary(256) NULL,          -- ciphertext from ENCRYPTBYKEY
    DateOfBirth    date           NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'Change-Me-1n-Real-Life!';   -- also needed for credentials in lab 7
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = N'PIICert')
    CREATE CERTIFICATE PIICert WITH SUBJECT = N'Protects the PII symmetric key';
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'PIIKey')
    CREATE SYMMETRIC KEY PIIKey WITH ALGORITHM = AES_256 ENCRYPTION BY CERTIFICATE PIICert;
GO

OPEN SYMMETRIC KEY PIIKey DECRYPTION BY CERTIFICATE PIICert;
    DELETE FROM crm.CustomerPII;
    INSERT crm.CustomerPII (CustomerID, NationalIDEnc, DateOfBirth)
    SELECT TOP (200) CustomerID,
           -- authenticator (CustomerID) binds ciphertext to its row: copying it to another row won't decrypt
           ENCRYPTBYKEY(KEY_GUID(N'PIIKey'), CONCAT(RIGHT(CONCAT('000000', CustomerID * 7919), 6), '-', CustomerID % 90000 + 10000),
                        1, CONVERT(varbinary(16), CustomerID)),
           DATEADD(DAY, -(CustomerID * 37 % 20000) - 6570, CAST('2026-01-01' AS date))
    FROM crm.Customer ORDER BY CustomerID;

    SELECT TOP (5) CustomerID, NationalIDEnc,
           CONVERT(varchar(20), DECRYPTBYKEY(NationalIDEnc, 1, CONVERT(varbinary(16), CustomerID))) AS NationalID
    FROM crm.CustomerPII;
CLOSE SYMMETRIC KEY PIIKey;
-- With the key closed, DECRYPTBYKEY returns NULL:
SELECT TOP (2) CustomerID, CONVERT(varchar(20), DECRYPTBYKEY(NationalIDEnc)) AS NationalID FROM crm.CustomerPII;
GO

/* =============================================================================================
   6. ALWAYS ENCRYPTED [NOT IN FABRIC SQL DB] — encryption happens in the CLIENT driver; the database
      engine (and DBAs) never see plaintext or keys. Use the SSMS wizard:
        Object Explorer -> crm.CustomerPII -> right-click -> Encrypt Columns...
          * DateOfBirth : Randomized    (strongest; no equality search)
          * add a char(11) NationalID column first if you want Deterministic (allows = lookups/joins)
          * Column master key in Azure Key Vault (or Windows cert store for local SQL Server)
      Then connect with "Column Encryption Setting=Enabled" to see plaintext; without it you see ciphertext.
      Secure enclaves (VBS / Intel SGX) add rich computations (LIKE, range) on encrypted columns.

   What the wizard generates looks like this (keys are created by tooling, not hand-written):

   CREATE COLUMN MASTER KEY CMK_KV WITH (KEY_STORE_PROVIDER_NAME = N'AZURE_KEY_VAULT',
       KEY_PATH = N'https://<vault>.vault.azure.net/keys/AlwaysEncryptedCMK/<version>');
   CREATE COLUMN ENCRYPTION KEY CEK_PII WITH VALUES (COLUMN_MASTER_KEY = CMK_KV,
       ALGORITHM = 'RSA_OAEP', ENCRYPTED_VALUE = 0x01...);
   ALTER TABLE ... DateOfBirth date ENCRYPTED WITH (COLUMN_ENCRYPTION_KEY = CEK_PII,
       ENCRYPTION_TYPE = RANDOMIZED, ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256')

   Exam contrasts to know:
     TDE           -> files/backups at rest, transparent, DBAs see data
     Column-level  -> T-SQL encrypts, keys in the database, DBAs with key access see data
     Always Encrypted -> client-side, keys outside the database, DBAs can't see data
     DDM           -> presentation-layer obfuscation only                                         */

/* =============================================================================================
   7. AUDITING
   ============================================================================================= */
/* Azure SQL Database: enable auditing at server or database level (Portal -> Auditing) with a
   Log Analytics workspace, storage account or Event Hub as destination. Query in Log Analytics:

       AzureDiagnostics
       | where Category == "SQLSecurityAuditEvents"
       | where statement_s has "crm.Customer"
       | project event_time_t, server_principal_name_s, action_name_s, statement_s
       | order by event_time_t desc

   Or with a storage destination, from T-SQL:
       SELECT * FROM sys.fn_get_audit_file('https://<account>.blob.core.windows.net/sqldbauditlogs/', DEFAULT, DEFAULT);

   SQL Server 2025 (run in master, then in the database):

   CREATE SERVER AUDIT TrailheadAudit TO FILE (FILEPATH = '/var/opt/mssql/audit/') WITH (ON_FAILURE = CONTINUE);
   ALTER SERVER AUDIT TrailheadAudit WITH (STATE = ON);
   -- in TrailheadOps:
   CREATE DATABASE AUDIT SPECIFICATION PII_Access FOR SERVER AUDIT TrailheadAudit
       ADD (SELECT, UPDATE ON SCHEMA::crm BY public),
       ADD (DATABASE_PERMISSION_CHANGE_GROUP)
   WITH (STATE = ON);
   SELECT event_time, action_id, server_principal_name, statement
   FROM sys.fn_get_audit_file('/var/opt/mssql/audit/TrailheadAudit*.sqlaudit', DEFAULT, DEFAULT);            */

/* =============================================================================================
   8. CHECK YOUR WORK
   ============================================================================================= */
SELECT pr.name AS Principal, pr.type_desc, pe.state_desc, pe.permission_name,
       OBJECT_SCHEMA_NAME(pe.major_id) AS SchemaName, OBJECT_NAME(pe.major_id) AS ObjectName,
       COL_NAME(pe.major_id, pe.minor_id) AS ColumnName, pe.class_desc
FROM sys.database_permissions AS pe
JOIN sys.database_principals AS pr ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name LIKE N'role[_]%'
ORDER BY pr.name, pe.permission_name;

SELECT p.name AS PolicyName, p.is_enabled, pr.predicate_type_desc, pr.operation_desc,
       OBJECT_NAME(pr.target_object_id) AS TargetTable, pr.predicate_definition
FROM sys.security_policies AS p
JOIN sys.security_predicates AS pr ON pr.object_id = p.object_id;
GO
