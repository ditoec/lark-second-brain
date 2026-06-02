---
description: Sync local vault notes to/from Lark Wiki - push, pull, bidirectional, or status
category: meta
triggers_en: ["sync to lark", "push to lark", "pull from lark", "lark sync", "lark status", "sync vault to lark"]
---

Use the obsidian-second-brain skill. Execute `/obsidian-lark-sync $ARGUMENTS`:

Syncs local vault markdown files to/from Lark Wiki using `scripts/sync.ps1`.
Local `.md` files are the primary source of truth; Lark Wiki is the sync target.
State is tracked in `.lark-sync.json` at the vault root.

Supported sub-commands (passed as ARGUMENTS):

| Sub-command | What it does |
|---|---|
| (none) or `status` | Show which files are new, modified, moved, or in sync |
| `push` | Push all locally changed files to Lark |
| `push <relative-path>` | Push a single file |
| `pull` | Pull all tracked Lark nodes to local |
| `pull <relative-path>` | Pull one file by its relative path |
| `sync` | Bidirectional: pull Lark changes, push local changes, flag conflicts |
| `init` | First-time setup: push every local `.md` file to the configured Wiki space |

Steps:

1. Read `_CLAUDE.md` to confirm the vault root.
2. If a Lark space ID is configured in `_CLAUDE.md` (look for a `lark_space_id:` field), export it as `$env:LARK_WIKI_SPACE_ID` before running.
3. Run `pwsh -File scripts/sync.ps1 <sub-command> [file] -VaultRoot <vault-root>` via the Bash tool from the vault root.
4. Report the result: files pushed/pulled, conflicts flagged, or sync status summary.

First-time setup: if no `.lark-sync.json` exists, ask the user for their Lark Wiki space ID, then run `init`.

Conflict resolution: when `sync` reports conflicts (both sides changed since last sync), ask the user which version to keep, then use `push <file>` or `pull <file>` to resolve each conflict.

---

**AI-first rule:** Every note created or updated by this command MUST follow `references/ai-first-rules.md` - `## For future Claude` preamble, rich frontmatter (`type`, `date`, `tags`, `ai-first: true`, plus type-specific fields), recency markers per external claim, mandatory `[[wikilinks]]` for every person/project/concept referenced, sources preserved verbatim with URLs inline, and confidence levels where applicable. The vault is for future-Claude retrieval - not human reading.

**Anti-fabrication:** Search exhaustively before claiming any note, person, or file is absent - false absence is the most common failure mode - and never invent facts, entities, or dates (mark unknowns as `TBD`). See the anti-fabrication and search-completeness hard rules in `references/ai-first-rules.md`.
