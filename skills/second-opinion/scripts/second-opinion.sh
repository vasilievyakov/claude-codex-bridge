#!/bin/bash
# second-opinion.sh -- ask OpenAI Codex CLI for an independent, read-only review.
#
# Runs `codex exec` with fixed safe flags (read-only sandbox, no approvals,
# no writes) and returns schema-constrained findings. Never modifies the repo.
# Compatible with bash 3.2 (macOS /bin/bash). Requires python3; jq not needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SCHEMA_FILE="$SCRIPT_DIR/findings.schema.json"

usage() {
  cat <<'EOF'
Usage: second-opinion.sh [scope] [options]

Scope (exactly one; default --uncommitted):
  --uncommitted          review the working tree: unstaged, staged and untracked changes
  --base <branch>        review commits since <branch> (git diff <branch>...HEAD)
  --commit <sha>         review a single commit (git show <sha>)
  --file <path>          review the given file(s) in full; repeatable
  --plan <path>          review a plan or design document, not code

Options:
  --repo <dir>           repository root (default: git toplevel of cwd, else cwd)
  --focus "<text>"       extra focus for the reviewer (the whole prompt in --resume mode)
  --label <name>         label used in output filenames (default: derived from scope)
  --model <m>            Codex model (default: whatever Codex config says)
  --effort <level>       low | medium | high | xhigh (default: high)
  --search               allow web search (tools.web_search=true)
  --no-schema            prose output instead of schema-constrained JSON
  --out-dir <dir>        where to write outputs (default: ${XDG_CACHE_HOME:-~/.cache}/second-opinion)
  --timeout <sec>        kill codex after <sec> seconds (default: 900; 0 disables)
  --resume <thread-id>   continue a previous review thread; --focus is the message (required)
  --dry-run              print the composed command and the prompt path; do not run codex
  --quiet                do not print live progress lines ([codex <label> mm:ss] ...) to stderr
  -h, --help             show this help

Stdout on completion: json:, markdown:, events:, log:, prompt:, thread_id:, exit: lines,
a blank line, then the review body. Exit code: 0 ok, 2 bad arguments, 3 output failed
the schema check, otherwise the codex exit code.
EOF
}

die() { printf 'second-opinion: error: %s\n' "$*" >&2; exit 2; }
note() { printf 'second-opinion: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
SCOPE=""
BASE=""
COMMIT=""
PLAN=""
FILES=()
REPO=""
FOCUS=""
LABEL=""
MODEL=""
EFFORT="high"
SEARCH=0
NO_SCHEMA=0
OUT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/second-opinion"
TIMEOUT=900
RESUME=""
DRY_RUN=0
QUIET=0

set_scope() {
  if [ -n "$SCOPE" ] && [ "$SCOPE" != "$1" ]; then
    die "only one scope allowed, got --$SCOPE and --$1"
  fi
  SCOPE="$1"
}

need_val() {
  # need_val <flag> <remaining-arg-count>
  if [ "$2" -lt 2 ]; then die "$1 requires a value"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --uncommitted) set_scope uncommitted; shift ;;
    --base) need_val "$1" $#; set_scope base; BASE="$2"; shift 2 ;;
    --commit) need_val "$1" $#; set_scope commit; COMMIT="$2"; shift 2 ;;
    --file) need_val "$1" $#; set_scope file; FILES+=("$2"); shift 2 ;;
    --plan) need_val "$1" $#; set_scope plan; PLAN="$2"; shift 2 ;;
    --repo) need_val "$1" $#; REPO="$2"; shift 2 ;;
    --focus) need_val "$1" $#; FOCUS="$2"; shift 2 ;;
    --label) need_val "$1" $#; LABEL="$2"; shift 2 ;;
    --model) need_val "$1" $#; MODEL="$2"; shift 2 ;;
    --effort) need_val "$1" $#; EFFORT="$2"; shift 2 ;;
    --search) SEARCH=1; shift ;;
    --no-schema) NO_SCHEMA=1; shift ;;
    --out-dir) need_val "$1" $#; OUT_DIR="$2"; shift 2 ;;
    --timeout) need_val "$1" $#; TIMEOUT="$2"; shift 2 ;;
    --resume) need_val "$1" $#; RESUME="$2"; shift 2 ;;
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

if [ -n "$RESUME" ]; then
  if [ -n "$SCOPE" ]; then die "--resume continues an existing thread; do not combine it with a scope flag (--$SCOPE)"; fi
  if [ -z "$FOCUS" ]; then die "--resume requires --focus \"<message to the reviewer>\""; fi
fi
if [ -z "$SCOPE" ]; then SCOPE="uncommitted"; fi

# ---------------------------------------------------------------------------
# Repository
# ---------------------------------------------------------------------------
if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
fi
if [ ! -d "$REPO" ]; then die "--repo is not a directory: $REPO"; fi
REPO="$(cd "$REPO" && pwd -P)"

repo_is_git() { git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

abs_path() {
  # abs_path <path> -> absolute path. Relative paths resolve against the repo
  # root first (so --repo X --file y works from any cwd), then against cwd.
  # The leaf does not have to exist.
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)
      if [ -e "$REPO/$1" ] || [ ! -e "$(pwd -P)/$1" ]; then
        printf '%s/%s\n' "$REPO" "$1"
      else
        printf '%s/%s\n' "$(pwd -P)" "$1"
      fi
      ;;
  esac
}

if [ -z "$RESUME" ]; then
  case "$SCOPE" in
    uncommitted|base|commit)
      repo_is_git || die "scope --$SCOPE needs a git repository; $REPO is not one (use --repo or --file/--plan)"
      ;;
  esac
  case "$SCOPE" in
    base)
      git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 \
        || die "--base: ref not found in $REPO: $BASE"
      ;;
    commit)
      git -C "$REPO" rev-parse --verify --quiet "$COMMIT^{commit}" >/dev/null 2>&1 \
        || die "--commit: commit not found in $REPO: $COMMIT"
      ;;
    file)
      i=0
      while [ $i -lt ${#FILES[@]} ]; do
        p="$(abs_path "${FILES[$i]}")"
        [ -e "$p" ] || die "--file: no such path: ${FILES[$i]} (looked in $REPO and $(pwd -P))"
        FILES[$i]="$p"
        i=$((i + 1))
      done
      ;;
    plan)
      PLAN="$(abs_path "$PLAN")"
      [ -f "$PLAN" ] || die "--plan: no such file: $PLAN"
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Output paths
# ---------------------------------------------------------------------------
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-60; }

if [ -z "$LABEL" ]; then
  if [ -n "$RESUME" ]; then
    LABEL="resume-$RESUME"
  else
    case "$SCOPE" in
      uncommitted) LABEL="uncommitted" ;;
      base) LABEL="base-$BASE" ;;
      commit) LABEL="commit-$(git -C "$REPO" rev-parse --short "$COMMIT" 2>/dev/null || printf '%s' "$COMMIT")" ;;
      file) LABEL="file-$(basename "${FILES[0]}")" ;;
      plan) LABEL="plan-$(basename "$PLAN")" ;;
    esac
  fi
fi
LABEL="$(sanitize "$LABEL")"
[ -n "$LABEL" ] || LABEL="review"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
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
OUT_EVENTS="$BASE_NAME.events.jsonl"
OUT_LOG="$BASE_NAME.log"
OUT_ANSWER="$BASE_NAME.answer.txt"

# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------
write_prompt() {
  {
    cat <<EOF
# Independent second-opinion review

You are an independent reviewer. The author of the change under review is a
different AI model, and you are being asked precisely because you are not it.
Default to skepticism: assume the change may be wrong until you have checked it
against the actual code. Do not rubber-stamp. Do not praise. Do not summarize
what the change does except where needed to explain a finding. Prefer a few
verified findings over a long list of guesses. If you looked carefully and
found nothing, say so plainly and describe what you checked.

You are running inside the repository at: $REPO
Your sandbox is read-only. Use it for reading and for read-only git commands.

## Scope

EOF
    case "$SCOPE" in
      uncommitted)
        cat <<'EOF'
Review the uncommitted changes in the working tree. Run these read-only git
commands yourself and review everything they show:

- `git status --porcelain`
- `git diff`
- `git diff --cached`
- `git ls-files --others --exclude-standard` to list untracked files, then read
  each untracked file in full.

Read the changed hunks in the context of the surrounding code: open the touched
files, follow callers and callees where the change could break them.
EOF
        ;;
      base)
        cat <<EOF
Review all commits on the current branch since it diverged from \`$BASE\`.
Run these read-only git commands yourself:

- \`git log --oneline $BASE..HEAD\`
- \`git diff $BASE...HEAD\`

Read the changed hunks in the context of the surrounding code: open the touched
files, follow callers and callees where the change could break them.
EOF
        ;;
      commit)
        cat <<EOF
Review the single commit \`$COMMIT\`. Run \`git show $COMMIT\` yourself and read
the changed hunks in the context of the surrounding code at that commit.
EOF
        ;;
      file)
        printf 'Review the following files in full (no git diff is involved):\n\n'
        i=0
        while [ $i -lt ${#FILES[@]} ]; do
          printf -- '- %s\n' "${FILES[$i]}"
          i=$((i + 1))
        done
        printf '\nRead the files, then follow their callers, callees and tests inside the\nrepository as needed to judge correctness.\n'
        ;;
      plan)
        cat <<EOF
This is a plan review, not a code review. Read the plan document in full:

- $PLAN

Review it as a plan: correctness gaps, unstated assumptions, risky or
out-of-order steps, missing edge cases, simpler alternatives that achieve the
same goal. You may read the repository to check whether the plan's assumptions
about the existing code hold. For a plan, "location" means the step or section
of the document.
EOF
        ;;
    esac
    if [ -n "$FOCUS" ]; then
      printf '\n## Focus requested by the author\n\n%s\n' "$FOCUS"
    fi
    cat <<'EOF'

## What counts as a finding

- A concrete failure scenario: which inputs or state lead to which wrong
  outcome. "Could be cleaner" is not a finding unless it has a consequence.
- A location: file:line or function (for a plan: step or section). Do not
  invent line numbers; quote or describe what you actually read.
- Severity: P1 = data loss, security, wrong results; P2 = a bug likely to be hit
  in normal use; P3 = quality, maintainability, missing tests.
- Confidence: high, medium or low, honestly.
- Evidence: what you read that supports the claim (the line, the code path, the
  command output).

Rules:

- Explicitly report what you could not verify in `coverage`. If the core of
  the change was not inspectable, set verdict to `could_not_verify`.
- Do not modify anything: no edits, no new files, no commands that write to
  disk, no builds or test runs that produce artifacts.
- Do not propose patches longer than one sentence. The author decides what
  to change.
- Zero findings is an acceptable result if you looked and found nothing.

## Output

EOF
    if [ "$NO_SCHEMA" = 1 ]; then
      cat <<'EOF'
Return Markdown with these sections, in this order: Summary; Verdict (one of
approve, needs_changes, could_not_verify); Coverage (what was inspected and what
was not); Findings. For each finding give: severity (P1/P2/P3), title,
location, claim, failure_scenario, evidence, confidence (high/medium/low).
EOF
    else
      cat <<'EOF'
Return only JSON matching the provided output schema: an object with summary,
verdict, coverage and a findings array whose items have severity, title,
location, claim, failure_scenario, evidence and confidence. No Markdown fences,
no commentary outside the JSON.
EOF
    fi
  } > "$PROMPT_FILE"
}

if [ -n "$RESUME" ]; then
  printf '%s\n' "$FOCUS" > "$PROMPT_FILE"
else
  write_prompt
fi
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
if [ -n "$RESUME" ]; then
  # `codex exec resume` (0.153) accepts -m, --json, -o, --skip-git-repo-check but
  # not -s or -C: run it from inside the repo and re-assert the sandbox via -c,
  # because a resumed thread does not inherit the sandbox it was created with.
  CMD+=(resume "$RESUME")
  CMD+=(-c 'sandbox_mode="read-only"' -c 'approval_policy="never"')
  CMD+=(--skip-git-repo-check)
  if [ -n "$MODEL" ]; then CMD+=(-m "$MODEL"); fi
  CMD+=(-c "model_reasoning_effort=\"$EFFORT\"")
  if [ "$SEARCH" = 1 ]; then CMD+=(-c 'tools.web_search=true'); fi
  CMD+=(--json -o "$OUT_ANSWER")
else
  CMD+=(-s read-only -c 'sandbox_mode="read-only"' -c 'approval_policy="never"')
  CMD+=(--skip-git-repo-check -C "$REPO")
  if [ -n "$MODEL" ]; then CMD+=(-m "$MODEL"); fi
  CMD+=(-c "model_reasoning_effort=\"$EFFORT\"")
  if [ "$SEARCH" = 1 ]; then CMD+=(-c 'tools.web_search=true'); fi
  if [ "$NO_SCHEMA" = 1 ]; then
    CMD+=(--json -o "$OUT_MD")
  else
    CMD+=(--output-schema "$SCHEMA_FILE" --json -o "$OUT_JSON")
  fi
fi
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
  printf 'dry-run: codex was not executed\n'
  printf 'repo: %s\n' "$REPO"
  printf 'prompt: %s\n' "$PROMPT_FILE"
  if [ -n "$RESUME" ]; then printf 'cwd: %s (cd before running; resume takes no -C)\n' "$REPO"; fi
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

command -v codex >/dev/null 2>&1 || { printf 'second-opinion: error: codex CLI not found on PATH (install: npm i -g @openai/codex, or brew install codex)\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'second-opinion: error: python3 not found on PATH\n' >&2; exit 1; }

if [ -n "$RESUME" ]; then
  note "resuming thread $RESUME (effort=$EFFORT, timeout=${TIMEOUT}s); outputs: $BASE_NAME.*"
else
  note "running codex exec (scope=$SCOPE, effort=$EFFORT, timeout=${TIMEOUT}s); outputs: $BASE_NAME.*"
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
if [ -n "$RESUME" ]; then
  ( cd "$REPO" && exec "${CMD[@]}" ) </dev/null >"$OUT_EVENTS" 2>"$OUT_LOG" &
else
  "${CMD[@]}" </dev/null >"$OUT_EVENTS" 2>"$OUT_LOG" &
fi
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

render_markdown() {
  # render_markdown <json> <markdown> ; exit 3 if the JSON is unusable
  python3 - "$1" "$2" <<'PY'
import json, re, sys
src, dst = sys.argv[1], sys.argv[2]
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
if not isinstance(data, dict) or not isinstance(data.get("findings"), list):
    print("output JSON has no 'findings' array", file=sys.stderr)
    sys.exit(3)
if text != raw:
    with open(src, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")

def s(v):
    return v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)

def cell(v):
    return s(v).replace("|", "\\|").replace("\n", " ").strip()

order = {"P1": 0, "P2": 1, "P3": 2}
findings = [f for f in data["findings"] if isinstance(f, dict)]
findings.sort(key=lambda f: order.get(str(f.get("severity", "")), 9))

out = []
out.append("# Second opinion (Codex)\n")
out.append("**Verdict:** %s  " % s(data.get("verdict", "")))
out.append("**Findings:** %d\n" % len(findings))
out.append("## Summary\n")
out.append(s(data.get("summary", "")).strip() + "\n")
out.append("## Coverage\n")
out.append(s(data.get("coverage", "")).strip() + "\n")
out.append("## Findings\n")
if not findings:
    out.append("No findings reported.\n")
else:
    out.append("| # | Severity | Title | Location | Confidence |")
    out.append("|---|---|---|---|---|")
    for i, f in enumerate(findings, 1):
        out.append("| %d | %s | %s | %s | %s |" % (
            i, cell(f.get("severity", "")), cell(f.get("title", "")),
            cell(f.get("location", "")), cell(f.get("confidence", ""))))
    out.append("")
    for i, f in enumerate(findings, 1):
        out.append("### %d. [%s] %s\n" % (i, s(f.get("severity", "")), s(f.get("title", "")).strip()))
        out.append("- Location: %s" % s(f.get("location", "")).strip())
        out.append("- Confidence: %s\n" % s(f.get("confidence", "")).strip())
        out.append("**Claim:** %s\n" % s(f.get("claim", "")).strip())
        out.append("**Failure scenario:** %s\n" % s(f.get("failure_scenario", "")).strip())
        out.append("**Evidence:** %s\n" % s(f.get("evidence", "")).strip())
with open(dst, "w", encoding="utf-8") as f:
    f.write("\n".join(out))
PY
}

print_header() {
  printf 'json: %s\n' "$1"
  printf 'markdown: %s\n' "$2"
  printf 'events: %s\n' "$3"
  printf 'log: %s\n' "$OUT_LOG"
  printf 'prompt: %s\n' "$PROMPT_FILE"
  printf 'thread_id: %s\n' "$THREAD_ID"
  printf 'exit: %s\n' "$CODEX_EXIT"
  printf '\n'
}

if [ -n "$RESUME" ]; then
  THREAD_ID="$RESUME"
  print_header "" "$OUT_ANSWER" "$OUT_EVENTS"
  if [ "$CODEX_EXIT" -ne 0 ]; then
    note "codex exited with $CODEX_EXIT; see $OUT_LOG"
    tail -n 20 "$OUT_LOG" >&2 || true
    exit "$CODEX_EXIT"
  fi
  if [ -f "$OUT_ANSWER" ]; then cat "$OUT_ANSWER"; else note "codex produced no final message (expected $OUT_ANSWER)"; fi
  exit 0
fi

THREAD_ID="$(extract_thread_id "$OUT_EVENTS")"

if [ "$CODEX_EXIT" -ne 0 ]; then
  if [ "$NO_SCHEMA" = 1 ]; then
    print_header "" "$OUT_MD" "$OUT_EVENTS"
  else
    print_header "$OUT_JSON" "$OUT_MD" "$OUT_EVENTS"
  fi
  note "codex exited with $CODEX_EXIT; see $OUT_LOG"
  tail -n 20 "$OUT_LOG" >&2 || true
  exit "$CODEX_EXIT"
fi

if [ "$NO_SCHEMA" = 1 ]; then
  print_header "" "$OUT_MD" "$OUT_EVENTS"
  if [ -f "$OUT_MD" ]; then cat "$OUT_MD"; else note "codex produced no final message (expected $OUT_MD)"; fi
  exit 0
fi

if [ ! -s "$OUT_JSON" ]; then
  print_header "$OUT_JSON" "" "$OUT_EVENTS"
  note "codex produced no final message (expected $OUT_JSON); see $OUT_LOG"
  exit 3
fi

set +e
render_markdown "$OUT_JSON" "$OUT_MD"
RENDER_EXIT=$?
set -e
if [ "$RENDER_EXIT" -ne 0 ]; then
  print_header "$OUT_JSON" "" "$OUT_EVENTS"
  note "output failed the schema check; raw output: $OUT_JSON"
  exit 3
fi

print_header "$OUT_JSON" "$OUT_MD" "$OUT_EVENTS"
cat "$OUT_JSON"
if [ -n "$(tail -c 1 "$OUT_JSON")" ]; then printf '\n'; fi
exit 0
