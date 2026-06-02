# lark-tasks-sync.ps1 - Sync vault task notes and kanban board items to/from Lark Tasks
# Usage: pwsh -File scripts/lark-tasks-sync.ps1 <command> [-Target <path|task-guid>] [-VaultRoot <path>]
# Commands: init, push [path], pull [task-guid], sync, status
#
# Configuration:
#   No env var required beyond lark-cli auth. State tracked in .lark-tasks-sync.json.
#   Scans both Tasks/ folder (type: task notes) and kanban board files (kanban-plugin: board).
#   Assignees are resolved from person notes via lark_user_id: frontmatter.

param(
    [Parameter(Position=0)]
    [ValidateSet("init","push","pull","sync","status")]
    [string]$Command = "status",

    [Parameter(Position=1)]
    [string]$Target = "",

    [string]$VaultRoot = $PWD.Path
)

$npmBin = "$env:APPDATA\npm"
if ($env:PATH -notlike "*$npmBin*") { $env:PATH = "$npmBin;$env:PATH" }

$lark      = "lark-cli"
$statePath = Join-Path $VaultRoot ".lark-tasks-sync.json"

# Status mapping: vault -> Lark
$STATUS_MAP = @{
    "todo"        = "to_do"
    "in-progress" = "in_progress"
    "blocked"     = "in_progress"
    "done"        = "completed"
    "cancelled"   = "abandoned"
}

# Reverse status mapping: Lark -> vault
$STATUS_RMAP = @{
    "to_do"      = "todo"
    "in_progress"= "in-progress"
    "completed"  = "done"
    "abandoned"  = "cancelled"
}

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

function relPath ([string]$full) { $full.Substring($VaultRoot.Length).TrimStart('\', '/') }

function readState {
    if (Test-Path $statePath) { return Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    [PSCustomObject]@{ tasks = [PSCustomObject]@{} }
}

function saveState ($s) {
    $s | ConvertTo-Json -Depth 10 | Set-Content $statePath -Encoding UTF8
}

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

# Parse subtask checklist items from note body (## Subtasks section)
function parseSubtasks ([string]$path) {
    $lines    = Get-Content $path -Encoding UTF8
    $inSection = $false
    $items    = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($line in $lines) {
        if ($line -match '^## Subtasks') { $inSection = $true; continue }
        if ($inSection -and $line -match '^## ') { break }
        if ($inSection -and $line -match '^- \[([ x])\] (.+)') {
            $items.Add(@{ title = $Matches[2].Trim(); done = ($Matches[1] -eq 'x') })
        }
    }
    $items
}

# Resolve an assignee name to a Lark user ID via person notes
function resolveAssignee ([string]$name) {
    if (-not $name) { return "" }
    $cleaned = $name -replace '[\[\]]', '' | ForEach-Object { $_.Trim() }
    $personNote = Join-Path $VaultRoot "People/$cleaned.md"
    if (Test-Path $personNote) {
        $fm = parseFrontmatter $personNote
        if ($fm["lark_user_id"]) { return $fm["lark_user_id"] }
    }
    Write-Host "    WARNING: no lark_user_id for '$cleaned' - assignee not synced"
    return ""
}

# Convert YYYY-MM-DD to Unix ms timestamp
function dateToTimestamp ([string]$d) {
    try {
        [int64](([datetime]::ParseExact($d.Trim(), "yyyy-MM-dd", $null)).ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,0,[DateTimeKind]::Utc)).TotalMilliseconds
    } catch { 0 }
}

# ── Collect all vault task notes ──────────────────────────────────────────────

function allTaskFiles {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $list = [System.Collections.Generic.List[string]]::new()

    # Type: task notes
    Get-ChildItem -Path $VaultRoot -Filter "*.md" -File -Recurse |
        Where-Object { $_.Name -notlike "_CLAUDE*" } |
        Where-Object { (parseFrontmatter $_.FullName)["type"] -eq "task" } |
        ForEach-Object { if ($seen.Add($_.FullName)) { $list.Add($_.FullName) } }

    $list
}

# ── Build Lark Task payload from vault task note ──────────────────────────────

function buildTaskPayload ([string]$fp) {
    $fm       = parseFrontmatter $fp
    $title    = if ($fm["title"]) { $fm["title"] } else { [IO.Path]::GetFileNameWithoutExtension($fp) }
    $status   = if ($fm["status"] -and $STATUS_MAP.ContainsKey($fm["status"])) { $STATUS_MAP[$fm["status"]] } else { "to_do" }
    $due      = if ($fm["due"]) { dateToTimestamp $fm["due"] } else { 0 }
    $assignee = if ($fm["assignee"]) { resolveAssignee ($fm["assignee"] -replace '[\[\]]', '').Trim() } else { "" }
    $isBlocked = $fm["status"] -eq "blocked"

    @{
        title      = $title
        status     = $status
        due        = $due
        assignee   = $assignee
        is_blocked = $isBlocked
    }
}

# ── Push one task note to Lark Tasks ──────────────────────────────────────────

function pushTask ($state, [string]$fp) {
    $rel      = relPath $fp
    $fm       = parseFrontmatter $fp
    $payload  = buildTaskPayload $fp
    $existGuid = if ($fm["lark_task_guid"]) { $fm["lark_task_guid"] } else { "" }
    $tracked  = if ($state.tasks.PSObject.Properties[$rel]) { $state.tasks.$rel } else { $null }
    $taskGuid = if ($existGuid) { $existGuid } elseif ($tracked -and $tracked.task_guid) { $tracked.task_guid } else { "" }

    $duePart      = if ($payload.due) { "--due $($payload.due)" } else { "" }
    $assigneePart = if ($payload.assignee) { "--member-user-id $($payload.assignee)" } else { "" }

    if ($taskGuid) {
        Write-Host "  -> $($payload.title) ($rel)"
        $r = & $lark task +task-update `
                --task-guid $taskGuid `
                --title $payload.title `
                --status $payload.status `
                --as user
        $j = parseJson $r
        if ($j -and $j.ok) {
            $state.tasks.$rel.local_hash = sha256 $fp
            $state.tasks.$rel.last_sync  = (Get-Date -Format "o")
            Write-Host "    OK updated"

            # Sync subtasks
            $subs = parseSubtasks $fp
            if ($subs.Count -gt 0) {
                foreach ($sub in $subs) {
                    & $lark task +subtask-create `
                            --task-guid $taskGuid `
                            --title $sub.title `
                            --as user | Out-Null
                }
            }
        } else {
            Write-Warning "    FAIL update: $($j.msg)"
        }
    } else {
        Write-Host "  + $($payload.title) ($rel)"
        $r = & $lark task +task-create `
                --title $payload.title `
                --status $payload.status `
                --as user
        $j = parseJson $r
        if ($j -and $j.ok) {
            $newGuid = $j.data.task.guid
            # Write lark_task_guid back to vault note
            $content = Get-Content $fp -Raw -Encoding UTF8
            if ($content -notmatch 'lark_task_guid:') {
                $content = $content -replace '(?m)^(---\s*\n)', "`$1lark_task_guid: $newGuid`n"
                $content | Set-Content $fp -Encoding UTF8 -NoNewline
            }
            if (-not $state.tasks.PSObject.Properties[$rel]) {
                $state.tasks | Add-Member -NotePropertyName $rel -NotePropertyValue ([PSCustomObject]@{
                    task_guid  = $newGuid
                    local_hash = sha256 $fp
                    last_sync  = (Get-Date -Format "o")
                })
            }
            Write-Host "    OK created (guid $newGuid)"

            # Create subtasks
            $subs = parseSubtasks $fp
            foreach ($sub in $subs) {
                & $lark task +subtask-create `
                        --task-guid $newGuid `
                        --title $sub.title `
                        --as user | Out-Null
            }
        } else {
            Write-Warning "    FAIL create: $($j.msg)"
        }
    }
    $state
}

# ── Pull one Lark Task to vault ───────────────────────────────────────────────

function pullTask ($state, [string]$taskGuid) {
    Write-Host "  <- task $taskGuid"
    $r = & $lark task +task-get --task-guid $taskGuid --as user
    $j = parseJson $r
    if (-not ($j -and $j.ok)) { Write-Warning "    FAIL fetch: $($j.msg)"; return $state }

    $t       = $j.data.task
    $title   = $t.title
    $larkSt  = if ($t.status) { $t.status } else { "to_do" }
    $vaultSt = if ($STATUS_RMAP.ContainsKey($larkSt)) { $STATUS_RMAP[$larkSt] } else { "todo" }
    $today   = (Get-Date -Format "yyyy-MM-dd")

    # Find existing note with this task guid
    $existingNote = Get-ChildItem -Path $VaultRoot -Filter "*.md" -File -Recurse |
        Where-Object { (parseFrontmatter $_.FullName)["lark_task_guid"] -eq $taskGuid } |
        Select-Object -First 1

    if ($existingNote) {
        $fp      = $existingNote.FullName
        $content = Get-Content $fp -Raw -Encoding UTF8
        $content = $content -replace '(?m)^status:.*$', "status: $vaultSt"
        $content | Set-Content $fp -Encoding UTF8 -NoNewline
        $rel = relPath $fp
        if ($state.tasks.PSObject.Properties[$rel]) {
            $state.tasks.$rel.local_hash = sha256 $fp
            $state.tasks.$rel.last_sync  = (Get-Date -Format "o")
        }
        Write-Host "    OK updated $fp"
    } else {
        # Create a new task note
        $safeTitle = ($title -replace '[\\/:*?"<>|]', ' ').Trim()
        $tasksDir  = Join-Path $VaultRoot "Tasks"
        if (-not (Test-Path $tasksDir)) { New-Item -ItemType Directory $tasksDir -Force | Out-Null }
        $fp   = Join-Path $tasksDir "$safeTitle.md"
        $stub = @"
---
date: $today
type: task
tags: [task]
ai-first: true
title: "$title"
status: $vaultSt
priority: medium
lark_task_guid: "$taskGuid"
---

## For future Claude
This task note was pulled from Lark Tasks on $today. Status and title are synced from Lark; the note body is the vault's place for context, blockers, and subtask detail.

## Context


## Subtasks


## Notes

"@
        $stub | Set-Content $fp -Encoding UTF8 -NoNewline
        $rel = relPath $fp
        $state.tasks | Add-Member -NotePropertyName $rel -NotePropertyValue ([PSCustomObject]@{
            task_guid  = $taskGuid
            local_hash = sha256 $fp
            last_sync  = (Get-Date -Format "o")
        }) -Force
        Write-Host "    OK created $fp"
    }
    $state
}

# ── init ──────────────────────────────────────────────────────────────────────

function cmdInit {
    $state = readState
    $files = @(allTaskFiles)

    if ($files.Count -eq 0) {
        Write-Host "No task notes found. Add some tasks and run push."
        return
    }

    Write-Host "Pushing $($files.Count) task(s) to Lark Tasks..."
    foreach ($fp in $files) { $state = pushTask $state $fp }
    saveState $state
    Write-Host "`nDone. State saved to .lark-tasks-sync.json"
}

# ── push ──────────────────────────────────────────────────────────────────────

function cmdPush ([string]$target) {
    $state = readState

    if ($target) {
        $fp = if ([IO.Path]::IsPathRooted($target)) { $target } else { Join-Path $VaultRoot $target }
        if (-not (Test-Path $fp)) { Write-Error "File not found: $fp"; return }
        $state = pushTask $state $fp
    } else {
        $files   = @(allTaskFiles)
        $changed = $files | Where-Object {
            $rel = relPath $_
            $n   = if ($state.tasks.PSObject.Properties[$rel]) { $state.tasks.$rel } else { $null }
            -not $n -or (sha256 $_) -ne $n.local_hash
        }
        if (@($changed).Count -eq 0) { Write-Host "All tasks in sync."; return }
        Write-Host "Pushing $(@($changed).Count) changed task(s)..."
        foreach ($fp in $changed) { $state = pushTask $state $fp }
    }
    saveState $state
}

# ── pull ──────────────────────────────────────────────────────────────────────

function cmdPull ([string]$target) {
    $state = readState

    if ($target) {
        $state = pullTask $state $target
    } else {
        foreach ($prop in $state.tasks.PSObject.Properties) {
            if ($prop.Value.task_guid) { $state = pullTask $state $prop.Value.task_guid }
        }
    }
    saveState $state
}

# ── sync ──────────────────────────────────────────────────────────────────────

function cmdSync {
    $state = readState

    $files = @(allTaskFiles)
    $localChanged = [System.Collections.Generic.List[string]]::new()
    foreach ($fp in $files) {
        $rel = relPath $fp
        $n   = if ($state.tasks.PSObject.Properties[$rel]) { $state.tasks.$rel } else { $null }
        if (-not $n -or (sha256 $fp) -ne $n.local_hash) { $localChanged.Add($fp) }
    }

    $conflicts = [System.Collections.Generic.List[string]]::new()
    $toPull    = [System.Collections.Generic.List[string]]::new()

    foreach ($prop in $state.tasks.PSObject.Properties) {
        $rel  = $prop.Name
        $n    = $prop.Value
        $guid = $n.task_guid
        if (-not $guid) { continue }

        $r = & $lark task +task-get --task-guid $guid --as user
        $j = parseJson $r
        if (-not ($j -and $j.ok)) { continue }

        $larkUpdated = $j.data.task.updated_at
        if ($larkUpdated -and $larkUpdated -gt ([datetimeoffset]::Parse($n.last_sync).ToUnixTimeMilliseconds())) {
            if ($localChanged.Contains($rel)) {
                $conflicts.Add($rel)
                $localChanged.Remove($rel) | Out-Null
            } else {
                $toPull.Add($guid)
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
        foreach ($fp in $localChanged) { $state = pushTask $state $fp }
    }
    if ($toPull.Count -gt 0) {
        Write-Host ""
        Write-Host "Pulling $($toPull.Count) Lark change(s)..."
        foreach ($guid in $toPull) { $state = pullTask $state $guid }
    }
    if ($localChanged.Count -eq 0 -and $toPull.Count -eq 0 -and $conflicts.Count -eq 0) {
        Write-Host "Everything in sync."
    }
    saveState $state
}

# ── status ────────────────────────────────────────────────────────────────────

function cmdStatus {
    $state  = readState
    $files  = @(allTaskFiles)
    $counts = @{ new = 0; modified = 0; synced = 0 }

    foreach ($fp in $files) {
        $rel = relPath $fp
        $n   = if ($state.tasks.PSObject.Properties[$rel]) { $state.tasks.$rel } else { $null }
        $fm  = parseFrontmatter $fp
        $title = if ($fm["title"]) { $fm["title"] } else { [IO.Path]::GetFileNameWithoutExtension($fp) }
        if (-not $n) {
            Write-Host "  [?] $title  ($rel)"
            $counts.new++
        } elseif ((sha256 $fp) -ne $n.local_hash) {
            Write-Host "  [M] $title  ($rel)"
            $counts.modified++
        } else {
            $counts.synced++
        }
    }

    Write-Host ""
    Write-Host "Synced:$($counts.synced)  Modified:$($counts.modified)  New:$($counts.new)"
    Write-Host "Total task notes: $($files.Count)"
}

# ── entry point ───────────────────────────────────────────────────────────────

switch ($Command) {
    "init"   { cmdInit }
    "push"   { cmdPush $Target }
    "pull"   { cmdPull $Target }
    "sync"   { cmdSync }
    "status" { cmdStatus }
}
