import Foundation

/// Headless end-to-end check: corpus -> schema -> search -> article body.
/// `Decarta --selftest <corpus.db>` exits non-zero if any link in the chain is broken.
enum Selftest {
    static func run(corpusPath: URL?) -> Int32 {
        var failures: [String] = []

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            print("\(condition ? "ok  " : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            if !condition { failures.append(label) }
        }

        // Escaping must survive prose that would otherwise be an FTS syntax error.
        check("ftsQuery quotes tokens", Corpus.ftsQuery(from: "don't co-op *") == "\"don\" \"t\" \"co\" \"op\"*",
              Corpus.ftsQuery(from: "don't co-op *"))
        check("ftsQuery empty on punctuation", Corpus.ftsQuery(from: "  !!! ") == "")

        guard let url = LaunchOptions.resolveCorpus(explicit: corpusPath) else {
            print("FAIL  corpus located: none found (build one with `make ingest`)")
            return 1
        }
        print("ok    corpus located: \(url.path)")

        let corpus: Corpus
        do {
            corpus = try Corpus(path: url)
        } catch {
            print("FAIL  open corpus: \(error.localizedDescription)")
            return 1
        }

        do {
            let total = try corpus.totalArticles()
            check("articles > 0", total > 0, "\(total) articles")
            let cats = try corpus.categories()
            check("categories > 0", !cats.isEmpty, "\(cats.count) categories")
            check("meta source_label", corpus.sourceLabel != "unknown", corpus.sourceLabel)

            let all = try corpus.entries(inCategory: nil)
            check("entries == count", all.count == total, "\(all.count) vs \(total)")

            if let first = all.first {
                let article = try corpus.article(slug: first.slug)
                check("article body fetched", (article?.body.isEmpty == false),
                      "\(first.title): \(article?.body.count ?? 0) chars")
                let hits = try corpus.search(first.title.split(separator: " ").first.map(String.init) ?? first.slug)
                check("search finds entry", hits.contains { $0.slug == first.slug },
                      "\(hits.count) hits for \(first.title)")
            }

            if let category = cats.first?.name {
                let inCat = try corpus.entries(inCategory: category)
                check("category filter", !inCat.isEmpty, "\(category): \(inCat.count)")
            }
        } catch {
            print("FAIL  query: \(error.localizedDescription)")
            failures.append("query")
        }

        if failures.isEmpty {
            print("SELFTEST OK")
            return 0
        }
        print("SELFTEST FAILED: \(failures.joined(separator: ", "))")
        return 1
    }
}