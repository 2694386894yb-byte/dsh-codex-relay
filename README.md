# DSH ⇄ Codex 中继

把"吃上下文"的重活转给**包月**的 Codex 跑；**按量计费**的主模型只读一份
≤600 字摘要，正文永远不进主上下文。

> 一句话：**贵的是读进去的上下文，不是那一次回复。**
> 所以"读 10 个文件 / 跑 20 分钟"的活交给订阅额度，"看一眼、改一行、问一句"的活留给自己。

## 为什么是这种形状

按量计费的模型（token 计费）和包月订阅的 Codex，边际成本完全不对称：

| 活 | 自己干 | 走中继 |
| --- | --- | --- |
| 通读 10 个文件再总结 | 十几万 token 进上下文 | 主模型只出 1 次命令 + 读 600 字 |
| 批量改代码 + 跑测试 | 多轮往返，上下文越滚越大 | Codex 在沙箱里改完、自测完，只回摘要 |
| 改一行 / 查一个命令 | 几秒 | 起 Codex 要 60–120 秒，**不划算** |

中继省的是**主模型的上下文**，不是省 Codex 的额度——Codex 那边也有周期限额，
所以脚本带了额度闸门，重活才值得派。

## 工作模式

```
        主模型（按量计费）                        Codex（包月订阅）
                │
   1. 拆任务、写 3–5 条可检验的验收标准
                │
   2. codex-run.sh --prompt-file task.md ─────────▶  在 --cd 目录里干活
                │                                    自己跑测试/验证
                │                                    写 DETAIL.md（完整内容）
                │                                    写 RESULT.md（≤600 字摘要）
   3. 只读 RESULT.md ◀─────────────────────────────  最终回复只输出摘要
                │
   4. 抽查 2–3 个关键点（看文件 / 跑测试 / 重算）
        ├─ 不合格 → 带着具体问题重派（最多 2 轮）
        └─ 合格   → 主模型统一风格后交付
```

关键约定：

1. **任务描述自带验收标准**，不然 Codex 无人值守时会"看起来做完了"；
2. **正文写文件、摘要才回流**，脚本 stdout 只有 5 行状态 + 路径；
3. **主模型必须抽查**，不能只看摘要就交付；
4. **额度 ≤ 20% 直接停派**（exit 11），改由主模型自己做；
5. **网络不通快速失败**（exit 12），不空等到超时。

## 快速开始

前置：macOS、ChatGPT 桌面端自带的 Codex CLI、`python3`、`curl`、`bash`。

```bash
# 1. 确认 Codex CLI 位置（默认是 ChatGPT.app 内置的路径）
export CODEX_BIN="/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

# 2. 需要代理时才设置（不设置就沿用环境里的 HTTPS_PROXY）
export CODEX_RELAY_PROXY="http://127.0.0.1:7890"

# 3. 先看额度
./codex-run.sh --quota

# 4. 派一个重活
cat > /tmp/task.md <<'TASK'
把 docs/ 下所有 Markdown 合并成一份索引，写到 docs/INDEX.md。
验收标准：
1. 每个文件都有标题与一句话摘要；
2. 链接可点击；
3. 合并后行数不超过原文件总行数的 1.1 倍。
写完自己检查一遍，把结果写进摘要。
TASK

./codex-run.sh --prompt-file /tmp/task.md --cd "$PWD" --timeout 900
```

输出只有 5 行左右：

```
▶ Codex 开工：/path/to/project（模型 gpt-6.1-terra，沙箱 workspace-write，超时 900s）
✅ Codex 完成：102s，模型 gpt-6.1-terra，消耗 ChatGPT 额度 30,006 tokens（不计入按量账单）
   额度：5h 剩余 82% · 周 剩余 85%
   摘要：/tmp/dsh-codex-runs/runs/<时间戳>/RESULT.md
   详情：/tmp/dsh-codex-runs/runs/<时间戳>/DETAIL.md
   原始：/tmp/dsh-codex-runs/runs/<时间戳>/stdout.log（只在排查时看）
```

主模型下一步只需要 `cat RESULT.md`，再按需抽查 `DETAIL.md` 的片段。

## 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--prompt` / `--prompt-file` | 必填 | 任务描述；长任务建议写文件 |
| `--cd` | 当前目录 | Codex 的工作目录 |
| `--add-dir` | — | 额外可写目录，可重复 |
| `--timeout` | 900 | 秒；超时杀掉 Codex |
| `--sandbox` | `workspace-write` | 传给 Codex 的沙箱模式 |
| `--strict-sandbox` | 关 | 让 Codex 用自己的沙箱（**在已有外层沙箱里要关**，见下） |
| `--model` | `gpt-6.1-terra` | 白名单：`gpt-6-luna` / `gpt-6.1-terra` |
| `--reasoning` | Codex 默认 | `low` / `medium` / `high` |
| `--allow-advanced` | 关 | 允许白名单外的模型 |
| `--no-quota-check` | 关 | 跳过额度检查（不推荐） |
| `--quota` | — | 只查额度 |
| `--ledger` | — | 只看中继账 |

环境变量：`CODEX_BIN`（CLI 路径）、`CODEX_RELAY_PROXY`（代理）、
`DSH_CODEX_MIN_REMAINING`（额度阈值，默认 20）、`DSH_CODEX_TMP`（临时目录根）、
`DSH_CODEX_RUNS_BASE`（运行记录目录）、`CODEX_RELAY_USAGE_CSV`（可选账单 CSV）。

## 路由表：什么给 Codex，什么留主模型

| 任务 | 走谁 | 理由 |
| --- | --- | --- |
| 批量整理 / 全量大文件通读 | **Codex** | 上下文最重 |
| 写代码 / 改代码 / 排错 | **Codex** | 强项，且不花按量费用 |
| 全网调研（有网时） | **Codex** | 抓不到再退回主子代理 |
| 需要宿主专属工具（GUI、Office、通知、定时任务） | **主模型** | Codex 在桥里碰不到这些 |
| 需要向人确认意图 | **主模型** | Codex 是无人值守的 |
| 改一行 / 跑个命令 / 看一个文件 | **主模型** | 起 Codex 的固定开销不划算 |

口诀：**"要读超过 3 个文件或超过 10 分钟"→ Codex；"几秒钟能完"→ 主模型。**

## 额度闸门与中继账

- 每次派单前查 Codex 的 5 小时窗口 + 7 天窗口；任一剩余 ≤ 阈值（默认 20%）
  直接 `exit 11`，调用方应当改走主模型。
- 额度接口查询失败时先快速探网（6 秒），连不上就 `exit 12`，不空等。
- `codex-ledger.py` 读运行记录，把 Codex 干掉的活折算成"主模型自己写大概要多少钱"：

```bash
./codex-run.sh --ledger        # 或 python3 codex-ledger.py --month
```

口径（可环境变量覆盖）：每 10 万 Codex token ≈ 主模型 ¥3.0；
每次派活 + 复核固定开销 ≈ ¥0.05。数字是估算，用来看趋势，不是账单。

## 五个必须知道的坑

1. **嵌套沙箱会直接失败。**
   在已有沙箱里再启动 Codex，Codex 自带的 seatbelt 会报
   `sandbox_apply: Operation not permitted`。脚本默认加
   `--dangerously-bypass-approvals-and-sandbox`，由**外层沙箱兜底**；
   如果你在终端里手工跑（没有外层沙箱），加 `--strict-sandbox`，别裸奔。

2. **`CODEX_HOME` 要搬到一个可写目录。**
   脚本把它指到临时目录，并把 `auth.json` **软链**到 `~/.codex/auth.json`
   ——只借用凭据，不复制、不落盘。

3. **模型列表刷新超时不影响使用。**
   日志里出现 `failed to refresh available models` / `failed to connect to websocket`
   是时序问题，Codex 会自动回退，任务照跑。

4. **Codex 额度不是无限的。**
   每次 60–120 秒起步，别拿它跑小活，也别同时开三四个并发。

5. **它是无人值守的。**
   不会问你问题。任务描述里要把边界写死：写到哪、什么格式、
   不确定时选一个并说明，而不是停下来等确认。

## 目录

```
codex-bridge/
├── codex-run.sh       # 中继本体：派单、额度闸门、摘要落盘、运行记录
├── codex-quota.py     # 查 Codex 余额（5h + 周窗口）
├── codex-ledger.py    # 中继账：承接量 / token / 折算成本
├── test/selftest.sh   # 不联网自测：语法、缺参退出码、账本聚合
└── README.md
```

运行记录默认写在 `$TMPDIR/dsh-codex-runs/`，**不随仓库提交**。

## 隐私与安全

- `auth.json` 是软链，不复制凭据；
- `runs.jsonl`、`runs/`、日志和 `.home/` 都在 `.gitignore` 里；
- 任务正文会原样写进 `DETAIL.md`：**别把密钥、token、个人隐私写进任务描述**；
- 脚本默认只给 Codex 一个目录的写权限，额外目录要显式 `--add-dir`。

## 兼容性与已知限制

- 面向 macOS；`CODEX_BIN` 默认指向 ChatGPT 桌面端内置的 Codex CLI，其他安装方式改环境变量即可；
- 依赖 Codex CLI 的 `exec` 与 app-server 协议，CLI 大版本升级后参数可能变化；
- 模型白名单写死 `gpt-6-luna` / `gpt-6.1-terra`，换模型用 `--model` + `--allow-advanced`；
- 中继账里的价格是估算参数，不代表真实账单。
