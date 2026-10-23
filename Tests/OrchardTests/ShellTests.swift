import Foundation
import Testing
@testable import Orchard

struct ShellTests {
    @Test func capturesAllOutputOfShortLivedCommands() async throws {
        let outputs = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<3000 {
                group.addTask { (index, try await Shell.run("/bin/echo", ["output \(index)"])) }
            }
            return try await group.reduce(into: [Int: String]()) { $0[$1.0] = $1.1 }
        }
        for index in 0..<3000 {
            #expect(outputs[index] == "output \(index)\n")
        }
    }

    @Test func streamsLinesAndReportsFailures() async throws {
        let lines = LockedLines()
        let error = await #expect(throws: ShellError.self) {
            try await Shell.run("/bin/sh", ["-c", "echo one; echo two >&2; printf three; exit 3"],
                                onLine: { lines.append($0) })
        }
        #expect(error?.status == 3)
        #expect(error?.output == "one\ntwo\nthree")
        #expect(lines.all == ["one", "two", "three"])
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
