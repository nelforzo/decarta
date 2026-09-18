import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var searchText = "" { didSet { scheduleReload() } }
    @Published var selectedCategory: String? { didSet { if selectedCategory != oldValue { reload() } } }
    @Published private(set) var entries: [Corpus.Entry] = []
    @Published var selection: Corpus.Entry.ID?
    @Published private(set) var categories: [(name: String, count: Int)] = []
    @Published private(set) var total = 0
    @Published private(set) var errorMessage: String?

    let corpus: Corpus?

    init(corpus: Corpus?) {
        self.corpus = corpus
        if corpus == nil {
            errorMessage = "No corpus found. Build one with `make ingest`, or pass --corpus <path>."
        }
        reload()
    }

    private var reloadTask: Task<Void, Never>?

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func reload() {
        guard let corpus else { return }
        do {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            entries = query.isEmpty
                ? try corpus.entries(inCategory: selectedCategory)
                : try corpus.search(query)
            categories = try corpus.categories()
            total = try corpus.totalArticles()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func article(for id: Corpus.Entry.ID?) -> Corpus.Article? {
        guard let corpus, let id, let entry = entries.first(where: { $0.id == id }) else { return nil }
        return try? corpus.article(slug: entry.slug)
    }
}