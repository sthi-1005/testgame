#!/bin/bash
# parse-check every script; prints errors only
cd "$(dirname "$0")/.."
for f in ${@:-scripts/*.gd}; do
  out=$(timeout 30 godot --headless --check-only -s "$f" 2>&1 | grep -E "SCRIPT ERROR|Parse Error|ERROR" -A1 | grep -vE "^--$|load_source|Failed loading|Can't load")
  [ -n "$out" ] && echo "== $f" && echo "$out"
done
echo checked
