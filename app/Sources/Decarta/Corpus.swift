import Foundation
import SQLite3

/// Read-only reader for a Decarta corpus (`corpus.db`, schema v1).
///
/// The app never writes: the corpus is opened SQLITE_OPEN_READONLY and every query
/// goes through `query`.
final class Corpus {
    enum CorpusError: Error, LocalizedError {
        case open(String)
        case unsupportedSchema(String)
        case query(String)

        var errorDescription: String? {
            switch self {
            case .open(let detail): return "Could not open corpus: \(detail)"
            case .unsupportedSchema(let version):
                return "Corpus schema \(version) is not supported by this build (expected 1)."
            case .query(let detail): return "Query failed: \(detail)"
            }
        }
    }

    struct Entry: Identifiable, Hashable {
        let id: Int64
        let slug: String
        let title: String
        let category: String
        let wordCount: Int
        var snippet: String = ""
    }

    struct Media: Identifiable, Hashable {
        let id: Int64
        let kind: String
        let relPath: String
    }

    struct Article {
        let entry: Entry
        let body: String
        let sourcePath: String
        let media: [Media]
    }

    static let schemaVersion = "1"

    let path: URL
    private var db: OpaquePointer?
    private(set) var sourceLabel: String = "unknown"
    private(set) var builtAt: String = "unknown"

    init(path: URL) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw CorpusError.open(detail)
        }
        self.db = handle

        let meta = (try? metaValues()) ?? [:]
        if let version = meta["schema_version"], version != Self.schemaVersion {
            sqlite3_close(handle)
            self.db = nil
            throw CorpusError.unsupportedSchema(version)
        }
        sourceLabel = meta["source_label"] ?? "unknown"
        builtAt = meta["built_at"] ?? "unknown"
    }

    deinit {
        sqlite3_close(db)
    }

    private func metaValues() throws -> [String: String] {
        var out: [String: String] = [:]
        try query("SELECT key, value FROM meta") { row in
            out[row.string(0)] = row.string(1)
        }
        return out
    }

    private func query(_ sql: String, bind: [String] = [], each: (Row) -> Void) throws {
        guard let db else { throw CorpusError.open("corpus is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CorpusError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bind.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, Self.transient)
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                each(Row(statement: statement!))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw CorpusError.query(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Row {
        let statement: OpaquePointer

        func string(_ index: Int32) -> String {
            guard let cString = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: cString)
        }

        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }

        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    }

    // MARK: - Reads

    func totalArticles() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM articles") { count = Int($0.int(0)) }
        return count
    }

    func categories() throws -> [(name: String, count: Int)] {
        var out: [(String, Int)] = []
        try query("SELECT category, COUNT(*) FROM articles GROUP BY category ORDER BY category") {
            out.append(($0.string(0), Int($0.int(1))))
        }
        return out
    }

    func entries(inCategory category: String?) throws -> [Entry] {
        let sql: String
        var bind: [String] = []
        if let category {
            sql = """
            SELECT id, slug, title, category, word_count FROM articles
            WHERE category = ? ORDER BY title COLLATE NOCASE
            """
            bind = [category]
        } else {
            sql = """
            SELECT id, slug, title, category, word_count FROM articles
            ORDER BY title COLLATE NOCASE
            """
        }
        var out: [Entry] = []
        try query(sql, bind: bind) { row in
            out.append(Entry(id: row.int(0), slug: row.string(1), title: row.string(2),
                             category: row.string(3), wordCount: Int(row.int(4))))
        }
        return out
    }

    /// Full-text search over the FTS5 index, title-weighted, with snippets.
    func search(_ text: String, limit: Int = 60) throws -> [Entry] {
        let match = Self.ftsQuery(from: text)
        guard !match.isEmpty else { return [] }
        var out: [Entry] = []
        try query("""
            SELECT a.id, a.slug, a.title, a.category, a.word_count,
                   snippet(articles_fts, 1, '', '', '…', 14)
            FROM articles_fts
            JOIN articles a ON a.id = articles_fts.rowid
            WHERE articles_fts MATCH ?
            ORDER BY bm25(articles_fts, 8.0, 1.0)
            LIMIT ?
            """, bind: [match, String(limit)]) { row in
            out.append(Entry(id: row.int(0), slug: row.string(1), title: row.string(2),
                             category: row.string(3), wordCount: Int(row.int(4)),
                             snippet: row.string(5)))
        }
        return out
    }

    /// Turn free text into a forgiving FTS5 MATCH expression.
    ///
    /// Users type prose, not FTS operators: quote each token so `don't`, `co-op` and
    /// stray `*` can't produce a syntax error, and prefix-match the last token so
    /// search feels live while typing.
    static func ftsQuery(from text: String) -> String {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.enumerated().map { index, token in
            index == tokens.count - 1 ? "\"\(token)\"*" : "\"\(token)\""
        }.joined(separator: " ")
    }

    func article(slug: String) throws -> Article? {
        var entry: Entry?
        var body = ""
        var sourcePath = ""
        try query("""
            SELECT id, slug, title, category, word_count, body, source_path
            FROM articles WHERE slug = ? LIMIT 1
            """, bind: [slug]) { row in
            entry = Entry(id: row.int(0), slug: row.string(1), title: row.string(2),
                          category: row.string(3), wordCount: Int(row.int(4)))
            body = row.string(5)
            sourcePath = row.string(6)
        }
        guard let entry else { return nil }
        var media: [Media] = []
        try query("SELECT id, kind, rel_path FROM media WHERE article_id = ?", bind: [String(entry.id)]) {
            media.append(Media(id: $0.int(0), kind: $0.string(1), relPath: $0.string(2)))
        }
        return Article(entry: entry, body: body, sourcePath: sourcePath, media: media)
    }
}