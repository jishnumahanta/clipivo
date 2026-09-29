<!--
  Links used on this page. Replace the placeholder website URL before the public launch:
    Website  (PLACEHOLDER)  https://example.com/clipivo
    GitHub                  https://github.com/jishnumahanta/clipivo
    Releases                https://github.com/jishnumahanta/clipivo/releases
-->

<div align="center">

<img src="Resources/AppIcon.png" width="128" height="128" alt="Clipivo app icon">

# Clipivo

### Your clipboard remembers.

A native macOS clipboard manager that keeps everything you copy searchable, organized and private — on your Mac.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#architecture)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-0A84FF)](#architecture)
[![License: source available](https://img.shields.io/badge/license-source%20available-5B5BF0)](LICENSE)
[![Status: beta](https://img.shields.io/badge/status-beta-D97706)](#project-status)

**[Download from GitHub Releases](https://github.com/jishnumahanta/clipivo/releases)** &nbsp;·&nbsp;
[Website](https://example.com/clipivo) &nbsp;·&nbsp;
[Source on GitHub](https://github.com/jishnumahanta/clipivo)

</div>

<br>

<p align="center">
  <img src="assets/screenshots/shelf-light.png" alt="Clipivo's card shelf in light mode: recent clips shown as cards for text, a link, Swift code, a color, an email address and a screenshot">
</p>
<p align="center"><sub>The card shelf — every recent copy one click away. Shown with sample data.</sub></p>

<p align="center">
  <img src="assets/screenshots/shelf-dark.png" alt="Clipivo's card shelf in dark mode">
</p>
<p align="center"><sub>The same shelf in dark mode.</sub></p>

---

## Why Clipivo

You copy something useful. Then something else. Then something else again.
The first thing is gone.

**Clipivo remembers it** — the text, the link, the screenshot, the color, the file — and finds it again in a keystroke, months later.

## Features

<table>
<tr>
<td width="50%" valign="top">

**Clipboard history**
- Keeps text, rich text, links, images, screenshots, PDFs, files, folders, colors and code
- Recognises emails, phone numbers, addresses, one-time codes and likely secrets
- No item-count cap and no automatic expiry
- Duplicates move to the top instead of piling up

</td>
<td width="50%" valign="top">

**Search**
- Instant, ranked local search as you type
- Searches content, titles, text inside images, file names, links, tags and source apps
- Filters by type, app, Space and date
- Search syntax: `app:safari type:image in:work date:week`

</td>
</tr>
<tr>
<td valign="top">

**Organization**
- Spaces to group clips by project or context
- Pins for the clips you reuse
- Custom titles and tags
- A Spaces sidebar with live counts

</td>
<td valign="top">

**Privacy**
- Stored locally; no account, no analytics
- Ignored apps are never read
- Password-manager and secret detection with per-type policies
- Encrypted private clips and an optional Touch ID lock

</td>
</tr>
<tr>
<td valign="top">

**Pasting**
- One click pastes into the app you were using
- Paste as plain text, or copy without pasting
- ⌘1–⌘9 for the first nine clips
- Quick Look previews with Space

</td>
<td valign="top">

**A real Mac app**
- Menu bar app with a global shortcut (⇧⌘V)
- Card shelf or floating list layout
- Light, dark and system appearance
- Opens on the display you're working on

</td>
</tr>
</table>

## Remember everything you copy

Clipivo does not impose an arbitrary clipboard item count or automatic expiration period. History is limited by available local storage and any cleanup policy you explicitly choose — for example removing clips you haven't used in a year, or only old screenshots. Pinned clips and clips in Spaces are never cleaned up automatically.

Every useful format of a copy is kept, so a clip pastes back the way it came in: rich text stays rich, images keep full resolution, and files paste as files.

## Find it again

Start typing and results appear instantly, best matches first. Clipivo searches everything it knows about a clip — its content, your title, text recognised in images, file names and paths, link addresses, tags and the app you copied it from. Filters narrow it down further, and you can type them straight into the search field.

## Search inside screenshots

<p align="center">
  <img src="assets/screenshots/search-ocr.png" width="780" alt="Searching for “weekly review” finds a screenshot that contains those words">
</p>
<p align="center"><sub>Searching “weekly review” finds the screenshot containing those words.</sub></p>

Text in copied images and screenshots is recognised on your Mac with Apple's Vision framework, in the background. Images are never uploaded. You can turn recognition off, or exclude recognised text from search.

## Organize with Spaces

Spaces group clips by context — a project, a client, a trip. A clip can belong to several Spaces, and clips in Spaces are kept even when cleanup is on. Create a Space from a selection with ⌘N and switch between Spaces with ⌘[ and ⌘].

## Keep sensitive apps out

Add apps to the ignore list and Clipivo won't read the clipboard at all while you copy from them — nothing is stored, previewed or recognised. Content that password managers mark as concealed is discarded by default. Clipivo also looks for likely secrets such as private keys, API tokens, card numbers and one-time codes, and lets you choose for each kind: **Always save**, **Save as private**, **Ask** or **Never save**.

## Paste the way you want

| Do this | To |
|---|---|
| Click, Return or ⌘1–⌘9 | Paste into the app you were using; the clip also becomes your newest clipboard item |
| ⇧-click or ⇧Return | Paste as plain text |
| ⌥-click, ⌥Return or ⌘C | Copy without pasting |

## How it works

```
Copy  →  Clipivo captures every useful format  →  stores it on your Mac
      →  indexes it for search  →  recognises text in images, detects the content type
      →  you search  →  one click pastes it back
```

Clipivo checks the clipboard a few times a second. Before reading anything it checks whether monitoring is paused or the app you copied from is ignored — if so, the clipboard is left untouched.

## Private by default

- **Local storage.** Your history lives in `~/Library/Application Support/Clipivo`, readable only by your user account. There is no account and no Clipivo server.
- **On-device text recognition.** OCR runs locally with Apple Vision.
- **No telemetry.** No analytics or tracking, and clipboard contents are never written to logs.
- **Network only if you ask.** The one optional network feature, *Fetch page titles for copied links*, is off by default and only contacts the copied link's own site.
- **Private clips** are encrypted with AES-256-GCM; the key is kept in your login Keychain on this Mac, created the first time you make a private clip.
- **App lock.** Optionally require Touch ID or your password to open Clipivo.

The history database itself isn't encrypted — only private clips are — so FileVault is recommended. [SECURITY.md](SECURITY.md) has the full threat model.

## Visual tour

<table>
<tr>
<td width="50%" align="center"><img src="assets/screenshots/list-light.png" alt="Floating list layout in light mode"><br><sub>Floating list, light</sub></td>
<td width="50%" align="center"><img src="assets/screenshots/list-dark.png" alt="Floating list layout in dark mode"><br><sub>Floating list, dark</sub></td>
</tr>
</table>

<p align="center">
  <img src="assets/screenshots/quick-look.png" alt="Quick Look previewing a screenshot clip at full size, with its recognised text and a Copy Text button">
</p>
<p align="center"><sub>Quick Look — a full-size preview, with the text Clipivo recognised in the image.</sub></p>

<p align="center">
  <img src="assets/screenshots/settings-privacy.png" width="760" alt="Privacy settings: ignored applications, sensitive-content policies and the option to respect temporary clipboard content">
</p>
<p align="center"><sub>Privacy settings — ignored apps and what happens to sensitive content.</sub></p>

<p align="center"><sub>All screenshots show sample data from Clipivo's demo mode.</sub></p>

<!-- TODO before launch: add assets/screenshots/menu-bar.png (see CONTRIBUTING.md › Screenshots and demo mode). -->

## Installation

> [!NOTE]
> Clipivo is in beta. Builds will be published on [GitHub Releases](https://github.com/jishnumahanta/clipivo/releases).

1. Open the latest release and download `Clipivo-<version>.zip`.
2. Unzip it and move **Clipivo** to your **Applications** folder.
3. Open Clipivo. Beta builds aren't notarized by Apple yet, so the first time macOS will block it — open **System Settings › Privacy & Security** and click **Open Anyway**.
4. When asked, allow **Accessibility** so Clipivo can paste for you.
5. Press **⇧⌘V** to open your clipboard.

[INSTALL.md](INSTALL.md) has step-by-step details, including updating and uninstalling.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel (release builds are universal)

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⇧⌘V | Open or close Clipivo (configurable) |
| ← → ↑ ↓ | Move the selection (⇧ extends it) |
| Return · click · ⌘1–⌘9 | Paste |
| ⇧Return | Paste as plain text |
| ⌥Return · ⌘C | Copy without pasting |
| Space · ⌘Y | Quick Look |
| ⌘P · ⌘R · ⌘T | Pin · rename · tag |
| ⌘N | New Space from the selection |
| ⌫ · ⌘⌫ | Delete |
| ⇥ · ⌘[ ⌘] | Cycle the type filter · switch Space |
| Esc | Clear the search, then close |

A second global shortcut, *Paste latest clip as plain text*, can be set in Settings. Right-click any clip for more: copy text from an image, open a link, reveal a file in Finder, copy a color in another format, delete similar clips, or never save from that app.

## Menu bar

Clipivo lives in the menu bar. Clicking its icon shows the menu or opens the clipboard — your choice. The menu gives quick access to search, history, pinned clips, Spaces, pausing and resuming capture, and Settings, and the icon changes to show when capture is paused. The icon can be the full-color logo or a monochrome version, and you can also show a Dock icon.

## Settings

| Section | What you can change |
|---|---|
| General | Launch at login, Dock icon, menu bar icon style and click behaviour |
| Clipboard | Monitoring, single-click paste, plain-text pasting, duplicates, which formats to keep |
| History | Optional age-based cleanup (off by default), manual cleanup |
| Spaces | Create, rename, reorder, pin and choose icons for Spaces |
| Privacy | Ignored apps, policies for password managers, secrets and one-time codes, Touch ID lock |
| Search | What search covers, text recognition, link titles |
| Appearance | Theme, density, sidebar, card shelf or floating list, which display to use |
| Keyboard | Global shortcuts and in-panel behaviour |
| Storage | Usage, maintenance, export and import, automatic backups |
| Advanced | Clipboard check interval, largest item size, reset |

## Storage

Clipivo stores each clip's details and searchable text in a local database, and keeps larger content — images, PDFs, files — as separate files, stored once even if you copy the same thing many times. Thumbnails and recognised text are generated in the background, so the panel stays fast however large your history grows.

**For developers:** SQLite in WAL mode with an FTS5 trigram index for substring search, plus a content-addressed (SHA-256) blob store. Schema changes use append-only migrations. Library directories are `0700` and files `0600`. Exports use a documented `.clipivo` archive format. See [ARCHITECTURE.md](ARCHITECTURE.md).

## Architecture

**Stack:** Swift 6 toolchain (Swift 5 language mode) · SwiftUI and AppKit · SQLite with FTS5 · Apple Vision · CryptoKit · LocalAuthentication · Swift Concurrency. No third-party dependencies.

```
Clipivo (app)          launch and composition
   │
ClipivoMacKit          SwiftUI/AppKit interface, clipboard monitoring, pasting,
   │                   global shortcuts, OCR, Keychain, Touch ID
   │
ClipivoCore            platform-neutral: models, capture pipeline, classification,
                       sensitive-content detection, search, SQLite storage, archives
```

`ClipivoCore` imports only Foundation, SQLite and CryptoKit, so it can be reused by future Windows, iOS and Android versions. The library is an actor, results are paged, and the interface never loads the whole history into memory.

## Development

```bash
git clone https://github.com/jishnumahanta/clipivo.git
cd clipivo
scripts/build-app.sh        # builds and signs dist/Clipivo.app
open dist/Clipivo.app
```

You need Xcode 16 or later. To edit and debug, open `Package.swift` in Xcode and run the **Clipivo** scheme.

| Command | Does |
|---|---|
| `swift test` | Runs the unit and integration tests |
| `CLIPIVO_STRESS=1 swift test -c release --filter Stress` | Stress tests with 100,000 and 500,000 clips |
| `scripts/build-app.sh` | Builds the app; options `CONFIG=debug`, `UNIVERSAL=1`, `VERSION=x.y.z`, `CODESIGN_IDENTITY=…` |
| `VERSION=x.y.z scripts/make-release.sh` | Builds a universal release zip and its SHA-256 checksum in `dist/release/` |

If `xcode-select` points at the Command Line Tools, the scripts use `/Applications/Xcode.app` automatically. [CONTRIBUTING.md](CONTRIBUTING.md) covers coding rules, tests and measured performance.

## Build configuration

| | |
|---|---|
| Bundle identifier | `in.jishnumahanta.clipivo` (permanent) |
| Deployment target | macOS 14 |
| Architectures | arm64 and x86_64 (universal release builds) |
| App Sandbox | Off — pasting into other apps needs Accessibility, which the sandbox doesn't allow |
| Signing | Uses an Apple Development identity if one is installed, otherwise ad-hoc. Public builds are meant to be signed with Developer ID and notarized. |

Ad-hoc builds get a new signature on every rebuild, and macOS then forgets the Accessibility permission — remove and re-add Clipivo in System Settings after rebuilding, or sign with a stable identity.

## Permissions

| Permission | Why | Needed? |
|---|---|---|
| **Accessibility** | To press ⌘V in the app you were using, so a clip pastes where your cursor is. Clipivo doesn't read other apps' windows. | Only for automatic pasting. Without it, choosing a clip copies it and you paste yourself. |
| **Keychain** | Holds the key that encrypts private clips. | Only if you use private clips. |

Reading the clipboard needs no permission on macOS. Clipivo doesn't need Screen Recording, Full Disk Access, Contacts or Apple Events.

## Project status

**Beta (0.9).** The macOS app is feature-complete for its first release and in testing.

| Available now | Planned |
|---|---|
| Everything described above, on macOS | Developer ID signing, notarization and automatic updates |
| | Drag clips into other apps, snippets, a paste queue |
| | Optional full-database encryption |
| | Windows, iOS / iPadOS and Android versions |
| | Opt-in, end-to-end encrypted sync |

## Roadmap

| | Status |
|---|---|
| macOS | Current priority — in beta |
| Windows | Planned |
| iOS / iPadOS | Planned |
| Android | Planned |
| End-to-end encrypted sync | Planned |

These are plans, not dates. Clipivo's core is platform-neutral by design — the same data model, search and archive format are meant to power future Windows, iOS and Android versions, with optional sync where any server only ever sees encrypted data. Nothing here exists yet; [ROADMAP.md](ROADMAP.md) has the details.

## Website

Official website: [example.com/clipivo](https://example.com/clipivo) <!-- PLACEHOLDER: replace before the public launch -->

## Releases

Official builds are published only on [GitHub Releases](https://github.com/jishnumahanta/clipivo/releases). No release has been published yet.

## Contributing

Bug reports and ideas are welcome in Issues. Code contributions are welcome subject to the terms in [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Please report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md) — not in a public issue.

## License

Copyright © 2026 Jishnu Mahanta. All rights reserved.

Clipivo is **source available, not open source**. You may view the source, fork it on GitHub, and build it privately to evaluate it, review its security or prepare a contribution. Forking does not grant the right to redistribute, publish, commercialize, sublicense or distribute builds, modified or not. Redistribution and commercial reuse require written permission. See [LICENSE](LICENSE) for the exact terms.

**Brand.** Clipivo, the Clipivo name, logo, icons, artwork and visual identity are not licensed under the source-code license. Forks must not present themselves as official Clipivo releases.

## Acknowledgements

Clipivo is built entirely on Apple's frameworks and SQLite (public domain), with no third-party packages. It respects the community [nspasteboard.org](http://nspasteboard.org) conventions for concealed and transient clipboard content.

## About

Clipivo is being built to make clipboard history feel less like a temporary buffer and more like a permanent memory for your Mac.

Designed and built by [Jishnu Mahanta](https://jishnumahanta.in/go/clipivo).
