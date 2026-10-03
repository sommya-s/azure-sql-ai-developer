/* Minimal test harness (no external framework): each test is a procedure in schema [test]
   that THROWs on failure. run_all_tests.sql executes them and fails the CI step if any fails.
   In real projects consider tSQLt (mocks/fakes of tables) — the idea is identical.            */
IF SCHEMA_ID(N'test') IS NULL EXEC (N'CREATE SCHEMA test');
GO
CREATE OR ALTER PROCEDURE test.AssertEquals @Expected sql_variant, @Actual sql_variant, @Message nvarchar(400)
AS
BEGIN
    IF (@Expected IS NULL AND @Actual IS NULL) OR @Expected = @Actual RETURN;
    DECLARE @m nvarchar(2048) = CONCAT(@Message, N' | expected: ', CAST(@Expected AS nvarchar(200)),
                                       N' actual: ', CAST(@Actual AS nvarchar(200)));
    THROW 50900, @m, 1;
END;
GO
