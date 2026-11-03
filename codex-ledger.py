#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""中继账：Codex 桥干了多少活、折成"DSH 自己写"要花多少钱。

数据源（都在本机，不联网）：
  - 桥自动写的运行记录：$TMPDIR/dsh-codex-runs/runs.jsonl
  - 每日账单（可选）：`CODEX_RELAY_USAGE_CSV` 指向的 CSV（列：日期 / 金额元 / 步数）

口径：
  - 每 10 万 Codex token ≈ 相当于 DSH 自己写 ¥3.0（DSH_CODEX_VALUE_PER_100K 可调）
  - 每次运行固定开销 ≈ ¥0.05（派活 + 读摘要 + 抽查，约 5 步）

用法：
  codex-ledger.py            # 今天
  codex-ledger.py --day 2026-11-02
  codex-ledger.py --month    # 本月
  codex-ledger.py --json     # 机器可读
  codex-ledger.py --md       # 一行 Markdown 表格
"""
import json, os, sys
from datetime import datetime

TMP = (os.environ.get("DSH_CODEX_TMP") or os.environ.get("TMPDIR") or "/tmp").rstrip("/")
RUNS = TMP + "/dsh-codex-runs/runs.jsonl"
VALUE = float(os.environ.get("DSH_CODEX_VALUE_PER_100K", "3.0"))
OVERHEAD = float(os.environ.get("DSH_CODEX_OVERHEAD_PER_RUN", "0.05"))
USAGE_CSV = os.environ.get("CODEX_RELAY_USAGE_CSV", "")


def load_runs():
    rows = []
    if not os.path.exists(RUNS):
        return rows
    with open(RUNS, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                continue
    # 排除自检/测试运行（cwd 在 /tmp 下的），不计入中继账
    rows = [r for r in rows if "/tmp/" not in (r.get("cwd") or "")]
    return rows


def dsh_usage(day):
    if not USAGE_CSV:
        return None
    try:
        import csv
        total, steps = 0.0, 0
        with open(USAGE_CSV, encoding="utf-8-sig") as f:
            for r in csv.DictReader(f):
                if r.get("日期") == day:
                    total += float(r.get("金额元") or 0)
                    steps += int(r.get("步数") or 0)
        return (total, steps) if steps else None
    except Exception:
        return None


def agg(rows):
    ok = [r for r in rows if int(r.get("exit_code") or 0) == 0]
    tokens = sum(int(r.get("codex_tokens") or 0) for r in rows)
    secs = sum(int(r.get("duration_s") or 0) for r in rows)
    est = tokens / 100000.0 * VALUE
    overhead = len(rows) * OVERHEAD
    by_model = {}
    for r in rows:
        m = r.get("model") or "?"
        by_model.setdefault(m, [0, 0])
        by_model[m][0] += 1
        by_model[m][1] += int(r.get("codex_tokens") or 0)
    return {"runs": len(rows), "ok": len(ok), "fail": len(rows) - len(ok),
            "tokens": tokens, "seconds": secs, "est": round(est, 2),
            "overhead": round(overhead, 2), "net": round(est - overhead, 2),
            "by_model": by_model}


def main():
    args = sys.argv[1:]
    mode = "json" if "--json" in args else ("md" if "--md" in args else "text")
    day = month = None
    for i, a in enumerate(args):
        if a == "--day" and i + 1 < len(args):
            day = args[i + 1]
        if a == "--month":
            month = datetime.now().strftime("%Y-%m")
    rows = load_runs()
    if day:
        sel = [r for r in rows if (r.get("ts") or "").startswith(day)]
        label = day
    elif month:
        sel = [r for r in rows if (r.get("ts") or "").startswith(month)]
        label = month
    else:
        day = datetime.now().strftime("%Y-%m-%d")
        sel = [r for r in rows if (r.get("ts") or "").startswith(day)]
        label = day

    a = agg(sel)
    out = {"label": label, **a}
    usage = dsh_usage(day) if day else None
    if usage:
        out["dsh_today"] = round(usage[0], 2)
        out["dsh_steps"] = usage[1]
        out["without_relay"] = round(usage[0] + a["net"], 2)

    if mode == "json":
        print(json.dumps(out, ensure_ascii=False, indent=1))
        return 0
    if mode == "md":
        print(f"| {label} | {a['runs']} | {a['tokens']/10000:.1f} 万 | "
              f"{a['seconds']/60:.1f} 分钟 | ¥{a['est']:.2f} | ¥{a['overhead']:.2f} | **¥{a['net']:.2f}** |")
        return 0

    if not sel:
        print(f"📒 中继账 · {label}：还没有桥运行记录。")
        return 0
    print(f"📒 中继账 · {label}")
    print(f"运行 {a['runs']} 次（成功 {a['ok']} / 失败 {a['fail']}）｜ Codex {a['tokens']/10000:.1f} 万 token "
          f"｜ {a['seconds']/60:.1f} 分钟 ｜ GPT 侧现金 ¥0")
    if a["by_model"]:
        parts = [f"{m} {c} 次/{t/10000:.1f}万" for m, (c, t) in
                 sorted(a["by_model"].items(), key=lambda x: -x[1][1])]
        print("模型：" + " · ".join(parts))
    print(f"估算：这些活 DSH 自己写 ≈ ¥{a['est']:.2f} ｜ 派活+复核开销 ≈ ¥{a['overhead']:.2f} "
          f"｜ 净省 ≈ ¥{a['net']:.2f}")
    if usage:
        print(f"今日 DSH 账单（本机重算）：¥{usage[0]:.2f}（{usage[1]} 步）｜ 不走中继估计 ≈ ¥{usage[0]+a['net']:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
