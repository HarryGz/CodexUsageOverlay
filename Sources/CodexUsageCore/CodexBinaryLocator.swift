import Foundation

public enum CodexBinaryLocator {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let explicit = environment["CODEX_BINARY"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])
        let home = environment["HOME"] ?? NSHomeDirectory()
        candidates.append((home as NSString).appendingPathComponent(".local/bin/codex"))
        return candidates.first(where: fileExists)
    }
}
