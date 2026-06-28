#!/usr/bin/env bash
# h5i-dispatch — dispatch an isolated subtask to a BACKGROUND agent, communicating
# over h5i (git-ref message bus) + a git worktree. Worker reports via h5i when done.
#
# ⚠ This script BLOCKS until the worker finishes. Run it via your harness's background
#    mechanism when available; otherwise run it in another terminal/session and poll h5i.
#    Foreground is fine for manual one-offs (you wait).
#
# Usage: dispatch.sh <codex|claude|qoder> <wt-name> <task-file> [dispatcher=main] [worker-id]
#   wt-name    must match ^[A-Za-z0-9._-]+$ (used in worktree path / branch / tmp names)
#   worker-id  default "<kind>-<wt-name>-<timestamp>-<random>" (UNIQUE per dispatch → no identity collision)
#
# Env (optional, no machine-specific hardcoding):
#   H5I_BIN / CODEX_BIN / CLAUDE_BIN / QODER_BIN
#                                      binary paths (default: resolve on PATH; H5I falls back to ~/.local/bin/h5i)
#   DISPATCH_WORKTREE_ROOT             worktree parent dir (default: <repo>/.worktrees/h5i)
#   DISPATCH_PROXY                     http proxy URL; if set, exported as HTTP(S)_PROXY/ALL_PROXY (upper+lower) for the worker.
#                                      Set it when your agent CLI normally gets its proxy from a shell wrapper — this script
#                                      calls the binary directly and bypasses such wrappers (shell functions don't exist in bash).
#   MAX_HANDOFF_BYTES                  max task-file size sent through h5i CLI args (default: 60000).
#                                      h5i handoff currently takes BODY as argv, not stdin/file.
#   WORKER_ALLOWED_TOOLS               comma-separated tool list passed to claude/qoder (default: Read,Grep,Glob,Edit,Write,Bash).
#                                      claude uses --allowedTools, qoder uses --allowed-tools.
#                                      codex exec has no standard tool-restrict flag; this var is ignored for codex.
#   WORKER_TIMEOUT                     seconds (default 1800). Requires timeout/gtimeout.
#   ALLOW_NO_TIMEOUT=1                 run worker unbounded when no timeout binary exists (NOT recommended).
set -euo pipefail

KIND="${1:?worker kind: codex|claude|qoder}"
WT_NAME="${2:?worktree name (^[A-Za-z0-9._-]+$)}"
TASK_FILE="${3:?task file (handoff body)}"
DISPATCHER="${4:-main}"
WORKER_ID="${5:-${KIND}-${WT_NAME}-$(date +%Y%m%d%H%M%S)-$RANDOM}"
WORKER_TIMEOUT="${WORKER_TIMEOUT:-1800}"
WORKER_ALLOWED_TOOLS="${WORKER_ALLOWED_TOOLS:-Read,Grep,Glob,Edit,Write,Bash}"
MAX_HANDOFF_BYTES="${MAX_HANDOFF_BYTES:-60000}"

# --- validate inputs (WT_NAME flows into path / branch / tmp) ---
[[ "$WT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "FATAL: wt-name must match ^[A-Za-z0-9._-]+\$ : '$WT_NAME'"; exit 2; }
case "$WT_NAME" in .*|*..*) echo "FATAL: wt-name must not start with '.' or contain '..': '$WT_NAME'"; exit 2 ;; esac
case "$KIND" in codex|claude|qoder) ;; *) echo "FATAL: worker kind must be codex|claude|qoder, got '$KIND'"; exit 2 ;; esac
# DISPATCHER/WORKER_ID flow into h5i commands + the worker prompt → validate the same
# charset as WT_NAME to close the prompt/shell-injection surface (codex review G2).
[[ "$DISPATCHER" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "FATAL: dispatcher must match ^[A-Za-z0-9._-]+\$ : '$DISPATCHER'"; exit 2; }
[[ "$WORKER_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "FATAL: worker-id must match ^[A-Za-z0-9._-]+\$ : '$WORKER_ID'"; exit 2; }
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
if [ -n "${DISPATCH_WORKTREE_ROOT:-}" ]; then
  case "$DISPATCH_WORKTREE_ROOT" in
    /*) WT_ROOT="$DISPATCH_WORKTREE_ROOT" ;;
    *)  WT_ROOT="$ROOT/$DISPATCH_WORKTREE_ROOT" ;;
  esac
else
  WT_ROOT="$ROOT/.worktrees/h5i"
fi
WT="$WT_ROOT/$WT_NAME"
BRANCH="dispatch/$WT_NAME"
# anti-collision: timestamp + random suffix prevents races between concurrent dispatches.
# strip trailing slash from TMPDIR (macOS sets it to .../T/) so we don't get a double slash.
TMP_DIR="${TMPDIR:-/tmp}"; TMP_DIR="${TMP_DIR%/}"
LAST="$TMP_DIR/dispatch-$WT_NAME-$(date +%s)-$RANDOM-last.txt"
RUN_LOG="$LAST"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || { echo "FATAL: invalid branch name: $BRANCH"; exit 2; }
TASK="$(cat "$TASK_FILE")"
TASK_BYTES="$(wc -c < "$TASK_FILE" | tr -d '[:space:]')"
case "$MAX_HANDOFF_BYTES" in
  ''|*[!0-9]*) echo "FATAL: MAX_HANDOFF_BYTES must be a positive integer, got '$MAX_HANDOFF_BYTES'"; exit 2 ;;
esac
if [ "$TASK_BYTES" -gt "$MAX_HANDOFF_BYTES" ]; then
  echo "FATAL: task file is ${TASK_BYTES} bytes, above MAX_HANDOFF_BYTES=${MAX_HANDOFF_BYTES}."
  echo "FATAL: h5i handoff accepts BODY via argv, so large tasks risk ARG_MAX and ps exposure. Put bulky context in tracked/tmp files and hand off a concise pointer."
  exit 2
fi

# residue pre-check: fail-loud (don't auto-nuke a worktree we didn't create — may hold prior output)
if git worktree list --porcelain | grep -Fqx "worktree $WT"; then
  echo "FATAL: worktree exists: $WT  (prev run? clean: git worktree remove --force '$WT')"; exit 1
fi
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "FATAL: branch exists: $BRANCH  (clean: git branch -D '$BRANCH')"; exit 1
fi

# isolation pre-check: warn if task paths overlap with dirty files in the main worktree (heuristic, not fatal)
# extract path-like tokens from task file, keep only tracked files/directories to avoid URL/noise false positives
_task_paths="$(grep -oE '(\./)?[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*' "$TASK_FILE" | while IFS= read -r _candidate; do
  _candidate="${_candidate#./}"
  case "$_candidate" in ''|.|..) continue ;; esac
  # accept if it is a tracked file, or a directory that contains tracked files
  git -C "$ROOT" ls-files --error-unmatch "$_candidate" >/dev/null 2>&1 || [ -n "$(git -C "$ROOT" ls-files "$_candidate" | sed -n '1p')" ] || continue
  echo "$_candidate"
done | sort -u || true)"
if [ -n "$_task_paths" ]; then
  _dirty=""
  while IFS= read -r _p; do
    # check the exact path (file or directory) against the main worktree dirty status
    _status="$(git -C "$ROOT" status --porcelain -- "$_p" 2>/dev/null || true)"
    [ -n "$_status" ] && _dirty+=$'\n'"  $_p"
  done <<< "$_task_paths"
  if [ -n "$_dirty" ]; then
    printf 'WARN: task paths overlap with main worktree dirty files:%s\n' "$_dirty"
    echo "WARN: review before proceeding to avoid merge conflicts"
  fi
fi

# trap: always remove the prompt; remove OUR worktree+branch only during setup (before worker starts).
PROMPT="$(mktemp)"
CLEANUP_WT=0
# shellcheck disable=SC2329 # invoked by EXIT trap
cleanup() {
  rm -f "$PROMPT"
  if [ "$CLEANUP_WT" = 1 ]; then
    git worktree remove --force "$WT" 2>/dev/null || true
    git branch -D "$BRANCH" 2>/dev/null || true
  fi
  # MUST end on status 0: under `set -e`, a non-zero last command in an EXIT trap
  # overrides `exit "$RC"` → the script exits 1 even on success (and masks real RC).
  return 0
}
trap cleanup EXIT

# 1. worktree FIRST (failure here → no orphan handoff)
echo "== 1. worktree: $WT =="
mkdir -p "$WT_ROOT"
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
3. For long tasks, send a PROGRESS heartbeat after each major phase. It MUST go through h5i (the dispatcher only sees the bus, not your stdout — printing PROGRESS to stdout alone is invisible):
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
if [ -n "$TO" ]; then
  TOPFX=("$TO" "$WORKER_TIMEOUT")
else
  TOPFX=()
  echo "WARN: ALLOW_NO_TIMEOUT — worker is unbounded"
fi

# 4. run worker isolated in $WT. Keep the worktree even if the worker fails (for inspection).
CLEANUP_WT=0
echo "== 4. launch worker ($KIND, id=$WORKER_ID, timeout=${WORKER_TIMEOUT}s) — blocks until done =="
set +e
case "$KIND" in
  codex)
    # codex exec has no standard --allowed-tools flag; WORKER_ALLOWED_TOOLS is not passed
    RUN_LOG="$TMP_DIR/dispatch-$WT_NAME-$(date +%s)-$RANDOM-run.log"
    "${TOPFX[@]}" "$WORKER_BIN" exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
      -C "$WT" -o "$LAST" - < "$PROMPT" > "$RUN_LOG" 2>&1; RC=$?
    ;;
  claude)
    ( cd "$WT" && "${TOPFX[@]}" "$WORKER_BIN" -p "$(cat "$PROMPT")" \
        --allowedTools "$WORKER_ALLOWED_TOOLS" ) > "$LAST" 2>&1; RC=$?
    ;;
  qoder)
    # cd "$WT" already sets the cwd; qoder's -w would be redundant (kept lean to match the claude branch)
    ( cd "$WT" && "${TOPFX[@]}" "$WORKER_BIN" -p "$(cat "$PROMPT")" \
        --allowed-tools "$WORKER_ALLOWED_TOOLS" --dangerously-skip-permissions ) > "$LAST" 2>&1; RC=$?
    ;;
esac
set -e

[ "$RC" = 124 ] && echo "WARN: worker timed out (${WORKER_TIMEOUT}s) and was killed"

# G1: verify the worker actually sent a DONE on the bus. A silent exit (crash/kill, or
# exit 0 without reporting) leaves no terminal state → a caller could mistake it for
# success. Promote to exit 3 (protocol violation). Do NOT synthesize a fake DONE on the
# bus (it could be mistaken for the worker's real report).
_HIST="$(H5I_AGENT="$DISPATCHER" "$H5I" msg history --plain 2>/dev/null || true)"
if ! printf '%s\n' "$_HIST" | grep -F "${WORKER_ID} -> ${DISPATCHER}" | grep -qF "DONE:"; then
  echo "FATAL: worker '$WORKER_ID' exited (RC=$RC) without sending DONE — terminal state missing, do NOT auto-merge"
  [ "$RC" = 0 ] && RC=3
fi

echo "== worker exit=$RC. last message -> $LAST ; run log -> $RUN_LOG =="
echo "verify:   git -C '$WT' diff --stat   &&   '$H5I' msg history --plain | tail"
echo "cleanup:  git worktree remove --force '$WT' && git branch -D '$BRANCH'"
exit "$RC"
