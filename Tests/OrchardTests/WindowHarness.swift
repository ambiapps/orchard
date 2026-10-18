import AppKit
import SwiftUI
@testable import Orchard

/// Hosts a SwiftUI view in a real `NSWindow`, so tests can check the AppKit layout SwiftUI
/// produces (split views, toolbars) and render screenshots without Screen Recording permission.
@MainActor
final class WindowHarness {
    let window: NSWindow

    init(_ view: some View, size: NSSize, appearance: NSAppearance.Name? = nil) {
        _ = NSApplication.shared
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.appearance = appearance.flatMap(NSAppearance.init(named:))
        window.setContentSize(size)
        window.orderFrontRegardless()
        settle()
    }

    /// Lets SwiftUI and AppKit finish layout passes and updates.
    func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    var contentWidth: CGFloat { window.contentLayoutRect.maxX }

    /// Every `NSSplitView` in the window, outermost first.
    var splitViews: [NSSplitView] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(window.contentView!).compactMap { $0 as? NSSplitView }
    }

    /// Renders the window, title bar included. Materials drawn by the window server (the
    /// Liquid Glass sidebar) come out blank.
    func snapshot(to url: URL) throws {
        let view = window.contentView!.superview!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    func close() { window.close() }
}

/// An in-memory `AppStore` without device discovery: tests never see or change the user's
/// pipelines, write nothing to disk, and don't depend on the host's devices.
@MainActor
func makeTestStore(pipelines: Int = 1) -> AppStore {
    let store = AppStore(defaults: nil, discoversDevices: false)
    for _ in 0..<pipelines { store.addPipeline() }
    return store
}
