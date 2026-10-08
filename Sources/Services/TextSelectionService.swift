import AppKit

/// 文本选中获取服务 - 通过模拟 Cmd+C 复制到剪贴板
final class TextSelectionService {
    static let shared = TextSelectionService()

    private init() {}

    private var isCapturingText = false

    /// 通过模拟 Cmd+C 获取当前选中文本
    func getSelectedText() -> String? {
        // 防止双通道按键事件或诊断操作重入，覆盖尚未恢复的剪贴板快照。
        guard !isCapturingText else { return nil }

        let pasteboard = NSPasteboard.general

        // 1. 深拷贝当前剪贴板。pasteboardItems 返回的实例仍绑定原
        // pasteboard，清空后不能把同一实例直接 writeObjects 回去。
        guard let savedItems = snapshotPasteboardItems(from: pasteboard) else {
            print("[TextSelection] ⚠️ 无法完整保存剪贴板，本次查词已取消")
            return nil
        }
        isCapturingText = true

        // 2. 清空剪贴板
        pasteboard.clearContents()
        let copyStartChangeCount = pasteboard.changeCount

        // 3. 模拟 Cmd+C
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        cmdDown?.flags = .maskCommand
        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        // 4. 等待复制完成
        Thread.sleep(forTimeInterval: 0.15)

        // 5. 检查是否复制了新内容
        guard pasteboard.changeCount != copyStartChangeCount else {
            restorePasteboard(savedItems, ifUnchangedSince: copyStartChangeCount)
            return nil
        }

        let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let copiedChangeCount = pasteboard.changeCount

        // 6. 恢复剪贴板（延迟）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.restorePasteboard(savedItems, ifUnchangedSince: copiedChangeCount)
        }

        guard let text = text, !text.isEmpty, text.count <= 80 else {
            return nil
        }

        return text
    }

    /// 为每个 item 的全部类型创建未绑定 pasteboard 的独立副本。
    /// 任一类型无法复制时取消本次查词，避免损坏用户原剪贴板。
    private func snapshotPasteboardItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        guard let originalItems = pasteboard.pasteboardItems else { return [] }

        var snapshots: [NSPasteboardItem] = []
        snapshots.reserveCapacity(originalItems.count)

        for original in originalItems {
            guard !original.types.isEmpty else { return nil }

            let snapshot = NSPasteboardItem()
            for type in original.types {
                guard let data = original.data(forType: type),
                      snapshot.setData(data, forType: type) else {
                    return nil
                }
            }
            snapshots.append(snapshot)
        }

        return snapshots
    }

    private func restorePasteboard(
        _ savedItems: [NSPasteboardItem],
        ifUnchangedSince expectedChangeCount: Int
    ) {
        let pasteboard = NSPasteboard.general

        // 若用户在延迟期间主动复制了其他内容，不覆盖用户的新剪贴板。
        if pasteboard.changeCount == expectedChangeCount {
            pasteboard.clearContents()
            if !savedItems.isEmpty, !pasteboard.writeObjects(savedItems) {
                print("[TextSelection] ⚠️ 剪贴板恢复失败")
            }
        }

        isCapturingText = false
    }

    /// 获取当前鼠标位置
    func getMouseLocation() -> NSPoint {
        NSEvent.mouseLocation
    }
}
