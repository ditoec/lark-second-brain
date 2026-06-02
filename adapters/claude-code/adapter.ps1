# adapters/claude-code/adapter.ps1 - Claude Code platform adapter
# Dot-sourced by scripts/build.ps1 after adapters/lib.ps1.

$CC_PLATFORM = "claude-code"

function adapter_build {
    param([string]$Src, [string]$Dst)
    _CC-CopyCommands     (Join-Path $Src 'commands')   (Join-Path $Dst 'commands')
    _CC-CopySkillManifest $Src $Dst
    _CC-CopyReferences   (Join-Path $Src 'references') (Join-Path $Dst 'references')
    _CC-CopyScripts      (Join-Path $Src 'scripts')    (Join-Path $Dst 'scripts')
    _CC-CopyHooks        (Join-Path $Src 'hooks')      (Join-Path $Dst 'hooks')
    _CC-EmitInstallHint  $Dst
}

function _CC-CopyCommands {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path $Src)) { return }
    New-Item -ItemType Directory -Force $Dst | Out-Null
    foreach ($f in (Get-ChildItem $Src -Filter "*.md")) {
        if (Should-Include $f.FullName $CC_PLATFORM) {
            Copy-Item $f.FullName (Join-Path $Dst $f.Name)
        }
    }
}

function _CC-CopySkillManifest {
    param([string]$Src, [string]$Dst)
    $skill = Join-Path $Src 'SKILL.md'
    if (Test-Path $skill) { Copy-Item $skill (Join-Path $Dst 'SKILL.md') }
}

function _CC-CopyReferences {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path $Src)) { return }
    New-Item -ItemType Directory -Force $Dst | Out-Null
    Copy-Item "$Src\*" $Dst -Recurse -Force
}

function _CC-CopyScripts {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path $Src)) { return }
    New-Item -ItemType Directory -Force $Dst | Out-Null
    Copy-Item "$Src\*" $Dst -Recurse -Force
}

function _CC-CopyHooks {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path $Src)) { return }
    New-Item -ItemType Directory -Force $Dst | Out-Null
    Copy-Item "$Src\*" $Dst -Recurse -Force
}

function _CC-EmitInstallHint {
    param([string]$Dst)
    $content = @'
# Install on Claude Code

```powershell
# From the repo root, after running: pwsh -File scripts/build.ps1 --platform claude-code
New-Item -ItemType SymbolicLink -Path "$env:USERPROFILE\.claude\skills\obsidian-second-brain" `
    -Target "$(Get-Location)\dist\claude-code" -Force
Get-ChildItem "dist\claude-code\commands\*.md" | ForEach-Object {
    New-Item -ItemType SymbolicLink -Path "$env:USERPROFILE\.claude\commands\$($_.Name)" `
        -Target $_.FullName -Force
}
```

Restart Claude Code. The `/obsidian-*`, `/research`, and `/brand-*` commands
will be available.
'@
    [System.IO.File]::WriteAllText((Join-Path $Dst 'INSTALL.md'), $content, [System.Text.Encoding]::UTF8)
}
