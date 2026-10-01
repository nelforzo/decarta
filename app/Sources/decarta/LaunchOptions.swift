import Foundation

/// Command line surface for the app, so the corpus pipeline is testable without a GUI.
struct LaunchOptions {
    var corpusPath: URL?
    var selftestPath: String?
    /// Open straight to an article (its numeric refid) instead of an empty reader.
    var openSlug: String?
    var showHelp = false

    init(arguments: [String] = CommandLine.arguments) {
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--corpus", "-c":
                if index + 1 < arguments.count {
                    corpusPath = URL(fileURLWithPath: arguments[index + 1])
                    index += 1
                }
            case "--open", "-o":
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    openSlug = arguments[index + 1]
                    index += 1
                }
            case "--selftest":
                // Bare form uses the resolved default corpus.
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    selftestPath = arguments[index + 1]
                    index += 1
                } else {
                    selftestPath = ""
                }
            case "--help", "-h":
                showHelp = true
            default:
                break
            }
            index += 1
        }
    }

    static let usage = """
    decarta — offline reader for the 2003-era encyclopedia corpus.

      decarta [--corpus <path/to/corpus.db>] [--open <refid>]
      decarta --selftest [path/to/corpus.db]

    --open takes an article's refid (its slug) and opens straight to it.
    Without --corpus the app looks for build/corpus.db, then
    ~/Library/Application Support/decarta/corpus.db.
    """

    /// Ordered search for a usable corpus.
    ///
    /// A packaged `decarta.app` carries its own corpus, and that must win over anything in
    /// the current working directory — otherwise launching the installed app from inside
    /// the repo would silently open the development build.
    static func resolveCorpus(explicit: URL?) -> URL? {
        var candidates: [URL] = []
        if let explicit { candidates.append(explicit) }
        if let env = ProcessInfo.processInfo.environment["DECARTA_CORPUS"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }

        let bundled = Bundle.main.resourceURL?.appendingPathComponent("corpus.db")
        let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        if isAppBundle, let bundled { candidates.append(bundled) }

        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/corpus.db"))
        if let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("decarta/corpus.db"))
        }
        if !isAppBundle, let bundled { candidates.append(bundled) }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}