import Foundation

/// A uniquely named directory that is deleted when the value is released.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        // Resolve symlinks (/var → /private/var) so paths match what git reports.
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchardTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func makeDirectories(_ paths: String...) throws {
        for path in paths {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(path), withIntermediateDirectories: true)
        }
    }

    func write(_ path: String, _ contents: String) throws {
        try contents.write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
}
