#!/bin/bash
# Test suite for scripts/second-opinion.sh.
# Uses a fake `codex` placed first on PATH; the real Codex CLI is never called.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$SKILL_DIR/scripts/second-opinion.sh"
SCHEMA="$SKILL_DIR/scripts/findings.schema.json"

# Temp root: $SECOND_OPINION_TEST_TMPDIR when set, else $TMPDIR (or /tmp).
SCRATCH="${SECOND_OPINION_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$SCRATCH"
TMP="$(mktemp -d "$SCRATCH/second-opinion-tests.XXXXXX")"
# Canonical path: on macOS $TMPDIR lives under /var, a symlink to /private/var,
# and the scripts print physical paths (pwd -P).
TMP="$(cd "$TMP" && pwd -P)"
# The temp dir goes away on any exit (also Ctrl-C) unless a test failed; stray
# fake codex processes from the interrupt tests are killed first.
KEEP_TMP=0
cleanup() {
  for pf in "$TMP"/*.fakepid; do
    [ -f "$pf" ] && kill -TERM "$(cat "$pf" 2>/dev/null)" 2>/dev/null
  done
  if [ "$KEEP_TMP" = 1 ]; then
    printf 'temp dir kept for inspection: %s\n' "$TMP"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then pass "$1"; else fail "$1 (got '$2', expected anything else)"; fi
}
line_value() { # line_value <stdout> <key>  -> value of "key: value"
  printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1
}

# --- fake codex -------------------------------------------------------------
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/codex" <<'FAKE'
#!/bin/bash
# Fake codex: records argv, reads the prompt from stdin, writes canned output,
# never touches the network.
# `codex --version` is answered first and records nothing: the version probe is
# not a run. FAKE_CODEX_VERSION overrides the reported version.
# With `-` as the last argument (the prompt comes from stdin, as in real codex)
# stdin is saved to $FAKE_CODEX_STDIN when set; otherwise it is drained.
# FAKE_CODEX_SLEEP=<sec>: write the own pid to $FAKE_CODEX_PIDFILE and become
# `sleep <sec>` (same pid), to test that interrupting the script stops codex.
if [ "${1:-}" = "--version" ]; then printf 'codex-cli %s\n' "${FAKE_CODEX_VERSION:-0.156.0}"; exit 0; fi
: "${FAKE_CODEX_ARGS:?FAKE_CODEX_ARGS must be set}"
printf '%s\n' "$@" > "$FAKE_CODEX_ARGS"
last=""
for a in "$@"; do last="$a"; done
if [ "$last" = "-" ] && [ -n "${FAKE_CODEX_STDIN:-}" ]; then cat > "$FAKE_CODEX_STDIN"; else cat > /dev/null; fi
if [ -n "${FAKE_CODEX_SLEEP:-}" ]; then
  printf '%s\n' "$$" > "$FAKE_CODEX_PIDFILE"
  exec sleep "$FAKE_CODEX_SLEEP"
fi
out=""
schema=0
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ] || [ "$prev" = "--output-last-message" ]; then out="$a"; fi
  if [ "$a" = "--output-schema" ]; then schema=1; fi
  prev="$a"
done
if [ -n "$out" ]; then
  if [ "$schema" = 1 ]; then
    cat > "$out" <<'JSON'
{"summary":"One likely bug in the uncommitted change.","verdict":"needs_changes","coverage":"Inspected git diff and hello.txt; did not run tests.","findings":[{"severity":"P2","title":"Greeting loses trailing newline","location":"hello.txt:1","claim":"The new line has no terminating newline.","failure_scenario":"cat hello.txt followed by another file concatenates lines.","evidence":"git diff shows '\\ No newline at end of file'.","confidence":"medium"}]}
JSON
  else
    cat > "$out" <<'MD'
# Review

## Summary
Prose review from fake codex.

## Verdict
needs_changes
MD
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
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" symbolic-ref HEAD refs/heads/main
gitc() { git -C "$REPO" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false "$@"; }
printf 'hello\n' > "$REPO/hello.txt"
gitc add hello.txt
gitc commit -qm "init"
gitc branch base0
printf 'lib\n' > "$REPO/lib.txt"
gitc add lib.txt
gitc commit -qm "second"
printf 'hello world' > "$REPO/hello.txt"
printf 'new file\n' > "$REPO/untracked.txt"

OUT="$TMP/out"
mkdir -p "$OUT"

# --- prerequisites ----------------------------------------------------------
if [ ! -x "$SCRIPT" ]; then fail "script is executable: $SCRIPT"; fi
if bash -n "$SCRIPT" 2>/dev/null; then pass "bash -n script"; else fail "bash -n script"; fi
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SCHEMA" 2>/dev/null; then pass "schema is valid JSON"; else fail "schema is valid JSON"; fi
if [ "$(command -v codex)" = "$BIN/codex" ]; then pass "fake codex is first on PATH"; else fail "fake codex is first on PATH ($(command -v codex))"; fi

# --- a. dry-run --------------------------------------------------------------
ARGS="$TMP/a.args"
rm -f "$ARGS"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --dry-run --uncommitted --label a --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "a: dry-run exit 0" "$rc" "0"
assert_contains "a: -s flag" "$out" "-s"
assert_contains "a: read-only" "$out" "read-only"
assert_contains "a: sandbox_mode override" "$out" 'sandbox_mode="read-only"'
assert_contains "a: approval_policy never" "$out" 'approval_policy="never"'
assert_contains "a: skip git repo check" "$out" "--skip-git-repo-check"
cline="$(printf '%s\n' "$out" | grep -A1 -x -- '-C' | tail -1)"
cline="${cline#\'}"; cline="${cline%\'}"  # dry-run shell-quotes paths with spaces
assert_eq "a: -C <repo>" "$cline" "$REPO"
assert_contains "a: output-schema" "$out" "--output-schema"
assert_contains "a: effort high" "$out" 'model_reasoning_effort="high"'
assert_not_contains "a: no --ephemeral" "$out" "--ephemeral"
assert_contains "a: prompt path printed" "$out" "prompt: $OUT/"
if [ -e "$ARGS" ]; then fail "a: codex not run in dry-run"; else pass "a: codex not run in dry-run"; fi
pfile="$(line_value "$out" prompt)"
assert_file_contains "a: prompt mentions git diff --cached" "$pfile" "git diff --cached"
assert_file_contains "a: prompt mentions untracked" "$pfile" "untracked"
assert_contains "a: stdin line names the prompt file" "$out" "stdin: $pfile"
lastarg="$(printf '%s\n' "$out" | tail -1)"
assert_eq "a: prompt is read from stdin (last argument -)" "$lastarg" "-"
assert_not_contains "a: prompt text not in argv" "$out" "Independent second-opinion review"

# --- b. full run, uncommitted ----------------------------------------------
ARGS="$TMP/b.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" FAKE_CODEX_STDIN="$TMP/b.stdin" bash "$SCRIPT" --uncommitted --label t1 --out-dir "$OUT" 2>"$TMP/b.stderr")"
rc=$?
assert_eq "b: exit 0" "$rc" "0"
assert_contains "b: json: line" "$out" "json: "
assert_contains "b: thread_id" "$out" "thread_id: thr_test_123"
assert_contains "b: exit: 0" "$out" "exit: 0"
jfile="$(line_value "$out" json)"
mfile="$(line_value "$out" markdown)"
assert_contains "b: label in json name" "$jfile" "-t1.json"
assert_file_contains "b: json has findings" "$jfile" '"findings"'
if [ -f "$mfile" ]; then pass "b: markdown exists"; else fail "b: markdown exists ($mfile)"; fi
assert_file_contains "b: markdown has finding title" "$mfile" "Greeting loses trailing newline"
assert_file_contains "b: markdown has verdict" "$mfile" "needs_changes"
assert_line "b: argv --json" "$ARGS" "--json"
assert_line "b: argv -o" "$ARGS" "-o"
assert_line "b: argv exec" "$ARGS" "exec"
assert_no_line "b: argv no --ephemeral" "$ARGS" "--ephemeral"
assert_no_line "b: argv no -m by default" "$ARGS" "-m"
assert_contains "b: stdout ends with json body" "$out" '"verdict": "needs_changes"'
assert_eq "b: last argv is - (prompt on stdin)" "$(tail -1 "$ARGS")" "-"
assert_file_contains "b: codex got the prompt on stdin" "$TMP/b.stdin" "Independent second-opinion review"
assert_no_line "b: prompt heading not in argv" "$ARGS" "# Independent second-opinion review"

# --- c. no-schema, base ------------------------------------------------------
ARGS="$TMP/c.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --no-schema --base base0 --label c --out-dir "$OUT" 2>"$TMP/c.stderr")"
rc=$?
assert_eq "c: exit 0" "$rc" "0"
assert_no_line "c: argv no --output-schema" "$ARGS" "--output-schema"
pfile="$(line_value "$out" prompt)"
assert_file_contains "c: prompt has git diff base0...HEAD" "$pfile" "git diff base0...HEAD"
assert_file_contains "c: prompt has git log" "$pfile" "git log --oneline base0..HEAD"
assert_file_contains "c: prompt asks for markdown" "$pfile" "arkdown"
mfile="$(line_value "$out" markdown)"
assert_file_contains "c: markdown is codex prose" "$mfile" "Prose review from fake codex"

# --- d. plan -----------------------------------------------------------------
ARGS="$TMP/d.args"
PLAN="$TMP/my plan.md"
printf '# Plan\n1. Do the thing.\n' > "$PLAN"
out="$(cd "$TMP" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --plan "$PLAN" --out-dir "$OUT" 2>"$TMP/d.stderr")"
rc=$?
assert_eq "d: exit 0 (non-git cwd)" "$rc" "0"
pfile="$(line_value "$out" prompt)"
assert_file_contains "d: prompt has plan path" "$pfile" "$PLAN"
assert_file_contains "d: prompt says plan" "$pfile" "plan"
assert_file_contains "d: prompt asks about assumptions" "$pfile" "assumptions"
cline="$(grep -A1 -x -- '-C' "$ARGS" | tail -1)"
assert_eq "d: repo falls back to cwd" "$cline" "$TMP"

# --- e. model, effort, search -------------------------------------------------
ARGS="$TMP/e.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --model gpt-5.4 --effort xhigh --search --label e --out-dir "$OUT" 2>"$TMP/e.stderr")"
rc=$?
assert_eq "e: exit 0" "$rc" "0"
assert_line "e: argv -m" "$ARGS" "-m"
assert_line "e: argv model" "$ARGS" "gpt-5.4"
assert_line "e: argv effort xhigh" "$ARGS" 'model_reasoning_effort="xhigh"'
assert_line "e: argv web search" "$ARGS" 'web_search="live"'
assert_no_line "e: argv no legacy tools.web_search" "$ARGS" "tools.web_search=true"
assert_no_line "e: argv no effort high" "$ARGS" 'model_reasoning_effort="high"'
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/e2.args" bash "$SCRIPT" --effort minimal --dry-run --label e2 --out-dir "$OUT" 2>&1)"
assert_eq "e: unlisted effort passes through (exit 0)" "$?" "0"
assert_contains "e: effort minimal passed to codex" "$out" 'model_reasoning_effort="minimal"'

# --- f. two scopes -------------------------------------------------------------
ARGS="$TMP/f.args"
rm -f "$ARGS"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --uncommitted --base main --out-dir "$OUT" 2>&1)"
rc=$?
assert_ne "f: two scopes exit non-zero" "$rc" "0"
assert_contains "f: error mentions scope" "$out" "scope"
if [ -e "$ARGS" ]; then fail "f: codex not run"; else pass "f: codex not run"; fi

# --- g. resume ------------------------------------------------------------------
ARGS="$TMP/g.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" FAKE_CODEX_STDIN="$TMP/g.stdin" bash "$SCRIPT" --resume thr_x --focus "argue" --label g --out-dir "$OUT" 2>"$TMP/g.stderr")"
rc=$?
assert_eq "g: exit 0" "$rc" "0"
head3="$(head -3 "$ARGS" | tr '\n' ' ')"
assert_eq "g: argv starts with exec resume thr_x" "$head3" "exec resume thr_x "
assert_line "g: argv sandbox override" "$ARGS" 'sandbox_mode="read-only"'
assert_line "g: argv approval never" "$ARGS" 'approval_policy="never"'
assert_no_line "g: argv no -C" "$ARGS" "-C"
assert_no_line "g: argv no -s" "$ARGS" "-s"
assert_eq "g: resume argv ends with - (prompt on stdin)" "$(tail -1 "$ARGS")" "-"
assert_eq "g: resume prompt on stdin is the focus" "$(cat "$TMP/g.stdin" 2>/dev/null)" "argue"
assert_contains "g: thread_id echoed" "$out" "thread_id: thr_x"

# --- h. codex failure -----------------------------------------------------------
ARGS="$TMP/h.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" FAKE_CODEX_EXIT=7 bash "$SCRIPT" --uncommitted --label h --out-dir "$OUT" 2>"$TMP/h.stderr")"
rc=$?
assert_ne "h: script exit non-zero" "$rc" "0"
assert_contains "h: stdout has exit: 7" "$out" "exit: 7"

# --- extra: file scope, bad args ---------------------------------------------------
ARGS="$TMP/i.args"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --file hello.txt --file untracked.txt --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "i: --file dry-run exit 0" "$rc" "0"
pfile="$(line_value "$out" prompt)"
assert_file_contains "i: prompt lists first file" "$pfile" "$REPO/hello.txt"
assert_file_contains "i: prompt lists second file" "$pfile" "$REPO/untracked.txt"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/j.args" bash "$SCRIPT" --effort 'High;1' --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_eq "j: malformed effort rejected with 2" "$rc" "2"
assert_contains "j: bad effort message" "$out" "effort"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/k.args" bash "$SCRIPT" --resume thr_x --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_ne "k: resume without focus rejected" "$rc" "0"
assert_contains "k: resume error mentions focus" "$out" "focus"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/l.args" bash "$SCRIPT" --commit nosuchsha --dry-run --out-dir "$OUT" 2>&1)"
rc=$?
assert_ne "l: unknown commit rejected" "$rc" "0"

out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/m.args" bash "$SCRIPT" --help 2>&1)"
rc=$?
assert_eq "m: --help exit 0" "$rc" "0"
assert_contains "m: --help shows usage" "$out" "Usage"

# --- n. live progress lines -------------------------------------------------------
: > "$ARGS"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --uncommitted --label n1 --out-dir "$OUT" 2>"$TMP/n1.stderr")"
assert_eq "n: progress run exit 0" "$?" "0"
assert_file_contains "n: progress line printed to stderr" "$TMP/n1.stderr" "[codex n1 "
assert_file_contains "n: progress shows thread id" "$TMP/n1.stderr" "thread thr_test_123"
assert_not_contains "n: progress does not leak into stdout" "$out" "[codex n1 "
: > "$ARGS"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --uncommitted --label n2 --quiet --out-dir "$OUT" 2>"$TMP/n2.stderr")"
assert_eq "n: quiet run exit 0" "$?" "0"
if grep -q "\[codex n2 " "$TMP/n2.stderr"; then fail "n: --quiet suppresses progress"; else pass "n: --quiet suppresses progress"; fi

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
  fail "o: minimal PATH has no timeout binaries"
else
  pass "o: minimal PATH has no timeout binaries"
fi

# --- o. timeout fallback ----------------------------------------------------------------
# o1: neither timeout nor gtimeout -> one warning, command without a limit, still exit 0
ARGS="$TMP/o1.args"
out="$(cd "$REPO" && PATH="$BIN:$MINBIN" FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --dry-run --uncommitted --label o1 --out-dir "$OUT" 2>"$TMP/o1.stderr")"
rc=$?
assert_eq "o: no-timeout dry-run exit 0" "$rc" "0"
assert_file_contains "o: no-timeout warning on stderr" "$TMP/o1.stderr" "second-opinion: warning: no timeout/gtimeout binary found (install coreutils); running without a time limit"
assert_eq "o: warning printed once" "$(grep -c 'no timeout/gtimeout' "$TMP/o1.stderr")" "1"
printf '%s\n' "$out" > "$TMP/o1.out"
assert_no_line "o: dry-run command has no timeout" "$TMP/o1.out" "timeout"
assert_no_line "o: dry-run command has no gtimeout" "$TMP/o1.out" "gtimeout"
first="$(grep -A1 -x -- 'command (one argument per line):' "$TMP/o1.out" | tail -1)"
assert_eq "o: dry-run command starts with codex" "$first" "codex"
# o2: a full run without a timeout binary completes normally
ARGS="$TMP/o2.args"
out="$(cd "$REPO" && PATH="$BIN:$MINBIN" FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --uncommitted --label o2 --out-dir "$OUT" 2>"$TMP/o2.stderr")"
rc=$?
assert_eq "o: no-timeout full run exit 0" "$rc" "0"
assert_file_contains "o: no-timeout full run warns" "$TMP/o2.stderr" "no timeout/gtimeout binary found"
assert_contains "o: no-timeout full run produced json" "$out" '"verdict": "needs_changes"'
assert_eq "o: codex invoked directly (first argv is exec)" "$(head -1 "$ARGS")" "exec"
# o3: --timeout 0 -> no warning even without the binaries
out="$(cd "$REPO" && PATH="$BIN:$MINBIN" FAKE_CODEX_ARGS="$TMP/o3.args" bash "$SCRIPT" --dry-run --uncommitted --label o3 --timeout 0 --out-dir "$OUT" 2>"$TMP/o3.stderr")"
assert_eq "o: --timeout 0 exit 0" "$?" "0"
if grep -q 'no timeout/gtimeout' "$TMP/o3.stderr"; then fail "o: --timeout 0 prints no warning"; else pass "o: --timeout 0 prints no warning"; fi
# o4: only gtimeout available -> it is used, no warning, dry-run shows it
out="$(cd "$REPO" && PATH="$BIN:$GTBIN:$MINBIN" FAKE_CODEX_ARGS="$TMP/o4.args" bash "$SCRIPT" --dry-run --uncommitted --label o4 --out-dir "$OUT" 2>"$TMP/o4.stderr")"
assert_eq "o: gtimeout dry-run exit 0" "$?" "0"
printf '%s\n' "$out" > "$TMP/o4.out"
first="$(grep -A1 -x -- 'command (one argument per line):' "$TMP/o4.out" | tail -1)"
assert_eq "o: dry-run command starts with gtimeout" "$first" "gtimeout"
second="$(grep -A2 -x -- 'command (one argument per line):' "$TMP/o4.out" | tail -1)"
assert_eq "o: dry-run gtimeout gets the default 900" "$second" "900"
if grep -q 'no timeout/gtimeout' "$TMP/o4.stderr"; then fail "o: gtimeout dry-run no warning"; else pass "o: gtimeout dry-run no warning"; fi
# o5: gtimeout is really invoked in a full run, with the --timeout value
GTLOG="$TMP/o5.gtimeout"
out="$(cd "$REPO" && PATH="$BIN:$GTBIN:$MINBIN" FAKE_CODEX_ARGS="$TMP/o5.args" FAKE_GTIMEOUT_LOG="$GTLOG" bash "$SCRIPT" --uncommitted --label o5 --timeout 42 --out-dir "$OUT" 2>"$TMP/o5.stderr")"
assert_eq "o: gtimeout full run exit 0" "$?" "0"
assert_eq "o: gtimeout invoked with --timeout value" "$(cat "$GTLOG" 2>/dev/null)" "42"
assert_contains "o: gtimeout full run produced json" "$out" '"verdict": "needs_changes"'
# o6: the resume path uses the same resolved binary
GTLOG="$TMP/o6.gtimeout"
out="$(cd "$REPO" && PATH="$BIN:$GTBIN:$MINBIN" FAKE_CODEX_ARGS="$TMP/o6.args" FAKE_GTIMEOUT_LOG="$GTLOG" bash "$SCRIPT" --resume thr_x --focus "again" --label o6 --timeout 43 --out-dir "$OUT" 2>"$TMP/o6.stderr")"
assert_eq "o: gtimeout resume exit 0" "$?" "0"
assert_eq "o: resume invoked gtimeout too" "$(cat "$GTLOG" 2>/dev/null)" "43"

# --- p. codex version warning ---------------------------------------------------------------
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/p1.args" FAKE_CODEX_VERSION=0.120.0 bash "$SCRIPT" --uncommitted --label p1 --out-dir "$OUT" 2>"$TMP/p1.stderr")"
rc=$?
assert_eq "p: old codex still exit 0" "$rc" "0"
assert_file_contains "p: old codex warning" "$TMP/p1.stderr" "second-opinion: warning: codex 0.120.0 detected; this script is tested with codex-cli 0.156 (0.150 and later should work); continuing"
assert_contains "p: old codex run produced json" "$out" '"verdict": "needs_changes"'
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/p2.args" bash "$SCRIPT" --uncommitted --label p2 --out-dir "$OUT" 2>"$TMP/p2.stderr")"
assert_eq "p: current codex exit 0" "$?" "0"
if grep -q 'warning: codex' "$TMP/p2.stderr"; then fail "p: no version warning at 0.156.0"; else pass "p: no version warning at 0.156.0"; fi
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/p3.args" FAKE_CODEX_VERSION=garbage bash "$SCRIPT" --dry-run --uncommitted --label p3 --out-dir "$OUT" 2>"$TMP/p3.stderr")"
assert_eq "p: unparsable version exit 0" "$?" "0"
assert_file_contains "p: unparsable version warns" "$TMP/p3.stderr" "warning: codex of unknown version"
assert_file_contains "p: unparsable version quotes raw output" "$TMP/p3.stderr" "codex-cli garbage"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/p4.args" FAKE_CODEX_VERSION=1.0.0 bash "$SCRIPT" --dry-run --uncommitted --label p4 --out-dir "$OUT" 2>"$TMP/p4.stderr")"
if grep -q 'warning: codex' "$TMP/p4.stderr"; then fail "p: no warning at 1.0.0"; else pass "p: no warning at 1.0.0"; fi
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/p5.args" FAKE_CODEX_VERSION=0.150.0 bash "$SCRIPT" --dry-run --uncommitted --label p5 --out-dir "$OUT" 2>"$TMP/p5.stderr")"
if grep -q 'warning: codex' "$TMP/p5.stderr"; then fail "p: no warning at boundary 0.150.0"; else pass "p: no warning at boundary 0.150.0"; fi
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$TMP/p6.args" FAKE_CODEX_VERSION=0.149.9 bash "$SCRIPT" --dry-run --uncommitted --label p6 --out-dir "$OUT" 2>"$TMP/p6.stderr")"
assert_file_contains "p: warning just below boundary 0.149.9" "$TMP/p6.stderr" "warning: codex 0.149.9 detected"
if [ -e "$TMP/p6.args" ]; then fail "p: --version probe is not a codex run in dry-run"; else pass "p: --version probe is not a codex run in dry-run"; fi

# --- q. nothing to review -------------------------------------------------------------
ARGS="$TMP/q1.args"
rm -f "$ARGS"
out="$(cd "$REPO" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --base main --label q1 --out-dir "$OUT" 2>&1)"
assert_eq "q: --base with no changes exits 5" "$?" "5"
assert_contains "q: --base message says nothing to review" "$out" "nothing to review"
if [ -e "$ARGS" ]; then fail "q: codex not run for an empty --base diff"; else pass "q: codex not run for an empty --base diff"; fi
CLEAN="$TMP/clean repo"
mkdir -p "$CLEAN"
git -C "$CLEAN" init -q
printf 'x\n' > "$CLEAN/x.txt"
git -C "$CLEAN" add x.txt
git -C "$CLEAN" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -qm init
printf 'ignored.log\n' > "$CLEAN/.git/info/exclude"
printf 'noise\n' > "$CLEAN/ignored.log"
ARGS="$TMP/q2.args"
rm -f "$ARGS"
out="$(cd "$CLEAN" && FAKE_CODEX_ARGS="$ARGS" bash "$SCRIPT" --uncommitted --label q2 --out-dir "$OUT" 2>&1)"
assert_eq "q: clean tree (ignored files only) exits 5" "$?" "5"
assert_contains "q: clean tree message" "$out" "working tree"
if [ -e "$ARGS" ]; then fail "q: codex not run on a clean tree"; else pass "q: codex not run on a clean tree"; fi
printf 'new\n' > "$CLEAN/new.txt"
out="$(cd "$CLEAN" && FAKE_CODEX_ARGS="$TMP/q3.args" bash "$SCRIPT" --uncommitted --dry-run --label q3 --out-dir "$OUT" 2>&1)"
assert_eq "q: an untracked file alone is something to review" "$?" "0"
out="$(bash "$SCRIPT" --help 2>&1)"
assert_contains "q: exit code 5 documented in --help" "$out" "5 nothing to review"

# --- r. same label in parallel -----------------------------------------------------------
i=1
while [ $i -le 4 ]; do
  ( cd "$REPO" && FAKE_CODEX_ARGS="$TMP/r.args" bash "$SCRIPT" --dry-run --uncommitted --label same --out-dir "$OUT/par" > "$TMP/r$i.out" 2>/dev/null ) &
  i=$((i + 1))
done
wait
distinct="$(for i in 1 2 3 4; do line_value "$(cat "$TMP/r$i.out")" prompt; done | sort -u | grep -c .)"
assert_eq "r: four parallel runs with one label get four prompt files" "$distinct" "4"

# --- s. interrupting the script stops codex ----------------------------------------------
# The script is started in the background with SIGINT reset to default (a
# background job of a non-interactive shell would otherwise inherit SIGINT as
# ignored, and bash cannot trap a signal ignored on entry).
SIGDFL_PY='import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])'
wait_for_file() { # wait_for_file <path> ; up to ~10 s
  local k=0
  while [ ! -s "$1" ] && [ $k -lt 100 ]; do sleep 0.1; k=$((k + 1)); done
  [ -s "$1" ]
}
gone() { # gone <pid> ; true once the process has disappeared (up to ~5 s)
  local k=0
  while kill -0 "$1" 2>/dev/null && [ $k -lt 50 ]; do sleep 0.1; k=$((k + 1)); done
  ! kill -0 "$1" 2>/dev/null
}
for sig in INT TERM; do
  PIDF="$TMP/s-$sig.fakepid"
  FAKE_CODEX_ARGS="$TMP/s-$sig.args" FAKE_CODEX_SLEEP=60 FAKE_CODEX_PIDFILE="$PIDF" \
    python3 -c "$SIGDFL_PY" bash "$SCRIPT" --uncommitted --repo "$REPO" --label "s$sig" --out-dir "$OUT" \
    >"$TMP/s-$sig.out" 2>"$TMP/s-$sig.stderr" &
  spid=$!
  if wait_for_file "$PIDF"; then
    fpid="$(cat "$PIDF")"
    sleep 0.3
    kill -"$sig" "$spid"
    wait "$spid"
    rc=$?
    if [ "$sig" = INT ]; then want=130; else want=143; fi
    assert_eq "s: SIG$sig exits $want" "$rc" "$want"
    if gone "$fpid"; then pass "s: SIG$sig stops the fake codex"; else fail "s: SIG$sig stops the fake codex (pid $fpid still alive)"; fi
    assert_file_contains "s: SIG$sig says interrupted" "$TMP/s-$sig.stderr" "interrupted"
  else
    kill "$spid" 2>/dev/null
    fail "s: SIG$sig fake codex started"
  fi
done

# --- summary ---------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  KEEP_TMP=1
  exit 1
fi
exit 0
