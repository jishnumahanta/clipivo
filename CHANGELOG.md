# Changelog

## 0.9.3 Beta — 2026-09-29

- Click selects a clip, and double-click pastes it into the app you were using (it also becomes your latest clipboard item). Single-click paste is still available in Settings › Clipboard.
- With single-click paste on, a double-click no longer loses the paste: Clipivo swallows the stray second click so it can't move focus out of the text field.

## 0.9.2 Beta — 2026-09-29

- Fixed: double-clicking a clip (especially an image) copied it but didn't paste. With single-click paste on, the second click of a double-click is now ignored, and only one paste runs at a time.

## 0.9.1 Beta — 2026-09-29

- Update checks: "Check for Updates…" in the menu bar menu and **Check Now** in Settings ▸ General. An optional daily check (off by default) shows "Update Available" in the menu when a new version is out.
- Release disk image opens without a Gatekeeper warning (only the app needs "Open Anyway")
- Fixed build warnings on older Xcode versions

## 0.9.0 Beta — 2026-09-29

First public beta.

- Unlimited, searchable clipboard history stored locally (SQLite + full-text search)
- Card shelf and floating list layouts; click or Return to paste into the previous app
- Text, rich text, images, screenshots, PDFs, files, links, colors and code with previews
- On-device OCR: search text inside images, "Copy Text from Image"
- Spaces, pins, titles and tags
- Ignored apps, password-manager awareness, sensitive-content detection, encrypted private clips, Touch ID lock
- Export/import archives and automatic local backups
- Menu bar app with customizable global shortcut
