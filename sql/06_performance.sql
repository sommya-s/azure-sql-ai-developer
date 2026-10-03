/* =============================================================================================
   DP-800 · Lab 6 · 06_performance.sql — Optimize database performance
   ---------------------------------------------------------------------------------------------
   Exam skills: recommend database configurations; transaction isolation levels and concurrency
   controls; evaluate performance with execution plans, DMVs, Query Store, Query Performance Insight;
   identify and resolve blocking and deadlocks. Bonus: partition maintenance and elimination.

   Turn on "Include Actual Execution Plan" (Ctrl+M in SSMS) for sections 2-3.
   Sections 5-6 need TWO query windows (Session A and Session B) — follow the step numbers.
   ============================================================================================= */

/* =============================================================================================
   1. CONFIGURATION REVIEW — what is on, what should be on
   ============================================================================================= */
SELECT name, compatibility_level,
       is_read_committed_snapshot_on,          -- RCSI: readers don't block writers (ON by default in Azure SQL DB)
       snapshot_isolation_state_desc,          -- allows SET TRANSACTION ISOLATION LEVEL SNAPSHOT
       is_accelerated_database_recovery_on,    -- ADR: fast rollback/recovery, required for optimized locking
       is_query_store_on
FROM sys.databases
WHERE name = DB_NAME();

SELECT DATABASEPROPERTYEX(DB_NAME(), 'IsOptimizedLockingOn') AS OptimizedLocking;   -- Azure SQL DB / SQL 2025

SELECT name, value, is_value_default
FROM sys.database_scoped_configurations
WHERE name IN ('MAXDOP', 'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION', 'OPTIMIZED_PLAN_FORCING',
               'LEGACY_CARDINALITY_ESTIMATION', 'PREVIEW_FEATURES');

SELECT name, desired_state_desc, actual_state_desc, reason_desc
FROM sys.database_automatic_tuning_options;
GO

-- Typical recommendations for an OLTP + light analytics database like this one
ALTER DATABASE CURRENT SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = AUTO);
ALTER DATABASE CURRENT SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);    -- auto-revert plan regressions
-- SQL Server only (Azure SQL DB already has these on):
-- ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
-- ALTER DATABASE CURRENT SET ACCELERATED_DATABASE_RECOVERY = ON;
-- ALTER DATABASE CURRENT SET OPTIMIZED_LOCKING = ON;                       -- SQL Server 2025, needs ADR
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION ON;                     -- for the SNAPSHOT demo below
GO

/* =============================================================================================
   2. READ EXECUTION PLANS — three classic problems and their fixes
   ============================================================================================= */
SET STATISTICS IO, TIME ON;
GO
-- 2a. Non-SARGable predicate: a function on the column prevents an index seek
SELECT COUNT(*) FROM sales.SalesOrder WHERE YEAR(OrderDate) = 2026 AND MONTH(OrderDate) = 8;
-- Fix: rewrite as a range on the bare column (and index OrderDate if this is a hot query)
DROP INDEX IF EXISTS IX_SalesOrder_OrderDate ON sales.SalesOrder;
CREATE INDEX IX_SalesOrder_OrderDate ON sales.SalesOrder (OrderDate) INCLUDE (Status, SalesRegion);
SELECT COUNT(*) FROM sales.SalesOrder WHERE OrderDate >= '2026-08-01' AND OrderDate < '2026-09-01';
GO

-- 2b. Implicit conversion: SKU is varchar, the literal is nvarchar -> CONVERT_IMPLICIT on the column.
--     Look for the yellow warning on the SELECT operator and compare logical reads.
SELECT ProductID, ProductName FROM catalog.Product WHERE SKU = N'TH-01-00001';   -- watch the plan warning
SELECT ProductID, ProductName FROM catalog.Product WHERE SKU = 'TH-01-00001';    -- seek on UQ_Product_SKU
GO

-- 2c. Key lookups: the index finds rows but must fetch extra columns from the clustered index.
SELECT OrderID, OrderDate, Channel, ModifiedAt
FROM sales.SalesOrder
WHERE CustomerID = 42;                      -- IX_SalesOrder_Customer seek + Key Lookup (Channel, ModifiedAt)
-- Fix: a covering index (or add INCLUDE columns to the existing one)
DROP INDEX IF EXISTS IX_SalesOrder_Customer_Cover ON sales.SalesOrder;
CREATE INDEX IX_SalesOrder_Customer_Cover ON sales.SalesOrder (CustomerID, OrderDate) INCLUDE (Status, Channel, ModifiedAt);
SELECT OrderID, OrderDate, Channel, ModifiedAt FROM sales.SalesOrder WHERE CustomerID = 42;
DROP INDEX IF EXISTS IX_SalesOrder_Customer ON sales.SalesOrder;    -- now redundant: the new index is a superset
GO

-- 2d. Columnstore + batch mode: compare an aggregate over the NCCI with a forced rowstore plan
SELECT ProductID, SUM(Quantity * UnitPrice) AS Gross FROM sales.SalesOrderLine GROUP BY ProductID;
SELECT ProductID, SUM(Quantity * UnitPrice) AS Gross FROM sales.SalesOrderLine GROUP BY ProductID
OPTION (USE HINT ('DISALLOW_BATCH_MODE'), IGNORE_NONCLUSTERED_COLUMNSTORE_INDEX);
SET STATISTICS IO, TIME OFF;
GO

/* =============================================================================================
   3. DMVs — what is slow, what is missing, what is waiting
   ============================================================================================= */
-- 3a. Top cached queries by CPU
SELECT TOP (10)
       qs.execution_count,
       qs.total_worker_time / 1000 AS total_cpu_ms,
       qs.total_logical_reads,
       qs.total_elapsed_time / NULLIF(qs.execution_count, 0) / 1000 AS avg_elapsed_ms,
       SUBSTRING(st.text, qs.statement_start_offset / 2 + 1,
                 (CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END
                  - qs.statement_start_offset) / 2 + 1) AS statement_text,
       qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
ORDER BY qs.total_worker_time DESC;

-- 3b. Missing-index suggestions (treat as hints, not orders: they ignore existing similar indexes)
SELECT TOP (10) d.statement AS TableName, d.equality_columns, d.inequality_columns, d.included_columns,
       s.user_seeks, s.avg_user_impact
FROM sys.dm_db_missing_index_details AS d
JOIN sys.dm_db_missing_index_groups AS g ON g.index_handle = d.index_handle
JOIN sys.dm_db_missing_index_group_stats AS s ON s.group_handle = g.index_group_handle
ORDER BY s.user_seeks * s.avg_user_impact DESC;

-- 3c. Unused indexes cost writes for nothing
SELECT OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS TableName, i.name AS IndexName,
       us.user_seeks, us.user_scans, us.user_lookups, us.user_updates
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS us
       ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1 AND i.index_id > 1
ORDER BY ISNULL(us.user_seeks + us.user_scans + us.user_lookups, 0), us.user_updates DESC;

-- 3d. Database-level waits (Azure SQL DB). On SQL Server use sys.dm_os_wait_stats.
SELECT TOP (10) wait_type, waiting_tasks_count, wait_time_ms
FROM sys.dm_db_wait_stats
ORDER BY wait_time_ms DESC;
GO

/* =============================================================================================
   4. QUERY STORE — history of queries, plans and runtime stats that survives restarts
   ============================================================================================= */
-- 4a. Top queries by total duration in the last 24 hours
SELECT TOP (10) q.query_id, p.plan_id, qt.query_sql_text,
       SUM(rs.count_executions)                         AS executions,
       SUM(rs.avg_duration * rs.count_executions) / 1000 AS total_duration_ms,
       MAX(rs.max_logical_io_reads)                     AS max_reads
FROM sys.query_store_query_text AS qt
JOIN sys.query_store_query AS q ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE i.start_time > DATEADD(HOUR, -24, SYSUTCDATETIME())
GROUP BY q.query_id, p.plan_id, qt.query_sql_text
ORDER BY total_duration_ms DESC;

-- 4b. Queries with more than one plan (candidates for regression / plan forcing)
SELECT q.query_id, COUNT(DISTINCT p.plan_id) AS plans, MIN(qt.query_sql_text) AS sample_text
FROM sys.query_store_query AS q
JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
GROUP BY q.query_id
HAVING COUNT(DISTINCT p.plan_id) > 1;

/* 4c. Fix a regression without touching the code:
     EXEC sys.sp_query_store_force_plan   @query_id = <id>, @plan_id = <good plan>;
     EXEC sys.sp_query_store_unforce_plan @query_id = <id>, @plan_id = <plan>;
     -- or attach a hint to a query you can't edit (vendor app):
     EXEC sys.sp_query_store_set_hints @query_id = <id>, @query_hints = N'OPTION (RECOMPILE)';
   Azure portal: "Query Performance Insight" is a UI over Query Store data for Azure SQL Database
   (top CPU/duration/execution-count queries per time window). "Intelligent Insights" and
   "Automatic tuning" (create/drop index, force last good plan) build on the same telemetry.       */
GO

/* =============================================================================================
   5. ISOLATION LEVELS AND BLOCKING — two windows. Run the numbered steps in order.
   ============================================================================================= */
/* ---------- Session A ----------                         ---------- Session B ----------
   -- A1: start a write and DON'T commit
   BEGIN TRAN;
   UPDATE catalog.Product SET ListPrice = ListPrice + 1
   WHERE ProductID = 1;
                                                           -- B1: READ COMMITTED (+RCSI in Azure SQL):
                                                           SELECT ListPrice FROM catalog.Product WHERE ProductID = 1;
                                                           -- returns the OLD committed value, no blocking.
                                                           -- On SQL Server without RCSI this WAITS. Why?

                                                           -- B2: force a locking read:
                                                           SELECT ListPrice FROM catalog.Product WITH (READCOMMITTEDLOCK)
                                                           WHERE ProductID = 1;   -- blocked now
   -- A2: in a THIRD window, find the blocking chain:
   SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time, r.wait_resource,
          t.text AS running_sql
   FROM sys.dm_exec_requests AS r
   CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
   WHERE r.blocking_session_id <> 0;

   SELECT request_session_id, resource_type, resource_description, request_mode, request_status
   FROM sys.dm_tran_locks WHERE resource_database_id = DB_ID() AND resource_type IN ('KEY', 'PAGE', 'OBJECT');

   -- A3: release it
   ROLLBACK;
                                                           -- B2 completes.

   ---------- SNAPSHOT update conflict ----------
                                                           -- B3:
                                                           SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
                                                           BEGIN TRAN;
                                                           SELECT ListPrice FROM catalog.Product WHERE ProductID = 2;
   -- A4:
   UPDATE catalog.Product SET ListPrice = ListPrice + 1 WHERE ProductID = 2;
                                                           -- B4: update the row A changed after B's snapshot began:
                                                           UPDATE catalog.Product SET ListPrice = ListPrice + 2 WHERE ProductID = 2;
                                                           -- Msg 3960: snapshot isolation update conflict. Optimistic = detect, not wait.
                                                           ROLLBACK; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

   ---------- SERIALIZABLE range locks (phantom protection) ----------
                                                           -- B5:
                                                           SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
                                                           BEGIN TRAN;
                                                           SELECT COUNT(*) FROM sales.SalesOrder WHERE CustomerID = 42;
   -- A5: insert a new order for customer 42 -> blocked by the key-range lock
   EXEC sales.usp_PlaceOrder @CustomerID = 42, @Channel = 'Online', @Lines = N'[{"productId":1,"qty":1}]';
                                                           -- B6: COMMIT; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

   Summary to remember:
     READ UNCOMMITTED  dirty reads possible (NOLOCK) — avoid
     READ COMMITTED    default; with RCSI readers see last committed version, no S locks held
     REPEATABLE READ   S locks held to end of transaction; phantoms still possible
     SERIALIZABLE      key-range locks; no phantoms; most blocking
     SNAPSHOT          transaction-level consistent versioned reads; update conflicts raise 3960   */

/* =============================================================================================
   6. DEADLOCKS — reproduce, capture, fix
   ============================================================================================= */
-- 6a. Capture deadlock graphs. Azure SQL DB: a database-scoped Extended Events session.
IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'trailhead_deadlocks')
    DROP EVENT SESSION trailhead_deadlocks ON DATABASE;
CREATE EVENT SESSION trailhead_deadlocks ON DATABASE
    ADD EVENT sqlserver.database_xml_deadlock_report
    ADD TARGET package0.ring_buffer
    WITH (STARTUP_STATE = ON);
ALTER EVENT SESSION trailhead_deadlocks ON DATABASE STATE = START;
-- SQL Server: deadlocks are already in the built-in system_health session (xml_deadlock_report event),
-- or create the same session ON SERVER with event sqlserver.xml_deadlock_report.
GO
/* 6b. Reproduce: opposite access order.
   ---------- Session A ----------                         ---------- Session B ----------
   BEGIN TRAN;
   UPDATE catalog.Product SET StandardCost = StandardCost
   WHERE ProductID = 10;
                                                           BEGIN TRAN;
                                                           UPDATE catalog.Product SET StandardCost = StandardCost
                                                           WHERE ProductID = 20;
   UPDATE catalog.Product SET StandardCost = StandardCost
   WHERE ProductID = 20;          -- waits for B
                                                           UPDATE catalog.Product SET StandardCost = StandardCost
                                                           WHERE ProductID = 10;  -- cycle! one session gets Msg 1205
   ROLLBACK;  (in whichever session survived)                                                         */

-- 6c. Read the captured graph (save the XML as .xdl and open it in SSMS for the picture)
SELECT x.event_data.value('(@timestamp)[1]', 'datetime2') AS DeadlockTime,
       x.event_data.query('(data[@name="xml_report"]/value/deadlock)[1]') AS DeadlockGraph
FROM (SELECT CAST(t.target_data AS xml) AS target_xml
      FROM sys.dm_xe_database_session_targets AS t
      JOIN sys.dm_xe_database_sessions AS s ON s.address = t.event_session_address
      WHERE s.name = N'trailhead_deadlocks' AND t.target_name = N'ring_buffer') AS src
CROSS APPLY src.target_xml.nodes('//RingBufferTarget/event') AS x(event_data);
GO
/* 6d. Fixes, in order of preference:
     1. Access objects in the same order everywhere (e.g., always lowest ProductID first)
     2. Keep transactions short; no user interaction inside a transaction
     3. Index so updates touch fewer rows/pages (fewer locks, less overlap)
     4. Use RCSI/SNAPSHOT for readers so read-write deadlocks disappear
     5. Retry logic for error 1205 in the application (deadlocks can't be eliminated entirely)
     SET DEADLOCK_PRIORITY LOW marks a session as the preferred victim (e.g., batch jobs).         */

/* =============================================================================================
   7. PARTITIONING — elimination and maintenance on sales.WebEvent
   ============================================================================================= */
-- 7a. Rows per partition and boundaries
SELECT p.partition_number, prv.value AS LowerBoundary, p.rows
FROM sys.partitions AS p
JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
LEFT JOIN sys.partition_range_values AS prv
       ON prv.function_id = (SELECT function_id FROM sys.partition_functions WHERE name = N'pf_EventMonth')
      AND prv.boundary_id = p.partition_number - 1
WHERE p.object_id = OBJECT_ID(N'sales.WebEvent') AND i.index_id = 1
ORDER BY p.partition_number;

-- 7b. Partition elimination: check "Actual Partition Count" on the Columnstore Index Scan operator
SELECT EventType, COUNT(*) FROM sales.WebEvent WHERE EventDate >= '2026-08-01' AND EventDate < '2026-09-01' GROUP BY EventType;
SELECT $PARTITION.pf_EventMonth('2026-08-15') AS PartitionForDate;
GO
-- 7c. Sliding window: add next month, remove the oldest data fast
ALTER PARTITION SCHEME ps_EventMonth NEXT USED [PRIMARY];
ALTER PARTITION FUNCTION pf_EventMonth() SPLIT RANGE ('2026-11-01');          -- split an EMPTY range: cheap
TRUNCATE TABLE sales.WebEvent WITH (PARTITIONS (2));                           -- drop July in a metadata op
ALTER PARTITION FUNCTION pf_EventMonth() MERGE RANGE ('2026-07-01');           -- remove the empty boundary
/* SWITCH (not in Fabric SQL DB): move a partition to an identical staging table instantly, e.g. to archive
   CREATE TABLE sales.WebEvent_Archive (...same columns..., INDEX CCI CLUSTERED COLUMNSTORE) ON [PRIMARY];
   ALTER TABLE sales.WebEvent SWITCH PARTITION 2 TO sales.WebEvent_Archive;                          */
GO
