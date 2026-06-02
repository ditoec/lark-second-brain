# adapters/lib.ps1 - Shared helpers for platform adapters
# Dot-sourced by scripts/build.ps1 before the platform-specific adapter.ps1.
# Do NOT execute directly.

$CAPABILITY_VOCAB = "read write edit bash webfetch websearch task todo"
$CATEGORY_ORDER   = @("vault", "thinking", "research", "meta")

function Parse-Frontmatter {
    param([string]$File, [string]$Key)
    $lines = Get-Content $File -Encoding UTF8
    $fmCount = 0
    foreach ($line in $lines) {
        if ($line -eq '---') {
            $fmCount++
            if ($fmCount -eq 2) { break }
            continue
        }
        if ($fmCount -eq 1) {
            if ($line.TrimStart() -match "^${Key}:\s*(.*)") {
                return $Matches[1].TrimEnd()
            }
        }
    }
    return ''
}

function Get-CommandBody {
    param([string]$File)
    $lines = Get-Content $File -Encoding UTF8
    $fmCount = 0
    $body = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($fmCount -lt 2 -and $line -eq '---') { $fmCount++; continue }
        if ($fmCount -ge 2) { $body.Add($line) }
    }
    return $body -join "`n"
}

function Should-Include {
    param([string]$File, [string]$Platform)
    $raw = Parse-Frontmatter $File 'exclude'
    if ([string]::IsNullOrEmpty($raw) -or $raw -eq '[]') { return $true }
    $tokens = ($raw -replace '[\[\]]', '') -split ',' | ForEach-Object { $_.Trim() }
    foreach ($t in $tokens) {
        if ($t -eq $Platform) { return $false }
    }
    return $true
}

function Enumerate-Commands {
    param([string]$Dir)
    if (-not (Test-Path $Dir -PathType Container)) { return @() }
    return Get-ChildItem $Dir -Filter "*.md" | Where-Object { -not $_.PSIsContainer }
}

function _Get-CategoryTitle {
    param([string]$Cat)
    switch ($Cat) {
        'vault'    { return 'Vault - daily writing, capture, find' }
        'thinking' { return 'Thinking - synthesis, decisions, learning, reviews' }
        'research' { return 'Research - bring external sources into the vault' }
        'meta'     { return 'Meta - vault setup, health, structure' }
        default    { return $Cat.Substring(0,1).ToUpper() + $Cat.Substring(1) }
    }
}

function _Emit-OneCategorySection {
    param([string]$Cat, [array]$Commands, [string]$PathPrefix)
    $title = _Get-CategoryTitle $Cat
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("### $title")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Command | What it does | Read this file |")
    $null = $sb.AppendLine("|---|---|---|")
    foreach ($cmd in ($Commands | Where-Object { $_.Cat -eq $Cat } | Sort-Object Name)) {
        $null = $sb.AppendLine("| ``/$($cmd.Name)`` | $($cmd.Desc) | ``$PathPrefix/$($cmd.Name).md`` |")
    }
    return $sb.ToString()
}

function Emit-RoutingTableGrouped {
    param([string]$SrcDir, [string]$Platform, [string]$PathPrefix)
    if (-not (Test-Path $SrcDir -PathType Container)) { return '' }

    $commands = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($f in (Get-ChildItem $SrcDir -Filter "*.md")) {
        if (-not (Should-Include $f.FullName $Platform)) { continue }
        $name = $f.BaseName
        $desc = (Parse-Frontmatter $f.FullName 'description') -replace '^["\x27]|["\x27]$', ''
        $cat  = Parse-Frontmatter $f.FullName 'category'
        if ([string]::IsNullOrEmpty($cat)) { $cat = 'other' }
        $commands.Add([PSCustomObject]@{ Cat = $cat; Name = $name; Desc = $desc })
    }

    $allCats = $commands | Select-Object -ExpandProperty Cat | Sort-Object -Unique
    $sb      = [System.Text.StringBuilder]::new()
    $emitted = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($c in $CATEGORY_ORDER) {
        if ($allCats -contains $c) {
            $null = $sb.Append((_Emit-OneCategorySection $c $commands $PathPrefix))
            $null = $emitted.Add($c)
        }
    }
    foreach ($c in $allCats) {
        if (-not $emitted.Contains($c)) {
            $null = $sb.Append((_Emit-OneCategorySection $c $commands $PathPrefix))
        }
    }
    return $sb.ToString()
}

function _Detect-Languages {
    param([string]$SrcDir)
    $langs = [System.Collections.Generic.List[string]]::new()
    foreach ($f in (Get-ChildItem $SrcDir -Filter "*.md" -ErrorAction SilentlyContinue)) {
        foreach ($line in (Get-Content $f.FullName -Encoding UTF8)) {
            if ($line -match '^triggers_([a-z]{2}):') {
                if (-not $langs.Contains($Matches[1])) { $langs.Add($Matches[1]) }
            }
        }
    }
    $sorted = [System.Collections.Generic.List[string]]::new()
    if ($langs.Contains('en')) { $sorted.Add('en') }
    foreach ($l in ($langs | Where-Object { $_ -ne 'en' } | Sort-Object)) { $sorted.Add($l) }
    return $sorted
}

function _Get-LangLabel {
    param([string]$Lang)
    switch ($Lang) {
        'en' { return 'English' }
        'es' { return 'Espanol' }
        'it' { return 'Italiano' }
        'fr' { return 'Francais' }
        'de' { return 'Deutsch' }
        'pt' { return 'Portugues' }
        'ru' { return 'Russian' }
        'ja' { return 'Japanese' }
        default { return $Lang.ToUpper() }
    }
}

function _Emit-OneTriggerCategory {
    param([string]$Cat, [array]$Commands)
    $title = _Get-CategoryTitle $Cat
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("**$title**")
    $null = $sb.AppendLine("")
    foreach ($cmd in ($Commands | Where-Object { $_.Cat -eq $Cat } | Sort-Object Name)) {
        $null = $sb.AppendLine("- ``/$($cmd.Name)`` - $($cmd.Triggers)")
    }
    return $sb.ToString()
}

function _Emit-TriggerLangBlock {
    param([string]$SrcDir, [string]$Platform, [string]$Lang)
    $label    = _Get-LangLabel $Lang
    $commands = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($f in (Get-ChildItem $SrcDir -Filter "*.md")) {
        if (-not (Should-Include $f.FullName $Platform)) { continue }
        $raw = Parse-Frontmatter $f.FullName "triggers_$Lang"
        if ([string]::IsNullOrEmpty($raw) -or $raw -eq '[]') { continue }
        $name     = $f.BaseName
        $cat      = Parse-Frontmatter $f.FullName 'category'
        if ([string]::IsNullOrEmpty($cat)) { $cat = 'other' }
        $triggers = $raw -replace '^\[|\]$', ''
        $commands.Add([PSCustomObject]@{ Cat = $cat; Name = $name; Triggers = $triggers })
    }
    if ($commands.Count -eq 0) { return '' }

    $sb      = [System.Text.StringBuilder]::new()
    $null    = $sb.AppendLine("")
    $null    = $sb.AppendLine("### $label (``$Lang``)")
    $null    = $sb.AppendLine("")
    $allCats = $commands | Select-Object -ExpandProperty Cat | Sort-Object -Unique
    $emitted = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($c in $CATEGORY_ORDER) {
        if ($allCats -contains $c) {
            $null = $sb.Append((_Emit-OneTriggerCategory $c $commands))
            $null = $emitted.Add($c)
        }
    }
    foreach ($c in $allCats) {
        if (-not $emitted.Contains($c)) {
            $null = $sb.Append((_Emit-OneTriggerCategory $c $commands))
        }
    }
    return $sb.ToString()
}

function Emit-TriggerReference {
    param([string]$SrcDir, [string]$Platform)
    if (-not (Test-Path $SrcDir -PathType Container)) { return '' }
    $langs = _Detect-Languages $SrcDir
    if ($langs.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("## Trigger phrases")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("When the user says any of the phrases below (or a close paraphrase), follow the matching command file.")
    foreach ($lang in $langs) {
        $null = $sb.Append((_Emit-TriggerLangBlock $SrcDir $Platform $lang))
    }
    return $sb.ToString()
}

function Rewrite-ToolNeutral {
    param([string]$File)
    if (-not (Test-Path $File)) { return }
    $content = Get-Content $File -Raw -Encoding UTF8
    $content = $content -replace '\bRead tool\b',            'read files'
    $content = $content -replace '\bWrite tool\b',           'write files'
    $content = $content -replace '\bEdit tool\b',            'edit files'
    $content = $content -replace '\bBash tool\b',            'run shell commands'
    $content = $content -replace '\bWebFetch tool\b',        'fetch web pages'
    $content = $content -replace '\bWebSearch tool\b',       'search the web'
    $content = $content -replace '\bGlob tool\b',            'find files'
    $content = $content -replace '\bGrep tool\b',            'search file contents'
    $content = $content -replace '\bTask tool\b',            'spawn a subagent'
    $content = $content -replace '\bTodoWrite tool\b',       'track tasks'
    $content = $content -replace '\bAskUserQuestion tool\b', 'ask the user'
    $content = $content -replace '\bSkill tool\b',           'invoke the skill'
    $content = $content -replace '\bAgent tool\b',           'spawn a subagent'
    [System.IO.File]::WriteAllText($File, $content, [System.Text.Encoding]::UTF8)
}

function Rewrite-PlatformPaths {
    param([string]$File, [string]$PlatformDir)
    if (-not (Test-Path $File)) { return }
    $content = (Get-Content $File -Raw -Encoding UTF8) -replace '\.claude/', ".$PlatformDir/"
    [System.IO.File]::WriteAllText($File, $content, [System.Text.Encoding]::UTF8)
}
