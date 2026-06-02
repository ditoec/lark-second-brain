---
description: Sync vault meeting notes and scheduled tasks to/from Lark Calendar - meetings, assignments, schedules
category: meta
triggers_en: ["sync calendar to lark", "push meetings to lark", "pull lark calendar", "lark calendar sync", "sync meeting notes to lark", "sync schedule to lark", "lark meetings sync", "lark schedule sync"]
---

Use the obsidian-second-brain skill. Execute `/obsidian-lark-calendar-sync $ARGUMENTS`:

Syncs vault meeting notes and task due dates to/from Lark Calendar using `scripts/lark-calendar-sync.ps1`.
Local vault is the primary source of truth for meeting notes; Lark Calendar is the source of truth for event scheduling.
State is tracked in `.lark-calendar-sync.json` at the vault root.

Supported sub-commands (passed as ARGUMENTS):

| Sub-command | What it does |
|---|---|
| (none) or `status` | Show unsynced meeting notes, upcoming task due dates, and calendar events not yet in vault |
| `push meetings` | Push vault `type: meeting` notes to Lark Calendar as events |
| `push schedule` | Push vault task due dates as Lark Calendar events (one event per task with a `due:` date) |
| `push <relative-path>` | Push a single meeting note to Lark Calendar |
| `pull` | Pull Lark Calendar events into vault as `type: meeting` stubs (empty notes, never fabricated content) |
| `pull <event-id>` | Pull one event by its Lark event ID |
| `sync` | Bidirectional: push new vault meetings, pull new Lark events, flag events changed on both sides |
| `init` | First-time setup: pull all upcoming Lark Calendar events and create vault meeting stubs |

Steps:

1. Read `_CLAUDE.md` to confirm the vault root and check for a `lark_calendar_id:` field.
2. If `lark_calendar_id` is present, export it as `$env:LARK_CALENDAR_ID` before running.
3. Run `pwsh -File scripts/lark-calendar-sync.ps1 <sub-command> [path|event-id] -VaultRoot <vault-root>` via the Bash tool from the vault root.
4. Report the result: events created/updated/pulled, stubs created, or sync status.

First-time setup: if no `.lark-calendar-sync.json` exists, ask the user for their Lark calendar ID (or use the primary calendar), then run `init` to create vault stubs for all upcoming events.

Field mapping (vault meeting note <-> Lark Calendar event):

| Vault frontmatter | Lark Calendar field |
|---|---|
| `title:` | summary |
| `date:` + time | start_time |
| `attendees:` | attendees (matched to Lark users by email from person notes) |
| `organizer:` | organizer |
| `lark_event_id:` | event_id (written back to vault after push) |
| `location:` | location |
| `duration_minutes:` | end_time (computed) |

When pulling events from Lark Calendar:
- Create meeting notes at `wiki/meetings/YYYY-MM-DD - <Title>.md` with:
  - Full AI-first frontmatter (`type: meeting`, `date`, `tags`, `ai-first: true`, `lark_event_id:`, `attendees:`)
  - `## For future Claude` preamble stating the event title, date, and participants
  - Cross-linked attendees: search vault for each attendee, create `[[Person]]` links, create stubs for unknown attendees
  - **Empty** `## Notes`, `## Decisions`, and `## Action items` sections - never fabricate meeting content
- Link the new meeting note from today's daily note and from each attendee's person note `## Interactions` section

When pushing task due dates as calendar events:
- Read vault tasks with `due:` dates from `Tasks/` and board notes
- Create one-hour Lark Calendar event per task titled `[Task] <task-title>`
- Write `lark_event_id:` back into the task note's frontmatter

Conflict resolution: when `sync` reports conflicts (meeting edited in vault AND rescheduled in Lark), show both versions and ask the user which takes priority before writing either side.

---

**AI-first rule:** Every note created or updated by this command MUST follow `references/ai-first-rules.md` - `## For future Claude` preamble, rich frontmatter (`type`, `date`, `tags`, `ai-first: true`, plus type-specific fields), recency markers per external claim, mandatory `[[wikilinks]]` for every person/project/concept referenced, sources preserved verbatim with URLs inline, and confidence levels where applicable. The vault is for future-Claude retrieval - not human reading.

**Anti-fabrication:** Search exhaustively before claiming any note, person, or file is absent - false absence is the most common failure mode - and never invent facts, entities, or dates (mark unknowns as `TBD`). See the anti-fabrication and search-completeness hard rules in `references/ai-first-rules.md`.
