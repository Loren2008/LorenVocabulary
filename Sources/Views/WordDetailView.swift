import SwiftUI

/// 生词详情视图
struct WordDetailView: View {
    let word: SavedWord
    var onDelete: () -> Void

    @State private var imageData: Data?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // 单词头部
                wordHeader

                // 配图
                if let data = imageData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 150)
                        .clipped()
                        .cornerRadius(10)
                }

                // 释义
                definitionsSection

                // 词组
                if let phrases = word.phrases, !phrases.isEmpty {
                    phrasesSection(phrases)
                }

                // IELTS 例句
                if let ielts = word.ieltsExamples, !ielts.isEmpty {
                    ieltsSection(ielts)
                }

                // 复习统计
                reviewStats
            }
            .padding(20)
        }
        .task {
            if let url = word.imageURL {
                imageData = try? await ImageService.shared.downloadImage(from: url)
            }
        }
    }

    // MARK: - Word Header

    private var wordHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(word.word)
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                if let phonetic = word.phonetic, !phonetic.isEmpty {
                    Text("/\(phonetic)/")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text("保存于 \(formatDate(word.savedAt))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if !word.tags.isEmpty {
                        ForEach(word.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
            }

            Spacer()

            VStack(spacing: 8) {
                Button(action: {
                    AudioService.shared.speak(word.word, phonetic: word.phonetic)
                }) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("播放发音")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("删除")
            }
        }
    }

    // MARK: - Definitions

    private var definitionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("释义")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            ForEach(word.definitions) { def in
                HStack(alignment: .top, spacing: 10) {
                    Text(def.partOfSpeech)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.accentColor)
                        .frame(width: 36, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(def.meaning)
                            .font(.system(size: 15))

                        if let example = def.example, !example.isEmpty {
                            Text(example)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Phrases

    private func phrasesSection(_ phrases: [DictionaryEntry.PhraseItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("词组 / 搭配")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            ForEach(phrases) { phrase in
                HStack(spacing: 6) {
                    Text("[\(phraseTypeLabel(phrase.type))]")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                    Text(phrase.text)
                        .font(.system(size: 14, weight: .medium))
                    Text("— \(phrase.meaning)")
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                }
            }
        }
    }

    // MARK: - IELTS Examples

    private func ieltsSection(_ examples: [DictionaryEntry.IELTSExample]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("IELTS 例句")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }

            ForEach(examples) { ex in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\"\(ex.sentence)\"")
                        .font(.system(size: 14))
                        .italic()

                    Text("— \(ex.source)\(ex.year.map { " (\($0))" } ?? "")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Review Stats

    private var reviewStats: some View {
        HStack(spacing: 20) {
            statItem(icon: "clock", label: "复习次数", value: "\(word.reviewCount)")
            statItem(icon: "calendar", label: "上次复习", value: word.lastReviewed.map { formatDate($0) } ?? "—")
            statItem(icon: "bookmark", label: "保存日期", value: formatDate(word.savedAt))
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private func statItem(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
        }
    }

    // MARK: - Helpers

    private func phraseTypeLabel(_ type: DictionaryEntry.PhraseItem.PhraseType) -> String {
        switch type {
        case .formal: return "正式"
        case .slang: return "俚语"
        case .idiom: return "习语"
        case .phrasalVerb: return "短语"
        case .collocation: return "搭配"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
