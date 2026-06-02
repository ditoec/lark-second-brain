# sync.ps1 - Bidirectional sync between local .md files and Lark Wiki
# Usage: pwsh -File scripts/sync.ps1 <command> [-File <file>] [-VaultRoot <path>]
# Commands: init, push [file], pull [file], sync, status
#
# Configuration:
#   Set $env:LARK_WIKI_SPACE_ID before first run, or rely on .lark-sync.json
#   after init. The state file tracks node tokens and hashes per file.

param(
    [Parameter(Position=0)]
    [ValidateSet("init","push","pull","sync","status")]
    [string]$Command = "status",

    [Parameter(Position=1)]
    [string]$File = "",

    [string]$VaultRoot = $PWD.Path
)

$npmBin    = "$env:APPDATA\npm"
if ($env:PATH -notlike "*$npmBin*") { $env:PATH = "$npmBin;$env:PATH" }

$lark      = "lark-cli"
$statePath = Join-Path $VaultRoot ".lark-sync.json"

# Space ID: env var wins, then state file, then fail on init.
$spaceId   = if ($env:LARK_WIKI_SPACE_ID) { $env:LARK_WIKI_SPACE_ID } else { "" }

# ── Helpers ───────────────────────────────────────────────────────────────────

function parseJson ([string[]]$lines) {
    $jsonStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\{') { $jsonStart = $i; break }
    }
    if ($jsonStart -lt 0) { return $null }
    $raw = ($lines[$jsonStart..($lines.Count - 1)]) -join "`n"
    try { $raw | ConvertFrom-Json } catch { $null }
}

function sha256 ([string]$path) {
    $h = [System.Security.Cryptography.SHA256]::Create()
    $b = [System.IO.File]::ReadAllBytes($path)
    ([BitConverter]::ToString($h.ComputeHash($b)) -replace "-", "").ToLower()
}

function fileTitle ([string]$path) {
    foreach ($line in (Get-Content $path -Encoding UTF8)) {
        if ($line -match '^#\s+(.+)') { return $Matches[1].Trim() }
    }
    [IO.Path]::GetFileNameWithoutExtension($path)
}

function relPath ([string]$full) {
    $full.Substring($VaultRoot.Length).TrimStart('\', '/')
}

function fullPath ([string]$rel) { Join-Path $VaultRoot $rel }

function readState {
    if (Test-Path $statePath) {
        $s = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $s.PSObject.Properties["nodes"]) {
            $s | Add-Member -NotePropertyName nodes -NotePropertyValue ([PSCustomObject]@{})
        }
        if (-not $s.PSObject.Properties["folders"]) {
            $s | Add-Member -NotePropertyName folders -NotePropertyValue ([PSCustomObject]@{})
        }
        # Prefer env var space ID over stored value when both are present
        if ($spaceId -and $s.space_id -ne $spaceId) { $s.space_id = $spaceId }
        return $s
    }
    [PSCustomObject]@{
        space_id = $spaceId
        folders  = [PSCustomObject]@{}
        nodes    = [PSCustomObject]@{}
    }
}

function saveState ($s) {
    $s | ConvertTo-Json -Depth 10 | Set-Content $statePath -Encoding UTF8
}

function getNode ($state, [string]$rel) {
    if ($state.nodes.PSObject.Properties[$rel]) { $state.nodes.$rel } else { $null }
}

function setNode ($state, [string]$rel, $info) {
    if ($state.nodes.PSObject.Properties[$rel]) { $state.nodes.$rel = $info }
    else { $state.nodes | Add-Member -NotePropertyName $rel -NotePropertyValue $info }
}

# Returns the subfolder portion of a rel path, or $null if at root
function nodeFolder ([string]$rel) {
    $d = [IO.Path]::GetDirectoryName($rel)
    if ([string]::IsNullOrEmpty($d)) { $null } else { $d }
}

# Ensures a Lark folder node exists for the given folder name; returns updated state
function ensureFolder ($state, [string]$folder) {
    if ($state.folders.PSObject.Properties[$folder]) { return $state }
    Write-Host "  [folder+] '$folder'"
    $cr = & $lark wiki +node-create --space-id $state.space_id --title $folder --as user
    $cj = parseJson $cr
    if (-not ($cj -and $cj.ok)) { Write-Warning "    FAIL create folder: $folder"; return $state }
    $state.folders | Add-Member -NotePropertyName $folder -NotePropertyValue $cj.data.node_token
    Write-Host "    OK (node $($cj.data.node_token))"
    $state
}

function localFiles {
    # Exclude state file, skill config, and any dot-lark files
    Get-ChildItem -Path $VaultRoot -Filter "*.md" -File -Recurse |
        Where-Object {
            $_.Name -notlike ".lark*" -and
            $_.Name -ne "CLAUDE.md" -and
            $_.Name -ne "_CLAUDE.md"
        }
}

# Returns $true if the file needs to be pushed (content changed or wrong Lark folder)
function needsPush ($state, $file) {
    $rel = relPath $file.FullName
    $n   = getNode $state $rel
    if (-not $n) { return $true }
    if ((sha256 $file.FullName) -ne $n.local_hash) { return $true }

    $folder = nodeFolder $rel
    $storedParent = if ($n.PSObject.Properties["parent_node_token"]) { $n.parent_node_token } else { $null }

    if ($folder) {
        if (-not $state.folders.PSObject.Properties[$folder]) { return $true }
        return $state.folders.$folder -ne $storedParent
    } else {
        return $null -ne $storedParent
    }
}

# ── Push one file to Lark ─────────────────────────────────────────────────────

function larkBody ([string]$content) {
    $lines = $content -split '(?:\r\n|\n)'
    $start = 0
    for ($i = 0; $i -lt [Math]::Min(5, $lines.Count); $i++) {
        if ($lines[$i] -match '^# ') { $start = $i + 1; break }
    }
    ($lines[$start..($lines.Count - 1)] -join "`n").TrimStart("`n")
}

function pushFile ($state, [string]$fp) {
    $rel     = relPath $fp
    $title   = fileTitle $fp
    $hash    = sha256 $fp
    $node    = getNode $state $rel
    $content = Get-Content -Raw $fp -Encoding UTF8
    $body    = larkBody $content

    # Resolve expected Lark parent for this file
    $folder      = nodeFolder $rel
    $parentToken = $null
    if ($folder) {
        $state = ensureFolder $state $folder
        if ($state.folders.PSObject.Properties[$folder]) {
            $parentToken = $state.folders.$folder
        }
    }

    if ($node) {
        Write-Host "  -> $rel"
        $r = $body | & $lark docs +update --api-version v2 `
                --doc $node.obj_token --command overwrite `
                --doc-format markdown --content - --as user
        $j = parseJson $r
        if ($j -and $j.ok) {
            & $lark docs +update --api-version v2 --doc $node.obj_token `
                --command str_replace --pattern "Untitled" --content $title --as user | Out-Null

            # Move node if it is in the wrong Lark folder
            $storedParent = if ($node.PSObject.Properties["parent_node_token"]) { $node.parent_node_token } else { $null }
            if ($parentToken -ne $storedParent) {
                $moveArgs = @("+move", "--node-token", $node.node_token,
                              "--target-space-id", $state.space_id, "--as", "user")
                if ($parentToken) { $moveArgs += @("--target-parent-token", $parentToken) }
                & $lark wiki @moveArgs | Out-Null
                $node | Add-Member -NotePropertyName parent_node_token -NotePropertyValue $parentToken -Force
                $dest = if ($folder) { "'$folder'" } else { "root" }
                Write-Host "    moved -> $dest"
            }

            $node.local_hash = $hash
            $node.last_sync  = (Get-Date -Format "o")
            if ($j.data.document.revision_id) { $node.lark_revision = $j.data.document.revision_id }
            setNode $state $rel $node
            Write-Host "    OK updated (rev $($node.lark_revision))"
        } else {
            Write-Warning "    FAIL push"
        }
    } else {
        Write-Host "  + $rel ($title)"

        $crArgs = @("+node-create", "--space-id", $state.space_id, "--title", $title, "--as", "user")
        if ($parentToken) { $crArgs += @("--parent-node-token", $parentToken) }
        $cr = & $lark wiki @crArgs
        $cj = parseJson $cr
        if (-not ($cj -and $cj.ok)) { Write-Warning "    FAIL create node"; return $state }

        $ot = $cj.data.obj_token
        $nt = $cj.data.node_token

        $ur = $body | & $lark docs +update --api-version v2 `
                --doc $ot --command overwrite `
                --doc-format markdown --content - --as user
        $uj = parseJson $ur

        & $lark docs +update --api-version v2 --doc $ot `
            --command str_replace --pattern "Untitled" --content $title --as user | Out-Null

        setNode $state $rel ([PSCustomObject]@{
            node_token        = $nt
            obj_token         = $ot
            title             = $title
            local_hash        = $hash
            lark_revision     = if ($uj -and $uj.data.document.revision_id) { $uj.data.document.revision_id } else { 1 }
            last_sync         = (Get-Date -Format "o")
            parent_node_token = $parentToken
        })
        Write-Host "    OK created (node $nt)"
    }
    $state
}

# ── Pull one node from Lark ───────────────────────────────────────────────────

function pullNode ($state, [string]$rel) {
    $node = getNode $state $rel
    if (-not $node) { Write-Warning "  no tracked node for: $rel"; return $state }

    Write-Host "  <- $rel"
    $r = & $lark docs +fetch --api-version v2 --doc $node.obj_token `
            --doc-format markdown --as user
    $j = parseJson $r
    if (-not ($j -and $j.ok)) {
        Write-Warning "    FAIL fetch (docx:document:readonly scope may not be granted yet)"
        return $state
    }

    $fp  = fullPath $rel
    $dir = [IO.Path]::GetDirectoryName($fp)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $j.data.document.content | Set-Content $fp -Encoding UTF8 -NoNewline

    $node.local_hash    = sha256 $fp
    $node.lark_revision = $j.data.document.revision_id
    $node.last_sync     = (Get-Date -Format "o")
    setNode $state $rel $node
    Write-Host "    OK pulled (rev $($node.lark_revision))"
    $state
}

# ── init ──────────────────────────────────────────────────────────────────────

function cmdInit {
    $state = readState
    if (-not $state.space_id) {
        Write-Error "Space ID required. Set `$env:LARK_WIKI_SPACE_ID before running init."
        return
    }
    $files = @(localFiles)
    if ($files.Count -eq 0) {
        Write-Host "No .md files found - add some and run '.\scripts\sync.ps1 push'."
    } else {
        Write-Host "Pushing $($files.Count) file(s) to space $($state.space_id)..."
        foreach ($f in $files) { $state = pushFile $state $f.FullName }
    }
    saveState $state
    Write-Host ""
    Write-Host "Done. State saved to .lark-sync.json"
}

# ── push ──────────────────────────────────────────────────────────────────────

function cmdPush ([string]$target) {
    $state = readState

    if ($target) {
        $fp = if ([IO.Path]::IsPathRooted($target)) { $target } else { fullPath $target }
        if (-not (Test-Path $fp)) { Write-Error "File not found: $fp"; return }
        $state = pushFile $state $fp
    } else {
        $changed = @(localFiles | Where-Object { needsPush $state $_ })
        if ($changed.Count -eq 0) { Write-Host "Nothing to push."; return }
        Write-Host "Pushing $($changed.Count) file(s)..."
        foreach ($f in $changed) { $state = pushFile $state $f.FullName }
    }
    saveState $state
}

# ── pull ──────────────────────────────────────────────────────────────────────

function cmdPull ([string]$target) {
    $state = readState
    if ($target) {
        $state = pullNode $state $target
    } else {
        $keys = @($state.nodes.PSObject.Properties.Name)
        if ($keys.Count -eq 0) { Write-Host "No tracked nodes."; return }
        Write-Host "Pulling $($keys.Count) node(s)..."
        foreach ($k in $keys) { $state = pullNode $state $k }
    }
    saveState $state
}

# ── sync ──────────────────────────────────────────────────────────────────────

function cmdSync {
    $state = readState

    $files    = @(localFiles)
    $localMap = @{}
    foreach ($f in $files) { $localMap[(relPath $f.FullName)] = $f }

    $localChanged = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $files) {
        if (needsPush $state $f) { $localChanged.Add((relPath $f.FullName)) }
    }

    $toPull    = [System.Collections.Generic.List[hashtable]]::new()
    $conflicts = [System.Collections.Generic.List[string]]::new()

    foreach ($prop in $state.nodes.PSObject.Properties) {
        $rel = $prop.Name
        $n   = $prop.Value
        $r   = & $lark docs +fetch --api-version v2 --doc $n.obj_token `
                    --doc-format markdown --as user
        $j   = parseJson $r
        if (-not ($j -and $j.ok)) { continue }

        if ($j.data.document.revision_id -gt $n.lark_revision) {
            if ($localChanged.Contains($rel)) {
                $conflicts.Add($rel)
                $localChanged.Remove($rel) | Out-Null
            } else {
                $toPull.Add(@{ Rel = $rel; Content = $j.data.document.content; Rev = $j.data.document.revision_id })
            }
        }
    }

    if ($conflicts.Count -gt 0) {
        Write-Host ""
        Write-Host "CONFLICTS (both sides changed - resolve manually):"
        foreach ($c in $conflicts) { Write-Host "  ! $c" }
    }
    if ($localChanged.Count -gt 0) {
        Write-Host ""
        Write-Host "Pushing $($localChanged.Count) local change(s)..."
        foreach ($rel in $localChanged) {
            $fp    = if ($localMap.ContainsKey($rel)) { $localMap[$rel].FullName } else { fullPath $rel }
            $state = pushFile $state $fp
        }
    }
    if ($toPull.Count -gt 0) {
        Write-Host ""
        Write-Host "Pulling $($toPull.Count) Lark change(s)..."
        foreach ($item in $toPull) {
            $fp  = fullPath $item.Rel
            $dir = [IO.Path]::GetDirectoryName($fp)
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
            $item.Content | Set-Content $fp -Encoding UTF8 -NoNewline
            $n               = getNode $state $item.Rel
            $n.local_hash    = sha256 $fp
            $n.lark_revision = $item.Rev
            $n.last_sync     = (Get-Date -Format "o")
            setNode $state $item.Rel $n
            Write-Host "  <- $($item.Rel)"
        }
    }
    if ($localChanged.Count -eq 0 -and $toPull.Count -eq 0 -and $conflicts.Count -eq 0) {
        Write-Host "Everything in sync."
    }
    saveState $state
}

# ── status ────────────────────────────────────────────────────────────────────

function cmdStatus {
    $state  = readState
    $files  = @(localFiles)
    $counts = @{ new = 0; modified = 0; moved = 0; synced = 0; lark_only = 0 }

    foreach ($f in $files) {
        $rel = relPath $f.FullName
        $n   = getNode $state $rel
        if (-not $n) {
            Write-Host "  [?] $rel  (new, not pushed)"
            $counts.new++
        } elseif ((sha256 $f.FullName) -ne $n.local_hash) {
            Write-Host "  [M] $rel  (modified locally)"
            $counts.modified++
        } elseif (needsPush $state $f) {
            Write-Host "  [P] $rel  (wrong folder in Lark)"
            $counts.moved++
        } else {
            $counts.synced++
        }
    }

    $tracked = @($files | ForEach-Object { relPath $_.FullName })
    foreach ($prop in $state.nodes.PSObject.Properties) {
        if ($tracked -notcontains $prop.Name) {
            Write-Host "  [L] $($prop.Name)  (in Lark only)"
            $counts.lark_only++
        }
    }

    Write-Host ""
    Write-Host "Synced:$($counts.synced)  Modified:$($counts.modified)  Moved:$($counts.moved)  New:$($counts.new)  Lark-only:$($counts.lark_only)"
    Write-Host "Space: $($state.space_id)  (wiki root)"
    if ($state.folders.PSObject.Properties.Count -gt 0) {
        Write-Host "Folders: $($state.folders.PSObject.Properties.Name -join ', ')"
    }
}

# ── entry point ───────────────────────────────────────────────────────────────

switch ($Command) {
    "init"   { cmdInit }
    "push"   { cmdPush $File }
    "pull"   { cmdPull $File }
    "sync"   { cmdSync }
    "status" { cmdStatus }
}
