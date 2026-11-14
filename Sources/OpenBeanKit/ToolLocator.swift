import Foundation

/// Resolve an explicitly configured executable or a known local installation.
public enum ToolLocator {
    public static func resolve(name: String, override: String?, preferred: [String] = [], searchPath: String? = nil) -> String? {
        let files = FileManager.default
        if let override, !override.isEmpty {
            return files.isExecutableFile(atPath: override) ? override : nil
        }
        let dirs = (searchPath ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return (preferred + dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path })
            .first { files.isExecutableFile(atPath: $0) }
    }
}
