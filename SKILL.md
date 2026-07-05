---
name: h5i-dispatch
description: 从 Codex/Claude Code 主 session 把可隔离子任务后台派给另一个独立 agent 并行执行，通信经 h5i + git worktree。触发：dispatch、派给另一个 agent、并行做 X、后台让 codex/claude/qoder 去做。
---

# h5i-dispatch · 后台并行 agent 任务派发（h5i + worktree）

## 触发词

- 派给另一个 agent、并行做 X、dispatch
- 后台让 codex/claude/qoder 去做、让另一个 agent 写 X
- agent 通信派活、并行派一个 worker
- 主动识别：当手头活可拆成 ≥2 个互不相干、可隔离的子任务时，提示用户是否派 worker（只提示不自动派）

把一个 **scope 清晰、可隔离**的子任务交给另一个独立 agent **后台并行**干，主 session 同时干别的；通信走 **h5i**（[git-ref 消息总线](https://github.com/h5i-dev/h5i)），工作目录走 **git worktree**（隔离、与主树共享 `refs/h5i`，秒级互通、免 remote）。worker 跑完后，主 session 必须独立验证产物再通知用户；Codex 和 Claude Code 都可作为主控 session，只是后台启动和回灌能力不同。

**token 充分合理利用**：多 agent 各自独立配额并行做活；worker 的探索/试错中间过程留在其自身上下文、不回灌主 session，主 session 的 context 省着花在决策与验证上——串行变并行，墙钟与 token 双省。

## 适用场景

**一句话判定**：能不能切成「一个不碰别人文件、agent 自己能干完还能自查」的活? 能 → 派得出去。

**强契合**（隔离子任务并行）：
- **跨端并行补齐**：一端先落，派 worker 写另一端（如 `lib/`+`ohos/` / Android），主 session 盯共享核 —— 各 worktree、改不同路径 = 零冲突
- **并行补单测**：改动命中多端/多模块（C++ GTest / Android JUnit / iOS XCTest），各派一 worker 写（全量编译/跑仍走 CI）
- **长耗时只读调研/分析、出报告**（只读 = 最安全）
- **doc/spec 起草**（`docs/` 与代码天然隔离）
- **批量机械改动**（codemod/rename）按模块切，前提：分区不相交
- **修 N 个独立失败用例**，一 worker 一个
- **"实现 → 派 codex 评审这个具体 diff" 接力**（协作评审，看你的改动 ≠ 独立面板）

**不用**：
- 独立多家评审、无标准答案 → 用多家独立 cross-review（独立性是其内核，**别上共享 bus**）
- 主 session 几步能搞定 / 纯 in-process 不需独立 session·配额 → 直接做 / 用内置 subagent
- 需紧密来回交互 → 这是"派出去自主干完回报"，非实时结对

**硬边界（必踩坑）**：
- **跨仓不通**：worktree 共享 refs 只在**同一个 `.git`** 内成立；派 worker 去另一个仓干活 h5i 通道不通用（需各仓自建 / 走共享 remote）
- **并行改同一共享文件 = 冲突**：worker 间路径必须不相交
- **不可信 / 多用户机**：danger-bypass + h5i 不签名 → 只本机可信（详见末尾安全前提）

## Workflow 优先分流（先判再派）

**派发前先过这棵树**——不是所有"可并行"任务都该走 h5i-dispatch；同 session 内的内置 Workflow 更轻、更快、零开销。

```
任务可并行？
├─ 同当前 harness/session 内可完成（无需独立配额/独立 CLI）？
│   └─ → 优先走当前 harness 的内置 subagent / background job / parallel tool
├─ 跨 session / 跨 harness / 长耗时 / 需独立配额 / 需隔离工作目录？
│   └─ → 走 h5i-dispatch
│       ├─ 改动路径不相交？→ 可以派（并行安全）
│       └─ 改动路径相交？→ 拆分到不相交，或放弃并行顺序做
└─ 需要多家独立评审、无标准答案？
    └─ → 走 cross-review（独立性是其内核，不走共享 bus）
```

| 场景 | 推荐 |
|---|---|
| 同 session 内的子查询、分析、局部改动 | **当前 harness 内置 Workflow**（subagent/background job/parallel tool） |
| 跨 session、独立 CLI/harness（codex/claude/qoder/Kimi） | **h5i-dispatch** |
| 长耗时隔离任务（写测试/分析/起草 doc） | **h5i-dispatch** |
| 多家独立评审（无标准答案） | **cross-review** |

## 主动识别（agent 不必等用户明说）

扫到下列信号就**主动提示**「要不要把 X 派给 worker 并行干？」——**只提示、不自动派**（派发是外发动作，等用户点头）：

| 信号 | 提示什么 |
|---|---|
| **独立任务分叉** | 出现"先做 A 还是 B"且 A/B 互不依赖、改不同路径 → "A、B 可并行，派一个出去你这边做另一个" |
| **多端/多模块同构活** | 补 ohos+Android+iOS / 补多端单测 / 修 N 个独立用例 → "按端·模块切片，派 worker 并行" |
| **长耗时隔离子活** | 某子任务（写测试/分析/起草 doc）能独立干完、不碰主线文件 → "派出去后台跑，主 session 继续" |

判据不变：**能切成「不碰别人文件、agent 自己能干完还能自查」的活**才提。提示格式 = 一句话点出可并行切片 + 问"派 codex/claude 去做 X 吗"。用户点头才进下面「流程」。

## 前置

| 项 | 要求 |
|---|---|
| **h5i** | 装好（`https://github.com/h5i-dev/h5i`），在 PATH 或设 `H5I_BIN`。**绝不跑 `h5i init`** —— 它可能改写 harness 指令文件（如 CLAUDE.md/AGENTS.md）。只用 `h5i msg`，零 tracked 污染，refs 不进 `git push` |
| **worker CLI** | codex（独立配额）/ claude（`-p` headless）/ **qoder（`qodercli -p`）** / 其它可命令行执行的 agent harness。在 PATH 或设 `CODEX_BIN`/`CLAUDE_BIN`/`QODER_BIN` |
| **身份** | `H5I_AGENT=<name>` 每条命令带（覆盖 `.git/.h5i/msg/identity`；worktree 共享该文件，故必须 env 覆盖）|
| **代理** | 可选。脚本直调二进制、**绕过 shell wrapper**（shell function 在非交互 bash 不存在）——若你平时靠 wrapper 给 codex/claude 设代理，须设 `DISPATCH_PROXY=<url>` 补上 |
| **timeout** | `timeout`/`gtimeout`（macOS：`brew install coreutils`）；**缺失即 fatal**（除非 `ALLOW_NO_TIMEOUT=1`），防失控后台 agent 永跑 |

## 配置（env 旋钮，均有默认，无机器特定硬编码）

| env | 默认 | 说明 |
|---|---|---|
| `H5I_BIN` | PATH 上的 `h5i`，再退 `~/.local/bin/h5i` | h5i 路径 |
| `CODEX_BIN` / `CLAUDE_BIN` / `QODER_BIN` | `command -v` 解析（qoder 默认 `qodercli`） | worker 二进制路径 |
| `DISPATCH_WORKTREE_ROOT` | `<repo>/.worktrees/h5i` | 隔离 worktree 父目录；默认使用仓内已忽略目录，避免 `.claude` 绑定 |
| `DISPATCH_PROXY` | 未设（继承环境） | 设则导出为 worker 的 `HTTP(S)_PROXY`/`ALL_PROXY`（大小写都设）|
| `MAX_HANDOFF_BYTES` | `60000` | h5i handoff 当前通过 argv 传 BODY；超过阈值直接 fatal，避免撞 `ARG_MAX` 或把大段敏感任务暴露在 `ps` |
| `WORKER_TIMEOUT` | `1800`（秒） | worker 超时 watchdog |
| `ALLOW_NO_TIMEOUT` | `0` | 没 `timeout/gtimeout` 时默认 **fatal**；置 `1` 才允许不限时（不推荐）|
| `WORKER_ALLOWED_TOOLS` | `Read,Grep,Glob,Edit,Write,Bash` | worker 允许的工具列表；claude 用 `--allowedTools`，qoder 用 `--allowed-tools`，codex 当前不吃该参数 |
| 位置参数 `worker-id` | `<kind>-<wt-name>-<timestamp>-<random>` | 唯一身份，防并发派发回报串线；手动指定时也必须保证唯一 |

## 流程

**一把梭**：优先用 skill 自带脚本 `scripts/dispatch.sh <codex|claude|qoder> <wt-name> <task-file> [dispatcher] [worker-id]`（封装手动流程 M1-M4；`wt-name` 限 `^[A-Za-z0-9._-]+$`，`worker-id` 默认 `<kind>-<wt-name>-<timestamp>-<random>` **唯一**，避免并发派发身份串线）。如果本 skill 被复制到项目的 `.agents/skills/h5i-dispatch/`，则从项目内调用 `.agents/skills/h5i-dispatch/scripts/dispatch.sh`；不要假设项目根目录一定有 `scripts/dispatch.sh`。

> ⚠ **脚本会阻塞到 worker 结束** —— 有后台机制的 harness 用后台任务跑；没有后台回灌能力时，用长运行 shell session/另一终端/session 跑或前台等待，再用 `h5i msg history --plain` 查 DONE。

**Codex 主控范式**：Codex 可直接使用同一个 dispatch 脚本；但 `dispatch.sh` 本身是同步阻塞脚本，不会产生自己的 session id，也没有 Claude Code 的 `Bash(run_in_background: true)` 自动唤醒语义。要让主 session 继续做只读工作，就在另一个终端/session 跑脚本，或用当前 Codex harness 提供的长运行 shell session 功能承载这个前台命令；主 session 通过 h5i 轮询 worker 回报。

```
# C-1) 准备 task 文件（一次性 receipt 放 /tmp；任务正文必须写死 scope）
/tmp/h5i-task-<name>.md

# C-2) 在另一个终端/session，或 Codex 长运行 shell session 中启动 dispatch
scripts/dispatch.sh <kind> <wt-name> /tmp/h5i-task-<name>.md <dispatcher> <worker-id>

# C-3) 主 session 轮询 worker 回报和 worktree diff
H5I_AGENT=<dispatcher> h5i msg history --plain
git -C <repo>/.worktrees/h5i/<wt-name> diff --stat

# C-4) worker 完成后，主 session 独立验证 diff；只在验证 OK 后集成或通知用户
git -C <repo>/.worktrees/h5i/<wt-name> status --porcelain
```

Codex 主控时不要把 stdout 当完成信号；以 `h5i msg history --plain` 中 worker 发给 dispatcher 的结构化 `DONE:` 和 dispatch 脚本 exit code 为准。若当前 Codex 工具不支持长运行 shell session，就在另一终端/session 跑脚本，主 session 轮询 h5i。

**Claude Code 主控范式（实测 ✅ 2026-06-27）**：用 `Bash(run_in_background: true)` 跑同一个 dispatch 脚本，主 session 不阻塞，worker 退出后 harness 自动唤醒（task-notification），再读 DONE、验越界、清理：

```
# CC-1) 后台派发（主 session 立即继续，不阻塞）
Bash(run_in_background: true):
  bash scripts/dispatch.sh <kind> <wt-name> <task-file> <dispatcher> <worker-id>
# CC-2) worker 完成 → harness 自动唤醒主 session 后：
H5I_AGENT=<dispatcher> h5i msg history --plain | tail        # 读 worker 的 DONE
git -C <repo>/.worktrees/h5i/<wt-name> status --porcelain    # 验越界（输出空=干净）
git -C <repo> worktree remove --force <repo>/.worktrees/h5i/<wt-name> \
  && git -C <repo> branch -D dispatch/<wt-name>              # 清理
```

注：task 里引用的上下文文件必须在 tracked HEAD 里（worktree 看不到 untracked / gitignored 文件，实测踩过），否则给绝对路径让 worker 读主仓。

手动等价：

### M1. 建隔离 worktree（**先建** —— 失败则不留孤儿 handoff）
```
git worktree add -b dispatch/<wt> .worktrees/h5i/<wt> HEAD   # 可用 DISPATCH_WORKTREE_ROOT 覆盖；残留先 worktree remove --force / branch -D
```

### M2. 发 handoff（worktree 就绪后；主 session 写提示词，任务全文 + **硬 scope 约束**进 h5i）
```
H5I_AGENT=<dispatcher> "$H5I_BIN" msg handoff <worker> "<任务全文，写死『只动 <path>，勿碰其它』>"
```

### M3. 后台起 worker + **timeout 兜底**
worker prompt **必含**：
- 用 `"$H5I_BIN" msg history --plain` 读任务（**别用 `inbox`，会消费该身份游标**）
- 长任务中每完成一个阶段发 PROGRESS 心跳（**必须经 h5i 发**，dispatcher 只看总线不看 worker stdout，只 print 到 stdout 不可见）：`H5I_AGENT=<worker> "$H5I_BIN" msg send <dispatcher> "PROGRESS: <phase> <pct>% <one-line note>"`
- 干完发结构化 DONE（用 `send` 不用 `done <N>`：并发派发时编号会错位）：
  ```
  H5I_AGENT=<worker> "$H5I_BIN" msg send <dispatcher> 'DONE: {"status":"done","files_changed":["path1"],"summary":"...","verification":"..."}'
  ```
- 出错时同样结构化：`'DONE: {"status":"error","error":"简短错误","files_changed":[]}'`
- ⚠ JSON 用**单引号**包裹（防 shell 解释 `"`）；若 `summary`/`verification` 文本含单引号，先转义或去掉，否则 JSON 截断——保持值里无 `'`
- "只动 <path>、自主、别问问题"

启动（`$WBIN`=worker 二进制，`$WT`=worktree 绝对路径，`$WORKER_ALLOWED_TOOLS` 默认 `Read,Grep,Glob,Edit,Write,Bash`）：
- **codex**：`[DISPATCH_PROXY 时 export HTTP(S)_PROXY+ALL_PROXY 大小写] H5I_AGENT=<worker> gtimeout 1800 "$WBIN" exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C "$WT" -o <last.txt> - < <prompt>`（codex exec 无标准 tool-restrict 参数，保持原样）
- **claude**：`cd "$WT" && gtimeout 1800 "$WBIN" -p "<prompt>" --allowedTools "$WORKER_ALLOWED_TOOLS"`（claude 无 `-C`，**必须 `cd "$WT"`**，否则在主树写文件）
- **qoder**：`cd "$WT" && gtimeout 1800 "$WBIN" -p "<prompt>" -w "$WT" --allowed-tools "$WORKER_ALLOWED_TOOLS" --dangerously-skip-permissions`
- **timeout 缺失即 fatal**（脚本里）：除非 `ALLOW_NO_TIMEOUT=1`，否则没 `timeout/gtimeout` 直接报错退出（防失控后台 agent 永跑）

### M4. worker 退出 → 主 session 验证 → 通知
- **唤醒机制**：如果当前 harness 支持后台任务完成回灌，worker 退出会自动提醒主 session；否则主 session 自己 `"$H5I_BIN" msg wait` 阻塞或轮询。
- 读 `"$H5I_BIN" msg history` 看 worker 的 done + last-message 文件
- **独立验证 worker 产物**（**别只信回报**，AI 产出落码前先验）：
  - `git -C <wt> diff --stat` 对照任务白名单路径 —— **越界文件即红旗**（scope 是建议非强制，这步是 enforce）
  - 对照真实 API/源码复核逻辑正确性
- 主动通知用户

### M5. 集成（主 session 决定，不越权自动合）
- 复核 OK → 落主分支，**commit scope 到 worker 改的文件**（`git commit --only <path>`，防误带主树其它未提交改动）
- 同主题未推 → 提醒 squash 进原 commit（别擅自 rebase 共享活分支）
- 清理：`git worktree remove --force .worktrees/h5i/<wt> && git branch -D dispatch/<wt>`（若设置了 `DISPATCH_WORKTREE_ROOT`，清理对应路径）

## worker 选型

| worker | 写文件 + 回写 h5i | 说明 |
|---|---|---|
| **codex** | 需 `--dangerously-bypass-approvals-and-sandbox`（`workspace-write` sandbox 挡不住写共享 `.git` 的 refs/h5i）| 独立配额 |
| **claude** | `-p` + `--allowedTools` | 最懂本仓 |
| **qoder** | `-p` + `-w` + `--allowed-tools` + `--dangerously-skip-permissions` | 本地独立审查/交叉验证，成本低 |
| **其它 CLI harness**（如 Kimi 包装器）| 按该 CLI 的 headless 参数适配脚本 | 换后端/配额时使用 |

## 坑（实测）
- `h5i msg inbox` 推进该身份游标（消费）→ 派任务时**别**替 worker 跑 inbox；worker 用 `history` 读
- `workspace-write` sandbox 写不了共享 `.git`（worktree 的 refs/h5i 在 common dir）→ worker 要经 h5i 回报必须 `danger-full-access`/bypass
- 不跑 `h5i init`（污染 CLAUDE.md/AGENTS.md）
- 脚本绕 shell wrapper 直调二进制 → CLI 若靠 wrapper 设代理，须 `DISPATCH_PROXY`
- worker prompt 不写死 scope → 可能越界改文件
- `git worktree add` 大仓会 checkout 数千文件，正常

## ⚠ 安全前提（单用户本机专用）
- **h5i v1 消息不签名、`from` 可伪造** → 同机任意进程能伪造回报骗主 session。**∴ worker 的 DONE 回报只能当"完成提示"，绝不能作为自动合入的依据** —— 合入前必须主 session 亲自 `git diff` 复核
- **worker 全部走权限绕过** = 给 worker 整机读写+执行权（只为写共享 `.git` 的 refs/h5i，影响面远超此需）：codex `--dangerously-bypass-approvals-and-sandbox`、qoder `--dangerously-skip-permissions`、claude `--allowedTools` 放行 Bash
- h5i handoff 当前通过命令行参数传任务 BODY；脚本会限制大任务体，但短任务仍可能被同机 `ps` 看到。last-message / run-log / 任务文件也可能落 tmp 明文

→ 仅在**你独占的可信机器**用，**禁多用户机 / 共享仓 / 不可信网络**。唯一防线 = 第4步 `git diff --stat` 越界检查 + 落码前人工复核（绝不凭 DONE 自动合）。
