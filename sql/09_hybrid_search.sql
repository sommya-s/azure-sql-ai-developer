/* =============================================================================================
   DP-800 · Lab 9 · 09_hybrid_search.sql — Full-text, semantic and hybrid search with RRF
   ---------------------------------------------------------------------------------------------
   Exam skills: choose from full-text, semantic vector, and hybrid search; implement full-text
   search; implement hybrid search; implement reciprocal rank fusion (RRF); evaluate performance
   of hybrid search.
   Platform notes: full-text is built into Azure SQL Database; in SQL database in Fabric it is in
   preview; the SQL Server Linux container image needs the mssql-server-fts package (custom image).
   ============================================================================================= */

/* =============================================================================================
   1. WHEN TO USE WHICH
   ---------------------------------------------------------------------------------------------
   | Query looks like...                         | Best fit       | Why                              |
   |---------------------------------------------|----------------|----------------------------------|
   | "Couloir", "TH-01-00042", "Alpenfox"        | full-text      | exact tokens, codes, names; vectors blur rare words |
   | "keeps my feet dry in the rain"             | vector         | meaning, synonyms, paraphrase     |
   | "Alpenfox tent that handles wind"           | hybrid         | a name AND an intent              |
   | Unknown mix (a search box for everyone)     | hybrid + RRF   | robust default for RAG retrieval  |
   ============================================================================================= */

/* =============================================================================================
   2. FULL-TEXT SEARCH
   ============================================================================================= */
IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = N'ftc_trailhead')
    CREATE FULLTEXT CATALOG ftc_trailhead AS DEFAULT;
IF NOT EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID(N'ai.ContentChunk'))
    CREATE FULLTEXT INDEX ON ai.ContentChunk (ChunkText LANGUAGE 1033)       -- 1033 = English word breaker/stemmer
        KEY INDEX PK_ContentChunk                                            -- unique, single-column, non-nullable
        ON ftc_trailhead
        WITH (CHANGE_TRACKING = AUTO);                                       -- index follows DML automatically
GO
-- Population is asynchronous. 0 = idle (done). Re-run until it returns 0.
SELECT FULLTEXTCATALOGPROPERTY(N'ftc_trailhead', 'PopulateStatus') AS PopulateStatus,
       FULLTEXTCATALOGPROPERTY(N'ftc_trailhead', 'ItemCount')      AS ItemCount;
GO

-- CONTAINS: precise predicates (words, phrases, prefixes, inflections, proximity)
SELECT TOP (10) ChunkID, ChunkText FROM ai.ContentChunk
WHERE CONTAINS(ChunkText, N'FORMSOF(INFLECTIONAL, leak) AND (tent OR jacket)');

SELECT TOP (10) ChunkID, ChunkText FROM ai.ContentChunk
WHERE CONTAINS(ChunkText, N'NEAR((zipper, broke), 10) OR NEAR((zipper, jammed), 3) OR "head*"');

-- FREETEXT / FREETEXTTABLE: natural-language input, ranked. [KEY] joins back to the table.
SELECT TOP (10) ft.[RANK], c.ChunkID, c.SourceType, c.ChunkText
FROM FREETEXTTABLE(ai.ContentChunk, ChunkText, N'waterproof boots for wet trails') AS ft
JOIN ai.ContentChunk AS c ON c.ChunkID = ft.[KEY]
ORDER BY ft.[RANK] DESC;
GO

/* =============================================================================================
   3. HYBRID SEARCH WITH RECIPROCAL RANK FUSION
      Scores from full-text (rank) and vectors (distance) live on different scales, so don't add
      them. RRF uses only the POSITION in each list:  score(d) = Σ 1 / (k + rank_i(d)),  k ≈ 60.
      A document ranked high in either list rises; ranked high in both rises most.
   ============================================================================================= */
CREATE OR ALTER PROCEDURE ai.usp_HybridSearch
    @Query      nvarchar(400),
    @Top        int = 10,
    @SourceType varchar(10) = NULL,      -- 'Product' | 'Review' | 'Ticket' | NULL = all
    @Candidates int = 50,                -- how deep to read each list before fusing
    @K          int = 60                 -- RRF damping constant
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @e nvarchar(max);
    EXEC ai.usp_EmbedText @Query, @e OUTPUT;
    DECLARE @qv vector(768) = CAST(@e AS vector(768));

    WITH keyword AS (
        SELECT TOP (@Candidates) ft.[KEY] AS ChunkID,
               ROW_NUMBER() OVER (ORDER BY ft.[RANK] DESC) AS rnk
        FROM FREETEXTTABLE(ai.ContentChunk, ChunkText, @Query, @Candidates) AS ft
        ORDER BY ft.[RANK] DESC
    ),
    semantic AS (
        SELECT ChunkID, ROW_NUMBER() OVER (ORDER BY distance) AS rnk
        FROM (
            SELECT TOP (@Candidates) WITH APPROXIMATE c.ChunkID, r.distance
            FROM VECTOR_SEARCH(TABLE = ai.ContentChunk AS c, COLUMN = Embedding,
                               SIMILAR_TO = @qv, METRIC = 'cosine') AS r
            WHERE @SourceType IS NULL OR c.SourceType = @SourceType
            ORDER BY r.distance
        ) AS v
    ),
    fused AS (
        SELECT COALESCE(k.ChunkID, s.ChunkID)                                  AS ChunkID,
               ISNULL(1.0 / (@K + k.rnk), 0) + ISNULL(1.0 / (@K + s.rnk), 0)   AS RrfScore,
               k.rnk AS KeywordRank,
               s.rnk AS SemanticRank
        FROM keyword AS k
        FULL OUTER JOIN semantic AS s ON s.ChunkID = k.ChunkID
    )
    SELECT TOP (@Top) f.ChunkID, c.SourceType, c.SourceID,
           CAST(f.RrfScore AS decimal(9, 6)) AS RrfScore, f.KeywordRank, f.SemanticRank, c.ChunkText
    FROM fused AS f
    JOIN ai.ContentChunk AS c ON c.ChunkID = f.ChunkID
    WHERE @SourceType IS NULL OR c.SourceType = @SourceType
    ORDER BY f.RrfScore DESC;
END;
GO

EXEC ai.usp_HybridSearch @Query = N'Alpenfox tent that handles strong wind';
EXEC ai.usp_HybridSearch @Query = N'headlamp will not charge', @SourceType = 'Ticket', @Top = 5;
GO

/* =============================================================================================
   4. EVALUATE: compare the three strategies side by side
      Look at which items each list finds, where they agree, and the latency of each.
      Path C (toy embeddings) behaves almost like keyword search; with a real model (path A/B) the
      semantic list finds paraphrases ("dry feet" ~ "waterproof") the keyword list misses.
   ============================================================================================= */
DECLARE @q nvarchar(400) = N'my feet stayed dry on a rainy hike';
DECLARE @e nvarchar(max), @t0 datetime2(7);
EXEC ai.usp_EmbedText @q, @e OUTPUT;
DECLARE @qv vector(768) = CAST(@e AS vector(768));

SET @t0 = SYSUTCDATETIME();
SELECT TOP (5) 'keyword' AS Strategy, c.ChunkID, c.ChunkText
FROM FREETEXTTABLE(ai.ContentChunk, ChunkText, @q, 5) AS ft
JOIN ai.ContentChunk AS c ON c.ChunkID = ft.[KEY]
ORDER BY ft.[RANK] DESC;
SELECT DATEDIFF(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0 AS KeywordMs;

SET @t0 = SYSUTCDATETIME();
SELECT TOP (5) WITH APPROXIMATE 'semantic' AS Strategy, c.ChunkID, c.ChunkText, r.distance
FROM VECTOR_SEARCH(TABLE = ai.ContentChunk AS c, COLUMN = Embedding, SIMILAR_TO = @qv, METRIC = 'cosine') AS r
ORDER BY r.distance;
SELECT DATEDIFF(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0 AS SemanticMs;

SET @t0 = SYSUTCDATETIME();
EXEC ai.usp_HybridSearch @Query = @q, @Top = 5;
SELECT DATEDIFF(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0 AS HybridMs;   -- includes embedding the query
GO
/* Your turn:
   1. Build a tiny judged set: 5 queries x the ChunkIDs you consider relevant. Compute precision@5
      for keyword, semantic and hybrid. Which wins on name-style vs intent-style queries?
   2. Change @K (10, 60, 200) and @Candidates (20, 50, 200). How do rankings and latency move?
   3. Weighted RRF: multiply the keyword term by 0.5 — when would you favour one list?            */
