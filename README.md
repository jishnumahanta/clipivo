# Clipivo

**Your clipboard remembers.** Clipivo is a native macOS clipboard manager that keeps everything you copy — text, rich text, images, screenshots, PDFs, links, colors, code and files — searchable forever, entirely on your Mac.

- Unlimited history by default. No 50/500/1,000-item caps, no 30-day expiry. The only limit is disk space.
- Instant panel (default **⇧⌘V**) as a full-width card shelf or a compact floating list.
- Click (or press Return) to paste straight into the app you were typing in; the clip also becomes your newest clipboard item.
- Fast full-text search (SQLite FTS5, substring, multi-word, ranked) across text, titles, OCR'd image text, file names, URLs, tags and source apps, plus filters (`app:chrome type:image in:work date:week`).
- Spaces, pinning, titles and tags for organisation.
- On-device OCR (Apple Vision), thumbnails, Quick Look previews, syntax-highlighted code, color swatches.
- Privacy first: ignored apps, password-manager awareness, heuristic secret detection (Always / Never / Ask / Save privately), encrypted private clips, Touch ID lock. No account, no network, no analytics.
- Export/import archives and local backups.

## Requirements

- macOS 14 Sonoma or later (Apple Silicon first-class; Intel supported with `UNIVERSAL=1`).
- Xcode 16+ (Swift 6 toolchain) to build.

## Build & run

```bash
scripts/build-app.sh          # → dist/Clipivo.app (release, signed)
open dist/Clipivo.app
```

Options: `CONFIG=debug`, `UNIVERSAL=1`, `VERSION=1.2.0`, `CODESIGN_IDENTITY="Developer ID Application: …"`.

If `xcode-select` points at the Command Line Tools, the script uses `/Applications/Xcode.app` automatically. You can also open `Package.swift` in Xcode to edit and debug (`Clipivo` scheme).

### Tests

```bash
swift test                                         # unit + integration tests (~100)
CLIPIVO_STRESS=1 swift test -c release --filter Stress   # 100k / 500k record stress tests
```

## Permissions

| Permission | Why | Required? |
|---|---|---|
| **Accessibility** | To send ⌘V to the app you were using (automatic paste). | Only for automatic paste. Without it Clipivo copies the clip and explains how to enable it — it never fails silently. |
| Keychain item | Stores the key that encrypts private clips. | Created automatically. |

Clipivo does **not** need Screen Recording, Full Disk Access, Contacts, network access or Apple Events.

> **Development note:** ad-hoc–signed builds get a new signature on every rebuild, and macOS then forgets the Accessibility grant. Sign with a stable identity (the build script automatically uses an "Apple Development" certificate if you have one — create a free one in Xcode ▸ Settings ▸ Accounts) to keep the grant.

## Using Clipivo

| Action | Keys |
|---|---|
| Open / close panel | ⇧⌘V (configurable) |
| Move selection | ← → ↑ ↓ (⇧ extends selection) |
| Paste | Click, Return, or ⌘1…⌘9 |
| Paste as plain text | ⇧-click or ⇧Return |
| Copy without pasting | ⌥-click, ⌥Return or ⌘C |
| Quick Look | Space (when search is empty) or ⌘Y |
| Pin / title / tags | ⌘P / ⌘R / ⌘T |
| New Space from selection | ⌘N |
| Delete | ⌫ (search empty) or ⌘⌫ |
| Cycle type filter / Space | ⇥ / ⌘[ ⌘] |
| Close | Esc (first clears search) |

Right-click any clip for type-specific actions (Copy Text from Image, Open Link, Reveal in Finder, Copy Color As…, Export, Mark as Private, Delete Similar, Never Save from this App…).

## License

Copyright © 2026 Jishnu Mahanta. All rights reserved. Designed and built by [Jishnu Mahanta](https://jishnumahanta.in/go/clipivo).

Clipivo is **proprietary, source-available software**, not open source. The source is public so
you can inspect how Clipivo handles your clipboard. You may view it, fork it on GitHub, and build
it privately to evaluate it or prepare a contribution. Copying, redistributing, modifying or
reusing it requires permission. Forking on GitHub does not grant the right to
redistribute, publish, commercialize, sublicense or distribute modified builds. See [LICENSE](LICENSE) for the exact terms.

- **Commercial reuse** of any part of Clipivo requires written permission.
- **The Clipivo name, logo and artwork/branding are not licensed**, under any terms.
- **Forks must not present themselves as official Clipivo releases.** Official builds are published
  only by Jishnu Mahanta.

Licensing questions: jishnumahanta17@gmail.com

## Documentation

- [INSTALL.md](INSTALL.md) — installing the beta (first launch, Accessibility) and signing releases for free
- [CHANGELOG.md](CHANGELOG.md) — release notes

- [ARCHITECTURE.md](ARCHITECTURE.md) — layers, data flow, storage format, schema, migrations, cross-platform plan
- [FEATURES.md](FEATURES.md) — feature inventory and status
- [SECURITY.md](SECURITY.md) — privacy and threat model
- [ROADMAP.md](ROADMAP.md) — what's next, including Windows/iOS/Android and sync
- [LICENSE](LICENSE) — proprietary source-available terms
- [CONTRIBUTING.md](CONTRIBUTING.md) — contribution terms, development workflow, testing, release process
