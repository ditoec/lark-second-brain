# scripts/setup.ps1 - obsidian-second-brain one-command installer
#
# Usage:
#   pwsh -File scripts/setup.ps1 "C:\path\to\your\vault"
#
# What it does:
#   1. Validates the vault path
#   2. Adds OBSIDIAN_VAULT_PATH to ~/.claude/settings.json
#   3. Wires the PostCompact and SessionStart background agent hooks
#   4. Registers slash commands in ~/.claude/commands/
#   5. Configures the MCP server for Claude Code (optional)

param([Parameter(Position=0)][string]$VaultArg = "")

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SKILL_DIR   = Split-Path $PSScriptRoot -Parent
$SETTINGS    = Join-Path $env:USERPROFILE '.claude\settings.json'
$HOOK_SCRIPT = Join-Path $SKILL_DIR 'hooks\obsidian-bg-agent.ps1'
$SESSION_HOOK = Join-Path $SKILL_DIR 'hooks\load_vault_context.py'
$ENV_FILE    = Join-Path $env:USERPROFILE '.config\obsidian-second-brain\.env'

function Write-Green  { param([string]$Msg) Write-Host $Msg -ForegroundColor Green }
function Write-Yellow { param([string]$Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Red    { param([string]$Msg) Write-Host $Msg -ForegroundColor Red }
function Write-Step   { param([string]$Msg) Write-Host "`n$Msg" -ForegroundColor White }

# Resolve vault path
$VAULT = $VaultArg
if (-not $VAULT) {
    Write-Red "Error: vault path required."
    Write-Host "Usage: pwsh -File scripts/setup.ps1 `"/path/to/your/vault`""
    exit 1
}

# Expand leading ~
if ($VAULT.StartsWith('~')) {
    $VAULT = Join-Path $env:USERPROFILE $VAULT.Substring(2).TrimStart('\','/')
}

if (-not (Test-Path $VAULT -PathType Container)) {
    Write-Red "Error: vault directory not found: $VAULT"
    Write-Host "Create it first or check the path."
    exit 1
}

Write-Host ""
Write-Host "obsidian-second-brain setup"
Write-Host "==========================="
Write-Host "Vault: $VAULT"
Write-Host "Skill: $SKILL_DIR"
Write-Host ""

# Step 1: hooks are .ps1 files - no chmod needed on Windows
Write-Step "1. Hook scripts ready (no chmod needed on Windows)..."
Write-Green "   Done - $HOOK_SCRIPT"
if (Test-Path $SESSION_HOOK) { Write-Green "   Done - $SESSION_HOOK" }

# Step 2: Update ~/.claude/settings.json
Write-Step "2. Updating ~/.claude/settings.json..."

$claudeDir = Split-Path $SETTINGS -Parent
New-Item -ItemType Directory -Force $claudeDir | Out-Null

if (-not (Test-Path $SETTINGS)) {
    '{}' | Set-Content $SETTINGS -Encoding UTF8
    Write-Host "   Created $SETTINGS"
}

$settingsText = Get-Content $SETTINGS -Raw -Encoding UTF8
try {
    $settings = $settingsText | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Red "Error: $SETTINGS contains invalid JSON. Fix it first."
    exit 1
}

# Helper: ensure a property exists on a PSCustomObject
function Ensure-Property {
    param($Obj, [string]$Name, $Default)
    if (-not ($Obj.PSObject.Properties.Name -contains $Name) -or $null -eq $Obj.$Name) {
        $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Default -Force
    }
}

# Add OBSIDIAN_VAULT_PATH to .env
Ensure-Property $settings 'env' ([PSCustomObject]@{})
$settings.env | Add-Member -NotePropertyName 'OBSIDIAN_VAULT_PATH' -NotePropertyValue $VAULT -Force
Write-Green "   OBSIDIAN_VAULT_PATH set"

# Wire VAULT into research toolkit .env if it exists
if (Test-Path $ENV_FILE) {
    $envLines = Get-Content $ENV_FILE
    $found = $false
    $newLines = foreach ($line in $envLines) {
        if ($line -match '^OBSIDIAN_VAULT_PATH=') { "OBSIDIAN_VAULT_PATH=$VAULT"; $found = $true }
        else { $line }
    }
    if (-not $found) { $newLines = @($newLines) + "OBSIDIAN_VAULT_PATH=$VAULT" }
    $newLines | Set-Content $ENV_FILE -Encoding UTF8
    Write-Green "   OBSIDIAN_VAULT_PATH written to research .env"
}

# Add PostCompact hook
$HOOK_CMD = "pwsh -File `"$HOOK_SCRIPT`""
Ensure-Property $settings 'hooks' ([PSCustomObject]@{})
Ensure-Property $settings.hooks 'PostCompact' @()

$existingPost = @($settings.hooks.PostCompact) | ForEach-Object {
    if ($_ -and $_.hooks) { @($_.hooks) | ForEach-Object { $_.command } }
} | Where-Object { $_ -like "*obsidian-bg-agent*" }

if ($existingPost) {
    Write-Yellow "   PostCompact hook already configured - skipping"
} else {
    $hookEntry = [PSCustomObject]@{
        matcher = ""
        hooks   = @([PSCustomObject]@{
            type    = "command"
            command = $HOOK_CMD
            timeout = 10
            async   = $true
        })
    }
    $settings.hooks.PostCompact = @($settings.hooks.PostCompact) + $hookEntry
    Write-Green "   PostCompact hook registered (inert by default)"
    Write-Host "      To enable: set OBSIDIAN_BG_AGENT_ENABLED=1 in the env section of"
    Write-Host "      ~/.claude/settings.json"
}

# Add SessionStart hook
if (Test-Path $SESSION_HOOK) {
    $SESSION_HOOK_CMD = "python3 `"$SESSION_HOOK`""
    Ensure-Property $settings.hooks 'SessionStart' @()

    $existingSession = @($settings.hooks.SessionStart) | ForEach-Object {
        if ($_ -and $_.hooks) { @($_.hooks) | ForEach-Object { $_.command } }
    } | Where-Object { $_ -like "*load_vault_context*" }

    if ($existingSession) {
        Write-Yellow "   SessionStart hook already configured - skipping"
    } else {
        $sessionEntry = [PSCustomObject]@{
            matcher = ""
            hooks   = @([PSCustomObject]@{
                type    = "command"
                command = $SESSION_HOOK_CMD
            })
        }
        $settings.hooks.SessionStart = @($settings.hooks.SessionStart) + $sessionEntry
        Write-Green "   SessionStart hook wired (injects _CLAUDE.md once per session)"
    }
}

# Write settings back
$settings | ConvertTo-Json -Depth 10 | Set-Content $SETTINGS -Encoding UTF8

# Step 3: Register slash commands
Write-Step "3. Registering slash commands in ~/.claude/commands/..."

$COMMANDS_SRC = Join-Path $SKILL_DIR 'commands'
$COMMANDS_DST = Join-Path $env:USERPROFILE '.claude\commands'

if (-not (Test-Path $COMMANDS_SRC)) {
    Write-Yellow "   No commands/ directory in skill - skipping"
} else {
    New-Item -ItemType Directory -Force $COMMANDS_DST | Out-Null
    $linked = 0; $skipped = 0; $blocked = 0
    foreach ($cmd in (Get-ChildItem $COMMANDS_SRC -Filter "*.md")) {
        $target = Join-Path $COMMANDS_DST $cmd.Name
        if (Test-Path $target -PathType Leaf) {
            $item = Get-Item $target
            if ($item.LinkType -eq 'SymbolicLink') {
                # Refresh symlink
                Remove-Item $target -Force
                New-Item -ItemType SymbolicLink -Path $target -Target $cmd.FullName | Out-Null
                $skipped++
            } else {
                Write-Yellow "   Skipped $($cmd.Name) - file already exists (not a symlink). Remove it manually if you want the skill version."
                $blocked++
            }
        } else {
            try {
                New-Item -ItemType SymbolicLink -Path $target -Target $cmd.FullName | Out-Null
                $linked++
            } catch {
                Copy-Item $cmd.FullName $target
                $linked++
            }
        }
    }
    Write-Green "   $linked new, $skipped refreshed, $blocked blocked"
}

# Step 4: MCP server (optional)
Write-Step "4. MCP server (optional - Claude Code only)..."
Write-Host "   The obsidian-vault MCP server gives Claude faster vault access."
Write-Host "   Without it, Claude reads/writes vault files directly (works fine)."
Write-Host ""
$REPLY = Read-Host "   Configure MCP server for Claude Code? [y/N]"
if ($REPLY -match '^[Yy]$') {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        claude mcp add obsidian-vault -s user -- npx -y mcp-obsidian $VAULT
        Write-Green "   MCP server configured"
    } else {
        Write-Yellow "   claude CLI not found - skipping MCP setup"
        Write-Host "   Run manually when ready:"
        Write-Host "   claude mcp add obsidian-vault -s user -- npx -y mcp-obsidian `"$VAULT`""
    }
} else {
    Write-Host "   Skipped. Run later if you want it:"
    Write-Host "   claude mcp add obsidian-vault -s user -- npx -y mcp-obsidian `"$VAULT`""
}

# Done
Write-Host ""
Write-Host "==========================="
Write-Green "Setup complete."
Write-Host ""
Write-Host "Next step: drop a _CLAUDE.md into your vault so Claude knows how it's structured."
Write-Host "Open Claude Code in your vault directory and run:"
Write-Host ""
Write-Host "   /obsidian-init"
Write-Host ""
Write-Host "That's it. Claude will scan your vault and generate its operating manual."
Write-Host ""
Write-Host "Background agent logs: $env:TEMP\obsidian-bg-agent.log"
Write-Host "Health check:          python scripts/vault_health.py --path `"$VAULT`""
Write-Host ""
