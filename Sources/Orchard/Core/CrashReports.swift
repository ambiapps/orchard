import Foundation

/// A crash of a deployed app, read from an `.ips` report (bug type 309).
struct CrashReport: Sendable, Equatable {
    struct Frame: Sendable, Equatable {
        var image: String
        var imagePath: String?
        var imageBase: UInt64?
        /// The image's Mach-O UUID, lowercase with dashes as in the report.
        var imageUUID: String?
        var imageOffset: UInt64
        var symbol: String?
        var symbolLocation: Int?

        var address: UInt64? { imageBase.map { $0 + imageOffset } }
    }

    var processName: String
    var bundleID: String?
    var timestamp: Date
    /// "EXC_BAD_ACCESS (SIGSEGV)".
    var exceptionType: String
    /// Why it died: Swift/ObjC messages from `asi`, else the termination indicator.
    var reasons: [String]
    /// The last exception backtrace when there is one (uncaught ObjC exceptions), else the
    /// crashed thread, innermost first.
    var frames: [Frame]
    /// `CoreSimulator.SimDevice.<UDID>` for simulator processes.
    var coalitionName: String?

    static let crashBugType = "309"

    /// Parses an `.ips` file: a JSON header line, then a JSON body. Nil for anything but a crash.
    static func parse(_ ips: String) -> CrashReport? {
        guard let newline = ips.firstIndex(of: "\n"),
              let header = json(ips[..<newline]),
              header["bug_type"] as? String == crashBugType,
              let body = json(ips[ips.index(after: newline)...])
        else { return nil }

        let exception = body["exception"] as? [String: Any]
        let type = exception?["type"] as? String ?? "Crash"
        let exceptionType = (exception?["signal"] as? String).map { "\(type) (\($0))" } ?? type

        var reasons: [String] = []
        if let asi = body["asi"] as? [String: [String]] {
            reasons += asi.keys.sorted().flatMap { asi[$0] ?? [] }
        }
        if let message = exception?["message"] as? String { reasons.append(message) }
        if reasons.isEmpty, let indicator = (body["termination"] as? [String: Any])?["indicator"] as? String {
            reasons.append(indicator)
        }

        let images = body["usedImages"] as? [[String: Any]] ?? []
        let rawFrames: [[String: Any]]
        if let backtrace = body["lastExceptionBacktrace"] as? [[String: Any]], !backtrace.isEmpty {
            rawFrames = backtrace
        } else if let threads = body["threads"] as? [[String: Any]] {
            let crashed = (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
                ?? threads.first { $0["triggered"] as? Bool == true }
            rawFrames = crashed?["frames"] as? [[String: Any]] ?? []
        } else {
            rawFrames = []
        }
        let frames = rawFrames.map { raw -> Frame in
            let index = raw["imageIndex"] as? Int
            let image = index.flatMap { images.indices.contains($0) ? images[$0] : nil }
            return Frame(
                image: image?["name"] as? String ?? "???",
                imagePath: image?["path"] as? String,
                imageBase: (image?["base"] as? NSNumber)?.uint64Value,
                imageUUID: (image?["uuid"] as? String)?.lowercased(),
                imageOffset: (raw["imageOffset"] as? NSNumber)?.uint64Value ?? 0,
                symbol: raw["symbol"] as? String,
                symbolLocation: raw["symbolLocation"] as? Int)
        }

        return CrashReport(
            processName: header["app_name"] as? String ?? header["name"] as? String
                ?? body["procName"] as? String ?? "?",
            bundleID: header["bundleID"] as? String,
            timestamp: (header["timestamp"] as? String).flatMap(parseTimestamp) ?? Date(),
            exceptionType: exceptionType,
            reasons: reasons,
            frames: frames,
            coalitionName: body["coalitionName"] as? String)
    }

    /// "2026-11-09 10:15:32.00 +0100"; the fraction's length varies, so it's dropped.
    static func parseTimestamp(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let time = parts[1].split(separator: ".").first ?? parts[1]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: "\(parts[0]) \(time) \(parts[2])")
    }

    /// The first `limit` frames as log lines: "0  FlightradarFree.debug.dylib  Foo.bar() + 12".
    func frameLines(limit: Int = 15) -> [String] {
        frames.prefix(limit).enumerated().map { number, frame in
            let location: String
            if let symbol = frame.symbol {
                location = frame.symbolLocation.map { "\(symbol) + \($0)" } ?? symbol
            } else if let address = frame.address {
                location = "0x" + String(address, radix: 16)
            } else {
                location = "+ \(frame.imageOffset)"
            }
            return "\(number)  \(frame.image)  \(location)"
        }
    }

    private static func json(_ text: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

/// Finds new crash reports of a deployed app on a device.
enum CrashReports {
    /// How many logged report keys a pipeline remembers.
    static let reportedLimit = 500

    /// Mac-side folder where this Mac and simulators write crash reports.
    static let macReportsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)

    /// Identifies one report on one device, so it's logged once however late it's found.
    static func key(device: Device, fileName: String) -> String {
        "\(device.id)/\((fileName as NSString).lastPathComponent)"
    }

    /// Reports are named "<executable>-<date>.ips" (a ".000" suffix for same-second duplicates).
    /// Resource reports ("<executable>.cpu_resource-<date>.ips") don't match the dash.
    static func isReport(fileName: String, of executable: String) -> Bool {
        let name = (fileName as NSString).lastPathComponent
        return name.hasPrefix("\(executable)-") && name.hasSuffix(".ips")
    }

    /// Crash files in a `devicectl device info files --json-output` listing that were written
    /// after `since` and aren't in `reported`.
    static func crashFiles(inListing data: Data, executable: String, device: Device,
                           since: Date, reported: Set<String>) -> [String] {
        struct Listing: Decodable {
            struct Result: Decodable { var files: [File] }
            struct File: Decodable {
                struct Metadata: Decodable {
                    var lastModDate: String?
                    var extendedAttributes: [String: String]?
                }
                var relativePath: String
                var metadata: Metadata?
            }
            var result: Result
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return [] }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return listing.result.files.compactMap { file in
            guard isReport(fileName: file.relativePath, of: executable),
                  !reported.contains(key(device: device, fileName: file.relativePath)),
                  file.metadata?.extendedAttributes?["bug_type"].map({ $0 == CrashReport.crashBugType }) ?? true,
                  let modified = file.metadata?.lastModDate.flatMap(dates.date(from:)),
                  modified > since
            else { return nil }
            return file.relativePath
        }
    }

    /// Crash reports of `executable` on `device` written after `since` and not in `reported`,
    /// oldest first, each with its local `.ips` (fetched into `folder` for physical devices) and
    /// its `key`. Errors, like a disconnected device, yield no reports: the next poll tries again.
    static func newReports(on device: Device, executable: String, since: Date, reported: Set<String>,
                           into folder: URL) async -> [(report: CrashReport, file: URL, key: String)] {
        let candidates: [URL]
        switch device.kind {
        case .physical:
            candidates = await fetchFromDevice(device, executable: executable, since: since,
                                               reported: reported, into: folder)
        case .simulator, .thisMac:
            candidates = macReports(of: executable, device: device, since: since, reported: reported)
        }
        return candidates
            .compactMap { url -> (report: CrashReport, file: URL, key: String)? in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let report = CrashReport.parse(text),
                      belongs(report, to: device)
                else { return nil }
                return (report, url, key(device: device, fileName: url.lastPathComponent))
            }
            .sorted { $0.report.timestamp < $1.report.timestamp }
    }

    /// Simulator crashes land in the same folder as this Mac's, tagged with the simulator's UDID.
    static func belongs(_ report: CrashReport, to device: Device) -> Bool {
        let coalition = report.coalitionName ?? ""
        switch device.kind {
        case .simulator: return coalition.contains(device.id)
        case .thisMac: return !coalition.contains("CoreSimulator")
        case .physical: return true
        }
    }

    private static func macReports(of executable: String, device: Device, since: Date,
                                   reported: Set<String>) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: macReportsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { url in
            guard isReport(fileName: url.lastPathComponent, of: executable),
                  !reported.contains(key(device: device, fileName: url.lastPathComponent))
            else { return false }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return modified.map { $0 > since } ?? true
        }
    }

    private static func fetchFromDevice(_ device: Device, executable: String, since: Date,
                                        reported: Set<String>, into folder: URL) async -> [URL] {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let listingURL = fileManager.temporaryDirectory
            .appendingPathComponent("orchard-crashlogs-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: listingURL) }
        do {
            try await Shell.xcrun(
                ["devicectl", "device", "info", "files", "--device", device.id,
                 "--domain-type", "systemCrashLogs", "--search", executable,
                 "--timeout", "30", "--quiet", "--json-output", listingURL.path])
        } catch {
            return []
        }
        guard let data = try? Data(contentsOf: listingURL) else { return [] }

        var copies: [URL] = []
        let sources = crashFiles(inListing: data, executable: executable, device: device,
                                 since: since, reported: reported)
        for source in sources {
            let destination = folder.appendingPathComponent((source as NSString).lastPathComponent)
            if !fileManager.fileExists(atPath: destination.path) {
                do {
                    try await Shell.xcrun(
                        ["devicectl", "device", "copy", "from", "--device", device.id,
                         "--domain-type", "systemCrashLogs", "--source", source,
                         "--destination", destination.path, "--timeout", "60", "--quiet"])
                } catch {
                    continue
                }
            }
            copies.append(destination)
        }
        return copies
    }

    /// Fills in symbols for frames in the deployed app's own binaries (the app executable and,
    /// in Debug builds, its `.debug.dylib`), which device crash reports leave as raw addresses.
    /// A binary is used only when its UUID matches the report's image, because the build folder
    /// may already hold a newer build. Best effort: unresolved frames stay as they were.
    static func symbolicate(_ report: CrashReport, app: URL) async -> CrashReport {
        let bundleName = app.lastPathComponent
        var result = report
        let unresolved = Dictionary(grouping: report.frames.indices.filter {
            report.frames[$0].symbol == nil && localBinary(for: report.frames[$0], app: app, bundleName: bundleName) != nil
        }) { report.frames[$0].image }

        for indices in unresolved.values {
            let first = report.frames[indices[0]]
            guard let binary = localBinary(for: first, app: app, bundleName: bundleName),
                  let base = first.imageBase,
                  let uuid = first.imageUUID,
                  let dump = try? await Shell.run("/usr/bin/dwarfdump", ["--uuid", binary.path]),
                  dwarfdumpUUIDs(dump).contains(uuid)
            else { continue }
            let addresses = indices.compactMap { report.frames[$0].address }.map { "0x" + String($0, radix: 16) }
            guard addresses.count == indices.count,
                  let output = try? await Shell.run(
                    "/usr/bin/atos", ["-o", binary.path, "-l", "0x" + String(base, radix: 16)] + addresses),
                  let symbols = atosSymbols(output, count: addresses.count)
            else { continue }
            for (index, symbol) in zip(indices, symbols) {
                guard let symbol else { continue }
                result.frames[index].symbol = symbol
                result.frames[index].symbolLocation = nil
            }
        }
        return result
    }

    /// UUIDs in `dwarfdump --uuid` output ("UUID: 4E98637A-… (arm64) /path"), lowercased.
    static func dwarfdumpUUIDs(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ")
            guard words.count >= 2, words[0] == "UUID:" else { return nil }
            return words[1].lowercased()
        })
    }

    /// One symbol per address from atos output, nil where atos echoed the address back.
    /// atos's stderr shares the pipe, so lines that are neither a symbol ("name (in Image)")
    /// nor an address are warnings and dropped; nil unless exactly `count` lines remain.
    static func atosSymbols(_ output: String, count: Int) -> [String?]? {
        let results = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(" (in ") || $0.hasPrefix("0x") }
        guard results.count == count else { return nil }
        return results.map { $0.hasPrefix("0x") ? nil : $0 }
    }

    /// The local file for a frame's image when it lives inside the deployed `.app`.
    private static func localBinary(for frame: CrashReport.Frame, app: URL, bundleName: String) -> URL? {
        guard let path = frame.imagePath, let range = path.range(of: "/\(bundleName)/") else { return nil }
        let local = app.appendingPathComponent(String(path[range.upperBound...]))
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }
}
