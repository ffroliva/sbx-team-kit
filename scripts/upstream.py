"""Status of every upstream item listed in UPSTREAM.md: state, last activity, and whose move it is.

python scripts/upstream.py [--me ffroliva] [--selfcheck]
"""
import argparse, json, re, subprocess, sys
from pathlib import Path

ITEM = re.compile(r"^\|\s*([\w.-]+/[\w.-]+)#(\d+)\s*\|", re.M)


def items(text: str) -> list[tuple[str, int]]:
    return [(repo, int(n)) for repo, n in ITEM.findall(text)]


def gh(path: str):
    return json.loads(subprocess.run(["gh", "api", path], capture_output=True, encoding="utf-8", check=True).stdout)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--me", default="ffroliva")
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()
    if a.selfcheck:
        t = "| a |\n|---|\n| docker/sbx-releases#773 | x |\n| docker/sandbox-kit-spec#12 | y |\nnot docker/x#1\n"
        assert items(t) == [("docker/sbx-releases", 773), ("docker/sandbox-kit-spec", 12)], items(t)
        print("selfcheck ok")
        return
    for repo, n in items((Path(__file__).parent.parent / "UPSTREAM.md").read_text(encoding="utf-8")):
        i = gh(f"repos/{repo}/issues/{n}")
        last = gh(f"repos/{repo}/issues/{n}/comments?per_page=100")
        who = last[-1]["user"]["login"] if last else i["user"]["login"]
        kind = "PR" if "pull_request" in i else "issue"
        move = "-" if i["state"] == "closed" else ("theirs" if who == a.me else "ours")
        print(f"{repo}#{n:<5} {kind:5} {i['state']:6} updated {i['updated_at'][:10]}  "
              f"comments {i['comments']:>2}  last {who:<20} move {move:6} {i['title'][:60]}")


if __name__ == "__main__":
    sys.exit(main())
