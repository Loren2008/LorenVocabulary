import SwiftUI

/// 百词斩风格生词复习
struct ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var words: [SavedWord] = []
    @State private var currentIndex = 0
    @State private var isRevealed = false
    @State private var countKnown = 0
    @State private var countUnknown = 0
    @State private var entry: DictionaryEntry?

    var body: some View {
        VStack(spacing: 0) {
            if words.isEmpty {
                emptyState
            } else if currentIndex >= words.count {
                completionView
            } else {
                reviewContent
            }
        }
        .frame(minWidth: 500, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { loadWords() }
    }

    // MARK: - Review Content

    private var reviewContent: some View {
        let word = words[currentIndex]

        return VStack(spacing: 0) {
            // 顶部进度
            headerView

            Spacer()

            // 闪卡
            flashCard(word)

            Spacer()

            // 操作按钮
            actionButtons(word)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)

                Spacer()

                Text("\(currentIndex + 1) / \(words.count)")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                Text("✅ \(countKnown)  ❌ \(countUnknown)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 16)
            }
            .padding(.top, 12)

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.blue)
                        .frame(width: geo.size.width * CGFloat(currentIndex) / CGFloat(max(words.count, 1)), height: 6)
                        .animation(.easeInOut, value: currentIndex)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 20)
    }

    // MARK: - Flash Card

    @ViewBuilder
    private func flashCard(_ word: SavedWord) -> some View {
        VStack(spacing: 20) {
            if !isRevealed {
                // 正面：只显示单词
                VStack(spacing: 16) {
                    Text(word.word)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    if let phonetic = entry?.phonetic {
                        Text(phonetic)
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: 400, minHeight: 200)
                .padding(30)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.blue.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.blue.opacity(0.2), lineWidth: 1))
                )
                .onTapGesture { revealCard() }
            } else {
                // 背面：释义、例句、IELTS 语境
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(word.word)
                            .font(.largeTitle.bold())

                        if let e = entry {
                            ForEach(e.definitions) { def in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        posTag(def.partOfSpeech)
                                        Text(def.meaning)
                                            .font(.body.weight(.medium))
                                    }
                                    if let ex = def.example, !ex.isEmpty {
                                        Text(ex)
                                            .font(.callout)
                                            .foregroundColor(.secondary)
                                            .padding(.leading, 4)
                                    }
                                }
                            }

                            if let ielts = e.ieltsExamples, !ielts.isEmpty {
                                Divider()
                                Label("IELTS 例句", systemImage: "doc.text.magnifyingglass")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.orange)
                                ForEach(ielts) { ie in
                                    Text("• \(ie.sentence)")
                                        .font(.callout)
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 400)
                    .frame(minHeight: 200)
                }
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.green.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.green.opacity(0.2), lineWidth: 1))
                )
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Action Buttons

    private func actionButtons(_ word: SavedWord) -> some View {
        VStack(spacing: 12) {
            if !isRevealed {
                Button(action: { revealCard() }) {
                    Label("点此查看释义", systemImage: "hand.tap.fill")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                HStack(spacing: 20) {
                    Button(action: { markAnswer(known: false, word: word) }) {
                        Label("不认识", systemImage: "xmark")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)

                    Button(action: { markAnswer(known: true, word: word) }) {
                        Label("认识", systemImage: "checkmark")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.green)
                }
            }
        }
        .padding(.bottom, 30)
    }

    // MARK: - Completion

    private var completionView: some View {
        VStack(spacing: 24) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.yellow)
            Text("复习完成！")
                .font(.largeTitle.bold())
            Text("认识 \(countKnown) 个 · 不认识 \(countUnknown) 个")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("不认识的词已加回生词本，明天继续复习")
                .font(.callout)
                .foregroundColor(.secondary)

            Button("再来一轮") {
                currentIndex = 0
                countKnown = 0
                countUnknown = 0
                isRevealed = false
                loadWords()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bookmark.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("生词本为空")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("双击 Control 查词并保存，即可开始复习")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private func posTag(_ pos: String) -> some View {
        Text(pos)
            .font(.caption2.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(posColor(pos)))
    }

    private func posColor(_ pos: String) -> Color {
        switch pos.lowercased() {
        case "noun", "n.": return .blue
        case "verb", "v.": return .green
        case "adjective", "adj.": return .orange
        case "adverb", "adv.": return .purple
        default: return .gray
        }
    }

    private func loadWords() {
        words = StorageService.shared.getAllWords()
    }

    private func revealCard() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isRevealed = true
        }
        // 加载释义
        if entry == nil {
            let w = words[currentIndex].word
            if let e = DatabaseService.shared.lookup(w) {
                entry = e
            } else if let raw = MacDictionaryService.shared.lookup(w) {
                let defs = MacDictionaryService.shared.parseDefinitions(from: raw)
                if !defs.isEmpty {
                    entry = DictionaryEntry(word: w, definitions: defs, phrases: [], source: "oxford")
                }
            }
        }
    }

    private func markAnswer(known: Bool, word: SavedWord) {
        if known {
            countKnown += 1
        } else {
            countUnknown += 1
        }
        withAnimation {
            isRevealed = false
            entry = nil
            currentIndex += 1
        }
    }
}
