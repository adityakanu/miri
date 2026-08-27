#!/bin/bash
set -euo pipefail

# Fail-closed benchmark evidence gate. Publishing is only allowed when the
# report was captured from the exact commit being released and every gate,
# plus the overall status, is "pass". Missing/incomplete never counts as pass.

SHA=${1:-}
REPORT=${2:-}
[[ -n "$SHA" && -n "$REPORT" ]] || {
  echo "usage: $0 <commit-sha> <benchmark-report.json>" >&2
  exit 2
}
[[ -f "$REPORT" ]] || { echo "benchmark evidence gate: missing report $REPORT" >&2; exit 1; }

python3 - "$SHA" "$REPORT" <<'PY'
import json, sys

sha, path = sys.argv[1], sys.argv[2]
try:
    report = json.load(open(path))
except Exception as exc:  # unreadable evidence is not passing evidence
    print(f"benchmark evidence gate: cannot parse {path}: {exc}", file=sys.stderr)
    sys.exit(1)

failures = []
if report.get("revision") != sha:
    failures.append(f"revision {report.get('revision')!r} does not match release commit {sha!r}")
if report.get("overall_status") != "pass":
    failures.append(f"overall_status is {report.get('overall_status')!r}, expected 'pass'")

gates = report.get("gates") or {}
if not gates:
    failures.append("report declares no gates")
for name in sorted(gates):
    status = (gates[name] or {}).get("status")
    if status != "pass":
        failures.append(f"gate {name} is {status!r}, expected 'pass'")

# Metrics do not always carry a status, but when they do it must also pass.
for name, metric in sorted((report.get("metrics") or {}).items()):
    status = (metric or {}).get("status")
    if status is not None and status != "pass":
        failures.append(f"metric {name} is {status!r}, expected 'pass'")

for failure in failures:
    print(f"benchmark evidence gate: {failure}", file=sys.stderr)
sys.exit(1 if failures else 0)
PY

echo "benchmark evidence gate: $REPORT passes at $SHA"
