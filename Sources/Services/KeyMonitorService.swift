import AppKit

/// 全局按键监控 - 双击 Control 键触发
/// 使用 keyDown + flagsChanged 双通道
final class KeyMonitorService {
    static let shared = KeyMonitorService()

    var onDoubleControlTap: (() -> Void)?

    private var keyMonitor: Any?
    private var flagMonitor: Any?
    private var lastControlPressTime: Date?
    private var lastTriggerTime: Date = .distantPast
    private let doubleTapInterval: TimeInterval
    private let controlKeyCodes: Set<Int> = [59, 62]

    private init() {
        doubleTapInterval = Config.doubleTapInterval
    }

    func start() {
        guard keyMonitor == nil else { return }

        // 主通道：keyDown 监听 Control 键码
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.controlKeyCodes.contains(Int(event.keyCode)) == true {
                self?.handleControlPress()
            }
        }

        // 备用：flagsChanged 监听 modifier 变化
        flagMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if event.modifierFlags.contains(.control) {
                self?.handleControlPress()
            }
        }

        // 本地事件
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.controlKeyCodes.contains(Int(event.keyCode)) == true {
                self?.handleControlPress()
            }
            return event
        }

        print("[KeyMonitor] ✅ 已启动 (keyDown + flagsChanged)")
    }

    func stop() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = flagMonitor { NSEvent.removeMonitor(m); flagMonitor = nil }
    }

    private func handleControlPress() {
        let now = Date()

        // 防抖：300ms 内不重复
        guard now.timeIntervalSince(lastTriggerTime) > 0.3 else { return }

        if let last = lastControlPressTime,
           now.timeIntervalSince(last) < doubleTapInterval {
            // 双击！
            lastTriggerTime = now
            lastControlPressTime = nil
            print("[KeyMonitor] ✅✅ 双击 Control！")
            DispatchQueue.main.async { [weak self] in
                self?.onDoubleControlTap?()
            }
        } else {
            lastControlPressTime = now
        }
    }
}
