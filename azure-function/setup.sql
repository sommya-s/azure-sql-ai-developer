-- Run in TrailheadOps before deploying the function (after labs 7 and 11).

-- Staging table written by the function's SQL output binding (upsert on the primary key)
IF OBJECT_ID(N'ai.ReviewVectorStaging', N'U') IS NULL
CREATE TABLE ai.ReviewVectorStaging
(
    ReviewID      int            NOT NULL PRIMARY KEY,
    ChunkText     nvarchar(2000) NOT NULL,
    EmbeddingJson nvarchar(max)  NOT NULL,
    Model         varchar(60)    NOT NULL,
    EmbeddedAt    datetime2(0)   NOT NULL
);
GO

-- Move staged vectors into the chunk table (schedule it, or call it from a second function)
CREATE OR ALTER PROCEDURE ai.usp_MergeReviewVectors
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
        DELETE c
        FROM ai.ContentChunk AS c
        JOIN ai.ReviewVectorStaging AS s ON c.SourceType = 'Review' AND c.SourceID = s.ReviewID;

        INSERT ai.ContentChunk (SourceType, SourceID, ChunkOrder, ChunkText, Embedding, EmbeddingModel, EmbeddedAt)
        SELECT 'Review', ReviewID, 1, ChunkText, CAST(EmbeddingJson AS vector(768)), Model, EmbeddedAt
        FROM ai.ReviewVectorStaging;

        DELETE FROM ai.ReviewVectorStaging;
    COMMIT;
END;
GO

-- The function's managed identity (name = Function App name) needs:
--   CREATE USER [func-trailhead] FROM EXTERNAL PROVIDER;
--   GRANT SELECT, VIEW CHANGE TRACKING ON catalog.ProductReview TO [func-trailhead];
--   GRANT SELECT, INSERT, UPDATE ON ai.ReviewVectorStaging TO [func-trailhead];
--   GRANT CREATE TABLE TO [func-trailhead];                 -- the trigger creates its lease tables
--   IF SCHEMA_ID(N'az_func') IS NULL EXEC (N'CREATE SCHEMA az_func');
--   GRANT CONTROL ON SCHEMA::az_func TO [func-trailhead];
-- Change Tracking must be on for the database and catalog.ProductReview (lab 11, section 2).
