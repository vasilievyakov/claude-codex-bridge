# Install: text for your agent

This file is written for an agent, not a shell. Open Claude Code (or Codex) on the machine you want to set up and paste everything below the line. The agent reads the environment, adapts the steps, verifies each one and reports back. A human can follow the same steps by hand; every step is a command, none is a click.

---

You are installing **claude-codex-bridge**: two skills (`second-opinion`, `codex-worker`) that let Claude Code use OpenAI Codex CLI as a second model, plus optional visibility tools. Work through the steps in order. Adapt paths to this machine. Before editing any existing config file, copy it to `<file>.bak-<YYYYMMDD>`. Never delete or overwrite user files. If a step needs a decision (for example the user already has a status line), ask. At the end, print a summary of what you changed and what you verified.

## 1. Preconditions

Check and report versions:

```
claude --version
codex --version        # expect codex-cli 0.153 or later; 0.150+ should work
git --version
python3 --version
```

If `codex` is missing: `npm i -g @openai/codex` (Node 18+) or `brew install codex`. Then `codex login` if `codex login status` says logged out. If `timeout` is missing (stock macOS), suggest `brew install coreutils`; the scripts run without it but then have no time limit.

## 2. Get the repository

```
git clone https://github.com/vasilievyakov/claude-codex-bridge ~/claude-codex-bridge
```

If the repository is already on disk, use that path and skip the clone. Call the path `$BRIDGE` below.

## 3. Install the skills for Claude Code

User scope (all projects):

```
mkdir -p ~/.claude/skills
ln -s "$BRIDGE/skills/second-opinion" ~/.claude/skills/second-opinion
ln -s "$BRIDGE/skills/codex-worker" ~/.claude/skills/codex-worker
```

Symlinks keep the skills updated with `git pull`. If the user prefers copies, `cp -R` instead. For one project only, use `<project>/.claude/skills/` instead of `~/.claude/skills/`. If a folder with the same name already exists, stop and ask.

Alternative when the `skills` CLI is available: `npx skills add vasilievyakov/claude-codex-bridge` installs both skills into the agents it detects.

## 4. Install the skills for Codex

Codex scans `~/.agents/skills` (current location) and `~/.codex/skills` (legacy). Use one of them, not both: duplicates make Codex shorten every skill description to fit its context budget.

```
mkdir -p ~/.agents/skills
ln -s "$BRIDGE/skills/second-opinion" ~/.agents/skills/second-opinion
ln -s "$BRIDGE/skills/codex-worker" ~/.agents/skills/codex-worker
```

## 5. Shared instructions for both agents

Claude Code reads `~/.claude/CLAUDE.md` and expands `@import` lines. Codex reads `~/.codex/AGENTS.md` and does not expand imports. One shared file plus a symlink covers both:

```
mkdir -p ~/.agents ~/.codex
[ -e ~/.agents/AGENTS.md ] || cp "$BRIDGE/extras/AGENTS.template.md" ~/.agents/AGENTS.md
[ -e ~/.codex/AGENTS.md ] || ln -s ~/.agents/AGENTS.md ~/.codex/AGENTS.md
```

If `~/.codex/AGENTS.md` already exists as a regular file, do not replace it; tell the user and propose merging. Then make Claude Code import the shared file: if `~/.claude/CLAUDE.md` does not contain the line `@~/.agents/AGENTS.md`, add it as the first line (create the file if missing; keep existing content).

Let Codex fall back to project `CLAUDE.md` files when a project has no `AGENTS.md`: in `~/.codex/config.toml` ensure the top-level line

```
project_doc_fallback_filenames = ["CLAUDE.md"]
```

exists (append it if absent; keep everything else). Codex caps project docs at 32 KiB.

## 6. Optional: the official Codex plugin for Claude Code

Native review and interactive delegation come from OpenAI's plugin. Check its README for current command names before running:

```
claude plugin marketplace add openai/codex-plugin-cc
claude plugin install codex@openai-codex
```

This is independent of the two skills; the skills work without it.

## 7. Optional: see Codex working

- Live table of running Codex processes and recent results: `python3 "$BRIDGE/extras/codex-watch.py"` in a separate terminal. Offer an alias.
- Status line indicator `codex:N`: if the user has a status line script (see `statusLine.command` in `~/.claude/settings.json`), add the segment from `$BRIDGE/extras/statusline-segment.sh` to it. If they have none, install `$BRIDGE/extras/statusline-minimal.sh` and set `"statusLine": {"type": "command", "command": "bash $BRIDGE/extras/statusline-minimal.sh"}` in `~/.claude/settings.json` (back the file up first). Details in `extras/README.md`.

## 8. Verify

```
bash "$BRIDGE/skills/second-opinion/tests/run.sh"
bash "$BRIDGE/skills/codex-worker/tests/run.sh"
cd <any git repo> && bash "$BRIDGE/skills/second-opinion/scripts/second-opinion.sh" --dry-run
```

The tests use a fake `codex` on PATH and cost nothing. `--dry-run` prints the exact `codex exec` command and the prompt path without running Codex. Then start a new Claude Code session and confirm the skills are listed (`/second-opinion`, `/codex-worker`). A real end-to-end check is `bash "$BRIDGE/demo.sh"` (one to two minutes, two Codex requests).

## 9. Report

List: versions found, where the skills were linked, which config files were created or edited (with backup paths), what was skipped and why, test results. Do not summarize this file back to the user.
