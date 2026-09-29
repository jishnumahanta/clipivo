import Foundation

/// Database schema and forward-only migrations.
///
/// Rules:
/// * `PRAGMA user_version` records the applied schema version.
/// * Migrations are append-only. Never edit a shipped migration; add a new one.
/// * Every migration runs inside a transaction together with the version bump.
enum Schema {
    static let migrations: [String] = [
        // v1 — initial schema.
        """
        CREATE TABLE clips (
            id               INTEGER PRIMARY KEY,
            uuid             TEXT NOT NULL UNIQUE,
            kind             TEXT NOT NULL,
            title            TEXT,
            auto_title       TEXT,
            preview_text     TEXT NOT NULL DEFAULT '',
            text_length      INTEGER NOT NULL DEFAULT 0,
            content_hash     TEXT NOT NULL,
            source_bundle_id TEXT,
            source_app_name  TEXT,
            created_at       REAL NOT NULL,
            last_used_at     REAL NOT NULL,
            use_count        INTEGER NOT NULL DEFAULT 0,
            is_pinned        INTEGER NOT NULL DEFAULT 0,
            pin_order        REAL,
            is_private       INTEGER NOT NULL DEFAULT 0,
            sensitivity      INTEGER NOT NULL DEFAULT 0,
            byte_size        INTEGER NOT NULL DEFAULT 0,
            thumbnail_key    TEXT,
            ocr_state        INTEGER NOT NULL DEFAULT 0,
            ocr_length       INTEGER NOT NULL DEFAULT 0,
            url              TEXT,
            metadata         TEXT
        );
        CREATE INDEX clips_last_used ON clips(last_used_at DESC, id DESC);
        CREATE INDEX clips_hash ON clips(content_hash);
        CREATE INDEX clips_source ON clips(source_bundle_id, last_used_at DESC);
        CREATE INDEX clips_kind ON clips(kind, last_used_at DESC);
        CREATE INDEX clips_pinned ON clips(is_pinned, pin_order) WHERE is_pinned = 1;
        CREATE INDEX clips_ocr_pending ON clips(ocr_state) WHERE ocr_state = 1;

        -- Full text lives outside `clips` so list queries never touch large overflow pages.
        CREATE TABLE clip_text (
            clip_id     INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
            plain_text  TEXT,
            ocr_text    TEXT
        );

        CREATE TABLE representations (
            id          INTEGER PRIMARY KEY,
            clip_id     INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
            item_index  INTEGER NOT NULL DEFAULT 0,
            ordinal     INTEGER NOT NULL DEFAULT 0,
            type        TEXT NOT NULL,
            byte_size   INTEGER NOT NULL,
            inline_data BLOB,
            blob_key    TEXT,
            encrypted   INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX representations_clip ON representations(clip_id, item_index, ordinal);
        CREATE INDEX representations_blob ON representations(blob_key) WHERE blob_key IS NOT NULL;

        CREATE TABLE spaces (
            id          INTEGER PRIMARY KEY,
            uuid        TEXT NOT NULL UNIQUE,
            name        TEXT NOT NULL,
            icon        TEXT NOT NULL DEFAULT 'folder',
            sort_order  INTEGER NOT NULL DEFAULT 0,
            is_pinned   INTEGER NOT NULL DEFAULT 0,
            created_at  REAL NOT NULL
        );

        CREATE TABLE clip_spaces (
            clip_id   INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
            space_id  INTEGER NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
            added_at  REAL NOT NULL,
            PRIMARY KEY (clip_id, space_id)
        ) WITHOUT ROWID;
        CREATE INDEX clip_spaces_space ON clip_spaces(space_id, clip_id);

        CREATE TABLE clip_tags (
            clip_id  INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
            tag      TEXT NOT NULL COLLATE NOCASE,
            PRIMARY KEY (clip_id, tag)
        ) WITHOUT ROWID;
        CREATE INDEX clip_tags_tag ON clip_tags(tag);

        CREATE TABLE ignored_apps (
            bundle_id  TEXT PRIMARY KEY,
            name       TEXT NOT NULL,
            added_at   REAL NOT NULL
        );

        CREATE TABLE meta (
            key    TEXT PRIMARY KEY,
            value  TEXT
        );

        -- Full-text index. The trigram tokenizer gives case-insensitive substring matching
        -- ("pabas" finds "supabase") and works for languages without word boundaries.
        CREATE VIRTUAL TABLE clip_fts USING fts5(
            title, body, ocr, files, url, app, tags,
            tokenize = 'trigram'
        );
        """,
        // v2 — images show the text recognised in them as their preview line.
        """
        UPDATE clips SET preview_text = substr(
            (SELECT ocr_text FROM clip_text WHERE clip_text.clip_id = clips.id), 1, 2000)
        WHERE kind IN ('image', 'screenshot') AND is_private = 0 AND preview_text = ''
          AND EXISTS (SELECT 1 FROM clip_text WHERE clip_text.clip_id = clips.id AND ocr_text IS NOT NULL AND ocr_text != '');
        """,
    ]

    static var currentVersion: Int { migrations.count }

    static func migrate(_ db: SQLiteDatabase) throws {
        let version = db.userVersion
        guard version < currentVersion else { return }
        for index in version..<currentVersion {
            try db.transaction {
                try db.execute(migrations[index])
                try db.setUserVersion(index + 1)
            }
        }
    }
}
