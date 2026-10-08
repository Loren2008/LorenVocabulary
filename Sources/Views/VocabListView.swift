import SwiftUI

/// 生词本列表视图
struct VocabListView: View {
    @State private var words: [SavedWord] = []
    @State private var searchText = ""
    @State private var selectedWord: SavedWord?
    @State private var showDetail = false
    @State private var sortBy: SortOption = .date

    enum SortOption: String, CaseIterable {
        case date = "时间"
        case alphabet = "字母"
        case review = "复习"

        var id: String { rawValue }
    }

    var filteredWords: [SavedWord] {
        let base = searchText.isEmpty
            ? words
            : StorageService.shared.searchWords(query: searchText)

        switch sortBy {
        case .date:
            return base.sorted { $0.savedAt > $1.savedAt }
        case .alphabet:
            return base.sorted { $0.word.lowercased() < $1.word.lowercased() }
        case .review:
            return base.sorted { ($0.reviewCount, $0.lastReviewed ?? Date.distantPast) > ($1.reviewCount, $1.lastReviewed ?? Date.distantPast) }
        }
    }

    var body: some View {
        NavigationSplitView {
            // 侧边栏列表
            VStack(spacing: 0) {
                // 搜索栏
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索单词或释义...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal, 10)
                .padding(.top, 8)

                // 排序选择
                Picker("排序", selection: $sortBy) {
                    ForEach(SortOption.allCases, id: \.id) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()

                // 统计
                HStack {
                    Text("共 \(filteredWords.count) 个生词")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()

                    if !searchText.isEmpty {
                        Text("搜索结果")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                // 单词列表
                List(filteredWords, selection: $selectedWord) { word in
                    WordRowView(word: word)
                        .contextMenu {
                            Button("删除") {
                                StorageService.shared.deleteWord(by: word.id)
                                refreshWords()
                            }
                        }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 240)
            .onAppear { refreshWords() }
        } detail: {
            if let word = selectedWord {
                WordDetailView(word: word, onDelete: {
                    StorageService.shared.deleteWord(by: word.id)
                    selectedWord = nil
                    refreshWords()
                })
            } else {
                emptyDetailView
            }
        }
        .frame(minWidth: 680, minHeight: 440)
    }

    // MARK: - Empty State

    private var emptyDetailView: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            Text("选择左侧单词查看详情")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "control")
                        .font(.system(size: 12))
                    Text("双击 Control 键查词")
                        .font(.system(size: 12))
                }
                Text("在任意应用中选中单词/词组，双击 Control 键即可查询")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func refreshWords() {
        words = StorageService.shared.getAllWords()
    }
}

// MARK: - Word Row

struct WordRowView: View {
    let word: SavedWord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(word.word)
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                if word.reviewCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                        Text("\(word.reviewCount)")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                }
            }

            if let firstDef = word.definitions.first {
                Text("\(firstDef.partOfSpeech) \(firstDef.meaning)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let phonetic = word.phonetic, !phonetic.isEmpty {
                Text("/\(phonetic)/")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.vertical, 3)
    }
}
