# claude-codex-bridge

[![tests](https://github.com/vasilievyakov/claude-codex-bridge/actions/workflows/tests.yml/badge.svg)](https://github.com/vasilievyakov/claude-codex-bridge/actions/workflows/tests.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-d4ff3f?labelColor=0b0b0c)](LICENSE) [![site](https://img.shields.io/badge/site-vasilievyakov.github.io%2Fclaude--codex--bridge-0b0b0c?labelColor=d4ff3f)](https://vasilievyakov.github.io/claude-codex-bridge/)

[Русская версия](README.ru.md)

claude-codex-bridge gives Claude Code a second AI: OpenAI Codex CLI, for two jobs. It looks at your code with fresh eyes, and it does a side task while you keep working. Codex runs in a sandbox and answers with files; Claude reads them, checks every claim against the code and shows you the result. Nothing in your project changes until you say yes. Your status line shows how many Codex agents are running right now. Two skills, a status line segment, bash and python3, no daemons, no services, 378 tests with a fake `codex`.

It was built by a product person working with Claude Code, and then taken apart and fixed by the same kind of review it offers: agents reviewed it, real Codex runs broke it, the human decided what counts. The paper trail is in the repository and in [How it was made](#how-it-was-made).

![bash demo.sh: Codex finds a planted bug read-only, then a Codex worker fixes it in a separate worktree and returns a patch](docs/media/demo.gif)

## What you get

| | |
|---|---|
| **Second opinion** | Say "ask Codex for a second opinion". Codex reads your uncommitted changes, a branch, named files or a plan in a read-only sandbox and returns findings in a fixed JSON format: severity, location, failure scenario, evidence, confidence. Claude opens each one in the code and marks it Confirmed, Refuted, Out of scope or Uncertain |
| **Worker** | Say "give this task to Codex". Codex does it in its own git worktree with write access to that folder only and no network, runs the checks you named and returns a patch. You see the diff and decide. Several workers can run at once |
| **Status line signal** | ` \| codex:2` at the end of your own Claude Code status line while two Codex agents run, nothing when Codex is idle. Installed by default; your status line is kept as it is, only the segment is appended |
| **Progress lines** | While Codex works, Claude's terminal shows what it does: files read, commands run, their results, token counts |
| **Live table** | `extras/codex-watch.py` in a second window: every running reviewer and worker, elapsed time, last event, newest results |
| **Paper trail** | Every run leaves its prompt, event log, answer and patch in `~/.cache/second-opinion/` or `~/.cache/codex-worker/`. The two models never talk directly; everything between them is a file you can open |

## Install

Open Claude Code and paste this line:

```
Install claude-codex-bridge: read https://raw.githubusercontent.com/vasilievyakov/claude-codex-bridge/main/INSTALL.md first, then do every step, adapt to this machine, verify, and report what you changed.
```

[INSTALL.md](INSTALL.md) is written for an agent: it reads the machine, adapts each step, verifies it and reports. It backs up every config file it edits and never overwrites yours. A human can follow the same steps; every step is a command.

What it does, in ten steps: checks versions, clones this repository, links the two skills into `~/.claude/skills`, sets up one instructions file that both agents read (`~/.agents/AGENTS.md`), installs the status line signal and runs its self-test, optionally adds the official Codex plugin and the live table, runs the tests, reports.

You need Claude Code, [Codex CLI](https://github.com/openai/codex) 0.150 or newer (tested with 0.156) with a login, git and python3. macOS or Linux.

Check it works: open a new Claude Code session and type `/second-opinion`. Or run the demo, about a minute, two Codex requests:

```
git clone https://github.com/vasilievyakov/claude-codex-bridge
cd claude-codex-bridge
bash demo.sh
```

It creates a throwaway repository with a planted bug (a percentage used as a fraction), asks Codex for a review, then gives a worker the fix. The GIF above is one such run.

## Everyday use

| You say in Claude Code | What happens | What you see |
|---|---|---|
| "Ask Codex for a second opinion on my changes" | Codex reviews your uncommitted changes, read-only | Progress lines, then a table: each finding with a verdict and the question what to fix |
| "Ask Codex to review the plan in docs/plan.md" | Same, for a document instead of a diff | Same table |
| "Ask Codex to look at src/billing.py, focus on rounding" | Same, for named files with a focus | Same table |
| "Give Codex the task: implement parse_date in src/dates.py, tests in tests/test_dates.py, run pytest" | Codex works in its own copy of the repository | Status, summary, what it ran to verify, the diff, and the question whether to apply it |
| "Argue finding 2 with Codex: there is a check on line 41" | The same Codex thread continues | Its answer |
| "Clean up the Codex worker" | Removes the worker's worktree; a branch with commits is kept | Confirmation |

Three rules of thumb. A task for the worker has to be complete: what to do, where, how to check, what not to touch; Codex does not ask questions, it assumes and lists its assumptions. Every run spends Codex quota, so ask for a review after a real change. A finding stays a claim until Claude checks it against the code, so you see them with verdicts.

## See Codex working

The installer adds one segment to the status line you already have. Here it is on a status line that printed `Opus | ~/my-project | 41.2K` before, with two real Codex agents started and finishing one after the other:

![The status line shows codex:2, then codex:1, then nothing as two real Codex agents finish](docs/media/statusline.gif)

How it works: `install-statusline.sh` saves your current `statusLine.command` to `~/.claude/statusline/base-command` and points Claude Code at `statusline-codex.sh`, which runs your command unchanged and appends ` | codex:N` while N `codex exec` processes are alive (`codex:N+srv` when the plugin's app-server runs too). Detection is `pgrep` on the process name, so it counts reviewers, workers and anything else started as `codex exec`, from npm, Homebrew or a downloaded binary. `--self-test` starts a fake `codex exec` process (no request to Codex) and expects `codex:1`; `--uninstall` puts your old command back.

For a bigger picture, run `python3 extras/codex-watch.py` in a second terminal: a top-style table of running Codex processes and the newest results.

## What happens under the hood

1. Claude writes the task into a prompt file: role, scope, focus, what counts as a finding, the output format.
2. A script starts `codex exec` with the prompt on stdin: sandbox `read-only` for a review; for a worker, `workspace-write` limited to a fresh git worktree, network off unless asked for.
3. Codex reads the code, may run the tests, and answers with JSON validated against a schema (`--output-schema`).
4. The script checks the answer, writes a Markdown twin next to it and prints the paths: `json:`, `markdown:`, `events:`, `log:`, `prompt:`, `thread_id:`, `exit:`.
5. Claude opens every finding in the code and gives its verdict. For a worker, the script snapshots the worktree into a patch file and prints the command to check that it applies.
6. Claude shows the patch and applies it only after you say so. `--resume` continues the same Codex thread when you want to argue a finding.

The full walk-through with real output from a demo run is in [docs/how-it-works.md](docs/how-it-works.md).

## Where the code is

Two skills, each one self-contained folder: instructions for Claude, a script, the answer format, tests.

```
skills/
  second-opinion/
    SKILL.md                 when and how Claude calls the review, how it judges findings
    scripts/second-opinion.sh   builds the prompt, runs codex exec read-only, validates, renders
    scripts/findings.schema.json  the answer format Codex must follow
    scripts/progress.py      turns Codex events into progress lines (same file in both skills)
    tests/run.sh             137 tests with a fake codex on PATH, no network, no cost
  codex-worker/
    SKILL.md                 how Claude writes a task, reads the result, offers the patch
    scripts/codex-worker.sh  worktree, sandbox, timeout, patch snapshot, resume, cleanup
    scripts/result.schema.json
    scripts/progress.py
    tests/run.sh             241 tests, same approach
extras/
  install-statusline.sh      the required status line step: install, --self-test, --uninstall
  statusline-codex.sh        wraps your status line and appends the Codex segment
  statusline-segment.sh      the segment itself, sourceable into any bash status line
  statusline-minimal.sh      a complete status line for those who had none
  codex-watch.py             live table of Codex processes and results
  AGENTS.template.md         one instructions file for both agents
demo.sh                      one real run on a throwaway repository
INSTALL.md, INSTALL.ru.md    the install text for your agent
docs/                        the site, the walk-through, the GIFs and their VHS tapes
.github/workflows/tests.yml  both suites and the status line installer on Ubuntu and macOS
```

Runtime output never lands in your project: `~/.cache/second-opinion/` and `~/.cache/codex-worker/` hold the prompt, the event log, the answer and the patch of every run.

## When something goes wrong

- The script prints `exit:` and `log:` paths. Read the log first; the progress lines usually show the cause already (a rejected model, a login problem, a failing command).
- Exit codes: 2 wrong arguments; 3 Codex answered outside the format, the raw answer is at the `json:` path; 4 (worker) branch or worktree already exists, change the label or clean up; 5 (review) nothing to review, the diff is empty; 124 time limit; 130 and 143 interrupted, Codex was stopped too.
- `--dry-run` prints the exact Codex command and the prompt file without running anything.
- Codex sees only what it is given: the task, the focus, the files to read, and `~/.agents/AGENTS.md`. It does not read your `~/.claude/CLAUDE.md`; a project `CLAUDE.md` only when the project has no `AGENTS.md` (install step 5 turns this fallback on). If it "did not know" something, put it into the focus or the task.
- Codex fails on the very first request: check the model in `~/.codex/config.toml`; the account you logged in with has to support it.
- Tests without Codex and without cost: `bash skills/second-opinion/tests/run.sh` and `bash skills/codex-worker/tests/run.sh`.

## How it was made

This is the part worth reading if you build tools with agents.

**Roles.** The human (Yakov) decided what the tool is for, what goes in, and what "done" means. Claude Code was the orchestrator: it wrote the scripts and the docs, dispatched subagents for review and fixes, ran the real Codex, read the logs. Codex was the subject: every claim about its flags and config keys was checked against the installed binary.

**First day, in one person's setup.** The bridge started as two private skills: a read-only reviewer that answers in a schema, and a worker in a git worktree. Then observability, because a Codex run that you cannot see feels broken: progress lines from the event stream, the `codex:N` counter, the live table.

**Second day, making it someone else's.** The form was checked against how Andrej Karpathy ships small repositories: the installer is text for an agent, with no branching shell script; the repository is small enough to read in one sitting; one command on an empty machine shows the whole thing (`demo.sh`); one real run is taken apart step by step (`docs/how-it-works.md`). The skills were rewritten in English with paths relative to their folder, the tests moved to a fake `codex` so CI runs them on Ubuntu and macOS for free, and the site went up. The first README started from the architecture; the human read it and said nobody would understand it and it had to be much simpler. It was rewritten as a map: what you say, what happens, what you see.

**A week later, the review.** The human asked for two things: put the Codex signal into the status line at install, always, and finish the repository so anyone can use it. The condition for the status line: do not move the whole status line, only add this piece. That rules out rewriting the user's script, so the installer wraps the existing command instead, and it can be undone.

A read-only review subagent then went through the repository as a newcomer would. It came back with five defects that would break the tool for other people and fifteen smaller ones. Another subagent fixed the scripts test-first, while the orchestrator fixed the docs; the two never touched the same file.

**What the reviews and the real runs caught.** A sample, all in the git history:

- Ctrl-C stopped the script but not Codex. GNU `timeout` moves itself into its own process group and background jobs in a non-interactive bash ignore SIGINT, so Codex kept working, and spending quota, for up to 30 minutes. Both scripts now trap INT, TERM and HUP, stop Codex and record `interrupted`.
- The install text used `$BRIDGE` and never assigned it. Every Bash call in Claude Code starts with a fresh environment, and `ln -s` does not check its target, so the skills were silently linked to `/skills/...`. Each command block now starts with the assignment and the links are verified.
- "Append this line to `~/.codex/config.toml`" is wrong for TOML: a line lands inside the last `[table]` of the file. The instruction now inserts it above the first table.
- The template for the shared instructions file was copied with its placeholders, so both agents would read `Respond in <language>` literally. Now every placeholder is asked for, and a `grep` proves none remains.
- The skills were also installed into Codex, where they would start Codex inside Codex's own sandbox, without network, and the "second opinion" would come from the same model. That step is gone.
- The prompt went to Codex as one command-line argument: visible to anyone running `ps`, and on Linux capped at 128 KiB per argument. It goes through stdin now.
- Codex had moved web search from `tools.web_search` to a top-level `web_search = "live"`, and a model alias pointed at a model that no longer exists. Both were checked against Codex 0.156 itself.
- A review of an empty diff still spent a request. It now exits with code 5 before calling Codex.
- The real demo showed what the tests did not: the worker's patch carried binary `__pycache__/*.pyc` files: the throwaway repository had no `.gitignore`, and the worker ran the tests. The worker respects `.gitignore`, so the demo got one.
- The real demo also failed on the first request for a reason no test can catch: the model named in the local Codex config was not available to the account. The progress lines showed the error within four seconds, which is the argument for having them.

The status line was tested the same way: a fake `codex exec` process (`exec -a codex perl exec`, no request, no cost) for the self-test and CI, then two real Codex agents for the proof in the GIF above.

**What to take from it.** Handing a tool over is work of its own: most defects were in the install text. A review is worth what its findings survive: every finding was checked against the code or reproduced before anything changed. And a real run finds what tests cannot: a model the account does not have, a cache directory in a patch.

## Agentic Lab

claude-codex-bridge is a case study from [Agentic Lab](https://ai-lab-agents.com), a laboratory on using AI agents in business, run by Dmitry Soloveev and Yakov Vasiliev. Participants go from chatting with a model to building agent systems that carry a task end to end: their own project, data pipelines, quick services and interfaces, with Claude Code, Codex and Cursor as the daily tools.

This repository shows one working pattern in full: two models from two companies, one orchestrating and one reviewing or executing, with files between them and a human deciding. Install it, run the demo, read the scripts.

## Contributing

Keep it small enough to read in one sitting. A new mode is a new flag with a test. Run both test suites before a change; CI runs them with a fake `codex` on Ubuntu and macOS, plus the status line installer in a throwaway HOME. `progress.py` is copied into both skills on purpose, edit both (CI compares them). Docs come in English and Russian, change both. The GIFs are rendered with [VHS](https://github.com/charmbracelet/vhs) from `docs/media/*.tape`.

## License

MIT.
