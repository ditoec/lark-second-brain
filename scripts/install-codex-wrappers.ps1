# scripts/install-codex-wrappers.ps1
# Install one PATH shim per command so Codex users can run them by name:
#   obsidian-init
#   obsidian-daily
#   research "topic"
# Each shim delegates to scripts/run-command.ps1. (Claude Code users do not need
# this - they use the slash commands directly.)

Set-StrictMode -Version Latest

$SKILL_DIR = Split-Path $PSScriptRoot -Parent
$BIN_DIR   = if ($env:OBSIDIAN_CODEX_BIN_DIR) { $env:OBSIDIAN_CODEX_BIN_DIR } `
             else { Join-Path $env:USERPROFILE '.codex\bin' }

New-Item -ItemType Directory -Force $BIN_DIR | Out-Null

$RUN_SCRIPT = Join-Path $SKILL_DIR 'scripts\run-command.ps1'
$count = 0

foreach ($file in (Get-ChildItem (Join-Path $SKILL_DIR 'commands') -Filter "*.md" -ErrorAction SilentlyContinue)) {
    $name    = $file.BaseName
    $wrapper = Join-Path $BIN_DIR "$name.ps1"
    @"
# Auto-generated wrapper - delegates to obsidian-second-brain run-command.ps1
param([Parameter(Position=0, ValueFromRemainingArguments=`$true)][string[]]`$PassThru)
& '$RUN_SCRIPT' '$name' @PassThru
"@ | Set-Content $wrapper -Encoding UTF8
    $count++
}

Write-Host "Installed $count command wrappers to $BIN_DIR"
Write-Host "If $BIN_DIR is not on your PATH, add:"
Write-Host "  `$env:PATH += `";$BIN_DIR`""
Write-Host "Or permanently: [System.Environment]::SetEnvironmentVariable('PATH', `$env:PATH + ';$BIN_DIR', 'User')"
