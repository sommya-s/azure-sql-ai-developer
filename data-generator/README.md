# Data generator

`generate_data.py` (standard library only) produces one deterministic dataset for all three tracks.

```bash
python generate_data.py                                  # ./output, 28 daily batches from 2026-08-01
python generate_data.py --days 35 --seed 7 --out ../output_35d
python generate_data.py --sql-seed ../sql/02_seed_data.sql
```

| Output | Contents | Used by |
|---|---|---|
| `output/landing/reference/` | `categories.csv`, `stores.csv` | DP-700 bronze |
| `output/landing/crm/customers/load_date=*/` | day-0 full extract, then daily deltas (`_change` = move / tier / email / new) | SCD2 lab |
| `output/landing/catalog/products/load_date=*/` | full extract + weekly price changes | type-1 dimension |
| `output/landing/sales/orders|order_lines/load_date=*/` | daily extracts (CSV, JSON column inside) | silver/gold |
| `output/landing/catalog/reviews/load_date=*/reviews.jsonl` | JSON Lines | silver, DP-800 text search |
| `output/landing/support/tickets/load_date=*/tickets.json` | JSON array with free text (order numbers, e-mails, phones) | PII redaction, regex |
| `output/landing/web/clickstream/event_date=*/events.jsonl` | sessions with page/product/cart/checkout/purchase events | streaming labs |
| `output/stream/clickstream_replay.jsonl` | all events in time order | `clickstream_sender.py` → Eventstream |
| `output/answer_keys/` | `expected_counts.json`, `near_duplicate_customers.csv` | check your results |

## Injected data problems (on purpose)

| Problem | Where | You should... |
|---|---|---|
| Exact duplicate orders/lines | orders, order_lines | deduplicate |
| Status updates in a later file (`Placed` first, final status 2-5 days later) | orders | upsert on latest `ModifiedAt` |
| Late-arriving orders (1-4 days) | orders | load by arrival, not by order date |
| `dd/MM/yyyy HH:mm` dates in an ISO column | orders | parse both formats |
| Missing `UnitPrice` | order_lines | impute from product price and flag |
| Negative quantity, unknown product | order_lines | quarantine with a reason |
| Missing / invalid e-mails, `latvia ` / `LATVIA` countries, phone formats | customers | standardize |
| New customers arriving one day after their first order | customers | inferred members (late-arriving dimension) |
| ~18 near-duplicate customers with typos | all customers | fuzzy matching (DP-800 lab 4) |
| Duplicate and day-late clickstream events | web events | watermark + dedup |

`clickstream_sender.py` (needs `pip install azure-eventhub`) replays events into a Fabric Eventstream custom endpoint in (accelerated) real time; `--inject-late` holds back ~3% of events for 2-10 minutes.
