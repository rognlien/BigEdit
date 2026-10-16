# BigEdit

A native macOS editor for very large text files — logs, JSON, XML, YAML,
CSV, SQL dumps and Markdown, many gigabytes each. Built with Swift and
AppKit.

BigEdit is for the files other editors refuse or choke on: a 20 GB log to
search, a one-line minified JSON export to read, a database dump to fix one
row of, a CSV too large for a spreadsheet. A 50 GB file opens as fast as a
50 KB one, because **memory and CPU scale with what is on screen and with
your edits, never with the file.** The file stays memory-mapped read-only,
edits live beside it, and the whole file is only written out — streaming and
atomically — when you save.

> **BigEdit is in beta.** It is used daily on real files, but keep a copy of
> anything you cannot afford to lose.

## Getting BigEdit

Download the signed and notarized DMG from
[maendeleo.io/bigedit](https://maendeleo.io/bigedit), or from the
repository's Releases page. BigEdit updates itself (Sparkle); updates can be
turned off in Settings.

**Requirements:** macOS 13 Ventura or later, on Apple silicon. The Apple
Intelligence items need macOS 26 with Apple Intelligence turned on; without
them everything else works the same.

## What it does

### Opening and reading

- **Opens instantly.** The window appears at once while lines are indexed in
  the background; scrolling, Go to Line (**⌘L**) and the line count work as
  soon as they reach the part you are looking at.
- **Long lines wrap to the window**, so a one-line minified JSON file becomes
  rows you can scroll, select and search.
- **Syntax colouring** for JSON, XML, Markdown, YAML, SQL and shell scripts,
  chosen from the file's name or its first bytes. **View ▸ Syntax Coloring**,
  or the language name at the right of the status bar, picks another.
- **Many documents in one window**, listed in a sidebar. The open documents,
  their scroll positions and the window are restored at the next launch, and
  each file remembers how it was shown — Text, CSV or Markdown, its CSV
  options and column widths, and a chosen language.
- **Follow File (⇧⌘T)** — like `tail -f`: bytes appended on disk appear as
  they arrive, and the view stays at the end if it was there.
- **Encodings:** UTF-8, and Windows-1252 / Latin-1 for files that are not
  valid UTF-8. Both can be edited and are saved in their own encoding; File ▸
  Convert to UTF-8… converts one. CRLF line endings are kept.
- Files in iCloud Drive that are not downloaded yet are fetched before they
  open.

### Editing

- **Click and type.** Undo and redo (**⌘Z** / **⇧⌘Z**) reach back across a
  save. **⌘S** saves atomically through a temporary file, with a progress
  sheet for large files.
- **Crash recovery.** Unsaved edits are written to a journal as you make
  them. If BigEdit crashes or is force-quit, opening the file again offers to
  recover them — and if the file changed on disk in the meantime, BigEdit
  says so rather than applying the edits in the wrong places.
- **Column selection** with Option-drag: copy, cut, delete or type into a
  rectangular block.
- **Edit ▸ Process Lines (⇧⌘L):** remove duplicates, keep or remove lines
  containing text, sort (plain, natural, or by a regular-expression key),
  replace within each line, and set operations against another document or
  file — remove the lines in another list, keep only those in it, add what
  it has, or keep what is in only one. Lines can be matched trimmed, ignoring
  case, or by a regular expression, so two CSV exports can be intersected on
  one column.
- **Edit ▸ Compare Documents (⇧⌘D):** two documents as sets of lines (only
  in the first, only in the second, in both) and as a unified diff that
  `patch` reads.

### Finding and replacing

- **⌘F** finds, **⌥⌘F** finds and replaces, **⌘G** / **⇧⌘G** move between
  matches. The magnifier menu in the search field holds Match Case, Regular
  Expression, Dot Matches Newline and a regular-expression reference card.
- **Search runs in the background** with live progress, so a search through
  many gigabytes never freezes the window.
- **⌥⌘L** lists every match with its line number and a snippet; click one to
  jump to it.
- **Regular expressions, as you type:** a pattern that does not compile is
  explained before you press Enter, and in replace mode the second row shows
  what `$1` expands to for the current match.
- **Replace All** has no match limit: when there are too many matches to
  apply as one undoable edit, BigEdit offers to stream the result to the file
  or to a new one.
- **Saved Patterns:** save a pattern, its replacement and options under a
  name, and pick it again from the find bar, the Find menu or Process Lines.
  They can be kept in iCloud Drive.
- **Apple Intelligence:** Describe a Pattern… turns a sentence and a few
  sample lines into a regular expression you can check before it runs, and
  Explain This Pattern does the reverse. The on-device model sees the pattern
  and at most a dozen lines, never the document, and nothing leaves the Mac.

### CSV and other delimited data

Choose **CSV** in the selector at the top right to see a file as aligned
columns on a grid. Comma, semicolon, tab and pipe are detected; any other
delimiter can be chosen, along with the quote character, the header row,
pinning the header while scrolling, and trimming spaces.

- Typing goes into the cell under the caret. **Tab** / **Shift-Tab** move
  between cells, Tab past the last column adds one, and **Return** moves down
  a row like Numbers. **Option-Tab** types a tab.
- Edits respect cells: typing a delimiter or a quote quotes the cell, and
  Delete stops at a cell's edge instead of merging it with the next. Deleting
  a selection across cells clears them and keeps the table's shape.
- **Click a header** to sort by that column (naturally, so `9` comes before
  `10`), again for descending; right-click a cell for the same. A sort is one
  undoable edit.
- **Drag a column's edge** to resize it; double-click the edge to fit it to
  its content.

### Markdown

The **Markdown** side of the selector shows a `.md` file of up to 16 MB
rendered the way GitHub does — tables, task lists, strikethrough, autolinks
and footnotes — unsaved edits included. Raw HTML is left out and the page
runs no scripts; links open in your browser.

### Settings (⌘,)

Appearance (System, Light or Dark), the editor font and size (**⌘+** /
**⌘−** / **⌘0**), whether rendered Markdown loads pictures from the web, and
automatic update checks.

## The `bigedit` command

BigEdit ships a `bigedit` command inside the app. Install it from
**BigEdit ▸ Install Command Line Tool…**, which links it into
`/usr/local/bin`.

```sh
bigedit notes.txt          # open it, creating the file if it does not exist
bigedit a.csv b.json       # open several at once
bigedit                    # bring BigEdit to the front
bigedit --help
```

It is a link rather than a copy, so updating BigEdit updates the command.
Files go to the BigEdit that is already running.

`/usr/local/bin` belongs to root, so the first install asks for permission
through a small privileged helper — the supported way for an app to do
privileged work — and the system's dialog accepts **Touch ID** as well as a
password. You are asked once. The helper does one thing (link this tool into
one of a fixed list of directories), runs no shell, and only accepts
connections from BigEdit itself.

## Limitations

BigEdit keeps its costs tied to the screen, and a few things follow from
that. Below 4 MB a document is handled whole and most of these bounds do not
apply.

- **VoiceOver** cannot read the document yet: the text view is drawn by
  BigEdit itself and does not expose its text to assistive technologies.
- **Syntax colouring** of a large document is exact as you scroll down from
  the top. After a jump far down, a comment or string opened more than about
  400 rows above the view is not seen until you scroll nearer.
- **Search** in a document over 4 MB collects the first 1,000,000 matches
  (shown as `1,000,000+`) and lists the first 100,000. A single
  regular-expression match cannot span more than about 4 MB of lines.
- **CSV:** rows are lines, so a quoted field that contains a line break is
  shown across two rows. Column widths of a file over 4 MB are measured from
  its first megabyte, so a much wider field further down is cut short until
  that row is edited. Sorting, like Process Lines, holds every line in memory
  and is limited to 32 MB.
- **Windows-1252 and Latin-1:** a character those encodings cannot hold is
  refused rather than typed (BigEdit offers to convert the file to UTF-8).
  Process Lines and CSV sorting need UTF-8. The encoding is detected from the
  first 64 KB, so a file whose first 64 KB are plain ASCII opens as UTF-8.
  UTF-16 and binary files are labelled but not decoded.
- **Compare Documents** holds both lists in memory, up to 256 MB each.
- **Follow File** follows only a document without unsaved edits.
- **Crash recovery** cannot apply the edits once the file has changed on
  disk; restoring the earlier version makes them recoverable again.

## Reporting a bug

Open an issue on the repository's GitHub Issues page, with:

- the BigEdit version (BigEdit ▸ About BigEdit) and the macOS version,
- the size and kind of file, and its encoding and line endings from the
  status bar,
- what you did, what you expected, and what happened instead,
- for a crash, the report from `~/Library/Logs/DiagnosticReports` whose name
  starts with `BigEdit`.

Please do not attach files containing anything private; a few lines that show
the problem are usually enough.

## Building from source

```sh
./make-app.sh && open BigEdit.app   # build a standalone app and launch it
swift test                          # the unit tests
```

The package opens directly in Xcode (File ▸ Open… the `BigEdit` folder).
`swift run BigEdit` works too, but that process dies with its shell — use the
app bundle for anything longer than a quick check.

Headless modes check the engine without the window, against standard tools:

```sh
swift run -c release BigEdit --index <path>              # vs wc -l
swift run -c release BigEdit --search <pattern> <path>   # vs grep -o
swift run -c release BigEdit --search-regex <pattern> <path>
swift run -c release BigEdit --stats <path>              # vs wc -lwm
swift run -c release BigEdit --dump <path> [rows]        # rows as shown
swift run -c release BigEdit --csv <path> [rows]
```

The `scripts/verify-*.sh` scripts cross-check editing, CSV, encodings,
Process Lines and regular expressions against Python, `iconv`, `awk`, `grep`,
`sort`, `sed` and `perl`. [SUMMARY.md](SUMMARY.md) describes the
architecture, and [docs/RELEASING.md](docs/RELEASING.md) the release process.

## License

MIT — see [LICENSE](LICENSE). BigEdit ships
[Sparkle](https://github.com/sparkle-project/Sparkle) for updates, which is
MIT-licensed as well, and renders Markdown with
[cmark-gfm](https://github.com/swiftlang/swift-cmark), which is BSD-licensed.
