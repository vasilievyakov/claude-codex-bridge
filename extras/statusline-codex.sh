#!/usr/bin/env bash
# statusline-codex.sh: the Claude Code status line command installed by
# install-statusline.sh. Shows whether Codex is running and how many agents.
#
# It runs the base status line command saved in `base-command` next to this
# file (the statusLine.command the user had before installation) with the same
# stdin JSON, and appends " | codex:N" to its last line while N `codex exec`
# processes run (" | codex:N+srv" with a plugin app-server alive). When Codex
# is idle nothing is appended. When there is no base command, it hands over to
# statusline-minimal.sh, which already ends with the same segment. When the
# base output already contains "codex:", nothing is appended twice.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -s "$here/base-command" ]; then
    exec bash "$here/statusline-minimal.sh"
fi

if [ -r "$here/statusline-segment.sh" ]; then
    # shellcheck source=statusline-segment.sh
    . "$here/statusline-segment.sh"
else
    codex_statusline_segment() { :; }
fi

input="$(cat)"
base="$(printf '%s' "$input" | bash -c "$(cat "$here/base-command")" 2>/dev/null)"

seg="$(codex_statusline_segment)"
if [ -n "$seg" ] && [[ "$base" != *codex:* ]]; then
    if [ -n "$base" ]; then base+=" | $seg"; else base="$seg"; fi
fi
printf '%s\n' "$base"
