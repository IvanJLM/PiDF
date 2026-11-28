# PiDF

A minimal native PDF viewer for macOS (Apple Silicon), built on PDFKit.
`README.md` describes the app and its scripts, `CHANGELOG.md` its versions.

- The Xcode project is generated: change `project.yml`, never
  `PiDF.xcodeproj`.
- Build, test, install and package through `scripts/` (see README).

## Tests leave the Mac as they found it

- Nothing a test run creates outside the project folder stays when it ends,
  also when tests fail. A test takes its preferences from
  `Scratch.defaults()` and its folders from `Scratch.folder(self)`, and
  changes a setting of the app itself only after
  `Scratch.restore(setting:after:)` (`Tests/Scratch.swift`): never
  `UserDefaults(suiteName:)` or the temporary folder directly. A script that
  builds or tests starts with `source scripts/tidy.sh` and uses its
  `generate` and `xcbuild` instead of `xcodegen` and `xcodebuild`.
- Check it after changing tests or scripts:
  `./scripts/leftovers.sh ./scripts/test.sh` lists what the run left in
  `~/Library` and in the user's temporary and cache folders, and fails when
  any of it is PiDF's.
- The tests run inside PiDF itself (`com.ivanjlm.pidf`), so
  `UserDefaults.standard` is the real app's settings. Never build or launch
  PiDF under another bundle identifier (as an audit did with
  `com.ivanjlm.pidfaudit`) without removing that identifier's preferences
  and caches afterwards.
