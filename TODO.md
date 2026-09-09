# BigEdit — TODO

What is actually left. Everything above the "Done" section is open work;
`[x]` items in Done are recorded so this file stops re-proposing them.

Last audited against the code on 2026-09-09, at v0.1.16 plus the CSV column
resize and the horizontal-scroll fix.

## New features

- [ ] **Process lines.** A "Process lines" function operating on the whole
      document:
      - Remove duplicate lines.
      - Remove lines containing a pattern.
      - Sort lines (naturally, or by a regex-extracted key).
      - Process each line with a regex.
      Needs a decision on how results are produced: materialised as undoable
      edits through the piece table (like Replace All under its cap), or
      streamed to a new document. Sorting in particular cannot be viewport-
      bounded — it has to read the whole file — so it needs a progress sheet
      and a cancel, and a stated ceiling on file size.
- [ ] **Command line tool.** A `bigedit` executable, bundled inside the app and
      installed by clicking a button in BigEdit (the usual pattern is a symlink
      into `/usr/local/bin`, which needs an authorisation prompt). `bigedit
      file.txt` opens that file in BigEdit, creating it if it does not exist.

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

## Follow-ups from shipped work

- [ ] **Editing (from Stage 2).**
      - On-disk edit journal behind `AddedByteStore`: crash/quit recovery for
        unsaved edits, and disk-backed storage for huge pastes.
      - Undo across save (retain the retired `MappedFile` in old records).
      - **Manual IME test pass** (Japanese/Chinese input, dead keys,
        press-and-hold). The `NSTextInputClient` synthetic-range scheme has
        only ever had unit tests, and has now shipped to users twice.
      - Word/character statistics over the edited document (still computed from
        the file on disk).
      - Raise the Replace All materialisation cap by moving the layout's prefix
        sums into a balanced tree (same pattern as `PieceTable`).
      - `⌘N` new empty document.
- [ ] **CSV.**
      - Make CSV mode editable: padding breaks the byte↔pixel mapping, so the
        mode is display-only. Mapping a click back through the padding would
        restore editing and exact search highlights.
      - Column widths come from a bounded head sample, so a wider field further
        down is truncated. Widening on demand as rows scroll into view needs
        the same care that kept the layout viewport-bound.
      - Join a quoted field that spans a newline across rows, which means a
        CSV-aware line model rather than physical lines.
      - Remember the chosen mode, dialect and dragged column widths per
        document; widths currently reset when an option changes and are not
        restored when reopening a file.

## Optional

- [ ] **Universal binary (arm64 + x86_64).** `make-app.sh` builds arm64 only.
      Add `--arch arm64 --arch x86_64`, or build twice and `lipo`. Only matters
      if you have Intel users.
- [ ] **Sandboxing.** Required only for the Mac App Store. The
      temp-file-next-to-destination save interacts with sandbox file access and
      would need security-scoped bookmarks for the destination directory.
- [ ] **Crash reporting.** Apple already collects crashes; integrate
      Sentry/Bugsnag/KSCrash only if you want them yourself.

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
- [x] **Unit tests.** 124 XCTests, run in CI on every PR, plus the headless
      cross-checks below.
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
- [x] **Horizontal scrolling is bounded** by the widest row drawn, so no
      document scrolls off into empty space.

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
