/* =============================================================================================
   DP-800 · Lab 4 · 04_advanced_tsql.sql — Write advanced T-SQL code
   ---------------------------------------------------------------------------------------------
   Exam skills: CTEs, window functions, JSON functions (JSON_OBJECT, JSON_ARRAY, JSON_ARRAYAGG,
   JSON_CONTAINS, OPENJSON, JSON_VALUE), regular expressions (REGEXP_LIKE/REPLACE/SUBSTR/INSTR/COUNT/
   MATCHES/SPLIT_TO_TABLE), fuzzy matching (EDIT_DISTANCE, EDIT_DISTANCE_SIMILARITY,
   JARO_WINKLER_DISTANCE), graph queries with MATCH, correlated queries, error handling.
   Bonus: temporal queries (FOR SYSTEM_TIME).
   Run section by section. Each section ends with a "Your turn" exercise — solutions are in
   ../solutions/04_advanced_tsql_solutions.sql (try first!).
   ============================================================================================= */

/* =============================================================================================
   1. COMMON TABLE EXPRESSIONS
   ============================================================================================= */

-- 1a. Chained CTEs: readable, step-by-step logic (each CTE can reference the previous ones)
WITH order_totals AS (
    SELECT o.OrderID, o.CustomerID, o.SalesRegion, SUM(l.LineTotal) AS OrderTotal
    FROM sales.SalesOrder AS o
    JOIN sales.SalesOrderLine AS l ON l.OrderID = o.OrderID
    WHERE o.Status NOT IN ('Cancelled', 'Returned')
    GROUP BY o.OrderID, o.CustomerID, o.SalesRegion
),
customer_value AS (
    SELECT CustomerID, SalesRegion, COUNT(*) AS Orders, SUM(OrderTotal) AS Revenue
    FROM order_totals
    GROUP BY CustomerID, SalesRegion
)
SELECT TOP (10) cv.*, c.FirstName, c.LastName, c.LoyaltyTier
FROM customer_value AS cv
JOIN crm.Customer AS c ON c.CustomerID = cv.CustomerID
ORDER BY cv.Revenue DESC;
GO

-- 1b. RECURSIVE CTE: walk referral chains (anchor = customers who referred someone but weren't referred)
WITH chain AS (
    SELECT CustomerID, CAST(CONCAT(FirstName, N' ', LastName) AS nvarchar(4000)) AS ReferralPath, 0 AS Depth
    FROM crm.Customer
    WHERE ReferredByCustomerID IS NULL
      AND CustomerID IN (SELECT ReferredByCustomerID FROM crm.Customer)
    UNION ALL
    SELECT c.CustomerID, CAST(CONCAT(ch.ReferralPath, N' -> ', c.FirstName, N' ', c.LastName) AS nvarchar(4000)), ch.Depth + 1
    FROM crm.Customer AS c
    JOIN chain AS ch ON c.ReferredByCustomerID = ch.CustomerID
)
SELECT TOP (15) CustomerID, Depth, ReferralPath
FROM chain
WHERE Depth >= 2
ORDER BY Depth DESC, CustomerID
OPTION (MAXRECURSION 50);    -- default is 100; 0 = unlimited (dangerous with cycles)
GO
-- Your turn 1: count how many customers each "root" referrer brought in, directly or indirectly.

/* =============================================================================================
   2. WINDOW FUNCTIONS
   ============================================================================================= */

-- 2a. Per-customer running total, order sequence and days since previous order
WITH t AS (
    SELECT o.CustomerID, o.OrderID, o.OrderDate, SUM(l.LineTotal) AS OrderTotal
    FROM sales.SalesOrder AS o
    JOIN sales.SalesOrderLine AS l ON l.OrderID = o.OrderID
    GROUP BY o.CustomerID, o.OrderID, o.OrderDate
)
SELECT CustomerID, OrderID, OrderDate, OrderTotal,
       ROW_NUMBER() OVER w                                            AS OrderSeq,
       SUM(OrderTotal) OVER (w ROWS UNBOUNDED PRECEDING)              AS RunningTotal,
       DATEDIFF(DAY, LAG(OrderDate) OVER w, OrderDate)                AS DaysSincePrevious,
       FIRST_VALUE(OrderDate) OVER w                                  AS FirstOrderDate
FROM t
WHERE CustomerID IN (42, 77, 105)
WINDOW w AS (PARTITION BY CustomerID ORDER BY OrderDate)              -- named WINDOW clause (SQL 2022+)
ORDER BY CustomerID, OrderDate;
GO

-- 2b. Top 3 products per category (DENSE_RANK keeps ties) + share of category sales
WITH p AS (
    SELECT pr.CategoryID, pr.ProductID, pr.ProductName, SUM(v.NetSales) AS NetSales
    FROM sales.vw_ProductSalesDaily AS v WITH (NOEXPAND)
    JOIN catalog.Product AS pr ON pr.ProductID = v.ProductID
    GROUP BY pr.CategoryID, pr.ProductID, pr.ProductName
)
SELECT *
FROM (
    SELECT p.*,
           DENSE_RANK() OVER (PARTITION BY CategoryID ORDER BY NetSales DESC)            AS RankInCategory,
           CAST(100.0 * NetSales / SUM(NetSales) OVER (PARTITION BY CategoryID) AS decimal(5, 2)) AS PctOfCategory
    FROM p
) AS ranked
WHERE RankInCategory <= 3
ORDER BY CategoryID, RankInCategory;
GO

-- 2c. 7-day moving average of daily sales (frame = ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
WITH d AS (
    SELECT SalesDate, SUM(NetSales) AS NetSales
    FROM sales.vw_ProductSalesDaily WITH (NOEXPAND)
    GROUP BY SalesDate
)
SELECT SalesDate, NetSales,
       AVG(NetSales) OVER (ORDER BY SalesDate ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS MovingAvg7d,
       NetSales - LAG(NetSales, 7) OVER (ORDER BY SalesDate)                              AS DeltaVsSameDayLastWeek
FROM d
ORDER BY SalesDate;
GO

-- 2d. Segment customers into revenue quartiles and compute percentile rank
WITH r AS (
    SELECT o.CustomerID, SUM(l.LineTotal) AS Revenue
    FROM sales.SalesOrder AS o JOIN sales.SalesOrderLine AS l ON l.OrderID = o.OrderID
    GROUP BY o.CustomerID
)
SELECT TOP (20) CustomerID, Revenue,
       NTILE(4) OVER (ORDER BY Revenue DESC)                 AS RevenueQuartile,
       CAST(PERCENT_RANK() OVER (ORDER BY Revenue) AS decimal(5, 4)) AS PctRank
FROM r
ORDER BY Revenue DESC;
GO
-- Your turn 2: for each store, find the day with the highest sales and its rank vs. other stores that day.

/* =============================================================================================
   3. JSON
   ============================================================================================= */

-- 3a. Read: JSON_VALUE for scalars, OPENJSON to explode arrays, JSON_CONTAINS to search arrays
SELECT ProductID, ProductName,
       JSON_VALUE(Attributes, '$.weight_g')   AS WeightG,
       JSON_VALUE(Attributes, '$.waterproof') AS Waterproof
FROM catalog.Product
WHERE JSON_VALUE(Attributes, '$.waterproof') = 'true'
  AND JSON_CONTAINS(Attributes, N'Moss', '$.colors[*]') = 1;      -- uses JX_Product_Attributes when present

SELECT p.ProductID, p.ProductName, c.Color
FROM catalog.Product AS p
CROSS APPLY OPENJSON(p.Attributes, '$.colors') WITH (Color nvarchar(30) '$') AS c
WHERE p.CategoryID = 4;
GO

-- 3b. Write: build an API-shaped document with JSON_OBJECT / JSON_ARRAY / JSON_ARRAYAGG.
--     JSON_QUERY() marks the nested subquery result as JSON so it is not escaped as a string.
SELECT TOP (3)
    JSON_OBJECT(
        'orderNumber': o.OrderNumber,
        'orderDate'  : o.OrderDate,
        'channel'    : o.Channel,
        'tags'       : JSON_ARRAY(o.SalesRegion, o.Status),
        'shipping'   : JSON_QUERY(CAST(o.ShippingInfo AS nvarchar(max))),
        'lines'      : JSON_QUERY((SELECT JSON_ARRAYAGG(JSON_OBJECT('sku': p.SKU, 'qty': l.Quantity, 'total': l.LineTotal)
                                                      ORDER BY l.LineNumber)
                                   FROM sales.SalesOrderLine AS l
                                   JOIN catalog.Product AS p ON p.ProductID = l.ProductID
                                   WHERE l.OrderID = o.OrderID))
    ) AS OrderDocument
FROM sales.SalesOrder AS o
WHERE o.Channel = 'Online'
ORDER BY o.OrderID;
GO

-- 3c. The classic alternative: FOR JSON PATH (dot-separated aliases create nesting)
SELECT TOP (2) o.OrderNumber AS [order.number], o.OrderDate AS [order.date],
       (SELECT l.ProductID AS productId, l.Quantity AS qty FROM sales.SalesOrderLine AS l
        WHERE l.OrderID = o.OrderID FOR JSON PATH) AS lines
FROM sales.SalesOrder AS o
FOR JSON PATH, ROOT('orders');
GO

-- 3d. Modify a JSON property in place (cast json -> nvarchar for JSON_MODIFY, assign back)
UPDATE sales.SalesOrder
SET ShippingInfo = JSON_MODIFY(CAST(ShippingInfo AS nvarchar(max)), '$.express', CAST(1 AS bit))
WHERE OrderID = (SELECT MIN(OrderID) FROM sales.SalesOrder WHERE Channel = 'Online');
GO
-- Your turn 3: list carriers with the count of express vs standard online orders (hint: JSON_VALUE + GROUP BY).

/* =============================================================================================
   4. REGULAR EXPRESSIONS (compat level 170; RE2 syntax)
   ============================================================================================= */

-- 4a. REGEXP_LIKE: validate e-mail format
SELECT CustomerID, Email
FROM crm.Customer
WHERE Email IS NOT NULL
  AND NOT REGEXP_LIKE(Email, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');

-- 4b. REGEXP_SUBSTR / REGEXP_INSTR: pull order numbers out of free-text tickets
SELECT TOP (10) TicketID,
       REGEXP_SUBSTR(Body, 'TH-[0-9]{8}') AS OrderNumberMentioned,
       REGEXP_INSTR(Body, 'TH-[0-9]{8}')  AS FoundAtPosition,
       Body
FROM support.Ticket
WHERE REGEXP_LIKE(Body, 'TH-[0-9]{8}');

-- 4c. REGEXP_REPLACE: normalize phone numbers in ticket text to digits only (keep a leading +).
--     A capture group anchors on the words before the number, so order numbers (TH-0010...) aren't caught.
--     REGEXP_SUBSTR(text, pattern, start, occurrence, flags, group)
SELECT TOP (10) TicketID,
       REGEXP_SUBSTR(Body, '(?:call me at|new phone:)\s*(\(?\+?[0-9][0-9 ()\-]{6,}[0-9])', 1, 1, 'i', 1) AS RawPhone,
       REGEXP_REPLACE(
           REGEXP_SUBSTR(Body, '(?:call me at|new phone:)\s*(\(?\+?[0-9][0-9 ()\-]{6,}[0-9])', 1, 1, 'i', 1),
           '[^0-9+]', '')                                                                                  AS NormalizedPhone
FROM support.Ticket
WHERE REGEXP_LIKE(Body, 'call me at|new phone:', 'i');

-- 4d. REGEXP_COUNT: how often do reviews mention leaking? ('i' = case-insensitive)
SELECT TOP (10) ReviewID, Rating, REGEXP_COUNT(ReviewText, '\bleak(s|ed|ing)?\b', 1, 'i') AS LeakMentions, ReviewText
FROM catalog.ProductReview
WHERE REGEXP_COUNT(ReviewText, '\bleak(s|ed|ing)?\b', 1, 'i') > 0
ORDER BY LeakMentions DESC;

-- 4e. Table-valued regex functions: every match with positions, and splitting text into sentences
SELECT t.TicketID, m.*
FROM support.Ticket AS t
CROSS APPLY REGEXP_MATCHES(t.Body, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') AS m
WHERE t.TicketID <= 60;

SELECT r.ReviewID, s.ordinal, LTRIM(s.value) AS Sentence
FROM catalog.ProductReview AS r
CROSS APPLY REGEXP_SPLIT_TO_TABLE(r.ReviewText, '(?:[.!?])\s+') AS s
WHERE r.ReviewID IN (1, 2, 3);
GO
-- Your turn 4: mask everything but the last 4 digits of any phone number found in ticket bodies.

/* =============================================================================================
   5. FUZZY STRING MATCHING (preview: needs PREVIEW_FEATURES on SQL Server 2025)
   The seed contains ~18 near-duplicate customers (typos). Find them.
   Answer key: data-generator/answer_keys_default/near_duplicate_customers.csv
   ============================================================================================= */
SELECT 'Colour' AS A, 'Color' AS B,
       EDIT_DISTANCE('Colour', 'Color')            AS EditDistance,        -- Damerau-Levenshtein edits
       EDIT_DISTANCE_SIMILARITY('Colour', 'Color') AS EditSimilarity,      -- 0..100
       JARO_WINKLER_DISTANCE('Colour', 'Color')    AS JaroWinklerDistance, -- 0 = identical
       JARO_WINKLER_SIMILARITY('Colour', 'Color')  AS JaroWinklerSimilarity;

WITH c AS (
    SELECT CustomerID, CONCAT(FirstName, N' ', LastName) AS FullName, City, Country, Email
    FROM crm.Customer
)
SELECT a.CustomerID AS IdA, b.CustomerID AS IdB, a.FullName AS NameA, b.FullName AS NameB, a.City,
       EDIT_DISTANCE(a.FullName, b.FullName, 3)          AS EditDistance,     -- stop counting after 3
       EDIT_DISTANCE_SIMILARITY(a.FullName, b.FullName)  AS Similarity,
       CAST(JARO_WINKLER_DISTANCE(a.FullName, b.FullName) AS decimal(5, 4)) AS JWDistance
FROM c AS a
JOIN c AS b
  ON a.CustomerID < b.CustomerID
 AND a.Country = b.Country                              -- "blocking key": never compare everything with everything
WHERE EDIT_DISTANCE(a.FullName, b.FullName, 2) BETWEEN 1 AND 2
ORDER BY EditDistance, JWDistance;
GO
-- Note: identical names (distance 0) are common in real data and are NOT necessarily duplicates.
-- Your turn 5: search products tolerant to typos, e.g. user typed 'hedlamp' or 'slepping bag'.

/* =============================================================================================
   6. GRAPH: MATCH and SHORTEST_PATH
   ============================================================================================= */

-- 6a. Load nodes and edges from the relational tables
DELETE FROM kg.Referred; DELETE FROM kg.BoughtWith; DELETE FROM kg.CustomerNode; DELETE FROM kg.ProductNode;

INSERT kg.CustomerNode (CustomerID, DisplayName)
SELECT CustomerID, CONCAT(FirstName, N' ', LastName) FROM crm.Customer;

INSERT kg.ProductNode (ProductID, ProductName)
SELECT ProductID, ProductName FROM catalog.Product;

INSERT kg.Referred ($from_id, $to_id, ReferredOn)              -- direction: referrer -> new customer
SELECT referrer.$node_id, newbie.$node_id, CAST(c.CreatedAt AS date)
FROM crm.Customer AS c
JOIN kg.CustomerNode AS newbie   ON newbie.CustomerID = c.CustomerID
JOIN kg.CustomerNode AS referrer ON referrer.CustomerID = c.ReferredByCustomerID;

INSERT kg.BoughtWith ($from_id, $to_id, TimesTogether)
SELECT pa.$node_id, pb.$node_id, x.Cnt
FROM (
    SELECT a.ProductID AS P1, b.ProductID AS P2, COUNT(*) AS Cnt
    FROM sales.SalesOrderLine AS a
    JOIN sales.SalesOrderLine AS b ON b.OrderID = a.OrderID AND a.ProductID < b.ProductID
    GROUP BY a.ProductID, b.ProductID
    HAVING COUNT(*) >= 2
) AS x
JOIN kg.ProductNode AS pa ON pa.ProductID = x.P1
JOIN kg.ProductNode AS pb ON pb.ProductID = x.P2;
GO

-- 6b. Two hops: who did the people referred by customer X refer?
DECLARE @x int = (SELECT TOP (1) ReferredByCustomerID FROM crm.Customer
                  WHERE ReferredByCustomerID IS NOT NULL GROUP BY ReferredByCustomerID ORDER BY COUNT(*) DESC);
SELECT a.DisplayName AS Referrer, b.DisplayName AS Referred, c.DisplayName AS ReferredBySecondLevel
FROM kg.CustomerNode AS a, kg.Referred AS r1, kg.CustomerNode AS b, kg.Referred AS r2, kg.CustomerNode AS c
WHERE MATCH(a-(r1)->b-(r2)->c)
  AND a.CustomerID = @x;
GO

-- 6c. SHORTEST_PATH: every customer reachable from a root referrer, with the chain and hop count
DECLARE @root int = (SELECT TOP (1) c.CustomerID FROM crm.Customer AS c
                     WHERE c.ReferredByCustomerID IS NULL
                       AND EXISTS (SELECT 1 FROM crm.Customer AS x WHERE x.ReferredByCustomerID = c.CustomerID)
                     ORDER BY c.CustomerID);
SELECT a.DisplayName AS Root,
       STRING_AGG(b.DisplayName, N' -> ') WITHIN GROUP (GRAPH PATH) AS Chain,
       COUNT(b.CustomerID)                 WITHIN GROUP (GRAPH PATH) AS Hops
FROM kg.CustomerNode AS a,
     kg.Referred FOR PATH AS r,
     kg.CustomerNode FOR PATH AS b
WHERE MATCH(SHORTEST_PATH(a(-(r)->b)+))
  AND a.CustomerID = @root;
GO

-- 6d. "Frequently bought together" for a product, both directions of the undirected relationship
DECLARE @p int = 1;
SELECT other.ProductName, bw.TimesTogether
FROM kg.ProductNode AS me, kg.BoughtWith AS bw, kg.ProductNode AS other
WHERE MATCH(me-(bw)->other) AND me.ProductID = @p
UNION ALL
SELECT other.ProductName, bw.TimesTogether
FROM kg.ProductNode AS me, kg.BoughtWith AS bw, kg.ProductNode AS other
WHERE MATCH(other-(bw)->me) AND me.ProductID = @p
ORDER BY TimesTogether DESC;
GO

/* =============================================================================================
   7. CORRELATED QUERIES
   ============================================================================================= */

-- 7a. Correlated subquery in WHERE: orders bigger than that customer's own average
SELECT o.CustomerID, o.OrderID, v.OrderTotal
FROM sales.SalesOrder AS o
JOIN sales.vw_OrderSummary AS v ON v.OrderID = o.OrderID
WHERE v.OrderTotal > (SELECT AVG(v2.OrderTotal) * 2
                      FROM sales.vw_OrderSummary AS v2
                      WHERE v2.CustomerID = o.CustomerID)       -- references the outer row
ORDER BY v.OrderTotal DESC;

-- 7b. NOT EXISTS: active products that were never reviewed
SELECT p.ProductID, p.ProductName
FROM catalog.Product AS p
WHERE p.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM catalog.ProductReview AS r WHERE r.ProductID = p.ProductID);

-- 7c. CROSS APPLY + TOP (1): latest order per customer (a correlated "top-N per group")
SELECT TOP (10) c.CustomerID, c.LastName, last_order.OrderNumber, last_order.OrderDate
FROM crm.Customer AS c
CROSS APPLY (SELECT TOP (1) o.OrderNumber, o.OrderDate
             FROM sales.SalesOrder AS o
             WHERE o.CustomerID = c.CustomerID
             ORDER BY o.OrderDate DESC) AS last_order
ORDER BY last_order.OrderDate DESC;
GO

/* =============================================================================================
   8. TEMPORAL QUERIES (bonus, ties back to lab 1)
   ============================================================================================= */
UPDATE crm.Customer SET City = N'Liepaja', LoyaltyTier = 'Gold' WHERE CustomerID = 2;
WAITFOR DELAY '00:00:02';
UPDATE crm.Customer SET City = N'Daugavpils' WHERE CustomerID = 2;

SELECT CustomerID, City, LoyaltyTier, ValidFrom, ValidTo        -- hidden columns must be named explicitly
FROM crm.Customer FOR SYSTEM_TIME ALL
WHERE CustomerID = 2
ORDER BY ValidFrom;

DECLARE @asOf datetime2(2) = DATEADD(SECOND, -1, SYSUTCDATETIME());
SELECT CustomerID, City FROM crm.Customer FOR SYSTEM_TIME AS OF @asOf WHERE CustomerID = 2;
GO

/* =============================================================================================
   9. ERROR HANDLING
   ============================================================================================= */

-- 9a. THROW vs RAISERROR: THROW always ends the batch/TRY block (severity 16) and re-raises with no
--     args; RAISERROR supports printf-style args and lower severities (informational, WITH NOWAIT).
BEGIN TRY
    RAISERROR (N'Progress: %d of %d', 0, 1, 5, 10) WITH NOWAIT;   -- severity 0 = message only, no CATCH
    THROW 50100, N'Business rule failed.', 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrNo, ERROR_SEVERITY() AS Sev, ERROR_STATE() AS St, ERROR_MESSAGE() AS Msg;
END CATCH;
GO

-- 9b. SAVEPOINTS: undo part of a transaction. Works only while XACT_STATE() = 1 (XACT_ABORT OFF).
SET XACT_ABORT OFF;
BEGIN TRANSACTION;
    UPDATE catalog.Product SET Description = Description + N' ' WHERE ProductID = 10;
    SAVE TRANSACTION BeforeRiskyPart;
    BEGIN TRY
        UPDATE catalog.Product SET ListPrice = -1 WHERE ProductID = 10;     -- violates CHECK
    END TRY
    BEGIN CATCH
        SELECT XACT_STATE() AS XactState, ERROR_MESSAGE() AS Msg;          -- 1 = still committable
        IF XACT_STATE() = 1 ROLLBACK TRANSACTION BeforeRiskyPart;
    END CATCH;
COMMIT TRANSACTION;          -- the first update survives
SET XACT_ABORT ON;           -- Re-run with XACT_ABORT ON: what is XACT_STATE() now, and why?
GO
