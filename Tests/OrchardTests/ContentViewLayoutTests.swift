import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Orchard

@MainActor
struct ContentViewLayoutTests {
    private func makeWindow(width: CGFloat, appearance: NSAppearance.Name? = nil,
                            store: AppStore = makeTestStore()) -> WindowHarness {
        let view = ContentView()
            .environment(store)
            .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
        return WindowHarness(view, size: NSSize(width: width, height: 700), appearance: appearance)
    }

    @Test func usesOneSplitViewForAllColumns() throws {
        let harness = makeWindow(width: 1000)
        defer { harness.close() }
        let split = try #require(harness.splitViews.first)
        #expect(split.isVertical)
        #expect(split.arrangedSubviews.count == 3)
        // A nested horizontal split view in a column is what let the sidebar push it off-window.
        #expect(!harness.splitViews.dropFirst().contains { $0.isVertical })
    }

    /// Dragging the sidebar wider used to grow the detail column past the window's edge.
    @Test(arguments: [Layout.windowMinWidth, 1000, 1400], [0, 360, 700, 5000])
    func resizingSidebarKeepsColumnsInsideWindow(windowWidth: CGFloat, sidebarDrag: CGFloat) throws {
        try checkSidebarResize(windowWidth: windowWidth, sidebarDrag: sidebarDrag, store: makeTestStore())
    }

    /// With nothing selected the activity column is empty, and must still keep its minimum width.
    @Test(arguments: [Layout.windowMinWidth, 1000], [360, 5000])
    func resizingSidebarWithoutPipelinesKeepsColumnsInsideWindow(windowWidth: CGFloat, sidebarDrag: CGFloat) throws {
        try checkSidebarResize(windowWidth: windowWidth, sidebarDrag: sidebarDrag, store: makeTestStore(pipelines: 0))
    }

    private func checkSidebarResize(windowWidth: CGFloat, sidebarDrag: CGFloat, store: AppStore) throws {
        let harness = makeWindow(width: windowWidth, store: store)
        defer { harness.close() }
        let split = try #require(harness.splitViews.first)

        split.setPosition(sidebarDrag, ofDividerAt: 0)
        harness.settle()

        let frame = split.convert(split.bounds, to: nil)
        #expect(frame.minX >= -0.5)
        #expect(frame.maxX <= harness.contentWidth + 0.5)

        let columns = split.arrangedSubviews.map(\.frame)
        try #require(columns.count == 3)
        let (sidebar, settings, activity) = (columns[0], columns[1], columns[2])
        #expect(activity.maxX <= split.bounds.maxX + 0.5)
        // Dragging the divider all the way left collapses the sidebar, which keeps its old frame.
        let sidebarCollapsed = split.isSubviewCollapsed(split.arrangedSubviews[0])
        if !sidebarCollapsed {
            #expect(sidebar.width >= Layout.sidebarMin - 0.5)
            #expect(sidebar.width <= Layout.sidebarMax + 0.5)
        }
        // The settings column runs under the floating sidebar; its visible part must keep its minimum.
        let visibleSettings = settings.maxX - (sidebarCollapsed ? 0 : sidebar.maxX)
        #expect(visibleSettings >= Layout.settingsMin - 0.5)
        #expect(activity.width >= Layout.activityMin - 0.5)
    }

    /// Writes screenshots for PR descriptions: `ORCHARD_SCREENSHOTS=<dir> swift test --filter screenshots`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORCHARD_SCREENSHOTS"] != nil))
    func screenshots() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORCHARD_SCREENSHOTS"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (state, drag) in [("default", CGFloat(0)), ("sidebar-wide", 5000)] {
                let store = makeTestStore()
                let harness = makeWindow(width: 1100, appearance: appearance, store: store)
                defer { harness.close() }
                // The app's `Window` scene sets the title from `navigationTitle`; a bare window doesn't.
                harness.window.title = store.pipelines[0].config.name
                if drag > 0 {
                    harness.splitViews.first?.setPosition(drag, ofDividerAt: 0)
                    harness.settle()
                }
                try harness.snapshot(to: directory.appendingPathComponent("\(state)-\(name).png"))
            }
        }
    }
}
