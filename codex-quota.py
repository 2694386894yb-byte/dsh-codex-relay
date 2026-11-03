#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""查询 ChatGPT/Codex 账户额度（5 小时窗口 + 7 天周窗口），给全局桥做前置保护。

用法：
    codex-quota.py          # 人读一行：5h 剩余 86% · 周 剩余 93%
    codex-quota.py --json   # 机器可读 JSON
退出码：0 正常；10 剩余 ≤ 阈值（默认 20%）；20 查询失败
"""
import json, os, select, subprocess, sys, time

CODEX = os.environ.get("CODEX_BIN", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
TMP = (os.environ.get("DSH_CODEX_TMP") or os.environ.get("TMPDIR") or "/tmp").rstrip("/")
CODEX_HOME = os.environ.get("CODEX_HOME") or (TMP + "/dsh-codex-home")
THRESH = int(os.environ.get("DSH_CODEX_MIN_REMAINING", "20"))


def main():
    env = dict(os.environ)
    env["CODEX_HOME"] = CODEX_HOME
    proxy = os.environ.get("CODEX_RELAY_PROXY")
    if proxy:
        env.setdefault("HTTP_PROXY", proxy)
        env.setdefault("HTTPS_PROXY", proxy)
        env.setdefault("ALL_PROXY", proxy)
    env.setdefault("NO_PROXY", "127.0.0.1,localhost")

    try:
        proc = subprocess.Popen([CODEX, "app-server"], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=env, text=True, bufsize=1)
    except OSError as e:
        print(f"⚠️ 无法启动 Codex app-server：{e}", file=sys.stderr)
        return 20

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def wait_result(rid, timeout):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not r:
                continue
            line = proc.stdout.readline()
            if not line:
                return None
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("id") == rid and ("result" in obj or "error" in obj):
                return obj
        return None

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"clientInfo": {"name": "dsh-quota", "title": "DSH Quota", "version": "1.0.0"}}})
        if not wait_result(1, 20):
            print("⚠️ Codex app-server 初始化超时", file=sys.stderr)
            return 20
        send({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": {}})
        res = wait_result(2, 25)
        if not res or "result" not in res:
            print("⚠️ 查询额度失败（无返回）", file=sys.stderr)
            return 20
        rl = res["result"].get("rateLimits") or {}
        prim = rl.get("primary") or {}
        sec = rl.get("secondary") or {}

        def rem(w):
            if not w or w.get("usedPercent") is None:
                return None
            return 100 - int(w["usedPercent"])

        p_rem, s_rem = rem(prim), rem(sec)
        rems = [x for x in (p_rem, s_rem) if x is not None]
        if not rems:
            print("⚠️ 额度数据为空", file=sys.stderr)
            return 20
        min_rem = min(rems)
        out = {
            "ok": min_rem > THRESH,
            "threshold": THRESH,
            "primary": {"remainingPercent": p_rem, "windowMins": prim.get("windowDurationMins"),
                        "resetsAt": prim.get("resetsAt")},
            "secondary": {"remainingPercent": s_rem, "windowMins": sec.get("windowDurationMins"),
                          "resetsAt": sec.get("resetsAt")},
            "planType": rl.get("planType"),
        }
        if "--json" in sys.argv:
            print(json.dumps(out, ensure_ascii=False))
        else:
            parts = []
            if p_rem is not None:
                parts.append(f"5h 剩余 {p_rem}%")
            if s_rem is not None:
                parts.append(f"周 剩余 {s_rem}%")
            print(" · ".join(parts))
        return 0 if out["ok"] else 10
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=3)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
