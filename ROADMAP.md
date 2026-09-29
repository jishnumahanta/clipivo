# Roadmap

## V1.x (macOS polish)
- Drag clips out of the panel into other apps, and onto Spaces
- Rebindable in-panel shortcuts
- Favicons for links (optional, cached)
- Snippets/templates with placeholders
- Paste queue ("paste stack") and merge multiple clips
- Developer ID signing, notarization and auto-update (Sparkle-style, self-hosted appcast)
- Optional full-database encryption (SQLCipher) behind the existing storage API

## V2: encrypted sync (opt-in)
- Change log + tombstones; per-device keys; end-to-end encryption via `ContentCipher`
- Content-addressed lazy blob sync (upload once, fetch on demand)
- Conflict rules: last-writer-wins for metadata, set-union for Spaces and tags
- Self-hostable relay; the server stores only ciphertext

## Windows
- Native app (WinUI 3 or Swift on Windows) using `AddClipboardFormatListener`, `RegisterHotKey`, `SendInput`
- Same schema, archive format and representation identifiers

## iOS / iPadOS
- Keyboard extension to insert clips, Share Extension to save, Shortcuts/App Intents, explicit paste button
- No background clipboard monitoring (platform rule); sync brings Mac history to the phone

## Android
- `ClipboardManager` while in foreground or as IME, share target, keyboard (IME) for insertion
- Respect Android 10+ background clipboard restrictions as product behaviour
