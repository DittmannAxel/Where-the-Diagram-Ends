#!/usr/bin/env python3

import ast
import re
from pathlib import Path


qam_root = Path(__file__).resolve().parents[2]
notebook_path = qam_root / "infra/fabric/qam-load-projection.notebook-content.py"
contract_path = qam_root / "contracts/qam-graph-1.0.ts"
notebook_source = notebook_path.read_text(encoding="utf-8")
tree = ast.parse(notebook_source, filename=str(notebook_path))

notebook_matrix = None
edges_allow_empty = False
matrix_is_applied = False
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == "EDGE_KIND_MATRIX" for target in node.targets
    ):
        notebook_matrix = ast.literal_eval(node.value)
    if (
        isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "edges" for target in node.targets)
        and isinstance(node.value, ast.Call)
        and isinstance(node.value.func, ast.Name)
        and node.value.func.id == "load_exact_ndjson"
    ):
        edges_allow_empty = any(
            keyword.arg == "allow_empty"
            and isinstance(keyword.value, ast.Constant)
            and keyword.value.value is True
            for keyword in node.value.keywords
        )
    if (
        isinstance(node, ast.For)
        and isinstance(node.iter, ast.Call)
        and isinstance(node.iter.func, ast.Attribute)
        and node.iter.func.attr == "items"
        and isinstance(node.iter.func.value, ast.Name)
        and node.iter.func.value.id == "EDGE_KIND_MATRIX"
    ):
        matrix_is_applied = True

contract_match = re.search(
    r"export const GRAPH_EDGE_KIND_MATRIX = \{(?P<body>.*?)\} as const satisfies",
    contract_path.read_text(encoding="utf-8"),
    re.DOTALL,
)
if contract_match is None:
    raise SystemExit("canonical GRAPH_EDGE_KIND_MATRIX declaration is missing")
contract_matrix = {
    edge_type: (source_kind, target_kind)
    for edge_type, source_kind, target_kind in re.findall(
        r'(\w+): \{ from: "(\w+)", to: "(\w+)" \}', contract_match.group("body")
    )
}

if notebook_matrix != contract_matrix:
    raise SystemExit(
        f"Fabric notebook edge-kind matrix {notebook_matrix!r} differs from canonical {contract_matrix!r}"
    )
if not edges_allow_empty:
    raise SystemExit("Fabric notebook must load edges.ndjson with allow_empty=True")
if not matrix_is_applied:
    raise SystemExit("Fabric notebook declares EDGE_KIND_MATRIX but does not apply it")
if "if expected_count > 0:" not in notebook_source:
    raise SystemExit("Fabric notebook must skip persisted provenance cardinality for an empty edge table")

print("Fabric notebook contract is synchronized with qam-graph/1.0.")
