import Foundation
import Testing
@testable import Orchard

struct CrashReportsTests {
    /// The shape of an iOS 27 `.ips` crash report, trimmed to the fields Orchard reads.
    static func ips(bugType: String = "309", lastExceptionBacktrace: String = "null",
                    coalition: String = "se.resenatverket.FlightRadar24-Free") -> String {
        """
        {"app_name":"FlightradarFree","timestamp":"2026-11-09 10:41:02.00 +0100","bug_type":"\(bugType)","bundleID":"se.resenatverket.FlightRadar24-Free","name":"FlightradarFree"}
        {
          "procName" : "FlightradarFree",
          "coalitionName" : "\(coalition)",
          "exception" : {"codes":"0x0000000000000001, 0x0000000000000000","type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
          "termination" : {"namespace":"SIGNAL","indicator":"Segmentation fault: 11","code":11},
          "asi" : {"libswiftCore.dylib":["Fatal error: Unexpectedly found nil while unwrapping an Optional value"]},
          "faultingThread" : 1,
          "lastExceptionBacktrace" : \(lastExceptionBacktrace),
          "threads" : [
            {"id":1,"frames":[{"imageOffset":10,"imageIndex":1}]},
            {"id":2,"triggered":true,"frames":[
              {"imageOffset":4096,"imageIndex":0},
              {"imageOffset":1054996,"symbol":"_assertionFailure(_:_:file:line:flags:)","symbolLocation":208,"imageIndex":1}
            ]}
          ],
          "usedImages" : [
            {"base":4294967296,"uuid":"4E98637A-8420-307A-8118-63D18BDCD4B3","name":"FlightradarFree.debug.dylib","path":"/private/var/containers/Bundle/Application/X/FlightradarFree.app/FlightradarFree.debug.dylib"},
            {"base":6442450944,"name":"libswiftCore.dylib","path":"/usr/lib/swift/libswiftCore.dylib"}
          ]
        }
        """
    }

    @Test func parsesCrashedThread() throws {
        let report = try #require(CrashReport.parse(Self.ips()))
        #expect(report.processName == "FlightradarFree")
        #expect(report.bundleID == "se.resenatverket.FlightRadar24-Free")
        #expect(report.exceptionType == "EXC_BAD_ACCESS (SIGSEGV)")
        #expect(report.reasons == ["Fatal error: Unexpectedly found nil while unwrapping an Optional value"])
        #expect(report.timestamp == Date(timeIntervalSince1970: 1_794_217_262))
        #expect(report.frameLines() == [
            "0  FlightradarFree.debug.dylib  0x100001000",
            "1  libswiftCore.dylib  _assertionFailure(_:_:file:line:flags:) + 208",
        ])
        #expect(report.frames[0].imageUUID == "4e98637a-8420-307a-8118-63d18bdcd4b3")
        #expect(report.frames[0].imagePath?.hasSuffix("FlightradarFree.app/FlightradarFree.debug.dylib") == true)
    }

    @Test func prefersLastExceptionBacktrace() throws {
        let backtrace = #"[{"imageOffset":8,"symbol":"objc_exception_throw","symbolLocation":60,"imageIndex":1}]"#
        let report = try #require(CrashReport.parse(Self.ips(lastExceptionBacktrace: backtrace)))
        #expect(report.frameLines() == ["0  libswiftCore.dylib  objc_exception_throw + 60"])
    }

    @Test func fallsBackToTerminationIndicator() throws {
        let text = Self.ips().replacingOccurrences(
            of: #""asi" : {"libswiftCore.dylib":["Fatal error: Unexpectedly found nil while unwrapping an Optional value"]},"#,
            with: "")
        let report = try #require(CrashReport.parse(text))
        #expect(report.reasons == ["Segmentation fault: 11"])
    }

    @Test func ignoresReportsThatAreNotCrashes() {
        #expect(CrashReport.parse(Self.ips(bugType: "202")) == nil)
        #expect(CrashReport.parse("not a report") == nil)
    }

    @Test func matchesReportFileNames() {
        #expect(CrashReports.isReport(fileName: "FlightradarFree-2026-11-09-104102.ips", of: "FlightradarFree"))
        #expect(CrashReports.isReport(fileName: "Retired/FlightradarFree-2026-11-09-104102.000.ips", of: "FlightradarFree"))
        #expect(!CrashReports.isReport(fileName: "FlightradarFree.cpu_resource-2026-11-09-104102.ips", of: "FlightradarFree"))
        #expect(!CrashReports.isReport(fileName: "FlightradarFreeWidget-2026-11-09-104102.ips", of: "FlightradarFree"))
        #expect(!CrashReports.isReport(fileName: "FlightradarFree-2026-11-09-104102.diag", of: "FlightradarFree"))
    }

    @Test func picksNewCrashFilesFromDeviceListing() {
        let listing = """
        {"result":{"files":[
          {"relativePath":"FlightradarFree-2026-11-09-104102.ips",
           "metadata":{"lastModDate":"2026-11-09T09:41:03.000Z","extendedAttributes":{"bug_type":"309"}}},
          {"relativePath":"FlightradarFree-2026-11-08-104102.ips",
           "metadata":{"lastModDate":"2026-11-08T09:41:03.000Z","extendedAttributes":{"bug_type":"309"}}},
          {"relativePath":"FlightradarFree.cpu_resource-2026-11-09-104102.ips",
           "metadata":{"lastModDate":"2026-11-09T09:41:03.000Z","extendedAttributes":{"bug_type":"202"}}},
          {"relativePath":"FlightradarFree-2026-11-09-104500.ips",
           "metadata":{"lastModDate":"2026-11-09T09:45:00.000Z","extendedAttributes":{"bug_type":"298"}}}
        ]}}
        """
        let since = Date(timeIntervalSince1970: 1_794_217_200) // 2026-11-09 09:40:00 UTC
        #expect(CrashReports.crashFiles(inListing: Data(listing.utf8), executable: "FlightradarFree",
                                        device: Self.phone, since: since, reported: [])
            == ["FlightradarFree-2026-11-09-104102.ips"])
    }

    static let phone = Device(id: "00008120-000118363C10A01E", name: "Nokia 5120", model: "iPhone 15",
                              kind: .physical, platform: .iOS, osVersion: "27.0")

    /// Reports are deduplicated by file, not by time, so a report found late (device asleep,
    /// report still being written) is still logged, and one already logged never is again.
    @Test func skipsReportsAlreadyLoggedButNotLateOnes() {
        let listing = """
        {"result":{"files":[
          {"relativePath":"FlightradarFree-2026-11-09-104102.ips",
           "metadata":{"lastModDate":"2026-11-09T09:41:03.000Z","extendedAttributes":{"bug_type":"309"}}},
          {"relativePath":"FlightradarFree-2026-11-09-104102.000.ips",
           "metadata":{"lastModDate":"2026-11-09T09:41:03.000Z","extendedAttributes":{"bug_type":"309"}}},
          {"relativePath":"FlightradarFree-2026-11-09-105000.ips",
           "metadata":{"lastModDate":"2026-11-09T09:50:00.000Z","extendedAttributes":{"bug_type":"309"}}}
        ]}}
        """
        let since = Date(timeIntervalSince1970: 1_794_217_200)
        let reported: Set = [CrashReports.key(device: Self.phone, fileName: "FlightradarFree-2026-11-09-105000.ips")]
        #expect(CrashReports.crashFiles(inListing: Data(listing.utf8), executable: "FlightradarFree",
                                        device: Self.phone, since: since, reported: reported)
            == ["FlightradarFree-2026-11-09-104102.ips", "FlightradarFree-2026-11-09-104102.000.ips"])
    }

    @Test func keysReportsPerDevice() {
        #expect(CrashReports.key(device: Self.phone, fileName: "Retired/App-2026-11-09-104102.ips")
            == "00008120-000118363C10A01E/App-2026-11-09-104102.ips")
        #expect(CrashReports.key(device: .thisMac, fileName: "App-2026-11-09-104102.ips")
            != CrashReports.key(device: Self.phone, fileName: "App-2026-11-09-104102.ips"))
    }

    @Test func mapsAtosOutputToFramesIgnoringWarnings() {
        let output = """
        atos[123]: warning: unable to load symbols for some image
        MapViewController.viewDidLoad() (in FlightradarFree.debug.dylib) (MapViewController.swift:42)
        0x100002000
        """
        #expect(CrashReports.atosSymbols(output, count: 2) == [
            "MapViewController.viewDidLoad() (in FlightradarFree.debug.dylib) (MapViewController.swift:42)", nil,
        ])
        #expect(CrashReports.atosSymbols(output, count: 3) == nil)
    }

    @Test func readsUUIDsFromDwarfdump() {
        let output = """
        UUID: 4E98637A-8420-307A-8118-63D18BDCD4B3 (arm64) /path/FlightradarFree.debug.dylib
        UUID: D753CBA8-F4ED-3813-B91C-C6F04918FCF4 (x86_64) /path/FlightradarFree.debug.dylib
        """
        #expect(CrashReports.dwarfdumpUUIDs(output)
            == ["4e98637a-8420-307a-8118-63d18bdcd4b3", "d753cba8-f4ed-3813-b91c-c6f04918fcf4"])
    }

    @Test func attributesSimulatorCrashesByUDID() throws {
        let udid = "4503BD85-30F2-4249-AFBA-96E81EA1CE6C"
        let simulatorCrash = try #require(CrashReport.parse(
            Self.ips(coalition: "com.apple.CoreSimulator.SimDevice.\(udid)")))
        let simulator = Device(id: udid, name: "iPad", model: "iPad", kind: .simulator,
                               platform: .iOSSimulator, osVersion: "27.2")
        let other = Device(id: "OTHER", name: "iPhone", model: "iPhone", kind: .simulator,
                           platform: .iOSSimulator, osVersion: "27.2")
        #expect(CrashReports.belongs(simulatorCrash, to: simulator))
        #expect(!CrashReports.belongs(simulatorCrash, to: other))
        #expect(!CrashReports.belongs(simulatorCrash, to: .thisMac))
    }
}
