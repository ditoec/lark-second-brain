---
description: Sync vault kanban tasks and assignments to/from Lark Tasks - push, pull, or bidirectional with assignee resolution
category: meta
triggers_en: ["sync tasks to lark", "push tasks to lark", "pull lark tasks", "lark tasks sync", "sync assignments to lark", "lark task sync", "sync kanban to lark", "push assignments to lark"]
---

Use the obsidian-second-brain skill. Execute `/obsidian-lark-tasks-sync $ARGUMENTS`:

Syncs vault task notes and kanban board items to/from Lark Tasks using `scripts/lark-tasks-sync.ps1`.
Local vault is the primary source of truth; Lark Tasks is the sync target.
State is tracked in `.lark-tasks-sync.json` at the vault root.

Supported sub-commands (passed as ARGUMENTS):

| Sub-command | What it does |
|---|---|
| (none) or `status` | Show unsynced tasks, modified tasks, and Lark tasks not yet in vault |
| `push` | Push all locally changed vault tasks to Lark Tasks |
| `push <relative-path>` | Push a single task note |
| `pull` | Pull all tracked Lark Tasks back to vault |
| `pull <task-guid>` | Pull one Lark task by its GUID |
| `sync` | Bidirectional: push local changes, pull Lark changes, flag conflicts |
| `init` | First-time setup: push every vault task note to Lark Tasks |

Steps:

1. Read `_CLAUDE.md` to confirm the vault root.
2. Run `pwsh -File scripts/lark-tasks-sync.ps1 <sub-command> [path|guid] -VaultRoot <vault-root>` via the Bash tool from the vault root.
3. Report the result: tasks created/updated/pulled, assignments synced, conflicts flagged, or status summary.

Task sources: scan `Tasks/` folder for `type: task` notes AND scan all board files (those with `kanban-plugin: board` frontmatter) for task items. Both are included in every push/pull.

Field mapping (vault task <-> Lark Task):

| Vault frontmatter / content | Lark Task field |
|---|---|
| `title:` (or `# Heading`) | title |
| `status:` (todo/in-progress/done/blocked) | status |
| `priority:` (high/medium/low) | priority |
| `due:` (YYYY-MM-DD) | due_date |
| `assignee:` | members - resolved to Lark user IDs via person note `lark_user_id:` fields |
| `project:` | tasklist or custom tag |
| `lark_task_guid:` | task_guid (written back to vault on create) |
| `tags:` | tags |
| Checklist items under `## Subtasks` | subtasks |

Assignee resolution: look up each `assignee:` value in `People/<name>.md`; use that note's `lark_user_id:` field. If the person note lacks `lark_user_id:`, log a warning and skip the assignee field rather than guessing.

Status mapping:

| Vault status | Lark task status |
|---|---|
| `todo` | to_do |
| `in-progress` | in_progress |
| `blocked` | in_progress (with a `[BLOCKED]` tag) |
| `done` | completed |
| `cancelled` | abandoned |

When pulling tasks from Lark: create notes at `Tasks/<title>.md` with full AI-first frontmatter, then update the relevant kanban board column to reflect the current status.

Conflict resolution: when `sync` reports conflicts (task updated in vault AND updated in Lark since last sync), show both versions and ask the user which to keep before writing either side.

---

**AI-first rule:** Every note created or updated by this command MUST follow `references/ai-first-rules.md` - `## For future Claude` preamble, rich frontmatter (`type`, `date`, `tags`, `ai-first: true`, plus type-specific fields), recency markers per external claim, mandatory `[[wikilinks]]` for every person/project/concept referenced, sources preserved verbatim with URLs inline, and confidence levels where applicable. The vault is for future-Claude retrieval - not human reading.

**Anti-fabrication:** Search exhaustively before claiming any note, person, or file is absent - false absence is the most common failure mode - and never invent facts, entities, or dates (mark unknowns as `TBD`). See the anti-fabrication and search-completeness hard rules in `references/ai-first-rules.md`.
