"""D15 (deterministic part): MCP queue payload keys written vs keys the worker reads.

gflow-cli's MCP tools build a `payload` dict and enqueue it; the worker decodes it in
`worker/codec.py`. They are matched by string, so a key written under one name and read under
another type-checks, passes every test, and silently does nothing. This check reports:
  - written, never read  -> the option is silently ignored by the worker
  - read, never written  -> the worker always falls back to its default
Usage: python d15_payload_keys.py <repo-root>   |   python d15_payload_keys.py --selfcheck
Exit 0 = no drift, 1 = drift found.
"""
from __future__ import annotations

import ast
import sys
import tempfile
from pathlib import Path

# Keys that are protocol plumbing, not user options (added at the enqueue site / read for routing).
PLUMBING = {"schema_version"}


def written_keys(source: str) -> set[str]:
    keys: set[str] = set()
    for node in ast.walk(ast.parse(source)):
        # payload: dict = {"k": ...}   /   payload = {"k": ...}
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if any(isinstance(t, ast.Name) and t.id == "payload" for t in targets) and isinstance(node.value, ast.Dict):
                keys |= {k.value for k in node.value.keys if isinstance(k, ast.Constant) and isinstance(k.value, str)}
            # payload["k"] = ...
            for t in targets:
                if (isinstance(t, ast.Subscript) and isinstance(t.value, ast.Name) and t.value.id == "payload"
                        and isinstance(t.slice, ast.Constant) and isinstance(t.slice.value, str)):
                    keys.add(t.slice.value)
    return keys


def _is_payload(node: ast.AST) -> bool:
    """`payload` or `<anything>.payload` (e.g. task.payload)."""
    return (isinstance(node, ast.Name) and node.id == "payload") or (
        isinstance(node, ast.Attribute) and node.attr == "payload")


def read_keys(source: str) -> set[str]:
    keys: set[str] = set()
    for node in ast.walk(ast.parse(source)):
        # payload["k"] in a load context
        if (isinstance(node, ast.Subscript) and _is_payload(node.value)
                and isinstance(node.ctx, ast.Load) and isinstance(node.slice, ast.Constant)
                and isinstance(node.slice.value, str)):
            keys.add(node.slice.value)
        # payload.get("k", ...)
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "get"
                and _is_payload(node.func.value)
                and node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str)):
            keys.add(node.args[0].value)
    return keys


def string_constants(source: str) -> set[str]:
    """Every string literal: catches dynamic writes such as key tables iterated into payload[key]."""
    return {n.value for n in ast.walk(ast.parse(source)) if isinstance(n, ast.Constant) and isinstance(n.value, str)}


def check(repo: Path) -> int:
    # Writes are counted from the MCP tools only: CLI modules build other dicts also named `payload`
    # (JSON output), so counting them as queue writes floods the report. CLI literals only excuse a
    # read-never-written key. shortcut: no data-flow tracking into enqueue_task(); upgrade if the
    # candidate list stays noisy.
    mcp = (repo / "src/gflow_cli/mcp/tools.py").read_text(encoding="utf-8")
    cli = [p.read_text(encoding="utf-8") for p in sorted((repo / "src/gflow_cli").glob("cli*.py"))]
    writers = [mcp]
    readers = sorted((repo / "src/gflow_cli/worker").glob("*.py"))
    w = written_keys(mcp) - PLUMBING
    mentioned = set().union(string_constants(mcp), *(string_constants(s) for s in cli))
    r = set().union(*(read_keys(p.read_text(encoding="utf-8")) for p in readers)) - PLUMBING
    # Written-never-read is strict (literal writes only); read-never-written also checks every literal
    # in the writers, so a key written through a key table is not reported as missing.
    ignored, defaulted = sorted(w - r), sorted(r - w - mentioned)
    print(f"D15 payload keys: written {len(w)}, read {len(r)} (writer files: {len(writers)}, worker files: {len(readers)})")
    for k in ignored:
        print(f"  WRITTEN, NEVER READ  {k!r}  -> option silently ignored by the worker")
    for k in defaulted:
        print(f"  READ, NEVER WRITTEN  {k!r}  -> worker always uses its default")
    print("  verdict:", "GREEN" if not (ignored or defaulted) else "FINDINGS (review each: plumbing vs real drift)")
    return 0 if not (ignored or defaulted) else 1


def selfcheck() -> None:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / "src/gflow_cli/mcp").mkdir(parents=True)
        (root / "src/gflow_cli/worker").mkdir(parents=True)
        (root / "src/gflow_cli/mcp/tools.py").write_text(
            'def f(x):\n    payload: dict = {"prompt": x, "aspect": 1}\n    payload["characterIds"] = []\n    return payload\n')
        (root / "src/gflow_cli/worker/codec.py").write_text(
            'def g(payload):\n    return payload["prompt"], payload.get("aspect"), payload.get("character_ids")\n')
        assert written_keys((root / "src/gflow_cli/mcp/tools.py").read_text()) == {"prompt", "aspect", "characterIds"}
        assert check(root) == 1, "planted camelCase/snake_case drift must be reported"
        (root / "src/gflow_cli/mcp/tools.py").write_text('def f(x):\n    payload = {"prompt": x, "aspect": 1, "character_ids": []}\n')
        assert check(root) == 0, "matched keys must be GREEN"
    print("selfcheck ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selfcheck"]:
        selfcheck()
    else:
        sys.exit(check(Path(sys.argv[1])))
