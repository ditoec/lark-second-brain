# scripts/build.ps1 - Compile platform-neutral source into dist\<platform>\
#
# Usage:
#   pwsh -File scripts/build.ps1                        # builds all platforms
#   pwsh -File scripts/build.ps1 -Platform claude-code
#   pwsh -File scripts/build.ps1 -Platform codex-cli

param(
    [string]$Platform = "",
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_DIR = $PSScriptRoot
$REPO_ROOT  = Split-Path $SCRIPT_DIR -Parent

. "$SCRIPT_DIR\lib.ps1"

if ($Help) {
    Write-Host @'
Usage: pwsh -File scripts/build.ps1 [-Platform <name>]

Without -Platform, builds every platform listed under adapters\.

Available platforms:
  claude-code   - Claude Code (slash commands + CLAUDE.md)
  codex-cli     - OpenAI Codex CLI (AGENTS.md + .codex/commands/)
  gemini-cli    - Gemini CLI (GEMINI.md + .gemini/commands/)
  opencode      - OpenCode (AGENTS.md + .opencode/commands/)
  lark          - Lark Wiki sync (commands + sync.ps1)
'@
    exit 0
}

function Discover-Platforms {
    (Get-ChildItem (Join-Path $REPO_ROOT 'adapters') -Directory).Name
}

function Build-One {
    param([string]$PlatformName)
    $adapterFile = Join-Path $REPO_ROOT "adapters\$PlatformName\adapter.ps1"
    if (-not (Test-Path $adapterFile)) {
        die "Adapter not found: $adapterFile"
    }
    info "Building platform: $PlatformName"
    # Source shared adapter helpers then the platform-specific adapter.
    # Both are dot-sourced into this function's scope so adapter_build
    # and all platform helpers can call each other and the lib functions.
    . "$REPO_ROOT\adapters\lib.ps1"
    . $adapterFile
    $distDir = Join-Path $REPO_ROOT "dist\$PlatformName"
    Remove-Item -Recurse -Force $distDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $distDir | Out-Null
    adapter_build $REPO_ROOT $distDir
    success "$PlatformName -> dist\$PlatformName\"
}

if ($Platform) {
    Build-One $Platform
} else {
    info "No -Platform given; building all"
    foreach ($p in (Discover-Platforms)) {
        Build-One $p
    }
    success "All platforms built"
}
