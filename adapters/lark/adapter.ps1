# adapters/lark/adapter.ps1 - Lark Wiki sync adapter
# Dot-sourced by scripts/build.ps1 after adapters/lib.ps1.

$LARK_PLATFORM = "lark"

function adapter_build {
    param([string]$Src, [string]$Dst)
    _Lark-CopyCommands   (Join-Path $Src 'commands')   (Join-Path $Dst 'commands')
    _Lark-CopyReferences (Join-Path $Src 'references') (Join-Path $Dst 'references')
    _Lark-CopyScripts    (Join-Path $Src 'scripts')    (Join-Path $Dst 'scripts')
    _Lark-EmitLarkMd     $Dst
    _Lark-EmitInstall    $Dst
}

function _Lark-CopyCommands {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path $Src)) { return }
    New-Item -ItemType Directory -Force $Dst | Out-Null
    foreach ($f in (Get-ChildItem $Src -Filter "*.md")) {
        if (Should-Include $f.FullName $LARK_PLATFORM) {
            Copy-Item $f.FullName (Join-Path $Dst $f.Name)
        }
    }
}

function _Lark-CopyReferences {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path $Src)) { return }
    New-Item -ItemType Directory -Force $Dst | Out-Null
    Copy-Item "$Src\*" $Dst -Recurse -Force
}

function _Lark-CopyScripts {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path $Src)) { return }
    New-Item -ItemType Directory -Force $Dst | Out-Null
    Copy-Item "$Src\*" $Dst -Recurse -Force
}

function _Lark-EmitLarkMd {
    param([string]$Dst)
    $content = @'
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
'@
    [System.IO.File]::WriteAllText((Join-Path $Dst 'LARK.md'), $content, [System.Text.Encoding]::UTF8)
}

function _Lark-EmitInstall {
    param([string]$Dst)
    $content = @'
# Install - Lark Wiki sync

```powershell
# After running: pwsh -File scripts/build.ps1 --platform lark
# Copy the built tree into your vault root:
Copy-Item "dist\lark\*" "/path/to/your/vault/" -Recurse -Force
```

Then in the vault:

- `LARK.md` - sync workflow reference
- `commands\*.md` - Claude Code slash commands (symlink into `~\.claude\commands\` if not using the skill installer)
- `scripts\sync.ps1` - bidirectional sync to Lark Wiki

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
'@
    [System.IO.File]::WriteAllText((Join-Path $Dst 'INSTALL.md'), $content, [System.Text.Encoding]::UTF8)
}
