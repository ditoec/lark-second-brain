# hooks/obsidian-bg-agent.ps1 - PostCompact vault propagation hook
#
# Fires after Claude compacts the conversation context. Reads the session
# summary from stdin (JSON), then runs a headless Claude agent to propagate
# everything worth preserving to the vault.
#
# TRUST CAVEAT: this agent writes to the vault UNATTENDED using
# --dangerously-skip-permissions. It is OPT-IN and ships INERT.
# Requires BOTH of the following before it does anything:
#   - OBSIDIAN_VAULT_PATH set (where to write), AND
#   - OBSIDIAN_BG_AGENT_ENABLED=1 (a second, deliberate enable flag)
#
# Logs: $env:TEMP\obsidian-bg-agent.log

$VAULT = $env:OBSIDIAN_VAULT_PATH
if (-not $VAULT) { exit 0 }

if ($env:OBSIDIAN_BG_AGENT_ENABLED -ne '1') { exit 0 }

# Read stdin
$rawInput = [Console]::In.ReadToEnd()
$TRANSCRIPT = ''
try {
    $parsed = $rawInput | ConvertFrom-Json -ErrorAction Stop
    $TRANSCRIPT = $parsed.transcript_path
} catch { exit 0 }

if (-not $TRANSCRIPT -or -not (Test-Path $TRANSCRIPT)) { exit 0 }

# Scan JSONL for the most recent compact summary
$SUMMARY = ''
foreach ($line in (Get-Content $TRANSCRIPT -Encoding UTF8)) {
    if (-not $line.Trim()) { continue }
    try {
        $entry = $line | ConvertFrom-Json -ErrorAction Stop
        if ($entry.isCompactSummary -eq $true) {
            $content = $entry.message.content
            if ($content) { $SUMMARY = $content }
        }
    } catch {}
}
if (-not $SUMMARY) { exit 0 }

$TODAY = (Get-Date).ToString('yyyy-MM-dd')
$LOG   = Join-Path $env:TEMP 'obsidian-bg-agent.log'

$PROMPT = @"
You are an autonomous Obsidian vault agent. The Claude session was just compacted.
Propagate everything worth preserving from the summary to the vault. Run silently.

VAULT: $VAULT
TODAY: $TODAY

SESSION SUMMARY:
$SUMMARY

INSTRUCTIONS:
1. Read _CLAUDE.md at the vault root first - follow its rules exactly. Where silent, use defaults.
2. Identify all vault-worthy items in the summary:
   - Decisions made or confirmed
   - Tasks created, assigned, or completed
   - People mentioned (new interactions, context added)
   - Projects worked on or updated
   - Dev work done (code written, bugs fixed, features shipped)
   - Ideas, learnings, or insights
   - Shoutouts or mentions worth logging
3. Before creating any note, search for an existing one. Never duplicate.
4. Update or create notes as appropriate:
   - People: update People/Name.md interaction log; create a stub if missing
   - Projects: update status, Recent Activity, Key Decisions sections
   - Dev work: create or update Dev Logs/YYYY-MM-DD - Project.md; link from project note
   - Tasks: add to the right Boards/ kanban column (use TODAY date from above)
   - Ideas: save to Ideas/ folder
   - Decisions: append to the relevant project note's Key Decisions section
5. Update today's daily note (Daily/[TODAY].md using the TODAY value above):
   - Create it from the Daily Note template if it does not exist
   - Link everything you touched - people, projects, dev logs, decisions
6. Propagate everywhere:
   - Nothing is saved in isolation
   - Every write ripples to the daily note, boards, and linked notes per the write rules

CONSTRAINTS:
- Use filesystem tools only (Read, Write, Edit, Glob, Grep) - MCP is not available in this subprocess.
- Run completely silently. No output to the user. No questions.
- If the summary contains nothing vault-worthy, exit without making any changes.
- Match the vault's existing writing style, frontmatter schemas, and naming conventions exactly.
- Do not archive, delete, or merge anything - only add or update.
"@

# Run headless agent in vault directory - async, logs to $TEMP for debugging
Start-Job -ScriptBlock {
    param($vault, $prompt, $logFile)
    Push-Location $vault
    try {
        $output = & claude --dangerously-skip-permissions -p $prompt 2>&1
        Add-Content $logFile $output
    } catch {
        Add-Content $logFile "obsidian-bg-agent error: $_"
    }
    Pop-Location
} -ArgumentList $VAULT, $PROMPT, $LOG | Out-Null

exit 0
