# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this repo is

A self-hosted Resilio Sync deployment defined with Docker Compose. There is no application code to build or test. The deliverable is the Compose stack (`compose.yaml`) plus its env config (`.env.example`, and the real values in `.env`).

## Language

- **Chat replies:** answer in the language of the user's latest message. Write Vietnamese with full diacritics, even if the user types without them. Keep technical terms, commands, file names and identifiers in English (container, volume, commit, `docker compose`).
- **Everything written to the repo or GitHub is English:** docs (`AGENTS.md`, `docs/`, `GLOSSARY.md`, ADRs, `README.md`), code and config comments, commit messages, PR descriptions and GitHub issues. When the user supplies the content in Vietnamese, translate it to English before writing.
- An explicit per-request instruction from the user (e.g. "write this README in Vietnamese") overrides these defaults.

## Commands

```bash
mise install                 # install tooling from mise.toml (Node LTS + allagents CLI)
docker compose config -q     # validate compose.yaml + .env
docker compose up -d         # start the stack
docker compose ps            # status / published ports
docker compose logs --tail=50
```

In Claude Code, `/stack-check` (user-invoked, `.claude/skills/stack-check/`) runs the full health check: config, container status, logs, web UI and sync port.

## Layout and conventions

- `data/` holds the synced folders and Resilio state at runtime. It is gitignored (apart from its own `.gitignore`). Never read, modify or delete anything there, and never run `docker compose down -v` or remove volumes.
- `.env` holds secrets and is gitignored. Add every new variable to `.env.example` with a placeholder value. Don't read `.env`.
- Volume permission errors (`permission denied` on `/sync`, `/mnt/...` or config paths) usually mean a PUID/PGID mismatch with the host owner of `data/`.

## Agent tooling

`CLAUDE.md` only contains `@AGENTS.md`. Put all guidance in this file, including edits from skills that target `CLAUDE.md` (`/setup-matt-pocock-skills`, `/revise-claude-md`, the `#` shortcut).

Agent plugins are managed by [allagents](https://www.npmjs.com/package/allagents) through `.allagents/workspace.yaml`, which lists the plugins and the target clients. Per-client config (e.g. `.claude/settings.json`) is generated from it, so never edit it by hand. Add plugins with `allagents plugin install <plugin>@<marketplace> --scope project --client claude --yes`, or edit `workspace.yaml` and run `allagents update`. Both files are committed; only `.claude/settings.local.json` and `.allagents/sync-state.json` are ignored.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on ttungbmt/resilio-sync (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-label vocabulary (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
