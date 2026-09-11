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
swift run -c release BigEdit --search-regex <pattern> /path/to/file
swift run -c release BigEdit --dump /path/to/file [rows]   # rows decoded as shown
swift run -c release BigEdit --csv /path/to/file [rows]
```

The package opens directly in Xcode (`File ▸ Open…` the `BigEdit` folder).

## Usage

- **⌘N** — create a new file and open it.
- **⇧⌘T** — View ▸ Follow File: like `tail -f`. Bytes appended on disk are
  indexed incrementally and shown as they arrive, and the view stays pinned
  to the end if it was there. A file that shrinks or is replaced reloads in
  full instead; a document with unsaved edits does not follow.
- **⌘O** — open a file.
- **Click and type** — edit in place (UTF-8 files). **⌘Z** / **⇧⌘Z** undo and
  redo, including back across a save; **⌘X/⌘C/⌘V** cut, copy, paste. **⌘S**
  saves atomically via a streaming temp-file write. Unsaved edits are
  journaled to disk as you make them, so if BigEdit crashes or is
  force-quit, opening the file again offers to recover them.
- **⌘F** — find. Type a query and press Enter to search. The magnifier menu
  in the search field holds **Match Case** and **Regular Expression** (`^`
  and `$` match at line boundaries, as in `grep`).
- **⌘G** / **⇧⌘G** — next / previous match. **Esc** or **Done** closes the
  find bar.
- **⌥⌘L**, or **Show All Matches** in the magnifier menu — every match as a
  list below the viewport, with its line number and a snippet; click one to
  jump to it.
  The list is built row by row as you scroll it, so a million matches cost
  nothing until they are looked at; the first 100,000 are listed.
- **Text / CSV** — the selector at the top right of the editor. The CSV side
  becomes available when the file is detected as delimited data, and turns it
  into aligned columns on a faint grid, with options for the delimiter, quote character,
  header row, pinning the header while scrolling, and trimming field spaces.
- **Click a column header** to sort the table by that column — naturally, so
  `9` comes before `10`; click again for descending. Right-click any cell
  for Sort Ascending / Descending by that column. The sort is one undoable
  edit (⌘Z puts the rows back) and, like Process Lines, holds every line in
  memory, so it is limited to files of 32 MB.
- **Drag a column edge** — the ticks along the top row mark each column's
  trailing edge; the pointer becomes a resize cursor within a few pixels of
  one. **Double-click an edge** to put that column back to the width its own
  content asks for. Widths reset when a CSV option changes, since that
  re-measures the columns.

## Command line

BigEdit ships a `bigedit` command inside the app bundle. Install it from
**BigEdit ▸ Install Command Line Tool…**, which symlinks it into
`/usr/local/bin` (asking for an administrator password only if that directory
is not writable).

```sh
bigedit notes.txt          # open it, creating the file if it does not exist
bigedit a.csv b.json       # open several at once
bigedit                    # just bring BigEdit to the front
bigedit --help
```

It is a symlink rather than a copy, so updating BigEdit updates the command
with it.

`/usr/local/bin` is owned by root, so the first install asks for authorisation.
BigEdit does that through a small privileged helper — the supported way for an
app to do privileged work — and the system's dialog for it accepts **Touch ID**
as well as a password. You are asked once; later installs and updates need no
prompt. The helper takes one instruction (link this tool into one of a fixed
list of directories), runs no shell, and only accepts connections from BigEdit
itself.

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

- Indexing runs one chunk per core for files of 64 MB and up. A 471 MB /
  12M-line file (page-cached) indexes in ~0.02 s on an 18-core machine, against
  ~0.13 s single-threaded; a cold file is bound by the disk either way. The
  parallel scan is tested to be indistinguishable from the serial one.
- 562 MB / 50M lines indexed in ~1.4 s single-threaded (~390 MB/s) before that.
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
- Regular-expression search runs one window of lines at a time, so a single
  match cannot span more than ~8 MB of lines. Matches beyond the 1,000,000th
  are not collected (shown as `N+`), and Replace All with a pattern only
  works under the materialisation cap — there is no streaming form of it.
- Syntax highlighting covers XML, JSON, Markdown, and YAML; other files draw
  as plain text.
- Files are read as UTF-8, or as Windows-1252 when they are not valid UTF-8
  (the status bar says which). A Windows-1252 file reads, copies, searches
  and counts correctly but stays read-only, since edits are made in UTF-8.
  UTF-16 and binary files are labelled but not decoded. CRLF line endings
  are handled.
- **CSV mode is display-only.** Padding fields into columns means the drawn
  text no longer matches the file's bytes, so editing is off and search
  highlights sit at byte positions rather than at the padded ones. Column
  widths are measured from a bounded head sample, so a much wider field far
  down the file is truncated rather than widening its column. A quoted field
  containing a newline is not joined across rows, since rows are physical
  lines.
