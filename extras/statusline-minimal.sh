#!/usr/bin/env bash
# statusline-minimal.sh: a complete minimal Claude Code status line that ends
# with the Codex segment. For users who have no status line yet.
#
# Output:   Opus 4.1 | ~/Projects/foo | 123.4K (61.7%) | codex:1
# Fields:   model.display_name | workspace.current_dir | context tokens used
#           (context_window.current_usage.input_tokens + cache_creation_input_tokens
#           + cache_read_input_tokens + output_tokens, falling back to
#           context_window.total_input_tokens + total_output_tokens) with the
#           share of context_window.context_window_size | codex segment (omitted
#           when no Codex process runs).
#
# Wire it in: add to ~/.claude/settings.json (adjust the path)
#   "statusLine": {
#     "type": "command",
#     "command": "bash ~/path/to/statusline-minimal.sh"
#   }
#
# Reads the status line JSON from stdin. Needs bash and python3, no jq.
# Sources statusline-segment.sh from the same directory. Renders in well under
# 100 ms (one python3 start plus two pgrep calls).

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$here/statusline-segment.sh" ]; then
    # shellcheck source=statusline-segment.sh
    . "$here/statusline-segment.sh"
else
    codex_statusline_segment() { :; }
fi

base="$(python3 -c '
import json, os, sys

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}


def get(obj, *keys):
    for k in keys:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(k)
    return obj


def num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) else 0


model = get(d, "model", "display_name") or "?"
cwd = get(d, "workspace", "current_dir") or os.getcwd()
home = os.path.expanduser("~")
if cwd == home or cwd.startswith(home + os.sep):
    cwd = "~" + cwd[len(home):]

cw = get(d, "context_window")
cw = cw if isinstance(cw, dict) else {}
cu = cw.get("current_usage")
if isinstance(cu, dict):
    used = (num(cu.get("input_tokens")) + num(cu.get("cache_creation_input_tokens"))
            + num(cu.get("cache_read_input_tokens")) + num(cu.get("output_tokens")))
else:
    used = num(cw.get("total_input_tokens")) + num(cw.get("total_output_tokens"))
size = num(cw.get("context_window_size"))

parts = [str(model), str(cwd)]
if used or size:
    tok = "%.1fK" % (used / 1000.0)
    if size:
        tok += " (%.1f%%)" % (100.0 * used / size)
    parts.append(tok)
sys.stdout.write(" | ".join(parts))
' 2>/dev/null)"
[ -n "$base" ] || base="?"

seg="$(codex_statusline_segment)"
printf '%s%s\n' "$base" "${seg:+ | $seg}"
