#!/usr/bin/env bash
# 不联网自测：语法、参数校验、账本聚合。
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
step() { printf '==> %s\n' "$*"; }

step "bash 语法"
bash -n codex-run.sh || fail=1

step "Python 语法"
python3 - codex-quota.py codex-ledger.py <<'PY' || fail=1
import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f, encoding="utf-8").read(), filename=f)
print("ok")
PY

step "缺少 --prompt 时 exit 2"
./codex-run.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 2 ]; then
  echo "期望 exit 2，实际 $rc"
  fail=1
fi

step "中继账聚合"
TMPD="$(mktemp -d)"
mkdir -p "$TMPD/dsh-codex-runs"
python3 - "$TMPD/dsh-codex-runs/runs.jsonl" <<'PY'
import datetime, json, sys
now = datetime.datetime.now().isoformat(timespec="seconds")
rows = [
    {"ts": now, "duration_s": 60, "exit_code": 0, "codex_tokens": 100000,
     "cwd": "/Users/example/project", "model": "gpt-6.1-terra"},
    {"ts": now, "duration_s": 30, "exit_code": 1, "codex_tokens": 50000,
     "cwd": "/Users/example/project", "model": "gpt-6-luna"},
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
out="$(DSH_CODEX_TMP="$TMPD" python3 codex-ledger.py --json)"
if ! printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["runs"] == 2, d
assert d["tokens"] == 150000, d
assert d["ok"] == 1 and d["fail"] == 1, d
print("ledger ok")
'; then
  fail=1
fi
rm -rf "$TMPD"

step "结果"
if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "FAILED"
  exit 1
fi
