# Fabric notebook source

# CELL ********************

# Parameter cell: the deployment script preserves this FabricGitSource metadata and
# the Job Scheduler supplies all five values for each immutable projection run.
workspace_id = "00000000-0000-0000-0000-000000000000"
lakehouse_id = "00000000-0000-0000-0000-000000000000"
staging_path = "Files/qam-staging/<projection-hash>/<commit-sha>"
expected_projection_id = "urn:qam:projection:<64-lowercase-hex>"
expected_commit_sha = "<40-or-64-lowercase-hex>"

# METADATA ********************
# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark",
# META   "tags": ["parameters"]
# META }

# CELL ********************

import json
import re

from notebookutils import mssparkutils
from pyspark.sql import functions as F
from pyspark.sql.types import MapType, StringType, StructField, StructType

UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
PROJECTION_ID = re.compile(r"^urn:qam:projection:[0-9a-f]{64}$")
COMMIT_SHA = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
SAFE_STAGING_PATH = re.compile(r"^Files/qam-staging/[0-9a-f]{64}/[0-9a-f]{40}(?:[0-9a-f]{24})?$")

NODE_FIELDS = [
    "id", "kind", "title", "type", "path", "repositoryPath", "conceptId", "tagsJson",
    "aliasesJson", "projectionId", "commitSha", "repository", "projectionGeneratedAt",
    "okfVersion", "summary", "resource", "status", "contentHash", "sourceUrl",
    "normalizedValue", "sourceIdsJson", "authorsJson", "usageCountsJson", "lastModified",
]
EDGE_FIELDS = ["id", "from", "to", "type", "projectionId", "commitSha", "label", "sourcePath"]
EDGE_KIND_MATRIX = {
    "LINKS_TO": ("Concept", "Concept"),
    "HAS_TAG": ("Concept", "Tag"),
    "DERIVED_FROM": ("Concept", "Source"),
    "ALIASED_AS": ("Concept", "Term"),
}

if not UUID.fullmatch(workspace_id) or not UUID.fullmatch(lakehouse_id):
    raise ValueError("workspace_id and lakehouse_id must be UUIDs")
if not PROJECTION_ID.fullmatch(expected_projection_id):
    raise ValueError("expected_projection_id is invalid")
if not COMMIT_SHA.fullmatch(expected_commit_sha):
    raise ValueError("expected_commit_sha is invalid")
if not SAFE_STAGING_PATH.fullmatch(staging_path):
    raise ValueError("staging_path must be the immutable qam-staging projection/commit path")
if staging_path.split("/")[-2] != expected_projection_id.rsplit(":", 1)[-1]:
    raise ValueError("staging path projection hash does not match expected_projection_id")
if staging_path.split("/")[-1] != expected_commit_sha:
    raise ValueError("staging path commit does not match expected_commit_sha")

base_path = f"abfss://{workspace_id}@onelake.dfs.fabric.microsoft.com/{lakehouse_id}/{staging_path}"


def load_exact_ndjson(path: str, fields: list[str], label: str, allow_empty: bool = False):
    raw = spark.read.text(path)
    schema = StructType([StructField(name, StringType(), True) for name in fields])
    if raw.limit(1).count() != 1:
        if allow_empty:
            return spark.createDataFrame([], schema)
        raise ValueError(f"{label} is empty")
    decoded = raw.select(
        F.from_json("value", MapType(StringType(), StringType(), True)).alias("record"),
        "value",
    )
    expected_keys = F.array_sort(F.array(*[F.lit(name) for name in fields]))
    malformed = decoded.filter(
        F.col("record").isNull()
        | (F.array_sort(F.map_keys("record")) != expected_keys)
    )
    if malformed.limit(1).count() != 0:
        raise ValueError(f"{label} contains invalid JSON, nested data, missing fields, or unknown fields")
    return raw.select(F.from_json("value", schema).alias("row")).select("row.*")


nodes = load_exact_ndjson(f"{base_path}/nodes.ndjson", NODE_FIELDS, "QamNode")
edges = load_exact_ndjson(f"{base_path}/edges.ndjson", EDGE_FIELDS, "QamEdge", allow_empty=True)

for field in ["id", "kind", "projectionId", "commitSha", "repository", "projectionGeneratedAt", "okfVersion"]:
    if nodes.filter(F.col(field).isNull() | (F.length(F.col(field)) == 0)).limit(1).count() != 0:
        raise ValueError(f"QamNode.{field} must be populated")
for field in ["id", "from", "to", "type", "projectionId", "commitSha"]:
    if edges.filter(F.col(field).isNull() | (F.length(F.col(field)) == 0)).limit(1).count() != 0:
        raise ValueError(f"QamEdge.{field} must be populated")


def exactly_one_value(frame, field: str, label: str) -> str:
    values = [row[field] for row in frame.select(field).distinct().limit(2).collect()]
    if len(values) != 1:
        raise ValueError(f"{label}.{field} must have exactly one value")
    return values[0]


node_projection = exactly_one_value(nodes, "projectionId", "QamNode")
node_commit = exactly_one_value(nodes, "commitSha", "QamNode")
if node_projection != expected_projection_id:
    raise ValueError("QamNode projectionId does not match the requested projection")
if node_commit != expected_commit_sha:
    raise ValueError("QamNode commitSha does not match the requested commit")
if edges.filter(
    (F.col("projectionId") != expected_projection_id) | (F.col("commitSha") != expected_commit_sha)
).limit(1).count() != 0:
    raise ValueError("QamEdge projectionId/commitSha does not match the requested projection")
if nodes.filter(~F.col("projectionId").rlike(PROJECTION_ID.pattern)).limit(1).count() != 0:
    raise ValueError("invalid QamNode projectionId")
if nodes.filter(~F.col("commitSha").rlike(COMMIT_SHA.pattern)).limit(1).count() != 0:
    raise ValueError("invalid QamNode commitSha")
if edges.filter(~F.col("projectionId").rlike(PROJECTION_ID.pattern)).limit(1).count() != 0:
    raise ValueError("invalid QamEdge projectionId")
if edges.filter(~F.col("commitSha").rlike(COMMIT_SHA.pattern)).limit(1).count() != 0:
    raise ValueError("invalid QamEdge commitSha")
if nodes.groupBy("id").count().filter(F.col("count") != 1).limit(1).count() != 0:
    raise ValueError("QamNode IDs must be unique")
if edges.groupBy("id").count().filter(F.col("count") != 1).limit(1).count() != 0:
    raise ValueError("QamEdge IDs must be unique")

node_ids = nodes.select(F.col("id").alias("nodeId"))
missing_sources = edges.select(F.col("from").alias("nodeId")).join(node_ids, "nodeId", "left_anti")
missing_targets = edges.select(F.col("to").alias("nodeId")).join(node_ids, "nodeId", "left_anti")
if missing_sources.limit(1).count() != 0 or missing_targets.limit(1).count() != 0:
    raise ValueError("every QamEdge endpoint must reference a QamNode in the same projection")

source_kinds = nodes.select(F.col("id").alias("sourceId"), F.col("kind").alias("sourceKind"))
target_kinds = nodes.select(F.col("id").alias("targetId"), F.col("kind").alias("targetKind"))
edge_kinds = (
    edges.join(source_kinds, edges["from"] == source_kinds["sourceId"], "inner")
    .join(target_kinds, edges["to"] == target_kinds["targetId"], "inner")
)
valid_edge_kind = None
for edge_type, (source_kind, target_kind) in EDGE_KIND_MATRIX.items():
    candidate = (
        (F.col("type") == edge_type)
        & (F.col("sourceKind") == source_kind)
        & (F.col("targetKind") == target_kind)
    )
    valid_edge_kind = candidate if valid_edge_kind is None else (valid_edge_kind | candidate)
if edge_kinds.filter(~valid_edge_kind).limit(1).count() != 0:
    raise ValueError("QamEdge type/source-kind/target-kind does not match the canonical qam-graph matrix")

node_count = nodes.count()
edge_count = edges.count()
if node_count >= 10_000 or edge_count >= 50_000:
    raise ValueError("projection reaches the MCP adapter safety limit and could be truncated")

# Both frames are fully validated before either table changes. Delta overwrite is atomic per table.
# The Graph Model must be saved/refreshed only after this notebook returns success, so a failed
# second write can never refresh a mixed Lakehouse snapshot into the queryable graph.
nodes.write.format("delta").mode("overwrite").option("overwriteSchema", "true").saveAsTable("QamNode")
edges.write.format("delta").mode("overwrite").option("overwriteSchema", "true").saveAsTable("QamEdge")

for table_name, expected_count in [("QamNode", node_count), ("QamEdge", edge_count)]:
    persisted = spark.table(table_name)
    if persisted.count() != expected_count:
        raise RuntimeError(f"{table_name} row count changed during Delta replacement")
    if expected_count > 0:
        if exactly_one_value(persisted, "projectionId", table_name) != expected_projection_id:
            raise RuntimeError(f"{table_name} persisted the wrong projectionId")
        if exactly_one_value(persisted, "commitSha", table_name) != expected_commit_sha:
            raise RuntimeError(f"{table_name} persisted the wrong commitSha")

mssparkutils.notebook.exit(json.dumps({
    "status": "success",
    "projectionId": expected_projection_id,
    "commitSha": expected_commit_sha,
    "nodeCount": node_count,
    "edgeCount": edge_count,
}, separators=(",", ":")))

# METADATA ********************
# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
