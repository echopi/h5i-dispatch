# h5i-dispatch

主 session skill —— 把隔离、可并行的子任务派给另一个 agent（qoder / pi / codex）后台执行。worker 跑在 **h5i box**（[h5i](https://github.com/h5i-dev/h5i) 0.3.x 的受限开发环境：git worktree + pinned 策略 + host 侧 receipt）里，产物经 **export 门**（patch.diff + report.md + receipt.json）由主 session 人工复核后合入；并能**主动识别**可并行的活、提示派发。

v0.4.0 起不再依赖 `h5i msg` 消息总线（上游 2026-08-05 pivot 已删除，见 h5i-dev/h5i#385）。

## 安装
把本 skill 放进 agent 的 skills 目录：
```bash
git clone https://github.com/echopi/h5i-dispatch.git
cp -r h5i-dispatch ~/.agents/skills/   # 或你的 harness skills 目录
```

## 用法
适用场景、主动识别信号、env 旋钮、实测坑、安全前提见 [SKILL.md](SKILL.md)。一把梭 helper：`scripts/dispatch.sh <qoder|pi|codex> <box-name> <task-file>`。内网发布走 ContextLab registry；GitHub clone 仅作源码安装/开发路径。

依赖：[h5i](https://github.com/h5i-dev/h5i) 0.3.x（box 模型）+ `timeout`/`gtimeout` + `rsync` + 至少一个 worker CLI（qoder / pi / codex）。

> ⚠ 单用户本机专用：worker 持凭据副本 + 权限绕过参数（box 策略是外层边界），仅限你独占的可信机器；patch 必须人工复核后才合入（详见 SKILL.md「安全前提」）。

## License
MIT
