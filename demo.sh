#!/bin/bash
# claude-codex-bridge demo: one real run, end to end, on a throwaway repo.
#
# What happens: a tiny Python repo with a planted bug is created. Codex reviews
# it read-only through the second-opinion skill and reports the bug as a
# finding. Then a Codex worker fixes it in an isolated git worktree and the
# patch is shown. Nothing is applied.
#
# Time: one to two minutes at effort medium (measured 51 s). Cost: two Codex
# requests (one review, one worker run).
# Requires: codex (logged in), git, python3.
#
# Usage:
#   bash demo.sh                # review + worker
#   bash demo.sh --review-only  # review only, one request
#   bash demo.sh --keep         # keep the demo repo and outputs for inspection
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SO="$ROOT/skills/second-opinion/scripts/second-opinion.sh"
CW="$ROOT/skills/codex-worker/scripts/codex-worker.sh"

REVIEW_ONLY=0
KEEP=0
for a in "$@"; do
  case "$a" in
    --review-only) REVIEW_ONLY=1 ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'demo: unknown argument: %s\n' "$a" >&2; exit 2 ;;
  esac
done
for t in codex git python3; do
  command -v "$t" >/dev/null 2>&1 || { printf 'demo: %s not found on PATH\n' "$t" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/codex-bridge-demo.XXXXXX")"
REPO="$WORK/repo"
OUT="$WORK/out"
mkdir -p "$REPO/tests" "$OUT"

# --- 1. A repo with a planted bug --------------------------------------------
cat > "$REPO/pricing.py" <<'PY'
"""Pricing helpers."""


def apply_discount(price: float, pct: float) -> float:
    """Return the price after a discount.

    pct is a percentage between 0 and 100 (10 means ten percent off).
    """
    return price * (1 - pct)
PY
: > "$REPO/tests/__init__.py"
cat > "$REPO/tests/test_pricing.py" <<'PY'
import unittest

from pricing import apply_discount


class DiscountTests(unittest.TestCase):
    def test_ten_percent(self):
        self.assertAlmostEqual(apply_discount(100.0, 10), 90.0)

    def test_zero(self):
        self.assertAlmostEqual(apply_discount(80.0, 0), 80.0)


if __name__ == "__main__":
    unittest.main()
PY
G=(git -C "$REPO" -c user.name=demo -c user.email=demo@example.com -c commit.gpgsign=false)
git -C "$REPO" init -q
"${G[@]}" add -A
"${G[@]}" commit -q -m "Add pricing with a planted bug"

printf '\nDemo repo: %s\n' "$REPO"
printf 'Planted bug: apply_discount treats pct as a fraction; docstring and tests say percent.\n'
printf 'Tests before the fix:\n'
(cd "$REPO" && python3 -m unittest discover -s tests -t . 2>&1 | tail -3 | sed 's/^/  /') || true

START="$(date +%s)"

# --- 2. Codex reviews, read-only ---------------------------------------------
printf '\n== Step 1 of 2: second-opinion (Codex reads pricing.py in a read-only sandbox)\n'
printf 'Progress lines below come from Codex events as they happen.\n\n'
REVIEW_EXIT=0
bash "$SO" --repo "$REPO" --file pricing.py --file tests/test_pricing.py \
  --label demo --effort medium --out-dir "$OUT" \
  --focus "Check apply_discount against its docstring and against tests/test_pricing.py. Wrong numeric results are P1. Write the report in English." \
  > "$OUT/review.stdout" || REVIEW_EXIT=$?
if [ "$REVIEW_EXIT" -ne 0 ]; then
  printf 'demo: second-opinion exited %s; see %s and the log path in %s\n' "$REVIEW_EXIT" "$OUT/review.stdout" "$OUT" >&2
  exit "$REVIEW_EXIT"
fi
REVIEW_JSON="$(sed -n 's/^json: //p' "$OUT/review.stdout" | head -1)"
printf '\nWhat Codex returned (%s):\n' "$REVIEW_JSON"
python3 - "$REVIEW_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  verdict: {d['verdict']}   findings: {len(d['findings'])}")
for f in d["findings"]:
    print(f"  [{f['severity']}] {f['location']}  {f['title']}  (confidence {f['confidence']})")
print(f"  coverage: {d['coverage'][:200]}")
PY
printf 'Prompt sent to Codex: %s\n' "$(sed -n 's/^prompt: //p' "$OUT/review.stdout" | head -1)"
printf 'Event log:             %s\n' "$(sed -n 's/^events: //p' "$OUT/review.stdout" | head -1)"

if [ "$REVIEW_ONLY" -eq 1 ]; then
  printf '\nDone in %ss (review only).\n' "$(( $(date +%s) - START ))"
  if [ "$KEEP" -eq 0 ]; then rm -rf "$WORK"; else printf 'Kept: %s\n' "$WORK"; fi
  exit 0
fi

# --- 3. A Codex worker fixes it in a worktree --------------------------------
printf '\n== Step 2 of 2: codex-worker (Codex edits a copy in git worktree, sandbox workspace-write)\n\n'
WORKER_EXIT=0
bash "$CW" --repo "$REPO" --label demo-fix --effort medium --out-dir "$OUT" \
  --task "apply_discount in pricing.py treats pct as a fraction, but its docstring and tests/test_pricing.py define pct as a percentage from 0 to 100. Fix the function so that 'python3 -m unittest discover -s tests -t .' passes. Do not change the tests. Report the exact verification command and its result. Write the report in English." \
  --context pricing.py --context tests/test_pricing.py \
  > "$OUT/worker.stdout" || WORKER_EXIT=$?
if [ "$WORKER_EXIT" -ne 0 ]; then
  printf 'demo: codex-worker exited %s; see %s\n' "$WORKER_EXIT" "$OUT/worker.stdout" >&2
  exit "$WORKER_EXIT"
fi
WORKER_JSON="$(sed -n 's/^json: //p' "$OUT/worker.stdout" | head -1)"
PATCH="$(sed -n 's/^patch: //p' "$OUT/worker.stdout" | head -1)"
printf '\nWhat the worker returned (%s):\n' "$WORKER_JSON"
python3 - "$WORKER_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  status: {d['status']}")
print(f"  summary: {d['summary']}")
for v in d.get("verification", []):
    print(f"  verification: {v['command']}  ->  {v['result']}")
for a in d.get("assumptions", []):
    print(f"  assumption: {a}")
PY
if [ -n "$PATCH" ] && [ -s "$PATCH" ]; then
  printf '\nPatch (%s), checked against the original repo, NOT applied:\n' "$PATCH"
  git -C "$REPO" apply --check "$PATCH" && git -C "$REPO" apply --stat "$PATCH" | sed 's/^/  /'
  printf '\nThe diff itself:\n'
  sed 's/^/  /' "$PATCH"
  printf '\nTo apply it yourself: git -C %s apply %s\n' "$REPO" "$PATCH"
else
  printf '\nThe worker produced no patch.\n'
fi

printf '\nDone in %ss.\n' "$(( $(date +%s) - START ))"
if [ "$KEEP" -eq 0 ]; then
  bash "$CW" --cleanup --label demo-fix --repo "$REPO" --out-dir "$OUT" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  printf 'Demo files removed. Run with --keep to inspect prompts, events and outputs.\n'
else
  printf 'Kept: %s\n' "$WORK"
fi
