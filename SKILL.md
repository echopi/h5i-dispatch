---
name: h5i-dispatch
version: 0.4.1
description: 从主 session 把可隔离子任务后台派给另一个独立 agent（qoder/pi/codex）并行执行，worker 跑在 h5i box（受限 worktree + 策略 + host 侧 receipt）里，产物经 export 门人工复核后合入。触发：dispatch、派给另一个 agent、并行做 X、后台让 qoder/pi/codex 去做。
---

# h5i-dispatch · 后台并行 agent 任务派发（h5i box 模型，v0.4.1）

## 触发词

- 派给另一个 agent、并行做 X、dispatch
- 后台让 qoder/pi/codex 去做、让另一个 agent 写 X
- 并行派一个 worker
- 主动识别：当手头活可拆成 ≥2 个互不相干、可隔离的子任务时，提示用户是否派 worker（只提示不自动派）

把一个 **scope 清晰、可隔离**的子任务交给另一个独立 agent **后台并行**干，主 session 同时干别的。v0.4.0 起 worker 跑在 **h5i box**（[h5i](https://github.com/h5i-dev/h5i) 0.3.x 的受限开发环境：git worktree + pinned 策略 + host 侧 receipt）里；产物经 **export 门**（patch.diff + report.md + receipt.json）由主 session 人工复核后 `git apply`。旧版依赖的 `h5i msg` 消息总线已被上游在 0.3.x 移除，本版本不再使用。

**token 充分合理利用**：多 agent 各自独立配额并行做活；worker 的探索/试错中间过程留在其自身上下文、不回灌主 session，主 session 的 context 省着花在决策与验证上——串行变并行，墙钟与 token 双省。

## 适用场景

**一句话判定**：能不能切成「一个不碰别人文件、agent 自己能干完还能自查」的活? 能 → 派得出去。

**强契合**（隔离子任务并行）：
- **跨端并行补齐**：一端先落，派 worker 写另一端，主 session 盯共享核 —— 各 box、改不同路径 = 零冲突
- **并行补单测**：改动命中多端/多模块，各派一 worker 写（全量编译/跑仍走 CI）
- **长耗时只读调研/分析、出报告**（只读 = 最安全）
- **doc/spec 起草**（`docs/` 与代码天然隔离）
- **批量机械改动**（codemod/rename）按模块切，前提：分区不相交
- **修 N 个独立失败用例**，一 worker 一个
- **同题竞技**：同一任务派两个 box（如 qoder vs pi），`h5i box compare` 并排比补丁

**不用**：
- 独立多家评审、无标准答案 → 用多家独立 cross-review（独立性是其内核）
- 主 session 几步能搞定 / 纯 in-process 不需独立 session·配额 → 直接做 / 用内置 subagent
- 需紧密来回交互 → 这是"派出去自主干完回报"，非实时结对

**硬边界（必踩坑）**：
- **单仓**：box 是当前仓的 worktree；跨仓任务在目标仓里各自跑本 skill
- **并行改同一共享文件 = 冲突**：worker 间路径必须不相交
- **无修订回路**：box 一经 export 即冻结；复核发现小问题也只能整单重跑（新 box + 重新 seed + 上下文全丢）。v1 已知回归，接受再派
- **不可信 / 多用户机**：worker 持真实凭据副本 + danger-skip → 只本机可信（详见末尾安全前提）

## Workflow 优先分流（先判再派）

```
任务可并行？
├─ 同当前 harness/session 内可完成（无需独立配额/独立 CLI）？
│   └─ → 优先走当前 harness 的内置 subagent / background job / parallel tool
├─ 跨 session / 跨 harness / 长耗时 / 需独立配额 / 需隔离工作目录？
│   └─ → 走 h5i-dispatch
│       ├─ 改动路径不相交？→ 可以派（并行安全）
│       └─ 改动路径相交？→ 拆分到不相交，或放弃并行顺序做
└─ 需要多家独立评审、无标准答案？
    └─ → 走 cross-review（独立性是其内核）
```

## 前置

| 项 | 要求 |
|---|---|
| **h5i** | 0.3.x（脚本入口按 `H5I_VERSION_PREFIX` 校验，失配 fail-closed）。安装：https://github.com/h5i-dev/h5i |
| **timeout** | `timeout`/`gtimeout` 必需（macOS：`brew install coreutils`） |
| **rsync** | seed worker HOME 用 |
| **worker CLI** | qoder（`qodercli`，主力）/ pi / codex，在 PATH 或设 `QODER_BIN`/`PI_BIN`/`CODEX_BIN` |
| **worker 登录态** | worker 在 host 上已登录（seed 的是凭据**副本**；实测副本使用不踢 host 下线，但 token 会轮换，长期异常时先怀疑这里） |

## 配置（env 旋钮，均有默认）

| env | 默认 | 说明 |
|---|---|---|
| `H5I_BIN` | PATH 上的 `h5i` | h5i 路径 |
| `H5I_VERSION_PREFIX` | `0.3.` | 版本 pin 前缀，失配即 fatal |
| `QODER_BIN`/`PI_BIN`/`CODEX_BIN` | `command -v` 解析 | worker 二进制 |
| `WORKER_TIMEOUT` | `1800`（秒） | worker 超时 watchdog；**超时的 run 不写 receipt**，脚本以 exit 124 上报 |
| `MAX_TASK_BYTES` | `60000` | task 文件大小上限 |
| `DISPATCH_PROXY` | `http://127.0.0.1:${PROXY_PORT:-7897}` | pi 专用代理（Anthropic API 需代理出海） |
| `DISPATCH_KEEP_BOX` | `0` | 置 1 结束时不删 box（调试）；export 失败时自动保留供取证 |
| `DISPATCH_FROM` | `HEAD` | box base revision，透传 `h5i box --from`（创建时不可变 pin，避免派发期间主线漂移） |
| `DISPATCH_EXTRA_ARGS` | 空 | 注入 worker 命令行的额外参数（如 `--model GLM-5.3`）；host 侧拼接、字符集校验。box 策略只放行 worker 二进制 exec（wrapper 脚本被拒），换模型/加 flag 只能走这个 |

## 流程

**一把梭**：

```bash
# 1) 任务文件：全文 + 硬 scope 约束（只动哪些路径）
cat > /tmp/task-<name>.md <<'EOF'
只允许修改 <path>，勿碰其它文件。
<任务描述>
EOF

# 2) 派发（脚本阻塞到 worker 结束；有后台机制的 harness 用后台任务跑）
scripts/dispatch.sh <qoder|pi|codex> <box-name> /tmp/task-<name>.md

# 3) 监控（可选）
h5i box log <box-name>        # 事件流
h5i box diff <box-name>       # 当前改动

# 4) 脚本结束后按输出指引验收：
#    - 读 h5i-export/<box-name>/report.md（跑过什么命令、被拒的 egress）
#    - patch 路径对照任务白名单（盯 rename/symlink/新二进制）
#    - 主树干净时 git apply --3way h5i-export/<box-name>/patch.diff
```

脚本内部做的事（对应旧版 M1-M5）：

1. **preflight**：h5i 版本 pin、timeout 存在、task 大小、在 git 仓内
2. **profile 注入**：幂等追加 `[profile.agent-qoder]`/`[profile.agent-pi]` 到 `.h5i/env.toml`（机器本地，勿提交）；codex 用内建 `agent-codex`
3. **建 box**：`h5i box --name <box> --profile agent-<kind>`（= worktree + 固定策略 digest）
4. **seed HOME**：qodercli/pi 启动即硬解析 `$HOME`，box 不放行真实 home → 拷凭据副本进 work 目录并运行时重定向 `HOME`（副本不写回，天然不污染 host session）
5. **handoff**：task 文件拷进 work 目录（**不走 argv**——会进 receipt 和 `ps`），worker 读 `.dispatch-task.md` 执行
6. **执行**：`timeout N h5i box run` 阻塞；exit 124 = 超时（该 run 无 receipt）
7. **清 seed**：worker 一结束即删凭据副本（缩短 token 驻留窗口），随后 export
8. **export 门**：冻结 box → patch.diff + report.md + receipt.json；**receipt 是 host 侧记录（命令/exit/egress 裁决），但 patch 内容仍是 worker 产物，必须人工复核**
9. **清理**：`trap` 兜底 `box rm --force`（含中断/失败路径；export 失败时保留 box 供取证）

## worker 选型

| worker | 端到端验证 | seed 成本 | 备注 |
|---|---|---|---|
| **qoder** | ✅ 2026-08-18（macOS arm64，supervised tier） | ~82M（瘦身副本） | 主力；egress = 4 个 qoder.sh 域名 |
| **pi** | ✅ 2026-08-18 | ~270M（含 agent/git 扩展） | 需代理；egress = anthropic + npm/github |
| **codex** | 🟡 仅启动验证 | 0（内建 HOME-state） | 内建 `agent-codex` profile |

egress 白名单是从 receipt 的 denied 发现项**实测**出来的，不是猜的；worker 升级或后端换域名会 fail-closed（403/拒连），届时重跑发现实验：空白名单 box 里跑 worker，读 receipt 的 `egress.hosts`。

## 坑（实测）

- **box 策略只放行 worker 二进制本体 exec**：包一层 wrapper 脚本再调 qodercli 会被 seatbelt 拒——给 worker 传额外参数（如换模型）只能走 `DISPATCH_EXTRA_ARGS`（host 侧拼进命令行），别造 wrapper
- **`env.pass` 是替换不是追加**：profile 一旦写了 `env.pass`，PATH 都掉成裸默认——必须把 `PATH`/`HOME` 显式列进去，否则 worker 二进制 127
- **seed 里不能有嵌套 git 仓**：export 的 mediated commit fail-closed 拒绝；rsync 一律 `--exclude=.git`
- **seed 目录会进 patch**：worker 结束后、export 前必须删 seed（脚本已做），否则交付物被几百 M HOME 噪声淹没
- **软链要解引用**：host 的配置软链（如 settings.json → 仓外）在 box 里 EPERM；rsync 用 `-L`
- **超时 run 无 receipt**：别拿 receipt 存在与否判断"跑没跑过"；脚本以 exit 124 为准
- **box 冻结后不可续跑**：export 即 proposed；`h5i box run` 报 Metadata error 是正常生命周期
- **stale 状态可复用**：超时后 box 显示 `running (stale)`，下次 run 照常；`box rm --force` 照常清理

## ⚠ 安全前提（单用户本机专用）

- **box 策略是真边界，但不是验收依据**：fs/egress 收窄 + 行为可审计是净收益；**patch 内容仍是 worker 可控产物**，合入前必须主 session 亲自复核（路径白名单 + 内容正确性），绝不凭 rc=0 或 receipt 自动合
- **凭据副本驻留**：seed 期间真实 token 明文存于 `<repo>/.git/.h5i/` 下——不进 git 对象库、不 push、`box rm` 即删，但**会进 Time Machine 等全盘备份**；`DISPATCH_KEEP_BOX=1` 会延长驻留
- **worker 持权限绕过参数**（qoder `--dangerously-skip-permissions` / codex `--dangerously-bypass-approvals-and-sandbox`）：box 策略是外层边界，但 worker 在 work 目录内完全自主；只派可信任务
- **egress 白名单对代理路同样强制**（supervised tier 在 loopback 上有出口裁决代理，✅ 实测对照），但 `net.egress = []` 是**完全不设防**（opt-out 语义），禁止使用
- → 仅在你独占的可信机器用，禁多用户机 / 共享仓 / 无人值守自动合

## 相对 v0.3.x（msg 模型）的变化

| 维度 | v0.3.x（msg 总线） | v0.4.0（box 模型） |
|---|---|---|
| 依赖 | `h5i msg`（**上游已删**） | `h5i box`（0.3.x 现役） |
| handoff | `msg handoff`（argv 传 body） | task 文件进 work 目录 |
| 回报 | PROGRESS/DONE 自报（可伪造） | host 侧 receipt + export 门 |
| 权限 | worker 整机 bypass | box 策略收窄（fs/egress/env） |
| 进度 | PROGRESS 心跳 | 无（`box log`/`box diff` 旁路） |
| 修订 | 可 msg 往返打回 | 无（export 即冻结，整单重跑） |
| 新增 | — | 同题竞技（compare）、舰队面板（`h5i ui`）、`box rebase` 跟随主线 |
