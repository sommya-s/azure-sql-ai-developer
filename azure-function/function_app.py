"""Azure Function: keep review embeddings fresh with the Azure SQL trigger binding.

DP-800 skills: "Azure Functions with SQL trigger binding" (integrate SQL with Azure services) and
"choose an embedding maintenance method" — the model call happens OUTSIDE the database, so writes
to catalog.ProductReview never wait on an AI service.

Flow
  catalog.ProductReview  --(Change Tracking)-->  SQL trigger binding  -->  this function
     -> Azure OpenAI embeddings (managed identity, no keys)
     -> SQL output binding upserts ai.ReviewVectorStaging (PK = ReviewID)
     -> ai.usp_MergeReviewVectors (setup.sql) moves staged vectors into ai.ContentChunk

Local run: func start   (needs Azure Functions Core Tools v4, Python 3.11+)
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os

import azure.functions as func
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AzureOpenAI

app = func.FunctionApp()

_token_provider = get_bearer_token_provider(DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default")
_client = AzureOpenAI(
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
    azure_ad_token_provider=_token_provider,          # passwordless: the Function's managed identity
    api_version="2024-10-21",
)
_DEPLOYMENT = os.environ.get("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-3-small")

INSERT, UPDATE, DELETE = 0, 1, 2                      # SqlChangeOperation values in the payload


@app.function_name(name="ReviewChanged")
@app.sql_trigger(arg_name="changes",
                 table_name="catalog.ProductReview",
                 connection_string_setting="SqlConnectionString")
@app.sql_output(arg_name="staged",
                command_text="ai.ReviewVectorStaging",
                connection_string_setting="SqlConnectionString")
def review_changed(changes: str, staged: func.Out[func.SqlRowList]) -> None:
    rows = json.loads(changes)                        # [{"Operation": 0|1|2, "Item": {...row...}}, ...]
    upserts = [r["Item"] for r in rows if r["Operation"] in (INSERT, UPDATE)]
    deletes = [r["Item"]["ReviewID"] for r in rows if r["Operation"] == DELETE]
    if deletes:
        logging.info("Deleted reviews %s: ai.usp_RefreshEmbeddings removes their chunks", deletes)
    if not upserts:
        return

    for item in upserts:
        if int(item["Rating"]) <= 2:
            logging.warning("Negative review %s (rating %s) for product %s", item["ReviewID"], item["Rating"],
                            item["ProductID"])

    texts = [f"Review ({item['Rating']}/5): {item['Title']}. {item['ReviewText']}" for item in upserts]
    result = _client.embeddings.create(model=_DEPLOYMENT, input=texts, dimensions=768)
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")

    staged.set(func.SqlRowList(
        func.SqlRow.from_dict({
            "ReviewID": item["ReviewID"],
            "ChunkText": text[:2000],
            "EmbeddingJson": json.dumps(emb.embedding),   # stored as nvarchar(max); CAST to vector(768) in SQL
            "Model": _DEPLOYMENT,
            "EmbeddedAt": now,
        })
        for item, text, emb in zip(upserts, texts, result.data)
    ))
    logging.info("Staged %d review embeddings", len(upserts))
