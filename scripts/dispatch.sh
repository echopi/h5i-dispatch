#!/usr/bin/env bash
# h5i-dispatch — dispatch an isolated subtask to a BACKGROUND agent running
# inside an h5i box (confined git worktree + pinned policy + host-side receipts).
#
# v0.4.0: migrated from the removed `h5i msg` bus to the h5i 0.3.x box model.
#   - handoff    = task file copied into the box work dir (never via argv)
#   - completion = `h5i box run` exit code (124 = timeout; a killed run writes NO receipt)
#   - verify     = `h5i box export` -> patch.diff + report.md + receipt.json
#     Receipts are host-side records of process behaviour; the patch CONTENT is
#     still worker-controlled and MUST be reviewed before `git apply`.
#
# Usage:
#   dispatch.sh <qoder|pi|codex> <box-name> <task-file>
#
# Env knobs (all have defaults):
#   H5I_BIN              h5i binary (default: `command -v h5i`)
#   H5I_VERSION_PREFIX   required h5i version prefix (default: 0.3.; fail-closed)
#   QODER_BIN/PI_BIN/CODEX_BIN  worker binaries (default: resolve on PATH)
#   WORKER_TIMEOUT       seconds (default 1800). timeout/gtimeout is REQUIRED.
#   MAX_TASK_BYTES       task file size cap (default 60000)
#   DISPATCH_PROXY       proxy for pi (default http://127.0.0.1:${PROXY_PORT:-7897})
#   DISPATCH_KEEP_BOX    1 = do not rm the box at the end (debug)
#   DISPATCH_FROM        base revision for the box (default: HEAD), passed to
#                        `h5i box --from` and pinned immutably at creation
#   DISPATCH_EXTRA_ARGS  extra CLI args injected HOST-SIDE into the worker
#                        command line (e.g. '--model GLM-5.3'). Charset-validated:
#                        the box policy only allows exec'ing the worker binary
#                        itself (a wrapper script is denied), so this is the
#                        supported way to select a model / pass extra flags.
#
# The script BLOCKS until the worker finishes. Run it inside your harness's
# background-task mechanism (e.g. Claude Code run_in_background) to keep the
# main session free; monitor with `h5i box log <box-name>` / `h5i box diff`.
set -euo pipefail

KIND="${1:-}"; BOX="${2:-}"; TASK_FILE="${3:-}"
[ -n "$KIND" ] && [ -n "$BOX" ] && [ -n "$TASK_FILE" ] || {
  echo "usage: dispatch.sh <qoder|pi|codex> <box-name> <task-file>" >&2; exit 2; }

case "$KIND" in qoder|pi|codex) ;; *)
  echo "FATAL: unknown worker kind '$KIND' (qoder|pi|codex)" >&2; exit 2 ;; esac
case "$BOX" in *[!A-Za-z0-9._-]*|"")
  echo "FATAL: box-name must match ^[A-Za-z0-9._-]+$" >&2; exit 2 ;; esac

H5I="${H5I_BIN:-$(command -v h5i || true)}"
[ -x "$H5I" ] || { echo "FATAL: h5i not found (set H5I_BIN; install: https://github.com/h5i-dev/h5i)" >&2; exit 1; }

# fail-closed version pin: the box surface is young and high-churn upstream
H5I_VER="$("$H5I" --version 2>/dev/null | awk '{print $2}')"
H5I_VERSION_PREFIX="${H5I_VERSION_PREFIX:-0.3.}"
case "$H5I_VER" in "$H5I_VERSION_PREFIX"*) ;; *)
  echo "FATAL: h5i $H5I_VER does not match required prefix '$H5I_VERSION_PREFIX' (this script targets the 0.3.x box model)" >&2; exit 1 ;; esac

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
[ -n "$TIMEOUT_BIN" ] || { echo "FATAL: timeout/gtimeout required (macOS: brew install coreutils)" >&2; exit 1; }

[ -f "$TASK_FILE" ] || { echo "FATAL: task file not found: $TASK_FILE" >&2; exit 1; }
TASK_BYTES=$(wc -c < "$TASK_FILE" | tr -d ' ')
MAX_TASK_BYTES="${MAX_TASK_BYTES:-60000}"
[ "$TASK_BYTES" -le "$MAX_TASK_BYTES" ] || { echo "FATAL: task file ${TASK_BYTES}B > MAX_TASK_BYTES=${MAX_TASK_BYTES}; put bulky context in tracked files and hand off a concise pointer" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || { echo "FATAL: not inside a git repo (a box is a worktree of THIS repo)" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel)"
BASE_SHA="$(git rev-parse HEAD)"

# --- optional knobs: fail closed BEFORE the box exists -----------------------
# DISPATCH_FROM pins an alternate base (sha / ref); h5i resolves and re-pins it
# immutably at creation. Reject anything but a plain revision spelling.
DISPATCH_FROM="${DISPATCH_FROM:-}"
if [ -n "$DISPATCH_FROM" ]; then
  case "$DISPATCH_FROM" in *[!A-Za-z0-9._/~^-]*|"")
    echo "FATAL: DISPATCH_FROM must be a plain git revision (sha or ref like HEAD~1; no spaces/quotes): '$DISPATCH_FROM'" >&2; exit 2 ;; esac
  BASE_SHA="$DISPATCH_FROM"
fi

# DISPATCH_EXTRA_ARGS is interpolated into the `sh -c` command line below
# (host-side, NOT via env.pass — so existing profiles need no migration).
# Restrict the charset so it can never break out of that interpolation.
DISPATCH_EXTRA_ARGS="${DISPATCH_EXTRA_ARGS:-}"
if [ -n "$DISPATCH_EXTRA_ARGS" ]; then
  case "$DISPATCH_EXTRA_ARGS" in *[!A-Za-z0-9\ .=:,_/-]*)
    echo "FATAL: DISPATCH_EXTRA_ARGS contains shell metacharacters (allowed: alnum space . = : , _ / -): '$DISPATCH_EXTRA_ARGS'" >&2; exit 2 ;; esac
fi

# --- profiles: ensure .h5i/env.toml carries the worker profiles -------------
# Machine-local grants; file stays untracked unless you commit it. Idempotent:
# appends only missing [profile.*] blocks. Grants verified on macOS arm64
# (Seatbelt supervised tier) 2026-08-18; egress lists were discovered from
# receipt `denied` findings, not guessed.
ENV_TOML="$REPO_ROOT/.h5i/env.toml"
ensure_profile() { # $1=name $2=body
  if [ -f "$ENV_TOML" ] && grep -q "^\[profile\.$1\]" "$ENV_TOML"; then return 0; fi
  mkdir -p "$REPO_ROOT/.h5i"
  printf '\n[profile.%s]\n%s\n' "$1" "$2" >> "$ENV_TOML"
  echo "note: appended [profile.$1] to $ENV_TOML (machine-local)"
}
# NOTE: env.pass REPLACES the ambient env (PATH drops to a bare default), so
# PATH must be listed explicitly or the worker binary is not found.
ensure_profile agent-qoder 'fs.read = ["/tmp", "/opt/homebrew"]
fs.write = ["/tmp"]
env.pass = ["PATH", "HOME", "INSTRUCTION", "QODER_BIN", "PI_BIN", "CODEX_BIN", "DISPATCH_PROXY", "PROXY_PORT"]
net.mode = "host"
net.egress = ["api2.qoder.sh", "api3.qoder.sh", "center.qoder.sh", "openapi.qoder.sh"]'
ensure_profile agent-pi 'fs.read = ["/tmp", "/opt/homebrew", "~/.local/lib/pi-bin"]
fs.write = ["/tmp"]
env.pass = ["PATH", "HOME", "INSTRUCTION", "QODER_BIN", "PI_BIN", "CODEX_BIN", "DISPATCH_PROXY", "PROXY_PORT"]
net.mode = "host"
net.egress = ["api.anthropic.com", "platform.claude.com", "registry.npmjs.org", "github.com", "codeload.github.com", "objects.githubusercontent.com"]'
# codex uses the BUILT-IN agent-codex profile (HOME-state copy + OpenAI egress).

# --- create box --------------------------------------------------------------
echo ">> creating box '$BOX' (worker=$KIND, base=$BASE_SHA)"
"$H5I" box --name "$BOX" --profile "agent-$KIND" ${DISPATCH_FROM:+--from "$DISPATCH_FROM"} >&2

WORK="$REPO_ROOT/.git/.h5i/env/human/$BOX/work"
[ -d "$WORK" ] || { echo "FATAL: box work dir missing: $WORK" >&2; exit 1; }

cleanup() {
  if [ "${DISPATCH_KEEP_BOX:-0}" = "1" ] || [ "${EXPORT_OK:-0}" != "1" ]; then
    [ "${EXPORT_OK:-0}" = "1" ] || echo ">> keeping box '$BOX' for forensics (export did not succeed; rm manually: h5i box rm $BOX --force)"
    return 0
  fi
  echo ">> cleaning up box '$BOX' (auth seed + frozen state)"
  "$H5I" box rm "$BOX" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- seed worker HOME state (copy-in; never written back to the host) -------
# qodercli and pi hard-resolve $HOME at startup; the box never grants the real
# home dir, so HOME is redirected to a seeded dir inside the work dir.
# Tokens sit under .git/.h5i/ while the box lives: never pushed, removed by
# `box rm`, but included in whole-disk backups (Time Machine) — know this.
case "$KIND" in
  qoder)
    [ -d "${HOME}/.qoder" ] || { echo "FATAL: ~/.qoder missing (qoder not set up on host?)" >&2; exit 1; }
    mkdir -p "$WORK/qhome/.qoder"
    # -L dereferences symlinks (a link target outside the box would EPERM);
    # --exclude=.git: a nested git repo in the seed fails the export's mediated commit
    rsync -aL --exclude=.git --exclude=logs --exclude=projects --exclude=bin \
      --exclude=external-commands --exclude=extensions --exclude=file-history \
      --exclude=cache --exclude=memories --exclude=knowledges \
      "$HOME/.qoder/" "$WORK/qhome/.qoder/" ;;
  pi)
    [ -d "${HOME}/.pi" ] || { echo "FATAL: ~/.pi missing (pi not set up on host?)" >&2; exit 1; }
    mkdir -p "$WORK/phome/.pi"
    # agent/git MUST stay (pre-cloned auth extension) but strip nested .git dirs:
    # a nested git repo fails the export's mediated commit
    rsync -aL --exclude=.git --exclude=npm "$HOME/.pi/" "$WORK/phome/.pi/" ;;
  codex) : ;; # built-in HOME-state seeding
esac

# --- handoff: task file into the work dir (NOT argv: receipts + ps) ---------
cp "$TASK_FILE" "$WORK/.dispatch-task.md"
export INSTRUCTION="You are a background worker inside an isolated h5i box. Read the file .dispatch-task.md in your current directory and execute it exactly. Only touch the paths it allows. When done, stop."
export QODER_BIN="${QODER_BIN:-}" PI_BIN="${PI_BIN:-}" CODEX_BIN="${CODEX_BIN:-}"
export DISPATCH_PROXY="${DISPATCH_PROXY:-}" PROXY_PORT="${PROXY_PORT:-}"

WORKER_TIMEOUT="${WORKER_TIMEOUT:-1800}"
echo ">> running $KIND worker in box '$BOX' (timeout ${WORKER_TIMEOUT}s)"
set +e
"$TIMEOUT_BIN" "$WORKER_TIMEOUT" "$H5I" box run "$BOX" -- sh -c '
  case '"$KIND"' in
    qoder) HOME=$PWD/qhome exec "${QODER_BIN:-qodercli}" '"$DISPATCH_EXTRA_ARGS"' -p "$INSTRUCTION" --dangerously-skip-permissions ;;
    pi)    HTTP_PROXY="${DISPATCH_PROXY:-http://127.0.0.1:${PROXY_PORT:-7897}}" \
           HTTPS_PROXY="${DISPATCH_PROXY:-http://127.0.0.1:${PROXY_PORT:-7897}}" \
           HOME=$PWD/phome exec "${PI_BIN:-pi}" '"$DISPATCH_EXTRA_ARGS"' -p "$INSTRUCTION" --no-session ;;
    codex) exec "${CODEX_BIN:-codex}" exec '"$DISPATCH_EXTRA_ARGS"' --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$INSTRUCTION" ;;
  esac'
RC=$?
set -e

if [ "$RC" -eq 124 ]; then
  echo "FATAL: worker hit WORKER_TIMEOUT=${WORKER_TIMEOUT}s. NOTE: a killed run writes NO receipt; box may show 'running (stale)' but stays reusable." >&2
  exit 124
fi
echo ">> worker exited rc=$RC"

# drop the seed + task file before export: keeps the patch clean of HOME-state
# noise and shortens the token-on-disk window (the run is already over)
case "$KIND" in
  qoder) rm -rf "$WORK/qhome" ;;
  pi)    rm -rf "$WORK/phome" ;;
esac
rm -f "$WORK/.dispatch-task.md"

# --- output gate -------------------------------------------------------------
echo ">> exporting (freeze box -> patch.diff + report.md + receipt.json)"
"$H5I" box export "$BOX" >&2
EXPORT_OK=1
EXPORT_DIR="$REPO_ROOT/h5i-export/$BOX"
[ -s "$EXPORT_DIR/patch.diff" ] || echo "note: patch.diff is empty (worker changed nothing)"

echo ""
echo "================ DISPATCH RESULT ================"
echo "worker      : $KIND (box $BOX)"
echo "worker rc   : $RC   (0 expected; anything else = worker reported failure)"
echo "base sha    : $BASE_SHA  (re-check before apply: main may have moved)"
echo "patch files :"
grep -E '^diff --git' "$EXPORT_DIR/patch.diff" 2>/dev/null | sed 's/diff --git/  /' || echo "  (none)"
echo ""
echo "REVIEW BEFORE APPLYING — the patch is worker-controlled output:"
echo "  1. read $EXPORT_DIR/report.md  (commands run, denied egress)"
echo "  2. check patch paths against the task's allowed-paths whitelist"
echo "     (watch renames/symlinks/new binaries); never apply with --unsafe-paths"
echo "  3. assert your worktree is clean, then: git apply --3way $EXPORT_DIR/patch.diff"
echo "================================================="
exit "$RC"
