#!/bin/sh
# Inside a sandbox: R fresh databases per journal mode, per tool; count successes.
# Usage: sqlite-repeat.sh <dir> <tag> [R]
d=$1; tag=$2; R=${3:-50}
for mode in DELETE TRUNCATE PERSIST WAL; do
  cli_ok=0; py_ok=0; i=0
  while [ $i -lt $R ]; do
    i=$((i+1))
    sqlite3 "$d/$tag-cli-$mode-$i.db" "PRAGMA journal_mode=$mode; CREATE TABLE t(x); INSERT INTO t VALUES(1);" >/dev/null 2>&1 && cli_ok=$((cli_ok+1))
    python3 -c "import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);c.execute('PRAGMA journal_mode=$mode');c.execute('CREATE TABLE t(x)');c.execute('INSERT INTO t VALUES(1)');c.commit()" "$d/$tag-py-$mode-$i.db" >/dev/null 2>&1 && py_ok=$((py_ok+1))
  done
  echo "$mode: cli $cli_ok/$R ok, python $py_ok/$R ok"
done
