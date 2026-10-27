#!/bin/sh
# Inside a sandbox: mount options, Unix-socket bind and inode stability for one directory.
# Usage: mount-probe.sh <dir> <tag>
d=$1; tag=$2
echo "-- mount entry for $d:"; grep -F " $d " /proc/mounts || awk -v d="$d" 'index(d,$2)==1' /proc/mounts | tail -1
python3 - "$d" "$tag" <<'PY'
import os, socket, sqlite3, sys
d, tag = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
try:
    s.bind(os.path.join(d, f"{tag}.sock")); print("unix socket bind: OK")
except OSError as e:
    print("unix socket bind: FAILED", e)
p = os.path.join(d, f"{tag}.bin")
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644); before = os.fstat(fd).st_ino
os.write(fd, b"x" * 8192); os.fsync(fd); after = os.fstat(fd).st_ino; os.close(fd)
print(f"inode before/after first write: {before} -> {after} {'STABLE' if before == after else 'CHANGED'}")
c = sqlite3.connect(os.path.join(d, f"{tag}.db")); c.execute("PRAGMA journal_mode=DELETE")
c.execute("CREATE TABLE t(x)"); c.commit()
try:
    c.execute("INSERT INTO t VALUES(1)"); c.commit(); print("sqlite DELETE mode, 2nd write: OK")
except sqlite3.Error as e:
    print("sqlite DELETE mode, 2nd write: FAILED", getattr(e, "sqlite_errorname", e))
PY
