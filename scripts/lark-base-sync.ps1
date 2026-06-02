# lark-base-sync.ps1 - Sync vault structured notes to/from Lark Base (bitable)
# Usage: pwsh -File scripts/lark-base-sync.ps1 <command> [-Type <type>] [-VaultRoot <path>]
# Commands: init, push [type], pull [type], sync, status
# Types: tasks, projects, persons, decisions (omit to target all four)
#
# Configuration:
#   Set $env:LARK_BASE_APP_TOKEN before first run, or rely on .lark-base-sync.json after init.
#   Tables are created automatically during init with the correct field schemas.

param(
    [Parameter(Position=0)]
    [ValidateSet("init","push","pull","sync","status")]
    [string]$Command = "status",

    [Parameter(Position=1)]
    [string]$Type = "",

    [string]$VaultRoot = $PWD.Path
)

$npmBin = "$env:APPDATA\npm"
if ($env:PATH -notlike "*$npmBin*") { $env:PATH = "$npmBin;$env:PATH" }

$lark      = "lark-cli"
$statePath = Join-Path $VaultRoot ".lark-base-sync.json"
$appToken  = if ($env:LARK_BASE_APP_TOKEN) { $env:LARK_BASE_APP_TOKEN } else { "" }

# ── Table definitions ─────────────────────────────────────────────────────────

$TABLE_DEFS = @{
    tasks = @{
        name   = "Tasks"
        fields = @(
            @{ field_name = "Title";    field_type = 1 }   # Text
            @{ field_name = "Status";   field_type = 3 }   # Single select
            @{ field_name = "Priority"; field_type = 3 }   # Single select
            @{ field_name = "Due";      field_type = 5 }   # DateTime
            @{ field_name = "Project";  field_type = 1 }   # Text
            @{ field_name = "Assignee"; field_type = 1 }   # Text (user IDs resolved separately)
            @{ field_name = "Tags";     field_type = 4 }   # Multi select
            @{ field_name = "VaultPath"; field_type = 1 }  # Text (internal key)
        )
    }
    projects = @{
        name   = "Projects"
        fields = @(
            @{ field_name = "Title";    field_type = 1 }
            @{ field_name = "Status";   field_type = 3 }
            @{ field_name = "Started";  field_type = 5 }
            @{ field_name = "Deadline"; field_type = 5 }
            @{ field_name = "Stack";    field_type = 1 }
            @{ field_name = "Tags";     field_type = 4 }
            @{ field_name = "VaultPath"; field_type = 1 }
        )
    }
    persons = @{
        name   = "Persons"
        fields = @(
            @{ field_name = "Name";     field_type = 1 }
            @{ field_name = "Role";     field_type = 1 }
            @{ field_name = "Org";      field_type = 1 }
            @{ field_name = "Email";    field_type = 1 }
            @{ field_name = "Strength"; field_type = 3 }   # Single select
            @{ field_name = "Tags";     field_type = 4 }
            @{ field_name = "VaultPath"; field_type = 1 }
        )
    }
    decisions = @{
        name   = "Decisions"
        fields = @(
            @{ field_name = "Title";    field_type = 1 }
            @{ field_name = "Date";     field_type = 5 }
            @{ field_name = "Decision"; field_type = 1 }
            @{ field_name = "Outcome";  field_type = 1 }
            @{ field_name = "Project";  field_type = 1 }
            @{ field_name = "Tags";     field_type = 4 }
            @{ field_name = "VaultPath"; field_type = 1 }
        )
    }
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

function relPath ([string]$full) {
    $full.Substring($VaultRoot.Length).TrimStart('\', '/')
}

function readState {
    if (Test-Path $statePath) {
        $s = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($appToken -and $s.app_token -ne $appToken) { $s.app_token = $appToken }
        return $s
    }
    [PSCustomObject]@{
        app_token = $appToken
        tables    = [PSCustomObject]@{}
        records   = [PSCustomObject]@{}
    }
}

function saveState ($s) {
    $s | ConvertTo-Json -Depth 10 | Set-Content $statePath -Encoding UTF8
}

# Parse YAML frontmatter from a markdown file; returns hashtable of key/value pairs
function parseFrontmatter ([string]$path) {
    $lines = Get-Content $path -Encoding UTF8
    $result = @{}
    if ($lines.Count -lt 2 -or $lines[0] -ne "---") { return $result }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq "---") { break }
        if ($lines[$i] -match '^(\w[\w-]*):\s*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim().Trim('"').Trim("'")
            $result[$key] = $val
        }
    }
    $result
}

function noteType ([string]$path) {
    $fm = parseFrontmatter $path
    $fm["type"]
}

# ── Vault scanners by note type ───────────────────────────────────────────────

function vaultNotesByType ([string]$noteType) {
    Get-ChildItem -Path $VaultRoot -Filter "*.md" -File -Recurse |
        Where-Object {
            $_.Name -notlike ".lark*" -and
            $_.Name -notlike "_CLAUDE*" -and
            $_.Name -notlike "CLAUDE*"
        } |
        Where-Object { (parseFrontmatter $_.FullName)["type"] -eq $noteType }
}

# ── Build Lark record fields from a vault note ────────────────────────────────

function buildTaskRecord ([string]$path) {
    $fm = parseFrontmatter $path
    $title = if ($fm["title"]) { $fm["title"] } else {
        foreach ($line in (Get-Content $path -Encoding UTF8)) {
            if ($line -match '^#\s+(.+)') { $Matches[1].Trim(); break }
        }
        [IO.Path]::GetFileNameWithoutExtension($path)
    }
    @{
        Title     = $title
        Status    = if ($fm["status"]) { $fm["status"] } else { "todo" }
        Priority  = if ($fm["priority"]) { $fm["priority"] } else { "medium" }
        Project   = if ($fm["project"]) { $fm["project"] } else { "" }
        Assignee  = if ($fm["assignee"]) { $fm["assignee"] } else { "" }
        Tags      = if ($fm["tags"]) { ($fm["tags"] -replace '[\[\]]', '').Split(',') | ForEach-Object { $_.Trim() } } else { @() }
        VaultPath = relPath $path
    }
}

function buildProjectRecord ([string]$path) {
    $fm = parseFrontmatter $path
    $title = if ($fm["title"]) { $fm["title"] } else { [IO.Path]::GetFileNameWithoutExtension($path) }
    @{
        Title     = $title
        Status    = if ($fm["status"]) { $fm["status"] } else { "active" }
        Stack     = if ($fm["stack"]) { $fm["stack"] } else { "" }
        Tags      = if ($fm["tags"]) { ($fm["tags"] -replace '[\[\]]', '').Split(',') | ForEach-Object { $_.Trim() } } else { @() }
        VaultPath = relPath $path
    }
}

function buildPersonRecord ([string]$path) {
    $fm = parseFrontmatter $path
    $name = if ($fm["name"]) { $fm["name"] } else { [IO.Path]::GetFileNameWithoutExtension($path) }
    @{
        Name      = $name
        Role      = if ($fm["role"]) { $fm["role"] } else { "" }
        Org       = if ($fm["org"]) { $fm["org"] } else { "" }
        Email     = if ($fm["email"]) { $fm["email"] } else { "" }
        Strength  = if ($fm["strength"]) { $fm["strength"] } else { "medium" }
        Tags      = if ($fm["tags"]) { ($fm["tags"] -replace '[\[\]]', '').Split(',') | ForEach-Object { $_.Trim() } } else { @() }
        VaultPath = relPath $path
    }
}

function buildDecisionRecord ([string]$path) {
    $fm = parseFrontmatter $path
    $title = if ($fm["title"]) { $fm["title"] } else { [IO.Path]::GetFileNameWithoutExtension($path) }
    @{
        Title     = $title
        Date      = if ($fm["date"]) { $fm["date"] } else { "" }
        Project   = if ($fm["project"]) { $fm["project"] } else { "" }
        Tags      = if ($fm["tags"]) { ($fm["tags"] -replace '[\[\]]', '').Split(',') | ForEach-Object { $_.Trim() } } else { @() }
        VaultPath = relPath $path
    }
}

# ── Push one note as a Lark Base record ───────────────────────────────────────

function pushRecord ($state, [string]$noteTypeName, [string]$fp) {
    $rel       = relPath $fp
    $tableId   = if ($state.tables.PSObject.Properties[$noteTypeName]) { $state.tables.$noteTypeName } else { "" }
    if (-not $tableId) { Write-Warning "  No table ID for '$noteTypeName' - run init first"; return $state }

    $fields = switch ($noteTypeName) {
        "tasks"     { buildTaskRecord $fp }
        "projects"  { buildProjectRecord $fp }
        "persons"   { buildPersonRecord $fp }
        "decisions" { buildDecisionRecord $fp }
    }
    $fieldsJson = $fields | ConvertTo-Json -Compress

    $existing = if ($state.records.PSObject.Properties[$rel]) { $state.records.$rel } else { $null }

    if ($existing) {
        Write-Host "  -> $rel"
        $r = & $lark bitable +record-update `
                --app-token $state.app_token `
                --table-id $tableId `
                --record-id $existing.record_id `
                --fields $fieldsJson `
                --as user
        $j = parseJson $r
        if ($j -and $j.ok) {
            $existing.local_hash = sha256 $fp
            $existing.last_sync  = (Get-Date -Format "o")
            $state.records.$rel  = $existing
            Write-Host "    OK updated"
        } else {
            Write-Warning "    FAIL update: $($j.msg)"
        }
    } else {
        Write-Host "  + $rel"
        $r = & $lark bitable +record-create `
                --app-token $state.app_token `
                --table-id $tableId `
                --fields $fieldsJson `
                --as user
        $j = parseJson $r
        if ($j -and $j.ok) {
            $recId = $j.data.record.record_id
            if (-not $state.records.PSObject.Properties[$rel]) {
                $state.records | Add-Member -NotePropertyName $rel -NotePropertyValue ([PSCustomObject]@{
                    record_id  = $recId
                    table_id   = $tableId
                    note_type  = $noteTypeName
                    local_hash = sha256 $fp
                    last_sync  = (Get-Date -Format "o")
                })
            }
            Write-Host "    OK created (record $recId)"
        } else {
            Write-Warning "    FAIL create: $($j.msg)"
        }
    }
    $state
}

# ── init ──────────────────────────────────────────────────────────────────────

function cmdInit {
    $state = readState
    if (-not $state.app_token) {
        Write-Error "App token required. Set `$env:LARK_BASE_APP_TOKEN or pass a token."
        return
    }

    foreach ($typeName in $TABLE_DEFS.Keys) {
        if ($state.tables.PSObject.Properties[$typeName]) {
            Write-Host "Table '$typeName' already exists (id: $($state.tables.$typeName))"
            continue
        }
        $def  = $TABLE_DEFS[$typeName]
        $name = $def.name
        Write-Host "Creating table '$name'..."
        $r = & $lark bitable +table-create `
                --app-token $state.app_token `
                --name $name `
                --as user
        $j = parseJson $r
        if (-not ($j -and $j.ok)) { Write-Warning "  FAIL create table '$name': $($j.msg)"; continue }
        $tableId = $j.data.table_id
        $state.tables | Add-Member -NotePropertyName $typeName -NotePropertyValue $tableId -Force
        Write-Host "  OK table id: $tableId"
    }

    saveState $state

    # Push all existing notes
    foreach ($typeName in @("tasks","projects","persons","decisions")) {
        $typeKey = @{ tasks="task"; projects="project"; persons="person"; decisions="decision" }[$typeName]
        $files = @(vaultNotesByType $typeKey)
        if ($files.Count -eq 0) { Write-Host "No '$typeKey' notes found."; continue }
        Write-Host "Pushing $($files.Count) $typeName..."
        foreach ($f in $files) { $state = pushRecord $state $typeName $f.FullName }
    }
    saveState $state
    Write-Host "`nDone. State saved to .lark-base-sync.json"
}

# ── push ──────────────────────────────────────────────────────────────────────

function cmdPush ([string]$target) {
    $state = readState

    $typeMap = @{ tasks="task"; projects="project"; persons="person"; decisions="decision" }
    $targets = if ($target -and $typeMap.ContainsKey($target)) {
        @($target)
    } elseif ($target) {
        # Treat as a file path
        $fp = if ([IO.Path]::IsPathRooted($target)) { $target } else { Join-Path $VaultRoot $target }
        if (-not (Test-Path $fp)) { Write-Error "File not found: $fp"; return }
        $nt = noteType $fp
        $typeName = ($typeMap.GetEnumerator() | Where-Object { $_.Value -eq $nt } | Select-Object -First 1).Key
        if (-not $typeName) { Write-Warning "Unknown note type '$nt' for $fp"; return }
        $state = pushRecord $state $typeName $fp
        saveState $state
        return
    } else {
        @("tasks","projects","persons","decisions")
    }

    foreach ($typeName in $targets) {
        $typeKey = $typeMap[$typeName]
        $files   = @(vaultNotesByType $typeKey)
        $changed = $files | Where-Object {
            $rel = relPath $_.FullName
            $n   = if ($state.records.PSObject.Properties[$rel]) { $state.records.$rel } else { $null }
            -not $n -or (sha256 $_.FullName) -ne $n.local_hash
        }
        if (@($changed).Count -eq 0) { Write-Host "Nothing to push for $typeName."; continue }
        Write-Host "Pushing $(@($changed).Count) $typeName..."
        foreach ($f in $changed) { $state = pushRecord $state $typeName $f.FullName }
    }
    saveState $state
}

# ── pull ──────────────────────────────────────────────────────────────────────

function cmdPull ([string]$target) {
    $state = readState

    $typeMap  = @{ tasks="task"; projects="project"; persons="person"; decisions="decision" }
    $targets  = if ($target -and $TABLE_DEFS.ContainsKey($target)) { @($target) } else { @("tasks","projects","persons","decisions") }

    foreach ($typeName in $targets) {
        $tableId = if ($state.tables.PSObject.Properties[$typeName]) { $state.tables.$typeName } else { "" }
        if (-not $tableId) { Write-Warning "No table ID for '$typeName' - run init first"; continue }

        Write-Host "Pulling $typeName from Lark Base..."
        $r = & $lark bitable +record-list `
                --app-token $state.app_token `
                --table-id $tableId `
                --as user
        $j = parseJson $r
        if (-not ($j -and $j.ok)) { Write-Warning "  FAIL list records: $($j.msg)"; continue }

        foreach ($rec in $j.data.items) {
            $vaultPath = $rec.fields.VaultPath
            if (-not $vaultPath) { continue }
            $fp = Join-Path $VaultRoot $vaultPath
            Write-Host "  <- $vaultPath"
            # Only update the frontmatter fields that Lark owns; never overwrite note body
            # (vault body is authoritative - only sync structured frontmatter fields back)
            if (Test-Path $fp) {
                $existing = Get-Content $fp -Raw -Encoding UTF8
                # Update key frontmatter fields from Lark record
                $statusVal = $rec.fields.Status
                if ($statusVal) {
                    $existing = $existing -replace '(?m)^status:.*$', "status: $statusVal"
                }
                $existing | Set-Content $fp -Encoding UTF8 -NoNewline
                $rel = relPath $fp
                if ($state.records.PSObject.Properties[$rel]) {
                    $state.records.$rel.last_sync  = (Get-Date -Format "o")
                    $state.records.$rel.local_hash = sha256 $fp
                }
                Write-Host "    OK updated frontmatter"
            } else {
                Write-Host "    SKIP (note not in vault - run /lark-tasks-sync pull for full import)"
            }
        }
    }
    saveState $state
}

# ── sync ──────────────────────────────────────────────────────────────────────

function cmdSync {
    Write-Host "Checking local changes..."
    cmdPush ""
    Write-Host "`nChecking Lark Base for remote changes..."
    cmdPull ""
}

# ── status ────────────────────────────────────────────────────────────────────

function cmdStatus {
    $state   = readState
    $typeMap = @{ tasks="task"; projects="project"; persons="person"; decisions="decision" }
    $counts  = @{ new = 0; modified = 0; synced = 0 }

    foreach ($typeName in @("tasks","projects","persons","decisions")) {
        $typeKey = $typeMap[$typeName]
        $files   = @(vaultNotesByType $typeKey)
        $tableStatus = if ($state.tables.PSObject.Properties[$typeName]) { "table $($state.tables.$typeName)" } else { "no table (run init)" }
        Write-Host "`n[$typeName] $tableStatus"

        foreach ($f in $files) {
            $rel = relPath $f.FullName
            $n   = if ($state.records.PSObject.Properties[$rel]) { $state.records.$rel } else { $null }
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
    }

    Write-Host "`nSynced:$($counts.synced)  Modified:$($counts.modified)  New:$($counts.new)"
    Write-Host "App token: $($state.app_token)"
}

# ── entry point ───────────────────────────────────────────────────────────────

switch ($Command) {
    "init"   { cmdInit }
    "push"   { cmdPush $Type }
    "pull"   { cmdPull $Type }
    "sync"   { cmdSync }
    "status" { cmdStatus }
}
