# BigEdit — TODO

What is actually left. Everything above the "Done" section is open work;
`[x]` items in Done are recorded so this file stops re-proposing them.

Last audited against the code on 2026-09-12, at v0.1.20 plus editable CSV
mode: the seven improvements, the source split into folders and per-concern
files, the system-style find bar and toolbar, CSV sorting, grid, exact cell
mapping, editing with Tab between cells, the MIT license, and CI on demand
only.

## Syntax highlighting — making it extendable

Steps 1–2 of the agreed refactor have landed (`RowScanner`, then
`Token`/`TokenKind` + `HighlightTheme`). Each remaining step is its own
pure-refactor PR with no functional change.

- [ ] **Step 3: `Highlighter` protocol + `LanguageRegistry`** (extensions,
      sniff, display name) replacing the two `switch` statements in
      `ViewportView` and the extension tables in `DocumentView`; make
      `HighlightState` opaque per language.
- [ ] **Step 4: state checkpoints every N rows** to replace the 400-row
      lookback in `seedState`.
- [ ] **Step 5: per-row token cache** keyed by row identity, start state and
      mode.
- [ ] **Step 6: user-facing language override** (View menu + status bar).

## Beta polish

- [ ] **README polish.** Still dev-facing. For a public beta it wants: what
      BigEdit is and who it is for; screenshots (open file, search, info pane,
      coloured JSON/XML/Markdown/YAML, CSV columns); a short GIF of scrolling a
      huge file and a Find & Replace; system requirements (macOS 13+); the
      honest limitations already listed in `SUMMARY.md`; and how to file a bug.
- [ ] **VoiceOver / accessibility.** `ViewportView` is custom-drawn and exposes
      nothing to assistive tech. Real fix: `NSAccessibilityStaticText` (or
      similar) exposing visible row text via `accessibilityValue`. Substantial;
      until then it belongs in the README's limitations.

## Adaptive limits for small documents

Several bounds exist only because a document might be enormous. Below a size
threshold each could be lifted, with no user-visible "mode" — the same bargain
Replace All already makes when it materialises under its cap and falls back to
the streaming rule above it.

- [ ] **Whole-file lexer state** instead of replaying a bounded ~400-row window
      above the viewport, so a construct opened far above is coloured.
- [ ] **Exact CSV column widths** measured from the whole file rather than a
      head sample, so a wider field further down is not truncated.
- [ ] **No 1,000,000-match display cap** on search, and no 100,000-row cap on
      the search results list.

## Follow-ups from shipped work

- [ ] **Editing (from Stage 2).**
      - Disk-backed storage for huge pastes. The journal mirrors the add
        buffer to disk already, but the buffer itself is still in memory.
      - **Manual IME test pass** (Japanese/Chinese input, dead keys,
        press-and-hold). The `NSTextInputClient` synthetic-range scheme has
        only ever had unit tests, and has now shipped to users twice.
      - Raise the Replace All materialisation cap by moving the layout's prefix
        sums into a balanced tree (same pattern as `PieceTable`).
- [ ] **Regular-expression search.** One match cannot span more than one
      scan window (~8 MB of lines), and Replace All with a pattern works only
      under the materialisation cap — there is no streaming form of it.
- [ ] **Follow File.** Only a clean document follows; an append to a file
      with unsaved edits would have to be spliced in behind every edit.
- [ ] **Windows-1252 / Latin-1 files are read-only**, since edits are made in
      UTF-8. Writing back in the file's own encoding needs `TextEncoding.encode`
      on the save path and a decision for characters it cannot represent.
- [ ] **Edit journal.** Recovery replays into a document opened over the same
      file; it does not yet offer recovery when the file has changed on disk
      since the edits were made, and journals of files that were never
      reopened are not cleaned up.
- [ ] **CSV.**
      - **Cell semantics while editing.** Editing is text editing under a
        table rendering: a delimiter typed into a cell splits it, and
        deleting across a divider merges two cells. Treating those as cell
        operations — quoting a typed delimiter, stopping a delete at the
        cell edge — would make the mode feel like a spreadsheet rather than
        like padded text.
      - Sorting rewrites the file under the 32 MB Process Lines ceiling. A
        view-only sort (a permutation over the line index) would lift the
        ceiling and leave the file clean, at the cost of a new layer between
        rows and lines.
      - Column widths come from a bounded head sample, so a wider field further
        down is truncated. Widening on demand as rows scroll into view needs
        the same care that kept the layout viewport-bound.
      - Join a quoted field that spans a newline across rows, which means a
        CSV-aware line model rather than physical lines.
      - Remember the chosen mode, dialect and dragged column widths per
        document; widths currently reset when an option changes and are not
        restored when reopening a file.

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
- [x] **Unit tests.** 309 XCTests, run by the release workflow and on demand
      from the Actions tab (CI no longer runs per push: macOS minutes are
      billed 10× for a private repository), plus the headless cross-checks
      below.
- [x] **Word-width hit testing** via `CTLineGetStringIndexForPosition`.
- [x] **Cursor refinement** — the I-beam stops at the gutter.
- [x] **Carry lexer state across rows** — `HighlightState` threads through
      rows, seeded by replaying a bounded window above the viewport.
- [x] **Window-width soft wrap** — `currentWrapBytes()` derives the wrap column
      from the text area's width instead of a fixed 1024 bytes.
- [x] **Stage 2 of the lazy editor.** Piece table, edit-aware layout, IME
      input, undo/redo, piece-walking save, search over edits, Replace All
      materialised under a 2,000-match cap.
- [x] **CSV support.** Detection enables a Text / CSV radio selector at the top
      right; CSV mode draws aligned columns with delimiter, quote, header,
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
- [x] **Highlighter refactor, steps 1–2** — `RowScanner`, then tokens and a
      theme; both proved byte-identical by a parity harness.
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
