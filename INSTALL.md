# Install: text for your agent

This file is written for an agent, not a shell. Open Claude Code (or Codex) on the machine you want to set up and paste everything below the line. The agent reads the environment, adapts the steps, verifies each one and reports back. A human can follow the same steps by hand; every step is a command, none is a click.

---

You are installing **claude-codex-bridge**: two skills (`second-opinion`, `codex-worker`) that let Claude Code use OpenAI Codex CLI as a second model, plus a Codex signal in the Claude Code status line and optional visibility tools. Work through the steps in order. Adapt paths to this machine. Before editing any existing config file, copy it to `<file>.bak-<YYYYMMDD>`. Never delete or overwrite user files. If a step needs a decision, ask. At the end, print a summary of what you changed and what you verified.

## 1. Preconditions

Check and report versions:

```
claude --version
codex --version        # expect codex-cli 0.150 or later (tested with 0.156)
git --version
python3 --version
```

On a fresh Mac, `git` and `python3` are stubs until the Xcode Command Line Tools are installed: if `git --version` opens an install dialog or fails, run `xcode-select --install` and wait for it to finish. Accounts: Claude Code needs a Pro, Max, Team, Enterprise or Console account; Codex needs a ChatGPT plan that includes Codex or an OpenAI API key (`codex login --with-api-key`). If the user has no OpenAI access, stop and say so: the bridge cannot work without it. On native Windows (not WSL) stop too: the scripts need bash and `pgrep`; WSL 2 should work as Linux but is untested, say so. If `codex` is missing: `npm i -g @openai/codex` (Node 18+) or `brew install codex`. Then `codex login` if `codex login status` says logged out. If `timeout` is missing (stock macOS), suggest `brew install coreutils`; the scripts run without it but then have no time limit.

## 2. Get the repository

```
git clone https://github.com/vasilievyakov/claude-codex-bridge ~/claude-codex-bridge
```

If the repository is already on disk, use that path and skip the clone. Below, `$BRIDGE` means this path. Shell variables do not survive between separate commands (in Claude Code every Bash call starts fresh), so start every command block below with the assignment, for example:

```
BRIDGE="$HOME/claude-codex-bridge"
test -f "$BRIDGE/skills/second-opinion/SKILL.md" && echo ok
```

## 3. Install the skills for Claude Code

User scope (all projects):

```
mkdir -p ~/.claude/skills
ln -s "$BRIDGE/skills/second-opinion" ~/.claude/skills/second-opinion
ln -s "$BRIDGE/skills/codex-worker" ~/.claude/skills/codex-worker
```

Check the links resolve: `test -f ~/.claude/skills/second-opinion/SKILL.md && test -f ~/.claude/skills/codex-worker/SKILL.md && echo ok` (`ln -s` does not check its target, so an empty `$BRIDGE` makes a broken link silently). Symlinks keep the skills updated with `git pull`. If the user prefers copies, `cp -R` instead. For one project only, use `<project>/.claude/skills/` instead of `~/.claude/skills/`. If a folder with the same name already exists, stop and ask.

Alternative when the `skills` CLI is available: `npx skills add vasilievyakov/claude-codex-bridge` installs both skills into the agents it detects; if it also puts them into Codex, remove those copies (see step 4).

## 4. Codex: do not install the skills there

The skills are for Claude Code: they start `codex exec` as a second model. Do not link them into Codex's skill folders (`~/.agents/skills`, `~/.codex/skills`). Called from inside Codex they would start Codex inside Codex's own sandbox, where the network and `~/.cache` are closed by default, and the "second opinion" would come from the same model. If the user already has them linked there, tell them and propose removing the links.

## 5. Shared instructions for both agents

Claude Code reads `~/.claude/CLAUDE.md` and expands `@import` lines. Codex reads `~/.codex/AGENTS.md` and does not expand imports. One shared file plus a symlink covers both:

```
mkdir -p ~/.agents ~/.codex
[ -e ~/.codex/AGENTS.md ] || ln -s ~/.agents/AGENTS.md ~/.codex/AGENTS.md
```

If `~/.agents/AGENTS.md` does not exist, create it from `$BRIDGE/extras/AGENTS.template.md`: ask the user for every `<...>` placeholder and write their answers in; no placeholder may remain (`grep -n '<[^>]*>' ~/.agents/AGENTS.md` must print nothing). If the user does not want to answer, keep only the Codex and Claude Code sections of the template. If `~/.codex/AGENTS.md` already exists as a regular file, do not replace it; tell the user and propose merging. Then make Claude Code import the shared file: if `~/.claude/CLAUDE.md` does not contain the line `@~/.agents/AGENTS.md`, add it as the first line (create the file if missing; keep existing content).

Let Codex fall back to project `CLAUDE.md` files when a project has no `AGENTS.md`: in `~/.codex/config.toml` ensure the top-level line

```
project_doc_fallback_filenames = ["CLAUDE.md"]
```

exists. TOML scopes every line to the last `[table]` header above it, so do not append it at the end of the file: insert it above the first line that starts with `[` (or at the end only if the file has no tables); keep everything else. Then run `codex --version` and a `codex exec --help` to make sure the config still parses. Codex caps project docs at 32 KiB.

## 6. Status line: Codex signal (required)

The Claude Code status line must show when Codex agents run and how many: ` | codex:2` while two run, nothing when Codex is idle. Install it with the script, do not edit the user's status line by hand:

```
bash "$BRIDGE/extras/install-statusline.sh"
bash "$BRIDGE/extras/install-statusline.sh" --self-test
```

The installer keeps the user's current status line exactly as it is: it saves its command, wraps it and appends only the Codex segment to its output. With no status line it installs a minimal one (`model | dir | tokens | codex:N`). It backs up `~/.claude/settings.json` first and changes only `statusLine.command`, plus `statusLine.refreshInterval` (2 seconds) when the user has none: without it the counter freezes while the session waits for Codex. Running it twice is safe. `--self-test` starts a fake `codex exec` process (no request to Codex) and must print `self-test passed`. If the user's status line already prints `codex:`, the segment is not added twice. Undo: `bash "$BRIDGE/extras/install-statusline.sh" --uninstall`.

## 7. Optional: the official Codex plugin for Claude Code

Native review and interactive delegation come from OpenAI's plugin. Check its README for current command names before running:

```
claude plugin marketplace add openai/codex-plugin-cc
claude plugin install codex@openai-codex
```

This is independent of the two skills; the skills work without it.

## 8. Optional: live table of Codex agents

Live table of running Codex processes and recent results: `python3 "$BRIDGE/extras/codex-watch.py"` in a separate terminal. Offer an alias.

## 9. Verify

```
bash "$BRIDGE/skills/second-opinion/tests/run.sh"
bash "$BRIDGE/skills/codex-worker/tests/run.sh"
cd <any git repo> && bash "$BRIDGE/skills/second-opinion/scripts/second-opinion.sh" --dry-run
```

The tests use a fake `codex` on PATH and cost nothing. `--dry-run` prints the exact `codex exec` command and the prompt path without running Codex. Then start a new Claude Code session and confirm the skills are listed (`/second-opinion`, `/codex-worker`). A real end-to-end check is `bash "$BRIDGE/demo.sh"` (one to two minutes, two Codex requests).

## 10. Report

List: versions found, where the skills were linked, the status line self-test result, which config files were created or edited (with backup paths), what was skipped and why, test results. Do not summarize this file back to the user.
