#!/bin/bash
# Runs scan.lua against a config that tries to run commands and touch files,
# and checks that none of it happened and the JSON still parses.
set -u
here=$(cd "$(dirname "$0")" && pwd)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cp "$here/sandbox/bindings.lua" "$dir/"
touch "$dir/keep"
out=$(KEYSMITH_TEST_DIR="$dir" lua "$here/../scan.lua" "$here/sandbox/hyprland.lua" "$dir/bindings.lua")
code=$?
fail=0
for f in executed popened written appended renamed via-debug; do
  [ -e "$dir/$f" ] && { echo "FAIL: side effect '$f' happened"; fail=1; }
done
[ -e "$dir/keep" ] || { echo "FAIL: os.remove deleted a file"; fail=1; }
[ $code -eq 0 ] || { echo "FAIL: scan exited $code (os.exit not blocked?)"; fail=1; }
printf '%s' "$out" | node -e '
  const t = require("fs").readFileSync(0, "utf8")
  const m = "@@KEYSMITH-SCAN@@\n"
  const d = JSON.parse(t.slice(t.lastIndexOf(m) + m.length))
  const ev = d.events.find(e => e.keys === "SUPER + T")
  if (!ev) { console.log("FAIL: binding not scanned"); process.exit(1) }
  if (!ev.span) { console.log("FAIL: binding with \"--\" in a string has no span"); process.exit(1) }
  if (!(d.warnings || []).some(w => /broken on purpose/.test(w))) { console.log("FAIL: failing module not reported"); process.exit(1) }
' || fail=1
[ $fail -eq 0 ] && echo "sandbox: all passed"
exit $fail
