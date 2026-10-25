# Changelog

## 1.0.0 — 2026-10-25

First release. A native Swift/AppKit PDF viewer written from scratch, on
PDFKit, with no third-party code.

- Opens PDFs from Finder, the Open panel or a drop on the window; protected
  documents ask for their password.
- Native macOS tabs: every document opens as a tab of the front window, with
  the + button to open more.
- Title bar and tabs hidden in the page: they show while the pointer is over
  the top of the window and fade out half a second after it leaves.
- Continuous scrolling fitted to the width, pinch and keyboard zoom, actual
  size, two pages side by side, Go to Page, back and forward after links.
- Find with every match highlighted; text selection and copy.
- Each document reopens at the page it was left at; changes saved by other
  apps show up at the same page.
- Show in Finder, Open in Preview, full screen.
- Light on memory: Live Text only for scanned documents, background tabs
  drop their rendered pages, freed memory goes back to macOS. 41 MB with a
  300-page document open, against 186 MB for Preview.
- Quits when its last window closes. Offers once to become the default PDF
  viewer.
