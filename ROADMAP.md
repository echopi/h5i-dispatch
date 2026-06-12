# h5i-dispatch ROADMAP

设计/协议层待办。当前 h5i-dispatch 是**单机可信 + 靠文本约定 + 人工复核**的 MVP；下列各项把它推向**可信 / 可管控 / 结构化 / 可组合**的生产级。

**触发条件**：这些在**单机自用**场景下不紧迫（已有代偿）；真正变"必须"是当 h5i-dispatch 要**走出单机**——多用户机 / 共享仓 / 无人值守自动合 / 大规模并行编排。

论断分级：✅ 实测 / 🟡 推理（设计构想未落地验证）。

---

## 1. h5i 消息签名（去掉人工复核瓶颈）

- **问题**（✅ 实测）：h5i v1 消息不签名、`from` 字段可伪造——同机任意进程能伪造 worker 的 DONE 回报骗主 session。
- **现状代偿**：SKILL.md 强制"DONE 只当完成提示，必须主 session 亲自 `git diff` 复核，绝不凭 DONE 自动合"。
- **解决后**：可信回报 → 允许更高自动化（可信回报自动合，去掉人工复核瓶颈）。
- **方向**：HMAC + shared secret，或借 git commit signature。
- **优先级**：低（单机可信前提下人工复核已足够）；走出单机时升为必须。

## 2. 跨 harness token budget 协议（配额管控）

- **问题**（🟡 推理）：worker 跑在独立配额（codex）/ 远端机时，主 session 看不到它烧了多少 token，只有时间闸（`WORKER_TIMEOUT`）没有配额闸。
- **现状代偿**：`WORKER_TIMEOUT` 时间兜底。
- **解决后**：worker 启动前 claim 预算、完成后 return 剩余、超预算主端可取消。
- **优先级**：低（timeout 代偿够用）；大规模/远端派发时升级。

## 3. h5i 协议扩展 phase / progress / schema（结构化回报）

- **问题**（🟡 推理）：PROGRESS / DONE 全靠 **body 文本前缀约定**（`PROGRESS:` / `DONE: {json}`），弱后端 worker 易写错格式，主端字符串解析脆弱。
- **现状代偿**：v0.2.0+ 把 DONE 做成 JSON、prompt 里约定 PROGRESS——但协议层没强制校验。
- **解决后**：把 phase / progress / 结构化输出做成 h5i 的 **kind 原语 + schema 校验**，回报结构化、可校验、不靠约定。
- **优先级**：中（当前 JSON 约定已较稳，但弱后端场景收益明显）。

## 4. Workflow ↔ h5i bridge（两套机制可组合）

- **问题**（🟡 推理）：Claude Code 内置 Workflow（同 session 高性能编排）和 h5i-dispatch（跨 session/harness）是两套独立机制，子任务要跨边界时无法无缝衔接。
- **现状代偿**：二选一——全 Workflow（跨不了边界）或全 h5i（同 session 也付 worktree + 延迟成本）。
- **解决后**：Workflow 脚本能把某个 stage 下放给 h5i worker 当远端后端，各取所长。
- **优先级**：低（nice-to-have，两套各自能用）。

---

*维护：这是开发 backlog，不进 SKILL.md 触发上下文。完成某项后从此移除并在 CHANGELOG/commit 记录。*
