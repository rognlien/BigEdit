# BigEdit — TODO

What is actually left. Everything above the "Done" section is open work;
`[x]` items in Done are recorded so this file stops re-proposing them.

Last audited against the code on 2026-10-19, at v0.1.24 plus the work that
followed it: the highlighter refactor finished, safe crash recovery,
Windows-1252 and Latin-1 editing, CSV cell editing, per-file view state,
adaptive limits for small documents, the README rewrite, the input-method
test pass, untitled documents and sampled encoding detection.

## Beta polish

- [ ] **README screenshots.** The text is rewritten for the beta; it still
      wants screenshots (open file, search, info pane, coloured JSON/XML/
      Markdown/YAML, CSV columns) and a short GIF of scrolling a huge file and
      a Find & Replace.
- [ ] **VoiceOver / accessibility.** `ViewportView` is custom-drawn and exposes
      nothing to assistive tech. Real fix: `NSAccessibilityStaticText` (or
      similar) exposing visible row text via `accessibilityValue`. Substantial;
      until then it belongs in the README's limitations.

## Follow-ups from shipped work

- [ ] **Editing (from Stage 2).**
      - Disk-backed storage for huge pastes. The journal mirrors the add
        buffer to disk already, but the buffer itself is still in memory.
      - **Input methods by hand.** `InputMethodTests` replays the call
        sequences, but a real Kotoeri/Pinyin session, dead keys,
        press-and-hold and the Character Viewer still want one manual pass —
        especially the candidate window's position (also under a pinned CSV
        header) and clicks inside marked text.
      - Backspace and Forward Delete remove one scalar at a time; Indic and
        Thai want Backspace by mark, everything else by character.
      - Escape after a composition that quoted a CSV cell leaves the quotes;
        composing in a newly quoted cell undoes step by step.
      - The emacs moves (Ctrl-F/B/N/P, `moveForward:` and friends) are not
        implemented.
      - Raise the Replace All materialisation cap by moving the layout's prefix
        sums into a balanced tree (same pattern as `PieceTable`).
- [ ] **Regular-expression search.** One match cannot span more than one
      scan window (~4 MB of lines); the streaming Replace All has the same
      bound, and writes to a file rather than landing as an undoable edit.
- [ ] **Compare Documents.** Both lists are held in memory (256 MB each);
      a gap with no unique lines larger than the Myers limit is reported as
      one replacement rather than diffed. A view-only diff over two line
      indexes would lift the ceiling.
- [ ] **Apple Intelligence.** Only patterns: a sentence to a regular
      expression and back. Describing a whole Process Lines operation
      ("remove lines that look like timestamps") would need the sheet's
      choices generated too. Writing Tools on the custom-drawn viewport
      would need `NSWritingToolsCoordinator` adopted — useful for Markdown,
      not for logs.
- [ ] **iCloud.** The saved patterns sync as a plain file in iCloud Drive.
      `NSUbiquitousKeyValueStore` for preferences, or CloudKit, needs an
      iCloud container and an embedded provisioning profile in the Developer
      ID build; deferred until the App Store question is decided.
- [ ] **Follow File.** Only a clean document follows; an append to a file
      with unsaved edits would have to be spliced in behind every edit.
- [ ] **Windows-1252 / Latin-1.** Above 4 MB detection samples 1 MB through
      the file, so a lone legacy byte between the samples is missed and the
      file opens as UTF-8. Process Lines and CSV sorting decode as UTF-8 and are refused outside
      it. A row holding a byte Windows-1252 leaves undefined (0x81, 0x8D…) is
      decoded as Latin-1 throughout, so a € on that row shows as U+0080.
- [ ] **Edit journal.** A journal kept with Not Now leaves that session's
      document unjournaled, so a second crash loses its edits. Tests that load
      a `DocumentView` write journals into the real Application Support folder.
- [ ] **Untitled documents.** Only the model is tested; ⌘N, the first save,
      the close sheet and quit-and-relaunch want a click-through. Journal
      appends are not fsynced, so a power loss may drop an untitled
      document's last edits with no prompt to fall back on. Replace in File,
      Convert to UTF-8 and Follow write into the placeholder and leave the
      document untitled.
- [ ] **CSV.**
      - **Cell editing gaps.** Ctrl-K is not cell-aware; lines of 1024 bytes
        or more keep plain-text typing and deleting; clearing a selection
        reads the lines it touches, so above 64 MB it is refused; a
        selection edge inside a doubled quote can leave a stray quote. With
        Return taken
        by cell navigation, a row cannot be inserted mid-table in CSV mode.
      - Sorting rewrites the file under the 32 MB Process Lines ceiling. A
        view-only sort (a permutation over the line index) would lift the
        ceiling and leave the file clean, at the cost of a new layer between
        rows and lines.
      - Above 4 MB, column widths come from a bounded head sample, so a wider
        field further down is truncated. Widening on demand as rows scroll
        into view needs the same care that kept the layout viewport-bound.
      - Join a quoted field that spans a newline across rows, which means a
        CSV-aware line model rather than physical lines.

## Optional

- [ ] **Mac App Store.** Wanted at some point; MIT keeps it open. Two things
      stand in the way:
      - **Sandboxing.** The temp-file-next-to-destination save interacts with
        sandbox file access and would need security-scoped bookmarks for the
        destination directory.
      - **The privileged helper.** `SMJobBless` and a root helper are not
        allowed in a sandboxed app, so the `bigedit` command's installer would
        have to become a user-run script (or a symlink the user creates from a
        sheet's instructions) in the App Store build.
- [ ] **Crash reporting.** Apple already collects crashes; integrate
      Sentry/Bugsnag/KSCrash only if you want them yourself.

## Decided against

- **Universal binary (arm64 + x86_64).** Not worth the doubled build and
  download for an audience that is entirely Apple silicon. `swift build --arch
  arm64 --arch x86_64` does work if this is ever revisited. Decided 2026-09-09.

## Done

Distribution, and the beta-polish list, are finished — this section exists so
they are not proposed again.

- [x] **Distribution channel decided.** GitHub Releases (notarized DMG) plus
      the download page at `maendeleo.io/bigedit`, updated by
      `scripts/update-site.sh`.
- [x] **One window or many, decided.** Multiple documents in one window with a
      sidebar list.
- [x] **Code signing, notarization, hardened runtime, entitlements.** All in
      `.github/workflows/release.yml`; `BigEdit.entitlements` ships the
      user-selected-files entitlement. App and DMG are both stapled.
- [x] **Bundle metadata.** `io.maendeleo.BigEdit`, `NSHumanReadableCopyright`,
      and CI-driven monotonic `CFBundleVersion` in `make-app.sh`.
- [x] **DMG packaging.** `scripts/make-dmg.sh` builds the styled drag-install
      DMG via `appdmg`.
- [x] **Sparkle auto-update.** Shipping, with the appcast regenerated per
      release.
- [x] **Right-click context menu** on the viewport (`menu(for:)`).
- [x] **Case-insensitive find** — the **Aa** toggle in the find bar.
- [x] **Go to Line (⌘L).**
- [x] **Dock-click reopen** (`applicationShouldHandleReopen`).
- [x] **Cancel `LineIndex` indexing** when the file changes — `LineIndex` has
      `cancel()` alongside `SearchScan` and `StatisticsScan`.
- [x] **Unit tests.** 701 XCTests, run by the release workflow and on demand
      from the Actions tab, plus the headless cross-checks below. CI stopped
      running per push while the repository was private; now that it is
      public, standard runners are free and per-push runs could return.
- [x] **Word-width hit testing** via `CTLineGetStringIndexForPosition`.
- [x] **Cursor refinement** — the I-beam stops at the gutter.
- [x] **Carry lexer state across rows** — `HighlightState` threads through
      rows, seeded by replaying a bounded window above the viewport.
- [x] **Window-width soft wrap** — `currentWrapBytes()` derives the wrap column
      from the text area's width instead of a fixed 1024 bytes.
- [x] **Stage 2 of the lazy editor.** Piece table, edit-aware layout, IME
      input, undo/redo, piece-walking save, search over edits, Replace All
      materialised under a 2,000-match cap.
- [x] **CSV support.** A Text / CSV radio selector at the top right, enabled
      for any file (a file with no detected dialect asks how to split it); CSV mode draws aligned columns with delimiter, quote, header,
      pin-header and trim options, and columns resize by dragging their
      trailing edge.
- [x] **Process lines — the engine.** `LineProcessor` does remove duplicates,
      remove/keep lines containing a pattern, sort (plain, natural, or by a
      regex-extracted key, stably), and regex replacement within each line.
      Cross-checked against awk, grep, sort and sed by
      `scripts/verify-process-lines.sh`.
- [x] **The `bigedit` command line tool.** Bundled in the app, installed from
      the app menu via a privileged helper whose authorisation accepts Touch ID.
      `scripts/verify-helper.sh` checks the SMJobBless preconditions in CI.
- [x] **Word/character statistics over the edited document.**
- [x] **`⌘N` new empty document.**
- [x] **Return at the end of a document.** A trailing newline now has a visual
      row of its own, and spans covering only inserted text stay in order — two
      separate bugs that together made Return look like it did nothing, then
      shift the previous line.
- [x] **Horizontal scrolling is bounded** by the widest row drawn, so no
      document scrolls off into empty space.
- [x] **Process lines — the user interface.** A sheet picks the operation and
      pattern, runs it off the main thread with progress and cancel, and lands
      the result as one undoable edit.
- [x] **Drop any file on the Dock icon** to open it.
- [x] **Parallel line indexing** — one chunk per core for files of 64 MB and
      up, stitched in order (471 MB: 0.134 s → 0.020 s).
- [x] **Regular-expression search** — the **.\*** toggle in the find bar;
      windows cut at line boundaries and scanned concurrently. Cross-checked
      against `grep -oE` by `scripts/verify-search-regex.sh`.
- [x] **Follow File (⇧⌘T)** — an append remaps the file and extends the line
      index from the old trailing line instead of rebuilding; pinned to the
      end when the view was there.
- [x] **Undo across save** — the mapping a save replaced is retired, not
      dropped, so ⌘Z reaches back through ⌘S (up to 8 retired mappings).
- [x] **Edit journal** — unsaved edits mirrored to disk as they happen;
      reopening the file after a crash offers to recover them.
- [x] **Windows-1252 / Latin-1 decoding** — files that are not valid UTF-8
      read, copy, search and count correctly, labelled in the status bar.
      Cross-checked against `iconv` by `scripts/verify-encodings.sh`.
- [x] **Search results list (⌥⌘L)** — every match with line number and
      snippet, built row by row on demand; click to jump.
- [x] **Highlighter refactor** — `RowScanner`, tokens and a theme, a
      `Highlighter` protocol with per-language state and a `LanguageRegistry`
      (proved byte-identical by a parity harness), exact state checkpoints
      every 256 rows, a per-row token cache, and View ▸ Syntax Coloring with
      the language in the status bar.
- [x] **Sources grouped by layer** and the three largest files split into
      one file per concern (`ViewportView`, `AppDelegate`, `DocumentView`);
      `HeadlessCommands` owns the command table.
- [x] **Find bar laid out like the system's** — options in the search field's
      magnifier menu, one segmented control for previous / next, Done, aligned
      replace field; Tab moves between the fields.
- [x] **Toolbar** — Find, Find & Replace and Info in a unified title bar,
      with the native proxy icon replacing the hand-drawn centred title.
- [x] **CSV sorting** — click a header (again for descending) or right-click
      a cell; natural order, header kept first, one undoable edit.
- [x] **CSV grid and cell geometry** — a faint grid under the table, a
      character of padding each side of a cell, and `CSVRowMap` so clicks,
      selection and search highlights land on the cell text they show.
- [x] **MIT license.**
- [x] **CSV mode is editable.** Typing goes into the cell the caret was
      placed in, Tab and Shift-Tab select the next and previous cell, a
      column widens to fit what is typed, and a cell a row does not have yet
      is created by the first character typed into it.
- [x] **Process Lines runs under CSV columns**, like sorting: it rewrites the
      whole document, which needs no caret.
- [x] **Set operations** — subtract, intersect, union, symmetric difference
      against another open document or a file, matched by whole line, trimmed,
      case-folded, or a regex key; subtract and intersect stream to a new file
      above the ceiling. Checked against `grep -Fxf` by
      `scripts/verify-process-lines.sh`.
- [x] **Compare Documents** — three-way line-set compare plus a patience /
      Myers sequence diff with unified export.
- [x] **Saved patterns** — one JSON library shared by the find bar, the Find
      menu and the Process Lines sheet, with a manage window and an iCloud
      Drive location.
- [x] **Live regular-expression feedback** — problems explained as typed,
      live search under 64 MB, `$1` preview, Dot Matches Newline, reference
      card.
- [x] **Streaming regular-expression Replace All** — no match cap; checked
      against `perl -pe` by `scripts/verify-replace-regex.sh`.
- [x] **iCloud Drive placeholders** are downloaded before opening.
- [x] **Apple Intelligence** — describe a pattern, explain a pattern, behind
      `canImport(FoundationModels)` and an availability check. Releases are
      built with the macOS 26 SDK so it ships.
- [x] **Settings window** — appearance, font, images and updates; syntax
      colours with readable contrast in light and dark mode.
- [x] **Window frame and sidebar width** remembered between launches.
- [x] **Shell script and SQL colouring.**
- [x] **Command-arrows** move and select to line and document ends.
- [x] **Column selections** can be deleted and cut, not just copied.
- [x] **Tabs** — Option-Tab types one everywhere, stops fall on whole
      characters, and text mode marks each with a faint arrow.
- [x] **CSV keyboard and reload** — Tab past the last column adds one, the
      grid is visible in dark mode, a reload keeps the view mode and CSV
      options, and columns are measured from the edited text.
- [x] **Safe crash recovery** — the journal fingerprints its baseline (size,
      inode, date and a digest of the first and last 64 KB); a changed file is
      never replayed onto, and abandoned journals are removed at launch.
- [x] **Windows-1252 / Latin-1 editing** in the file's own encoding, with
      unrepresentable characters refused and File ▸ Convert to UTF-8….
- [x] **CSV cell editing** — typed delimiters and quotes quote the cell,
      Return moves down a row, Delete stops at cell edges, and deleting across
      cells clears them.
- [x] **Per-file view state** — mode, CSV options, resized columns and the
      chosen language are remembered; resized columns survive option changes.
- [x] **Adaptive limits below 4 MB** — exact colouring from the first row,
      CSV widths from every row, and every search match collected and listed.
- [x] **README** rewritten for the public beta, linking Releases and Issues.
- [x] **Input-method test pass** — Kotoeri, Pinyin, dead keys,
      press-and-hold and the Character Viewer replayed in tests; arrows,
      press-and-hold, clause selection, candidate placement, whole-character
      caret steps and CSV quoting of compositions fixed.
- [x] **Untitled documents** — ⌘N without a dialog, kept across quit, asked
      where on first save.
- [x] **Encoding detection beyond the first 64 KB.**

## Verification scripts to keep around

The cheapest correctness checks, all cross-checked against POSIX tools or an
independent implementation.

- `swift run BigEdit --index <path>` — line/row count vs `wc -l`.
- `swift run BigEdit --search <pattern> <path>` — match count vs `grep -oa`.
- `swift run BigEdit --stats <path>` — words/chars vs `wc -lwm`.
- `swift run BigEdit --preview <pattern> <replacement> <path>` — first rows
  with a deferred edit vs `sed`.
- `swift run BigEdit --replace <pattern> <replacement> <in> <out>` — full
  edited file vs `sed 's/pattern/replacement/g'`.
- `swift run BigEdit --csv <path> [rows]` — detected dialect and aligned rows;
  `scripts/verify-csv.sh` diffs them against Python's `csv` module.
- `scripts/verify-editing.sh` — edits, undo/redo walk and piece save against an
  independent Python replay.
- `scripts/verify-process-lines.sh` — every line operation against awk, grep,
  sort and sed.
- `scripts/verify-search-regex.sh` — regular-expression match counts against
  `grep -oE`.
- `scripts/verify-encodings.sh` — Windows-1252 and Latin-1 decoding against
  `iconv`.
- `scripts/verify-replace-regex.sh` — the streaming regular-expression
  replace against `perl -pe 's///g'`.
