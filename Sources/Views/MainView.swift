import AppKit
import SwiftUI

struct MainView: View {
    @State private var searchText = ""
    @State private var entry: DictionaryEntry?
    @State private var isLoading = false
    @State private var errorMsg: String?
    @State private var showReview = false
    @State private var showSettings = false

    private let dbCount: Int = DatabaseService.shared.count()
    private let fullCount: Int = DatabaseService.shared.fullCount()
    private let savedCount: Int = StorageService.shared.wordCount()

    var body: some View {
        HSplitView {
            sidebar
            contentArea
        }
        .sheet(isPresented: $showReview) {
            ReviewView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("IELTS 生词本")
                .font(.title3.bold())
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                StatRow(icon: "books.vertical.fill", label: "离线词典", value: "\(dbCount) 词", color: .blue)
                StatRow(icon: "star.fill", label: "完整数据", value: "\(fullCount) 词", color: .orange)
                StatRow(icon: "bookmark.fill", label: "生词本", value: "\(savedCount) 词", color: .purple)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Button(action: { showReview = true }) {
                Label("开始复习", systemImage: "repeat.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .disabled(savedCount == 0)

            Button(action: { showSettings = true }) {
                Label("API 设置", systemImage: "key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)

            Spacer()

            Text("双击 Control 查词")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 12)
        }
        .frame(minWidth: 180, idealWidth: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            if isLoading {
                Spacer()
                ProgressView("查询中...")
                Spacer()
            } else if let err = errorMsg {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(err)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if let e = entry {
                entryDetail(e)
            } else {
                Spacer()
                emptyState
                Spacer()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("输入单词并按回车查询...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit { performSearch() }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Entry Detail

    private func entryDetail(_ entry: DictionaryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                wordHeader(entry)
                definitionsSection(entry.definitions)
                if let ielts = entry.ieltsExamples, !ielts.isEmpty {
                    ieltsSection(ielts)
                }
                if !entry.phrases.isEmpty {
                    phrasesSection(entry.phrases)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func wordHeader(_ entry: DictionaryEntry) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(entry.word)
                .font(.largeTitle.bold())
            if let phonetic = entry.phonetic {
                Text(phonetic)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                if let url = entry.audioURL, !url.isEmpty {
                    Task { await AudioService.shared.playAudio(from: url) }
                } else {
                    AudioService.shared.speak(entry.word, phonetic: entry.phonetic)
                }
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
    }

    private func definitionsSection(_ defs: [DictionaryEntry.Definition]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("释义")
                .font(.headline)
                .foregroundColor(.primary)

            ForEach(defs) { def in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(def.partOfSpeech)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(partOfSpeechColor(def.partOfSpeech)))

                        Text(def.meaning)
                            .font(.body.weight(.medium))
                    }
                    if let example = def.example, !example.isEmpty {
                        Text(example)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                    }
                }
            }
        }
    }

    private func ieltsSection(_ examples: [DictionaryEntry.IELTSExample]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("IELTS 语境例句", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
                .foregroundColor(.orange)

            ForEach(examples) { ex in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ex.sentence)
                        .font(.callout)
                    HStack {
                        Text(ex.source)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let year = ex.year {
                            Text("·")
                            Text(year)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
            }
        }
    }

    private func phrasesSection(_ phrases: [DictionaryEntry.PhraseItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("搭配 / 词组", systemImage: "text.word.spacing")
                .font(.headline)
                .foregroundColor(.green)

            ForEach(phrases) { p in
                HStack(spacing: 8) {
                    Text(p.type.rawValue)
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(phraseTypeColor(p.type)))

                    Text("**\(p.text)**")
                        .font(.callout)
                    + Text("  \(p.meaning)")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue.opacity(0.6))
            Text("输入单词查询，或选中文本双击 Control")
                .foregroundColor(.secondary)
            Text("\(dbCount) 词离线可用")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private func performSearch() {
        let word = WordNormalizer.normalize(searchText)
        guard !word.isEmpty else { return }
        isLoading = true
        errorMsg = nil
        entry = nil

        // 1. macOS 牛津词典 → 释义 + 短语（全面）
        var definitions: [DictionaryEntry.Definition] = []
        if let raw = MacDictionaryService.shared.lookup(word) {
            definitions = MacDictionaryService.shared.parseDefinitions(from: raw)
        }

        // 如果系统词典没有，回退到数据库
        if definitions.isEmpty {
            if let dbEntry = DatabaseService.shared.lookup(word) {
                entry = dbEntry
                isLoading = false
                return
            }
        }

        // 2. 词库 → IELTS 语境例句
        var ieltsExamples: [DictionaryEntry.IELTSExample]? = nil
        if let dbEntry = DatabaseService.shared.lookup(word) {
            ieltsExamples = dbEntry.ieltsExamples
        }

        // 如果都没查到，走网络
        guard !definitions.isEmpty else {
            Task {
                do {
                    let e = try await DictionaryService.shared.lookup(word)
                    await MainActor.run { entry = e; isLoading = false }
                } catch {
                    await MainActor.run { errorMsg = error.localizedDescription; isLoading = false }
                }
            }
            return
        }

        // 合并：牛津释义 + 词库 IELTS 语境例句
        entry = DictionaryEntry(
            word: word,
            definitions: definitions,
            phrases: [],
            ieltsExamples: ieltsExamples,
            source: "oxford"
        )
        isLoading = false
    }

    private func partOfSpeechColor(_ pos: String) -> Color {
        switch pos.lowercased() {
        case "noun", "n.": return .blue
        case "verb", "v.": return .green
        case "adjective", "adj.": return .orange
        case "adverb", "adv.": return .purple
        default: return .gray
        }
    }

    private func phraseTypeColor(_ type: DictionaryEntry.PhraseItem.PhraseType) -> Color {
        switch type {
        case .collocation: return .blue
        case .formal: return .indigo
        case .slang: return .pink
        case .idiom: return .orange
        case .phrasalVerb: return .green
        }
    }
}

// MARK: - Stat Row

private struct StatRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundColor(color)
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.medium))
        }
    }
}
