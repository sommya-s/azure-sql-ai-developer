# Lab 10b — Data API builder: REST, GraphQL and MCP over TrailheadOps

**Exam skills (DP-800 → Integrate SQL solutions with Azure services / Secure GraphQL, REST and MCP endpoints)**
create DAB configuration files · configure entities for REST and GraphQL (caching, pagination, searching, filtering) · expose tables, views and stored procedures, including GraphQL relationships · configure and implement DAB deployment · secure the endpoints.

## 1. Install and run locally

```bash
dotnet tool install --global Microsoft.DataApiBuilder      # needs .NET 8 SDK; `dab --version`
cd data-api-builder
export DAB_CONNECTION_STRING="Server=tcp:<server>.database.windows.net;Database=TrailheadOps;Authentication=Active Directory Default;Encrypt=True;"
export DAB_ENVIRONMENT=Development      # merges dab-config.Development.json over dab-config.json
dab validate
dab start
```

`dab-config.json` is production-shaped (Entra ID auth, no introspection). `dab-config.Development.json` overrides just what local work needs (Simulator auth, introspection, localhost CORS). That base + environment-override split is the pattern to know for deployment.

### Build the same config with the CLI (do this once to learn the commands)

```bash
dab init --database-type mssql --connection-string "@env('DAB_CONNECTION_STRING')" --set-session-context true --config my-dab.json
dab add Category --source catalog.Category --permissions "anonymous:read" --config my-dab.json
dab add Product  --source catalog.vw_ActiveProduct --source.type view --source.key-fields "ProductID" --permissions "anonymous:read" --config my-dab.json
dab update Category --relationship products --target.entity Product --cardinality many \
    --relationship.fields "CategoryID:CategoryID" --config my-dab.json
dab add Search --source ai.usp_HybridSearch --source.type stored-procedure --permissions "anonymous:execute" \
    --rest.methods "get,post" --graphql.operation query --config my-dab.json
dab configure --runtime.mcp.enabled true --config my-dab.json
```

Diff `my-dab.json` against `dab-config.json` to see what the CLI generated vs what was hand-tuned.

## 2. Try the endpoints

**REST** — filtering, sorting, projection and paging are OData-style query options:

```bash
curl "http://localhost:5000/api/products?\$filter=Brand eq 'Alpenfox' and ListPrice lt 200&\$orderby=ListPrice desc&\$select=ProductID,ProductName,ListPrice&\$first=5"
# Response contains "nextLink" when more pages exist -> follow it (cursor-based pagination)
curl "http://localhost:5000/api/search?Query=tent%20for%20strong%20wind&Top=5"
curl -X POST http://localhost:5000/api/place-order -H "Content-Type: application/json" \
     -H "X-MS-API-ROLE: authenticated" \
     -d '{"CustomerID": 42, "Channel": "Online", "Lines": "[{\"productId\":1,\"qty\":1}]"}'
```

**GraphQL** — open `http://localhost:5000/graphql` (Banana Cake Pop / Nitro UI in development mode):

```graphql
{
  categories(filter: { Department: { eq: "Camping" } }) {
    items {
      CategoryName
      products(first: 3, orderBy: { ListPrice: DESC }) {
        items { ProductName ListPrice }
      }
    }
  }
}
```

Relationships declared in the config become nested fields — that is "expose GraphQL relationships".

**MCP** — the same entities become tools for AI agents (SQL MCP Server). In VS Code add `.vscode/mcp.json` (template in `../copilot/mcp.json`), then ask Copilot Chat in Agent mode: *"Using trailhead-sql, find the three cheapest Alpenfox products and search reviews about wind."* Entities expose the generic DML tools (`describe_entities`, `read_records`, …); `PlaceOrder` and `Search` are exposed as **custom tools** because of `"custom-tool": true`.

## 3. Security checklist (what the exam asks)

| Concern | Where it is handled here |
|---|---|
| Who is calling? | `runtime.host.authentication.provider = EntraId` + `jwt.audience/issuer` (production) |
| What can each role do? | `permissions[].role/actions` per entity; roles come from the token's `roles` claim, selected with the `X-MS-API-ROLE` header |
| Column exposure | `fields.include/exclude` (`Review` hides `CustomerID`), or expose a view (`Product` → `vw_ActiveProduct` hides cost) |
| Row filtering in the API | database policy on `OrderSummary`: `@item.SalesRegion eq @claims.region` |
| Row filtering in the database too | `set-session-context: true` sends token claims to `SESSION_CONTEXT`, which the lab 5 RLS predicate reads — defense in depth |
| DB credentials | `@env('DAB_CONNECTION_STRING')` with `Authentication=Active Directory Managed Identity` — no password anywhere |
| Schema discovery | `allow-introspection: false` in production; `depth-limit` caps expensive nested GraphQL queries |
| Browser access | explicit `cors.origins`, no wildcard |
| MCP | same roles/permissions apply to MCP tools; disable `dml-tools` you don't want agents to use (`dab configure --runtime.mcp.dml-tools.delete-record.enabled false`) |

The Simulator provider treats every request as authenticated and lets you pick the role with `X-MS-API-ROLE`; it does not create custom claims, so test the `@claims.region` policy with a real Entra token.

## 4. Deploy (Azure Container Apps)

```bash
RG=rg-trailhead; ACR=<youracr>; APP=ca-trailhead-dab
az acr build -r $ACR -t trailhead-dab:1 .
az containerapp env create -n cae-trailhead -g $RG -l westeurope
az containerapp create -n $APP -g $RG --environment cae-trailhead \
  --image $ACR.azurecr.io/trailhead-dab:1 --registry-server $ACR.azurecr.io \
  --target-port 5000 --ingress external --system-assigned \
  --env-vars DAB_CONNECTION_STRING="Server=tcp:<server>.database.windows.net;Database=TrailheadOps;Authentication=Active Directory Managed Identity;Encrypt=True;" \
             APPLICATIONINSIGHTS_CONNECTION_STRING="<from your App Insights resource>"
```

Then in the database, create a user for the container app's managed identity and grant it only what the API needs (lab 5 `role_api`):

```sql
CREATE USER [ca-trailhead-dab] FROM EXTERNAL PROVIDER;
ALTER ROLE role_api ADD MEMBER [ca-trailhead-dab];
GRANT EXECUTE ON ai.usp_HybridSearch TO role_api;
```

Alternatives to know: Azure Static Web Apps database connections (DAB built in), Azure App Service, AKS. Caching here is in-memory per instance (`L1`); a distributed `L1L2` level exists for multi-instance deployments.
