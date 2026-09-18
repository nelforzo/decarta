import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            entryList
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        .searchable(text: $state.searchText, placement: .sidebar,
                    prompt: "Search \(state.total) articles")
        .frame(minWidth: 900, minHeight: 560)
    }

    private var sidebar: some View {
        List(selection: $state.selectedCategory) {
            Label("All entries (\(state.total))", systemImage: "books.vertical")
                .tag(String?.none)
            Section("Categories") {
                ForEach(state.categories, id: \.name) { category in
                    Label("\(category.name) (\(category.count))", systemImage: "folder")
                        .tag(String?.some(category.name))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var entryList: some View {
        Group {
            if let message = state.errorMessage {
                ContentUnavailableViewCompat(title: "No corpus", message: message)
            } else if state.entries.isEmpty {
                ContentUnavailableViewCompat(title: "No matches",
                                             message: "Nothing in the corpus matches this.")
            } else {
                List(state.entries, selection: $state.selection) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.headline)
                        Text(entry.snippet.isEmpty
                             ? "\(entry.category) · \(entry.wordCount) words"
                             : entry.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .tag(entry.id)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let article = state.article(for: state.selection) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(article.entry.title).font(.largeTitle.bold())
                    Text("\(article.entry.category) · \(article.entry.wordCount) words · \(article.sourcePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text(article.body)
                        .font(.body)
                        .textSelection(.enabled)
                    if !article.media.isEmpty {
                        Divider()
                        Text("Media on the original disc").font(.headline)
                        ForEach(article.media) { media in
                            Text("[\(media.kind)] \(media.relPath)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }
        } else {
            ContentUnavailableViewCompat(title: "Pick an entry",
                                         message: "Search the corpus or browse a category.")
        }
    }
}

/// `ContentUnavailableView` is macOS 14+; this keeps the target at macOS 13.
struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}