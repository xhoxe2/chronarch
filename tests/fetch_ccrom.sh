#!/bin/sh
# Downloads real CC: Tweaked modules (MPL-2.0): rednet, parallel, textutils,
# cc.expect. Tests run programs against the genuine implementation.
set -e
cd "$(dirname "$0")"
mkdir -p ccrom
BASE=https://raw.githubusercontent.com/cc-tweaked/CC-Tweaked/mc-1.21.x/projects/core/src/main/resources/data/computercraft/lua/rom
for f in apis/rednet.lua apis/parallel.lua apis/textutils.lua modules/main/cc/expect.lua; do
  curl -fsSL "$BASE/$f" -o "ccrom/$(basename $f)"
  echo "ok ccrom/$(basename $f)"
done
