import AppKit
import Foundation
import SQLite3

/// Read-only reader for a Decarta corpus (`corpus.db`, schema v2).
///
/// The app never writes: the corpus is opened SQLITE_OPEN_READONLY and every query
/// goes through `query`.
///
/// v2 carries what a Japanese corpus needs: character counts (`word_count` was
/// meaningless), the kana reading, article cross-references, and a `tokenizer` in
/// `meta` that decides how search runs — `trigram` matches substrings of three or more
/// characters, and shorter queries take a `LIKE` scan.
final class Corpus {
    enum CorpusError: Error, LocalizedError {
        case open(String)
        case unsupportedSchema(String)
        case query(String)

        var errorDescription: String? {
            switch self {
            case .open(let detail): return "Could not open corpus: \(detail)"
            case .unsupportedSchema(let version):
                return "Corpus schema \(version) is not supported by this build (expected \(Corpus.schemaVersion))."
            case .query(let detail): return "Query failed: \(detail)"
            }
        }
    }

    struct Entry: Identifiable, Hashable {
        let id: Int64
        let slug: String
        let title: String
        var reading: String = ""
        let category: String
        let charCount: Int
        var snippet: String = ""
    }

    struct Media: Identifiable, Hashable {
        let id: Int64
        let kind: String
        let relPath: String
        let caption: String
    }

    /// An article-to-article cross-reference, resolved to the target's title.
    struct Relation: Identifiable, Hashable {
        var id: String { targetSlug }
        let targetSlug: String
        let anchor: String
        let title: String
    }

    struct Article {
        let entry: Entry
        let body: String
        let sourcePath: String
        let media: [Media]
        let xrefs: [Relation]
    }

    static let schemaVersion = "2"
    static let shortQueryLength = 3

    let path: URL
    private var db: OpaquePointer?
    private(set) var sourceLabel: String = "unknown"
    private(set) var builtAt: String = "unknown"
    private(set) var tokenizer: String = "unicode61"
    /// Where referenced media was copied at ingest time, when it was.
    private(set) var mediaRoot: URL?

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
        tokenizer = meta["tokenizer"] ?? "unicode61"
        mediaRoot = Corpus.resolveMediaRoot(meta: meta, corpusPath: path)
    }

    /// Find the media tree, preferring what the corpus recorded but falling back to a
    /// `media/` directory beside the corpus file.
    ///
    /// The fallback is what makes a packaged `Decarta.app` self-contained: the corpus is
    /// built on a machine where the media lived under `build/`, so the recorded
    /// `meta.media_root` is an absolute path that means nothing once the app is copied to
    /// /Applications. Inside the bundle the pictures sit next to `corpus.db` instead.
    private static func resolveMediaRoot(meta: [String: String], corpusPath: URL) -> URL? {
        let corpusDir = corpusPath.deletingLastPathComponent()
        var candidates: [URL] = []
        if let recorded = meta["media_root"], !recorded.isEmpty {
            candidates.append(recorded.hasPrefix("/")
                ? URL(fileURLWithPath: recorded)
                : URL(fileURLWithPath: recorded, relativeTo: corpusDir).standardizedFileURL)
        }
        candidates.append(corpusDir.appendingPathComponent("media"))
        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: candidate.path,
                                                        isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
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
            SELECT id, slug, title, reading, category, char_count FROM articles
            WHERE category = ? ORDER BY reading COLLATE NOCASE, title COLLATE NOCASE
            """
            bind = [category]
        } else {
            sql = """
            SELECT id, slug, title, reading, category, char_count FROM articles
            ORDER BY reading COLLATE NOCASE, title COLLATE NOCASE
            """
        }
        var out: [Entry] = []
        try query(sql, bind: bind) { row in
            out.append(Entry(id: row.int(0), slug: row.string(1), title: row.string(2),
                             reading: row.string(3), category: row.string(4),
                             charCount: Int(row.int(5))))
        }
        return out
    }

    /// Search results plus the exact number of matches when it is cheap to know.
    ///
    /// `total` is nil on the `LIKE` path, where counting means scanning every column
    /// (~80-90 ms measured); the caller says "N+" rather than reporting a wrong number.
    struct SearchResults {
        let entries: [Entry]
        let total: Int?
    }

    /// Full-text search, dispatching on the corpus's tokenizer.
    ///
    /// The query is NFKC-normalized and split into terms first: IMEs hand over full-width
    /// Latin and half-width katakana that never match the indexed text (measured `ＦＵＪＩ`
    /// 0 hits as typed, 5 once normalized), and a multi-word query should AND its terms
    /// rather than demand one exact phrase (`自由 女神` was 0 hits, now 28).
    ///
    /// `trigram` cannot serve terms shorter than three characters, so a query containing
    /// one takes the `LIKE` path. Anything that still trips the FTS parser also degrades
    /// to `LIKE` rather than surfacing an error.
    func search(_ text: String, limit: Int = 300) throws -> SearchResults {
        let raw = Self.splitTerms(text)
        guard !raw.isEmpty else { return SearchResults(entries: [], total: 0) }
        let typed = try search(terms: raw, limit: limit)
        if !typed.entries.isEmpty { return typed }
        // Only rewrite the query if it matched nothing as typed.
        let normalized = Self.queryTerms(text)
        if normalized == raw { return typed }
        return try search(terms: normalized, limit: limit)
    }

    private func search(terms: [String], limit: Int) throws -> SearchResults {
        if tokenizer == "trigram", terms.contains(where: { $0.count < Self.shortQueryLength }) {
            return try likeSearch(terms, limit: limit)
        }
        do {
            let match = matchExpression(for: terms)
            guard !match.isEmpty else { return SearchResults(entries: [], total: 0) }
            return SearchResults(entries: try ftsSearch(match, limit: limit),
                                 total: try ftsCount(match))
        } catch {
            return try likeSearch(terms, limit: limit)
        }
    }

    /// Exact match count — a plain COUNT over the FTS index, which is effectively free.
    func searchCount(_ text: String) throws -> Int? {
        let raw = Self.splitTerms(text)
        guard !raw.isEmpty else { return 0 }
        let typed = try count(terms: raw)
        if typed == nil || (typed ?? 0) > 0 { return typed }
        let normalized = Self.queryTerms(text)
        if normalized == raw { return typed }
        return try count(terms: normalized)
    }

    private func count(terms: [String]) throws -> Int? {
        if tokenizer == "trigram", terms.contains(where: { $0.count < Self.shortQueryLength }) {
            return nil
        }
        let match = matchExpression(for: terms)
        guard !match.isEmpty else { return 0 }
        return try ftsCount(match)
    }

    private func ftsCount(_ match: String) throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM articles_fts WHERE articles_fts MATCH ?",
                  bind: [match]) { count = Int($0.int(0)) }
        return count
    }

    private func ftsSearch(_ match: String, limit: Int) throws -> [Entry] {
        var out: [Entry] = []
        try query("""
            SELECT a.id, a.slug, a.title, a.reading, a.category, a.char_count,
                   snippet(articles_fts, 2, '', '', '…', 14)
            FROM articles_fts
            JOIN articles a ON a.id = articles_fts.rowid
            WHERE articles_fts MATCH ?
            ORDER BY bm25(articles_fts, 8.0, 4.0, 1.0)
            LIMIT ?
            """, bind: [match, String(limit)]) { row in
            out.append(Entry(id: row.int(0), slug: row.string(1), title: row.string(2),
                             reading: row.string(3), category: row.string(4),
                             charCount: Int(row.int(5)), snippet: row.string(6)))
        }
        return out
    }

    /// Two-tier `LIKE` for queries the trigram index cannot serve.
    ///
    /// Ranking every match by `length(title)` forces a scan and sort of the whole corpus
    /// (measured 82-104 ms). Titles and readings are instead queried and ranked on their
    /// own — few rows, and the most relevant ones anyway — and the body only fills the
    /// remaining page, unordered.
    private func likeSearch(_ terms: [String], limit: Int) throws -> SearchResults {
        let patterns = terms.map { "%\(Self.escapeLike($0))%" }

        var headBind: [String] = []
        for pattern in patterns { headBind.append(pattern); headBind.append(pattern) }
        let headPredicate = Array(repeating: "(a.title LIKE ? ESCAPE '\\' OR a.reading LIKE ? ESCAPE '\\')",
                                  count: terms.count).joined(separator: " AND ")

        var out: [Entry] = []
        try query("""
            SELECT a.id, a.slug, a.title, a.reading, a.category, a.char_count,
                   substr(a.body, 1, 160)
            FROM articles a
            WHERE \(headPredicate)
            ORDER BY length(a.title), a.title COLLATE NOCASE
            LIMIT ?
            """, bind: headBind + [String(limit)]) { row in
            out.append(Entry(id: row.int(0), slug: row.string(1), title: row.string(2),
                             reading: row.string(3), category: row.string(4),
                             charCount: Int(row.int(5)), snippet: row.string(6)))
        }
        if out.count >= limit { return SearchResults(entries: out, total: nil) }

        var bodyBind: [String] = []
        for pattern in patterns {
            bodyBind.append(pattern); bodyBind.append(pattern); bodyBind.append(pattern)
        }
        let bodyPredicate = Array(repeating: "(a.title LIKE ? ESCAPE '\\' OR a.reading LIKE ? ESCAPE '\\' OR a.body LIKE ? ESCAPE '\\')",
                                  count: terms.count).joined(separator: " AND ")
        let seen = Set(out.map(\.id))
        var extra: [Entry] = []
        try query("""
            SELECT a.id, a.slug, a.title, a.reading, a.category, a.char_count,
                   substr(a.body, 1, 160)
            FROM articles a
            WHERE \(bodyPredicate)
            LIMIT ?
            """, bind: bodyBind + [String(limit + out.count)]) { row in
            extra.append(Entry(id: row.int(0), slug: row.string(1), title: row.string(2),
                               reading: row.string(3), category: row.string(4),
                               charCount: Int(row.int(5)), snippet: row.string(6)))
        }
        out.append(contentsOf: extra.filter { !seen.contains($0.id) })
        return SearchResults(entries: Array(out.prefix(limit)), total: nil)
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Split a query on whitespace, leaving the text exactly as typed.
    static func splitTerms(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// NFKC-normalize the query and split it on whitespace into terms.
    ///
    /// The extra NFC pass matters: `precomposedStringWithCompatibilityMapping` decomposes
    /// half-width kana to a full-width base plus a combining mark but does not compose it
    /// back, so `ﾌｼﾞ` became U+30D5 U+30B7 U+3099 where Python's NFKC (which built the
    /// corpus) stores U+30D5 U+30B8 — the two never compare equal.
    static func queryTerms(_ text: String) -> [String] {
        text.precomposedStringWithCompatibilityMapping
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    /// FTS5 MATCH expression: every term must appear.
    ///
    /// Trigram corpora quote each term as a phrase (a substring match, which is how CJK
    /// is actually searched). Latin corpora keep per-token matching with a prefix on the
    /// last token, so search feels live while typing. Quoting either way keeps `don't`,
    /// `co-op` and stray `*` from becoming syntax.
    func matchExpression(for terms: [String]) -> String {
        if tokenizer == "trigram" {
            return terms.map(Self.phrase).joined(separator: " AND ")
        }
        var tokens: [String] = []
        for term in terms {
            tokens.append(contentsOf: term
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty })
        }
        guard !tokens.isEmpty else { return "" }
        var parts = tokens.map(Self.phrase)
        parts[parts.count - 1] += "*"
        return parts.joined(separator: " ")
    }

    static func phrase(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func article(slug: String) throws -> Article? {
        var entry: Entry?
        var body = ""
        var sourcePath = ""
        try query("""
            SELECT id, slug, title, reading, category, char_count, body, source_path
            FROM articles WHERE slug = ? LIMIT 1
            """, bind: [slug]) { row in
            entry = Entry(id: row.int(0), slug: row.string(1), title: row.string(2),
                          reading: row.string(3), category: row.string(4),
                          charCount: Int(row.int(5)))
            body = row.string(6)
            sourcePath = row.string(7)
        }
        guard let entry else { return nil }
        var media: [Media] = []
        try query("SELECT id, kind, rel_path, caption FROM media WHERE article_id = ?",
                  bind: [String(entry.id)]) {
            media.append(Media(id: $0.int(0), kind: $0.string(1), relPath: $0.string(2),
                               caption: $0.string(3)))
        }
        var xrefs: [Relation] = []
        try query("""
            SELECT x.target_slug, x.anchor, COALESCE(a.title, '')
            FROM xrefs x
            LEFT JOIN articles a ON a.slug = x.target_slug
            WHERE x.article_id = ? ORDER BY x.ordinal
            """, bind: [String(entry.id)]) {
            xrefs.append(Relation(targetSlug: $0.string(0), anchor: $0.string(1),
                                  title: $0.string(2)))
        }
        return Article(entry: entry, body: body, sourcePath: sourcePath,
                       media: media, xrefs: xrefs)
    }

    /// Resolve a media row to a file on disk, when the bytes were copied out.
    func url(for media: Media) -> URL? {
        guard let mediaRoot else { return nil }
        let candidate = mediaRoot.appendingPathComponent(media.relPath)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// How many picture rows actually resolve to a file — used by `--selftest` to prove
    /// the media path works, since that is not otherwise covered headlessly.
    func mediaResolution(sample: Int = 300) throws -> (checked: Int, resolved: Int) {
        var relPaths: [String] = []
        try query("SELECT rel_path FROM media WHERE kind = 'image' LIMIT ?",
                  bind: [String(sample)]) { relPaths.append($0.string(0)) }
        guard let mediaRoot else { return (relPaths.count, 0) }
        let resolved = relPaths.count { rel in
            FileManager.default.fileExists(atPath: mediaRoot.appendingPathComponent(rel).path)
        }
        return (relPaths.count, resolved)
    }

    /// Decode-check a few pictures the way the gallery does, for `--selftest`.
    ///
    /// Resolving a path is not the same as being able to display it: this asserts that
    /// `NSImage` actually loads the file, which is what decides whether a reader sees a
    /// picture or the "could not be decoded" placeholder.
    func mediaDecodeCheck(sample: Int = 8) throws -> (checked: Int, decoded: Int) {
        var relPaths: [String] = []
        try query("SELECT rel_path FROM media WHERE kind = 'image' LIMIT ?",
                  bind: [String(sample)]) { relPaths.append($0.string(0)) }
        guard let mediaRoot else { return (0, 0) }
        var checked = 0
        var decoded = 0
        for rel in relPaths {
            let url = mediaRoot.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            checked += 1
            if let image = NSImage(contentsOf: url), image.size.width > 0 {
                decoded += 1
            }
        }
        return (checked, decoded)
    }

    /// Every article that cross-references `slug` — the "referenced by" direction.
    func backlinks(to slug: String, limit: Int = 40) throws -> [Entry] {
        var out: [Entry] = []
        try query("""
            SELECT a.id, a.slug, a.title, a.reading, a.category, a.char_count
            FROM xrefs x JOIN articles a ON a.id = x.article_id
            WHERE x.target_slug = ?
            GROUP BY a.id
            ORDER BY a.title COLLATE NOCASE
            LIMIT ?
            """, bind: [slug, String(limit)]) { row in
            out.append(Entry(id: row.int(0), slug: row.string(1), title: row.string(2),
                             reading: row.string(3), category: row.string(4),
                             charCount: Int(row.int(5))))
        }
        return out
    }

    func entry(slug: String) throws -> Entry? {
        var found: Entry?
        try query("""
            SELECT id, slug, title, reading, category, char_count
            FROM articles WHERE slug = ? LIMIT 1
            """, bind: [slug]) { row in
            found = Entry(id: row.int(0), slug: row.string(1), title: row.string(2),
                          reading: row.string(3), category: row.string(4),
                          charCount: Int(row.int(5)))
        }
        return found
    }
}
