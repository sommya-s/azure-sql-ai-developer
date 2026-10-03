CREATE VIEW sales.vw_OrderSummary
AS
SELECT o.OrderID,
       o.OrderNumber,
       o.OrderDate,
       o.Channel,
       o.SalesRegion,
       o.Status,
       c.CustomerID,
       CONCAT(c.FirstName, N' ', c.LastName) AS CustomerName,
       s.StoreName,
       COUNT(l.LineNumber)                    AS LineCount,
       SUM(l.LineTotal)                       AS OrderTotal
FROM sales.SalesOrder AS o
JOIN crm.Customer AS c ON c.CustomerID = o.CustomerID
LEFT JOIN sales.Store AS s ON s.StoreID = o.StoreID
LEFT JOIN sales.SalesOrderLine AS l ON l.OrderID = o.OrderID
GROUP BY o.OrderID, o.OrderNumber, o.OrderDate, o.Channel, o.SalesRegion, o.Status,
         c.CustomerID, c.FirstName, c.LastName, s.StoreName;
