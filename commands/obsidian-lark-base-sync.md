---
description: Sync vault structured data to/from Lark Base (bitable) - tasks, projects, persons as database records
category: meta
triggers_en: ["sync to lark base", "push tasks to lark base", "pull from lark base", "lark base sync", "sync projects to lark base", "sync persons to lark base", "lark bitable sync"]
---

Use the obsidian-second-brain skill. Execute `/obsidian-lark-base-sync $ARGUMENTS`:

Syncs structured vault notes (tasks, projects, person notes, decisions) to Lark Base (bitable) as database records using `scripts/lark-base-sync.ps1`.
Local vault is the primary source of truth; Lark Base is the sync target.
State is tracked in `.lark-base-sync.json` at the vault root.

Supported sub-commands (passed as ARGUMENTS):

| Sub-command | What it does |
|---|---|
| (none) or `status` | Show pending pushes, modified records, and items in sync per table |
| `init` | First-time setup: create Base tables for tasks, projects, persons, and decisions |
| `push tasks` | Push all vault task notes to the Tasks table in Lark Base |
| `push projects` | Push all vault project notes to the Projects table |
| `push persons` | Push all vault person notes to the Persons table |
| `push decisions` | Push all vault decision notes to the Decisions table |
| `push` | Push all changed vault notes across all four tables |
| `pull tasks` | Pull Lark Base task records back to vault task notes |
| `pull projects` | Pull Lark Base project records back to vault project notes |
| `pull persons` | Pull Lark Base person records back to vault person notes |
| `sync` | Bidirectional: push local changes, pull Lark Base changes, flag conflicts |

Steps:

1. Read `_CLAUDE.md` to confirm the vault root and check for a `lark_base_app_token:` field.
2. If `lark_base_app_token` is present, export it as `$env:LARK_BASE_APP_TOKEN` before running.
3. Run `pwsh -File scripts/lark-base-sync.ps1 <sub-command> [type] -VaultRoot <vault-root>` via the Bash tool from the vault root.
4. Report the result: records created/updated/pulled, conflicts flagged, or table status summary.

First-time setup: if no `.lark-base-sync.json` exists, ask the user for their Lark Base app token (or offer to create a new Base), then run `init` to create the four tables with the correct field schemas.

Field mapping by note type:

| Note type | Lark Base table | Key fields synced |
|---|---|---|
| `type: task` | Tasks | title, status, priority, due, project, assignee, tags |
| `type: project` | Projects | title, status, started, deadline, stack, tags |
| `type: person` | Persons | name, role, org, email, strength, tags |
| `type: decision` | Decisions | title, date, decision, outcome, project, tags |

Conflict resolution: when `sync` reports conflicts (both sides changed since last sync), ask the user which version to keep, then use `push <type>` or `pull <type>` to resolve.

---

**AI-first rule:** Every note created or updated by this command MUST follow `references/ai-first-rules.md` - `## For future Claude` preamble, rich frontmatter (`type`, `date`, `tags`, `ai-first: true`, plus type-specific fields), recency markers per external claim, mandatory `[[wikilinks]]` for every person/project/concept referenced, sources preserved verbatim with URLs inline, and confidence levels where applicable. The vault is for future-Claude retrieval - not human reading.

**Anti-fabrication:** Search exhaustively before claiming any note, person, or file is absent - false absence is the most common failure mode - and never invent facts, entities, or dates (mark unknowns as `TBD`). See the anti-fabrication and search-completeness hard rules in `references/ai-first-rules.md`.
