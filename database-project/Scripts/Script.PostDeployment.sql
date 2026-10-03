/*
Post-deployment script: runs after every publish. Keep it IDEMPOTENT.
Reference (static) data lives in source control and is MERGEd, so the target always matches the repo:
inserts new rows and updates changed ones (deletes are a deliberate, separate decision).
SQLCMD :r includes keep each reference table in its own reviewable file.
*/
:r ./ReferenceData/Category.sql
:r ./ReferenceData/Store.sql
