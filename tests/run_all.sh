#!/bin/sh
# Run every CHRONARCH test suite.
# Setup once:  python3 -m venv .venv && .venv/bin/pip install lupa
set -e
cd "$(dirname "$0")/.."
[ -f tests/ccrom/rednet.lua ] || sh tests/fetch_ccrom.sh
PY=.venv/bin/python
[ -x "$PY" ] || PY=python3
for t in run_tests test_probe test_protocol test_status test_orescan test_oremap test_navigate test_update test_net test_bridge test_gpssetup test_swarm; do
  echo "== $t =="
  "$PY" "tests/$t.py"
done
