---
title: BigEdit
tagline: A native macOS viewer for very large text, JSON, XML, YAML and Markdown files — many gigabytes, opened instantly.
description: BigEdit is a native macOS viewer for very large text, JSON, XML, YAML and Markdown files — many gigabytes. Memory and CPU scale with the viewport, never the file.
icon: appicon.png
download:
  file: BigEdit-{{VERSION}}.dmg
  label: Download BigEdit {{VERSION}}
requirements: macOS 13 or later, Apple Silicon. Signed and notarized. No telemetry.
version: "{{VERSION}}"
notice: "**BigEdit is in beta.** It might ruin your day, eat your files, or worse. Use at your own risk."
features:
  - title: Opens instantly
    text: Memory-mapped access and a sparse background line index — the window opens immediately, even on a 50 GB file.
  - title: Fast search
    text: Background literal search across the whole file with live progress, case-sensitive or not. Jump between matches as they stream in.
  - title: Syntax highlighting
    text: Automatic colouring for JSON, XML, Markdown and YAML, picked from the extension or the file’s first bytes.
  - title: Find & replace
    text: A deferred find-and-replace rule previews live in the viewport and writes to disk with a streaming, atomic save.
  - title: Multiple documents
    text: Open many files at once and switch between them from a sidebar — each keeps its own scroll position and search.
  - title: Built for big
    text: Go to line, word/character stats, soft-wrap for minified one-line JSON, and a copy that matches exactly what you see.
---
