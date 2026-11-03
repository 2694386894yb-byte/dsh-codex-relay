#!/usr/bin/env bash
# ============================================================
# DSH ⇄ Codex 中继桥 v1
# ------------------------------------------------------------
# 把"重活"转给 ChatGPT 订阅里的 Codex 跑；DSH（按量计费）侧
# 只收一行状态 + 文件路径，正文永远不进上下文。
#
# 契约（Codex 必须遵守）：
#   1) 完整内容写进 <run>/DETAIL.md
#   2) ≤600 字摘要写进 <run>/RESULT.md
#   3) 最终回复只输出 RESULT.md 的内容
#
# 用法：
#   codex-run.sh --prompt "任务" [--cd 目录] [--model gpt-6.1-terra]
#                [--reasoning low|medium|high] [--timeout 900]
#                [--sandbox workspace-write] [--strict-sandbox]
#                [--add-dir 目录] [--prompt-file 文件] [--allow-advanced]
#
# 模型白名单：gpt-6-luna（常规）/ gpt-6.1-terra（默认，重活）。
#            更高级模型默认拒绝，确认要用时显式加 --allow-advanced。
#
# 额度保护：每次运行前查 Codex 额度（5h + 周窗口）；任一剩余 ≤ 20% 时
#            直接拒绝执行（exit 11），调用方应立即改走 DSH。阈值：
#            DSH_CODEX_MIN_REMAINING（默认 20）；查询失败则提示后继续。
#            单独查额度：codex-run.sh --quota
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_BIN="${CODEX_BIN:-/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex}"
TMP_BASE="${DSH_CODEX_TMP:-${TMPDIR:-/tmp}}"
CODEX_HOME_DIR="${CODEX_HOME_DIR:-$TMP_BASE/dsh-codex-home}"
RUNS_BASE="${DSH_CODEX_RUNS_BASE:-$TMP_BASE/dsh-codex-runs}"
RUNS_DIR="$RUNS_BASE/runs"
LOG="$RUNS_BASE/runs.jsonl"

PROMPT=""
PROMPT_FILE=""
CD_DIR="$PWD"
SANDBOX="workspace-write"
STRICT=0
TIMEOUT=900
MODEL=""
REASONING=""
ALLOW_ADVANCED=0
ADD_DIRS=()
QUOTA_CHECK=1
QUOTA_ONLY=0
LEDGER_ONLY=0
SUMMARY_CHARS=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)         PROMPT="$2"; shift 2 ;;
    --prompt-file)    PROMPT_FILE="$2"; shift 2 ;;
    --cd)             CD_DIR="$2"; shift 2 ;;
    --add-dir)        ADD_DIRS+=("$2"); shift 2 ;;
    --sandbox)        SANDBOX="$2"; shift 2 ;;
    --strict-sandbox) STRICT=1; shift ;;
    --timeout)        TIMEOUT="$2"; shift 2 ;;
    --model)          MODEL="$2"; shift 2 ;;
    --reasoning)      REASONING="$2"; shift 2 ;;
    --allow-advanced) ALLOW_ADVANCED=1; shift ;;
    --no-quota-check) QUOTA_CHECK=0; shift ;;
    --quota)          QUOTA_ONLY=1; shift ;;
    --ledger)         LEDGER_ONLY=1; shift ;;
    -h|--help)        awk 'NR>1 { if (/^# =====/ && n++ > 0) exit; sub(/^# ?/,""); print }' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

if [[ "$QUOTA_ONLY" -eq 1 ]]; then
  python3 "$SCRIPT_DIR/codex-quota.py"
  exit $?
fi

if [[ "$LEDGER_ONLY" -eq 1 ]]; then
  python3 "$SCRIPT_DIR/codex-ledger.py"
  exit $?
fi

[[ -z "$PROMPT" && -z "$PROMPT_FILE" ]] && { echo "缺少 --prompt 或 --prompt-file" >&2; exit 2; }
[[ -n "$PROMPT_FILE" ]] && PROMPT="$(cat "$PROMPT_FILE")"
[[ -d "$CD_DIR" ]] || { echo "工作目录不存在：$CD_DIR" >&2; exit 2; }

[[ -z "$MODEL" ]] && MODEL="gpt-6.1-terra"
case "$MODEL" in
  gpt-6-luna|gpt-6.1-terra) ;;
  *)
    if [[ "$ALLOW_ADVANCED" -eq 0 ]]; then
      echo "❌ 模型 $MODEL 不在默认白名单（gpt-6-luna / gpt-6.1-terra）。" >&2
      echo "   更高级模型默认不允许；确认要用请加 --allow-advanced。" >&2
      exit 2
    fi ;;
esac

[[ -x "$CODEX_BIN" ]] || { echo "找不到 Codex CLI：$CODEX_BIN" >&2; exit 3; }
mkdir -p "$CODEX_HOME_DIR" "$RUNS_DIR"
if [[ ! -e "$CODEX_HOME_DIR/auth.json" ]]; then
  ln -sf "$HOME/.codex/auth.json" "$CODEX_HOME_DIR/auth.json" 2>/dev/null || true
fi
[[ -r "$CODEX_HOME_DIR/auth.json" ]] || { echo "CODEX_HOME 缺 auth.json（应软链到 ~/.codex/auth.json）" >&2; exit 3; }

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$RUNS_DIR/$STAMP"
mkdir -p "$OUT_DIR"

WRAPPED="$(cat <<EOF
你在为一个按量计费的系统打工，它的上下文很贵。必须遵守：

1. 把**详细结论/完整内容**写进 \`$OUT_DIR/DETAIL.md\`（可以很长）。
2. 把**摘要**写进 \`$OUT_DIR/RESULT.md\`，**不超过 $SUMMARY_CHARS 字**，只写：做了什么、改了/产出了哪些文件（绝对路径）、关键结论、验证证据（测试/命令结果）、没做完的部分、需要人工决策的点。
3. 最终回复**只输出 RESULT.md 的内容**，不要复述 DETAIL。
4. 需要验证的自己跑测试/命令，把结论写进摘要；不要问"要不要继续"，自己判断做完为止。

===== 任务 =====
$PROMPT
EOF
)"

QUOTA_LINE=""
if [[ "$QUOTA_CHECK" -eq 1 ]]; then
  QUOTA_LINE="$(python3 "$SCRIPT_DIR/codex-quota.py" 2>/dev/null)"; QRC=$?
  if [[ "$QRC" -eq 10 ]]; then
    echo "⛔ Codex 额度不足（${QUOTA_LINE}），按额度规则暂停中继：改由主模型直接完成。"
    exit 11
  elif [[ "$QRC" -ne 0 || -z "$QUOTA_LINE" ]]; then
    echo "⚠️ GPT 额度查询失败，继续执行（未能确认剩余额度）。"
    QUOTA_LINE=""
    # 额度接口不通时先快速探网：6 秒内连不上就别让 Codex 空等到超时
    PROBE_PROXY="${CODEX_RELAY_PROXY:-${HTTPS_PROXY:-${HTTP_PROXY:-}}}"
    CURL_PROXY_ARGS=()
    [[ -n "$PROBE_PROXY" ]] && CURL_PROXY_ARGS=(--proxy "$PROBE_PROXY")
    if ! curl -sS -m 6 "${CURL_PROXY_ARGS[@]}" -o /dev/null "https://chatgpt.com/" >/dev/null 2>&1; then
      echo "💡 网络/代理连不上：先检查 VPN/代理，再重试；不要让任务空等到超时。"
      exit 12
    fi
  fi
fi

echo "▶ Codex 开工：${CD_DIR}（模型 ${MODEL}，沙箱 ${SANDBOX}，超时 ${TIMEOUT}s）"

ARGS=(-s "$SANDBOX" -C "$CD_DIR" --skip-git-repo-check --ephemeral -m "$MODEL")
[[ "$STRICT" -eq 0 ]] && ARGS+=(--dangerously-bypass-approvals-and-sandbox)
[[ -n "$REASONING" ]] && ARGS+=(-c "model_reasoning_effort=\"$REASONING\"")
for d in "${ADD_DIRS[@]:-}"; do [[ -n "$d" ]] && ARGS+=(--add-dir "$d"); done

# 需要代理时设置 CODEX_RELAY_PROXY（例如 http://127.0.0.1:7890）；
# 没设置就沿用环境里已有的 HTTP(S)_PROXY。
PROXY="${CODEX_RELAY_PROXY:-${HTTPS_PROXY:-${HTTP_PROXY:-}}}"
if [[ -n "$PROXY" ]]; then
  export HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" ALL_PROXY="$PROXY"
fi
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"

START=$(date +%s)
if command -v timeout >/dev/null 2>&1; then
  CODEX_HOME="$CODEX_HOME_DIR" timeout "$TIMEOUT" "$CODEX_BIN" exec "${ARGS[@]}" "$WRAPPED" \
    >"$OUT_DIR/stdout.log" 2>"$OUT_DIR/stderr.log"
  RC=$?
else
  CODEX_HOME="$CODEX_HOME_DIR" perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
    "$CODEX_BIN" exec "${ARGS[@]}" "$WRAPPED" \
    >"$OUT_DIR/stdout.log" 2>"$OUT_DIR/stderr.log"
  RC=$?
fi
END=$(date +%s)
DUR=$((END-START))

parse_tokens() {
  grep -A1 -m1 '^tokens used' "$1" 2>/dev/null | tail -1 | tr -d ' ,'
}
TOKENS="$(parse_tokens "$OUT_DIR/stdout.log")"
[[ -z "$TOKENS" || "$TOKENS" == "tokens used" ]] && TOKENS="$(parse_tokens "$OUT_DIR/stderr.log")"
[[ ! "$TOKENS" =~ ^[0-9]+$ ]] && TOKENS=0

SUMMARY_FILE="$OUT_DIR/RESULT.md"
if [[ ! -s "$SUMMARY_FILE" ]]; then
  { echo "（Codex 未生成 RESULT.md，以下为最终回复原文截断）"; echo;
    tail -c "$((SUMMARY_CHARS*4))" "$OUT_DIR/stdout.log" 2>/dev/null; } > "$SUMMARY_FILE"
fi

python3 - "$LOG" "$STAMP" "$DUR" "$RC" "$TOKENS" "$CD_DIR" "$MODEL" "$SUMMARY_FILE" <<'PY'
import json, sys, datetime
log, stamp, dur, rc, tokens, cd, model, summary = sys.argv[1:9]
rec = {
    "ts": datetime.datetime.now().isoformat(timespec="seconds"),
    "stamp": stamp,
    "duration_s": int(dur),
    "exit_code": int(rc),
    "codex_tokens": int(tokens or 0),
    "cwd": cd,
    "model": model,
    "summary_file": summary,
}
with open(log, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY

if [[ "$RC" -ne 0 ]]; then
  echo "❌ Codex 失败（exit ${RC}，${DUR}s）"
  echo "   日志：$OUT_DIR/stderr.log"
  tail -5 "$OUT_DIR/stderr.log" 2>/dev/null | sed 's/^/   /'
  if grep -qiE 'proxy|connect|network|timeout|timed out|ECONNREFUSED|ENOTFOUND|unauthorized|401|403|502|503' "$OUT_DIR/stderr.log" 2>/dev/null; then
    echo "💡 看起来是网络/代理问题：先检查 VPN/代理，再重试。"
  fi
  exit "$RC"
fi

echo "✅ Codex 完成：${DUR}s，模型 ${MODEL}，消耗 ChatGPT 额度 ${TOKENS} tokens（不计入 DSH 账单）"
[[ -n "$QUOTA_LINE" ]] && echo "   额度：$QUOTA_LINE"
echo "   摘要：$SUMMARY_FILE"
echo "   详情：$OUT_DIR/DETAIL.md"
echo "   原始：$OUT_DIR/stdout.log（只在排查时看）"
