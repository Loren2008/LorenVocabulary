import AppKit

/// 状态栏控制器 - 菜单栏图标 + 菜单
final class StatusBarController {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem!
    private var loadingIndicator: NSProgressIndicator?
    private var countTimer: Timer?

    // 菜单项引用（用于实时刷新）
    private weak var wordCountItem: NSMenuItem?
    private weak var dbCountItem: NSMenuItem?
    private weak var fullCountItem: NSMenuItem?

    private init() {}

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "character.book.closed.fill",
                accessibilityDescription: "IELTS生词本"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let wcItem = NSMenuItem(
            title: "",
            action: nil,
            keyEquivalent: ""
        )
        wcItem.target = self
        wordCountItem = wcItem
        menu.addItem(wcItem)

        let dcItem = NSMenuItem(
            title: "",
            action: nil,
            keyEquivalent: ""
        )
        dcItem.target = self
        dcItem.isEnabled = false
        dbCountItem = dcItem
        menu.addItem(dcItem)

        let fcItem = NSMenuItem(
            title: "",
            action: nil,
            keyEquivalent: ""
        )
        fcItem.target = self
        fcItem.isEnabled = false
        fullCountItem = fcItem
        menu.addItem(fcItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "打开生词本",
            action: #selector(openVocabList),
            keyEquivalent: "v"
        )
        openItem.target = self
        menu.addItem(openItem)

        let testItem = NSMenuItem(
            title: "查词测试",
            action: #selector(testLookup),
            keyEquivalent: "t"
        )
        testItem.target = self
        menu.addItem(testItem)

        let diagItem = NSMenuItem(
            title: "🔍 诊断",
            action: #selector(runDiagnostic),
            keyEquivalent: "d"
        )
        diagItem.target = self
        menu.addItem(diagItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "关于 IELTS生词本",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        // 辅助功能权限引导：自签名 app 的 AXIsProcessTrusted() 始终返回 false
        // 但不影响功能（实际使用 Cmd+C 模拟复制），所以不显示这个误导性提示
        menu.addItem(.separator())

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshCounts()

        // 每 3 秒刷新菜单栏数字
        countTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshCounts()
        }
        countTimer?.tolerance = 1.0
    }

    private func refreshCounts() {
        wordCountItem?.title = "生词本: \(StorageService.shared.wordCount()) 个"
        dbCountItem?.title = "离线词典: \(DatabaseService.shared.count()) 词"
        fullCountItem?.title = "完整数据: \(DatabaseService.shared.fullCount()) 词（释义+例句+搭配）"
    }

    func updateWordCount() {
        refreshCounts()
    }

    /// 显示加载状态
    func showLoading() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "hourglass",
                accessibilityDescription: "查询中..."
            )
        }
    }

    func showNormal() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "character.book.closed.fill",
                accessibilityDescription: "IELTS生词本"
            )
            button.image?.isTemplate = true
        }
    }

    // MARK: - Actions

    @objc private func openVocabList() {
        VocabListWindowController.shared.show()
    }

    @objc private func testLookup() {
        // 可用于测试查词
        print("[StatusBar] 测试查词...")
    }

    @objc private func runDiagnostic() {
        let trusted = AXIsProcessTrusted()
        let wordCount = StorageService.shared.wordCount()
        let bundlePath = Bundle.main.bundlePath
        let bundleID = Bundle.main.bundleIdentifier ?? "nil"

        let text = """
        Bundle: \(bundlePath)
        Bundle ID: \(bundleID)
        AXIsProcessTrusted: \(trusted)
        生词数量: \(wordCount)
        """

        if let selected = TextSelectionService.shared.getSelectedText() {
            print("[Diagnostic] 选中文本: \"\(selected)\"")
        } else {
            print("[Diagnostic] 未获取到选中文本")
        }

        let alert = NSAlert()
        alert.messageText = "Diagnostic Report"
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "IELTS 生词本 v1.0"
        alert.informativeText = """
        专为雅思备考（目标7.5分）设计的高效生词本工具。

        功能：
        · 选中单词/词组 → 双击 Control 键查词
        · 牛津词典 + DeepSeek AI 智能精简释义
        · IELTS 语境例句（来源清晰标注）
        · 词组/俚语/正式用语全覆盖
        · 单词发音 + 配图记忆

        键盘快捷键：双击 Control 查词
        """
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func requestAccessibilityPermission() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true
        ]
        AXIsProcessTrustedWithOptions(options)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
