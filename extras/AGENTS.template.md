# Shared agent instructions

Read by Claude Code through `@~/.agents/AGENTS.md` in `~/.claude/CLAUDE.md` and by Codex CLI through the symlink `~/.codex/AGENTS.md` -> `~/.agents/AGENTS.md`.
Keep this file self-contained and short: Codex does not expand `@imports`, and Codex caps project docs at 32 KiB (`project_doc_max_bytes` in `~/.codex/config.toml`). Tool-specific rules live in `~/.claude/CLAUDE.md` (Claude Code) and in the Codex section below.

Note: write this file in the language you want the agents to answer in; the headings and placeholders in `<angle brackets>` are only a skeleton.

## Language
- Respond in <language>. Code, comments and commit messages in English.
- <spelling or wording rules, if any>

## Style
- Be concise. No filler, no restating the request, no explaining the obvious.
- When a decision is needed, stop and present the options with their consequences before acting.
- Do not add features, refactoring or "improvements" that were not asked for.
- Plan before implementing when a task touches 3+ files.
- Do not repeat the plan back after it is approved; execute it.

## Safety
- Never delete files without confirmation.
- Never push without confirmation.
- Never run destructive git operations (`--force`, `reset --hard`, `clean -f`) without confirmation.

## Git
- Commit messages in English, short, to the point.
- Regular push only; `--force` only when explicitly asked.

## Environment
- <os>, user `<username>`, shell `<shell>`, timezone `<timezone>`.
- <package managers, runtime versions, anything both agents must know>
- <directories the agents may act on directly, e.g. open a folder, move a file>

## Codex
Read by Codex CLI; Claude Code can ignore this section.
- Global config: `~/.codex/config.toml`. This file is reached through `~/.codex/AGENTS.md`, a symlink to `~/.agents/AGENTS.md`.
- Skills: `~/.agents/skills` (current location, shared with other agents) or `~/.codex/skills` (legacy, Codex only). Install skills in one of them, not both: duplicates make Codex shorten skill descriptions.
- Plugins: `~/.codex/plugins`.
- Update this file when the user states a new durable preference.

## Claude Code
Read by Claude Code; Codex can ignore this section.
- Codex as a second model: skill `second-opinion` (read-only review via `codex exec`), skill `codex-worker` (delegate a fully specified task to Codex in an isolated worktree; the patch is never auto-applied; several workers can run in parallel). Native Codex review and interactive delegation: the Codex plugin (`/codex:review`, `/codex:adversarial-review`, `/codex:rescue`).
- <hooks, memory rules, anything Claude Code only>
