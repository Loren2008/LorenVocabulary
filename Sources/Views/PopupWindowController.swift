import SwiftUI
import AppKit

/// 弹窗控制器 - 划词释义弹窗
final class PopupWindowController {
    static let shared = PopupWindowController()

    private var panel: NSPanel?
    private var word: String = ""

    private init() {}

    /// 立即显示弹窗（数据库→缓存→系统词典→网络，逐级回退）
    func showWithLoading(word: String, at point: NSPoint) {
        let databaseLookupValue = word
        let word = WordNormalizer.normalize(word)
        guard !word.isEmpty else { return }

        dismiss()
        self.word = word

        // 0. SQLite 数据库（预构建词典，微秒级）
        // 传入原选区，让数据库可以先尝试 `.NET` / `C++` 等保留
        // 合法边界符号的 canonical 键，再使用剔除包装标点的回退键。
        if let entry = DatabaseService.shared.lookup(databaseLookupValue) {
            showEntry(entry, at: point)

            // 仅在数据库没有 IELTS 数据时，才异步去 DeepSeek 补全
            if entry.ieltsExamples?.isEmpty != false {
                DictionaryService.shared.enrichWithIELTS(word: word) { [weak self] examples in
                    guard let self = self, !examples.isEmpty else { return }
                    self.updateIELTS(examples: examples)
                }
            }
            return
        }

        // 1. JSON 缓存（毫秒级）
        if let cached = LocalCacheService.shared.get(word) {
            showEntry(cached, at: point)
            DictionaryService.shared.enrichWithIELTS(word: word) { [weak self] examples in
                guard let self = self, !examples.isEmpty else { return }
                self.updateIELTS(examples: examples)
            }
            return
        }

        // 3. macOS 内置词典（同步，毫秒级，离线）
        if let rawDef = MacDictionaryService.shared.lookup(word) {
            let defs = MacDictionaryService.shared.parseDefinitions(from: rawDef)
            if !defs.isEmpty {
                let entry = DictionaryEntry(word: word, phonetic: nil, audioURL: nil,
                                             definitions: defs, phrases: [], source: "oxford")
                LocalCacheService.shared.cache(entry)
                showEntry(entry, at: point)

                // 后台 DeepSeek 增强中文翻译 + IELTS
                DictionaryService.shared.enrichWithIELTS(word: word) { [weak self] _ in
                    DispatchQueue.main.async {
                        if let updated = LocalCacheService.shared.get(word) {
                            self?.refreshEntry(updated)
                        }
                    }
                }
                return
            }
        }

        // 3. 缓存和系统词典都不行 → 显示加载 + 网络查词
        let loadingView = PopupLoadingView(word: word, onClose: { [weak self] in
            self?.dismiss()
        })
        show(hostingView: NSHostingView(rootView: loadingView), at: point)

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let entry = try await DictionaryService.shared.lookup(word)
                await MainActor.run {
                    self.showEntry(entry, at: point)
                }
                // 已由 lookup 内部调用 DeepSeek，不需要再单独补全
            } catch {
                await MainActor.run {
                    self.showError(word: word, error: error, at: point)
                }
            }
        }
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }

    // MARK: - IELTS 风格例句补全（缓存命中后异步追加）

    private func updateIELTS(examples: [DictionaryEntry.IELTSExample]) {
        guard let updatedEntry = LocalCacheService.shared.get(word) else { return }
        refreshEntry(updatedEntry)
    }

    private func refreshEntry(_ entry: DictionaryEntry) {
        guard let panel = panel else { return }
        let currentFrame = panel.frame

        let contentView = PopupView(
            entry: entry,
            onSave: { [weak self] in self?.saveWord(entry) },
            onClose: { [weak self] in self?.dismiss() },
            onPlayAudio: {
                if let url = entry.audioURL, !url.isEmpty {
                    Task { await AudioService.shared.playAudio(from: url) }
                } else {
                    AudioService.shared.speak(entry.word, phonetic: entry.phonetic)
                }
            }
        )

        let hosting = NSHostingView(rootView: contentView)
        hosting.frame.size = hosting.fittingSize

        let newSize = hosting.fittingSize
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + currentFrame.height - newSize.height,
            width: newSize.width,
            height: newSize.height
        )

        panel.contentView = hosting
        panel.setFrame(newFrame, display: true, animate: true)
    }

    // MARK: - Private

    private func showEntry(_ entry: DictionaryEntry, at point: NSPoint) {
        let contentView = PopupView(
            entry: entry,
            onSave: { [weak self] in
                self?.saveWord(entry)
            },
            onClose: { [weak self] in
                self?.dismiss()
            },
            onPlayAudio: {
                if let audioURL = entry.audioURL, !audioURL.isEmpty {
                    Task { await AudioService.shared.playAudio(from: audioURL) }
                } else {
                    AudioService.shared.speak(entry.word, phonetic: entry.phonetic)
                }
            }
        )

        let hosting = NSHostingView(rootView: contentView)
        let size = hosting.fittingSize

        // 尝试复用现有 panel 的框架
        if let existingPanel = panel {
            panel?.contentView = hosting
            let currentFrame = existingPanel.frame
            let newFrame = NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y + currentFrame.height - size.height - 60,
                width: size.width,
                height: size.height + 60
            )
            existingPanel.setFrame(newFrame, display: true, animate: true)
        } else {
            show(hostingView: hosting, at: point)
        }
    }

    private func showError(word: String, error: Error, at point: NSPoint) {
        let errorView = PopupErrorView(word: word, error: error.localizedDescription, onClose: { [weak self] in
            self?.dismiss()
        })
        let hosting = NSHostingView(rootView: errorView)
        show(hostingView: hosting, at: point)
    }

    private func show(hostingView: NSHostingView<some View>, at point: NSPoint) {
        let size = hostingView.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(x: point.x, y: point.y - size.height - 10, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        adjustPosition(panel, preferredPoint: point, size: size)
        hostingView.frame.size = size

        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func saveWord(_ entry: DictionaryEntry) {
        let saved = SavedWord(
            word: entry.word,
            phonetic: entry.phonetic,
            definitions: entry.definitions.map {
                SavedWord.SavedDefinition(partOfSpeech: $0.partOfSpeech, meaning: $0.meaning, example: $0.example)
            },
            phrases: entry.phrases.isEmpty ? nil : entry.phrases,
            ieltsExamples: entry.ieltsExamples,
            imageURL: entry.imageURL,
            savedAt: Date()
        )
        StorageService.shared.saveWord(saved)
        StatusBarController.shared.updateWordCount()
    }

    private func adjustPosition(_ panel: NSPanel, preferredPoint: NSPoint, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        var x = preferredPoint.x
        var y = preferredPoint.y - size.height - 10

        if x + size.width > screenFrame.maxX {
            x = screenFrame.maxX - size.width - 10
        }
        if x < screenFrame.minX { x = screenFrame.minX + 10 }

        if y < screenFrame.minY {
            y = preferredPoint.y + 30
        }
        if y + size.height > screenFrame.maxY {
            y = screenFrame.maxY - size.height - 10
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - 加载中视图

struct PopupLoadingView: View {
    let word: String
    var onClose: () -> Void

    @State private var dots = 0
    let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(word)
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ProgressView()
                .scaleEffect(0.8)

            Text("牛津词典 · DeepSeek AI 查询中\(String(repeating: ".", count: (dots % 3) + 1))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .onReceive(timer) { _ in dots += 1 }

            Text("IELTS生词本 · developed by Loren")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.5))
                .padding(.bottom, 4)
        }
        .frame(width: 300)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
    }
}

// MARK: - 错误视图

struct PopupErrorView: View {
    let word: String
    let error: String
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("查询失败")
                    .font(.system(size: 16, weight: .semibold))

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Text("\"\(word)\"")
                .font(.system(size: 15, weight: .medium))

            Text(error)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer().frame(height: 8)
        }
        .frame(width: 300)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
    }
}
