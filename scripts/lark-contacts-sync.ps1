# lark-contacts-sync.ps1 - Sync vault person notes to/from Lark Contacts
# Usage: pwsh -File scripts/lark-contacts-sync.ps1 <command> [-Target <path|user-id>] [-VaultRoot <path>]
# Commands: import, push [path], pull [user-id], sync, status
#
# Configuration:
#   Lark Contact API uses the app's OAuth token - no extra env var needed beyond lark-cli auth.
#   State is tracked in .lark-contacts-sync.json.
#   Person notes must have type: person frontmatter. Notes with lark_user_id: frontmatter
#   are treated as already linked to a Lark Contact.

param(
    [Parameter(Position=0)]
    [ValidateSet("import","push","pull","sync","status")]
    [string]$Command = "status",

    [Parameter(Position=1)]
    [string]$Target = "",

    [string]$VaultRoot = $PWD.Path
)

$npmBin = "$env:APPDATA\npm"
if ($env:PATH -notlike "*$npmBin*") { $env:PATH = "$npmBin;$env:PATH" }

$lark      = "lark-cli"
$statePath = Join-Path $VaultRoot ".lark-contacts-sync.json"

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

function relPath ([string]$full) {
    $full.Substring($VaultRoot.Length).TrimStart('\', '/')
}

function readState {
    if (Test-Path $statePath) { return Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    [PSCustomObject]@{ contacts = [PSCustomObject]@{} }
}

function saveState ($s) {
    $s | ConvertTo-Json -Depth 10 | Set-Content $statePath -Encoding UTF8
}

# Parse YAML frontmatter from a markdown file; returns hashtable
function parseFrontmatter ([string]$path) {
    $lines  = Get-Content $path -Encoding UTF8
    $result = @{}
    if ($lines.Count -lt 2 -or $lines[0] -ne "---") { return $result }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq "---") { break }
        if ($lines[$i] -match '^(\w[\w-]*):\s*(.*)$') {
            $result[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
        }
    }
    $result
}

function personNotes {
    Get-ChildItem -Path (Join-Path $VaultRoot "People") -Filter "*.md" -File -ErrorAction SilentlyContinue |
        Where-Object { (parseFrontmatter $_.FullName)["type"] -eq "person" }
}

# ── Push one person note to Lark Contacts ────────────────────────────────────

function pushContact ($state, [string]$fp) {
    $fm  = parseFrontmatter $fp
    $rel = relPath $fp

    $name     = if ($fm["name"]) { $fm["name"] } else { [IO.Path]::GetFileNameWithoutExtension($fp) }
    $email    = if ($fm["email"]) { $fm["email"] } else { "" }
    $role     = if ($fm["role"]) { $fm["role"] } else { "" }
    $org      = if ($fm["org"]) { $fm["org"] } else { "" }
    $mobile   = if ($fm["mobile"]) { $fm["mobile"] } else { "" }
    $strength = if ($fm["strength"]) { $fm["strength"] } else { "medium" }
    $userId   = if ($fm["lark_user_id"]) { $fm["lark_user_id"] } else { "" }

    $existing = if ($state.contacts.PSObject.Properties[$rel]) { $state.contacts.$rel } else { $null }
    $linkedId = if ($userId) { $userId } elseif ($existing -and $existing.user_id) { $existing.user_id } else { "" }

    if ($linkedId) {
        # Update existing Lark contact
        Write-Host "  -> $name ($rel)"
        $r = & $lark contact +user-update `
                --user-id $linkedId `
                --name $name `
                --job-title $role `
                --department $org `
                --as user
        $j = parseJson $r
        if ($j -and $j.ok) {
            if ($state.contacts.PSObject.Properties[$rel]) {
                $state.contacts.$rel.local_hash = sha256 $fp
                $state.contacts.$rel.last_sync  = (Get-Date -Format "o")
            }
            Write-Host "    OK updated"
        } else {
            Write-Warning "    FAIL update: $($j.msg)"
        }
    } else {
        # Search for an existing contact by email first to avoid duplicates
        if ($email) {
            Write-Host "  ? searching Lark for $email..."
            $sr = & $lark contact +user-search --query $email --as user
            $sj = parseJson $sr
            if ($sj -and $sj.ok -and $sj.data.user_list.Count -gt 0) {
                $linkedId = $sj.data.user_list[0].user_id
                Write-Host "    found user_id: $linkedId - linking without creating duplicate"
            }
        }
        if ($linkedId) {
            # Link to found contact
            if (-not $state.contacts.PSObject.Properties[$rel]) {
                $state.contacts | Add-Member -NotePropertyName $rel -NotePropertyValue ([PSCustomObject]@{
                    user_id    = $linkedId
                    name       = $name
                    local_hash = sha256 $fp
                    last_sync  = (Get-Date -Format "o")
                })
            }
            # Write lark_user_id back to vault note frontmatter
            $content = Get-Content $fp -Raw -Encoding UTF8
            if ($content -notmatch 'lark_user_id:') {
                $content = $content -replace '(?m)^(---\s*\n)', "`$1lark_user_id: $linkedId`n"
                $content | Set-Content $fp -Encoding UTF8 -NoNewline
            }
            Write-Host "    OK linked (user $linkedId)"
        } else {
            Write-Host "  + $name ($rel) - contact not in Lark directory (external person, skipping create)"
            Write-Host "    TIP: Lark Contacts API only updates existing org members. For external contacts, use Lark Base Persons table instead."
        }
    }
    $state
}

# ── Pull one Lark contact to vault ───────────────────────────────────────────

function pullContact ($state, [string]$userId) {
    Write-Host "  <- user $userId"
    $r = & $lark contact +user-get --user-id $userId --as user
    $j = parseJson $r
    if (-not ($j -and $j.ok)) { Write-Warning "    FAIL fetch: $($j.msg)"; return $state }

    $u    = $j.data.user
    $name = $u.name
    $fp   = Join-Path $VaultRoot "People/$name.md"

    if (Test-Path $fp) {
        # Sync name and fields into existing frontmatter
        $content = Get-Content $fp -Raw -Encoding UTF8
        if ($u.job_title) { $content = $content -replace '(?m)^role:.*$', "role: $($u.job_title)" }
        if ($u.enterprise_email) { $content = $content -replace '(?m)^email:.*$', "email: $($u.enterprise_email)" }
        if ($content -notmatch 'lark_user_id:') {
            $content = $content -replace '(?m)^(---\s*\n)', "`$1lark_user_id: $userId`n"
        }
        $content | Set-Content $fp -Encoding UTF8 -NoNewline
        Write-Host "    OK updated $fp"
    } else {
        # Create a new person stub
        $today = (Get-Date -Format "yyyy-MM-dd")
        $email = if ($u.enterprise_email) { $u.enterprise_email } else { "TBD" }
        $role  = if ($u.job_title) { $u.job_title } else { "TBD" }
        $dept  = if ($u.department) { $u.department } else { "TBD" }
        $stub  = @"
---
date: $today
type: person
tags: [person]
ai-first: true
name: "$name"
email: "$email"
role: "$role"
org: "$dept"
strength: medium
lark_user_id: "$userId"
---

## For future Claude
This note is a person record for $name imported from Lark Contacts on $today. Contact details were pulled from the Lark directory; the note body is empty pending real interactions.

## Context


## Interactions


## Notes

"@
        $dir = Split-Path $fp -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
        $stub | Set-Content $fp -Encoding UTF8 -NoNewline
        Write-Host "    OK created $fp"
    }

    $rel = relPath $fp
    if (-not $state.contacts.PSObject.Properties[$rel]) {
        $state.contacts | Add-Member -NotePropertyName $rel -NotePropertyValue ([PSCustomObject]@{
            user_id    = $userId
            name       = $name
            local_hash = sha256 $fp
            last_sync  = (Get-Date -Format "o")
        })
    } else {
        $state.contacts.$rel.local_hash = sha256 $fp
        $state.contacts.$rel.last_sync  = (Get-Date -Format "o")
    }
    $state
}

# ── import ────────────────────────────────────────────────────────────────────

function cmdImport {
    $state = readState
    Write-Host "Pulling all Lark Contacts..."
    $r = & $lark contact +user-list --as user
    $j = parseJson $r
    if (-not ($j -and $j.ok)) { Write-Warning "FAIL list contacts: $($j.msg)"; return }

    foreach ($u in $j.data.items) {
        $state = pullContact $state $u.user_id
    }
    saveState $state
    Write-Host "`nDone. State saved to .lark-contacts-sync.json"
}

# ── push ──────────────────────────────────────────────────────────────────────

function cmdPush ([string]$target) {
    $state = readState

    if ($target) {
        $fp = if ([IO.Path]::IsPathRooted($target)) { $target } else { Join-Path $VaultRoot $target }
        if (-not (Test-Path $fp)) { Write-Error "File not found: $fp"; return }
        $state = pushContact $state $fp
    } else {
        $files = @(personNotes)
        if ($files.Count -eq 0) { Write-Host "No person notes found in People/."; return }
        $changed = $files | Where-Object {
            $rel = relPath $_.FullName
            $n   = if ($state.contacts.PSObject.Properties[$rel]) { $state.contacts.$rel } else { $null }
            -not $n -or (sha256 $_.FullName) -ne $n.local_hash
        }
        if (@($changed).Count -eq 0) { Write-Host "All contacts in sync."; return }
        Write-Host "Pushing $(@($changed).Count) changed person note(s)..."
        foreach ($f in $changed) { $state = pushContact $state $f.FullName }
    }
    saveState $state
}

# ── pull ──────────────────────────────────────────────────────────────────────

function cmdPull ([string]$target) {
    $state = readState

    if ($target) {
        $state = pullContact $state $target
    } else {
        foreach ($prop in $state.contacts.PSObject.Properties) {
            $state = pullContact $state $prop.Value.user_id
        }
    }
    saveState $state
}

# ── sync ──────────────────────────────────────────────────────────────────────

function cmdSync {
    Write-Host "Pushing local changes..."
    cmdPush ""
    Write-Host "`nPulling Lark changes..."
    cmdPull ""
}

# ── status ────────────────────────────────────────────────────────────────────

function cmdStatus {
    $state  = readState
    $files  = @(personNotes)
    $counts = @{ new = 0; modified = 0; synced = 0; linked = 0 }

    foreach ($f in $files) {
        $rel = relPath $f.FullName
        $fm  = parseFrontmatter $f.FullName
        $n   = if ($state.contacts.PSObject.Properties[$rel]) { $state.contacts.$rel } else { $null }
        $hasId = $fm["lark_user_id"] -or ($n -and $n.user_id)

        if (-not $n) {
            $marker = if ($hasId) { "[L]" } else { "[?]" }
            Write-Host "  $marker $rel  (not pushed)"
            $counts.new++
        } elseif ((sha256 $f.FullName) -ne $n.local_hash) {
            Write-Host "  [M] $rel  (modified)"
            $counts.modified++
        } else {
            $counts.synced++
        }
    }

    Write-Host "`nSynced:$($counts.synced)  Modified:$($counts.modified)  New:$($counts.new)"
    Write-Host "Total person notes: $($files.Count)"
}

# ── entry point ───────────────────────────────────────────────────────────────

switch ($Command) {
    "import" { cmdImport }
    "push"   { cmdPush $Target }
    "pull"   { cmdPull $Target }
    "sync"   { cmdSync }
    "status" { cmdStatus }
}
