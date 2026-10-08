import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.migrateLegacyAPIKeyToKeychainIfNeeded()

        // 正常应用模式（非 accessory）- Dock 可见
        NSApp.setActivationPolicy(.regular)

        StatusBarController.shared.setup()

        KeyMonitorService.shared.onDoubleControlTap = { [weak self] in
            DispatchQueue.main.async {
                self?.handleDoubleControlTap()
            }
        }
        KeyMonitorService.shared.start()

        // 自动请求辅助功能权限
        requestAccessibilityIfNeeded()

        print("[App] ✅ IELTS生词本已启动")
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeyMonitorService.shared.stop()
    }

    // MARK: - 辅助功能权限请求

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let options: NSDictionary = [
                kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true
            ]
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func handleDoubleControlTap() {
        print("[App] 双击 Control 触发")

        guard let selectedText = TextSelectionService.shared.getSelectedText() else {
            print("[App] ⚠️ 未获取到选中文本")
            return
        }

        let word = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .prefix(5)
            .joined(separator: " ")

        guard !word.isEmpty else { return }

        print("[App] 查询: \"\(word)\"")
        let mousePoint = TextSelectionService.shared.getMouseLocation()

        // 立即显示加载弹窗，后台查词
        PopupWindowController.shared.showWithLoading(word: word, at: mousePoint)
    }
}
