#!/usr/bin/env bash
# Used by docs/media/statusline.tape: installs the status line into a throwaway
# HOME on top of an existing one, starts two real Codex agents and redraws the
# status line every half second until both finish. Two Codex requests.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$(mktemp -d "${TMPDIR:-/tmp}/sl-demo.XXXXXX")"
REPO="$H/repo"
mkdir -p "$H/.claude" "$REPO"
git -C "$REPO" init -q
python3 -c 'import json,sys; json.dump({"statusLine":{"type":"command","command":"echo \"Opus | ~/my-project | 41.2K\""}}, open(sys.argv[1],"w"))' "$H/.claude/settings.json"
HOME="$H" bash "$ROOT/extras/install-statusline.sh" | sed 's#'"$H"'#~#g'
line() { printf '{}' | bash "$H/.claude/statusline/statusline-codex.sh"; }
echo
echo "starting two Codex agents..."
(cd "$REPO" && codex exec --skip-git-repo-check -s read-only "List the prime numbers below 100, comma separated." >/dev/null 2>&1) &
(cd "$REPO" && codex exec --skip-git-repo-check -s read-only "List the prime numbers below 300, comma separated, then their count." >/dev/null 2>&1) &
sleep 1
start=$SECONDS
while pgrep -f '^([^ ]*/)?codex exec( |$)' >/dev/null 2>&1; do
    printf '\r\033[K  %2ss  %s' "$((SECONDS - start))" "$(line)"
    sleep 0.5
done
printf '\r\033[K  %2ss  %s\n' "$((SECONDS - start))" "$(line)"
echo "both agents finished"
wait
rm -rf "$H"
