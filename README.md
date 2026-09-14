# claude-codex-bridge

[![tests](https://github.com/vasilievyakov/claude-codex-bridge/actions/workflows/tests.yml/badge.svg)](https://github.com/vasilievyakov/claude-codex-bridge/actions/workflows/tests.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-d4ff3f?labelColor=0b0b0c)](LICENSE) [![site](https://img.shields.io/badge/site-vasilievyakov.github.io%2Fclaude--codex--bridge-0b0b0c?labelColor=d4ff3f)](https://vasilievyakov.github.io/claude-codex-bridge/)

You work in Claude Code. This adds a second AI, OpenAI Codex, for two jobs: look at your code with fresh eyes, and do a side task while you keep working. Codex runs in a sandbox and answers with files. Claude reads those files and shows you the result. Nothing in your project changes until you say yes.

Made for the participants of [Agentic Lab](https://ai-lab-agents.com). Open to everyone.

Site: [vasilievyakov.github.io/claude-codex-bridge](https://vasilievyakov.github.io/claude-codex-bridge/). По-русски: [README.ru.md](README.ru.md).

## What you get

- **A second opinion.** Say "ask Codex for a second opinion" in Claude Code. Codex reads your changes without touching them and returns a list of problems, each with a file and line. Claude checks every item against the code and tells you which ones are real. Twenty seconds in the demo.
- **A worker.** Say "give this task to Codex". Codex does it in a separate copy of your repository and returns a patch. You see the diff and decide. Several workers can run at once.
- **You can watch.** Progress lines in the terminal while Codex works, a `codex:N` counter in the status line, a live table in a second window.

## Install

Open Claude Code on your machine and paste this line:

```
Install claude-codex-bridge: read https://raw.githubusercontent.com/vasilievyakov/claude-codex-bridge/main/INSTALL.md first, then do every step, adapt to this machine, verify, and report what you changed.
```

The agent installs everything and reports what it changed. It never overwrites your files. To do it by hand, follow [INSTALL.md](INSTALL.md); every step is a command.

Check: open a new Claude Code session and type `/second-opinion`. Or run the demo, one to two minutes, two Codex requests:

```
git clone https://github.com/vasilievyakov/claude-codex-bridge
cd claude-codex-bridge
bash demo.sh
```

You need Claude Code, [Codex CLI](https://github.com/openai/codex) 0.150 or newer with a login, git and python3. macOS or Linux.

## How to use it day to day

| You say in Claude Code | What happens | What you see |
|---|---|---|
| "Ask Codex for a second opinion on my changes" | Codex reviews your uncommitted changes, read-only | Progress lines, then a table: each finding with a verdict (Confirmed, Refuted, Out of scope, Uncertain) and the question what to fix |
| "Ask Codex to review the plan in docs/plan.md" | Same, for a document instead of a diff | Same table |
| "Ask Codex to look at src/billing.py, focus on rounding" | Same, for named files with a focus | Same table |
| "Give Codex the task: implement parse_date in src/dates.py, tests in tests/test_dates.py, run pytest" | Codex works in its own copy of the repo | Status, summary, what it ran to verify, the diff, and the question whether to apply it |
| "Argue finding 2 with Codex: there is a check on line 41" | The same Codex thread continues | Its answer |
| "Clean up the Codex worker" | Removes the worker's copy | Confirmation |

Two rules of thumb. A task for the worker has to be complete: what to do, where, how to check, what not to touch. Codex does not ask questions, it assumes and lists its assumptions. And every run spends Codex quota, so ask for a review after a real change, not after every typo.

## What happens under the hood

1. Claude writes a task into a text file.
2. A script starts Codex in a sandbox: read-only for a review, write access to one separate copy for a worker.
3. Codex reads the code, may run the tests, and answers with a JSON file in a fixed format.
4. The script checks the answer, saves it next to the log, and prints the paths.
5. Claude opens every finding in the code and marks it real or not.
6. A fix comes back as a patch. Claude shows it and applies it only after you say so.

The two models never talk to each other. Everything between them is a file you can open. The full walk-through with real output from the demo run is in [docs/how-it-works.md](docs/how-it-works.md).

## Where things are

| Folder | What is inside |
|---|---|
| `skills/second-opinion/` | The review skill: instructions for Claude, the script, the answer format, tests |
| `skills/codex-worker/` | The worker skill: same shape |
| `extras/` | Optional: live table of Codex processes, status line counter, a template for one instructions file both agents read |
| `demo.sh` | One real run on a throwaway repo |
| `INSTALL.md`, `INSTALL.ru.md` | The install text for your agent |
| `docs/` | The site and the detailed walk-through |
| `~/.cache/second-opinion/`, `~/.cache/codex-worker/` | Everything a run produced: prompt, log, answer, patch. Written by the scripts, not by you |

## When something goes wrong

- The script prints `exit:` and `log:` paths. Read the log first.
- Exit code 2: wrong arguments. 3: Codex answered outside the format, the raw answer is at the `json:` path. 4 (worker only): branch or worktree already exists, change the label or clean up. 124: time limit.
- `--dry-run` prints the exact Codex command and the prompt without running anything.
- Codex sees only what it is given: the task, the focus, the files to read, and the shared `~/.agents/AGENTS.md`. It does not read `CLAUDE.md`. If it "did not know" something, put it into the focus or the task.
- Tests without Codex and without cost: `bash skills/second-opinion/tests/run.sh` and `bash skills/codex-worker/tests/run.sh`.

## Contributing

Keep it small enough to read in one sitting. A new mode is a new flag with a test. Run both test suites before a change; CI runs them on Ubuntu and macOS with a fake `codex`. `progress.py` is copied into both skills on purpose, edit both. Docs come in English and Russian, change both.

MIT license.
