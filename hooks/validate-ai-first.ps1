# hooks/validate-ai-first.ps1 - Enforce the AI-first vault rule on Write/Edit
#
# Fires as a Claude Code PostToolUse hook after Write/Edit. Inspects the
# written file and warns if it does not follow the AI-first rule defined in
# references/ai-first-rules.md.
#
# Validation (warnings, non-blocking):
#   1. Frontmatter delimiters (--- ... ---) are well-formed
#   2. No tabs inside frontmatter (YAML requires spaces)
#   3. Required AI-first fields present: date, type, tags, ai-first: true
#   4. `## For future Claude` preamble exists in the body
#   5. No banned non-ASCII substitution characters
#
# Exit codes:
#   0 = pass (silent)
#   1 = warn (issue surfaced; write is NOT reverted)

$rawInput = [Console]::In.ReadToEnd()

$FILE = ''
try {
    $data = $rawInput | ConvertFrom-Json -ErrorAction Stop
    $FILE = if ($data.tool_input.file_path) { $data.tool_input.file_path }
            elseif ($data.args.file_path)   { $data.args.file_path }
            else                            { '' }
} catch { exit 0 }

if (-not $FILE)                          { exit 0 }
if (-not $FILE.EndsWith('.md'))          { exit 0 }
if (-not (Test-Path $FILE -PathType Leaf)) { exit 0 }

$VAULT = $env:OBSIDIAN_VAULT_PATH
if (-not $VAULT) { exit 0 }

$normalFile  = [System.IO.Path]::GetFullPath($FILE)
$normalVault = [System.IO.Path]::GetFullPath($VAULT)
if (-not $normalFile.StartsWith($normalVault + [System.IO.Path]::DirectorySeparatorChar)) { exit 0 }

# Skip non-first-class paths
$skipPatterns = @('\raw\', '\templates\', '\_export\', '\.obsidian\', '\.git\', '\.trash\')
foreach ($pat in $skipPatterns) {
    if ($normalFile -like "*$pat*") { exit 0 }
}

$BASENAME = [System.IO.Path]::GetFileName($FILE)
$WARNINGS = [System.Collections.Generic.List[string]]::new()
$lines    = Get-Content $FILE -Encoding UTF8 -ErrorAction SilentlyContinue
if (-not $lines) { exit 0 }

# Check 1: frontmatter delimiters
if ($lines[0] -ne '---') {
    [Console]::Error.WriteLine("AI-first warning: $BASENAME has no frontmatter (expected --- on the first line). AI-first notes need date/type/tags/ai-first metadata.")
    exit 1
}

$delimCount = ($lines | Where-Object { $_ -eq '---' }).Count
if ($delimCount -lt 2) {
    $WARNINGS.Add("$BASENAME frontmatter is missing the closing --- delimiter.")
}

# Extract frontmatter (between first and second ---)
$fm = [System.Collections.Generic.List[string]]::new()
$fmCount = 0
foreach ($line in $lines) {
    if ($line -eq '---') {
        $fmCount++
        if ($fmCount -eq 2) { break }
        continue
    }
    if ($fmCount -eq 1) { $fm.Add($line) }
}
$FRONTMATTER = $fm -join "`n"

# Check 2: tabs in frontmatter
if ($FRONTMATTER -match "`t") {
    $WARNINGS.Add("$BASENAME frontmatter contains tab characters. YAML requires spaces only.")
}

# Check 3: required AI-first frontmatter fields
foreach ($field in @('date', 'type', 'tags')) {
    if ($FRONTMATTER -notmatch "(?m)^${field}:") {
        $WARNINGS.Add("$BASENAME missing '${field}:' in frontmatter.")
    }
}
if ($FRONTMATTER -notmatch '(?m)^ai-first:\s*true\s*$') {
    $WARNINGS.Add("$BASENAME missing 'ai-first: true' in frontmatter.")
}

# Check 4: For future Claude preamble in body
$body = [System.Collections.Generic.List[string]]::new()
$fmCount = 0
foreach ($line in $lines) {
    if ($fmCount -lt 2 -and $line -eq '---') { $fmCount++; continue }
    if ($fmCount -ge 2) { $body.Add($line) }
}
$BODY = $body -join "`n"
if ($BODY -notmatch '(?m)^##\s+For future Claude') {
    $WARNINGS.Add("$BASENAME missing '## For future Claude' preamble (required by ai-first-rules.md rule #2).")
}

# Check 5: banned non-ASCII substitution characters
$BANNED = [ordered]@{
    [char]0x2014 = "U+2014 em-dash -- try ` - `"
    [char]0x2013 = "U+2013 en-dash -- try ` - `"
    [char]0x201C = 'U+201C left double quote -- try ["]'
    [char]0x201D = 'U+201D right double quote -- try ["]'
    [char]0x2018 = "U+2018 left single quote -- try [']"
    [char]0x2019 = "U+2019 right single quote -- try [']"
    [char]0x2265 = 'U+2265 >= -- try [>=]'
    [char]0x2264 = 'U+2264 <= -- try [<=]'
    [char]0x2260 = 'U+2260 != -- try [!=]'
    [char]0x2026 = 'U+2026 ellipsis -- try [...]'
    [char]0x00A0 = 'U+00A0 non-breaking space -- try [ ]'
}

$nonAsciiHits = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $lines.Count; $i++) {
    $seenChars = [System.Collections.Generic.HashSet[char]]::new()
    foreach ($ch in $lines[$i].ToCharArray()) {
        if ($BANNED.Contains($ch) -and $seenChars.Add($ch)) {
            $nonAsciiHits.Add("    line $($i+1): $($BANNED[$ch])")
        }
    }
}
if ($nonAsciiHits.Count -gt 0) {
    $WARNINGS.Add("$BASENAME contains banned non-ASCII substitution characters:")
    foreach ($hit in $nonAsciiHits) { $WARNINGS.Add($hit) }
}

# Emit warnings
if ($WARNINGS.Count -gt 0) {
    [Console]::Error.WriteLine("AI-first warnings on ${BASENAME}:")
    foreach ($w in $WARNINGS) {
        [Console]::Error.WriteLine("  - $w")
    }
    [Console]::Error.WriteLine("`nSee references/ai-first-rules.md for the full spec.")
    exit 1
}

exit 0
