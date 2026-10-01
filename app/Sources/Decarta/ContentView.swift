import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } content: {
            entryList
                .navigationSplitViewColumnWidth(min: 260, ideal: 340)
        } detail: {
            detail
        }
        .searchable(text: $state.searchText, placement: .sidebar,
                    prompt: "Search \(state.total) articles")
        .frame(minWidth: 940, minHeight: 580)
        // The corpus summary lives in the window subtitle rather than in a strip above
        // the list, so the content column stays flush with the sidebar.
        .navigationSubtitle(state.statusLine)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!state.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to the previous article")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    if state.isSearching {
                        ProgressView().controlSize(.small)
                    }
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $state.selectedCategory) {
            Label("All entries (\(state.total))", systemImage: "books.vertical")
                .tag(String?.none)
            Section("Browse") {
                ForEach(state.categories, id: \.name) { category in
                    Label("\(category.name)", systemImage: "textformat.abc")
                        .badge(category.count)
                        .tag(String?.some(category.name))
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.selectedCategory) { _ in
            DispatchQueue.main.async { state.categoryChanged() }
        }
    }

    // MARK: - Entry list

    private var entryList: some View {
        Group {
            if let message = state.errorMessage {
                ContentUnavailableViewCompat(title: "No corpus", message: message,
                                             systemImage: "externaldrive.badge.questionmark")
            } else if state.entries.isEmpty {
                ContentUnavailableViewCompat(
                    title: state.activeQuery.isEmpty ? "Nothing to browse" : "No matches",
                    message: state.activeQuery.isEmpty
                        ? "This bucket is empty."
                        : "Nothing in the corpus matches “\(state.activeQuery)”.",
                    systemImage: "magnifyingglass")
            } else {
                // No header strip here: any inset at the top of this column pushes its
                // rows below the sidebar's, which start flush against the toolbar.
                List(selection: $state.selection) {
                    ForEach(state.entries) { entry in
                        EntryRow(entry: entry)
                            .tag(entry.id)
                    }
                    if state.hasMore {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading more…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .onAppear {
                            // Deferred like the selection handlers: appending the next
                            // page must not run inside AppKit's row callback.
                            DispatchQueue.main.async { state.loadNextPage() }
                        }
                    }
                }
                .onChange(of: state.selection) { _ in
                    // Not deferred: `onChange` already runs outside AppKit's selection
                    // callback, and deferring added a render where the reader showed the
                    // previous article.
                    state.selectionChanged()
                }
            }
        }
    }

    /// What the list is currently showing, for the toolbar.
    private var summaryText: String {
        let shown = state.entries.count
        if !state.activeQuery.isEmpty {
            return "\(shown) result\(shown == 1 ? "" : "s") for “\(state.activeQuery)”"
        }
        if let category = state.selectedCategory {
            return "\(shown) entries in \(category)"
        }
        return state.hasMore ? "showing \(shown) entries" : "\(shown) entries"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let article = state.article {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ArticleHeader(entry: article.entry, sourcePath: article.sourcePath)
                    Divider()
                    if !article.media.isEmpty {
                        MediaGallery(media: article.media, corpus: state.corpus)
                        Divider()
                    }
                    ArticleBody(text: article.body)
                    if !article.xrefs.isEmpty {
                        Divider()
                        RelationsSection(title: "See also",
                                         systemImage: "arrow.turn.down.right",
                                         relations: article.xrefs,
                                         onOpen: { state.open(slug: $0) })
                    }
                    if !state.backlinks.isEmpty {
                        Divider()
                        BacklinksSection(entries: state.backlinks,
                                         onOpen: { state.open(slug: $0) })
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            ContentUnavailableViewCompat(title: "Pick an entry",
                                         message: "Search the corpus or browse a 五十音 bucket.",
                                         systemImage: "book")
        }
    }
}

// MARK: - Rows and sections

private struct EntryRow: View {
    let entry: Corpus.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
                .font(.headline)
                .lineLimit(1)
            if entry.snippet.isEmpty {
                HStack(spacing: 6) {
                    if !entry.reading.isEmpty {
                        Text(entry.reading).lineLimit(1)
                    }
                    Text("\(entry.charCount) chars")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(entry.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ArticleHeader: View {
    let entry: Corpus.Entry
    let sourcePath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.system(size: 30, weight: .bold))
                .textSelection(.enabled)
            if !entry.reading.isEmpty {
                Text(entry.reading)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("\(entry.category) · \(entry.charCount) chars · \(sourcePath)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The body is paragraph-separated text, so render it with real paragraph spacing —
/// no space-delimited words to reflow in Japanese, so spacing is the only cue.
private struct ArticleBody: View {
    let text: String

    private var paragraphs: [String] {
        text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MediaGallery: View {
    let media: [Corpus.Media]
    let corpus: Corpus?

    /// Only `<image>` records are pictures. `<thumb>`/`<picon>` are proprietary
    /// derivatives (.jsm/.jtn/.gsm/.gtn) the disc shipped for its own viewer, so they
    /// are neither displayed nor counted as missing.
    private var pictures: [Corpus.Media] {
        media.filter { $0.kind == "image" }
    }

    private var resolvable: [(Corpus.Media, URL)] {
        pictures.compactMap { item in
            guard let url = corpus?.url(for: item) else { return nil }
            return (item, url)
        }
    }

    private var missing: [Corpus.Media] {
        pictures.filter { corpus?.url(for: $0) == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pictures.count == 1 ? "Picture" : "Pictures").font(.headline)
            ForEach(resolvable, id: \.0.id) { item, url in
                VStack(alignment: .leading, spacing: 4) {
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 520, maxHeight: 380, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.quaternary))
                    } else {
                        Label("\(item.relPath) — could not be decoded",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !item.caption.isEmpty {
                        Text(item.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !missing.isEmpty {
                Text("\(missing.count) picture\(missing.count == 1 ? "" : "s") not copied — "
                     + "re-ingest with media enabled to include \(missing.count == 1 ? "it" : "them").")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct RelationsSection: View {
    let title: String
    let systemImage: String
    let relations: [Corpus.Relation]
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
            FlowRow {
                ForEach(relations) { relation in
                    Button {
                        onOpen(relation.targetSlug)
                    } label: {
                        Text(relation.title.isEmpty ? relation.anchor : relation.title)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(relation.title.isEmpty)
                }
            }
        }
    }
}

private struct BacklinksSection: View {
    let entries: [Corpus.Entry]
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Referenced by (\(entries.count))", systemImage: "link").font(.headline)
            ForEach(entries) { entry in
                Button {
                    onOpen(entry.slug)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.up.left").font(.caption2)
                        Text(entry.title)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
    }
}

/// Minimal wrapping row — `LazyVGrid` cannot size to content, and these are short.
private struct FlowRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // macOS 13 has no Layout-based flow; a wrapping HStack via a simple grid is fine
        // for the handful of links a reference article carries.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8, alignment: .leading)],
                  alignment: .leading, spacing: 8) {
            content
        }
    }
}

/// `ContentUnavailableView` is macOS 14+; this keeps the target at macOS 13.
struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String
    var systemImage: String = "doc.text.magnifyingglass"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
