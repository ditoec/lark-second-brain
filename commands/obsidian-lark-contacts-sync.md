---
description: Sync vault person notes to/from Lark Contacts - push keypersons, pull contact updates
category: meta
triggers_en: ["sync contacts to lark", "push contacts to lark", "pull lark contacts", "lark contacts sync", "sync keypersons to lark", "sync people to lark", "lark people sync"]
---

Use the obsidian-second-brain skill. Execute `/obsidian-lark-contacts-sync $ARGUMENTS`:

Syncs vault `type: person` notes to/from Lark Contacts using `scripts/lark-contacts-sync.ps1`.
Local vault person notes are the primary source of truth; Lark Contacts is the sync target.
State is tracked in `.lark-contacts-sync.json` at the vault root.

Supported sub-commands (passed as ARGUMENTS):

| Sub-command | What it does |
|---|---|
| (none) or `status` | Show which person notes are new, modified, or in sync with Lark Contacts |
| `push` | Push all locally changed person notes to Lark Contacts |
| `push <relative-path>` | Push a single person note by its vault path |
| `pull` | Pull all tracked Lark Contacts back to vault person notes |
| `pull <user-id>` | Pull one Lark contact by user ID |
| `sync` | Bidirectional: push local changes, pull Lark changes, flag conflicts |
| `import` | One-way import: pull all Lark Contacts into vault, creating missing person stubs |

Steps:

1. Read `_CLAUDE.md` to confirm the vault root and check for a `lark_contacts_sync:` field.
2. Run `pwsh -File scripts/lark-contacts-sync.ps1 <sub-command> [path|id] -VaultRoot <vault-root>` via the Bash tool from the vault root.
3. Report the result: contacts created/updated/pulled, conflicts flagged, or sync status.

First-time setup: run `import` to pull all Lark Contacts and create vault person stubs for contacts not already in the vault.

Field mapping (vault person note <-> Lark Contact):

| Vault frontmatter | Lark Contact field |
|---|---|
| `name:` | display_name |
| `email:` | enterprise_email or custom_email |
| `role:` | job_title |
| `org:` | department |
| `mobile:` | mobile |
| `strength:` | stored as custom attribute `vault_strength` |
| `tags:` | stored as custom attribute `vault_tags` |

When importing from Lark, create person notes at `People/<Name>.md` with:
- Full AI-first frontmatter (`type: person`, `date`, `tags`, `ai-first: true`)
- `## For future Claude` preamble stating who the person is and where they were imported from
- `lark_user_id:` frontmatter field to track the Lark user ID for future syncs
- Empty `## Context`, `## Interactions`, and `## Notes` sections (never fabricate content)

Conflict resolution: when `sync` reports conflicts, ask the user which version to keep, then use `push` or `pull` to resolve.

---

**AI-first rule:** Every note created or updated by this command MUST follow `references/ai-first-rules.md` - `## For future Claude` preamble, rich frontmatter (`type`, `date`, `tags`, `ai-first: true`, plus type-specific fields), recency markers per external claim, mandatory `[[wikilinks]]` for every person/project/concept referenced, sources preserved verbatim with URLs inline, and confidence levels where applicable. The vault is for future-Claude retrieval - not human reading.

**Anti-fabrication:** Search exhaustively before claiming any note, person, or file is absent - false absence is the most common failure mode - and never invent facts, entities, or dates (mark unknowns as `TBD`). See the anti-fabrication and search-completeness hard rules in `references/ai-first-rules.md`.
