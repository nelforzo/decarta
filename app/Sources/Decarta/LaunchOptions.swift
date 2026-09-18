import Foundation

/// Command line surface for the app, so the corpus pipeline is testable without a GUI.
struct LaunchOptions {
    var corpusPath: URL?
    var selftestPath: String?
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
    Decarta — offline reader for the 2003-era encyclopedia corpus.

      Decarta [--corpus <path/to/corpus.db>]
      Decarta --selftest [path/to/corpus.db]

    Without --corpus the app looks for build/corpus.db, then
    ~/Library/Application Support/Decarta/corpus.db.
    """

    /// Ordered search for a usable corpus.
    static func resolveCorpus(explicit: URL?) -> URL? {
        var candidates: [URL] = []
        if let explicit { candidates.append(explicit) }
        if let env = ProcessInfo.processInfo.environment["DECARTA_CORPUS"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/corpus.db"))
        if let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("Decarta/corpus.db"))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("corpus.db"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}