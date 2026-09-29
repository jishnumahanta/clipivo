import Foundation

/// Translates a `ClipQuery` into SQL.
///
/// * Terms of 3+ characters use the FTS5 trigram index (substring, case-insensitive, ranked by bm25).
/// * Shorter terms cannot use a trigram index; they fall back to `LIKE` on the short, indexed-row
///   columns (title, automatic title, preview) which stays fast because those are bounded in size.
/// * Multiple terms combine with AND.
struct SearchPlanner {
    struct Plan {
        var sql: String
        var bindings: [SQLValue]
    }

    /// bm25 column weights: title, body, ocr, files, url, app, tags.
    static let columnWeights = "8.0, 1.0, 0.8, 3.0, 2.0, 0.6, 4.0"
    /// Rank penalty added per 30 days of age, so recent clips win ties.
    static let recencyPenaltyPer30Days = 0.35

    static func plan(_ query: ClipQuery, now: Date, countOnly: Bool = false) -> Plan {
        let terms = SearchSyntax.terms(query.text)
        let ftsTerms = terms.filter { $0.count >= 3 }
        let shortTerms = terms.filter { $0.count < 3 }
        let useFTS = !ftsTerms.isEmpty && !query.fields.ftsColumns.isEmpty

        var bindings: [SQLValue] = []
        var conditions: [String] = []
        var from = "clips c"

        if useFTS {
            from = "clip_fts JOIN clips c ON c.id = clip_fts.rowid"
            conditions.append("clip_fts MATCH ?")
            bindings.append(.text(matchExpression(ftsTerms, columns: query.fields.ftsColumns)))
        }

        for term in shortTerms {
            let pattern = "%" + escapeLike(term) + "%"
            conditions.append("(c.title LIKE ? ESCAPE '\\' OR c.auto_title LIKE ? ESCAPE '\\' OR c.preview_text LIKE ? ESCAPE '\\')")
            bindings += [.text(pattern), .text(pattern), .text(pattern)]
        }

        if let kinds = query.kinds, !kinds.isEmpty {
            let sorted = kinds.map(\.rawValue).sorted()
            conditions.append("c.kind IN (\(sorted.map { _ in "?" }.joined(separator: ", ")))")
            bindings += sorted.map { .text($0) }
        }
        if !query.sourceBundleIDs.isEmpty {
            let sorted = query.sourceBundleIDs.sorted()
            conditions.append("c.source_bundle_id IN (\(sorted.map { _ in "?" }.joined(separator: ", ")))")
            bindings += sorted.map { .text($0) }
        }
        if let app = query.appNameContains, !app.isEmpty {
            let pattern = "%" + escapeLike(app) + "%"
            conditions.append("(c.source_app_name LIKE ? ESCAPE '\\' OR c.source_bundle_id LIKE ? ESCAPE '\\')")
            bindings += [.text(pattern), .text(pattern)]
        }
        if let spaceID = query.spaceID {
            conditions.append("EXISTS (SELECT 1 FROM clip_spaces cs WHERE cs.clip_id = c.id AND cs.space_id = ?)")
            bindings.append(.int(spaceID))
        } else if let spaceName = query.spaceNameContains, !spaceName.isEmpty {
            conditions.append("EXISTS (SELECT 1 FROM clip_spaces cs JOIN spaces sp ON sp.id = cs.space_id WHERE cs.clip_id = c.id AND sp.name LIKE ? ESCAPE '\\')")
            bindings.append(.text("%" + escapeLike(spaceName) + "%"))
        }
        if query.pinnedOnly {
            conditions.append("c.is_pinned = 1")
        }
        if let tag = query.tag, !tag.isEmpty {
            conditions.append("EXISTS (SELECT 1 FROM clip_tags ct WHERE ct.clip_id = c.id AND ct.tag = ?)")
            bindings.append(.text(tag))
        }
        if let dateFilter = query.dateFilter {
            let interval = dateFilter.interval(now: now)
            if let from = interval.from {
                conditions.append("c.last_used_at >= ?")
                bindings.append(.date(from))
            }
            if let to = interval.to {
                conditions.append("c.last_used_at < ?")
                bindings.append(.date(to))
            }
        }

        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")

        if countOnly {
            return Plan(sql: "SELECT count(*) FROM \(from)\(whereClause)", bindings: bindings)
        }

        let orderBy: String
        if query.pinnedOnly && !useFTS {
            orderBy = "c.pin_order DESC, c.id DESC"
        } else if useFTS && query.sort == .relevance {
            orderBy = "bm25(clip_fts, \(columnWeights)) + ((? - c.last_used_at) / 2592000.0) * \(recencyPenaltyPer30Days), c.last_used_at DESC"
            bindings.append(.date(now))
        } else if query.sort == .created {
            orderBy = "c.created_at DESC, c.id DESC"
        } else {
            orderBy = "c.last_used_at DESC, c.id DESC"
        }

        bindings.append(.int(Int64(max(1, query.limit))))
        bindings.append(.int(Int64(max(0, query.offset))))
        let sql = "SELECT \(ClipLibrary.summaryColumns) FROM \(from)\(whereClause) ORDER BY \(orderBy) LIMIT ? OFFSET ?"
        return Plan(sql: sql, bindings: bindings)
    }

    /// Builds an FTS5 expression: every term must match (as a substring) in one of the columns.
    static func matchExpression(_ terms: [String], columns: [String]) -> String {
        let columnFilter = columns.count == 7 ? "" : "{\(columns.joined(separator: " "))} : "
        return terms.map { term in
            columnFilter + "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: " AND ")
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
