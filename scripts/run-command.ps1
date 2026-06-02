# scripts/run-command.ps1 - Run an obsidian-second-brain command on Codex CLI
#
# Codex/Gemini/OpenCode have no native slash-command runtime, so the command
# markdown under commands/ is inert on those platforms. This wraps a command
# file into a prompt and hands it to `codex exec`. (On Claude Code, use the
# slash command directly.)
#
# Usage:
#   pwsh -File run-command.ps1 /obsidian-init
#   pwsh -File run-command.ps1 obsidian-daily
#   pwsh -File run-command.ps1 research "state of MCP servers"
#   pwsh -File run-command.ps1 --print /obsidian-health
#
# Environment:
#   OBSIDIAN_SECOND_BRAIN_HOME   skill root override (default: parent of this script)
#   OBSIDIAN_VAULT_PATH          vault path (default: current directory)
#   CODEX_BIN                    codex binary (default: codex)

param(
    [switch]$Print,
    [Parameter(Position=0, Mandatory=$true)]
    [string]$Command,
    [Parameter(Position=1, ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

Set-StrictMode -Version Latest

$SELF_DIR  = $PSScriptRoot
$SKILL_DIR = if ($env:OBSIDIAN_SECOND_BRAIN_HOME) { $env:OBSIDIAN_SECOND_BRAIN_HOME } `
             else { Split-Path $SELF_DIR -Parent }
$CODEX_BIN = if ($env:CODEX_BIN) { $env:CODEX_BIN } else { 'codex' }
$CONFIG_FILE = Join-Path $env:USERPROFILE '.config\obsidian-second-brain\config.env'

if (Test-Path $CONFIG_FILE) {
    foreach ($line in (Get-Content $CONFIG_FILE)) {
        if ($line -match '^([^#=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process')
        }
    }
}

# Normalize: strip a leading / or $ and a trailing .md
$CMD = $Command -replace '^[/$]', '' -replace '\.md$', ''

$COMMAND_FILE = Join-Path $SKILL_DIR "commands\$CMD.md"
if (-not (Test-Path $COMMAND_FILE)) {
    Write-Error "Unknown command: $Command (expected $COMMAND_FILE)"
    exit 1
}

# Resolve the vault path, expanding leading ~
$VAULT = if ($env:OBSIDIAN_VAULT_PATH) { $env:OBSIDIAN_VAULT_PATH } else { (Get-Location).Path }
if ($VAULT.StartsWith('~')) {
    $VAULT = Join-Path $env:USERPROFILE $VAULT.Substring(2).TrimStart('\','/')
}
if (-not (Test-Path $VAULT -PathType Container)) {
    Write-Error "Vault directory not found: $VAULT"
    exit 1
}

$ARGS_TEXT = if ($Args -and $Args.Count -gt 0) { $Args -join ' ' } else { '(none)' }
$COMMAND_SPEC = Get-Content $COMMAND_FILE -Raw -Encoding UTF8

$PROMPT = @"
You are executing an installed obsidian-second-brain command in a non-slash client.

Command: /$CMD
Skill root: $SKILL_DIR
Vault root: $VAULT

Rules:
- Treat this exactly as if the user invoked /$CMD in a slash-command client.
- Read AGENTS.md at the vault root first if it exists; otherwise read _CLAUDE.md.
- Follow the command spec below exactly. If it references a skill path under
  ~/.codex/skills or ~/.claude/skills, use $SKILL_DIR instead.

User-supplied arguments: $ARGS_TEXT

Command spec:
$COMMAND_SPEC
"@

if ($Print) {
    Write-Output $PROMPT
    exit 0
}

if (-not (Get-Command $CODEX_BIN -ErrorAction SilentlyContinue)) {
    Write-Error "codex CLI not found (looked for: $CODEX_BIN). Use -Print to see the prompt."
    exit 1
}

Write-Host "[obsidian-second-brain] Running /$CMD in $VAULT" -ForegroundColor Cyan
& $CODEX_BIN exec --skip-git-repo-check --cd $VAULT $PROMPT
