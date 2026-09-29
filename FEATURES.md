# Features (V1, macOS)

✅ implemented and tested · 🟡 implemented, partial · ⏳ planned

## Capture & history
- ✅ Automatic pasteboard monitoring off the main thread; own writes never re-captured
- ✅ All useful representations kept: plain text, RTF, RTFD, HTML, URL, PNG/TIFF/JPEG/HEIC/GIF/WebP, PDF, colors, file URLs (multi-file), web archives, plus small proprietary formats
- ✅ Unlimited retention by default; optional age-based cleanup (never touches pinned or Space clips)
- ✅ Duplicate handling (move to top or keep all), content-hash dedupe of identical blobs
- ✅ Pause / resume monitoring with clear state in panel and menu bar
- ✅ Per-item size cap (default 200 MB, configurable, can be disabled)

## Types & previews
- ✅ Text, Rich Text, Link, Image, Screenshot, File, Folder, PDF, Code (18 languages), Color (hex/rgb/hsl + native), Email, Phone, Address, Credential, One-time code
- ✅ Thumbnails (ImageIO downsampling, PDF first page), cached on disk
- ✅ Syntax-highlighted code, color swatches, file icons, link host/title
- ✅ Quick Look: text, rich text, code, images (+OCR text), PDFs, files (with missing-file detection), colors
- ✅ Versioned background reclassification when rules improve

## Search & filters
- ✅ SQLite FTS5 trigram: substring, case-insensitive, multi-word AND, quoted phrases, ranked
- ✅ Searches text, titles, OCR, file names/paths, URLs, tags, app names and bundle IDs (each toggleable)
- ✅ Filters: type, source app, Space, pinned, date; inline syntax `app: type: in: is:pinned tag: date:`
- ✅ Paged results; tested to 500k records

## Organisation
- ✅ Spaces: create, rename, delete (clips kept), reorder, pin, icon; clips in many Spaces
- ✅ Pinning with manual order; titles (never auto-overwritten); tags
- ✅ Multi-select (⌘-click, ⇧-arrows) bulk actions

## Paste
- ✅ Click / Return / ⌘1–9 paste into the previously active app; plain-text and copy-only variants
- ✅ Paste behaviour preference (paste / copy only / ask); "always plain text"
- ✅ Used clips move to the top (clipboard + history)
- ✅ Accessibility missing → clip copied and explained, never silent
- ✅ Global "paste latest as plain text" shortcut (optional)

## OCR
- ✅ Vision OCR in the background, persisted queue, searchable; "Copy Text from Image"

## Privacy & security
- ✅ Ignored apps (installed-app picker or file chooser), checked before reading
- ✅ Transient/concealed markers, password-manager awareness, sensitive detection with policies incl. Ask banner
- ✅ Encrypted private clips (Keychain key), Touch ID / password lock, idle and sleep relock
- ✅ 0600/0700 file permissions; corrupt database preserved and recovered

## App
- ✅ Menu bar app (Search, Recent Clips, Spaces, Pause, Open, Settings, About, Quit); optional Dock icon
- ✅ Shelf (full-width cards) and floating list layouts; top/bottom docking; screen choice; remembered size
- ✅ Settings: General, Clipboard, History, Spaces, Privacy, Search, Appearance, Keyboard, Storage, Advanced
- ✅ Customisable global shortcuts with conflict reporting
- ✅ Light/Dark/System, compact/comfortable density, reduced motion, VoiceOver labels
- ✅ Storage statistics, thumbnail cache clearing, compaction, index rebuild
- ✅ Export/import `.clipivo` archives (dedupe-safe), automatic local backups
- ✅ Launch at login, welcome/onboarding window
- 🟡 In-panel shortcuts are documented but fixed (only global shortcuts are rebindable)
- ⏳ Drag clips out to other apps; drag clips onto Spaces
- ⏳ URL favicons
