/* Solutions for the "Your turn" exercises in 04_advanced_tsql.sql. Try first! */

-- 1. Customers brought in by each root referrer, directly or indirectly
WITH chain AS (
    SELECT CustomerID AS RootID, CustomerID, 0 AS Depth
    FROM crm.Customer
    WHERE ReferredByCustomerID IS NULL
    UNION ALL
    SELECT ch.RootID, c.CustomerID, ch.Depth + 1
    FROM crm.Customer AS c
    JOIN chain AS ch ON c.ReferredByCustomerID = ch.CustomerID
)
SELECT TOP (10) RootID, COUNT(*) - 1 AS CustomersBroughtIn, MAX(Depth) AS DeepestLevel
FROM chain
GROUP BY RootID
HAVING COUNT(*) > 1
ORDER BY CustomersBroughtIn DESC
OPTION (MAXRECURSION 50);
GO

-- 2. Best day per store, and that store's rank among all stores on that day
WITH daily AS (
    SELECT o.StoreID, CAST(o.OrderDate AS date) AS SalesDate, SUM(l.LineTotal) AS Sales
    FROM sales.SalesOrder AS o JOIN sales.SalesOrderLine AS l ON l.OrderID = o.OrderID
    WHERE o.StoreID IS NOT NULL AND o.Status <> 'Cancelled'
    GROUP BY o.StoreID, CAST(o.OrderDate AS date)
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY StoreID ORDER BY Sales DESC)   AS BestDayForStore,
           RANK()       OVER (PARTITION BY SalesDate ORDER BY Sales DESC) AS RankAmongStoresThatDay
    FROM daily
)
SELECT s.StoreName, r.SalesDate, r.Sales, r.RankAmongStoresThatDay
FROM ranked AS r JOIN sales.Store AS s ON s.StoreID = r.StoreID
WHERE r.BestDayForStore = 1
ORDER BY r.Sales DESC;
GO

-- 3. Express vs standard online orders per carrier
SELECT JSON_VALUE(ShippingInfo, '$.carrier') AS Carrier,
       SUM(CASE WHEN JSON_VALUE(ShippingInfo, '$.express') = 'true' THEN 1 ELSE 0 END) AS Express,
       SUM(CASE WHEN JSON_VALUE(ShippingInfo, '$.express') = 'true' THEN 0 ELSE 1 END) AS Standard
FROM sales.SalesOrder
WHERE Channel = 'Online'
GROUP BY JSON_VALUE(ShippingInfo, '$.carrier')
ORDER BY Carrier;
GO

-- 4. Mask all but the last 4 digits of phone numbers inside ticket text.
--    Find each phone with REGEXP_MATCHES, then rebuild it digit by digit.
SELECT t.TicketID, m.match_value AS PhoneFound,
       CONCAT(REGEXP_REPLACE(LEFT(m.match_value, LEN(m.match_value) - 4), '[0-9]', '*'),
              RIGHT(m.match_value, 4)) AS Masked
FROM support.Ticket AS t
CROSS APPLY REGEXP_MATCHES(t.Body, '\+[0-9][0-9 ]{6,}[0-9]|\([0-9]{2,4}\)\s?[0-9]{6,}|\b[0-9]{2}-[0-9]{3}-[0-9]{3}\b') AS m;
GO

-- 5. Typo-tolerant product search: compare the search term with each word of the product name
DECLARE @term nvarchar(50) = N'hedlamp';
SELECT TOP (5) p.ProductID, p.ProductName,
       MIN(EDIT_DISTANCE(LOWER(w.value), @term)) AS BestWordDistance,
       MAX(JARO_WINKLER_SIMILARITY(LOWER(w.value), @term)) AS BestWordSimilarity
FROM catalog.Product AS p
CROSS APPLY STRING_SPLIT(p.ProductName, N' ') AS w
GROUP BY p.ProductID, p.ProductName
ORDER BY BestWordDistance, BestWordSimilarity DESC;
GO
