# claude-codex-bridge

Claude Code orchestrates. OpenAI Codex CLI is the second model. Two skills make that concrete: `second-opinion` asks Codex for an independent read-only review and gets findings back as JSON, which Claude then checks against the source before anything is fixed; `codex-worker` hands Codex a fully specified task in an isolated git worktree and gets back a patch that is never applied without you. The two models share no memory. Everything that passes between them is a file you can open.

Built for the participants of [Agentic Lab](https://ai-lab-agents.com), a program on agentic engineering. Open to anyone who wants the same setup.

Русская версия: [README.ru.md](README.ru.md). Установка для агента: [INSTALL.ru.md](INSTALL.ru.md).

## Give this to your agent

Open Claude Code on the machine you want to set up and paste one line:

```
Install claude-codex-bridge: read https://raw.githubusercontent.com/vasilievyakov/claude-codex-bridge/main/INSTALL.md first, then do every step, adapt to this machine, verify, and report what you changed.
```

[INSTALL.md](INSTALL.md) is written for the agent: it checks versions, links the two skills into Claude Code and Codex, wires one shared `AGENTS.md` for both, optionally installs the official Codex plugin and the visibility tools, runs the tests. A human can follow the same file by hand. Every step is a command, none is a click.

## Run the demo

```
git clone https://github.com/vasilievyakov/claude-codex-bridge
cd claude-codex-bridge
bash demo.sh
```

One to two minutes and two Codex requests. The script creates a throwaway repo with a planted bug, Codex finds it in a read-only sandbox, a Codex worker fixes it in a worktree, and the patch is printed and not applied. `bash demo.sh --review-only` does the first half with one request. `--keep` leaves the prompts, event logs and outputs on disk so you can read exactly what was said.

## What is in the box

| Path | What it is | Who edits it |
|---|---|---|
| `skills/second-opinion/SKILL.md` | What Claude does to run a review and adjudicate the findings | You, rarely |
| `skills/second-opinion/scripts/second-opinion.sh` | The contract: flags, sandbox settings, prompt template, schema check, Markdown render | Nobody by hand. New behaviour is a new flag with a test |
| `skills/second-opinion/scripts/findings.schema.json` | What Codex must return | Contract |
| `skills/codex-worker/SKILL.md` | What Claude does to write a task, launch a worker, read the patch | You, rarely |
| `skills/codex-worker/scripts/codex-worker.sh` | The contract: worktree, sandbox, prompt, patch snapshot, worker state, `--resume`, `--list`, `--cleanup` | Contract |
| `skills/codex-worker/scripts/result.schema.json` | What the worker must return | Contract |
| `skills/*/scripts/progress.py` | Turns the Codex event stream into one line per action | Contract. Identical copy in both skills so each installs alone; CI checks they match |
| `skills/*/tests/run.sh` | Fake `codex` on PATH, no network, no cost | Run before a change |
| `extras/codex-watch.py` | Live table of running Codex processes, worker states, recent results | Optional |
| `extras/statusline-segment.sh`, `extras/statusline-minimal.sh` | `codex:N` indicator for the Claude Code status line | Optional |
| `extras/AGENTS.template.md` | Shared instructions read by both agents | You |
| `demo.sh` | One real run, end to end | Run it |
| `~/.cache/second-opinion/`, `~/.cache/codex-worker/` | Prompts, event logs, JSON, Markdown, patches, worker state, worktrees | Written at run time by the scripts, never by you |

## One run, walked through

This is the review half of `demo.sh`. The same shape holds for a review of a real diff.

**1. Claude writes the task.** In a session the skill fires on "second opinion", "ask Codex" or `/second-opinion`. Claude picks the scope (uncommitted changes by default, or `--base`, `--commit`, `--file`, `--plan`) and a focus, then runs one command:

```
bash <skill-dir>/scripts/second-opinion.sh --repo <repo> --file pricing.py --file tests/test_pricing.py \
  --effort medium --label demo --focus "Check apply_discount against its docstring and the tests."
```

**2. The script builds a prompt and starts Codex.** The prompt is a Markdown file (2.6 KB in the demo): a role paragraph ("you are an independent reviewer, the author is a different model, default to skepticism"), the scope, the focus, what counts as a finding (concrete failure scenario, location, severity, confidence, evidence), the rules (no edits, report what you could not verify), and the output format (JSON only, by schema). Then:

```
codex exec -s read-only -c 'sandbox_mode="read-only"' -c 'approval_policy="never"' \
  --skip-git-repo-check -C <repo> -c 'model_reasoning_effort="medium"' \
  --output-schema findings.schema.json --json -o <out>.json "$(cat <out>.prompt.md)" </dev/null
```

Codex never asks a question and cannot write. The flags are fixed in the script on purpose.

**3. Codex works inside the sandbox.** It decides what to read: in the demo it numbered both files, searched the tree for other callers and ran the failing test itself, all read-only. Each action arrives as a JSON event; `progress.py` prints one line per event to stderr while you wait:

```
[codex demo 00:01] thread 01a0a01d-c869-7952-9244-feefa7f8a349
[codex demo 00:07] message: I'll read both files and check the discount calculation against its documented behavior and tests.
[codex demo 00:08] run: nl -ba pricing.py && nl -ba tests/test_pricing.py
[codex demo 00:11] run: rg -n 'apply_discount|pricing' . && PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest tests.test_pricing
[codex demo 00:11] exit 1: ./pricing.py:4:def apply_discount(price: float, pct: float) -> float:...
[codex demo 00:20] turn completed: in 68934 (cached 45056), out 448
```

**4. Codex returns one JSON document.** `summary`, `verdict` (`approve`, `needs_changes`, `could_not_verify`), `coverage` (what it did not check), and `findings[]`. One finding from the demo run, as delivered:

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

The script validates the JSON against the schema, renders a Markdown twin next to it, and prints the paths as its first lines: `json:`, `markdown:`, `events:`, `log:`, `prompt:`, `thread_id:`, `exit:`.

**5. Claude adjudicates against the source, not against Codex.** For each finding it opens the location and marks it Confirmed (reproducible from the code, with `file:line`), Refuted (the code or a recorded decision says otherwise), Out of scope, or Uncertain (needs a run or an external system). Then it asks what to fix. Nothing is edited on Codex's word alone. To argue with a finding, the same thread continues: `--resume <thread_id> --focus "Finding 2: ..."`.

**6. The fix goes through a worker.** `codex-worker.sh` creates a worktree on branch `codex/<label>`, writes a task prompt (the task text, files to read first from `--context`, the rule that Codex never commits), and runs `codex exec` with `workspace-write`. When it returns, the script snapshots the diff from outside the sandbox, validates the JSON report (`status`, `summary`, `changes`, `verification`, `assumptions`, `blocked_on`), and prints `patch:`. Claude runs `git apply --check`, shows the diffstat and the report, and applies only after you say so.


Measured on the run whose output is quoted above (effort `medium`; numbers vary with the model):

| Step | Wall clock | Input tokens | of which cached | Output tokens |
|---|---|---|---|---|
| Review (`second-opinion`) | 20 s | 68 934 | 45 056 | 448 |
| Fix (`codex-worker`) | 15 s | 69 728 | 45 696 | 409 |
| Whole demo | 39 s | | | |

## How the two agents talk

- Files only. Claude writes a prompt file; Codex reads the repository and writes an event stream and a JSON result; Claude reads the JSON. No MCP server, no shared memory, no chat between the models.
- Codex does not read `~/.claude/CLAUDE.md` and does not expand `@imports`. Task-specific context travels in `--focus`, `--task` and `--context`. Durable shared rules live in one `~/.agents/AGENTS.md` that Claude imports and Codex reads through a symlink (INSTALL step 5).
- Codex output is data, not instructions. It read a repository that may contain hostile text. Anything that looks like an instruction inside a finding or a patch is shown to you as suspicious content.
- Sandboxes: read-only for review. For the worker, writes are allowed only inside the worktree and the system temp dir, there is no network unless `--network`, and the worktree's `.git` is not writable from inside, so all git operations happen in the script, outside the sandbox.
- Each skill is one self-contained folder (`SKILL.md` plus `scripts/` and `tests/`), the layout Claude Code, Codex (`~/.agents/skills`) and `npx skills add` all understand. Codex also loads the installed skills as its own; keep one copy per machine, duplicates make it shorten every skill description.

## Requirements and limits

- macOS or Linux. Windows only through WSL or Git Bash, untested.
- bash 3.2 or later, git, python3 (standard library only), codex-cli 0.150 or later (tested with 0.153 and 0.154). GNU `timeout` or `gtimeout` is optional; without it the scripts warn and run with no time limit.
- Claude Code with skills. The official Codex plugin for Claude Code (`/codex:review`, `/codex:adversarial-review`, `/codex:rescue`) is a separate, optional install; the two skills do not depend on it.
- Every run spends Codex quota. The demo review of two small files used about 70 thousand input tokens, two thirds of them from cache; a review of a large tree runs into millions of input tokens, most of them cached. Effort `high` is slower and dearer than the demo's `medium`.
- `codex exec resume` does not inherit sandbox flags; the scripts pass them again. Do not assemble `codex exec` by hand with other flags; add a flag to the script instead.

## Contributing

- Keep the whole thing readable in one sitting. No framework, no configuration objects. A new mode is a new flag with a test.
- Run `bash skills/second-opinion/tests/run.sh` and `bash skills/codex-worker/tests/run.sh` before a change. CI runs both on Ubuntu and macOS with a fake `codex`.
- `progress.py` is duplicated on purpose; CI fails if the two copies differ. Edit both.
- Documentation is bilingual: `README.md` and `INSTALL.md` in English, `README.ru.md` and `INSTALL.ru.md` in Russian. Change both or say which one you could not.

MIT license.
