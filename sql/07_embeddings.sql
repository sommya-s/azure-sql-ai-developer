/* =============================================================================================
   DP-800 · Lab 7 · 07_embeddings.sql — Design and implement models and embeddings
   ---------------------------------------------------------------------------------------------
   Exam skills: evaluate external models; create and manage external models; choose an embedding
   maintenance method; identify which columns to include; design chunks; generate embeddings.
   Also: secure model endpoints with Managed Identity (from "Implement data security").

   PICK ONE MODEL PATH (all three produce vector(768), so labs 8-10 work unchanged):
     A) Azure OpenAI / Microsoft Foundry  text-embedding-3-small with dimensions = 768   (recommended)
     B) Ollama  nomic-embed-text (768 dims) behind an HTTPS proxy, for local SQL Server 2025
     C) OFFLINE "toy" embeddings: a hashing bag-of-words function in T-SQL. No AI service needed.
        It teaches the mechanics (vector type, indexes, VECTOR_SEARCH, hybrid, RRF) but it is
        LEXICAL, not semantic: "dry feet" will not match "waterproof". Switch to A or B to see
        real semantic search.
   ============================================================================================= */

/* =============================================================================================
   0. Configuration: which path are you on?
   ============================================================================================= */
IF OBJECT_ID(N'ai.Config', N'U') IS NULL
CREATE TABLE ai.Config (ConfigKey varchar(50) NOT NULL PRIMARY KEY, ConfigValue nvarchar(400) NOT NULL);
MERGE ai.Config AS t
USING (VALUES ('EmbeddingMode', N'toy'),            -- 'toy' (path C) or 'model' (paths A/B)
              ('EmbeddingModel', N'TrailheadEmbeddings'),
              ('CT_LastSyncVersion', N'0')) AS s (k, v)
ON t.ConfigKey = s.k
WHEN NOT MATCHED THEN INSERT (ConfigKey, ConfigValue) VALUES (s.k, s.v);
GO

/* =============================================================================================
   1. EVALUATE EXTERNAL MODELS — questions the exam expects you to reason about
   ---------------------------------------------------------------------------------------------
   | Need                                   | Look for                                          |
   |----------------------------------------|---------------------------------------------------|
   | Reviews in Latvian, Polish, German...  | multilingual embedding model                      |
   | Search product photos with text        | multimodal model (shared text+image vector space) |
   | Millions of rows, tight storage/latency| fewer dimensions (e.g. 768 via "dimensions"),     |
   |                                        | smaller model; check quality on YOUR queries      |
   | LLM answer must be machine-readable    | chat model supporting structured output           |
   |                                        | (response_format json_schema) — used in lab 10    |
   | Data must not leave the network        | local model (Ollama / ONNX Runtime on SQL Server) |
   Rule: the SAME model (and dimensions) must embed documents and queries. Changing model = re-embed all.
   ============================================================================================= */

/* =============================================================================================
   2. CREATE THE EXTERNAL MODEL (paths A and B). Skip this section on path C.
   ============================================================================================= */
/* SQL Server 2025 only: allow outbound REST calls from the engine
EXEC sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;
*/

/* ---- Path A1: Azure OpenAI with MANAGED IDENTITY (passwordless — preferred) ----
   1. Azure SQL logical server -> Identity -> System assigned: On
   2. On the Azure OpenAI / Foundry resource: Access control (IAM) -> add role
      "Cognitive Services OpenAI User" to the SQL server's identity
   3. Deploy "text-embedding-3-small" (deployment name used below)

CREATE DATABASE SCOPED CREDENTIAL [https://<your-resource>.openai.azure.com/]
    WITH IDENTITY = 'Managed Identity', SECRET = '{"resourceid":"https://cognitiveservices.azure.com"}';

CREATE EXTERNAL MODEL TrailheadEmbeddings
WITH (
    LOCATION   = 'https://<your-resource>.openai.azure.com/openai/deployments/text-embedding-3-small/embeddings?api-version=2024-10-21',
    API_FORMAT = 'Azure OpenAI',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'text-embedding-3-small',
    CREDENTIAL = [https://<your-resource>.openai.azure.com/],
    PARAMETERS = '{"dimensions": 768, "sql_rest_options": {"retry_count": 3}}'
);
*/

/* ---- Path A2: same, with an API key (simpler, but a secret now lives in the database) ----
   Needs a database master key (created in lab 5).

CREATE DATABASE SCOPED CREDENTIAL [https://<your-resource>.openai.azure.com/]
    WITH IDENTITY = 'HTTPEndpointHeaders', SECRET = '{"api-key":"<your-key>"}';
-- then the same CREATE EXTERNAL MODEL as A1
*/

/* ---- Path B: Ollama, local. SQL Server only calls HTTPS endpoints, so put Ollama behind a TLS proxy
   (e.g. Caddy) and trust its certificate. If SQL Server runs in Docker, use host.docker.internal.
     ollama pull nomic-embed-text

CREATE EXTERNAL MODEL TrailheadEmbeddings
WITH (
    LOCATION   = 'https://host.docker.internal:11435/api/embed',
    API_FORMAT = 'Ollama',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'nomic-embed-text'
);
*/

/* After creating the model:
UPDATE ai.Config SET ConfigValue = N'model' WHERE ConfigKey = 'EmbeddingMode';
SELECT name, api_format, model_type_desc, model, location FROM sys.external_models;
SELECT AI_GENERATE_EMBEDDINGS(N'waterproof hiking boots' USE MODEL TrailheadEmbeddings) AS TestVector;
GRANT EXECUTE ON EXTERNAL MODEL::TrailheadEmbeddings TO role_api;     -- least privilege for the app
-- Manage: ALTER EXTERNAL MODEL TrailheadEmbeddings SET (MODEL = '...'); DROP EXTERNAL MODEL ...;
*/
GO

/* =============================================================================================
   3. PATH C: offline toy embedding (feature hashing). Read it — it is a good mental model of
      what a vector is: a fixed-length list of numbers where similar texts get similar numbers.
   ============================================================================================= */
CREATE OR ALTER FUNCTION ai.fn_ToyEmbeddingJson (@Text nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    DECLARE @json nvarchar(max);
    WITH words AS (
        -- lowercase words, crude stemming (leaks/leaked/leaking -> leak), drop stop words
        SELECT REGEXP_REPLACE(LOWER(value), '(ing|ed|es|s)$', '') AS w
        FROM STRING_SPLIT(REGEXP_REPLACE(@Text, '[^A-Za-z]+', ' '), ' ')
        WHERE LEN(value) > 2
          AND LOWER(value) NOT IN ('the', 'and', 'for', 'with', 'this', 'that', 'but', 'was', 'are', 'after',
                                   'from', 'very', 'its', 'not', 'you', 'your', 'had', 'has', 'have', 'all',
                                   'one', 'out', 'into', 'over', 'built', 'review', 'category', 'brand')
    ),
    buckets AS (    -- hash each word into one of 768 dimensions and count
        SELECT CAST(CAST(SUBSTRING(HASHBYTES('SHA2_256', w), 1, 4) AS bigint) % 768 AS int) AS b, COUNT(*) AS c
        FROM words
        GROUP BY CAST(CAST(SUBSTRING(HASHBYTES('SHA2_256', w), 1, 4) AS bigint) % 768 AS int)
    )
    SELECT @json = CONCAT('[', STRING_AGG(CAST(ISNULL(b.c, 0) AS varchar(max)), ',') WITHIN GROUP (ORDER BY g.value), ']')
    FROM GENERATE_SERIES(0, 767) AS g
    LEFT JOIN buckets AS b ON b.b = g.value;
    RETURN @json;
END;
GO

-- One procedure to embed query text, whichever path you chose (used by labs 8-10)
CREATE OR ALTER PROCEDURE ai.usp_EmbedText
    @Text      nvarchar(max),
    @Embedding nvarchar(max) OUTPUT          -- JSON array; callers CAST(@Embedding AS vector(768))
AS
BEGIN
    SET NOCOUNT ON;
    IF (SELECT ConfigValue FROM ai.Config WHERE ConfigKey = 'EmbeddingMode') = N'model'
        -- dynamic SQL so this procedure compiles even before the external model exists
        EXEC sys.sp_executesql
             N'SET @e = CAST(AI_GENERATE_EMBEDDINGS(@t USE MODEL TrailheadEmbeddings) AS nvarchar(max));',
             N'@t nvarchar(max), @e nvarchar(max) OUTPUT', @t = @Text, @e = @Embedding OUTPUT;
    ELSE
        SET @Embedding = ai.fn_ToyEmbeddingJson(@Text);
END;
GO

/* =============================================================================================
   4. WHICH COLUMNS GO INTO AN EMBEDDING? One view defines the "document" for each source.
      * Include what a user would search by: names, category, descriptions, key attributes, review text.
      * Add context that makes a chunk self-contained ("Review of <product> (2/5): ...").
      * EXCLUDE PII and secrets: e-mails/phones in tickets are redacted before they reach the model
        (embeddings can leak their source text, and the text travels to an external endpoint).
      * Exclude volatile values (stock, price) — they change often and don't carry meaning.
   ============================================================================================= */
CREATE OR ALTER VIEW ai.vw_SourceDocument
AS
SELECT 'Product' AS SourceType, p.ProductID AS SourceID,
       CONCAT(p.ProductName, N'. Category: ', c.CategoryName, N'. Brand: ', p.Brand, N'. ', p.Description,
              CASE WHEN JSON_VALUE(p.Attributes, '$.waterproof') = 'true' THEN N' Waterproof.' ELSE N'' END) AS DocText
FROM catalog.Product AS p
JOIN catalog.Category AS c ON c.CategoryID = p.CategoryID
WHERE p.IsActive = 1
UNION ALL
SELECT 'Review', r.ReviewID,
       CONCAT(N'Review of ', p.ProductName, N' (', r.Rating, N'/5): ', r.Title, N'. ', r.ReviewText)
FROM catalog.ProductReview AS r
JOIN catalog.Product AS p ON p.ProductID = r.ProductID
UNION ALL
SELECT 'Ticket', t.TicketID,
       CONCAT(t.Subject, N'. ',
              REGEXP_REPLACE(
                  REGEXP_REPLACE(t.Body, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email]'),
                  '\+[0-9][0-9 ]{6,}[0-9]|\([0-9]{2,4}\)\s?[0-9]{6,}|\b[0-9]{2}-[0-9]{3}-[0-9]{3}\b', '[phone]'))
FROM support.Ticket AS t;
GO
SELECT TOP (3) * FROM ai.vw_SourceDocument WHERE SourceType = 'Ticket';   -- check the redaction
GO

/* =============================================================================================
   5. CHUNKS — the table that holds text fragments and their vectors
      Chunk size trade-off: small chunks = precise matches but lost context; large = more context,
      blurrier vectors and more tokens sent to the LLM. Overlap keeps sentences that straddle a
      boundary retrievable. AI_GENERATE_CHUNKS(FIXED) counts characters and can split mid-word;
      for production consider sentence/token-aware chunking in your app or in Foundry.
   ============================================================================================= */
IF OBJECT_ID(N'ai.ContentChunk', N'U') IS NULL
CREATE TABLE ai.ContentChunk
(
    ChunkID        int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_ContentChunk PRIMARY KEY CLUSTERED,
    SourceType     varchar(10)    NOT NULL CONSTRAINT CK_ContentChunk_Source CHECK (SourceType IN ('Product', 'Review', 'Ticket')),
    SourceID       int            NOT NULL,
    ChunkOrder     int            NOT NULL,
    ChunkText      nvarchar(2000) NOT NULL,
    Embedding      vector(768)    NULL,
    EmbeddingModel varchar(60)    NULL,
    EmbeddedAt     datetime2(0)   NULL,
    IsStale        bit            NOT NULL CONSTRAINT DF_ContentChunk_IsStale DEFAULT (0),
    CONSTRAINT UQ_ContentChunk UNIQUE (SourceType, SourceID, ChunkOrder)
);
GO

-- Preview what chunking does to one long-ish document
SELECT c.chunk_order, c.chunk_offset, c.chunk_length, c.chunk
FROM (SELECT TOP (1) DocText FROM ai.vw_SourceDocument WHERE SourceType = 'Product' ORDER BY LEN(DocText) DESC) AS d
CROSS APPLY AI_GENERATE_CHUNKS(SOURCE = d.DocText, CHUNK_TYPE = FIXED, CHUNK_SIZE = 150, OVERLAP = 10) AS c;
GO

/* =============================================================================================
   6. GENERATE + MAINTAIN EMBEDDINGS — one idempotent procedure
      * new sources        -> chunked and embedded
      * deleted sources    -> chunks removed
      * changed sources    -> flagged IsStale (by trigger or Change Tracking, below) -> re-chunked
      Batches keep each model call small and let you respect rate limits.
      NOTE SQL Server 2025 (preview vector index): tables with a vector index may be read-only.
      Drop the index, refresh, recreate it (lab 8). Azure SQL DB / Fabric: full DML is supported.
   ============================================================================================= */
CREATE OR ALTER PROCEDURE ai.usp_RefreshEmbeddings
    @BatchSize int = 100
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @mode nvarchar(20) = (SELECT ConfigValue FROM ai.Config WHERE ConfigKey = 'EmbeddingMode');
    DECLARE @rc int = 1, @total int = 0;

    -- 1. remove chunks whose source is gone or stale
    DELETE c
    FROM ai.ContentChunk AS c
    WHERE c.IsStale = 1
       OR NOT EXISTS (SELECT 1 FROM ai.vw_SourceDocument AS d WHERE d.SourceType = c.SourceType AND d.SourceID = c.SourceID);

    -- 2. chunk sources that have no chunks (new or just-deleted stale ones)
    INSERT ai.ContentChunk (SourceType, SourceID, ChunkOrder, ChunkText)
    SELECT d.SourceType, d.SourceID, ch.chunk_order, ch.chunk
    FROM ai.vw_SourceDocument AS d
    CROSS APPLY AI_GENERATE_CHUNKS(SOURCE = d.DocText, CHUNK_TYPE = FIXED, CHUNK_SIZE = 500, OVERLAP = 10) AS ch
    WHERE NOT EXISTS (SELECT 1 FROM ai.ContentChunk AS c WHERE c.SourceType = d.SourceType AND c.SourceID = d.SourceID);

    -- 3. embed everything that has no vector yet, in batches
    WHILE @rc > 0
    BEGIN
        IF @mode = N'model'
            EXEC sys.sp_executesql N'
                UPDATE TOP (@n) ai.ContentChunk
                SET Embedding = AI_GENERATE_EMBEDDINGS(ChunkText USE MODEL TrailheadEmbeddings),
                    EmbeddingModel = ''TrailheadEmbeddings'', EmbeddedAt = SYSUTCDATETIME()
                WHERE Embedding IS NULL;
                SET @rc = @@ROWCOUNT;', N'@n int, @rc int OUTPUT', @n = @BatchSize, @rc = @rc OUTPUT;
        ELSE
        BEGIN
            UPDATE TOP (@BatchSize * 10) ai.ContentChunk
            SET Embedding = CAST(ai.fn_ToyEmbeddingJson(ChunkText) AS vector(768)),
                EmbeddingModel = 'toy-hash-768', EmbeddedAt = SYSUTCDATETIME()
            WHERE Embedding IS NULL;
            SET @rc = @@ROWCOUNT;
        END;
        SET @total += @rc;
    END;

    SELECT @total AS ChunksEmbedded,
           (SELECT COUNT(*) FROM ai.ContentChunk) AS TotalChunks,
           (SELECT COUNT(*) FROM ai.ContentChunk WHERE Embedding IS NULL) AS StillMissing;
END;
GO

EXEC ai.usp_RefreshEmbeddings;      -- first run: chunks + embeds everything (toy: ~1-2 min)
GO
SELECT SourceType, COUNT(*) AS Chunks, AVG(LEN(ChunkText)) AS AvgChars, MIN(EmbeddingModel) AS Model
FROM ai.ContentChunk GROUP BY SourceType;
SELECT TOP (1) ChunkID, ChunkText, CAST(Embedding AS nvarchar(200)) AS FirstValues FROM ai.ContentChunk;
GO

/* =============================================================================================
   7. CHOOSING AN EMBEDDING MAINTENANCE METHOD
   ---------------------------------------------------------------------------------------------
   | Method                         | When it fits                                  | Watch out for                     |
   |--------------------------------|-----------------------------------------------|-----------------------------------|
   | Table trigger (7a)             | small volume, must be flagged in the same txn | adds latency to every write; don't|
   |                                |                                               | call the model INSIDE the trigger |
   | Change Tracking + job (7b)     | periodic batch refresh, "what changed since?" | no old values; needs a scheduler  |
   | Azure Functions SQL trigger    | near-real-time, code outside the DB,          | uses Change Tracking underneath;  |
   |   binding (../azure-function)  | call any model/SDK, scale out                 | another service to run & secure   |
   | Azure Logic Apps               | low-code, approval steps, connectors          | per-action cost, polling latency  |
   | CDC                            | need before/after values, downstream ETL      | not in Fabric SQL DB; more storage|
   | Microsoft Foundry (indexers /  | managed pipelines when vectors live in an     | data and vectors leave the DB     |
   |   agents over the data)        | external search index                         |                                   |
   ============================================================================================= */

-- 7a. Trigger: flag chunks stale when the text that feeds them changes (cheap; no model call here)
CREATE OR ALTER TRIGGER catalog.trg_ProductReview_EmbeddingStale
ON catalog.ProductReview
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT (UPDATE(ReviewText) OR UPDATE(Title) OR UPDATE(Rating)) RETURN;
    UPDATE c SET IsStale = 1
    FROM ai.ContentChunk AS c
    JOIN inserted AS i ON c.SourceType = 'Review' AND c.SourceID = i.ReviewID;
END;
GO

-- 7b. Change Tracking: ask "which products changed since version N?" — no trigger on the write path
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
    ALTER DATABASE CURRENT SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 3 DAYS, AUTO_CLEANUP = ON);
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'catalog.Product'))
    ALTER TABLE catalog.Product ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
-- start syncing from "now" (otherwise the first run sees version 0 as too old and flags everything)
UPDATE ai.Config SET ConfigValue = CAST(CHANGE_TRACKING_CURRENT_VERSION() AS nvarchar(30))
WHERE ConfigKey = 'CT_LastSyncVersion' AND ConfigValue = N'0';
GO
CREATE OR ALTER PROCEDURE ai.usp_FlagChangedProducts
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @last bigint = CAST((SELECT ConfigValue FROM ai.Config WHERE ConfigKey = 'CT_LastSyncVersion') AS bigint);
    DECLARE @now bigint = CHANGE_TRACKING_CURRENT_VERSION();

    IF @last < CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N'catalog.Product'))
        UPDATE ai.ContentChunk SET IsStale = 1 WHERE SourceType = 'Product';   -- too old: full refresh
    ELSE
        UPDATE c SET IsStale = 1
        FROM ai.ContentChunk AS c
        JOIN CHANGETABLE(CHANGES catalog.Product, @last) AS ct ON c.SourceType = 'Product' AND c.SourceID = ct.ProductID
        WHERE ct.SYS_CHANGE_OPERATION IN ('U', 'D')
          -- only text columns matter; a price change shouldn't trigger a (paid) re-embed
          AND (CHANGE_TRACKING_IS_COLUMN_IN_MASK(COLUMNPROPERTY(OBJECT_ID(N'catalog.Product'), 'Description', 'ColumnId'), ct.SYS_CHANGE_COLUMNS) = 1
            OR CHANGE_TRACKING_IS_COLUMN_IN_MASK(COLUMNPROPERTY(OBJECT_ID(N'catalog.Product'), 'ProductName', 'ColumnId'), ct.SYS_CHANGE_COLUMNS) = 1
            OR ct.SYS_CHANGE_OPERATION = 'D');

    UPDATE ai.Config SET ConfigValue = CAST(@now AS nvarchar(30)) WHERE ConfigKey = 'CT_LastSyncVersion';
END;
GO

-- Try the maintenance loop
UPDATE catalog.ProductReview SET ReviewText = ReviewText + N' Update: the seller replaced it for free.' WHERE ReviewID = 1;
UPDATE catalog.Product SET Description = Description + N' Now with recycled laces.' WHERE ProductID = 1;
UPDATE catalog.Product SET ListPrice = ListPrice WHERE ProductID = 2;   -- price-only change: should NOT flag
EXEC ai.usp_FlagChangedProducts;
SELECT SourceType, SourceID, IsStale FROM ai.ContentChunk WHERE IsStale = 1;
EXEC ai.usp_RefreshEmbeddings;
GO
