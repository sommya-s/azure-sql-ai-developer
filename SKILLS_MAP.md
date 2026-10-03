# Skills map — every exam bullet → where you practise it

Source: the official Microsoft Learn study guides, *skills measured as of October 19, 2026* (DP-800). Exams change; check the study guide's change log before you rely on this list.

Legend: **file** = runnable artifact in this repo · *README step* = guided step in the track README (portal work).

---

## DP-800 — Developing AI-Enabled Database Solutions (SQL AI Developer Associate)

### Design and develop database solutions (35–40%)

| Skill | Where |
|---|---|
| Tables: data types, size, columns, indexes, columnstore indexes | `sql/01_schema.sql` §3–7, §9 (NCCI on order lines, partitioned CCI on web events) |
| Specialized tables: in-memory, temporal, external, ledger, graph | `01_schema.sql` §5 temporal, §8 ledger, §10 graph, §11 in-memory, §12 external; queries in `04_advanced_tsql.sql` §6, §8 |
| JSON columns and indexes | `01_schema.sql` §4 (`json` type + `CREATE JSON INDEX`); `04_advanced_tsql.sql` §3 |
| Constraints: PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK, DEFAULT | `01_schema.sql` (named constraints throughout, table-level CHECK) |
| SEQUENCES | `01_schema.sql` §2; `03_programmability.sql` 4a; `02_seed_data.sql` (RESTART) |
| Partitioning for tables and indexes | `01_schema.sql` §9; `06_performance.sql` §7 (elimination, SPLIT/MERGE/TRUNCATE partitions, SWITCH) |
| Create views | `03_programmability.sql` §1 (plain, indexed, updatable facade) |
| Create scalar functions | `03_programmability.sql` §2 (+ inlining check) |
| Create table-valued functions | `03_programmability.sql` §3 (inline vs multi-statement) |
| Create stored procedures | `03_programmability.sql` §4 |
| Create triggers | `03_programmability.sql` §5 (AFTER → ledger, AFTER audit column, INSTEAD OF on view); `07_embeddings.sql` 7a |
| CTEs | `04_advanced_tsql.sql` §1 (chained + recursive) |
| Window functions | `04_advanced_tsql.sql` §2 |
| JSON functions (JSON_OBJECT, JSON_ARRAY, JSON_ARRAYAGG, JSON_CONTAINS, OPENJSON, JSON_VALUE) | `04_advanced_tsql.sql` §3; `10_rag.sql` (payload building) |
| Regular expressions (REGEXP_LIKE/REPLACE/SUBSTR/INSTR/COUNT/MATCHES/SPLIT_TO_TABLE) | `04_advanced_tsql.sql` §4; `07_embeddings.sql` §4 (PII redaction) |
| Fuzzy matching (EDIT_DISTANCE, EDIT_DISTANCE_SIMILARITY, JARO_WINKLER_DISTANCE) | `04_advanced_tsql.sql` §5 (+ answer key `data-generator/answer_keys_default/near_duplicate_customers.csv`) |
| Graph queries with MATCH | `04_advanced_tsql.sql` §6 (MATCH, SHORTEST_PATH) |
| Correlated queries | `04_advanced_tsql.sql` §7 |
| Error handling | `03_programmability.sql` §4, §6c; `04_advanced_tsql.sql` §9 |
| Interpret security impact of AI-assisted tools | `README.md` lab 4b step 5; `copilot/copilot-instructions.md` (security rules) |
| Enable GitHub Copilot and Copilot in Fabric | *README lab 4b step 1* |
| Configure model and MCP tool options in a Copilot chat session | *README lab 4b step 3* |
| Create and configure GitHub Copilot instruction files | `copilot/copilot-instructions.md`; *lab 4b step 2* |
| Connect to MCP server endpoints (SQL Server, Fabric lakehouse) | `copilot/mcp.json` (DAB SQL MCP Server http + stdio, Fabric SQL endpoint MCP) |

### Secure, optimize, and deploy database solutions (35–40%)

| Skill | Where |
|---|---|
| Encryption: Always Encrypted, column-level encryption | `05_security.sql` §5 (symmetric key + authenticator), §6 (Always Encrypted wizard + comparison) |
| Dynamic Data Masking | `05_security.sql` §3 (granular UNMASK, inference demo); `database-project/crm/Tables/Customer.sql` |
| Row-Level Security | `05_security.sql` §4 (mapping table + SESSION_CONTEXT, filter + block predicates) |
| Object-level permissions | `05_security.sql` §1–2 (roles, schema grants, column DENY, ownership chaining) |
| Secure access, including passwordless | `05_security.sql` §1 (Entra users, `Active Directory Default`); `data-api-builder/README.md` §4; workflows use OIDC |
| Auditing | `05_security.sql` §7 (Azure SQL → Log Analytics, SQL Server audit) |
| Secure model endpoints, incl. Managed Identity | `07_embeddings.sql` §2 path A1; `azure-function/function_app.py` |
| Secure GraphQL, REST and MCP endpoints | `data-api-builder/dab-config.json` + README §3 |
| Recommend database configurations | `06_performance.sql` §1 |
| Isolation levels and concurrency controls | `06_performance.sql` §5; `03_programmability.sql` 4b (rowversion) |
| Execution plans, DMVs, Query Store, Query Performance Insight | `06_performance.sql` §2–4 |
| Blocking and deadlocks | `06_performance.sql` §5–6 (two-session repro, XE capture, fixes) |
| Testing strategy: unit and integration tests | `database-project/tests/` + CI job in `.github/workflows/sql-database-project.yml` |
| Reference/static data in source control | `database-project/Scripts/ReferenceData/*.sql` (idempotent MERGE in post-deployment) |
| Build/validate models with SQL Database Projects (SDK-style) | `database-project/TrailheadOps.sqlproj` (Microsoft.Build.Sql) |
| Source control for SQL Database Projects | *README lab 12* |
| Branching, pull requests, conflict resolution | *README lab 12 steps 3–4*; `.github/CODEOWNERS` |
| Secrets management | workflows (OIDC, repo secret only for the throwaway CI container); DAB `@env()`; Function app settings |
| Detect schema drift | `sql-database-project.yml` job `drift-detection` (SqlPackage DeployReport) |
| Update a project and deploy changes | `sql-database-project.yml` job `deploy-production` (script artifact + publish) |
| Deployment controls: branch policies, approvals, code owners | *README lab 12 steps 3, 7*; `.github/CODEOWNERS`; environment `production` |
| DAB configuration files | `data-api-builder/dab-config.json`, `dab-config.Development.json` |
| DAB entities: caching, pagination, searching, filtering | `dab-config.json` (`cache`, `pagination`); README §2 (`$filter`, `$orderby`, `$first`, GraphQL filters) |
| REST or GraphQL endpoints | `dab-config.json` `runtime.rest/graphql` |
| Expose tables, procedures, views, GraphQL relationships | `dab-config.json` entities (view `OrderSummary`, procedures `PlaceOrder`/`Search`, relationships) |
| DAB deployment | `data-api-builder/Dockerfile` + README §4 (Container Apps, managed identity) |
| Azure Monitor (Application Insights, Log Analytics) | `11_change_events_and_monitoring.sql` §6; DAB telemetry setting |
| Change handling: CES, CDC, Change Tracking, Functions SQL trigger, Logic Apps | `11_change_events_and_monitoring.sql` §1–5; `azure-function/` |

### Implement AI capabilities in database solutions (25–30%)

| Skill | Where |
|---|---|
| Evaluate external models (multimodal, multilanguage, size, structured output) | `07_embeddings.sql` §1 |
| Create and manage external models | `07_embeddings.sql` §2 (Azure OpenAI MI/key, Ollama; ALTER/DROP, GRANT EXECUTE) |
| Choose an embedding maintenance method | `07_embeddings.sql` §6–7 (trigger, Change Tracking, decision table); `azure-function/` |
| Which columns to include in embeddings | `07_embeddings.sql` §4 (`ai.vw_SourceDocument`, PII exclusion) |
| Design and implement chunks | `07_embeddings.sql` §5 (`AI_GENERATE_CHUNKS`, size/overlap trade-offs) |
| Generate embeddings | `07_embeddings.sql` §6 (`AI_GENERATE_EMBEDDINGS` batches; offline toy path) |
| Choose full-text, semantic vector or hybrid | `09_hybrid_search.sql` §1 |
| Implement full-text search | `09_hybrid_search.sql` §2 |
| Design for vector data (type, indexes, size) | `08_vector_search.sql` §1, §3 |
| VECTOR_NORMALIZE, VECTOR_DISTANCE, VECTORPROPERTY, VECTOR_SEARCH | `08_vector_search.sql` §1–3 |
| ANN vs KNN | `08_vector_search.sql` §2–5 |
| Vector index types and metrics | `08_vector_search.sql` §1, §3, §5 |
| Implement vector search | `08_vector_search.sql` §2–3 |
| Implement hybrid search | `09_hybrid_search.sql` §3 (`ai.usp_HybridSearch`) |
| Reciprocal rank fusion | `09_hybrid_search.sql` §3 |
| Evaluate performance of vector and hybrid search | `08_vector_search.sql` §4 (recall@10 + latency); `09_hybrid_search.sql` §4 |
| Use cases for RAG | `10_rag.sql` §1 |
| Prompt with `sp_invoke_external_rest_endpoint` | `10_rag.sql` §3c–3d |
| Convert structured data to JSON for the model | `10_rag.sql` §3b (`FOR JSON`, `JSON_ARRAYAGG`, `JSON_OBJECT`) |
| Send results to a language model | `10_rag.sql` §3d |
| Extract language model responses | `10_rag.sql` §3e (wrapper JSON, `OPENJSON` for > 4000 chars, structured output) |
