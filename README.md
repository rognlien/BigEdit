# BigEdit

A native macOS editor for very large text / JSON / XML files (many GB).
Built with Swift and AppKit.

The guiding principle: **memory and CPU scale with the viewport and the
edits, never with the file.** A 50 GB file and a 50 KB file cost the same to
display, and editing either costs only what the edits themselves weigh: the
file stays memory-mapped read-only while edits live in a piece table, and the
full file is only written out — streaming, atomically — when you save.

## Build & run

```sh
./make-app.sh && open BigEdit.app  # build a standalone app and launch it
```

Use the app bundle for normal use: it runs independently of any terminal.
`swift run BigEdit` also works, but that process is a child of its shell and
dies when the shell or `swift run` is interrupted — handy for quick tests only.

```sh
# Headless modes, for testing without the GUI:
swift run -c release BigEdit --index /path/to/file
swift run -c release BigEdit --search <pattern> /path/to/file
```

The package opens directly in Xcode (`File ▸ Open…` the `BigEdit` folder).

## Usage

- **⌘O** — open a file.
- **Click and type** — edit in place (UTF-8 files). **⌘Z** / **⇧⌘Z** undo and
  redo; **⌘X/⌘C/⌘V** cut, copy, paste. **⌘S** saves atomically via a streaming
  temp-file write.
- **⌘F** — find. Type a query and press Enter to search.
- **⌘G** / **⇧⌘G** — next / previous match. **Esc** closes the find bar.

## Status — steps 1–5 of the plan

| Step | Component | File |
|------|-----------|------|
| 1 | `mmap` file access | `MappedFile.swift` |
| 1 | Sparse line index, built on a background queue | `LineIndex.swift` |
| 2 | Viewport view — draws only visible rows | `ViewportView.swift` |
| 3 | Custom `NSScroller`-driven scrolling | `DocumentView.swift` |
| 4 | Long-line / minified-JSON chunking | `LineIndex.swift` |
| 5 | Literal search + find bar | `SearchScan.swift`, `FindBar.swift` |

App shell (window, menu, open panel) is in `AppDelegate.swift` / `main.swift`.

### How it works

- **`MappedFile`** maps the file with `mmap`; the OS pages in only the bytes
  actually touched.
- **`LineIndex`** scans for newlines and stores one *checkpoint* every 4096
  lines. To reach line *N* it jumps to the nearest checkpoint and scans forward.
  The index stays small for any file size. Scanning runs in the background and
  publishes progress incrementally, so the window opens instantly.
- **Long-line chunking** — a line longer than `bytesPerChunk` (1024) is shown
  as a stack of *visual rows*, each one a 1024-byte chunk. A minified JSON file
  that is one 5 GB line becomes ~5M navigable rows instead of one unreadable
  row. Each checkpoint also stores a cumulative visual-row count, so a scroll
  position maps to a `(line, chunk)` in `O(log n)`. The chunk size is fixed, so
  nothing is recomputed when the window is resized.
- **`ViewportView`** holds the scroll position as a *fractional visual-row
  number* and draws only the ~60 visible rows. It never builds a view as tall
  as the whole document.
- **`DocumentView`** drives an `NSScroller` directly over `0...visualRowCount`
  instead of using `NSScrollView`, avoiding the coordinate-precision breakdown
  that a billion-point-tall document view would cause.
- **`SearchScan`** searches the mmap'd bytes with `memmem` on a background
  queue, collecting match offsets into a sorted array (capped at 1,000,000).
  Navigation is array indexing; highlighting visible matches is a binary search
  into that array. `LineIndex.visualRow(forByteOffset:)` maps a match back to a
  row so it can be scrolled into view.

### Measured

- 562 MB / 50M lines indexed in ~1.4 s (~390 MB/s, single background thread).
- A 100 MB single-line file indexes in ~0.17 s — and is now 102,400 navigable
  visual rows.
- Searching the 562 MB file took ~1.3 s; the match count matched `grep -o`
  exactly (139,731 hits for `999`).

## Known limitations (later plan steps)

- Long lines wrap at a **fixed 1024-byte column**, not the window width, so a
  chunk wider than the window needs horizontal scrolling. Window-width soft
  wrap could be a later view option.
- A chunk seam falling inside a multi-byte UTF-8 character renders one
  replacement glyph at the seam (rare in ASCII-dominant JSON/XML).
- Search is **literal and case-sensitive**; no regex. Matches beyond the
  1,000,000th are not collected (shown as `N+`).
- No syntax highlighting yet (**step 6**).
- Encoding is assumed UTF-8; CRLF line endings are handled.
