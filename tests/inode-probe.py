"""Does stat(path) agree with fstat(fd) on this filesystem? SQLite treats a mismatch as 'database moved'
(SQLITE_READONLY_DBMOVED, extended code 1032) and refuses further writes."""
import os
import sqlite3
import sys

d, tag = sys.argv[1], sys.argv[2]
p = os.path.join(d, f"{tag}.bin")
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
before = (os.fstat(fd).st_ino, os.stat(p).st_ino)
os.write(fd, b"x" * 8192)
os.fsync(fd)
after = (os.fstat(fd).st_ino, os.stat(p).st_ino)
os.close(fd)
print(f"{d}: fstat/stat inode before write {before} match={before[0] == before[1]}; after write {after} match={after[0] == after[1]}")

db = os.path.join(d, f"{tag}.db")
c = sqlite3.connect(db)
c.execute("PRAGMA journal_mode=DELETE")
c.execute("CREATE TABLE t(x)")
c.commit()
try:
    c.execute("INSERT INTO t VALUES(1)")
    c.commit()
    print(f"{d}: second write OK")
except sqlite3.Error as e:
    print(f"{d}: second write FAILED: {e} | sqlite_errorcode={getattr(e, 'sqlite_errorcode', '?')} ({getattr(e, 'sqlite_errorname', '?')})")
