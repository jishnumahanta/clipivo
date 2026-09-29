# Clipivo Architecture

## Layers

```
Sources/
  ClipivoCore/        Platform-neutral. Foundation + SQLite + CryptoKit only. No UI imports.
    Models/           ClipKind, ClipCategory, ClipSummary, ClipContent, Space, …
    Capture/          ClipboardSnapshot (neutral clipboard state), CaptureProcessor (policy pipeline)
    Classification/   ContentClassifier, CodeDetector, ColorParser
    Security/         SensitiveContentDetector, ContentCipher (AES-GCM)
    Persistence/      SQLiteDatabase wrapper, Schema + migrations, ClipLibrary actor
    Search/           ClipQuery, SearchSyntax (inline filters), SearchPlanner (SQL/FTS5)
    Storage/          StorageLayout, content-addressed BlobStore
    Processing/       BackgroundProcessor (OCR + thumbnails via platform protocols)
    Archive/          Export/import archive format
  ClipivoMacKit/      macOS platform services + UI
    Platform/         ClipboardMonitor, PasteboardIO, PasteService, HotKeyCenter, Vision OCR,
                      ImageIO thumbnails, Keychain, LockService, Preferences, system services
    App/              AppModel (composition root), status item, windows, app delegate
    UI/               Panel (shelf + list), Settings, components, theme
  Clipivo/            main.swift (entry point only)
Tests/
  ClipivoCoreTests/   unit, integration and stress tests for the core
  ClipivoMacKitTests/ real NSPasteboard integration tests (private named pasteboards)
```

Business logic never depends on SwiftUI/AppKit. Platform capabilities the core needs are injected through protocols: `TextRecognizer`, `ThumbnailRenderer`, `ContentCipher`.

## Capture pipeline

```
NSPasteboard ──poll changeCount (utility queue, 0.3 s, with leeway)──▶ ClipboardMonitor
   │ changed?  → CaptureProcessor.shouldRead(bundleID, policy)   ← paused / ignored app: STOP, nothing read
   ▼
PasteboardReader → ClipboardSnapshot (all useful representations + hints: color, image size, folders, PDF pages)
   ▼
CaptureProcessor.prepare (pure, testable)
   transient marker → drop · filter types/sizes · classify · sensitive policy (save / private / ask / discard)
   ▼
ClipLibrary.store (actor) → dedupe by content hash → SQLite row + FTS row + inline/blob payloads
   ▼
BackgroundProcessor (schedule) → thumbnails (ImageIO) → OCR (Vision) → FTS reindex
```

- Clipivo's own pasteboard writes carry a marker type (`app.clipivo.internal`) and bump the monitor's change count, so they are never re-captured.
- The system has no clipboard-change notification; polling an integer counter is the standard and cheap approach.

## Storage format

```
~/Library/Application Support/Clipivo/      (0700)
  Database/clipivo.sqlite (+ -wal, -shm)    (0600) metadata, text, FTS index
  Blobs/ab/cd/<sha256>                      (0600) payloads > 32 KB, content-addressed and deduplicated
  Private/p-<uuid>                          (0600) AES-GCM encrypted payloads of private clips
  Thumbnails/<sha256>.png                   cache, regenerable
  Backups/*.clipivo                          optional local backups
```

Blobs are immutable. Garbage collection deletes blobs no longer referenced by any representation after deletes.

## Database schema (v1)

| Table | Purpose |
|---|---|
| `clips` | one row per clip: uuid, kind, title, auto_title, preview_text (≤2 000 chars), content_hash, source app, created/last-used times, use count, pin state/order, private flag, sensitivity, byte size, thumbnail key, OCR state, url, metadata JSON |
| `clip_text` | full plain text (when not already a representation) and OCR text — kept out of `clips` so list queries never read large overflow pages |
| `representations` | every pasteboard representation: item index, UTI, size, `inline_data` (≤32 KB) or `blob_key`, encrypted flag |
| `spaces`, `clip_spaces` | Spaces and many-to-many membership |
| `clip_tags` | tags |
| `ignored_apps` | per-app exclusions |
| `meta` | key/value (seed flags, classifier and thumbnail versions) |
| `clip_fts` | FTS5 (trigram tokenizer): title, body (first 256 KB), ocr, files, url, app, tags |

Indexes cover the common access paths: recency, content hash, source app, kind, pinned, pending OCR.

### Search

- Terms of ≥3 characters use FTS5 trigram `MATCH` — case-insensitive **substring** matching (`pabas` finds `supabase`), ranked with bm25 column weights (titles and tags weigh most) plus a small recency penalty.
- Shorter terms fall back to `LIKE` on bounded columns (title, auto title, preview).
- Filters (kind, app, Space, pinned, tag, date) are plain SQL predicates combined with AND.
- Inline syntax: `app:`, `type:`, `in:`/`space:`, `is:pinned`, `tag:`, `date:`, `"exact phrase"`.
- Results are paged (80 per page); the UI never holds the full history.

### Migration strategy

- `PRAGMA user_version` stores the schema version; `Schema.migrations` is an append-only array of SQL steps, each applied in a transaction together with the version bump.
- Never edit a shipped migration; add a new one. Data rewrites that need Swift (e.g. re-classification) are versioned in `meta` (`classifier_version`, `thumbnail_pixel_size`) and run in the background at launch.
- An unreadable database is **moved aside** (`damaged-<date>.sqlite`), never deleted, and a fresh one is created; the UI tells the user.

## Performance design

- All database work runs on the `ClipLibrary` actor, never on the main thread. Pasteboard polling and reading happen on a utility queue. OCR and thumbnails run on background executors.
- Search typing is debounced (45 ms) and superseded queries are cancelled; counts are computed after results are displayed.
- Rows/cards are lightweight `ClipSummary` values; thumbnails are pre-rendered files loaded off-main into an `NSCache`.
- Measured (release, Apple Silicon): see CONTRIBUTING.md › Performance baselines.

## macOS UI

- The panel is a non-activating `NSPanel`: it takes keyboard focus while the app you were typing in stays active, so ⌘V lands in the right text field. It uses `.transient`/`.ignoresCycle` (not in Mission Control), floats above normal windows and closes when you click elsewhere.
- Two layouts: **shelf** (full-width cards docked to the bottom or top edge) and **list** (compact floating window). Screen selection: active window's screen, pointer screen, or primary display.
- Settings is a SwiftUI window with ten sections. Menu bar item via `NSStatusItem`; no Dock icon unless enabled.

## Cross-platform plan

The core is the reusable part. Swift runs on Windows, Linux and Android; alternatively the core's schema and archive format are the contract for native ports.

| Concern | macOS (V1) | Windows | iOS / iPadOS | Android |
|---|---|---|---|---|
| Clipboard | `NSPasteboard` polling | `AddClipboardFormatListener` (event-driven) | `UIPasteboard` on explicit user action; Share Extension; keyboard extension; Shortcuts/App Intents | `ClipboardManager` while foreground/IME; share target; custom keyboard (IME) |
| Paste into app | CGEvent ⌘V (Accessibility) | `SendInput` Ctrl+V | keyboard extension inserts text | IME commits text |
| OCR | Vision | Windows.Media.Ocr | Vision | ML Kit |
| Global shortcut | Carbon hot key | `RegisterHotKey` | n/a | n/a |
| Storage | same SQLite schema + blob layout | same | same (app group container) | same |

Representation types are stored as UTIs; ports map native formats (e.g. `CF_UNICODETEXT`, `text/plain`) onto the same identifiers so archives and future sync stay portable.

### Future sync

```
Mac ⇄ encrypted sync ⇄ Windows ⇄ iPhone/iPad ⇄ Android
```

Designed-in prerequisites: stable clip UUIDs, content hashes for dedupe, content-addressed immutable blobs (upload once, fetch lazily), `ContentCipher` abstraction for end-to-end encryption, per-record timestamps. Remaining work: a change log/tombstone table, per-device keys with key wrapping, last-writer-wins for metadata (titles, pins) with set-union for Spaces/tags, and bandwidth-aware lazy blob transfer. The server should only ever see ciphertext.
