# install.ps1 - Install obsidian-second-brain slash commands and skill link
#
# Usage:
#   pwsh -File install.ps1
#
# Note: creating the skill symlink requires either:
#   - Developer Mode enabled in Windows Settings, OR
#   - running this script as Administrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SKILL_DIR    = $PSScriptRoot
$CLAUDE_DIR   = Join-Path $env:USERPROFILE '.claude'
$COMMANDS_DIR = Join-Path $CLAUDE_DIR 'commands'
$SKILLS_DIR   = Join-Path $CLAUDE_DIR 'skills'
$CONFIG_DIR   = Join-Path $env:USERPROFILE '.config\obsidian-second-brain'
$ENV_FILE     = Join-Path $CONFIG_DIR '.env'

Write-Host "Installing obsidian-second-brain..."

# Create directories if needed
New-Item -ItemType Directory -Force $COMMANDS_DIR | Out-Null
New-Item -ItemType Directory -Force $SKILLS_DIR   | Out-Null

# Copy commands to ~/.claude/commands/
Write-Host "Installing slash commands..."
foreach ($file in (Get-ChildItem (Join-Path $SKILL_DIR 'commands') -Filter "*.md" -ErrorAction SilentlyContinue)) {
    $dest = Join-Path $COMMANDS_DIR $file.Name
    if (Test-Path $dest) {
        Write-Host "  skipping $($file.Name) (already exists)"
    } else {
        Copy-Item $file.FullName $dest
        Write-Host "  installed $($file.Name)"
    }
}

# Link skill into ~/.claude/skills/
$SKILL_LINK = Join-Path $SKILLS_DIR 'obsidian-second-brain'
if (Test-Path $SKILL_LINK) {
    Write-Host "Skill already linked at $SKILL_LINK"
} else {
    try {
        New-Item -ItemType SymbolicLink -Path $SKILL_LINK -Target $SKILL_DIR | Out-Null
        Write-Host "Skill linked at $SKILL_LINK"
    } catch {
        Write-Warning "Could not create symlink (requires Developer Mode or Administrator): $_"
        Write-Host "  Fallback: copying skill directory instead..."
        Copy-Item $SKILL_DIR $SKILL_LINK -Recurse -Force
        Write-Host "  Copied to $SKILL_LINK"
    }
}

# Research toolkit setup (optional)
Write-Host ""
Write-Host "Research toolkit (optional): /x-read, /x-pulse, /research, /research-deep, /youtube"
Write-Host "These commands need API keys for Grok (xAI) and Perplexity. YouTube key is optional."
Write-Host ""
$setupResearch = Read-Host "Set up research toolkit now? [y/N]"
if (-not $setupResearch) { $setupResearch = 'N' }

if ($setupResearch -match '^[Yy]$') {
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        Write-Warning "'uv' not found. Install with: powershell -c `"irm https://astral.sh/uv/install.ps1 | iex`""
        Write-Host "     Then re-run this installer to finish research toolkit setup."
    } else {
        Write-Host "  Installing Python deps via uv..."
        Push-Location $SKILL_DIR
        uv sync --quiet
        Pop-Location
        Write-Host "  Python deps ready."
    }

    New-Item -ItemType Directory -Force $CONFIG_DIR | Out-Null
    if (Test-Path $ENV_FILE) {
        Write-Host "  $ENV_FILE already exists - leaving it untouched."
    } else {
        $exampleEnv = Join-Path $SKILL_DIR '.env.example'
        if (Test-Path $exampleEnv) {
            Copy-Item $exampleEnv $ENV_FILE
        } else {
            New-Item -ItemType File $ENV_FILE | Out-Null
        }
        Write-Host "  Created $ENV_FILE"
    }

    Write-Host ""
    Write-Host "  Now paste your API keys into: $ENV_FILE"
    Write-Host "    XAI_API_KEY=          (https://console.x.ai)"
    Write-Host "    PERPLEXITY_API_KEY=   (https://perplexity.ai/settings/api)"
    Write-Host "    YOUTUBE_API_KEY=      (https://console.cloud.google.com - optional)"
    Write-Host ""
    Read-Host "  Press Enter to open the file in Notepad (or Ctrl+C to skip)"
    notepad $ENV_FILE
}

Write-Host ""
Write-Host "Done. Restart Claude Code to activate the commands."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Run /obsidian-init to generate your vault's _CLAUDE.md"
Write-Host "  2. (If research toolkit installed) Verify keys: Get-Content $ENV_FILE"
