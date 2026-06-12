#!/usr/bin/env bash
# h5i-dispatch — dispatch an isolated subtask to a BACKGROUND agent, communicating
# over h5i (git-ref message bus) + a git worktree. Worker reports via h5i when done.
#
# ⚠ This script BLOCKS until the worker finishes. Run it via your harness's background
#    mechanism (Claude Code: run_in_background) so the main session isn't held — on exit
#    the harness wakes the main session. Foreground is fine for manual one-offs (you wait).
#
# Usage: dispatch.sh <codex|claude|qoder> <wt-name> <task-file> [dispatcher=claude-main] [worker-id]
#   wt-name    must match ^[A-Za-z0-9._-]+$ (used in worktree path / branch / tmp names)
#   worker-id  default "<kind>-<wt-name>" (UNIQUE per dispatch → no identity collision)
#
# Env (optional, no machine-specific hardcoding):
#   H5I_BIN / CODEX_BIN / CLAUDE_BIN / QODER_BIN
#                                      binary paths (default: resolve on PATH; H5I falls back to ~/.local/bin/h5i)
#   DISPATCH_PROXY                     http proxy URL; if set, exported as HTTP(S)_PROXY/ALL_PROXY (upper+lower) for the worker.
#                                      Set it when your agent CLI normally gets its proxy from a shell wrapper — this script
#                                      calls the binary directly and bypasses such wrappers (shell functions don't exist in bash).
#   WORKER_ALLOWED_TOOLS               comma-separated tool list passed to claude/qoder (default: Read,Grep,Glob,Edit,Bash).
#                                      claude uses --allowedTools, qoder uses --allowed-tools.
#                                      codex exec has no standard tool-restrict flag; this var is ignored for codex.
#   WORKER_TIMEOUT                     seconds (default 1800). Requires timeout/gtimeout.
#   ALLOW_NO_TIMEOUT=1                 run worker unbounded when no timeout binary exists (NOT recommended).
set -euo pipefail

KIND="${1:?worker kind: codex|claude|qoder}"
WT_NAME="${2:?worktree name (^[A-Za-z0-9._-]+$)}"
TASK_FILE="${3:?task file (handoff body)}"
DISPATCHER="${4:-claude-main}"
WORKER_ID="${5:-${KIND}-${WT_NAME}}"
WORKER_TIMEOUT="${WORKER_TIMEOUT:-1800}"
WORKER_ALLOWED_TOOLS="${WORKER_ALLOWED_TOOLS:-Read,Grep,Glob,Edit,Bash}"

# --- validate inputs (WT_NAME flows into path / branch / tmp) ---
[[ "$WT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "FATAL: wt-name must match ^[A-Za-z0-9._-]+\$ : '$WT_NAME'"; exit 2; }
case "$WT_NAME" in .*|*..*) echo "FATAL: wt-name must not start with '.' or contain '..': '$WT_NAME'"; exit 2 ;; esac
case "$KIND" in codex|claude|qoder) ;; *) echo "FATAL: worker kind must be codex|claude|qoder, got '$KIND'"; exit 2 ;; esac
[ -f "$TASK_FILE" ] || { echo "FATAL: task file not found: $TASK_FILE"; exit 1; }

# --- resolve binaries (env override > PATH > fallback) ---
H5I="${H5I_BIN:-$(command -v h5i || echo "$HOME/.local/bin/h5i")}"
[ -x "$H5I" ] || { echo "FATAL: h5i not found (set H5I_BIN, or install: https://github.com/h5i-dev/h5i)"; exit 1; }
case "$KIND" in
  codex)  WORKER_BIN="${CODEX_BIN:-$(command -v codex || true)}";    KENV=CODEX_BIN ;;
  claude) WORKER_BIN="${CLAUDE_BIN:-$(command -v claude || true)}";  KENV=CLAUDE_BIN ;;
  qoder)  WORKER_BIN="${QODER_BIN:-$(command -v qodercli || true)}"; KENV=QODER_BIN ;;
esac
[ -n "$WORKER_BIN" ] && [ -x "$WORKER_BIN" ] || { echo "FATAL: $KIND binary not found (set $KENV, or install $KIND)"; exit 1; }

ROOT="$(git rev-parse --show-toplevel)"
WT="$ROOT/.claude/worktrees/$WT_NAME"
BRANCH="dispatch/$WT_NAME"
# anti-collision: timestamp + random suffix prevents races between concurrent dispatches
LAST="${TMPDIR:-/tmp}/dispatch-$WT_NAME-$(date +%s)-$RANDOM-last.txt"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || { echo "FATAL: invalid branch name: $BRANCH"; exit 2; }
TASK="$(cat "$TASK_FILE")"

# residue pre-check: fail-loud (don't auto-nuke a worktree we didn't create — may hold prior output)
if git worktree list --porcelain | grep -Fqx "worktree $WT"; then
  echo "FATAL: worktree exists: $WT  (prev run? clean: git worktree remove --force '$WT')"; exit 1
fi
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "FATAL: branch exists: $BRANCH  (clean: git branch -D '$BRANCH')"; exit 1
fi

# isolation pre-check: warn if task paths overlap with dirty files in the main worktree (heuristic, not fatal)
# extract path-like tokens from task file, keep only tracked files/directories to avoid URL/noise false positives
_task_paths="$(grep -oE '([a-zA-Z0-9_-]+/)+[a-zA-Z0-9_.-]+' "$TASK_FILE" | while IFS= read -r _candidate; do
  # accept if it is a tracked file, or a directory that contains tracked files
  git -C "$ROOT" ls-files --error-unmatch "$_candidate" >/dev/null 2>&1 || [ -n "$(git -C "$ROOT" ls-files "$_candidate" | head -1)" ] || continue
  echo "$_candidate"
done | sort -u || true)"
if [ -n "$_task_paths" ]; then
  _dirty=""
  while IFS= read -r _p; do
    # check the exact path (file or directory) against the main worktree dirty status
    _status="$(git -C "$ROOT" status --porcelain -- "$_p" 2>/dev/null || true)"
    [ -n "$_status" ] && _dirty="${_dirty} $_p"
  done <<< "$_task_paths"
  if [ -n "$_dirty" ]; then
    echo "WARN: task paths overlap with main worktree dirty files:$_dirty"
    echo "WARN: review before proceeding to avoid merge conflicts"
  fi
fi

# trap: always remove the prompt; remove OUR worktree+branch only during setup (before worker starts).
PROMPT="$(mktemp)"
CLEANUP_WT=0
cleanup() {
  rm -f "$PROMPT"
  [ "$CLEANUP_WT" = 1 ] && { git worktree remove --force "$WT" 2>/dev/null; git branch -D "$BRANCH" 2>/dev/null; }
}
trap cleanup EXIT

# 1. worktree FIRST (failure here → no orphan handoff)
echo "== 1. worktree: $WT =="
git worktree add -b "$BRANCH" "$WT" HEAD
CLEANUP_WT=1   # from now until worker launch, a failure rolls back the worktree we just made

# 2. handoff (worktree ready)
echo "== 2. handoff: $DISPATCHER -> $WORKER_ID =="
H5I_AGENT="$DISPATCHER" "$H5I" msg handoff "$WORKER_ID" "$TASK"

# 3. worker prompt (structured DONE/PROGRESS; msg send — no fragile numbered done with concurrent dispatches)
cat > "$PROMPT" <<EOF
You are agent "$WORKER_ID" on an h5i git message bus, inside a git worktree of this repo (cwd). h5i = $H5I
1. Read your task:  $H5I msg history --plain   — the HANDOFF line addressed to "$WORKER_ID" is your task (obey its scope constraints exactly; only touch allowed paths).
2. Execute fully in THIS worktree.
3. For long tasks, send a PROGRESS heartbeat after each major phase:
   H5I_AGENT=$WORKER_ID $H5I msg send $DISPATCHER "PROGRESS: <phase> <pct>% <one-line note>"
4. On completion, send a structured DONE message:
   H5I_AGENT=$WORKER_ID $H5I msg send $DISPATCHER 'DONE: {"status":"done","files_changed":["path1","path2"],"summary":"...","verification":"..."}'
   On error:
   H5I_AGENT=$WORKER_ID $H5I msg send $DISPATCHER 'DONE: {"status":"error","error":"short reason","files_changed":[]}'
Be autonomous and concise; do not ask questions; print a final summary as your last message.
EOF

# proxy (re-supply since we bypass shell wrappers): both cases + ALL_PROXY
if [ -n "${DISPATCH_PROXY:-}" ]; then
  export HTTP_PROXY="$DISPATCH_PROXY" HTTPS_PROXY="$DISPATCH_PROXY" ALL_PROXY="$DISPATCH_PROXY"
  export http_proxy="$DISPATCH_PROXY" https_proxy="$DISPATCH_PROXY" all_proxy="$DISPATCH_PROXY"
fi
export H5I_AGENT="$WORKER_ID"

# timeout watchdog — fatal if unavailable (a runaway background agent is worse than failing fast)
TO="$(command -v timeout || command -v gtimeout || true)"
if [ -z "$TO" ] && [ "${ALLOW_NO_TIMEOUT:-0}" != 1 ]; then
  echo "FATAL: no timeout/gtimeout (brew install coreutils). Set ALLOW_NO_TIMEOUT=1 to run unbounded (NOT recommended)."; exit 1
fi
[ -n "$TO" ] && TOPFX=("$TO" "$WORKER_TIMEOUT") || { TOPFX=(); echo "WARN: ALLOW_NO_TIMEOUT — worker is unbounded"; }

# 4. run worker isolated in $WT. Keep the worktree even if the worker fails (for inspection).
CLEANUP_WT=0
echo "== 4. launch worker ($KIND, id=$WORKER_ID, timeout=${WORKER_TIMEOUT}s) — blocks until done =="
set +e
case "$KIND" in
  codex)
    # codex exec has no standard --allowed-tools flag; WORKER_ALLOWED_TOOLS is not passed
    "${TOPFX[@]}" "$WORKER_BIN" exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
      -C "$WT" -o "$LAST" - < "$PROMPT"; RC=$?
    ;;
  claude)
    ( cd "$WT" && "${TOPFX[@]}" "$WORKER_BIN" -p "$(cat "$PROMPT")" \
        --allowedTools "$WORKER_ALLOWED_TOOLS" ) > "$LAST" 2>&1; RC=$?
    ;;
  qoder)
    ( cd "$WT" && "${TOPFX[@]}" "$WORKER_BIN" -p "$(cat "$PROMPT")" -w "$WT" \
        --allowed-tools "$WORKER_ALLOWED_TOOLS" --dangerously-skip-permissions ) > "$LAST" 2>&1; RC=$?
    ;;
esac
set -e

[ "$RC" = 124 ] && echo "WARN: worker timed out (${WORKER_TIMEOUT}s) and was killed"
echo "== worker exit=$RC. last message -> $LAST =="
echo "verify:   git -C '$WT' diff --stat   &&   '$H5I' msg history --plain | tail"
echo "cleanup:  git worktree remove --force '$WT' && git branch -D '$BRANCH'"
exit "$RC"
