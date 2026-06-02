#!/usr/bin/env bash
# =============================================================================
# adapters/lark/adapter.sh - Lark Wiki sync adapter
# =============================================================================
# This adapter targets Claude Code users who sync their local vault to Lark
# Wiki. Local .md files remain the primary source of truth; scripts/sync.ps1
# handles bidirectional transfer to the configured Lark Wiki space.
#
# Output shape:
#   dist/lark/
#     LARK.md          sync workflow reference
#     INSTALL.md       setup instructions
#     commands/        identity copy of all commands (no tool rewriting)
#     references/      identity copy
#     scripts/         identity copy including sync.ps1
# =============================================================================

LARK_PLATFORM="lark"

adapter_build() {
  local src="$1" dst="$2"

  _lark_copy_commands   "$src/commands"   "$dst/commands"
  _lark_copy_references "$src/references" "$dst/references"
  _lark_copy_scripts    "$src/scripts"    "$dst/scripts"
  _lark_emit_lark_md    "$dst"
  _lark_emit_install    "$dst"
}

# Identity copy - no tool rewriting needed; this adapter targets Claude Code.
_lark_copy_commands() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"
  local f
  for f in "$src"/*.md; do
    [[ -f "$f" ]] || continue
    should_include "$f" "$LARK_PLATFORM" || continue
    cp "$f" "$dst/$(basename "$f")"
  done
}

_lark_copy_references() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"
  cp -R "$src/." "$dst/"
}

_lark_copy_scripts() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"
  cp -R "$src/." "$dst/"
}

_lark_emit_lark_md() {
  local dst="$1"
  cat > "$dst/LARK.md" <<'LARKEOF'
# Obsidian Second Brain - Lark Wiki Sync

Local `.md` files are the primary source of truth. Lark Wiki is the sync
target - changes live on disk first, then get pushed. `scripts/sync.ps1`
handles the bidirectional transfer.

## Sync workflow

Run from the vault root (requires PowerShell / pwsh and lark-cli):

| Command | What it does |
|---|---|
| `pwsh -File scripts/sync.ps1 status` | Show pending pushes, pulls, and conflicts |
| `pwsh -File scripts/sync.ps1 init` | First-time push of all `.md` files to Lark |
| `pwsh -File scripts/sync.ps1 push` | Push all locally changed files |
| `pwsh -File scripts/sync.ps1 push <file>` | Push one file by relative path |
| `pwsh -File scripts/sync.ps1 pull` | Pull all Lark changes to local |
| `pwsh -File scripts/sync.ps1 pull <file>` | Pull one file |
| `pwsh -File scripts/sync.ps1 sync` | Bidirectional sync; flags conflicts |

Or use the `/obsidian-lark-sync` Claude Code command (same operations, Claude-managed).

## Configuration

Set the Lark Wiki space ID in one of:

1. Environment variable: `$env:LARK_WIKI_SPACE_ID = "your-space-id"`
2. `_CLAUDE.md` at vault root with a `lark_space_id: <id>` field
3. `.lark-sync.json` at vault root (created automatically on first `init`)

The space ID appears in your Lark Wiki URL: `.../wiki/space/<space-id>`.

## State file

`.lark-sync.json` tracks node tokens and content hashes for each synced file.
Add it to `.gitignore` if the vault is in a git repo - it is machine-local.
LARKEOF
}

_lark_emit_install() {
  local dst="$1"
  cat > "$dst/INSTALL.md" <<'EOF'
# Install - Lark Wiki sync

```bash
# After running: bash scripts/build.sh --platform lark
# Copy (or symlink) the built tree into your vault root:
cp -R dist/lark/. /path/to/your/vault/
```

Then in the vault:

- `LARK.md` - sync workflow reference
- `commands/*.md` - Claude Code slash commands (symlink into `~/.claude/commands/` if not using the skill installer)
- `scripts/sync.ps1` - bidirectional sync to Lark Wiki

First-time setup:

```powershell
$env:LARK_WIKI_SPACE_ID = "your-space-id"
pwsh -File scripts/sync.ps1 init
```

Subsequent syncs:

```powershell
pwsh -File scripts/sync.ps1 sync
```

Or within Claude Code: `/lark-sync sync`
EOF
}
