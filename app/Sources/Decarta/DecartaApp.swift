import AppKit
import SwiftUI

/// A SwiftPM executable is not an `.app` bundle, so AppKit launches it as an accessory:
/// it gets a window but can never become the active application, and keystrokes have
/// nowhere to land. Declaring a regular activation policy before the app finishes
/// launching gives it a Dock entry and real keyboard focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DecartaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
        _state = StateObject(wrappedValue: AppState(corpus: corpus,
                                                    openSlug: options.openSlug))
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