"""D12 (deterministic): BDD fakes must accept every parameter of the function they replace.

gflow-cli's BDD steps swap real functions with `monkeypatch.setattr("gflow_cli.mod.Name.attr", _fake_x)`.
When the real function gains a parameter the fake does not accept, the step fails only at run time
with a TypeError — or worse, a caller's new keyword is never exercised. This check resolves every
such target in src/, compares parameter names, and reports real parameters the fake cannot take
(a fake with **kwargs accepts everything).
Usage: python d12_bdd_stubs.py <repo-root>   |   python d12_bdd_stubs.py --selfcheck
Exit 0 = all fakes compatible, 1 = mismatch found.
"""
from __future__ import annotations

import ast
import sys
import tempfile
from pathlib import Path

FuncNode = ast.FunctionDef | ast.AsyncFunctionDef


def params(fn: FuncNode) -> tuple[set[str], bool]:
    a = fn.args
    names = {p.arg for p in a.posonlyargs + a.args + a.kwonlyargs} - {"self", "cls"}
    return names, a.kwarg is not None


def find_def(repo: Path, dotted: str) -> FuncNode | None:
    """Resolve 'gflow_cli.pkg.mod.Class.method' or 'gflow_cli.pkg.mod.func' to its AST node."""
    parts = dotted.split(".")
    for cut in range(len(parts) - 1, 0, -1):
        mod = repo / "src" / Path(*parts[:cut]).with_suffix(".py")
        if not mod.exists():
            continue
        scope: list[ast.stmt] = ast.parse(mod.read_text(encoding="utf-8")).body
        node: ast.AST | None = None
        for name in parts[cut:]:
            node = next((n for n in scope if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
                         and n.name == name), None)
            if node is None:
                break
            scope = node.body if isinstance(node, ast.ClassDef) else []
        return node if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) else None
    return None


def check(repo: Path) -> int:
    findings, pairs, unresolved = [], 0, 0
    for step in sorted((repo / "tests/features").glob("*.py")):
        tree = ast.parse(step.read_text(encoding="utf-8"))
        fakes = {n.name: n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
        for call in ast.walk(tree):
            if not (isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute) and call.func.attr == "setattr"
                    and len(call.args) >= 2 and isinstance(call.args[0], ast.Constant)
                    and isinstance(call.args[0].value, str) and call.args[0].value.startswith("gflow_cli.")
                    and isinstance(call.args[1], ast.Name) and call.args[1].id in fakes):
                continue
            target, fake = call.args[0].value, fakes[call.args[1].id]
            real = find_def(repo, target)
            if real is None:
                unresolved += 1
                continue
            pairs += 1
            real_p, _ = params(real)
            fake_p, fake_kw = params(fake)
            missing = sorted(real_p - fake_p) if not fake_kw else []
            if missing:
                findings.append(f"  {step.name}:{call.lineno} {fake.name} stands in for {target} "
                                f"but does not accept {missing}")
    print(f"D12 BDD fakes: {pairs} fake↔real pairs checked, {unresolved} targets not resolvable statically")
    print("\n".join(findings) if findings else "  all fakes accept the real parameters")
    print("  verdict:", "GREEN" if not findings else "FINDINGS")
    return 1 if findings else 0


def selfcheck() -> None:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / "src/gflow_cli").mkdir(parents=True)
        (root / "tests/features").mkdir(parents=True)
        (root / "src/gflow_cli/cli_image.py").write_text("def _resolve_project(name, *, create=False):\n    pass\n")
        step = root / "tests/features/test_x_steps.py"
        step.write_text('def _fake(name):\n    return 1\n\ndef t(monkeypatch):\n'
                        '    monkeypatch.setattr("gflow_cli.cli_image._resolve_project", _fake)\n')
        assert check(root) == 1, "fake missing the new 'create' parameter must be reported"
        step.write_text('def _fake(name, **kw):\n    return 1\n\ndef t(monkeypatch):\n'
                        '    monkeypatch.setattr("gflow_cli.cli_image._resolve_project", _fake)\n')
        assert check(root) == 0, "a **kwargs fake accepts everything"
    print("selfcheck ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selfcheck"]:
        selfcheck()
    else:
        sys.exit(check(Path(sys.argv[1])))
