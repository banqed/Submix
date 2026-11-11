import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let mixer = MainActor.assumeIsolated { Mixer() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: ContentView(m: mixer))
        host.sizingOptions = [.minSize, .maxSize]
        let w = ClassicWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }

    /// Dropping the taps hands every app back to its normal output.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { mixer.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SubmixApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
