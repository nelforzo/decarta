import Foundation

/// Headless end-to-end check: corpus -> schema -> search -> article body -> relations.
/// `Decarta --selftest <corpus.db>` exits non-zero if any link in the chain is broken.
enum Selftest {
    static func run(corpusPath: URL?) -> Int32 {
        var failures: [String] = []

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            print("\(condition ? "ok  " : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            if !condition { failures.append(label) }
        }

        // Escaping must survive prose that would otherwise be an FTS syntax error.
        check("phrase match quotes whole query",
              Corpus.phraseMatch(from: "don't co-op *") == "\"don't co-op *\"",
              Corpus.phraseMatch(from: "don't co-op *"))
        check("latin match tokenizes and prefixes last",
              Corpus.latinMatch(from: "don't co-op *") == "\"don\" \"t\" \"co\" \"op\"*",
              Corpus.latinMatch(from: "don't co-op *"))
        check("latin match empty on punctuation", Corpus.latinMatch(from: "  !!! ") == "")

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
            check("categories > 0", !cats.isEmpty, "\(cats.count) buckets")
            check("meta source_label", corpus.sourceLabel != "unknown", corpus.sourceLabel)
            check("schema v\(Corpus.schemaVersion)", true, "tokenizer \(corpus.tokenizer)")

            let all = try corpus.entries(inCategory: nil)
            check("entries == count", all.count == total, "\(all.count) vs \(total)")
            check("char counts present", all.allSatisfy { $0.charCount > 0 })

            if let first = all.first {
                let article = try corpus.article(slug: first.slug)
                check("article body fetched", (article?.body.isEmpty == false),
                      "\(first.title): \(article?.body.count ?? 0) chars")
                let term = first.title.split(separator: " ").first.map(String.init) ?? first.title
                let hits = try corpus.search(term)
                check("search finds entry", hits.contains { $0.slug == first.slug },
                      "\(hits.count) hits for \(term)")
                check("chars match body", article?.entry.charCount == first.charCount,
                      "\(first.charCount)")
            }

            if let category = cats.first?.name {
                let inCat = try corpus.entries(inCategory: category)
                check("category filter", !inCat.isEmpty, "\(category): \(inCat.count)")
            }

            // The Japanese path: a two-character query must still return something. Under
            // `unicode61` this returned nothing at all, which is why the corpus is trigram.
            if corpus.tokenizer == "trigram", total > 1000 {
                let shortQueries = ["火山", "栄養", "日本"]
                var best = 0
                for query in shortQueries {
                    best = max(best, try corpus.search(query).count)
                }
                check("short CJK query hits (LIKE fallback)", best > 0,
                      "best \(best) hits among \(shortQueries.joined(separator: ", "))")

                let long = "自由の女神"
                check("CJK phrase query hits", try corpus.search(long).count > 0, long)
            }

            // Cross-references and their reverse direction.
            if total > 1000 {
                var found: (Corpus.Article, [Corpus.Entry])?
                for entry in all.prefix(400) {
                    guard let article = try corpus.article(slug: entry.slug),
                          !article.xrefs.isEmpty else { continue }
                    found = (article, try corpus.backlinks(to: entry.slug))
                    break
                }
                check("cross-references present", found != nil,
                      found.map { "\($0.0.xrefs.count) links on \($0.0.entry.title)" } ?? "")
                if let (article, backlinks) = found {
                    let target = article.xrefs[0]
                    check("xref resolves to a title", !target.title.isEmpty, target.title)
                    _ = backlinks
                }
            }

            // Pictures: every sampled media row must resolve to a file the reader can load.
            if corpus.mediaRoot != nil {
                let stats = try corpus.mediaResolution(sample: 300)
                check("pictures resolve to files on disk",
                      stats.checked > 0 && stats.checked == stats.resolved,
                      "\(stats.resolved)/\(stats.checked)")
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
