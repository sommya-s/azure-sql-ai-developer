/* Runs every procedure named test.test_% and reports. Exits with error if anything failed
   (sqlcmd -b makes the CI step fail on the THROW at the end).                                  */
SET NOCOUNT ON;
DECLARE @results TABLE (TestName sysname, Passed bit, Message nvarchar(2048));
DECLARE @name sysname, @sql nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(name)
    FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'test' AND name LIKE 'test[_]%' ORDER BY name;
OPEN c;
FETCH NEXT FROM c INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC (@name);
        INSERT @results VALUES (@name, 1, N'ok');
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        INSERT @results VALUES (@name, 0, ERROR_MESSAGE());
    END CATCH;
    FETCH NEXT FROM c INTO @name;
END;
CLOSE c; DEALLOCATE c;

SELECT * FROM @results ORDER BY Passed, TestName;
IF EXISTS (SELECT 1 FROM @results WHERE Passed = 0)
    THROW 50999, N'One or more database tests failed.', 1;
PRINT 'All database tests passed.';
