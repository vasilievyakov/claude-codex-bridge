#!/bin/bash
# Test suite for scripts/codex-worker.sh.
# Uses a fake `codex` placed first on PATH; the real Codex CLI is never called.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$SKILL_DIR/scripts/codex-worker.sh"
SCHEMA="$SKILL_DIR/scripts/result.schema.json"

# Temp root: $CODEX_WORKER_TEST_TMPDIR when set, else $TMPDIR (or /tmp).
SCRATCH="${CODEX_WORKER_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$SCRATCH"
TMP="$(mktemp -d "$SCRATCH/codex-worker-tests.XXXXXX")"
# Canonical path: on macOS $TMPDIR lives under /var, a symlink to /private/var,
# and the scripts print physical paths (pwd -P).
TMP="$(cd "$TMP" && pwd -P)"

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

# assert_contains <name> <haystack> <needle>
assert_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1 (expected to contain: $3)" ;;
  esac
}
assert_not_contains() {
  case "$2" in
    *"$3"*) fail "$1 (expected NOT to contain: $3)" ;;
    *) pass "$1" ;;
  esac
}
# assert_line <name> <file> <exact line>
assert_line() {
  if grep -qxF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1 (no line '$3' in $2)"; fi
}
assert_no_line() {
  if grep -qxF -- "$3" "$2" 2>/dev/null; then fail "$1 (unexpected line '$3' in $2)"; else pass "$1"; fi
}
assert_file_contains() {
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (file $2 lacks: $3)"; fi
}
assert_exists() { if [ -e "$2" ]; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
assert_absent() { if [ -e "$2" ]; then fail "$1 (should not exist: $2)"; else pass "$1"; fi; }
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then pass "$1"; else fail "$1 (got '$2', expected anything else)"; fi
}
line_value() { # line_value <stdout> <key>  -> value of "key: value"
  printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1
}
json_get() { # json_get <file> <key> -> value as text (True/False for booleans)
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null
}
branch_exists() { git -C "$REPO" rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1; }

# --- fake codex -------------------------------------------------------------
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/codex" <<'FAKE'
#!/bin/bash
# Fake codex: records argv and cwd, drains stdin, simulates edits in the work dir,
# writes canned output, never touches the network.
# `codex --version` is answered first and records nothing: the version probe is
# not a run. FAKE_CODEX_VERSION overrides the reported version.
if [ "${1:-}" = "--version" ]; then printf 'codex-cli %s\n' "${FAKE_CODEX_VERSION:-0.153.4}"; exit 0; fi
: "${FAKE_CODEX_ARGS:?FAKE_CODEX_ARGS must be set}"
printf '%s\n' "$@" > "$FAKE_CODEX_ARGS"
if [ -n "${FAKE_CODEX_PWD:-}" ]; then pwd -P > "$FAKE_CODEX_PWD"; fi
cat > /dev/null
out=""
schema=0
work="$(pwd -P)"
prev=""
for a in "$@"; do
  case "$prev" in
    -o|--output-last-message) out="$a" ;;
    -C) work="$a" ;;
  esac
  if [ "$a" = "--output-schema" ]; then schema=1; fi
  prev="$a"
done
if [ "${FAKE_CODEX_NOOP:-0}" != 1 ]; then
  printf 'line added by fake codex\n' >> "$work/a.txt"
  printf 'output from fake codex\n' > "$work/worker-output.txt"
fi
if [ -n "$out" ]; then
  if [ "$schema" = 1 ]; then
    cat > "$out" <<'JSON'
{"status":"done","summary":"Appended a greeting line to a.txt and wrote worker-output.txt.","changes":[{"path":"a.txt","change":"modified","note":"appended one line"}],"verification":[{"command":"python3 -m pytest","result":"not_run","note":"no tests in the repository"}],"assumptions":["The greeting text was not specified; used a placeholder."],"blocked_on":"","notes_for_reviewer":"Nothing special."}
JSON
  else
    printf '# Result\n\nProse from fake codex.\n' > "$out"
  fi
fi
printf '%s\n' '{"type":"thread.started","thread_id":"thr_test_123"}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
exit "${FAKE_CODEX_EXIT:-0}"
FAKE
chmod +x "$BIN/codex"
export PATH="$BIN:$PATH"

# --- temp git repo ----------------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO/src"
git -C "$REPO" init -q
git -C "$REPO" symbolic-ref HEAD refs/heads/main
GIT="git -C $REPO -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false"
printf 'alpha\n' > "$REPO/a.txt"
printf 'def util():\n    return 1\n' > "$REPO/src/util.py"
$GIT add a.txt src/util.py
$GIT commit -qm "init"
REPO="$(cd "$REPO" && pwd -P)"
REPO_KEY="$(basename "$REPO")-$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:8])' "$REPO")"

OUT="$TMP/out"
mkdir -p "$OUT"
WT_DIR="$OUT/worktrees/$REPO_KEY"
ST_DIR="$OUT/workers/$REPO_KEY"

# --- prerequisites ----------------------------------------------------------
if [ -x "$SCRIPT" ]; then pass "script is executable"; else fail "script is executable: $SCRIPT"; fi
if bash -n "$SCRIPT" 2>/dev/null; then pass "bash -n script"; else fail "bash -n script"; fi
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SCHEMA" 2>/dev/null; then pass "schema is valid JSON"; else fail "schema is valid JSON"; fi
if python3 - "$SCHEMA" <<'PY' 2>/dev/null
import json, sys
def walk(node):
    if isinstance(node, dict):
        if node.get("type") == "object":
            props = node.get("properties", {})
            assert node.get("additionalProperties") is False, "additionalProperties must be false"
            assert sorted(node.get("required", [])) == sorted(props.keys()), "all properties must be required"
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)
walk(json.load(open(sys.argv[1])))
PY
then pass "schema is structured-outputs compatible"; else fail "schema is structured-outputs compatible"; fi
if [ "$(command -v codex)" = "$BIN/codex" ]; then pass "fake codex is first on PATH"; else fail "fake codex is first on PATH ($(command -v codex))"; fi

# --- a. dry-run --------------------------------------------------------------
ARGS="$TMP/a.args"
rm -f "$ARGS"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --dry-run --task "t" --label d1 --out-dir "$OUT" 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/a.out"
assert_eq "a: dry-run exit 0" "$rc" "0"
assert_line "a: argv -s" "$TMP/a.out" "-s"
assert_line "a: argv workspace-write" "$TMP/a.out" "workspace-write"
assert_contains "a: sandbox_mode override" "$out" 'sandbox_mode="workspace-write"'
assert_contains "a: approval_policy never" "$out" 'approval_policy="never"'
assert_line "a: argv --skip-git-repo-check" "$TMP/a.out" "--skip-git-repo-check"
assert_line "a: argv -C" "$TMP/a.out" "-C"
cline="$(grep -A1 -x -- '-C' "$TMP/a.out" | tail -1)"
assert_eq "a: -C points at the planned worktree" "$cline" "$WT_DIR/d1"
assert_line "a: argv --output-schema" "$TMP/a.out" "--output-schema"
assert_line "a: argv --json" "$TMP/a.out" "--json"
assert_line "a: argv -o" "$TMP/a.out" "-o"
assert_contains "a: effort high" "$out" 'model_reasoning_effort="high"'
assert_not_contains "a: no --ephemeral" "$out" "--ephemeral"
assert_not_contains "a: no network_access" "$out" "network_access"
assert_contains "a: repo printed" "$out" "repo: $REPO"
assert_contains "a: label printed" "$out" "label: d1"
assert_contains "a: base printed" "$out" "base: "
assert_contains "a: worktree printed" "$out" "worktree: $WT_DIR/d1"
assert_absent "a: no worktree created" "$WT_DIR/d1"
if branch_exists codex/d1; then fail "a: no branch created"; else pass "a: no branch created"; fi
if [ -e "$ARGS" ]; then fail "a: codex not run in dry-run"; else pass "a: codex not run in dry-run"; fi
pfile="$(line_value "$out" prompt)"
assert_file_contains "a: prompt has task text" "$pfile" "t"
assert_file_contains "a: prompt names the branch" "$pfile" "codex/d1"

# --- b. full run --------------------------------------------------------------
ARGS="$TMP/b.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --task "add greeting" --label w1 --context src/util.py --out-dir "$OUT" 2>"$TMP/b.stderr")"
rc=$?
assert_eq "b: exit 0" "$rc" "0"
WT_W1="$WT_DIR/w1"
STATE_W1="$ST_DIR/w1.json"
assert_exists "b: worktree exists at expected path" "$WT_W1/.git"
if branch_exists codex/w1; then pass "b: branch codex/w1 exists"; else fail "b: branch codex/w1 exists"; fi
assert_eq "b: main repo untouched" "$(git -C "$REPO" status --porcelain)" ""
B_PATCH="$(line_value "$out" patch)"
B_JSON="$(line_value "$out" json)"
B_MD="$(line_value "$out" markdown)"
if [ -s "$B_PATCH" ]; then pass "b: patch file exists and is non-empty"; else fail "b: patch file exists and is non-empty ($B_PATCH)"; fi
assert_file_contains "b: patch has worker-output.txt" "$B_PATCH" "worker-output.txt"
assert_file_contains "b: patch has a.txt change" "$B_PATCH" "+line added by fake codex"
assert_eq "b: json status parsed" "$(json_get "$B_JSON" status)" "done"
assert_exists "b: markdown exists" "$B_MD"
assert_file_contains "b: markdown has diffstat file" "$B_MD" "worker-output.txt"
assert_file_contains "b: markdown has diffstat summary" "$B_MD" "insertion"
assert_file_contains "b: markdown has apply hint" "$B_MD" "apply --3way"
assert_exists "b: state file exists" "$STATE_W1"
assert_eq "b: state thread_id" "$(json_get "$STATE_W1" thread_id)" "thr_test_123"
assert_eq "b: state status" "$(json_get "$STATE_W1" status)" "done"
assert_eq "b: state branch" "$(json_get "$STATE_W1" branch)" "codex/w1"
assert_eq "b: state worktree" "$(json_get "$STATE_W1" worktree)" "$WT_W1"
for key in json markdown patch worktree branch base events log prompt thread_id exit; do
  assert_contains "b: header line $key:" "
$out" "
$key: "
done
assert_contains "b: header branch value" "$out" "branch: codex/w1"
assert_contains "b: header worktree value" "$out" "worktree: $WT_W1"
assert_contains "b: header thread_id value" "$out" "thread_id: thr_test_123"
assert_contains "b: header exit value" "$out" "exit: 0"
assert_contains "b: header base is sha" "$out" "base: $(git -C "$REPO" rev-parse HEAD)"
assert_contains "b: stdout ends with json body" "$out" '"status": "done"'
pfile="$(line_value "$out" prompt)"
assert_file_contains "b: prompt lists context" "$pfile" "src/util.py"
assert_file_contains "b: prompt has task text" "$pfile" "add greeting"
assert_file_contains "b: prompt forbids git writes" "$pfile" "git command that writes"
assert_file_contains "b: prompt names worktree" "$pfile" "$WT_W1"
cline="$(grep -A1 -x -- '-C' "$ARGS" | tail -1)"
assert_eq "b: argv -C <worktree>" "$cline" "$WT_W1"
assert_line "b: argv -s" "$ARGS" "-s"
assert_line "b: argv workspace-write" "$ARGS" "workspace-write"
assert_line "b: argv --output-schema" "$ARGS" "--output-schema"
assert_no_line "b: argv no --ephemeral" "$ARGS" "--ephemeral"
assert_no_line "b: argv no -m by default" "$ARGS" "-m"

# --- c. resume ----------------------------------------------------------------
prev_run="$(json_get "$STATE_W1" last_run)"
prev_json="$(json_get "$STATE_W1" last_json)"
sleep 1
ARGS="$TMP/c.args"
PWDF="$TMP/c.pwd"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" FAKE_CODEX_PWD="$PWDF" bash "$SCRIPT" --resume --label w1 --task "also fix docs" --out-dir "$OUT" 2>"$TMP/c.stderr")"
rc=$?
assert_eq "c: exit 0" "$rc" "0"
head3="$(head -3 "$ARGS" | tr '\n' ' ')"
assert_eq "c: argv starts with exec resume thr_test_123" "$head3" "exec resume thr_test_123 "
assert_line "c: argv sandbox override" "$ARGS" 'sandbox_mode="workspace-write"'
assert_line "c: argv approval never" "$ARGS" 'approval_policy="never"'
assert_line "c: argv --json" "$ARGS" "--json"
assert_line "c: argv -o" "$ARGS" "-o"
assert_line "c: argv --output-schema" "$ARGS" "--output-schema"
assert_no_line "c: argv no -C" "$ARGS" "-C"
assert_no_line "c: argv no -s" "$ARGS" "-s"
assert_eq "c: fake pwd is the worktree" "$(cat "$PWDF" 2>/dev/null)" "$WT_W1"
C_PATCH="$(line_value "$out" patch)"
if [ -s "$C_PATCH" ]; then pass "c: patch present"; else fail "c: patch present ($C_PATCH)"; fi
assert_file_contains "c: patch cumulative (worker-output.txt)" "$C_PATCH" "worker-output.txt"
assert_eq "c: patch cumulative (two a.txt lines)" "$(grep -c '^+line added by fake codex' "$C_PATCH")" "2"
assert_ne "c: state last_run updated" "$(json_get "$STATE_W1" last_run)" "$prev_run"
assert_ne "c: state last_json updated" "$(json_get "$STATE_W1" last_json)" "$prev_json"
assert_contains "c: thread_id echoed" "$out" "thread_id: thr_test_123"
pfile="$(line_value "$out" prompt)"
assert_file_contains "c: prompt has follow-up text" "$pfile" "also fix docs"

# --- d. list --------------------------------------------------------------------
out="$(cd "$REPO" && bash "$SCRIPT" --list --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "d: list exit 0" "$rc" "0"
line="$(printf '%s\n' "$out" | grep -F 'codex/w1' | head -1)"
assert_contains "d: list has label" "$line" "w1 |"
assert_contains "d: list has branch" "$line" "codex/w1"
assert_contains "d: list has thread_id" "$line" "thr_test_123"
assert_contains "d: list has status" "$line" "done"

# --- e. duplicate label ---------------------------------------------------------
ARGS="$TMP/e.args"
rm -f "$ARGS"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --task "again" --label w1 --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "e: duplicate label exit 4" "$rc" "4"
assert_contains "e: hint mentions --cleanup" "$out" "--cleanup"
if [ -e "$ARGS" ]; then fail "e: codex not run"; else pass "e: codex not run"; fi

# --- f. cleanup -----------------------------------------------------------------
out="$(cd "$REPO" && bash "$SCRIPT" --cleanup --label w1 --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "f: cleanup exit 0" "$rc" "0"
assert_absent "f: worktree gone" "$WT_W1"
if branch_exists codex/w1; then fail "f: branch gone"; else pass "f: branch gone"; fi
assert_absent "f: state gone" "$STATE_W1"
assert_exists "f: patch kept" "$B_PATCH"
assert_exists "f: json kept" "$B_JSON"
assert_contains "f: reports removal" "$out" "removed"
assert_eq "f: main repo still clean" "$(git -C "$REPO" status --porcelain)" ""

# --- g. cleanup keeps a branch with commits ---------------------------------------
ARGS="$TMP/g.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --task "w2 task" --label w2 --out-dir "$OUT" 2>"$TMP/g.stderr")"
rc=$?
assert_eq "g: w2 run exit 0" "$rc" "0"
WT_W2="$WT_DIR/w2"
git -C "$WT_W2" add -A >/dev/null 2>&1
git -C "$WT_W2" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -qm "worker commit" >/dev/null 2>&1
out="$(cd "$REPO" && bash "$SCRIPT" --cleanup --label w2 --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "g: cleanup exit 0" "$rc" "0"
assert_absent "g: worktree gone" "$WT_W2"
if branch_exists codex/w2; then pass "g: branch with commits kept"; else fail "g: branch with commits kept"; fi
assert_contains "g: message says kept" "$out" "kept"
assert_absent "g: state gone" "$ST_DIR/w2.json"

# --- h. in-place on a dirty repo ----------------------------------------------------
printf 'def util():\n    return 2\n' > "$REPO/src/util.py"
$GIT add src/util.py
ARGS="$TMP/h.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --in-place --task "x" --label ip1 --out-dir "$OUT" 2>"$TMP/h.stderr")"
rc=$?
assert_eq "h: exit 0" "$rc" "0"
assert_absent "h: no worktree" "$WT_DIR/ip1"
if branch_exists codex/ip1; then fail "h: no branch"; else pass "h: no branch"; fi
cline="$(grep -A1 -x -- '-C' "$ARGS" | tail -1)"
assert_eq "h: argv -C <repo>" "$cline" "$REPO"
H_PATCH="$(line_value "$out" patch)"
if [ -s "$H_PATCH" ]; then pass "h: patch created"; else fail "h: patch created ($H_PATCH)"; fi
assert_file_contains "h: patch has worker file" "$H_PATCH" "worker-output.txt"
assert_file_contains "h: patch has pre-existing change" "$H_PATCH" "+    return 2"
assert_eq "h: state pre_dirty true" "$(json_get "$ST_DIR/ip1.json" pre_dirty)" "True"
assert_eq "h: state in_place true" "$(json_get "$ST_DIR/ip1.json" in_place)" "True"
assert_contains "h: stderr warns about dirty tree" "$(cat "$TMP/h.stderr")" "dirty"
assert_eq "h: user index preserved" "$(git -C "$REPO" diff --cached --name-only)" "src/util.py"
assert_exists "h: codex edited the repo directly" "$REPO/worker-output.txt"
# restore the repo
$GIT reset -q
git -C "$REPO" checkout -q -- .
rm -f "$REPO/worker-output.txt"
out="$(cd "$REPO" && bash "$SCRIPT" --cleanup --label ip1 --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "h: in-place cleanup exit 0" "$rc" "0"
assert_absent "h: in-place state gone" "$ST_DIR/ip1.json"
assert_eq "h: repo clean after restore" "$(git -C "$REPO" status --porcelain)" ""

# --- i. flags ------------------------------------------------------------------------
ARGS="$TMP/i.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" FAKE_CODEX_NOOP=1 bash "$SCRIPT" --task "flags" --label fl1 --model spark --effort xhigh --network --search --out-dir "$OUT" 2>"$TMP/i.stderr")"
rc=$?
assert_eq "i: exit 0" "$rc" "0"
assert_line "i: argv -m" "$ARGS" "-m"
assert_line "i: argv spark mapped" "$ARGS" "gpt-5.3-codex-spark"
assert_line "i: argv effort xhigh" "$ARGS" 'model_reasoning_effort="xhigh"'
assert_line "i: argv network" "$ARGS" "sandbox_workspace_write.network_access=true"
assert_line "i: argv search" "$ARGS" "tools.web_search=true"
assert_no_line "i: argv no effort high" "$ARGS" 'model_reasoning_effort="high"'
I_PATCH="$(line_value "$out" patch)"
if [ -f "$I_PATCH" ] && [ ! -s "$I_PATCH" ]; then pass "i: empty patch file still created"; else fail "i: empty patch file still created ($I_PATCH)"; fi
out="$(cd "$REPO" && bash "$SCRIPT" --cleanup --label fl1 --out-dir "$OUT" 2>&1)"
assert_eq "i: cleanup exit 0" "$?" "0"

# --- j. errors ---------------------------------------------------------------------------
printf 'task from file\n' > "$TMP/task.md"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/j1.args" bash "$SCRIPT" --task "a" --task-file "$TMP/task.md" --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "j: --task and --task-file together exit 2" "$rc" "2"
assert_contains "j: message mentions task" "$out" "task"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/j2.args" bash "$SCRIPT" --resume --task "more" --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "j: --resume without --label exit 2" "$rc" "2"
assert_contains "j: message mentions label" "$out" "label"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/j3.args" bash "$SCRIPT" --task "a" --context missing.py --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "j: missing --context exit 2" "$rc" "2"
assert_contains "j: message names missing path" "$out" "missing.py"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/j4.args" bash "$SCRIPT" --task "a" --base nosuchref --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
if [ "$rc" = 2 ] || [ "$rc" = 4 ]; then pass "j: unknown --base exit 2 or 4"; else fail "j: unknown --base exit 2 or 4 (got $rc)"; fi
assert_contains "j: message mentions base" "$out" "base"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/j5.args" bash "$SCRIPT" --task "a" --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "j: no --task without label still ok (default label)" "$rc" "0"
assert_contains "j: default label pattern" "$out" "label: w-"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/j6.args" bash "$SCRIPT" --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "j: run without task exit 2" "$rc" "2"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/j7.args" bash "$SCRIPT" --task-file "$TMP/task.md" --label tf1 --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "j: --task-file dry-run exit 0" "$rc" "0"
pfile="$(line_value "$out" prompt)"
assert_file_contains "j: prompt has task from file" "$pfile" "task from file"

ARGS="$TMP/j8.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" FAKE_CODEX_EXIT=7 bash "$SCRIPT" --task "fail" --label f7 --out-dir "$OUT" 2>"$TMP/j8.stderr")"
rc=$?
assert_eq "j: codex exit 7 propagated" "$rc" "7"
assert_contains "j: header exit: 7" "$out" "exit: 7"
J_PATCH="$(line_value "$out" patch)"
if [ -s "$J_PATCH" ]; then pass "j: patch snapshotted despite failure"; else fail "j: patch snapshotted despite failure ($J_PATCH)"; fi
assert_file_contains "j: failed run patch has worker file" "$J_PATCH" "worker-output.txt"
assert_exists "j: state written despite failure" "$ST_DIR/f7.json"
out="$(cd "$REPO" && bash "$SCRIPT" --cleanup --label f7 --out-dir "$OUT" 2>&1)"
assert_eq "j: cleanup f7 exit 0" "$?" "0"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/j9.args" bash "$SCRIPT" --task "a" --effort bogus --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "j: bad effort exit 2" "$rc" "2"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/j10.args" bash "$SCRIPT" --resume --label nosuchworker --task "x" --out-dir "$OUT" 2>&1)"
rc=$?
assert_ne "j: resume of unknown worker fails" "$rc" "0"
assert_contains "j: resume of unknown worker names it" "$out" "nosuchworker"

# --- k. help ------------------------------------------------------------------------------
out="$(bash "$SCRIPT" --help 2>&1)"
rc=$?
assert_eq "k: --help exit 0" "$rc" "0"
assert_contains "k: --help shows usage" "$out" "Usage"
out="$(bash "$SCRIPT" -h 2>&1)"
assert_eq "k: -h exit 0" "$?" "0"

# --- l. live progress lines -------------------------------------------------------
: > "$ARGS"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --task "progress" --label prog1 --out-dir "$OUT" 2>"$TMP/l1.stderr")"
assert_eq "l: progress run exit 0" "$?" "0"
assert_file_contains "l: progress line printed to stderr" "$TMP/l1.stderr" "[codex prog1 "
assert_file_contains "l: progress shows thread id" "$TMP/l1.stderr" "thread thr_test_123"
assert_not_contains "l: progress does not leak into stdout" "$out" "[codex prog1 "
: > "$ARGS"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --task "progress" --label prog2 --quiet --out-dir "$OUT" 2>"$TMP/l2.stderr")"
assert_eq "l: quiet run exit 0" "$?" "0"
if grep -q "\[codex prog2 " "$TMP/l2.stderr"; then fail "l: --quiet suppresses progress"; else pass "l: --quiet suppresses progress"; fi

# --- minimal PATH --------------------------------------------------------------------
# A directory of wrapper scripts for every external command the script under test
# needs, so PATH can be restricted to it (plus the fake codex) and neither `timeout`
# nor `gtimeout` is found even on a machine that has both (Homebrew coreutils).
MINBIN="$TMP/minbin"
mkdir -p "$MINBIN"
for tool in bash sh git python3 cat tr cut mkdir date basename dirname sed head tail grep rm cp mv env sleep; do
  real="$(command -v "$tool" 2>/dev/null)" || continue
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$real" > "$MINBIN/$tool"
  chmod +x "$MINBIN/$tool"
done
# Fake gtimeout: records its duration argument, then runs the command without a limit.
GTBIN="$TMP/gtbin"
mkdir -p "$GTBIN"
cat > "$GTBIN/gtimeout" <<'FAKE'
#!/bin/bash
if [ -n "${FAKE_GTIMEOUT_LOG:-}" ]; then printf '%s\n' "$1" > "$FAKE_GTIMEOUT_LOG"; fi
shift
exec "$@"
FAKE
chmod +x "$GTBIN/gtimeout"
if PATH="$BIN:$MINBIN" bash -c 'command -v timeout || command -v gtimeout' >/dev/null 2>&1; then
  fail "m: minimal PATH has no timeout binaries"
else
  pass "m: minimal PATH has no timeout binaries"
fi

# --- m. timeout fallback ----------------------------------------------------------------
# m1: neither timeout nor gtimeout -> one warning, command without a limit, still exit 0
ARGS="$TMP/m1.args"
out="$(cd "$REPO" && PATH="$BIN:$MINBIN" FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --dry-run --task "t" --label to1 --out-dir "$OUT" 2>"$TMP/m1.stderr")"
rc=$?
assert_eq "m: no-timeout dry-run exit 0" "$rc" "0"
assert_file_contains "m: no-timeout warning on stderr" "$TMP/m1.stderr" "codex-worker: warning: no timeout/gtimeout binary found (install coreutils); running without a time limit"
assert_eq "m: warning printed once" "$(grep -c 'no timeout/gtimeout' "$TMP/m1.stderr")" "1"
printf '%s\n' "$out" > "$TMP/m1.out"
assert_no_line "m: dry-run command has no timeout" "$TMP/m1.out" "timeout"
assert_no_line "m: dry-run command has no gtimeout" "$TMP/m1.out" "gtimeout"
first="$(grep -A1 -x -- 'command (one argument per line):' "$TMP/m1.out" | tail -1)"
assert_eq "m: dry-run command starts with codex" "$first" "codex"
# m2: a full run without a timeout binary completes normally
ARGS="$TMP/m2.args"
out="$(cd "$REPO" && PATH="$BIN:$MINBIN" FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --task "t" --label to2 --out-dir "$OUT" 2>"$TMP/m2.stderr")"
rc=$?
assert_eq "m: no-timeout full run exit 0" "$rc" "0"
assert_file_contains "m: no-timeout full run warns" "$TMP/m2.stderr" "no timeout/gtimeout binary found"
assert_contains "m: no-timeout full run produced json" "$out" '"status": "done"'
assert_eq "m: codex invoked directly (first argv is exec)" "$(head -1 "$ARGS")" "exec"
# m3: --timeout 0 -> no warning even without the binaries
out="$(cd "$REPO" && PATH="$BIN:$MINBIN" FAKE_CODEX_ARGS="$TMP/m3.args" bash "$SCRIPT" --dry-run --task "t" --label to3 --timeout 0 --out-dir "$OUT" 2>"$TMP/m3.stderr")"
assert_eq "m: --timeout 0 exit 0" "$?" "0"
if grep -q 'no timeout/gtimeout' "$TMP/m3.stderr"; then fail "m: --timeout 0 prints no warning"; else pass "m: --timeout 0 prints no warning"; fi
# m4: only gtimeout available -> it is used, no warning, dry-run shows it
out="$(cd "$REPO" && PATH="$BIN:$GTBIN:$MINBIN" FAKE_CODEX_ARGS="$TMP/m4.args" bash "$SCRIPT" --dry-run --task "t" --label to4 --out-dir "$OUT" 2>"$TMP/m4.stderr")"
assert_eq "m: gtimeout dry-run exit 0" "$?" "0"
printf '%s\n' "$out" > "$TMP/m4.out"
first="$(grep -A1 -x -- 'command (one argument per line):' "$TMP/m4.out" | tail -1)"
assert_eq "m: dry-run command starts with gtimeout" "$first" "gtimeout"
second="$(grep -A2 -x -- 'command (one argument per line):' "$TMP/m4.out" | tail -1)"
assert_eq "m: dry-run gtimeout gets the default 1800" "$second" "1800"
if grep -q 'no timeout/gtimeout' "$TMP/m4.stderr"; then fail "m: gtimeout dry-run no warning"; else pass "m: gtimeout dry-run no warning"; fi
# m5: gtimeout is really invoked in a full run, with the --timeout value
GTLOG="$TMP/m5.gtimeout"
out="$(cd "$REPO" && PATH="$BIN:$GTBIN:$MINBIN" FAKE_CODEX_ARGS="$TMP/m5.args" FAKE_GTIMEOUT_LOG="$GTLOG" bash "$SCRIPT" --task "t" --label to5 --timeout 42 --out-dir "$OUT" 2>"$TMP/m5.stderr")"
assert_eq "m: gtimeout full run exit 0" "$?" "0"
assert_eq "m: gtimeout invoked with --timeout value" "$(cat "$GTLOG" 2>/dev/null)" "42"
assert_contains "m: gtimeout full run produced json" "$out" '"status": "done"'
# m6: the resume path uses the same resolved binary
GTLOG="$TMP/m6.gtimeout"
out="$(cd "$REPO" && PATH="$BIN:$GTBIN:$MINBIN" FAKE_CODEX_ARGS="$TMP/m6.args" FAKE_GTIMEOUT_LOG="$GTLOG" bash "$SCRIPT" --resume --label to5 --task "again" --timeout 43 --out-dir "$OUT" 2>"$TMP/m6.stderr")"
assert_eq "m: gtimeout resume exit 0" "$?" "0"
assert_eq "m: resume invoked gtimeout too" "$(cat "$GTLOG" 2>/dev/null)" "43"

# --- n. codex version warning ---------------------------------------------------------------
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/n1.args" FAKE_CODEX_VERSION=0.120.0 bash "$SCRIPT" --task "t" --label ver1 --out-dir "$OUT" 2>"$TMP/n1.stderr")"
rc=$?
assert_eq "n: old codex still exit 0" "$rc" "0"
assert_file_contains "n: old codex warning" "$TMP/n1.stderr" "codex-worker: warning: codex 0.120.0 detected; this script is tested with codex-cli 0.153 and later; continuing"
assert_contains "n: old codex run produced json" "$out" '"status": "done"'
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/n2.args" bash "$SCRIPT" --task "t" --label ver2 --out-dir "$OUT" 2>"$TMP/n2.stderr")"
assert_eq "n: current codex exit 0" "$?" "0"
if grep -q 'warning: codex' "$TMP/n2.stderr"; then fail "n: no version warning at 0.153.4"; else pass "n: no version warning at 0.153.4"; fi
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/n3.args" FAKE_CODEX_VERSION=garbage bash "$SCRIPT" --dry-run --task "t" --label ver3 --out-dir "$OUT" 2>"$TMP/n3.stderr")"
assert_eq "n: unparsable version exit 0" "$?" "0"
assert_file_contains "n: unparsable version warns" "$TMP/n3.stderr" "warning: codex of unknown version"
assert_file_contains "n: unparsable version quotes raw output" "$TMP/n3.stderr" "codex-cli garbage"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/n4.args" FAKE_CODEX_VERSION=1.0.0 bash "$SCRIPT" --dry-run --task "t" --label ver4 --out-dir "$OUT" 2>"$TMP/n4.stderr")"
if grep -q 'warning: codex' "$TMP/n4.stderr"; then fail "n: no warning at 1.0.0"; else pass "n: no warning at 1.0.0"; fi
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/n5.args" FAKE_CODEX_VERSION=0.150.0 bash "$SCRIPT" --dry-run --task "t" --label ver5 --out-dir "$OUT" 2>"$TMP/n5.stderr")"
if grep -q 'warning: codex' "$TMP/n5.stderr"; then fail "n: no warning at boundary 0.150.0"; else pass "n: no warning at boundary 0.150.0"; fi
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/n6.args" FAKE_CODEX_VERSION=0.149.9 bash "$SCRIPT" --dry-run --task "t" --label ver6 --out-dir "$OUT" 2>"$TMP/n6.stderr")"
assert_file_contains "n: warning just below boundary 0.149.9" "$TMP/n6.stderr" "warning: codex 0.149.9 detected"
if [ -e "$TMP/n6.args" ]; then fail "n: --version probe is not a codex run in dry-run"; else pass "n: --version probe is not a codex run in dry-run"; fi

# --- summary ---------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'temp dir kept for inspection: %s\n' "$TMP"
  exit 1
fi
# remove worktrees registered in the temp repo before deleting the tree
git -C "$REPO" worktree prune >/dev/null 2>&1 || true
rm -rf "$TMP"
exit 0
