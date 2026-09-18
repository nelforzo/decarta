import AppKit
import SwiftUI

@main
struct DecartaApp: App {
    @StateObject private var state: AppState
    private let corpusURL: URL?

    init() {
        let options = LaunchOptions()
        if options.showHelp {
            print(LaunchOptions.usage)
            exit(0)
        }
        if let selftest = options.selftestPath {
            let explicit = selftest.isEmpty ? nil : URL(fileURLWithPath: selftest)
            exit(Selftest.run(corpusPath: explicit ?? options.corpusPath))
        }

        let url = LaunchOptions.resolveCorpus(explicit: options.corpusPath)
        corpusURL = url
        let corpus = url.flatMap { try? Corpus(path: $0) }
        _state = StateObject(wrappedValue: AppState(corpus: corpus))
    }

    var body: some Scene {
        WindowGroup("Decarta") {
            ContentView()
                .environmentObject(state)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Copy Corpus Location") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(corpusURL?.path ?? "no corpus loaded", forType: .string)
                }
            }
        }
    }
}