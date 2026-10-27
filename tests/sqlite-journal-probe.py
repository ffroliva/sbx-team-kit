"""Python sqlite3 on a shared host-mount: which journal modes work? Prints the SQLite library version."""
import os
import sqlite3
import sys

d = sys.argv[1]
tag = sys.argv[2] if len(sys.argv) > 2 else "probe"
print("python sqlite library", sqlite3.sqlite_version)
for mode in ["DELETE", "TRUNCATE", "PERSIST", "MEMORY", "WAL", "OFF"]:
    p = os.path.join(d, f"{tag}-{mode}.db")
    try:
        c = sqlite3.connect(p)
        got = c.execute(f"PRAGMA journal_mode={mode}").fetchone()[0]
        c.execute("CREATE TABLE IF NOT EXISTS t(x)")
        c.execute("INSERT INTO t VALUES(1)")
        c.commit()
        print(f"{mode:9} -> {got:9} OK")
    except Exception as e:  # noqa: BLE001 — report every failure mode
        print(f"{mode:9} -> FAILED: {e}")
