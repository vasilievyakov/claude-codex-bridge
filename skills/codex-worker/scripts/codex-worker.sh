#!/bin/bash
# codex-worker.sh -- delegate a fully specified coding task to OpenAI Codex CLI.
#
# Codex runs as a worker inside an isolated git worktree (branch codex/<label>)
# under the workspace-write sandbox with approvals disabled. The script collects
# the worker's changes into a patch that is never applied automatically and
# returns a schema-constrained JSON report. Several workers with distinct labels
# can run in parallel. Compatible with bash 3.2 (macOS /bin/bash). Requires
# python3; jq not needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SCHEMA_FILE="$SCRIPT_DIR/result.schema.json"

usage() {
  cat <<'EOF'
Usage: codex-worker.sh --task "<text>" | --task-file <path> [options]
       codex-worker.sh --resume --label <name> --task "<text>" [options]
       codex-worker.sh --list [--out-dir <dir>]
       codex-worker.sh --cleanup --label <name> [--repo <dir>] [--out-dir <dir>]

Task (exactly one; required for a run and for --resume):
  --task "<text>"        the task for the worker, fully specified
  --task-file <path>     read the task text from a file

Options:
  --label <name>         worker id, also the branch name codex/<name> (default: w-<HHMMSS>)
  --repo <dir>           repository root (default: git toplevel of cwd)
  --base <ref>           the worker branch starts here (default: HEAD)
  --in-place             no worktree: Codex edits --repo directly; one worker only
  --context <path>       file or directory Codex must read first; repeatable
  --model <m>            Codex model, passed as -m; "spark" means gpt-5.3-codex-spark
  --effort <level>       low | medium | high | xhigh (default: high)
  --network              allow network inside the sandbox (sandbox_workspace_write.network_access=true)
  --search               allow web search (tools.web_search=true)
  --timeout <sec>        kill codex after <sec> seconds (default: 1800; 0 disables)
  --out-dir <dir>        outputs, worker state and worktrees (default: ${XDG_CACHE_HOME:-~/.cache}/codex-worker)
  --worktree-dir <dir>   worktree path (default: <out-dir>/worktrees/<repo>-<hash>/<label>)
  --resume               continue worker <label> in its own thread and worktree; --task is the message
  --list                 list known workers: label | status | branch | worktree | thread_id | last_run
  --cleanup              remove the worktree, the branch (only if it has no commits) and the state of <label>
  --dry-run              print the plan and the command, write the prompt; do not run codex
  --quiet                do not print live progress lines ([codex <label> mm:ss] ...) to stderr
  -h, --help             show this help

Stdout on completion: json:, markdown:, patch:, worktree:, branch:, base:, events:, log:,
prompt:, thread_id:, exit: lines, a blank line, then the JSON report. The patch is a
snapshot of the worktree against base and is never applied automatically.
Exit code: 0 ok, 2 bad arguments, 3 report failed the schema check, 4 git or worktree
failure, otherwise the codex exit code (124 on timeout).
EOF
}

die() { printf 'codex-worker: error: %s\n' "$*" >&2; exit 2; }
die4() { printf 'codex-worker: error: %s\n' "$*" >&2; exit 4; }
note() { printf 'codex-worker: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
MODE="run"
TASK=""
TASK_SET=0
TASK_FILE=""
LABEL=""
REPO=""
BASE="HEAD"
BASE_SET=0
IN_PLACE=0
CONTEXTS=()
MODEL=""
EFFORT="high"
NETWORK=0
SEARCH=0
TIMEOUT=1800
OUT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codex-worker"
WORKTREE=""
DRY_RUN=0
QUIET=0

set_mode() {
  if [ "$MODE" != "run" ] && [ "$MODE" != "$1" ]; then
    die "only one of --resume, --list, --cleanup allowed (got --$MODE and --$1)"
  fi
  MODE="$1"
}

need_val() {
  # need_val <flag> <remaining-arg-count>
  if [ "$2" -lt 2 ]; then die "$1 requires a value"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --task) need_val "$1" $#; TASK="$2"; TASK_SET=1; shift 2 ;;
    --task-file) need_val "$1" $#; TASK_FILE="$2"; shift 2 ;;
    --label) need_val "$1" $#; LABEL="$2"; shift 2 ;;
    --repo) need_val "$1" $#; REPO="$2"; shift 2 ;;
    --base) need_val "$1" $#; BASE="$2"; BASE_SET=1; shift 2 ;;
    --in-place) IN_PLACE=1; shift ;;
    --context) need_val "$1" $#; CONTEXTS+=("$2"); shift 2 ;;
    --model) need_val "$1" $#; MODEL="$2"; shift 2 ;;
    --effort) need_val "$1" $#; EFFORT="$2"; shift 2 ;;
    --network) NETWORK=1; shift ;;
    --search) SEARCH=1; shift ;;
    --timeout) need_val "$1" $#; TIMEOUT="$2"; shift 2 ;;
    --out-dir) need_val "$1" $#; OUT_DIR="$2"; shift 2 ;;
    --worktree-dir) need_val "$1" $#; WORKTREE="$2"; shift 2 ;;
    --resume) set_mode resume; shift ;;
    --list) set_mode list; shift ;;
    --cleanup) set_mode cleanup; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) die "unexpected argument: $1 (see --help)" ;;
  esac
done
if [ $# -gt 0 ]; then die "unexpected argument: $1 (see --help)"; fi

case "$EFFORT" in
  low|medium|high|xhigh) ;;
  *) die "--effort must be one of low, medium, high, xhigh (got '$EFFORT')" ;;
esac
case "$TIMEOUT" in
  ''|*[!0-9]*) die "--timeout must be a non-negative integer (seconds), got '$TIMEOUT'" ;;
esac
case "$MODEL" in
  spark) MODEL="gpt-5.3-codex-spark" ;;
esac

if [ "$TASK_SET" = 1 ] && [ -n "$TASK_FILE" ]; then
  die "use either --task or --task-file, not both"
fi

command -v python3 >/dev/null 2>&1 || { printf 'codex-worker: error: python3 not found on PATH\n' >&2; exit 1; }

abs_path() {
  # abs_path <path> -> absolute path (does not require existence of the leaf)
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd -P)" "$1" ;;
  esac
}

case "$MODE" in
  run|resume)
    if [ -n "$TASK_FILE" ]; then
      TASK_FILE="$(abs_path "$TASK_FILE")"
      [ -f "$TASK_FILE" ] || die "--task-file: no such file: $TASK_FILE"
      TASK="$(cat "$TASK_FILE")"
      TASK_SET=1
    fi
    if [ "$TASK_SET" = 0 ]; then die "--task \"<text>\" or --task-file <path> is required"; fi
    if [ -z "$TASK" ]; then die "the task text is empty"; fi
    ;;
esac
if [ "$MODE" = "resume" ] && [ -z "$LABEL" ]; then die "--resume requires --label <name> of the worker to continue"; fi
if [ "$MODE" = "cleanup" ] && [ -z "$LABEL" ]; then die "--cleanup requires --label <name>"; fi
if [ "$IN_PLACE" = 1 ] && [ "$BASE_SET" = 1 ]; then die "--base has no effect with --in-place (the snapshot is taken against HEAD)"; fi
if [ "$IN_PLACE" = 1 ] && [ -n "$WORKTREE" ]; then die "--worktree-dir has no effect with --in-place"; fi

# ---------------------------------------------------------------------------
# Repository, label, paths
# ---------------------------------------------------------------------------
if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
fi
if [ ! -d "$REPO" ]; then die "--repo is not a directory: $REPO"; fi
REPO="$(cd "$REPO" && pwd -P)"

repo_is_git() { git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

if [ "$MODE" = "run" ] && [ "$IN_PLACE" = 0 ]; then
  repo_is_git || die "a run needs a git repository; $REPO is not one (use --repo <dir>, or --in-place for a plain directory)"
fi

hash8() { python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:8])' "$1"; }
REPO_KEY="$(basename "$REPO")-$(hash8 "$REPO")"

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-60; }
if [ -z "$LABEL" ]; then LABEL="w-$(date +%H%M%S)"; fi
LABEL="$(sanitize "$LABEL")"
[ -n "$LABEL" ] || LABEL="w-$(date +%H%M%S)"
BRANCH="codex/$LABEL"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
STATE_DIR="$OUT_DIR/workers/$REPO_KEY"
STATE_FILE="$STATE_DIR/$LABEL.json"
if [ -z "$WORKTREE" ]; then
  WORKTREE="$OUT_DIR/worktrees/$REPO_KEY/$LABEL"
else
  WORKTREE="$(abs_path "$WORKTREE")"
fi

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

state_get() {
  # state_get <key> -> value as text ("true"/"false" for booleans, "" when absent)
  python3 - "$STATE_FILE" "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}
v = d.get(sys.argv[2], "")
if isinstance(v, bool):
    print("true" if v else "false")
elif isinstance(v, str):
    print(v)
else:
    print(json.dumps(v, ensure_ascii=False))
PY
}

state_set() {
  # state_set key=value ... ; in_place and pre_dirty are stored as booleans
  mkdir -p "$STATE_DIR"
  python3 - "$STATE_FILE" "$@" <<'PY'
import json, os, sys
path = sys.argv[1]
d = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        d = {}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    if k in ("in_place", "pre_dirty"):
        v = (v == "true")
    d[k] = v
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if [ "$MODE" = "list" ]; then
  python3 - "$OUT_DIR" <<'PY'
import glob, json, os, sys
root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, "workers", "*", "*.json")))
if not files:
    print("codex-worker: no workers under %s/workers" % root, file=sys.stderr)
for p in files:
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        print("%s | unreadable state" % p)
        continue
    branch = d.get("branch") or ("(in-place)" if d.get("in_place") else "")
    print(" | ".join(str(x) for x in (
        d.get("label", ""), d.get("status", ""), branch,
        d.get("worktree", ""), d.get("thread_id", ""), d.get("last_run", ""))))
PY
  exit 0
fi

# ---------------------------------------------------------------------------
# --cleanup
# ---------------------------------------------------------------------------
if [ "$MODE" = "cleanup" ]; then
  if [ -f "$STATE_FILE" ]; then
    S_WT="$(state_get worktree)"
    S_BRANCH="$(state_get branch)"
    S_BASE="$(state_get base_sha)"
    S_INPLACE="$(state_get in_place)"
  else
    note "no state file for worker '$LABEL' ($STATE_FILE); using the default worktree path and branch"
    S_WT="$WORKTREE"
    S_BRANCH="$BRANCH"
    S_BASE=""
    S_INPLACE="false"
  fi
  if [ "$S_INPLACE" != "true" ]; then
    repo_is_git || die4 "cleanup needs the git repository the worker was created from; $REPO is not one (use --repo)"
    if [ -n "$S_WT" ] && [ -e "$S_WT" ]; then
      if git -C "$REPO" worktree remove --force "$S_WT" >/dev/null 2>&1; then
        printf 'removed worktree: %s\n' "$S_WT"
      else
        die4 "could not remove worktree $S_WT (git worktree remove --force failed; is it registered in $REPO?)"
      fi
    else
      git -C "$REPO" worktree prune >/dev/null 2>&1 || true
      printf 'worktree already absent: %s\n' "$S_WT"
    fi
    if [ -n "$S_BRANCH" ] && git -C "$REPO" rev-parse --verify --quiet "refs/heads/$S_BRANCH" >/dev/null 2>&1; then
      keep=0
      why=""
      if [ -n "$S_BASE" ]; then
        if [ -n "$(git -C "$REPO" rev-list "$S_BASE..$S_BRANCH" 2>/dev/null)" ]; then
          keep=1
          why="it has commits beyond its base ${S_BASE}"
        fi
      elif ! git -C "$REPO" merge-base --is-ancestor "$S_BRANCH" HEAD >/dev/null 2>&1; then
        keep=1
        why="its base is unknown and it is not an ancestor of HEAD"
      fi
      if [ "$keep" = 1 ]; then
        printf 'kept branch %s: %s; merge or delete it yourself\n' "$S_BRANCH" "$why"
      else
        if git -C "$REPO" branch -D -q "$S_BRANCH" >/dev/null 2>&1; then
          printf 'removed branch: %s\n' "$S_BRANCH"
        else
          die4 "could not delete branch $S_BRANCH"
        fi
      fi
    else
      printf 'branch already absent: %s\n' "$S_BRANCH"
    fi
  fi
  if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    printf 'removed state: %s\n' "$STATE_FILE"
  else
    printf 'state already absent: %s\n' "$STATE_FILE"
  fi
  printf 'kept outputs (patch, json, markdown, log): %s/*-%s.*\n' "$OUT_DIR" "$LABEL"
  exit 0
fi

# ---------------------------------------------------------------------------
# run / resume: validate
# ---------------------------------------------------------------------------
BASE_SHA=""
CWD_FOR_CODEX=""
THREAD_ID=""
PRE_DIRTY="false"
IS_GIT=0
if repo_is_git; then IS_GIT=1; fi

if [ "$MODE" = "resume" ]; then
  [ -f "$STATE_FILE" ] || die "no worker '$LABEL' for $REPO (state file $STATE_FILE not found); run --list to see known workers"
  THREAD_ID="$(state_get thread_id)"
  [ -n "$THREAD_ID" ] || die "worker '$LABEL' has no thread_id recorded (the first run produced no thread); start a new worker instead"
  S_INPLACE="$(state_get in_place)"
  if [ "$S_INPLACE" = "true" ]; then IN_PLACE=1; fi
  WORKTREE="$(state_get worktree)"
  BRANCH="$(state_get branch)"
  BASE_SHA="$(state_get base_sha)"
  if [ "$IN_PLACE" = 1 ]; then
    CWD_FOR_CODEX="$REPO"
    if [ "$IS_GIT" = 1 ]; then BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"; fi
  else
    [ -d "$WORKTREE" ] || die4 "worktree of worker '$LABEL' is missing: $WORKTREE (run --cleanup --label $LABEL and start a new worker)"
    CWD_FOR_CODEX="$WORKTREE"
  fi
else
  if [ "$IN_PLACE" = 1 ]; then
    CWD_FOR_CODEX="$REPO"
    if [ -f "$STATE_FILE" ]; then
      die4 "worker '$LABEL' already exists for $REPO; pick another label or run --cleanup --label $LABEL"
    fi
    if [ "$IS_GIT" = 1 ]; then
      BASE_SHA="$(git -C "$REPO" rev-parse --verify --quiet "HEAD^{commit}" 2>/dev/null || true)"
      [ -n "$BASE_SHA" ] || die "--in-place: $REPO has no commits, nothing to diff against"
      if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
        PRE_DIRTY="true"
        note "warning: $REPO is dirty before the run; the patch will include those changes too (pre_dirty=true)"
      fi
    fi
  else
    CWD_FOR_CODEX="$WORKTREE"
    BASE_SHA="$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}" 2>/dev/null || true)"
    [ -n "$BASE_SHA" ] || die "--base: ref not found in $REPO: $BASE"
    if git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null 2>&1; then
      die4 "branch $BRANCH already exists in $REPO; pick another --label or run --cleanup --label $LABEL"
    fi
    if [ -e "$WORKTREE" ]; then
      die4 "worktree path already exists: $WORKTREE; pick another --label or run --cleanup --label $LABEL"
    fi
    if [ -f "$STATE_FILE" ]; then
      die4 "worker '$LABEL' already has a state file ($STATE_FILE); pick another --label or run --cleanup --label $LABEL"
    fi
  fi
fi

# --context paths: relative to the repo (or absolute); stored relative to the repo when inside it
i=0
while [ $i -lt ${#CONTEXTS[@]} ]; do
  c="${CONTEXTS[$i]}"
  case "$c" in
    /*) abs="$c" ;;
    *)
      abs="$REPO/$c"
      if [ ! -e "$abs" ] && [ -e "$(pwd -P)/$c" ]; then abs="$(pwd -P)/$c"; fi
      ;;
  esac
  [ -e "$abs" ] || die "--context: no such path: $c (looked in $REPO)"
  abs="$(cd "$(dirname "$abs")" && pwd -P)/$(basename "$abs")"
  case "$abs" in
    "$REPO"/*) rel="${abs#"$REPO"/}" ;;
    *) rel="$abs" ;;
  esac
  if [ "$MODE" = "run" ] && [ "$IN_PLACE" = 0 ] && [ "$rel" != "$abs" ]; then
    if ! git -C "$REPO" cat-file -e "$BASE_SHA:$rel" 2>/dev/null; then
      note "warning: --context $rel is not in $BASE ($BASE_SHA); the worktree will not contain it"
    fi
  fi
  CONTEXTS[$i]="$rel"
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Output paths
# ---------------------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE_NAME="$OUT_DIR/$STAMP-$LABEL"
n=1
while [ -e "$BASE_NAME.prompt.md" ]; do
  n=$((n + 1))
  BASE_NAME="$OUT_DIR/$STAMP-$LABEL-$n"
done
PROMPT_FILE="$BASE_NAME.prompt.md"
OUT_JSON="$BASE_NAME.json"
OUT_MD="$BASE_NAME.md"
OUT_PATCH="$BASE_NAME.patch"
OUT_EVENTS="$BASE_NAME.events.jsonl"
OUT_LOG="$BASE_NAME.log"

# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------
write_context_section() {
  if [ ${#CONTEXTS[@]} -gt 0 ]; then
    printf '\n## Read first\n\nBefore editing anything, read these paths (relative to your working directory):\n\n'
    i=0
    while [ $i -lt ${#CONTEXTS[@]} ]; do
      printf -- '- %s\n' "${CONTEXTS[$i]}"
      i=$((i + 1))
    done
  fi
}

write_prompt() {
  {
    printf '# Delegated coding task\n\n'
    if [ "$IN_PLACE" = 1 ]; then
      cat <<EOF
You are a worker executing a task delegated by an orchestrator. You are running
directly inside the user's repository at $CWD_FOR_CODEX (no isolated worktree):
edit carefully, the working tree is the user's own.
EOF
    else
      cat <<EOF
You are a worker executing a task delegated by an orchestrator. You are running
inside an isolated git worktree at $WORKTREE on branch $BRANCH, created from
commit $BASE_SHA. Nothing you do here touches the user's main checkout.
EOF
    fi
    printf '\n## Task\n\n%s\n' "$TASK"
    write_context_section
    cat <<'EOF'

## Rules

- Do the whole task, not a sketch. If something cannot be finished, finish what
  you can and report the rest honestly with status `partial` or `blocked`.
- Read the surrounding code before editing: callers, callees, existing tests,
  project conventions.
- Run the project's relevant tests or linters if they exist and report the
  results under `verification`. If you did not run something, say `not_run`.
- DO NOT run any git command that writes: add, commit, stash, checkout, reset,
  rebase, push, merge, tag. Read-only git (status, diff, log, show, blame) is
  fine. The orchestrator collects your changes from the working tree itself.
- Do not modify files outside this working directory.
- There is no network access unless the task says so. If a dependency is
  missing, do not work around it: report it under `blocked_on`.
- Do not ask questions: make the smallest reasonable assumption and list it
  under `assumptions`.
- Do not leave debug output, temporary files or stray artifacts behind.

## Output

When done, return only JSON matching the provided output schema: status
(done | partial | blocked), summary, changes (every file you touched, with
path, change and note), verification, assumptions, blocked_on (empty string
when nothing blocked you) and notes_for_reviewer. No Markdown fences, no
commentary outside the JSON.
EOF
  } > "$PROMPT_FILE"
}

write_resume_prompt() {
  {
    printf '## Follow-up task\n\n%s\n' "$TASK"
    write_context_section
    if [ "$IN_PLACE" = 1 ]; then
      printf '\nYou are still working directly in %s.' "$CWD_FOR_CODEX"
    else
      printf '\nYou are still in the worktree %s on branch %s.' "$WORKTREE" "$BRANCH"
    fi
    cat <<'EOF'
 The same rules apply: do the whole task, read before editing, run the relevant
tests, do not run any git command that writes (add, commit, stash, checkout,
reset, rebase, push), do not touch files outside the working directory, no
network unless allowed, no questions (list assumptions instead), no stray files.
Return only JSON matching the provided output schema; `changes` lists every
file you touched in this turn.
EOF
  } > "$PROMPT_FILE"
}

if [ "$MODE" = "resume" ]; then write_resume_prompt; else write_prompt; fi
PROMPT_TEXT="$(cat "$PROMPT_FILE")"

# ---------------------------------------------------------------------------
# Command
# ---------------------------------------------------------------------------
# Time limit: prefer GNU `timeout`, then `gtimeout` (Homebrew coreutils on macOS,
# which ships no timeout of its own). With neither present the run proceeds
# without a limit and says so once. The resolved binary is stored once, so the
# resume path and the --dry-run listing use the same one as a normal run.
TIMEOUT_BIN=""
if [ "$TIMEOUT" != "0" ]; then
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
  else
    note "warning: no timeout/gtimeout binary found (install coreutils); running without a time limit"
  fi
fi
CMD=()
if [ -n "$TIMEOUT_BIN" ]; then
  CMD+=("$TIMEOUT_BIN" "$TIMEOUT")
fi
CMD+=(codex exec)
if [ "$MODE" = "resume" ]; then
  # `codex exec resume` (0.153) accepts -c, -m, --json, -o, --output-schema and
  # --skip-git-repo-check but not -s or -C: run it with cwd set to the worktree
  # and re-assert the sandbox via -c, because a resumed thread does not inherit
  # the sandbox it was created with.
  CMD+=(resume "$THREAD_ID")
  CMD+=(-c 'sandbox_mode="workspace-write"' -c 'approval_policy="never"')
  CMD+=(--skip-git-repo-check)
else
  CMD+=(-s workspace-write -c 'sandbox_mode="workspace-write"' -c 'approval_policy="never"')
  CMD+=(--skip-git-repo-check -C "$CWD_FOR_CODEX")
fi
if [ -n "$MODEL" ]; then CMD+=(-m "$MODEL"); fi
CMD+=(-c "model_reasoning_effort=\"$EFFORT\"")
if [ "$NETWORK" = 1 ]; then CMD+=(-c 'sandbox_workspace_write.network_access=true'); fi
if [ "$SEARCH" = 1 ]; then CMD+=(-c 'tools.web_search=true'); fi
CMD+=(--output-schema "$SCHEMA_FILE" --json -o "$OUT_JSON")
CMD+=("$PROMPT_TEXT")

shell_quote() {
  case "$1" in
    ''|*[!A-Za-z0-9_./:=@%+-]*)
      printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

warn_codex_version() {
  # Warn, never fail, when the installed codex looks older than the version
  # this script is tested with (codex-cli 0.153; anything below 0.150.0 warns).
  # `codex --version` prints e.g. "codex-cli 0.153.4". Pure bash 3.2 compare.
  local raw ver major minor shown
  raw="$(codex --version 2>&1)" || true
  raw="${raw%%$'\n'*}"
  ver="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)" || true
  if [ -n "$ver" ]; then
    major="${ver%%.*}"
    minor="${ver#*.}"
    minor="${minor%%.*}"
    if [ "$major" -gt 0 ] || [ "$minor" -ge 150 ]; then return 0; fi
    shown="$ver"
  else
    shown="of unknown version (codex --version said: ${raw:-nothing})"
  fi
  note "warning: codex $shown detected; this script is tested with codex-cli 0.153 and later; continuing"
}

# The version check is cheap and runs even in --dry-run whenever codex is on
# PATH. A missing codex is an error only for a real run (checked further down),
# so --dry-run keeps working on a machine without Codex.
if command -v codex >/dev/null 2>&1; then warn_codex_version; fi

if [ "$DRY_RUN" = 1 ]; then
  printf 'dry-run: codex was not executed, no worktree was created\n'
  printf 'repo: %s\n' "$REPO"
  printf 'label: %s\n' "$LABEL"
  if [ "$IN_PLACE" = 1 ]; then
    printf 'mode: in-place (no worktree)\n'
    printf 'base: %s\n' "$BASE_SHA"
  else
    printf 'base: %s (%s)\n' "$BASE" "$BASE_SHA"
    printf 'worktree: %s\n' "$WORKTREE"
    printf 'branch: %s\n' "$BRANCH"
  fi
  printf 'state: %s\n' "$STATE_FILE"
  printf 'prompt: %s\n' "$PROMPT_FILE"
  if [ "$MODE" = "resume" ]; then printf 'cwd: %s (cd before running; resume takes no -C)\n' "$CWD_FOR_CODEX"; fi
  printf 'command (one argument per line):\n'
  last=$(( ${#CMD[@]} - 1 ))
  i=0
  while [ $i -le $last ]; do
    if [ $i -eq $last ]; then
      printf '"$(cat %s)"\n' "$(shell_quote "$PROMPT_FILE")"
    else
      shell_quote "${CMD[$i]}"
      printf '\n'
    fi
    i=$((i + 1))
  done
  exit 0
fi

command -v codex >/dev/null 2>&1 || { printf 'codex-worker: error: codex CLI not found on PATH (install: npm i -g @openai/codex, or brew install codex)\n' >&2; exit 1; }

# ---------------------------------------------------------------------------
# Worktree and state
# ---------------------------------------------------------------------------
if [ "$MODE" = "run" ] && [ "$IN_PLACE" = 0 ]; then
  mkdir -p "$(dirname "$WORKTREE")"
  if ! git -C "$REPO" worktree add -q -b "$BRANCH" "$WORKTREE" "$BASE_SHA" 2>"$OUT_LOG"; then
    tail -n 5 "$OUT_LOG" >&2 || true
    die4 "git worktree add failed for $WORKTREE (branch $BRANCH); see $OUT_LOG"
  fi
fi

if [ "$MODE" = "run" ]; then
  if [ "$IN_PLACE" = 1 ]; then
    state_set "label=$LABEL" "repo=$REPO" "in_place=true" "worktree=$REPO" "branch=" \
      "base_sha=$BASE_SHA" "thread_id=" "created=$(now_iso)" "last_run=$(now_iso)" \
      "status=running" "last_json=$OUT_JSON" "last_patch=$OUT_PATCH" "pre_dirty=$PRE_DIRTY"
  else
    state_set "label=$LABEL" "repo=$REPO" "in_place=false" "worktree=$WORKTREE" "branch=$BRANCH" \
      "base_sha=$BASE_SHA" "thread_id=" "created=$(now_iso)" "last_run=$(now_iso)" \
      "status=running" "last_json=$OUT_JSON" "last_patch=$OUT_PATCH" "pre_dirty=false"
  fi
else
  state_set "last_run=$(now_iso)" "status=running" "last_json=$OUT_JSON" "last_patch=$OUT_PATCH"
fi

if [ "$MODE" = "resume" ]; then
  note "resuming worker $LABEL, thread $THREAD_ID in $CWD_FOR_CODEX (effort=$EFFORT, timeout=${TIMEOUT}s); outputs: $BASE_NAME.*"
elif [ "$IN_PLACE" = 1 ]; then
  note "running worker $LABEL in-place in $REPO (effort=$EFFORT, timeout=${TIMEOUT}s); outputs: $BASE_NAME.*"
else
  note "running worker $LABEL in $WORKTREE on $BRANCH (effort=$EFFORT, timeout=${TIMEOUT}s); outputs: $BASE_NAME.*"
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
# Codex runs in the background; progress.py follows the events file and prints
# one line per Codex action to stderr (visible live in a terminal or in the
# Background panel of Claude Code). --quiet disables the follower.
PROGRESS_PY="$SCRIPT_DIR/progress.py"
START_EPOCH="$(date +%s)"
set +e
( cd "$CWD_FOR_CODEX" && exec "${CMD[@]}" ) </dev/null >"$OUT_EVENTS" 2>>"$OUT_LOG" &
CODEX_PID=$!
FOLLOW_PID=""
if [ "$QUIET" = 0 ] && [ -f "$PROGRESS_PY" ]; then
  python3 "$PROGRESS_PY" --file "$OUT_EVENTS" --label "$LABEL" --start "$START_EPOCH" --pid "$CODEX_PID" &
  FOLLOW_PID=$!
fi
wait "$CODEX_PID"
CODEX_EXIT=$?
if [ -n "$FOLLOW_PID" ]; then wait "$FOLLOW_PID" 2>/dev/null; fi
set -e

# ---------------------------------------------------------------------------
# Snapshot: working tree against base, taken from outside the sandbox.
# A temporary index (a copy of the real one) is used so the user's own index
# is never touched; untracked files are included, ignored files are not.
# ---------------------------------------------------------------------------
DIFFSTAT=""
snapshot_patch() {
  # snapshot_patch <dir> <base_sha> <patch_file>
  local dir="$1" base="$2" patch="$3" idx real
  : > "$patch"
  DIFFSTAT=""
  idx="$STATE_DIR/.$LABEL.index.tmp"
  rm -f "$idx"
  real="$(git -C "$dir" rev-parse --git-path index 2>/dev/null || true)"
  case "$real" in
    '') ;;
    /*) ;;
    *) real="$dir/$real" ;;
  esac
  if [ -n "$real" ] && [ -f "$real" ]; then cp "$real" "$idx"; fi
  if GIT_INDEX_FILE="$idx" git -C "$dir" add -A 2>>"$OUT_LOG"; then
    if ! GIT_INDEX_FILE="$idx" git -C "$dir" diff --cached --binary "$base" >"$patch" 2>>"$OUT_LOG"; then
      note "warning: git diff failed while snapshotting the patch; see $OUT_LOG"
    fi
    DIFFSTAT="$(GIT_INDEX_FILE="$idx" git -C "$dir" diff --cached --stat "$base" 2>>"$OUT_LOG" || true)"
  else
    note "warning: git add failed while snapshotting; the patch may be incomplete; see $OUT_LOG"
  fi
  rm -f "$idx"
}

HAS_PATCH=0
if [ "$IN_PLACE" = 1 ] && [ "$IS_GIT" = 0 ]; then
  note "$REPO is not a git repository: no patch can be produced in-place"
else
  snapshot_patch "$CWD_FOR_CODEX" "$BASE_SHA" "$OUT_PATCH"
  HAS_PATCH=1
fi

extract_thread_id() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
tid = ""
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if not isinstance(ev, dict):
                continue
            for key in ("thread_id", "threadId"):
                v = ev.get(key)
                if isinstance(v, str) and v:
                    tid = v
                    break
            if tid:
                break
            if "thread" in str(ev.get("type", "")).lower():
                v = ev.get("id")
                if isinstance(v, str) and v:
                    tid = v
                    break
                th = ev.get("thread")
                if isinstance(th, dict) and isinstance(th.get("id"), str) and th["id"]:
                    tid = th["id"]
                    break
except Exception:
    pass
print(tid)
PY
}

if [ "$MODE" = "run" ]; then
  THREAD_ID="$(extract_thread_id "$OUT_EVENTS")"
  if [ -z "$THREAD_ID" ]; then note "warning: no thread_id found in $OUT_EVENTS; --resume will not work for this worker"; fi
fi

render_markdown() {
  # render_markdown <json> <markdown> key=value... ; prints the status; exit 3 if the JSON fails the schema
  CW_DIFFSTAT="$DIFFSTAT" python3 - "$@" <<'PY'
import json, os, re, sys
src, dst = sys.argv[1], sys.argv[2]
meta = {}
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1)
    meta[k] = v
try:
    with open(src, encoding="utf-8") as f:
        raw = f.read()
except Exception as e:
    print("cannot read %s: %s" % (src, e), file=sys.stderr)
    sys.exit(3)
text = raw.strip()
m = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, re.S)
if m:
    text = m.group(1)
try:
    data = json.loads(text)
except Exception as e:
    print("output is not valid JSON: %s" % e, file=sys.stderr)
    sys.exit(3)

def fail(msg):
    print("output failed the schema: %s" % msg, file=sys.stderr)
    sys.exit(3)

STATUS = ("done", "partial", "blocked")
CHANGE = ("added", "modified", "deleted", "renamed")
RESULT = ("passed", "failed", "not_run")
if not isinstance(data, dict):
    fail("top level is not an object")
for k in ("status", "summary", "changes", "verification", "assumptions", "blocked_on", "notes_for_reviewer"):
    if k not in data:
        fail("missing key '%s'" % k)
if data["status"] not in STATUS:
    fail("status must be one of %s" % ", ".join(STATUS))
for k in ("summary", "blocked_on", "notes_for_reviewer"):
    if not isinstance(data[k], str):
        fail("'%s' must be a string" % k)
if not isinstance(data["changes"], list):
    fail("'changes' must be an array")
for i, c in enumerate(data["changes"]):
    if not isinstance(c, dict) or not isinstance(c.get("path"), str) or not isinstance(c.get("note"), str):
        fail("changes[%d] must have string path and note" % i)
    if c.get("change") not in CHANGE:
        fail("changes[%d].change must be one of %s" % (i, ", ".join(CHANGE)))
if not isinstance(data["verification"], list):
    fail("'verification' must be an array")
for i, v in enumerate(data["verification"]):
    if not isinstance(v, dict) or not isinstance(v.get("command"), str) or not isinstance(v.get("note"), str):
        fail("verification[%d] must have string command and note" % i)
    if v.get("result") not in RESULT:
        fail("verification[%d].result must be one of %s" % (i, ", ".join(RESULT)))
if not isinstance(data["assumptions"], list) or not all(isinstance(a, str) for a in data["assumptions"]):
    fail("'assumptions' must be an array of strings")
if text != raw:
    with open(src, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")

def cell(v):
    return str(v).replace("|", "\\|").replace("\n", " ").strip()

diffstat = os.environ.get("CW_DIFFSTAT", "").rstrip()
in_place = meta.get("in_place") == "true"
out = []
out.append("# Codex worker: %s\n" % meta.get("label", ""))
out.append("**Status:** %s  " % data["status"])
if in_place:
    out.append("**Mode:** in-place in %s (HEAD %s)  " % (meta.get("repo", ""), meta.get("base", "")[:12]))
else:
    out.append("**Branch:** %s (from %s)  " % (meta.get("branch", ""), meta.get("base", "")[:12]))
    out.append("**Worktree:** %s  " % meta.get("worktree", ""))
out.append("**Patch:** %s  " % (meta.get("patch", "") or "(none)"))
out.append("**Codex exit:** %s\n" % meta.get("codex_exit", ""))
out.append("## Summary\n")
out.append(data["summary"].strip() + "\n")
out.append("## Diffstat (from git, authoritative)\n")
if diffstat:
    out.append("```")
    out.append(diffstat)
    out.append("```\n")
elif meta.get("patch"):
    out.append("No changes in the working tree against base.\n")
else:
    out.append("Not available: not a git repository.\n")
out.append("## Changes claimed by Codex\n")
if data["changes"]:
    out.append("| Path | Change | Note |")
    out.append("|---|---|---|")
    for c in data["changes"]:
        out.append("| %s | %s | %s |" % (cell(c["path"]), cell(c["change"]), cell(c["note"])))
    out.append("")
else:
    out.append("None claimed.\n")
out.append("## Verification\n")
if data["verification"]:
    out.append("| Command | Result | Note |")
    out.append("|---|---|---|")
    for v in data["verification"]:
        out.append("| %s | %s | %s |" % (cell(v["command"]), cell(v["result"]), cell(v["note"])))
    out.append("")
else:
    out.append("Nothing was run.\n")
out.append("## Assumptions\n")
if data["assumptions"]:
    for a in data["assumptions"]:
        out.append("- %s" % a.strip())
    out.append("")
else:
    out.append("None.\n")
out.append("## Blocked on\n")
out.append((data["blocked_on"].strip() or "Nothing.") + "\n")
out.append("## Notes for reviewer\n")
out.append((data["notes_for_reviewer"].strip() or "None.") + "\n")
out.append("## How to apply\n")
if in_place:
    out.append("Codex edited %s directly; the changes are already in the working tree." % meta.get("repo", ""))
    out.append("The patch is a snapshot of the working tree against HEAD for review%s." % (
        " (it also contains changes that were there before the run: pre_dirty=true)" if meta.get("pre_dirty") == "true" else ""))
    out.append("")
else:
    out.append("Nothing is applied automatically. Review the patch, then in the main repository:\n")
    out.append("    git -C %s apply --check %s" % (meta.get("repo", ""), meta.get("patch", "")))
    out.append("    git -C %s apply --3way %s\n" % (meta.get("repo", ""), meta.get("patch", "")))
    out.append("Alternative: commit inside the worktree and merge branch %s." % meta.get("branch", ""))
    out.append("Afterwards: codex-worker.sh --cleanup --label %s\n" % meta.get("label", ""))
with open(dst, "w", encoding="utf-8") as f:
    f.write("\n".join(out))
print(data["status"])
PY
}

STATUS="unknown"
MD_OK=0
if [ -s "$OUT_JSON" ]; then
  set +e
  STATUS_OUT="$(render_markdown "$OUT_JSON" "$OUT_MD" "label=$LABEL" "repo=$REPO" "branch=$BRANCH" \
    "worktree=$WORKTREE" "base=$BASE_SHA" "patch=$([ "$HAS_PATCH" = 1 ] && printf '%s' "$OUT_PATCH")" \
    "in_place=$([ "$IN_PLACE" = 1 ] && printf true || printf false)" "pre_dirty=$PRE_DIRTY" "codex_exit=$CODEX_EXIT")"
  RENDER_EXIT=$?
  set -e
  if [ "$RENDER_EXIT" -eq 0 ]; then
    STATUS="$STATUS_OUT"
    MD_OK=1
  fi
fi

state_set "thread_id=$THREAD_ID" "last_run=$(now_iso)" "status=$STATUS" "last_json=$OUT_JSON" \
  "last_patch=$([ "$HAS_PATCH" = 1 ] && printf '%s' "$OUT_PATCH")"

print_header() {
  printf 'json: %s\n' "$OUT_JSON"
  printf 'markdown: %s\n' "$([ "$MD_OK" = 1 ] && printf '%s' "$OUT_MD")"
  printf 'patch: %s\n' "$([ "$HAS_PATCH" = 1 ] && printf '%s' "$OUT_PATCH")"
  printf 'worktree: %s\n' "$CWD_FOR_CODEX"
  printf 'branch: %s\n' "$([ "$IN_PLACE" = 1 ] || printf '%s' "$BRANCH")"
  printf 'base: %s\n' "$BASE_SHA"
  printf 'events: %s\n' "$OUT_EVENTS"
  printf 'log: %s\n' "$OUT_LOG"
  printf 'prompt: %s\n' "$PROMPT_FILE"
  printf 'thread_id: %s\n' "$THREAD_ID"
  printf 'exit: %s\n' "$CODEX_EXIT"
  printf '\n'
}

print_header

if [ "$CODEX_EXIT" -ne 0 ]; then
  note "codex exited with $CODEX_EXIT; see $OUT_LOG (the patch was snapshotted anyway)"
  tail -n 20 "$OUT_LOG" >&2 || true
  exit "$CODEX_EXIT"
fi

if [ ! -s "$OUT_JSON" ]; then
  note "codex produced no final message (expected $OUT_JSON); see $OUT_LOG"
  exit 3
fi

if [ "$MD_OK" = 0 ]; then
  note "output failed the schema check; raw output: $OUT_JSON"
  exit 3
fi

cat "$OUT_JSON"
if [ -n "$(tail -c 1 "$OUT_JSON")" ]; then printf '\n'; fi
exit 0
