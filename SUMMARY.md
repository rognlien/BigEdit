# BigEdit — what we built

A native macOS editor for very large text / JSON / XML / YAML / Markdown
files — many GB. Swift + AppKit. The guiding principle throughout: **memory
and CPU scale with the viewport and the edits, never with the file.** A 50 GB
file and a 50 KB file cost the same to display and to edit.

## Architecture, top to bottom

### Core engine

| Component | Role |
|---|---|
| `MappedFile` | `mmap` wrapper. The OS pages in only the bytes that are actually touched. |
| `LineIndex` | Sparse line index, built on a background queue. One checkpoint per 4096 lines (byte offset + visual-row offset). Now also tracks "long lines" (≥ 1024 bytes) so they can soft-wrap to the viewport width without recomputing the whole index on resize. |
| `SearchScan` | Background search with byte-progress reporting: `memmem` for literal queries, or `NSRegularExpression` over windows cut at line boundaries (UTF-16 ranges walked back to byte offsets in one pass) for patterns. Case-sensitive uses the fast path; case-insensitive is byte-by-byte with ASCII case folding. Match offsets collected (cap 1,000,000) for display. |
| `StatisticsScan` | Background per-byte pass counting words and characters; matches `wc -lwm`. |
| `ReplacementRule` + `EditModel` | The "lazy editor" Stage 1: one deferred find-and-replace rule, never written to disk until the user saves. The viewport renders the transformed result live. Still used when Replace All has too many matches to materialise, and by the CLI. |
| `PieceTable` + `AddBuffer` | The "lazy editor" Stage 2 storage: logical bytes map onto pieces of the read-only mmap and an append-only add buffer. Edits are O(log pieces) splices in a balanced tree (treap, flat node pool); typed bytes are never copied out of the add buffer again. `AddedByteStore` is the seam for a future on-disk edit journal. |
| `EditedDocument` | The single read/write funnel between the UI and the bytes. Logical offsets everywhere; zero-edit reads pass straight through to the mmap. `replace(_:with:)` keeps the piece table, layout, and undo history in step. |
| `EditedLayout` | Line/row layout of the edited document. The original `LineIndex` is never rebuilt; line-aligned edit *spans* (with their own local line layout, re-derived by scanning just the edit) overlay it, composed through prefix sums — O(log #spans) queries, O(#spans) update per edit. |
| `UndoStack` | Edit history as piece splices — never copied bytes, so undoing a 10 GB deletion is O(pieces). Typing/deletion runs coalesce; Replace All applies as one grouped step. |
| `FileWriter` | Streaming save, two paths: the rule save (`memmem` splice over the mmap) and the piece save (walk the piece table in logical order). Both write to a temp file in the destination directory then atomic `rename()`; both preserve permission bits, report progress, and cancel cleanly. |
| `TextEncoding` | UTF-8, Windows-1252 or Latin-1: decode (never failing), strict decode, encode (nil when a character has no representation — so a search for it has nothing to look for), and the byte length of a scalar, which is what maps a character position back to a byte. |
| `TextSelection` | Selection range in logical byte offsets. |
| `BigEditHelper` + `BigEditHelperKit` + `PrivilegedHelperInstaller` | The privileged helper. Creating a symlink in a root-owned directory needs root, and macOS gives an app no supported way to run a command as root itself, so a launchd daemon blessed once via `SMJobBless` does it. That authorisation dialog accepts Touch ID. The helper takes one verb, runs no shell, restricts destinations to a fixed list, and checks its caller against a code-signing requirement. |
| `CommandLineTool` (`BigEditCLI`) + `CommandLineToolInstaller` | The `bigedit` command. The tool resolves its paths, creates any file that does not exist, and hands them to the app via `open`; it finds its own `.app` by resolving symlinks and walking up, so a link on the PATH still works. The installer symlinks it into `/usr/local/bin`, escalating only when that directory is not writable. |
| `CSVDialect` + `CSVParser` + `CSVColumnLayout` | Delimited-data support. The dialect is sniffed from a bounded head sample (comma / semicolon / tab / pipe), the parser splits one row quote-aware, and the column layout measures widths from a bounded sample — so a table does not shift as you scroll and the cost stays tied to the sample, not the file. |

### UI layer

| Component | Role |
|---|---|
| `ViewportView` | Custom `NSView`. Renders ~60 visible rows; never builds a view as tall as the document. Click+drag selection, auto-scroll past edges, double-click word / triple-click line, copy to pasteboard, I-beam cursor, right-click → Copy. Layers search highlights, selection rect, replacement-rule preview, and per-row syntax colouring. |
| `DocumentView` | Container. Drives a custom `NSScroller` directly over `0…visualRowCount` rather than using `NSScrollView` — sidesteps the coordinate-precision breakdown a billion-point-tall document view would hit. Hosts the find bar and info pane. |
| `FormatBar` | The thin strip across the top of the document. Two-segment Text / CSV radio selector at the right-hand end, with the CSV side disabled until detection finds delimited data; choosing CSV reveals the delimiter, quote, header, pin-header and trim options. |
| `FindBar` | Find + find-&-replace UI. Replace mode adds a second row with replacement field, Replace All, Revert. **Aa** toggle for case sensitivity. |
| `InfoPane` | Right-side inspector with name / type / size / lines / words / characters. Lines update live during indexing; words / characters update during the stats scan with a `(N%)` suffix. |
| `SaveProgressSheet` | Window-modal sheet during streaming save. Cancellable. |
| `AppDelegate` | Window, menu, open flow, Open Recent, state restoration, Dock-click reopen, Finder document-type associations. |

### Syntax highlighters (per-row, stateless)

| | Recognises |
|---|---|
| `XMLHighlighter` | tags, attribute names, attribute values, comments, declarations / PIs |
| `JSONHighlighter` | keys (string + colon), string values, numbers, `true` / `false` / `null`, `//` and `/* */` comments (JSONC) |
| `MarkdownHighlighter` | headings (bold blue), bold (font), italic (colour), inline code, links (text teal + URL purple), strikethrough, fences, HR, blockquotes, list markers |
| `YAMLHighlighter` | keys (bare and quoted), strings, numbers, literals (`true`/`false`/`null`/`yes`/`no`/`on`/`off`/`~`), comments, anchors / aliases / tags, block-scalar indicators, document separators |

Multi-row constructs (XML/JSONC block comments, Markdown fenced code, YAML
block scalars) are coloured across rows by threading a small carry-state between
rows; the visible region's start state is seeded by replaying a bounded window
(~400 rows) above the viewport, so a construct opening far above the top is only
picked up once scrolled nearer — a deliberate bound that keeps cost tied to the
viewport, not the file.

## What the user gets

- `⌘O` open · `⌘L` go to line.
- `⌘F` find · `⌥⌘F` find & replace · `⌘G` / `⇧⌘G` next / previous. **Aa** toggles case sensitivity. Status shows `Searching… 23%` so long scans don't look frozen.
- `⌘S` save (atomic) · `⇧⌘S` save as. Progress sheet during save.
- `⌘C` copy · `⌘A` select all. Right-click → Copy. Select All is deliberately absent from the right-click menu (selecting many GB onto the pasteboard would try to materialise it).
- `⌘I` toggle Info Inspector.
- **`bigedit` on the command line** — installed from the app menu; `bigedit file.txt` opens the file, creating it if it does not exist.
- **Text / CSV** selector, top right. In CSV mode rows are drawn as aligned columns, the header is set in bold and can stay pinned to the top while you scroll, and the status bar reads `CSV — read-only`. Columns resize by dragging their trailing edge in the band along the top row, and double-clicking an edge returns that column to its measured width.
- Click + drag to select (with auto-scroll past the viewport edges). Double-click selects a word, triple-click selects the visual line.
- I-beam cursor over the text area.
- Window frame remembered across launches. The full set of open documents (and which one was active) is restored on launch, unless the user launched with a different file from Finder or Open Recent.
- Files are watched on disk; an external change is flagged in the title and sidebar, and **⌘R** reloads from disk (keeping the scroll position).
- **Open Recent** populated via `NSDocumentController.recentDocumentURLs`.
- **Finder integration**: declared `CFBundleDocumentTypes` covers `public.text` / `public.plain-text` / `public.source-code` / `public.xml` / `public.json` / `public.html`. Double-click and drag-to-Dock both route through `application(_:open:)`.
- **Auto-detected syntax mode** by extension (`json` / `xml` / `md` / `yaml` / …) or by first non-whitespace byte (`{`/`[` → JSON, `<` → XML).
- **Soft wrap for long lines**: lines under 1024 bytes never wrap (they overflow with horizontal scroll if narrower than the window); lines at or above 1024 bytes re-wrap to the viewport width on resize. Minified JSON becomes vertically navigable.
- **Close-window-keeps-app-alive**: closing the window leaves BigEdit in the Dock; clicking the icon brings the same document back. `⌘Q` quits.
- **Iceberg icon** sliced from the `Resources/AppIcon.png` master into a full multi-resolution `.icns` at build time (via `sips` + `iconutil`; regenerate the master from new artwork with `tools/make-icon.swift`).

## The lazy editor

### Stage 2 — positional editing (typing, delete, paste, undo)

- Click to place a caret and type: insertions, deletions, newlines, cut/paste
  — all real edits on the logical document. The file on disk stays untouched
  and memory-mapped read-only; edits are piece-table splices whose cost is
  the edit itself, never the file.
- `NSTextInputClient` conformance: IME composition (with underline), dead
  keys, press-and-hold accents. Composition bytes commit live to the piece
  table; ranges are reported in a synthetic space anchored at the marked text.
- Editing is enabled for UTF-8 / ASCII files; Return inserts the detected
  line ending (CRLF files get `\r\n`), pasted text is normalised to it, and a
  CRLF pair deletes as one unit.
- **Undo/redo** (⌘Z / ⇧⌘Z): piece-splice history with typing/deletion-run
  coalescing; Replace All reverts as one step. History clears on save (the
  document re-maps from disk).
- **Save** streams the piece table through the same atomic temp-file +
  rename path as the rule save. Constant memory; transiently needs ~file-size
  free disk — that is the price of never corrupting the original.
- **Search over edits** re-runs through the piece table (logical windows
  assembled from a piece snapshot) 300 ms after typing pauses.
- **Replace All** materialises up to 2,000 matches as one undoable grouped
  edit (newlines allowed); above that it falls back to the Stage 1 rule.
- Lifecycle: dirty dot, prompt on close/quit, ⌘R confirms before discarding
  edits, and a file that changed on disk under unsaved edits blocks saving
  over it (Save As or reload instead).

### Stage 1 — the deferred replacement rule

- One active rule at a time: `pattern → replacement`, both newline-free.
- Setting a rule starts a background `SearchScan` for the pattern. Matches stream into the viewport's transformed render (with progress %).
- **Revert** discards the rule. **Save** writes the result to disk via a fresh streaming pass that is independent of the 1M display match cap.
- After save the document re-loads from disk — the rule is cleared automatically.
- The rule and positional edits are mutually exclusive; the rule remains the path for over-cap Replace All, non-UTF-8 files, and the `--replace` CLI.

## Verification

### Headless modes (cross-checked against POSIX tools)
- `--index <path>` — line / visual-row count (vs `wc -l`)
- `--search <pattern> <path>` — match count (vs `grep -oa`)
- `--search-regex <pattern> <path>` — match count (vs `grep -oE`, via
  `scripts/verify-search-regex.sh`)
- `--preview <pattern> <replacement> <path>` — first rows after a deferred edit
- `--replace <pattern> <replacement> <in> <out>` — full deferred-edit save (vs `sed 's/pattern/replacement/g'`)
- `--stats <path>` — words / characters (vs `wc -lwm`)
- `--csv <path> [rows]` — the detected dialect and the first rows as the
  viewport draws them; `scripts/verify-csv.sh` diffs that against an
  independent replay through Python's `csv` module.
- `--process-lines <op> <in> <out> [pattern] [replacement]` — remove
  duplicates, remove/keep lines containing a pattern, sort (plain, natural, or
  by a regex key), or replace within each line;
  `scripts/verify-process-lines.sh` diffs all six against awk, grep, sort and
  sed.
- `--edit-smoke <in> <out>` — deterministic edits through the piece table +
  full undo/redo walk + piece save; `scripts/verify-editing.sh` generates a
  large input, replays the sequence in Python, and compares byte-for-byte.

### Unit tests
`Tests/BigEditTests/` — ~90 XCTests. Beyond the viewer suites (`LineIndex`,
`SearchScan`, `ReplacementRule`, `EditModel`, `FileWriter`, `StatisticsScan`,
the four highlighters), the editing stack is fuzz-tested against naive
models with seeded generators: `PieceTable` splices vs a plain array,
`EditedLayout` vs a from-scratch line layout (including long lines and wrap
changes), `EditedDocument` end-to-end, `UndoStack` history walks, and the
piece-table search vs naive search. Run with `swift test`.

### Measured performance
- 562 MB / 50M-line file: indexed in **~1.4 s**, searched (`999`) in **~1.3 s** (139,731 matches, identical to `grep`), replaced (`999` → `ZZ`) in **~2.2 s** byte-identical to `sed`.
- 100 MB single-line file (minified-JSON-shaped): indexed in **~0.17 s**; 102,400 visual rows at default wrap.

## Build & distribution

- `./make-app.sh` — `swift build -c release` → bundle the binary → slice `Resources/AppIcon.png` into the iconset via `sips` + `iconutil` → write `Info.plist` → optionally hardened-runtime-sign when `SIGN_IDENTITY` is set. `scripts/make-dmg.sh` packages the styled installer DMG (via `appdmg`). Signing + notarization run in CI (`.github/workflows/release.yml`).
- `Package.swift` — executable target + test target.
- `TODO.md` — outstanding pre-beta items (distribution blockers, polish, optional). The signing/notarization step is the only thing strictly gating a public beta.

## Honest limitations (documented)

- Hit testing maps clicks to byte offsets with CoreText, so non-ASCII selections land on character boundaries. (It falls back to a monospaced column estimate only while a replacement rule is active, since the drawn text then differs from the underlying bytes.)
- 64 MB cap on a single copy to the pasteboard.
- 1,000,000-match cap on the display match list (the save path bypasses this).
- Multi-row highlighting only looks back a bounded window (~400 rows) above the viewport, so a comment/fence/block-scalar opened further up isn't coloured until scrolled nearer.
- Editing is UTF-8 only. A file that is not valid UTF-8 is read as Windows-1252 — decoded for
  display, copy, search, statistics and CSV detection, with every byte↔character mapping exact
  because one byte is one character — and stays read-only. UTF-16 and binary are labelled but
  not decoded: the line index finds newlines by the `0x0A` byte, and UTF-16 would need an
  indexer that understands two-byte units. `scripts/verify-encodings.sh` checks the decoded
  rows, searches and character count against `iconv`.
- No VoiceOver / accessibility yet — the custom-drawn viewport exposes nothing to assistive tech.
- Word boundaries for double-click are ASCII-only.
- Unsaved edits live in memory only: they are lost on crash or quit-without-saving (the edit-storage API is shaped so an on-disk journal can add recovery later).
- Editing inside a single multi-GB line re-scans that line's span per splice — no worse than the viewer's own cost profile in a megaline file, but noticeable.
- CSV column widths are dragged per session and reset whenever a CSV option changes, since changing the delimiter, quote or trim re-measures the columns from scratch.
- CSV mode is display-only: padding means the drawn text no longer matches the file's bytes, so editing is off, search highlights sit at byte positions rather than padded ones, and column widths come from a bounded head sample (a much wider field further down is truncated). A quoted field containing a newline is not joined across rows.
- Undo history clears on save (the document re-maps from disk).
