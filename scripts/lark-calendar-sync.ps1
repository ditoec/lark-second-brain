# lark-calendar-sync.ps1 - Sync vault meeting notes and task due dates to/from Lark Calendar
# Usage: pwsh -File scripts/lark-calendar-sync.ps1 <command> [-Target <meetings|schedule|path|event-id>] [-VaultRoot <path>]
# Commands: init, push [meetings|schedule|path], pull [event-id], sync, status
#
# Configuration:
#   Set $env:LARK_CALENDAR_ID for a non-primary calendar, else the primary calendar is used.
#   State is tracked in .lark-calendar-sync.json.
#   Meeting notes must have type: meeting frontmatter.
#   Tasks with a due: date field are eligible for schedule push.

param(
    [Parameter(Position=0)]
    [ValidateSet("init","push","pull","sync","status")]
    [string]$Command = "status",

    [Parameter(Position=1)]
    [string]$Target = "",

    [string]$VaultRoot = $PWD.Path
)

$npmBin     = "$env:APPDATA\npm"
if ($env:PATH -notlike "*$npmBin*") { $env:PATH = "$npmBin;$env:PATH" }

$lark       = "lark-cli"
$statePath  = Join-Path $VaultRoot ".lark-calendar-sync.json"
$calendarId = if ($env:LARK_CALENDAR_ID) { $env:LARK_CALENDAR_ID } else { "primary" }

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
    if (Test-Path $statePath) {
        $s = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($calendarId -and $s.calendar_id -ne $calendarId) { $s.calendar_id = $calendarId }
        return $s
    }
    [PSCustomObject]@{ calendar_id = $calendarId; events = [PSCustomObject]@{} }
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

# Resolve attendee list to Lark user IDs via person notes
function resolveAttendees ([string[]]$names) {
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        $cleaned = $name -replace '[\[\]]', '' | ForEach-Object { $_.Trim() }
        if (-not $cleaned) { continue }
        $personNote = Join-Path $VaultRoot "People/$cleaned.md"
        if (Test-Path $personNote) {
            $fm = parseFrontmatter $personNote
            if ($fm["lark_user_id"]) { $ids.Add($fm["lark_user_id"]) }
            elseif ($fm["email"]) {
                $sr = & $lark contact +user-search --query $fm["email"] --as user
                $sj = parseJson $sr
                if ($sj -and $sj.ok -and $sj.data.user_list.Count -gt 0) {
                    $ids.Add($sj.data.user_list[0].user_id)
                }
            }
        }
    }
    $ids.ToArray()
}

# Parse attendees from frontmatter string (handles "[Name1, Name2]" or "Name1")
function parseAttendeeList ([string]$raw) {
    ($raw -replace '[\[\]]', '').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# Convert YYYY-MM-DD [HH:mm] to Unix timestamp (ms)
function dateToTimestamp ([string]$dateStr) {
    try {
        [int64](([datetime]::ParseExact($dateStr.Trim(), "yyyy-MM-dd", $null)).ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,0,[DateTimeKind]::Utc)).TotalMilliseconds
    } catch { 0 }
}

# ── Meeting notes ─────────────────────────────────────────────────────────────

function meetingNotes {
    $meetingsDir = Join-Path $VaultRoot "wiki/meetings"
    if (-not (Test-Path $meetingsDir)) {
        $meetingsDir = Join-Path $VaultRoot "Meetings"
    }
    Get-ChildItem -Path $meetingsDir -Filter "*.md" -File -ErrorAction SilentlyContinue |
        Where-Object { (parseFrontmatter $_.FullName)["type"] -eq "meeting" }
}

# ── Push a meeting note to Lark Calendar ─────────────────────────────────────

function pushMeeting ($state, [string]$fp) {
    $fm        = parseFrontmatter $fp
    $rel       = relPath $fp
    $title     = if ($fm["title"]) { $fm["title"] } else { [IO.Path]::GetFileNameWithoutExtension($fp) }
    $dateVal   = if ($fm["date"]) { $fm["date"] } else { (Get-Date -Format "yyyy-MM-dd") }
    $duration  = if ($fm["duration_minutes"]) { [int]$fm["duration_minutes"] } else { 60 }
    $location  = if ($fm["location"]) { $fm["location"] } else { "" }
    $existEvId = if ($fm["lark_event_id"]) { $fm["lark_event_id"] } else { "" }
    $tracked   = if ($state.events.PSObject.Properties[$rel]) { $state.events.$rel } else { $null }
    $eventId   = if ($existEvId) { $existEvId } elseif ($tracked -and $tracked.event_id) { $tracked.event_id } else { "" }

    $startTs = dateToTimestamp $dateVal
    $endTs   = $startTs + $duration * 60 * 1000

    $attendeeNames = if ($fm["attendees"]) { parseAttendeeList $fm["attendees"] } else { @() }
    $attendeeIds   = resolveAttendees $attendeeNames

    $attendeesArg = ($attendeeIds | ForEach-Object { "--attendee-user-id $_" }) -join " "

    if ($eventId) {
        Write-Host "  -> $title ($rel)"
        $r = & $lark calendar +event-update `
                --calendar-id $state.calendar_id `
                --event-id $eventId `
                --summary $title `
                --start-timestamp $startTs `
                --end-timestamp $endTs `
                --location $location `
                --as user
        $j = parseJson $r
        if ($j -and $j.ok) {
            $state.events.$rel.local_hash = sha256 $fp
            $state.events.$rel.last_sync  = (Get-Date -Format "o")
            Write-Host "    OK updated"
        } else {
            Write-Warning "    FAIL update: $($j.msg)"
        }
    } else {
        Write-Host "  + $title ($rel)"
        $r = & $lark calendar +event-create `
                --calendar-id $state.calendar_id `
                --summary $title `
                --start-timestamp $startTs `
                --end-timestamp $endTs `
                --location $location `
                --as user
        $j = parseJson $r
        if ($j -and $j.ok) {
            $newId = $j.data.event.event_id
            # Write lark_event_id back to vault note frontmatter
            $content = Get-Content $fp -Raw -Encoding UTF8
            if ($content -notmatch 'lark_event_id:') {
                $content = $content -replace '(?m)^(---\s*\n)', "`$1lark_event_id: $newId`n"
                $content | Set-Content $fp -Encoding UTF8 -NoNewline
            }
            if (-not $state.events.PSObject.Properties[$rel]) {
                $state.events | Add-Member -NotePropertyName $rel -NotePropertyValue ([PSCustomObject]@{
                    event_id   = $newId
                    local_hash = sha256 $fp
                    last_sync  = (Get-Date -Format "o")
                })
            }
            Write-Host "    OK created (event $newId)"
        } else {
            Write-Warning "    FAIL create: $($j.msg)"
        }
    }
    $state
}

# ── Push task due dates as calendar events ────────────────────────────────────

function pushSchedule ($state) {
    $taskFiles = Get-ChildItem -Path $VaultRoot -Filter "*.md" -File -Recurse |
        Where-Object { $_.Name -notlike "_CLAUDE*" } |
        Where-Object {
            $fm = parseFrontmatter $_.FullName
            $fm["type"] -eq "task" -and $fm["due"] -and $fm["status"] -ne "done"
        }

    foreach ($f in $taskFiles) {
        $fm    = parseFrontmatter $f.FullName
        $rel   = relPath $f.FullName
        $title = "[Task] " + (if ($fm["title"]) { $fm["title"] } else { [IO.Path]::GetFileNameWithoutExtension($f.FullName) })
        $due   = $fm["due"]
        $existEvId = if ($fm["lark_event_id"]) { $fm["lark_event_id"] } else { "" }
        $tracked   = if ($state.events.PSObject.Properties[$rel]) { $state.events.$rel } else { $null }
        $eventId   = if ($existEvId) { $existEvId } elseif ($tracked -and $tracked.event_id) { $tracked.event_id } else { "" }

        $startTs = dateToTimestamp $due
        $endTs   = $startTs + 3600000  # 1 hour

        if ($eventId) {
            Write-Host "  -> $title (due $due)"
            & $lark calendar +event-update `
                    --calendar-id $state.calendar_id `
                    --event-id $eventId `
                    --summary $title `
                    --start-timestamp $startTs `
                    --end-timestamp $endTs `
                    --as user | Out-Null
        } else {
            Write-Host "  + $title (due $due)"
            $r = & $lark calendar +event-create `
                    --calendar-id $state.calendar_id `
                    --summary $title `
                    --start-timestamp $startTs `
                    --end-timestamp $endTs `
                    --as user
            $j = parseJson $r
            if ($j -and $j.ok) {
                $newId   = $j.data.event.event_id
                $content = Get-Content $f.FullName -Raw -Encoding UTF8
                if ($content -notmatch 'lark_event_id:') {
                    $content = $content -replace '(?m)^(---\s*\n)', "`$1lark_event_id: $newId`n"
                    $content | Set-Content $f.FullName -Encoding UTF8 -NoNewline
                }
                if (-not $state.events.PSObject.Properties[$rel]) {
                    $state.events | Add-Member -NotePropertyName $rel -NotePropertyValue ([PSCustomObject]@{
                        event_id   = $newId
                        local_hash = sha256 $f.FullName
                        last_sync  = (Get-Date -Format "o")
                    })
                }
                Write-Host "    OK (event $newId)"
            } else {
                Write-Warning "    FAIL: $($j.msg)"
            }
        }
    }
    $state
}

# ── Pull a Lark Calendar event to vault ──────────────────────────────────────

function pullEvent ($state, [string]$eventId) {
    Write-Host "  <- event $eventId"
    $r = & $lark calendar +event-get `
            --calendar-id $state.calendar_id `
            --event-id $eventId `
            --as user
    $j = parseJson $r
    if (-not ($j -and $j.ok)) { Write-Warning "    FAIL fetch: $($j.msg)"; return $state }

    $ev      = $j.data.event
    $title   = $ev.summary
    $date    = (([datetimeoffset]::FromUnixTimeMilliseconds($ev.start_time.timestamp)).DateTime).ToString("yyyy-MM-dd")
    $organizer = if ($ev.organizer_calendar_id) { $ev.organizer_calendar_id } else { "TBD" }
    $attendeeList = ($ev.attendee_ability_list | ForEach-Object { $_.display_name }) -join ", "

    $safeTitle = ($title -replace '[\\/:*?"<>|]', ' ').Trim()
    $meetDir   = Join-Path $VaultRoot "wiki/meetings"
    if (-not (Test-Path $meetDir)) {
        $meetDir = Join-Path $VaultRoot "Meetings"
        if (-not (Test-Path $meetDir)) { New-Item -ItemType Directory $meetDir -Force | Out-Null }
    }
    $fp = Join-Path $meetDir "$date - $safeTitle.md"

    if (-not (Test-Path $fp)) {
        $stub = @"
---
date: $date
type: meeting
tags: [meeting]
ai-first: true
title: "$title"
organizer: "$organizer"
attendees: [$attendeeList]
lark_event_id: "$eventId"
---

## For future Claude
This is a meeting note for "$title" held on $date. The note was pulled from Lark Calendar on $((Get-Date -Format "yyyy-MM-dd")). Attendees and time are pre-filled from the calendar event; the note body is empty pending actual meeting content.

## Notes


## Decisions


## Action items

"@
        $stub | Set-Content $fp -Encoding UTF8 -NoNewline
        Write-Host "    OK created stub $fp"
    } else {
        # Update the event_id in existing note if not already there
        $content = Get-Content $fp -Raw -Encoding UTF8
        if ($content -notmatch 'lark_event_id:') {
            $content = $content -replace '(?m)^(---\s*\n)', "`$1lark_event_id: $eventId`n"
            $content | Set-Content $fp -Encoding UTF8 -NoNewline
        }
        Write-Host "    OK linked to existing note"
    }

    $rel = relPath $fp
    if (-not $state.events.PSObject.Properties[$rel]) {
        $state.events | Add-Member -NotePropertyName $rel -NotePropertyValue ([PSCustomObject]@{
            event_id   = $eventId
            local_hash = sha256 $fp
            last_sync  = (Get-Date -Format "o")
        })
    } else {
        $state.events.$rel.local_hash = sha256 $fp
        $state.events.$rel.last_sync  = (Get-Date -Format "o")
    }
    $state
}

# ── init ──────────────────────────────────────────────────────────────────────

function cmdInit {
    $state = readState
    $now   = [int64](([datetime]::UtcNow) - [datetime]::new(1970,1,1,0,0,0,0,[DateTimeKind]::Utc)).TotalMilliseconds
    $end   = $now + 30 * 24 * 3600 * 1000  # next 30 days

    Write-Host "Pulling upcoming Lark Calendar events (next 30 days)..."
    $r = & $lark calendar +event-list `
            --calendar-id $state.calendar_id `
            --start-time $now `
            --end-time $end `
            --as user
    $j = parseJson $r
    if (-not ($j -and $j.ok)) { Write-Warning "FAIL list events: $($j.msg)"; return }

    foreach ($ev in $j.data.items) {
        $state = pullEvent $state $ev.event_id
    }
    saveState $state
    Write-Host "`nDone. State saved to .lark-calendar-sync.json"
}

# ── push ──────────────────────────────────────────────────────────────────────

function cmdPush ([string]$target) {
    $state = readState

    if ($target -eq "schedule") {
        Write-Host "Pushing task due dates as Lark Calendar events..."
        $state = pushSchedule $state
        saveState $state
        return
    }

    if ($target -and $target -ne "meetings") {
        $fp = if ([IO.Path]::IsPathRooted($target)) { $target } else { Join-Path $VaultRoot $target }
        if (-not (Test-Path $fp)) { Write-Error "File not found: $fp"; return }
        $state = pushMeeting $state $fp
        saveState $state
        return
    }

    $files   = @(meetingNotes)
    $changed = $files | Where-Object {
        $rel = relPath $_.FullName
        $n   = if ($state.events.PSObject.Properties[$rel]) { $state.events.$rel } else { $null }
        -not $n -or (sha256 $_.FullName) -ne $n.local_hash
    }
    if (@($changed).Count -eq 0) { Write-Host "All meetings in sync."; return }
    Write-Host "Pushing $(@($changed).Count) meeting note(s)..."
    foreach ($f in $changed) { $state = pushMeeting $state $f.FullName }
    saveState $state
}

# ── pull ──────────────────────────────────────────────────────────────────────

function cmdPull ([string]$target) {
    $state = readState
    if ($target) {
        $state = pullEvent $state $target
    } else {
        foreach ($prop in $state.events.PSObject.Properties) {
            if ($prop.Value.event_id) { $state = pullEvent $state $prop.Value.event_id }
        }
    }
    saveState $state
}

# ── sync ──────────────────────────────────────────────────────────────────────

function cmdSync {
    Write-Host "Pushing local meeting changes..."
    cmdPush "meetings"
    Write-Host "`nPulling Lark Calendar changes..."
    cmdPull ""
}

# ── status ────────────────────────────────────────────────────────────────────

function cmdStatus {
    $state  = readState
    $files  = @(meetingNotes)
    $counts = @{ new = 0; modified = 0; synced = 0 }

    Write-Host "Calendar: $($state.calendar_id)"
    Write-Host "`nMeeting notes:"
    foreach ($f in $files) {
        $rel = relPath $f.FullName
        $n   = if ($state.events.PSObject.Properties[$rel]) { $state.events.$rel } else { $null }
        if (-not $n) {
            Write-Host "  [?] $rel  (not pushed)"
            $counts.new++
        } elseif ((sha256 $f.FullName) -ne $n.local_hash) {
            Write-Host "  [M] $rel  (modified)"
            $counts.modified++
        } else {
            $counts.synced++
        }
    }

    # Count tasks with due dates not yet pushed
    $tasksDue = @(Get-ChildItem -Path $VaultRoot -Filter "*.md" -File -Recurse |
        Where-Object {
            $fm = parseFrontmatter $_.FullName
            $fm["type"] -eq "task" -and $fm["due"] -and $fm["status"] -ne "done" -and -not $fm["lark_event_id"]
        })
    if ($tasksDue.Count -gt 0) {
        Write-Host "`nTasks with due dates not yet in Lark Calendar: $($tasksDue.Count) (run: push schedule)"
    }

    Write-Host "`nMeetings - Synced:$($counts.synced)  Modified:$($counts.modified)  New:$($counts.new)"
}

# ── entry point ───────────────────────────────────────────────────────────────

switch ($Command) {
    "init"   { cmdInit }
    "push"   { cmdPush $Target }
    "pull"   { cmdPull $Target }
    "sync"   { cmdSync }
    "status" { cmdStatus }
}
