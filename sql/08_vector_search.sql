/* =============================================================================================
   DP-800 · Lab 8 · 08_vector_search.sql — Design for vector data and implement vector search
   ---------------------------------------------------------------------------------------------
   Exam skills: vector data type, size and indexes; VECTOR_NORMALIZE, VECTOR_DISTANCE,
   VECTORPROPERTY, VECTOR_SEARCH; ANN vs KNN; vector index types and metrics; implement vector
   search; evaluate performance of vector search.
   Prerequisite: 07_embeddings.sql (ai.ContentChunk populated).
   Each demo is ONE batch (variables don't survive GO), so select from DECLARE to the next GO.
   ============================================================================================= */

/* =============================================================================================
   1. THE VECTOR TYPE — what you store and what it costs
   ============================================================================================= */
DECLARE @a vector(3) = '[1, 2, 2]';
DECLARE @b vector(3) = '[2, 4, 4]';                  -- same direction, twice as long
DECLARE @c vector(3) = '[-1, 0, 3]';
SELECT VECTORPROPERTY(@a, 'Dimensions')          AS Dims,
       VECTORPROPERTY(@a, 'BaseType')            AS BaseType,             -- float32 by default
       VECTOR_DISTANCE('cosine', @a, @b)         AS CosineAB,             -- 0: identical direction
       VECTOR_DISTANCE('euclidean', @a, @b)      AS EuclideanAB,          -- 3: length matters
       VECTOR_DISTANCE('dot', @a, @b)            AS NegDotAB,             -- negative dot product (smaller = closer)
       VECTOR_DISTANCE('cosine', @a, @c)         AS CosineAC,
       CAST(VECTOR_NORMALIZE(@b, 'norm2') AS nvarchar(200)) AS B_Normalized; -- unit length: [0.333,0.667,0.667]
-- Key facts:
--  * cosine distance = 1 - cosine similarity; range 0..2. For unit-length (normalized) vectors,
--    cosine and dot give the SAME ranking and dot is cheaper. OpenAI embeddings are already normalized.
--  * Size: vector(768) float32 = 768 x 4 bytes ~ 3 KB per row (+ small header); vector(1536) ~ 6 KB.
--    Fewer dimensions = less storage/IO and faster distance math, usually with a small quality loss.
--    (A half-precision base type, vector(n, float16), halves storage where your platform supports it.)
--  * Max 1998 dimensions (float32). Vectors are stored in an optimized binary format; cast to
--    nvarchar to see the JSON array.
GO

SELECT EmbeddingModel, COUNT(*) AS Chunks,
       MIN(VECTORPROPERTY(Embedding, 'Dimensions')) AS Dims,
       SUM(DATALENGTH(Embedding)) / 1024 AS VectorKB
FROM ai.ContentChunk
GROUP BY EmbeddingModel;
GO

/* =============================================================================================
   2. EXACT SEARCH (KNN) — compare the query vector with EVERY row. Always correct; O(n).
   ============================================================================================= */
DECLARE @q nvarchar(400) = N'boots that keep my feet dry when crossing streams';
DECLARE @e nvarchar(max);
EXEC ai.usp_EmbedText @q, @e OUTPUT;
DECLARE @qv vector(768) = CAST(@e AS vector(768));

SELECT TOP (10) ChunkID, SourceType, SourceID,
       VECTOR_DISTANCE('cosine', Embedding, @qv) AS Distance,
       ChunkText
FROM ai.ContentChunk
WHERE Embedding IS NOT NULL
ORDER BY Distance;

-- Filters are trivial with exact search: only negative reviews
SELECT TOP (5) c.ChunkID, r.Rating, VECTOR_DISTANCE('cosine', c.Embedding, @qv) AS Distance, c.ChunkText
FROM ai.ContentChunk AS c
JOIN catalog.ProductReview AS r ON c.SourceType = 'Review' AND r.ReviewID = c.SourceID
WHERE r.Rating <= 2
ORDER BY Distance;
GO

/* =============================================================================================
   3. APPROXIMATE SEARCH (ANN) — a DiskANN graph index: visits a small part of the data.
      Much faster at scale, but may miss some true neighbors (recall < 100%).
   ============================================================================================= */
-- Latest-version vector indexes need >= 100 rows. METRIC must match the METRIC used in VECTOR_SEARCH,
-- otherwise the engine warns and falls back to an exact (kNN) scan.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'vix_ContentChunk_Embedding')
    CREATE VECTOR INDEX vix_ContentChunk_Embedding
        ON ai.ContentChunk (Embedding)
        WITH (METRIC = 'cosine', TYPE = 'diskann');
GO
SELECT * FROM sys.dm_db_vector_indexes;          -- index state and version
GO

DECLARE @q nvarchar(400) = N'boots that keep my feet dry when crossing streams';
DECLARE @e nvarchar(max);
EXEC ai.usp_EmbedText @q, @e OUTPUT;
DECLARE @qv vector(768) = CAST(@e AS vector(768));

-- Latest syntax (Azure SQL Database, SQL database in Fabric):
SELECT TOP (10) WITH APPROXIMATE
       c.ChunkID, c.SourceType, c.SourceID, r.distance, c.ChunkText
FROM VECTOR_SEARCH(
        TABLE      = ai.ContentChunk AS c,
        COLUMN     = Embedding,
        SIMILAR_TO = @qv,
        METRIC     = 'cosine'
     ) AS r
WHERE c.SourceType = 'Review'                    -- iterative filtering: applied DURING the graph search
ORDER BY r.distance;                             -- ORDER BY distance ASC is mandatory with APPROXIMATE

/* Earlier preview syntax (SQL Server 2025 with an earlier-version index): TOP_N inside the function,
   filters applied AFTER the top N are found (post-filtering -> you may get fewer than N rows):
SELECT TOP (10) c.ChunkID, r.distance, c.ChunkText
FROM VECTOR_SEARCH(TABLE = ai.ContentChunk AS c, COLUMN = Embedding, SIMILAR_TO = @qv,
                   METRIC = 'cosine', TOP_N = 10) AS r
ORDER BY r.distance;                                                                              */
GO

/* =============================================================================================
   4. EVALUATE: recall@10 and latency, ANN vs exact, over several queries
      recall@k = |ANN top-k ∩ exact top-k| / k. Aim for >= 0.95 for most search UIs.
   ============================================================================================= */
DECLARE @queries TABLE (q nvarchar(400));
INSERT @queries VALUES (N'boots that keep my feet dry when crossing streams'),
                       (N'tent that survives strong wind on a ridge'),
                       (N'headlamp battery dies in the cold'),
                       (N'warm sleeping bag for winter camping'),
                       (N'refund for a returned jacket');
DECLARE @results TABLE (q nvarchar(400), recall decimal(4, 2), exact_ms int, ann_ms int);
DECLARE @q nvarchar(400), @e nvarchar(max), @qv vector(768), @t0 datetime2(7), @exact_ms int, @ann_ms int;
DECLARE @exact TABLE (ChunkID int PRIMARY KEY);
DECLARE @ann   TABLE (ChunkID int PRIMARY KEY);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT q FROM @queries;
OPEN cur;
FETCH NEXT FROM cur INTO @q;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC ai.usp_EmbedText @q, @e OUTPUT;
    SET @qv = CAST(@e AS vector(768));
    DELETE @exact; DELETE @ann;

    SET @t0 = SYSUTCDATETIME();
    INSERT @exact SELECT TOP (10) ChunkID FROM ai.ContentChunk ORDER BY VECTOR_DISTANCE('cosine', Embedding, @qv);
    SET @exact_ms = DATEDIFF(MILLISECOND, @t0, SYSUTCDATETIME());

    SET @t0 = SYSUTCDATETIME();
    INSERT @ann
    SELECT ChunkID FROM (
        SELECT TOP (10) WITH APPROXIMATE c.ChunkID, r.distance
        FROM VECTOR_SEARCH(TABLE = ai.ContentChunk AS c, COLUMN = Embedding, SIMILAR_TO = @qv, METRIC = 'cosine') AS r
        ORDER BY r.distance) AS x;
    SET @ann_ms = DATEDIFF(MILLISECOND, @t0, SYSUTCDATETIME());

    INSERT @results
    SELECT @q, (SELECT COUNT(*) FROM @exact AS e JOIN @ann AS a ON a.ChunkID = e.ChunkID) / 10.0, @exact_ms, @ann_ms;
    FETCH NEXT FROM cur INTO @q;
END;
CLOSE cur; DEALLOCATE cur;

SELECT * FROM @results;
SELECT AVG(recall) AS AvgRecallAt10, AVG(exact_ms) AS AvgExactMs, AVG(ann_ms) AS AvgAnnMs FROM @results;
GO

/* =============================================================================================
   5. DECISIONS THE EXAM ASKS ABOUT
   ---------------------------------------------------------------------------------------------
   KNN (exact, VECTOR_DISTANCE + ORDER BY)        | ANN (vector index + VECTOR_SEARCH ... APPROXIMATE)
   -----------------------------------------------|---------------------------------------------------
   small tables (roughly < 50k vectors)           | large tables, latency-sensitive search
   very selective filters (search 200 rows)       | broad search, filters handled iteratively
   need 100% recall (dedup, compliance)           | 95-99% recall is fine (recommendations, RAG)
   no index maintenance                           | index build time + memory; >= 100 rows to create

   Metric: use what the model was trained for (cosine is the safe default for text embeddings);
   dot = cosine ranking for normalized vectors; euclidean when magnitude carries meaning.
   Index TYPE today: 'diskann' (graph-based ANN, works from disk with a compact in-memory part).
   With ~2,000 rows in this lab both are fast — try it with 100k+ rows (exercise in the README)
   to see ANN pull away.
   ============================================================================================= */
