# quick-install.ps1 - One-command installer for obsidian-second-brain
#
# Usage:
#   irm https://raw.githubusercontent.com/eugeniughelbur/obsidian-second-brain/main/scripts/quick-install.ps1 | iex
#
# What it does:
#   1. Clones the repo to ~/.claude/skills/obsidian-second-brain (or pulls if it exists)
#   2. Prompts for the vault path
#   3. Runs scripts/setup.ps1 with that path
#
# Environment:
#   OBSIDIAN_VAULT_PATH - skip the prompt and use this path
#   SKILL_DIR           - override the install location (default: ~/.claude/skills/obsidian-second-brain)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$REPO_URL  = "https://github.com/eugeniughelbur/obsidian-second-brain"
$SKILL_DIR = if ($env:SKILL_DIR) { $env:SKILL_DIR } else { Join-Path $env:USERPROFILE '.claude\skills\obsidian-second-brain' }

function Write-Red    { param([string]$Msg) Write-Host $Msg -ForegroundColor Red }
function Write-Green  { param([string]$Msg) Write-Host $Msg -ForegroundColor Green }
function Write-Yellow { param([string]$Msg) Write-Host $Msg -ForegroundColor Yellow }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Red "Error: git not found. Install git and retry."
    exit 1
}

# Clone or update
if (Test-Path (Join-Path $SKILL_DIR '.git')) {
    Write-Yellow "Repo already at $SKILL_DIR - pulling latest..."
    git -C $SKILL_DIR pull --ff-only
} else {
    if (Test-Path $SKILL_DIR) {
        Write-Red "Error: $SKILL_DIR exists and is not a git checkout. Move it aside first."
        exit 1
    }
    $parentDir = Split-Path $SKILL_DIR -Parent
    New-Item -ItemType Directory -Force $parentDir | Out-Null
    git clone $REPO_URL $SKILL_DIR
}

Write-Green "Skill installed at $SKILL_DIR"

# Resolve vault path
$VAULT = if ($env:OBSIDIAN_VAULT_PATH) { $env:OBSIDIAN_VAULT_PATH } else { '' }

if (-not $VAULT) {
    $VAULT = Read-Host "Path to your Obsidian vault"
}

if (-not $VAULT) {
    Write-Yellow "Vault path required. Re-run with `$env:OBSIDIAN_VAULT_PATH set, or run setup.ps1 directly:"
    Write-Host "  pwsh -File $SKILL_DIR\scripts\setup.ps1 `"/path/to/your/vault`""
    exit 0
}

# Hand off to setup.ps1
pwsh -File (Join-Path $SKILL_DIR 'scripts\setup.ps1') $VAULT
