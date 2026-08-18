# h5i-dispatch ROADMAP

设计/协议层待办。v0.4.0 起本 skill 迁移到 **h5i 0.3.x box 模型**（上游 2026-08-05 pivot 删除了 `h5i msg` 总线，PR h5i-dev/h5i#385）；迁移后 #1/#3 被 box 的 host 侧 receipt 结构性解决/取代。

**触发条件**：这些在**单机自用**场景下不紧迫（已有代偿）；真正变"必须"是当 h5i-dispatch 要**走出单机**——多用户机 / 共享仓 / 无人值守自动合 / 大规模并行编排。

论断分级：✅ 实测 / 🟡 推理（设计构想未落地验证）。

---

## 1. ~~h5i 消息签名~~（v0.4.0 结构性解决）

- **原问题**：h5i v1 消息不签名、`from` 可伪造，DONE 回报可被同机进程伪造。
- **现状**（✅ 实测）：msg 总线已随上游 pivot 删除；box 模型的完成信号 = `h5i box run` exit code，行为证据 = host 侧 receipt（命令/exit/wall/egress 裁决，worker 不可写）。伪造面消失。
- **未解决部分**：receipt 证明"进程行为"不证明"产物正确"——patch 内容仍是 worker 可控产物，人工复核仍是合入门槛，**无人值守自动合仍未解锁**。

## 2. 跨 harness token budget 协议（配额管控）

- **问题**（🟡 推理）：worker 跑在独立配额（codex）/ 远端机时，主 session 看不到它烧了多少 token，只有时间闸（`WORKER_TIMEOUT`）没有配额闸。
- **现状代偿**：`WORKER_TIMEOUT` 时间兜底。
- **解决后**：worker 启动前 claim 预算、完成后 return 剩余、超预算主端可取消。
- **优先级**：低（timeout 代偿够用）；大规模/远端派发时升级。

## 3. ~~h5i 协议扩展 phase / progress / schema~~（v0.4.0 被取代）

- **原问题**：PROGRESS/DONE 靠 body 文本前缀约定，解析脆弱。
- **现状**（✅ 实测）：msg 协议不复存在；回报结构化由 receipt.json（host 侧、schema 稳定）承担。
- **遗留**：进度可见性回退——无 PROGRESS 心跳，只能 `h5i box log`/`box diff` 旁路观察（见 #5）。

## 4. Workflow ↔ h5i bridge（两套机制可组合）

- **问题**（🟡 推理）：Claude Code 内置 Workflow（同 session 高性能编排）和 h5i-dispatch（跨 session/harness）是两套独立机制，子任务要跨边界时无法无缝衔接。
- **现状代偿**：二选一——全 Workflow（跨不了边界）或全 h5i（同 session 也付 worktree + 延迟成本）。
- **解决后**：Workflow 脚本能把某个 stage 下放给 h5i worker 当远端后端，各取所长。
- **优先级**：低（nice-to-have，两套各自能用）。

## 5. 活性探针（v0.4.0 回退的代偿）

- **问题**（✅ 实测回退）：msg 时代有 PROGRESS 心跳；box 模型主 session 在 `WORKER_TIMEOUT` 内盲等，无法区分"在干活"和"卡死"。
- **方向**（🟡 推理）：host 侧轮询 work 目录 mtime / `git status --short` 行数增长 / `h5i box diff`，每 60s 输出一行活性摘要；无需 worker 配合。
- **优先级**：中（长任务体验明显，实现成本低）。

## 6. claude worker 回归

- **问题**（✅ 实测方向）：v0.3.x 支持 claude worker；v0.4.0 首版只有 qoder/pi/codex（claude 需同款 HOME-seed + profile 适配，未验证）。
- **方向**：照 qoder 配方实测 `~/.claude*` seed + anthropic egress（内建 `agent-claude` profile 或自定义）。
- **优先级**：按需。

## 7. 修订回路（export 冻结的代偿）

- **问题**（✅ 实测回归）：export 即冻结，复核发现一行小错也只能整单重跑（新 box + seed + 上下文全丢）。
- **方向**（🟡 推理）：复核反馈写回 box 前用 `h5i box shell` 交互式修（box 未 export 时可续 run）；或把"小修"降级为 `box shell` 人工介入流程写进 SKILL.md。
- **优先级**：低（整单重跑可接受时不紧迫）。

---

*维护：这是开发 backlog，不进 SKILL.md 触发上下文。完成某项后从此移除并在 CHANGELOG/commit 记录。*
