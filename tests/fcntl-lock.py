"""Try an exclusive POSIX (fcntl) lock on a file; optionally hold it. Used by lock-visibility-test.sh."""
import fcntl
import sys
import time

f = open(sys.argv[1], "a+")
try:
    fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("GOT-IT", flush=True)
    if len(sys.argv) > 2:
        time.sleep(int(sys.argv[2]))
except OSError as e:
    print("blocked errno", e.errno, flush=True)
