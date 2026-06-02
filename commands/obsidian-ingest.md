---
description: Ingest a source into the vault - the vault rewrites itself around new knowledge. Accepts a URL, file path, local folder, Lark Wiki space, or pasted text. Every ingest updates entities, rewrites stale claims, synthesizes new concepts, and resolves contradictions.
category: research
triggers_en: ["ingest this source", "add this article", "import this", "absorb this", "ingest this folder", "ingest lark wiki", "import wiki structure", "bulk ingest", "ingest directory", "import lark space"]
---

Use the obsidian-second-brain skill. Execute `/obsidian-ingest $ARGUMENTS`:

The argument is a URL, file path, **local folder path**, **Lark Wiki space ID or URL**, or pasted text. If no argument, ask what to ingest.

Optional flags (append after the source):
- `--dry-run` - list what would be ingested without writing anything to the vault
- `--filter <glob>` - when ingesting a folder, only include matching files (e.g. `--filter "*.pdf"`)
- `--shallow` - when ingesting a folder or wiki, process the top level only (no recursion)
- `--batch-size <n>` - files to process per batch when ingesting a folder or wiki (default: 10)

1. Read `_CLAUDE.md` first if it exists in the vault root

2. Classify the source type before reading the full content:
   - **Article/blog post** - extract key claims, people, tools, concepts
   - **PDF/document** - extract structure, findings, recommendations
   - **Transcript (meeting/podcast)** - extract speakers, decisions, action items, quotes
   - **YouTube video** - pull metadata, description, and transcript (see step 3 for method)
   - **Audio file** (.m4a, .mp3, .wav, .ogg, .webm) - transcribe, identify speakers, extract decisions/tasks/promises
   - **Image/screenshot** (.png, .jpg, .jpeg, .webp) - read/OCR the image, extract text and context
   - **Raw text** - classify by content (opinion, technical, narrative) and extract accordingly
   - **Local folder** - argument is a path to a directory (absolute or relative to vault root); go to step 3B
   - **Lark Wiki space** - argument is a Lark Wiki URL (`https://*.larksuite.com/wiki/...` or `https://*.feishu.cn/wiki/...`) or a bare space ID (alphanumeric, ~16 chars); go to step 3C

3. Read or fetch the full source content (single-source path - skip to 3B for folders, 3C for Lark Wiki):

   **For YouTube URLs** - try methods in this order (use the first one that works):

   **Method A - `yt-dlp` (best, works in Claude Code / terminal):**
   ```bash
   which yt-dlp || brew install yt-dlp
   yt-dlp --skip-download --print title --print description --print duration_string --print view_count --print like_count --print upload_date --print channel "URL"
   yt-dlp --write-auto-sub --sub-lang en --skip-download -o "/tmp/%(id)s" "URL"
   ```

   **Method B - YouTube MCP tools (works in Claude Desktop if configured):**
   Check if YouTube MCP tools are available. If so, use them.

   **Method C - oEmbed fallback (works everywhere, limited data):**
   Fetch `https://www.youtube.com/oembed?url=URL&format=json` - gives title and channel only. Ask user to paste description for full ingest.

   **For audio files** (.m4a, .mp3, .wav, .ogg, .webm):
   ```bash
   # Transcribe with Whisper (install if missing)
   which whisper || pip install openai-whisper
   whisper "path/to/audio.m4a" --model base --output_format txt --output_dir /tmp
   ```
   If `whisper` can't be installed, ask the user to paste the transcript.
   After transcription: identify speakers if possible, extract decisions, action items, promises, and who said what.
   Save the transcript to `raw/transcripts/`.

   **For images/screenshots** (.png, .jpg, .jpeg, .webp):
   Claude can read images directly. Analyze the image for:
   - Text content (OCR) - extract all readable text
   - UI screenshots - describe what's shown, extract data from tables/forms/dashboards
   - Whiteboard/diagram photos - describe the structure and extract concepts
   - Chat screenshots - extract messages, people, decisions
   Save the image description to `raw/articles/` as a markdown summary with context.

   **For articles** - use WebFetch to pull the page content
   **For PDFs** - read the file directly
   **For pasted text** - use as-is

3B. **Folder ingestion** (skip here when source is a local directory):

   a. Scan the folder for supported file types. Supported extensions: `.md`, `.txt`, `.pdf`, `.png`, `.jpg`, `.jpeg`, `.webp`, `.mp3`, `.m4a`, `.wav`, `.ogg`, `.webm`. If `--filter` was passed, apply the glob pattern to restrict. If `--shallow`, scan only the top level; otherwise recurse into subdirectories.

   b. Check each file against `raw/` to detect duplicates: compute a content hash and search the vault's `raw/` folder for any existing note with a matching `content_hash:` frontmatter field. Skip already-ingested files and report them in the summary.

   c. Report the file inventory to the user before processing:
      ```
      Folder: /path/to/folder
      Files found: 42  (28 .md, 8 .pdf, 4 .png, 2 .mp3)
      Already ingested: 7 (skipping)
      To ingest: 35
      Batch size: 10  (4 batches)
      ```
      If `--dry-run` was passed, stop here and report the full file list.

   d. Process files in batches (default 10 per batch). For each batch:
      - Read all files in the batch in parallel
      - Run steps 4-6 collectively across the batch (the parallel subagents see all batch files at once so cross-file entity deduplication happens within the batch)
      - Save each file to `raw/` individually before moving to the next batch
      - Report batch completion: `Batch 1/4 complete: 10 files, 3 entities, 5 concepts, 2 rewrites`

   e. After all batches: run a cross-batch synthesis pass. Look for entities and concepts that appeared in multiple batches and create or update synthesis pages connecting them. This is where folder-level patterns emerge that no single file could surface.

   f. Skip to step 7 (structural files update).

3C. **Lark Wiki ingestion** (skip here when source is a Lark Wiki URL or space ID):

   a. Resolve the space ID. If a URL was given, extract the space token from the path (`/wiki/<space-token>/...`). If already a bare ID, use it directly.

   b. Fetch the full node tree using lark-cli:
      ```bash
      lark wiki +node-list --space-id <space-id> --as user
      ```
      This returns a flat list of all nodes. Build the hierarchy from `parent_node_token` fields.

   c. Report the wiki inventory before processing:
      ```
      Lark Wiki space: <space-id>
      Nodes found: 78  (12 folders, 66 documents)
      Hierarchy depth: 4 levels
      To ingest: 66 documents
      Batch size: 10  (7 batches)
      ```
      If `--dry-run` was passed, show the full node tree with titles and stop here.
      If `--shallow`, only process nodes at depth 1 (top-level documents, no nested nodes).

   d. Fetch each document's content as markdown:
      ```bash
      lark docs +fetch --api-version v2 --doc <obj_token> --doc-format markdown --as user
      ```

   e. Mirror the wiki's folder structure into `raw/lark-wiki/<space-id>/` as markdown files:
      - Folder nodes become directories
      - Document nodes become `.md` files named `<node-title>.md`
      - Preserve the hierarchy so future re-ingests can detect unchanged nodes by content hash

   f. Process fetched documents in batches (same batch-size logic as 3B). Use the wiki's folder structure as topical grouping - prefer to batch documents that share a parent node so the subagents see topically related content together.

   g. After all batches: run a cross-batch synthesis pass that uses the Lark Wiki's own hierarchy as a structural hint - sibling nodes in the same wiki folder are more likely to form a coherent topic cluster than random vault notes.

   h. Skip to step 7 (structural files update).

4. Extract and organize (single-source path only; folder/wiki paths use this logic inside each batch):
   - **Entities**: people mentioned, companies, tools, projects
   - **Concepts**: key ideas, frameworks, methodologies
   - **Claims**: specific assertions with supporting evidence
   - **Action items**: anything actionable for the user
   - **Quotes**: notable quotes worth preserving

5. Save the raw source to `raw/` (immutable - never modify after saving):
   - Create `raw/articles/YYYY-MM-DD — Source Title.md` (or transcripts/, pdfs/, videos/)
   - Frontmatter: `date`, `tags: [source, <type>]`, `source_url`, `source_type`, `content_hash`

6. **REWRITE the vault** - this is the critical step. Don't just create new pages. Rewrite existing ones.

   Read `index.md` first to understand what already exists in the vault. Then spawn parallel subagents:

   - **Entities agent**: for each person/company/tool mentioned:
     - Search `wiki/entities/` for existing page
     - If found: REWRITE the page - merge new info with old, update role/context/interactions, add new links. Don't just append - integrate.
     - If not found: create new entity page with full context
   
   - **Concepts agent**: for each idea/framework/methodology:
     - Search `wiki/concepts/` for existing or related pages
     - If found: REWRITE - update the concept with new evidence, new examples, new connections. If the new source adds depth, rewrite the whole section.
     - If not found: create new concept page
     - If the ingest reveals a PATTERN across multiple existing concepts: create a new synthesis page that connects them (e.g., "Three sources now mention X - this is a trend, not a one-off")
   
   - **Projects agent**: for each project referenced:
     - Search `wiki/projects/` for matching project
     - If found: update with new findings, add to Recent Activity, update Key Decisions if the source contains relevant decisions
   
   - **Contradictions agent**: for each claim in the new source:
     - Search the vault for CONFLICTING claims in existing pages
     - If contradiction found: UPDATE the existing page to note the conflict, add the new evidence, and mark which claim is more recent/authoritative
     - If the new source SUPERSEDES old info: rewrite the old page with updated info and note what changed and why in the page's history section

7. Update structural files:
   - REBUILD `index.md` - don't just append. Regenerate the sections that changed so descriptions stay current with the rewritten pages.
   - Append to the operation log: if `Logs/` exists write `**HH:MM** - ingest | Source Title (type) - X created, Y rewritten, Z contradictions resolved` to `Logs/YYYY-MM-DD.md`; otherwise append `## [YYYY-MM-DD] ingest | Source Title (type) — X created, Y rewritten, Z contradictions resolved` to `log.md`

8. Update today's daily note with:
   - What was ingested
   - What pages were REWRITTEN (not just created - this is the important part)
   - Any contradictions found and how they were resolved
   - Any new synthesis pages created from emerging patterns

9. Report back:

   **Single source:**
   - Source title and type
   - **New pages created** (list)
   - **Existing pages rewritten** (list with what changed)
   - **Contradictions resolved** (list with old claim vs new claim)
   - **Synthesis pages created** (patterns that emerged from this + existing knowledge)

   **Folder or Lark Wiki:**
   - Source path / wiki space ID and total files processed
   - Files skipped (already ingested, hash match)
   - Batches completed
   - Cumulative totals: new pages, rewrites, contradictions, synthesis pages
   - **Cross-batch patterns** found (entities or concepts spanning multiple files)
   - Any files that failed to process (list with reason)

The vault should be DIFFERENT after every ingest - not just bigger. Pages that existed before should be smarter, more connected, and more current. If an ingest only creates new pages and doesn't rewrite anything, it wasn't deep enough. For folder and wiki ingests this rule applies to the batch as a whole - expect cross-file entity merging and synthesis pages that no single file could have produced.

---

**AI-first rule:** Every note created or updated by this command MUST follow `references/ai-first-rules.md` - `## For future Claude` preamble, rich frontmatter (`type`, `date`, `tags`, `ai-first: true`, plus type-specific fields), recency markers per external claim, mandatory `[[wikilinks]]` for every person/project/concept referenced, sources preserved verbatim with URLs inline, and confidence levels where applicable. The vault is for future-Claude retrieval - not human reading.

**Anti-fabrication:** Search exhaustively before claiming any note, person, or file is absent - false absence is the most common failure mode - and never invent facts, entities, or dates (mark unknowns as `TBD`). See the anti-fabrication and search-completeness hard rules in `references/ai-first-rules.md`.
