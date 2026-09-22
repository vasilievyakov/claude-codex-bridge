#!/usr/bin/env bash
# install-statusline.sh: put the Codex signal into the Claude Code status line.
#
# After installation the status line ends with " | codex:N" while N Codex
# agents (`codex exec` processes: second-opinion reviewers, codex-worker
# workers, anything else) are running, and shows nothing extra when Codex is
# idle. An existing status line is kept as it is: its command is saved and
# wrapped, never edited.
#
# What it does:
#   1. copies statusline-codex.sh, statusline-minimal.sh and
#      statusline-segment.sh into ~/.claude/statusline/
#   2. saves the current statusLine.command (if any) to
#      ~/.claude/statusline/base-command
#   3. backs up ~/.claude/settings.json to settings.json.bak-<timestamp> and
#      points statusLine.command at statusline-codex.sh; other keys are kept
#   4. sets statusLine.refreshInterval to 2 seconds unless one is already set:
#      without it Claude Code re-runs the status line only on events (a new
#      assistant message, /compact, ...), so the counter would freeze while the
#      session sits idle waiting for Codex. CODEX_STATUSLINE_REFRESH overrides
#      the value; --uninstall removes it only if this script added it.
# Running it again is safe: a second run changes nothing in settings.json.
# Honors CLAUDE_CONFIG_DIR when set.
#
# Usage:
#   bash install-statusline.sh              # install
#   bash install-statusline.sh --self-test  # start a fake `codex exec`, render, expect codex:1
#   bash install-statusline.sh --uninstall  # restore the previous status line
# Needs bash, python3, pgrep; perl for --self-test only.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CONF/statusline"
SETTINGS="$CONF/settings.json"
TARGET="bash \"$DEST/statusline-codex.sh\""
REFRESH="${CODEX_STATUSLINE_REFRESH:-2}"
case "$REFRESH" in ""|*[!0-9]*|0) printf 'install-statusline: CODEX_STATUSLINE_REFRESH must be a whole number of seconds, 1 or more\n' >&2; exit 2 ;; esac
SAMPLE='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_read_input_tokens":50000,"output_tokens":200}}}'

say() { printf 'install-statusline: %s\n' "$*"; }
die() { printf 'install-statusline: %s\n' "$*" >&2; exit 1; }

for t in python3 pgrep; do
    command -v "$t" >/dev/null 2>&1 || die "$t not found on PATH"
done

backup_settings() {
    if [ -f "$SETTINGS" ]; then
        local b
        b="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
        cp -p "$SETTINGS" "$b"
        say "backup: $b"
    fi
}

# settings_py <mode>: read/modify statusLine in settings.json.
#   get     print the current statusLine.command (empty if none)
#   set     set statusLine.command to $TARGET, keep other statusLine keys;
#           add refreshInterval=$REFRESH when absent and touch $DEST/refresh-added
#   refresh only the refreshInterval part of `set` (settings already wired)
#   restore set statusLine.command to $BASE_CMD, or drop statusLine if empty;
#           drop refreshInterval if $DEST/refresh-added exists
settings_py() {
    MODE="$1" SETTINGS="$SETTINGS" TARGET="$TARGET" BASE_CMD="${BASE_CMD:-}" \
        REFRESH="$REFRESH" MARK="$DEST/refresh-added" python3 - <<'PY'
import json, os, sys

mode, path = os.environ["MODE"], os.environ["SETTINGS"]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    sys.exit(f"install-statusline: {path} is not valid JSON ({e}); fix it first")
if not isinstance(data, dict):
    sys.exit(f"install-statusline: {path} is not a JSON object")
sl = data.get("statusLine")
sl = sl if isinstance(sl, dict) else {}

if mode == "get":
    cmd = sl.get("command")
    print(cmd if isinstance(cmd, str) else "", end="")
    sys.exit(0)
if mode == "refresh-check":
    print("present" if "refreshInterval" in sl else "missing", end="")
    sys.exit(0)
mark = os.environ["MARK"]
if mode in ("set", "refresh"):
    if mode == "set":
        sl["type"] = "command"
        sl["command"] = os.environ["TARGET"]
    if "refreshInterval" not in sl:
        sl["refreshInterval"] = int(os.environ["REFRESH"])
        open(mark, "w").close()
        print("install-statusline: statusLine.refreshInterval -> %s s (the counter "
              "updates while the session is idle)" % os.environ["REFRESH"])
    elif mode == "refresh":
        sys.exit(0)
    data["statusLine"] = sl
elif mode == "restore":
    if os.path.exists(mark):
        sl.pop("refreshInterval", None)
        os.remove(mark)
    base = os.environ["BASE_CMD"]
    if base:
        sl["type"] = "command"
        sl["command"] = base
        data["statusLine"] = sl
    else:
        data.pop("statusLine", None)
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PY
}

render() {
    printf '%s' "$SAMPLE" | bash "$DEST/statusline-codex.sh"
}

install() {
    mkdir -p "$DEST"
    for f in statusline-codex.sh statusline-minimal.sh statusline-segment.sh; do
        cp "$SRC/$f" "$DEST/$f"
    done
    say "scripts copied to $DEST"

    local cur
    cur="$(settings_py get)"
    if [ "$cur" = "$TARGET" ]; then
        if [ "$(settings_py refresh-check)" = "missing" ]; then
            backup_settings
            settings_py refresh
        else
            say "status line already wired; settings.json unchanged"
        fi
    else
        if [ -n "$cur" ]; then
            printf '%s\n' "$cur" > "$DEST/base-command"
            say "previous status line kept and wrapped: $cur"
        else
            rm -f "$DEST/base-command"
            say "no previous status line; using statusline-minimal.sh"
        fi
        backup_settings
        settings_py set
        say "statusLine.command -> $TARGET"
    fi
    say "sample render (Codex idle): $(render)"
    say "done; the status line updates on the next Claude Code refresh"
}

self_test() {
    [ -f "$DEST/statusline-codex.sh" ] || die "not installed; run without arguments first"
    command -v perl >/dev/null 2>&1 || die "perl not found; cannot fake a codex process"
    local tmp pid out
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-sl-test.XXXXXX")"
    # A process whose command line is exactly `codex exec`, like a real agent,
    # without calling Codex: perl runs the file named `exec` under argv[0]=codex.
    printf 'sleep 20;\n' > "$tmp/exec"
    (cd "$tmp" && exec -a codex perl exec) &
    pid=$!
    sleep 1
    out="$(render)"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -rf "$tmp"
    say "with one fake Codex agent: $out"
    case "$out" in
        *codex:[1-9]*) say "self-test passed" ;;
        *) die "self-test failed: expected codex:N in the status line" ;;
    esac
}

uninstall() {
    local cur
    cur="$(settings_py get)"
    if [ "$cur" != "$TARGET" ]; then
        say "statusLine.command is not ours ($cur); nothing to undo"
        return 0
    fi
    BASE_CMD=""
    [ -s "$DEST/base-command" ] && BASE_CMD="$(cat "$DEST/base-command")"
    backup_settings
    BASE_CMD="$BASE_CMD" settings_py restore
    if [ -n "$BASE_CMD" ]; then say "restored: $BASE_CMD"; else say "statusLine removed"; fi
    say "scripts left in $DEST; delete the folder by hand if you want"
}

case "${1:-}" in
    "") install ;;
    --self-test) self_test ;;
    --uninstall) uninstall ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown argument: $1" ;;
esac
