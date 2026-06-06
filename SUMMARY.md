# BigEdit — what we built

A native macOS viewer (with deferred-edit support) for very large text /
JSON / XML / YAML / Markdown files — many GB. Swift + AppKit. The guiding
principle throughout: **memory and CPU scale with the viewport, never with the
file.** A 50 GB file and a 50 KB file cost the same to display.

## Architecture, top to bottom

### Core engine

| Component | Role |
|---|---|
| `MappedFile` | `mmap` wrapper. The OS pages in only the bytes that are actually touched. |
| `LineIndex` | Sparse line index, built on a background queue. One checkpoint per 4096 lines (byte offset + visual-row offset). Now also tracks "long lines" (≥ 1024 bytes) so they can soft-wrap to the viewport width without recomputing the whole index on resize. |
| `SearchScan` | Background `memmem` search with byte-progress reporting. Case-sensitive uses the fast path; case-insensitive is byte-by-byte with ASCII case folding. Match offsets collected (cap 1,000,000) for display. |
| `StatisticsScan` | Background per-byte pass counting words and characters; matches `wc -lwm`. |
| `ReplacementRule` + `EditModel` | The "lazy editor": one deferred find-and-replace rule, never written to disk until the user saves. The viewport renders the transformed result live. |
| `FileWriter` | Streaming save: `memmem` over the mmap'd input → write to temp file in the same directory → atomic `rename()`. Independent of the display match cap; preserves the destination's permission bits. Cancellable. |
| `TextSelection` | Selection range in original byte offsets. |

### UI layer

| Component | Role |
|---|---|
| `ViewportView` | Custom `NSView`. Renders ~60 visible rows; never builds a view as tall as the document. Click+drag selection, auto-scroll past edges, double-click word / triple-click line, copy to pasteboard, I-beam cursor, right-click → Copy. Layers search highlights, selection rect, replacement-rule preview, and per-row syntax colouring. |
| `DocumentView` | Container. Drives a custom `NSScroller` directly over `0…visualRowCount` rather than using `NSScrollView` — sidesteps the coordinate-precision breakdown a billion-point-tall document view would hit. Hosts the find bar and info pane. |
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

All four are stateless per-row, which keeps them cheap but means multi-row
constructs (comments, fences, block scalars) only colour their first row.

## What the user gets

- `⌘O` open · `⌘L` go to line.
- `⌘F` find · `⌥⌘F` find & replace · `⌘G` / `⇧⌘G` next / previous. **Aa** toggles case sensitivity. Status shows `Searching… 23%` so long scans don't look frozen.
- `⌘S` save (atomic) · `⇧⌘S` save as. Progress sheet during save.
- `⌘C` copy · `⌘A` select all. Right-click → Copy. Select All is deliberately absent from the right-click menu (selecting many GB onto the pasteboard would try to materialise it).
- `⌥⌘I` toggle Info Inspector.
- Click + drag to select (with auto-scroll past the viewport edges). Double-click selects a word, triple-click selects the visual line.
- I-beam cursor over the text area.
- Window frame remembered across launches. The last file is restored on launch unless the user launched with a different file from Finder or Open Recent.
- **Open Recent** populated via `NSDocumentController.recentDocumentURLs`.
- **Finder integration**: declared `CFBundleDocumentTypes` covers `public.text` / `public.plain-text` / `public.source-code` / `public.xml` / `public.json` / `public.html`. Double-click and drag-to-Dock both route through `application(_:open:)`.
- **Auto-detected syntax mode** by extension (`json` / `xml` / `md` / `yaml` / …) or by first non-whitespace byte (`{`/`[` → JSON, `<` → XML).
- **Soft wrap for long lines**: lines under 1024 bytes never wrap (they overflow with horizontal scroll if narrower than the window); lines at or above 1024 bytes re-wrap to the viewport width on resize. Minified JSON becomes vertically navigable.
- **Close-window-keeps-app-alive**: closing the window leaves BigEdit in the Dock; clicking the icon brings the same document back. `⌘Q` quits.
- **Iceberg icon** sliced from the `Resources/AppIcon.png` master into a full multi-resolution `.icns` at build time (via `sips` + `iconutil`; regenerate the master from new artwork with `tools/make-icon.swift`).

## The deferred-edit feature (Stage 1 of the "lazy editor")

- One active rule at a time: `pattern → replacement`, both newline-free.
- Setting a rule via Replace All starts a background `SearchScan` for the pattern. Matches stream into the viewport's transformed render (with progress %).
- The document edit indicator dot appears in the close button (`isDocumentEdited`).
- **Revert** discards the rule. **Save** writes the result to disk via a fresh streaming pass that is independent of the 1M display match cap.
- After save the document re-loads from disk — the rule is cleared automatically.
- Stage 2 (positional / hand-typed edits, undo stack) is planned, not built.

## Verification

### Headless modes (cross-checked against POSIX tools)
- `--index <path>` — line / visual-row count (vs `wc -l`)
- `--search <pattern> <path>` — match count (vs `grep -oa`)
- `--preview <pattern> <replacement> <path>` — first rows after a deferred edit
- `--replace <pattern> <replacement> <in> <out>` — full deferred-edit save (vs `sed 's/pattern/replacement/g'`)
- `--stats <path>` — words / characters (vs `wc -lwm`)

### Unit tests
`Tests/BigEditTests/` — 16 XCTests covering `LineIndex`, `SearchScan` (both
case modes), `ReplacementRule`, `EditModel`, `FileWriter`, `StatisticsScan`,
and the four highlighters. Run with `swift test`.

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
- Highlighters are per-row stateless: multi-row XML comments, Markdown fenced code blocks, and YAML block scalars only colour their opening row.
- UTF-8 only.
- No VoiceOver / accessibility yet — the custom-drawn viewport exposes nothing to assistive tech.
- No keyboard selection extension (shift+arrow).
- Word boundaries for double-click are ASCII-only.
- Stage 2 of the lazy editor (positional edits + undo) not implemented.
