import SwiftUI

/// 划词释义弹窗视图
struct PopupView: View {
    let entry: DictionaryEntry
    var onSave: () -> Void
    var onClose: () -> Void
    var onPlayAudio: () -> Void

    @State private var selectedTab = 0
    @State private var imageData: Data?
    @State private var isSaved: Bool

    init(entry: DictionaryEntry, onSave: @escaping () -> Void, onClose: @escaping () -> Void, onPlayAudio: @escaping () -> Void) {
        self.entry = entry
        self.onSave = onSave
        self.onClose = onClose
        self.onPlayAudio = onPlayAudio
        self._isSaved = State(initialValue: StorageService.shared.wordExists(entry.word))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            headerBar

            Divider()

            // 内容
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    // 配图
                    if let data = imageData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 140)
                            .clipped()
                            .cornerRadius(8)
                    }

                    // 释义区
                    definitionsSection

                    // 词组区
                    if !entry.phrases.isEmpty {
                        phrasesSection
                    }

                    // IELTS 例句区
                    if let ielts = entry.ieltsExamples, !ielts.isEmpty {
                        ieltsSection(ielts)
                    }
                }
                .padding(12)
                .padding(.bottom, 16)
            }

            Divider()

            // 底部操作栏
            bottomBar
        }
        .frame(width: 380)
        .frame(minHeight: 200, maxHeight: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        .task {
            await loadImage()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(entry.word)
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                if let phonetic = entry.phonetic, !phonetic.isEmpty {
                    Text("/\(phonetic)/")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                if entry.phonetic != nil || entry.audioURL != nil {
                    Button(action: onPlayAudio) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("播放发音")
                }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }

            Text("IELTS生词本 · developed by Loren")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.5))
    }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Definitions

    private var definitionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("释义")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Text(entry.source.hasPrefix("deepseek")
                     ? "(离线 AI 词条)"
                     : "(Oxford · DeepSeek 精简)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            ForEach(entry.definitions) { def in
                definitionRow(def)
            }
        }
    }

    private func definitionRow(_ def: DictionaryEntry.Definition) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(def.partOfSpeech)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(def.meaning)
                    .font(.system(size: 14))
                    .lineLimit(nil)

                if let example = def.example, !example.isEmpty {
                    Text(example)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Phrases

    private var phrasesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("词组 / 搭配")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            ForEach(entry.phrases) { phrase in
                HStack(alignment: .top, spacing: 6) {
                    phraseTypeBadge(phrase.type)

                    Text(phrase.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text("—")
                        .foregroundColor(.secondary)

                    Text(phrase.meaning)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)

                    Spacer()
                }
            }
        }
    }

    private func phraseTypeBadge(_ type: DictionaryEntry.PhraseItem.PhraseType) -> some View {
        Text(typeLabel(type))
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(typeColor(type))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(typeColor(type).opacity(0.12))
            .cornerRadius(4)
    }

    private func typeLabel(_ type: DictionaryEntry.PhraseItem.PhraseType) -> String {
        switch type {
        case .formal: return "正式"
        case .slang: return "俚语"
        case .idiom: return "习语"
        case .phrasalVerb: return "动词短语"
        case .collocation: return "搭配"
        }
    }

    private func typeColor(_ type: DictionaryEntry.PhraseItem.PhraseType) -> Color {
        switch type {
        case .formal: return .blue
        case .slang: return .orange
        case .idiom: return .purple
        case .phrasalVerb: return .green
        case .collocation: return .teal
        }
    }

    // MARK: - IELTS Examples

    private func ieltsSection(_ examples: [DictionaryEntry.IELTSExample]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("IELTS 例句")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            ForEach(examples) { example in
                VStack(alignment: .leading, spacing: 4) {
                    Text(example.sentence)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)

                    HStack(spacing: 4) {
                        Text(example.source)
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)

                        if let year = example.year {
                            Text("·")
                                .foregroundColor(.secondary)
                            Text(year)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.05))
                .cornerRadius(6)
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // 来源标记
            Text(sourceLabel)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))

            Spacer()

            // 保存按钮
            Button(action: {
                isSaved.toggle()
                onSave()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 13))
                    Text(isSaved ? "已收藏" : "加入生词本")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(isSaved ? .secondary : .accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSaved ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(isSaved)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var sourceLabel: String {
        if entry.source == "deepseek" {
            return "DeepSeek AI 生成"
        }
        if entry.source.hasPrefix("deepseek-expansion") {
            return "离线词库 · DeepSeek 生成"
        }
        return "牛津词典 · DeepSeek AI 增强"
    }

    // MARK: - Image Loading

    private func loadImage() async {
        guard let url = entry.imageURL else { return }
        do {
            imageData = try await ImageService.shared.downloadImage(from: url)
        } catch {
            // 配图加载失败不影响主流程
        }
    }
}
