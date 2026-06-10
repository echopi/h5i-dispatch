# h5i-dispatch

Claude Code skill —— 把隔离、可并行的子任务派给另一个 agent（codex / claude / 任意 Claude-Code-harness）后台执行，经 **h5i**（基于 git ref 的消息总线）+ **git worktree** 通信，worker 跑完自动唤主 session 验证回报；并能**主动识别**可并行的活、提示派发。

## 安装
把本 skill 放进你 agent 的 skills 目录：
```bash
git clone https://github.com/echopi/h5i-dispatch.git
cp -r h5i-dispatch ~/.agents/skills/   # 或你 harness 的 skills 目录（如 .claude/skills/）
```

## 用法
适用场景、主动识别信号、env 旋钮、实测坑、安全前提见 [SKILL.md](SKILL.md)。一把梭 helper：`scripts/dispatch.sh <codex|claude> <wt-name> <task-file>`。

依赖：[h5i](https://github.com/h5i-dev/h5i)（git agent 消息总线）+ codex/claude CLI。

> ⚠ 单用户本机专用：h5i v1 消息不签名、worker 走 sandbox bypass，仅限你独占的可信机器（详见 SKILL.md「安全前提」）。

## License
MIT
