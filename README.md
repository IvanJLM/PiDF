# PiDF

A minimal, native PDF viewer for Apple Silicon Macs.

PiDF does one thing: it shows PDF documents, quietly, and gets out of the
way. It is written from scratch in Swift and AppKit, with no third-party
code. Pages are drawn by PDFKit, the engine behind Preview; the title bar and
the tabs melt into the page while you read, as the window buttons do in
[Vids](https://github.com/IvanJLM/Vids).

## Why

Same 300-page document open and idle, measured on an M4 Pro Mac with macOS 26
(`./scripts/benchmark.sh --compare`):

| | PiDF 1.0 | Preview | PDF Expert |
|---|---|---|---|
| Memory (Activity Monitor) | 41 MB | 186 MB | 134 MB |
| CPU while idle | 0.0 % | 0.0 % | 1.2 % |
| Wake-ups per second | 0 | 0 | 2.9 |
| App size | 0.7 MB | 7.6 MB | 221 MB |

With a real 58-page manual: 59 MB for PiDF, 169 MB for Preview and for PDF
Expert. Five real documents open as tabs take 94 MB in all.

Most of that difference comes from three choices:

- **No Live Text on documents that have text.** PDFKit runs text recognition
  on every page it shows, which loads the Vision models and doubles the
  memory a window needs. PiDF keeps it for scanned documents only, so their
  text can still be selected and found.
- **Tabs in the background let go of their rendered pages** and keep only
  the document and where you were. Coming back to a tab draws it again, at
  the same page and zoom.
- **Freed memory goes back to macOS** instead of staying reserved for reuse.

PiDF quits when its last window closes, so it uses no memory at all when you
are not reading.

## What it does

- **Opens PDFs** from Finder, the Open panel (⌘O) or by dropping them on a
  window. Protected documents ask for their password.
- **Tabs, native to macOS**: every document opens as a tab of the front
  window. The + button opens more; drag a tab out for its own window, or use
  Window › Merge All Windows to bring them back.
- **The title bar disappears into the page**, tabs included: it shows while
  the pointer is over the top of the window and fades out half a second after
  it leaves. Nothing runs while it is hidden.
- **Continuous scrolling**, with pages fitted to the width of the window.
  ← and → turn a whole page; ↑ and ↓ scroll a little.
  Zoom with a pinch, ⌘+ / ⌘−; ⌘0 shows the actual size, ⌘9 fits the width
  again. Two pages side by side with ⌥⌘2.
- **Find** (⌘F): every match is highlighted; ⌘G and ⇧⌘G (or Return in the
  search field) walk through them. Selected text is what you look for.
- **Select and copy text** (⌘C), follow links, and go back after a link with
  ⌘[.
- **Remembers where you were**: each document reopens at the page you left
  (for the last 200 documents). The page number shows in the title bar.
- **Follows the file**: when another app saves a new version, PiDF shows it
  at the same page.
- **Highlight and notes**, in one yellow and nothing to set up. ⌃H
  highlights the selected text (or removes the highlights under it). ⌃N
  puts a note where the pointer is, in the type of the page's own text,
  at least 1.5 points smaller (⌥Return for a new line); click a note to select it, drag it to move it,
  double-click or ⌃N to edit it, Delete to remove it. Both are
  ordinary PDF annotations, written into the file itself (⌘S, or when the
  tab goes to the background, closes or PiDF quits), so they travel with
  the document and show in Preview or any other viewer.
- **Show in Finder** (⇧⌘R), **Open in Preview** (⇧⌘P) to sign, fill forms
  or print, and **full screen** (⌃⌘F).

There is no other editing, no sidebar, no preferences and no auto-updates.
For those, Open in Preview hands the document over.

## Shortcuts

| Key | Action |
|---|---|
| ⌘O | Open |
| ⌘W | Close the tab |
| ⌘F / ⌘G / ⇧⌘G | Find / next / previous match |
| ⌃H | Highlight the selected text (again: remove it) |
| ⌃N | Add a note where the pointer is (note selected: edit it) |
| Delete | Remove the selected note |
| ⌘S | Save the highlights and notes now |
| ⌘+ / ⌘− | Zoom in / out |
| ⌘0 / ⌘9 | Actual size / fit the width |
| ⌥⌘2 | Two pages |
| ← / → (or ⌥⌘← / ⌥⌘→) | Previous / next page |
| ↑ / ↓ | Scroll a little |
| ⌥⌘↑ / ⌥⌘↓ | First / last page |
| ⌥⌘G | Go to page |
| ⌘[ / ⌘] | Back / forward after a link |
| ⌃⌘F | Full screen (Esc to leave) |
| ⇧⌘R / ⇧⌘P | Show in Finder / open in Preview |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |

## Install

Requirements: an Apple Silicon Mac with macOS 15 or later, Xcode 26 or later,
and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
./scripts/install.sh
```

The script builds a Release copy, installs it in `/Applications` and asks
macOS to make PiDF the default app for PDF documents, in a confirmation
dialog. To skip that step, run `./scripts/install.sh --no-default`.

To install on another Mac, run `./scripts/package.sh`, copy
`dist/PiDF-<version>.zip` over, unzip it into `/Applications` and open PiDF
once: it offers to become the default PDF viewer.

## Development

```bash
./scripts/test.sh                       # unit tests (Debug build)
./scripts/benchmark.sh [doc.pdf] --compare   # memory, CPU, wake-ups; Preview and PDF Expert too
./scripts/tour.sh                       # screenshots of the main states, in build/Tour
./scripts/bump-version.sh minor         # or patch / major, then fill in CHANGELOG.md
swift scripts/make-icon.swift           # redraw the app icon
```

The tests write their own small PDFs with Core Graphics, so the repository
holds no PDF files. Every pull request runs them on GitHub Actions, with a
Release build that fails on any warning. The benchmark skips any app that is already running, so
it never closes your own documents.

## License

MIT. See [LICENSE](LICENSE).
