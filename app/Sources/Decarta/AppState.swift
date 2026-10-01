import Foundation
import SwiftUI

/// 五十音 browse order, matching the buckets the extractor derives from `<jtitle>`.
enum CategoryOrder {
    static let rows = ["あ行", "か行", "さ行", "た行", "な行", "は行",
                       "ま行", "や行", "ら行", "わ行"]
    static let tail = ["A–Z", "0–9", "その他"]

    static func sorted(_ categories: [(name: String, count: Int)])
        -> [(name: String, count: Int)] {
        let order = rows + tail
        return categories.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.name) ?? order.count
            let right = order.firstIndex(of: rhs.name) ?? order.count
            if left != right { return left < right }
            return lhs.name < rhs.name
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var searchText = "" { didSet { scheduleReload() } }
    /// Written directly by the sidebar's `List(selection:)`; `categoryChanged()`
    /// (fired from `onChange`) does the reload, so nothing mutates state inside AppKit's
    /// own selection callback.
    @Published var selectedCategory: String?
    @Published private(set) var entries: [Corpus.Entry] = []
    @Published private(set) var categories: [(name: String, count: Int)] = []
    @Published private(set) var total = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeQuery = ""
    @Published private(set) var isSearching = false

    /// The full result of the current browse/search, and the window shown so far. A
    /// 39,000-entry corpus is loaded a page at a time: handing the whole array to a
    /// `List` at once makes AppKit complain (and stalls the first frame).
    private var allEntries: [Corpus.Entry] = []
    private static let pageSize = 250
    var hasMore: Bool { entries.count < allEntries.count }
    var loadedCount: Int { entries.count }

    /// The list selection. Kept separate from `currentSlug` so a cross-reference jump can
    /// show an article that is not in the current list.
    @Published var selection: Corpus.Entry.ID?

    /// The currently-open article and its reverse links. These MUST be `@Published`:
    /// the list selection already triggers a render, and if loading the article did not
    /// invalidate the view too, the reader would show the article from one click ago.
    @Published private(set) var currentSlug: String?
    @Published private(set) var article: Corpus.Article?
    @Published private(set) var backlinks: [Corpus.Entry] = []
    private var history: [String] = []

    let corpus: Corpus?

    init(corpus: Corpus?) {
        self.corpus = corpus
        if corpus == nil {
            errorMessage = "No corpus found. Build one with `make ingest`, or pass --corpus <path>."
        }
        reload()
    }

    var canGoBack: Bool { history.count > 1 }
    var corpusPath: String { corpus?.path.path ?? "no corpus loaded" }
    var statusLine: String {
        guard let corpus else { return "no corpus" }
        return "\(total) entries · \(categories.count) buckets · \(corpus.tokenizer)"
    }

    private var reloadTask: Task<Void, Never>?

    private func scheduleReload() {
        reloadTask?.cancel()
        isSearching = true
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func reload() {
        guard let corpus else { return }
        isSearching = false
        do {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            activeQuery = query
            allEntries = query.isEmpty
                ? try corpus.entries(inCategory: selectedCategory)
                : try corpus.search(query)
            entries = Array(allEntries.prefix(Self.pageSize))
            categories = CategoryOrder.sorted(try corpus.categories())
            total = try corpus.totalArticles()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadNextPage() {
        guard hasMore else { return }
        let next = allEntries.prefix(entries.count + Self.pageSize)
        if next.count != entries.count {
            entries = Array(next)
        }
    }

    /// Load an article by slug. A jump records history; a list click does not re-record.
    private func show(slug: String, recordHistory: Bool) {
        guard let corpus, let article = try? corpus.article(slug: slug) else { return }
        if recordHistory, history.last != slug {
            history.append(slug)
        }
        currentSlug = slug
        self.article = article
        backlinks = (try? corpus.backlinks(to: slug)) ?? []
    }

    /// A selection made in the entry list.
    func selectionChanged() {
        guard let id = selection, let entry = entries.first(where: { $0.id == id }) else { return }
        show(slug: entry.slug, recordHistory: true)
    }

    /// A cross-reference jump from the reader.
    func open(slug: String) {
        selection = nil
        show(slug: slug, recordHistory: true)
    }

    func goBack() {
        guard history.count > 1 else { return }
        history.removeLast()
        if let previous = history.last {
            selection = nil
            show(slug: previous, recordHistory: false)
        }
    }

    /// The browse bucket changed. Reset the reading position and reload the list.
    func categoryChanged() {
        searchText = ""
        currentSlug = nil
        article = nil
        backlinks = []
        selection = nil
        history = []
        reload()
    }
}
