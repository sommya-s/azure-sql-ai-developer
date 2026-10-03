/* =============================================================================================
   DP-800 · Lab 11 · 11_change_events_and_monitoring.sql — Integrate SQL with Azure services
   ---------------------------------------------------------------------------------------------
   Exam skills: handle changes by using change event streaming (CES), change data capture (CDC),
   Change Tracking, Azure Functions with SQL trigger binding, or Azure Logic Apps; recommend Azure
   Monitor configurations (Application Insights, Log Analytics).
   (Data API builder — the other half of this skill area — is in ../data-api-builder/.)
   ============================================================================================= */

/* =============================================================================================
   1. WHICH CHANGE MECHANISM?
   ---------------------------------------------------------------------------------------------
   | Mechanism            | What you get                          | Push/pull | Typical consumer                    |
   |----------------------|---------------------------------------|-----------|-------------------------------------|
   | Change Tracking      | WHICH rows changed (keys + op), no    | pull      | sync jobs, Azure Functions SQL       |
   |                      | old values; lightweight, synchronous  |           | trigger binding, embedding refresh  |
   | CDC                  | full before/after row images from the | pull      | ETL/ELT, audit, Fabric mirroring-   |
   |                      | log, async capture job                |           | style replication, data lake loads  |
   | Change event         | each change as a CloudEvent pushed to | PUSH      | Event Hubs -> Fabric Eventstream,   |
   |   streaming (CES)    | Azure Event Hubs, near-real-time      |           | microservices, real-time analytics  |
   | Trigger              | anything, in the same transaction     | sync      | tiny side effects only              |
   | Logic Apps SQL       | low-code workflow on new/changed rows | poll      | notifications, approvals, SaaS glue |
   |   connector trigger  |                                       |           |                                     |
   Fabric SQL database: no CDC (it already mirrors to OneLake automatically).
   ============================================================================================= */

/* =============================================================================================
   2. CHANGE TRACKING (already on for catalog.Product in lab 7) — add orders for the Function app
   ============================================================================================= */
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'catalog.ProductReview'))
    ALTER TABLE catalog.ProductReview ENABLE CHANGE_TRACKING;     -- used by ../azure-function (SQL trigger binding)
GO
DECLARE @v bigint = CHANGE_TRACKING_CURRENT_VERSION();
INSERT catalog.ProductReview (ReviewID, ProductID, CustomerID, Rating, Title, ReviewText, ReviewDate)
VALUES ((SELECT MAX(ReviewID) + 1 FROM catalog.ProductReview), 1, 42, 5, N'Lab test',
        N'Kept my feet dry on a week of rain in Lapland.', CAST(SYSUTCDATETIME() AS date));
SELECT ct.ReviewID, ct.SYS_CHANGE_OPERATION, ct.SYS_CHANGE_VERSION
FROM CHANGETABLE(CHANGES catalog.ProductReview, @v) AS ct;
GO

/* =============================================================================================
   3. CHANGE DATA CAPTURE (Azure SQL DB vCore or S3+, SQL Server; NOT Fabric SQL DB)
   ============================================================================================= */
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND is_cdc_enabled = 1)
    EXEC sys.sp_cdc_enable_db;
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID(N'sales.SalesOrder') AND is_tracked_by_cdc = 1)
    EXEC sys.sp_cdc_enable_table
         @source_schema        = N'sales',
         @source_name          = N'SalesOrder',
         @role_name            = NULL,                 -- or a gating role that may read change data
         @supports_net_changes = 1,                    -- requires a PK/unique index; enables net-change function
         @captured_column_list = N'OrderID, CustomerID, Status, SalesRegion, ModifiedAt';
GO
-- Make a change, wait for the capture job (Azure SQL DB runs it for you; SQL Server needs SQL Agent)
UPDATE sales.SalesOrder SET Status = 'Shipped' WHERE OrderID = (SELECT MIN(OrderID) FROM sales.SalesOrder WHERE Status = 'Placed');
WAITFOR DELAY '00:00:20';
GO
DECLARE @from binary(10) = sys.fn_cdc_get_min_lsn(N'sales_SalesOrder'),
        @to   binary(10) = sys.fn_cdc_get_max_lsn();
SELECT __$operation AS Op,                 -- 1 delete, 2 insert, 3 update (before), 4 update (after)
       sys.fn_cdc_map_lsn_to_time(__$start_lsn) AS ChangedAt,
       OrderID, Status, ModifiedAt
FROM cdc.fn_cdc_get_all_changes_sales_SalesOrder(@from, @to, N'all update old')
ORDER BY __$start_lsn, __$seqval, __$operation;
GO

/* =============================================================================================
   4. CHANGE EVENT STREAMING (preview) — push row changes to Azure Event Hubs as CloudEvents.
      Then in Fabric: Eventstream -> Add source -> Azure Event Hubs -> route to an Eventhouse.
      That connects this DP-800 database to the DP-700 real-time lab.
      Confirm current procedure names/parameters in the "Configure change event streaming" docs.

   -- credential for Event Hubs (SAS key shown; managed identity is preferred where supported)
   CREATE DATABASE SCOPED CREDENTIAL TrailheadEhCred
       WITH IDENTITY = 'SHARED ACCESS SIGNATURE', SECRET = '<sas-token>';
   EXEC sys.sp_enable_event_stream;
   EXEC sys.sp_create_event_stream_group
        @stream_group_name      = N'TrailheadOrders',
        @destination_type       = N'AzureEventHubsApacheKafka',      -- 'AzureEventHubs' on Azure SQL DB
        @destination_location   = N'<namespace>.servicebus.windows.net:9093/<event-hub>',
        @destination_credential = TrailheadEhCred,
        @partition_key_scheme   = N'Table';
   EXEC sys.sp_add_object_to_event_stream_group N'TrailheadOrders', N'sales.SalesOrder';
   -- every INSERT/UPDATE/DELETE on sales.SalesOrder is now published as a JSON event             */

/* =============================================================================================
   5. AZURE FUNCTIONS SQL TRIGGER BINDING  -> see ../azure-function/function_app.py
      Uses Change Tracking (section 2) under the hood: new/changed reviews are delivered to the
      function in batches; the function can embed them, call an API, or post to Teams.
      Needs a lease table it creates itself (az_func.*) and the identity to have
      VIEW CHANGE TRACKING + SELECT on the table:
   GRANT VIEW CHANGE TRACKING ON catalog.ProductReview TO [func-trailhead];
   GRANT SELECT ON catalog.ProductReview TO [func-trailhead];
   GRANT CREATE TABLE TO [func-trailhead]; GRANT ALTER ON SCHEMA::az_func TO [func-trailhead];   -- lease tables

   AZURE LOGIC APPS: SQL Server connector trigger "When an item is created (V2)" / "modified (V2)"
   polls a table (needs an IDENTITY/rowversion column) -> e.g. post negative reviews (Rating <= 2)
   to a Teams channel and create a support ticket. Low-code; good for workflows with approvals.   */

/* =============================================================================================
   6. MONITORING WITH AZURE MONITOR — recommended configuration
   ---------------------------------------------------------------------------------------------
   Azure SQL Database -> Diagnostic settings -> send to a Log Analytics workspace:
     * SQLInsights, QueryStoreRuntimeStatistics, QueryStoreWaitStatistics  (query performance)
     * Errors, DatabaseWaitStatistics, Timeouts, Blocks, Deadlocks        (troubleshooting)
     * AutomaticTuning                                                    (plan forcing actions)
     * Basic / InstanceAndAppAdvanced metrics                             (CPU, IO, storage)
     * SQLSecurityAuditEvents comes from Auditing (lab 5), same workspace
   Alerts (metric alert rules): CPU % > 80 for 15 min, deadlocks > 0, storage % > 85,
     failed connections spike. Action group -> e-mail/Teams.
   Application Insights on the API tier (Data API builder / Function app): dependency telemetry
     shows each SQL call's duration and failures from the app's point of view; correlate with
     Log Analytics via the same workspace. DAB has built-in Application Insights support
     (runtime.telemetry.application-insights in dab-config.json).
   Database watcher (Azure SQL) is the newer managed option for collecting detailed DMV data
     into Azure Data Explorer / Fabric Real-Time Intelligence.

   Sample KQL (Log Analytics):
     AzureDiagnostics
     | where Category == "Deadlocks"
     | project TimeGenerated, DatabaseName_s, deadlock_xml_s

     AzureDiagnostics
     | where Category == "QueryStoreRuntimeStatistics"
     | summarize total_cpu_ms = sum(cpu_time_d) / 1000 by query_hash_s
     | top 10 by total_cpu_ms

     AppDependencies                      // Application Insights
     | where Type == "SQL"
     | summarize p95 = percentile(DurationMs, 95), failures = countif(Success == false) by Target
   ============================================================================================= */
