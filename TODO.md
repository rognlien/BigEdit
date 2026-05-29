# BigEdit — pre-beta TODO

Outstanding work between today's build and a public beta. Items that are
already done (Finder integration, Open Recent, state restoration, I-beam
cursor) are not listed here.

## Decisions to make first

These ripple into several tasks below — worth pinning down before starting.

- [ ] **Distribution channel.** GitHub Releases (notarized DMG) is the easiest;
      TestFlight via Mac App Store is heavier (needs sandboxing + review);
      direct download from a website is GitHub Releases plus hosting. Affects
      the signing/sandbox/auto-update tasks.
- [ ] **One window or many?** Today BigEdit is one document per process. Decide
      whether `⌘N` opens a new window with a new file (multi-window), or
      whether `⌘O` always replaces the current document (single-window). The
      choice changes how Open Recent and Finder double-click behave when a
      file is already open.

## Distribution blockers — can't ship without these

- [ ] **Apple Developer ID + code signing.** Sign the bundle:
      `codesign --deep --options runtime --sign "Developer ID Application: …" BigEdit.app`.
      Wire this into `make-app.sh` behind a `SIGN_IDENTITY` env var.
- [ ] **Notarization.** `xcrun notarytool submit BigEdit.zip --wait …`,
      then `xcrun stapler staple BigEdit.app`. Without this every tester sees
      a Gatekeeper warning on first open.
- [ ] **Hardened runtime + entitlements.** Required for notarization. The only
      entitlement BigEdit needs is `com.apple.security.files.user-selected.read-write`
      (for `NSOpenPanel` / `NSSavePanel`). Add a `BigEdit.entitlements` plist
      and pass it to `codesign --entitlements`.
- [ ] **Bundle metadata cleanup.** In `make-app.sh`'s Info.plist:
      - Replace the `dev.bigedit.BigEdit` bundle identifier with a real
        reverse-DNS prefix you own.
      - Add `NSHumanReadableCopyright`.
      - Lock in a version-bumping discipline; `CFBundleVersion` must increase
        monotonically.
- [ ] **DMG packaging.** Build a `.dmg` with a background image + Applications
      symlink for drag-install. `create-dmg` (Homebrew) is the easy path.

## Beta polish — testers will notice

- [ ] **Right-click context menu on the viewport.** `NSView.menu(for:)` (or
      override) returning a menu with **Copy** / **Select All** — mirroring
      the Edit menu. ~10 lines in `ViewportView.swift`.
- [ ] **Case-insensitive find.** Add a toggle to the find bar (a small
      ⓘ-style button or `NSSegmentedControl`). When on, `SearchScan` cannot
      use `memmem`'s fast path; either fold both haystack and needle to
      lowercase in a one-shot copy, or do a slower per-byte scan with
      tolower. The latter avoids the multi-GB copy but is slower per byte.
- [ ] **Go to Line (⌘L).** A small modal sheet that asks for a line number
      and scrolls the viewport via `LineIndex.visualRow(forByteOffset:)` —
      or rather a new `LineIndex.visualRow(forDocumentLine:)`. Useful for
      log inspection.
- [ ] **Dock-click reopen.** Implement
      `applicationShouldHandleReopen(_:hasVisibleWindows:)` in `AppDelegate`
      so clicking the Dock icon after the window has been closed brings it
      back (or shows the Open panel).
- [ ] **Cancel `LineIndex` indexing when the file changes.** Today, opening
      file A and then quickly switching to file B leaves A's indexer
      running to completion in the background. `LineIndex` needs a
      `cancel()` like `SearchScan` and `StatisticsScan` already have.
- [ ] **README polish.** The current `README.md` is dev-facing. For a beta
      release it should include:
      - A short paragraph of what BigEdit is and who it's for.
      - Screenshots (open file, search, info pane, JSON/XML/Markdown/YAML
        coloured rows).
      - A 20-second GIF showing scroll on a big file + a Find & Replace.
      - System requirements (macOS 13+).
      - "Known limitations" section pulling honest caveats from this codebase
        (UTF-8 only, stateless highlighters, no VoiceOver, 64 MB copy cap, 1M
        match cap for display, hit-testing assumes monospace ASCII).
      - How to file a bug / where to get binaries.
- [ ] **A handful of unit tests.** The headless modes (`--index`, `--search`,
      `--preview`, `--replace`, `--stats`) are good integration checks; wrap
      them as `XCTest` cases against fixture files committed to the repo, so
      changes that break correctness fail CI. Highlighter outputs are also
      cheap to test (string-in → attribute-runs out).

## Optional / can ship later

- [ ] **Sandboxing.** Required only if you go via the Mac App Store. The
      temp-file-next-to-destination save dance interacts with sandbox file
      access — would need security-scoped URL bookmarks for the destination
      directory.
- [ ] **Universal binary (arm64 + x86_64).** `swift build` is arm64-only on
      Apple silicon by default. Add `--arch arm64 --arch x86_64` (or build
      twice and `lipo` them together). Only matters if you have Intel users.
- [ ] **Sparkle auto-update.** Lovely for a beta cadence, not required for
      first release. Adds a private update feed + an Edit ▸ Check for
      Updates… menu item.
- [ ] **Crash reporting.** Apple already collects crashes; if you want them
      yourself, integrate Sentry/Bugsnag/KSCrash.
- [ ] **VoiceOver / accessibility.** `ViewportView` is a custom-drawn view —
      it exposes nothing to assistive tech today. Real fix: implement
      `NSAccessibilityStaticText` (or similar) and expose visible row text
      via `accessibilityValue`. Substantial work; honest beta should
      acknowledge it as a known limitation in the meantime.
- [ ] **Word-width hit testing.** Today the viewport approximates click→byte
      using `characterWidth` (monospaced ASCII assumption). Non-ASCII text
      can select a few bytes off the click point. Fix:
      `CTLineGetStringIndexForPosition` on the row's attributed string.
- [ ] **Better long-line handling.** Long lines wrap at a fixed 1024-byte
      column. Window-width soft-wrap would be nicer for minified JSON
      viewing but means recomputing chunk counts when the window resizes.
- [ ] **Stage 2 of the lazy editor.** Positional / hand-typed edits via a
      piece-table layer, undo stack, composition with the existing rule.
      Separate effort, not a beta blocker.
- [ ] **Cursor refinement.** Today the I-beam covers the whole viewport
      including the gutter. Switch to default cursor over the gutter strip.
- [ ] **Carry lexer state across rows.** Stateless highlighters miss
      multi-row constructs (fenced code blocks in Markdown, multi-line
      comments in XML, block scalars in YAML). Fix: cache per-row "exit
      state" alongside line offsets in `LineIndex` and pass start state to
      the highlighter.

## Verification scripts to keep around

These already exist as headless modes and are the cheapest way to sanity-check
correctness; preserve them and turn them into the basis of the test suite.

- `swift run BigEdit --index <path>` — line/row count vs `wc -l`.
- `swift run BigEdit --search <pattern> <path>` — match count vs `grep -oa`.
- `swift run BigEdit --stats <path>` — words/chars vs `wc -lwm`.
- `swift run BigEdit --preview <pattern> <replacement> <path>` — first rows
  with deferred edit vs `sed`.
- `swift run BigEdit --replace <pattern> <replacement> <in> <out>` — full
  edited file vs `sed 's/pattern/replacement/g'`.
