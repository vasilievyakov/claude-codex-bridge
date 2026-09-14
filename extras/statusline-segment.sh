#!/usr/bin/env bash
# statusline-segment.sh: Codex activity segment for a Claude Code status line.
# Source this file, then call codex_statusline_segment. Works on macOS and
# Linux (procps) for any Codex install method: npm, Homebrew, downloaded binary.
#
# The function prints one of:
#   codex:N        N running `codex exec` processes (second-opinion reviewers,
#                  codex-worker workers, anything else started as `codex exec`)
#   codex:N+srv    the same, plus a plugin `codex app-server` is alive
#   codex:0+srv    only an app-server is alive
#   (nothing)      no Codex process at all; print nothing so the caller can
#                  skip the separator
#
# Detection: `pgrep -f` with the extended regex
#   ^([^ ]*/)?codex (exec|app-server)( |$)
# i.e. argv[0] must have the basename `codex` (any directory prefix or none:
# `.../vendor/<triple>/bin/codex`, `/opt/homebrew/Cellar/codex/<ver>/bin/codex`,
# a downloaded binary, plain `codex` from PATH) and the next word must be
# `exec` or `app-server`. The npm node wrapper (`node .../bin/codex.js exec`),
# `timeout 900 codex exec ...` and the skills' own bash scripts do not match:
# the real codex child is a separate process and is counted on its own.
# macOS pgrep and procps pgrep both treat the pattern as an extended regex.
#
# Usage: append the segment to an existing status line script.
#   source "$HOME/path/to/statusline-segment.sh"   # 1. load the function
#   status="Opus | ~/proj | 123.4K (61.7%)"        # 2. whatever you already build
#   codex_seg="$(codex_statusline_segment)"         # 3. "" when Codex is idle
#   [ -n "$codex_seg" ] && status+=" | $codex_seg"  # 4. append only when non-empty
#   printf '%s\n' "$status"                          # 5. print as before
#   # One-liner alternative for step 3-4: status+="${codex_seg:+ | $codex_seg}"

codex_statusline_segment() {
    command -v pgrep >/dev/null 2>&1 || return 0
    local execs servers out
    execs=$(pgrep -f '^([^ ]*/)?codex exec( |$)' 2>/dev/null | wc -l | tr -d '[:space:]')
    servers=$(pgrep -f '^([^ ]*/)?codex app-server( |$)' 2>/dev/null | wc -l | tr -d '[:space:]')
    execs=${execs:-0}
    servers=${servers:-0}
    if [ "$execs" -eq 0 ] && [ "$servers" -eq 0 ]; then
        return 0
    fi
    out="codex:$execs"
    [ "$servers" -gt 0 ] && out+="+srv"
    printf '%s' "$out"
}

# Print the segment when run directly (bash statusline-segment.sh) for a quick check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    seg="$(codex_statusline_segment)"
    if [ -n "$seg" ]; then printf '%s\n' "$seg"; else echo "(no codex processes)"; fi
fi
