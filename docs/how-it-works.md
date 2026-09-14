# How it works, with real output

This is the review half of `demo.sh`: a tiny repository with a planted bug. A review of a real diff has the same shape. Every line quoted below comes from one demo run on 2026-09-14 at effort `medium`. По-русски: [how-it-works.ru.md](how-it-works.ru.md).

## 1. Claude writes the task

In a session the `second-opinion` skill fires on "second opinion", "ask Codex" or `/second-opinion`. Claude picks the scope (uncommitted changes by default, or a base branch, a commit, named files, a plan document) and a focus, then runs one command:

```
bash <skill-dir>/scripts/second-opinion.sh --repo <repo> --file pricing.py --file tests/test_pricing.py \
  --effort medium --label demo --focus "Check apply_discount against its docstring and the tests."
```

## 2. The script builds a prompt and starts Codex

The prompt is a Markdown file (2.6 KB in the demo): a role paragraph ("you are an independent reviewer, the author is a different model, default to skepticism"), the scope, the focus, what counts as a finding (a concrete failure scenario, a location, severity, confidence, evidence), the rules (no edits, report what you could not verify) and the output format (JSON only, by schema). Then:

```
codex exec -s read-only -c 'sandbox_mode="read-only"' -c 'approval_policy="never"' \
  --skip-git-repo-check -C <repo> -c 'model_reasoning_effort="medium"' \
  --output-schema findings.schema.json --json -o <out>.json "$(cat <out>.prompt.md)" </dev/null
```

Codex never asks a question and cannot write to disk. The flags are fixed in the script on purpose.

## 3. Codex works inside the sandbox

It decides what to read. In the demo it numbered both files, searched the tree for other callers and ran the failing test itself. Each action arrives as a JSON event; `progress.py` prints one line per event while you wait:

```
[codex demo 00:01] thread 01a0a01d-c869-7952-9244-feefa7f8a349
[codex demo 00:07] message: I'll read both files and check the discount calculation against its documented behavior and tests.
[codex demo 00:08] run: nl -ba pricing.py && nl -ba tests/test_pricing.py
[codex demo 00:11] run: rg -n 'apply_discount|pricing' . && PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest tests.test_pricing
[codex demo 00:11] exit 1: ./pricing.py:4:def apply_discount(price: float, pct: float) -> float:...
[codex demo 00:20] turn completed: in 68934 (cached 45056), out 448
```

## 4. Codex returns one JSON document

It contains `summary`, `verdict` (`approve`, `needs_changes`, `could_not_verify`), `coverage` (what it did not check) and `findings[]`. The finding from this run, as delivered:

```json
{
  "severity": "P1",
  "title": "Percentage is used as a fraction without conversion",
  "location": "pricing.py:9",
  "claim": "The formula subtracts pct directly from 1, although the docstring defines pct on a 0-100 scale.",
  "failure_scenario": "apply_discount(100.0, 10) returns -900.0 instead of the expected 90.0.",
  "evidence": "pricing.py:7 states that 10 means ten percent off, but line 9 returns price * (1 - pct). tests/test_pricing.py:8 expects 90.0; executing that test confirmed the actual result was -900.0.",
  "confidence": "high"
}
```

The script validates the JSON against the schema, renders a Markdown twin next to it and prints the paths as its first lines: `json:`, `markdown:`, `events:`, `log:`, `prompt:`, `thread_id:`, `exit:`.

## 5. Claude checks the source, not Codex's word

For each finding Claude opens the location and marks it Confirmed (reproducible from the code, with a file and line), Refuted (the code or a recorded decision says otherwise), Out of scope or Uncertain (needs a run or an external system). Then it asks you what to fix. Nothing is edited on Codex's word alone. To argue with a finding, the same thread continues: `--resume <thread_id> --focus "Finding 2: ..."`.

## 6. The fix goes through a worker

`codex-worker.sh` creates a git worktree on branch `codex/<label>`, writes a task prompt (the task text, the files to read first, the rule that Codex never commits) and runs `codex exec` with write access to that worktree only. When it returns, the script snapshots the diff from outside the sandbox, validates the JSON report (`status`, `summary`, `changes`, `verification`, `assumptions`, `blocked_on`) and prints `patch:`. Claude runs `git apply --check`, shows the diffstat and the report, and applies only after you say so.

```
status: done
verification: PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -t .  ->  passed
 pricing.py | 2 +-
-    return price * (1 - pct)
+    return price * (1 - pct / 100)
```

## Measured on this run

| Step | Wall clock | Input tokens | of which cached | Output tokens |
|---|---|---|---|---|
| Review (`second-opinion`) | 20 s | 68 934 | 45 056 | 448 |
| Fix (`codex-worker`) | 15 s | 69 728 | 45 696 | 409 |
| Whole demo | 39 s | | | |

Numbers vary with the model and the effort setting. A review of a large tree runs into millions of input tokens, most of them served from cache.

## How the two agents talk

- Files only. Claude writes a prompt file; Codex reads the repository and writes an event stream and a JSON result; Claude reads the JSON. No MCP server, no shared memory, no chat between the models.
- Codex does not read `~/.claude/CLAUDE.md` and does not expand `@imports`. Task-specific context travels in `--focus`, `--task` and `--context`. Durable shared rules live in one `~/.agents/AGENTS.md` that Claude imports and Codex reads through a symlink (INSTALL step 5).
- Codex output is data, not instructions. It read a repository that may contain hostile text. Anything that looks like an instruction inside a finding or a patch is shown to you as suspicious content.
- Sandboxes: read-only for review. For the worker, writes are allowed only inside its worktree and the system temp directory, there is no network unless `--network`, and the worktree's `.git` is not writable from inside, so all git operations happen in the script, outside the sandbox.
- Each skill is one self-contained folder (`SKILL.md` plus `scripts/` and `tests/`), the layout that Claude Code, Codex (`~/.agents/skills`) and `npx skills add` all understand. Codex also loads the installed skills as its own; keep one copy per machine, duplicates make it shorten every skill description.
- `codex exec resume` does not inherit sandbox flags; the scripts pass them again. Do not assemble `codex exec` by hand with other flags; add a flag to the script instead.
