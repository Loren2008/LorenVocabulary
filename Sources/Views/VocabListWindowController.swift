import SwiftUI
import AppKit

/// 生词本窗口控制器
final class VocabListWindowController {
    static let shared = VocabListWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = VocabListView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame.size = NSSize(width: 740, height: 520)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        win.title = "IELTS 生词本"
        win.contentView = hostingView
        win.center()
        win.setFrameAutosaveName("VocabListWindow")
        win.isReleasedWhenClosed = false
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func toggle() {
        if let win = window, win.isVisible {
            win.close()
        } else {
            show()
        }
    }
}
