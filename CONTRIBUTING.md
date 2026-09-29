# Contributing

Clipivo is proprietary, source-available software (see [LICENSE](LICENSE)). It is not open
source. Bug reports, feature ideas and security reports are always welcome.

## Before you open a pull request

Code contributions are welcome, but they can only be accepted under these terms:

1. **You wrote it, or have the right to submit it**, and it contains no code copied from other
   projects or products (including other clipboard managers) or generated from sources whose
   license you can't pass on.
2. **You keep your copyright**, and you grant Jishnu Mahanta a perpetual, worldwide,
   irrevocable, royalty-free license to use, modify, sublicense and distribute your contribution
   as part of Clipivo, under any license, including proprietary, commercial, dual or
   open-source licenses.
3. **No payment or credit is owed** beyond what the maintainer chooses to give (for example, the
   changelog).

Opening a pull request means you agree to these terms. For large changes, open an issue first so
we can agree on the approach before you spend time on it.

Forks exist only to prepare contributions: please don't publish builds, and don't use the Clipivo
name, logo or artwork in a way that suggests your fork is an official Clipivo release.


## Setup
1. Xcode 16+ (Swift 6 toolchain). If `xcode-select -p` shows the Command Line Tools, export
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the build script does this automatically).
2. `swift build` to compile, `scripts/build-app.sh` to produce `dist/Clipivo.app`.
3. Open `Package.swift` in Xcode for editing/debugging.

## Build configuration

| | |
|---|---|
| Bundle identifier | `in.jishnumahanta.clipivo` (permanent; extensions use `in.jishnumahanta.clipivo.<name>`) |
| Deployment target | macOS 14 |
| Architectures | arm64 and x86_64 (release builds are universal) |
| App Sandbox | Off: pasting into other apps needs Accessibility, which the sandbox doesn't allow |
| Signing | `CODESIGN_IDENTITY` if set, otherwise an installed Apple Development identity, otherwise ad-hoc |
| Permissions | Accessibility (automatic paste), Keychain (private clips only) |

Ad-hoc builds get a new signature on every rebuild, and macOS then forgets the Accessibility permission. Sign with a stable identity to keep it.

## Rules
- `ClipivoCore` must not import AppKit, SwiftUI or any Apple-only UI framework.
- Never log clipboard content. Never add network calls without an explicit, off-by-default setting.
- Database changes = a new entry in `Schema.migrations` (never edit shipped ones) + tests.
- Heavy work (I/O, decoding, OCR) never on the main thread.
- Every regex applied to clipboard text must be linear-time on hostile input; add a case to `ClassifierPerformanceTests`.
- No buttons that do nothing; errors surface to the user via `AppModel.show(_:style:)`.

## Tests
```bash
swift test                                               # all unit + integration tests
swift test --filter ClipivoMacKitTests                   # real NSPasteboard tests (private pasteboards)
CLIPIVO_STRESS=1 swift test -c release --filter Stress   # 100k and 500k record stress runs
```
Test suites: classification, code detection, sensitive content, search syntax, persistence, capture policy, search, Spaces/pins/cleanup, background OCR/thumbnails, archive import/export, stress/memory, pasteboard integration, monitor, preferences.

## Screenshots

README screenshots in `assets/screenshots/` show sample data only — never a real clipboard. The demo mode used to make them was removed after capture; it's in the history at commit `40b8e62` if new screenshots are needed.

## Performance baselines
Recorded by the stress tests (`[stress N]` lines). Budgets enforced by tests: first page / filters / search under 250 ms at 10k (debug), 500 ms at 50k (debug), 600 ms at 100k and 2 s at 500k (release), with resident memory growth under 300 MB.

Release build, Apple Silicon, synthetic data where nearly every clip matches common search terms (worst case):

| Clips | First page | App/type filter | Substring search (dense matches) | Insert (batched) | Memory growth |
|---|---|---|---|---|---|
| 10,000 | 0.2 ms | 0.3 ms | ~10 ms | 0.2 s | +41 MB |
| 100,000 | 0.2 ms | 0.3 ms | ~100 ms | 3.5 s | +142 MB |
| 500,000 | 0.3 ms | 0.3 ms | ~0.55–0.65 s | 35 s | +271 MB |

Real histories are far sparser than this synthetic set, so searches are usually much faster. Known next optimisation: when a term matches a huge share of the history, rank only the most recent N matches instead of bm25 over all of them.

## Release process
1. Bump the version in the `VERSION` file (every build, including local ones, reads it) and add a CHANGELOG entry.
2. `swift test` and the stress suite must pass with no warnings (`swift build 2>&1 | grep warning:` is empty).
3. `scripts/make-release.sh` builds the universal app, signs it with "Clipivo Beta", and writes the DMG, zip and checksums to `dist/release/`.
4. Publish: `gh release create v<version>-beta dist/release/Clipivo-<version>.* --title "Clipivo <version> Beta" --notes-file <notes> --latest`
5. With a paid Developer ID later: sign with `CODESIGN_IDENTITY="Developer ID Application: …"`, then notarize (`xcrun notarytool submit … --wait`) and staple (`xcrun stapler staple`) the app and DMG.
