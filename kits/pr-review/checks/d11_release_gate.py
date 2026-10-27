"""D11 (deterministic): release-gate facts the council used to read by eye.

  - version in pyproject.toml == __version__ in src/gflow_cli/__init__.py  (drift = RED)
  - CHANGELOG.md has an `## [Unreleased]` section
  - if the version changed against a base ref, CHANGELOG.md has a `## [<version>]` section
Usage: python d11_release_gate.py <repo-root> [<base-version>]   |   --selfcheck
Exit 0 = GREEN, 1 = RED.
"""
from __future__ import annotations

import re
import sys
import tempfile
import tomllib
from pathlib import Path


def check(repo: Path, base_version: str | None = None) -> int:
    proj = tomllib.loads((repo / "pyproject.toml").read_text(encoding="utf-8"))["project"]["version"]
    m = re.search(r'^__version__\s*=\s*["\']([^"\']+)["\']', (repo / "src/gflow_cli/__init__.py").read_text(encoding="utf-8"), re.M)
    init = m.group(1) if m else None
    changelog = (repo / "CHANGELOG.md").read_text(encoding="utf-8")
    red = []
    if proj != init:
        red.append(f"version drift: pyproject {proj} vs __init__ {init}")
    if not re.search(r"^## \[Unreleased\]", changelog, re.M):
        red.append("CHANGELOG.md has no '## [Unreleased]' section")
    if base_version and base_version != proj and not re.search(rf"^## \[{re.escape(proj)}\]", changelog, re.M):
        red.append(f"version bumped {base_version} -> {proj} but CHANGELOG.md has no '## [{proj}]' section")
    print(f"D11 release gate: pyproject {proj}, __init__ {init}, base {base_version or '-'}")
    print("\n".join(f"  RED {r}" for r in red) if red else "  versions agree; changelog sections present")
    print("  verdict:", "GREEN" if not red else "RED")
    return 1 if red else 0


def selfcheck() -> None:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / "src/gflow_cli").mkdir(parents=True)
        (root / "pyproject.toml").write_text('[project]\nname="x"\nversion = "1.2.0"\n')
        (root / "src/gflow_cli/__init__.py").write_text('__version__ = "1.1.0"\n')
        (root / "CHANGELOG.md").write_text("## [Unreleased]\n")
        assert check(root) == 1, "version drift must be RED"
        (root / "src/gflow_cli/__init__.py").write_text('__version__ = "1.2.0"\n')
        assert check(root, "1.1.0") == 1, "bump without a changelog section must be RED"
        (root / "CHANGELOG.md").write_text("## [Unreleased]\n\n## [1.2.0]\n")
        assert check(root, "1.1.0") == 0
    print("selfcheck ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selfcheck"]:
        selfcheck()
    else:
        sys.exit(check(Path(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else None))
