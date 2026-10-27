"""Compare acknowledged batches with what the database holds after a single-postmaster restart.

Usage (inside a Mem0 sandbox, with its postmaster running alone):
  python pg-verify-traced.py <who>=<acked-file> [<who>=<acked-file> ...]
Each acked file lists the batch numbers that writer was told were committed.
"""
import subprocess
import sys

PSQL = ["psql", "-X", "-q", "-t", "-A", "-h", "127.0.0.1", "-U", "agent", "-d", "postgres", "-c"]


def query(sql: str) -> list[str]:
    out = subprocess.run(PSQL + [sql], capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line]


for arg in sys.argv[1:]:
    who, path = arg.split("=", 1)
    acked = {int(x) for x in open(path).read().split()}
    rows = {}
    for line in query(f"SELECT n, count(*) FROM race WHERE who='{who}' GROUP BY n"):
        n, c = line.split("|")
        rows[int(n)] = int(c)
    present = set(rows)
    lost = acked - present
    phantom = present - acked
    partial = {n: c for n, c in rows.items() if c != 200}
    print(f"{who}: acked_batches={len(acked)} present_batches={len(present)} "
          f"lost_acked={len(lost)} ({100 * len(lost) / max(len(acked), 1):.1f}%) "
          f"phantom_not_acked={len(phantom)} partial_batches={len(partial)}")
    if phantom:
        print(f"  phantom batch numbers (sample): {sorted(phantom)[:10]}")
    if partial:
        print(f"  partial batches (n: rows) sample: {dict(list(sorted(partial.items()))[:5])}")
    if lost:
        s = sorted(lost)
        print(f"  lost range: {s[0]}..{s[-1]} (first acked {min(acked)}, last acked {max(acked)})")
