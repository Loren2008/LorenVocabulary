import Foundation

/// 数据持久化服务 - JSON 文件存储
final class StorageService {
    static let shared = StorageService()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.ielts.vocab.storage", attributes: .concurrent)
    private var cache: [UUID: SavedWord] = [:]

    private init() {
        fileURL = Config.savedWordsFile
        loadFromDisk()
    }

    // MARK: - CRUD

    func getAllWords() -> [SavedWord] {
        queue.sync {
            Array(cache.values).sorted { $0.savedAt > $1.savedAt }
        }
    }

    func getWord(by id: UUID) -> SavedWord? {
        queue.sync { cache[id] }
    }

    func wordExists(_ word: String) -> Bool {
        let lower = word.lowercased()
        return queue.sync {
            cache.values.contains { $0.word.lowercased() == lower }
        }
    }

    func saveWord(_ word: SavedWord) {
        queue.async(flags: .barrier) { [weak self] in
            self?.cache[word.id] = word
            self?.persist()
        }
    }

    func deleteWord(by id: UUID) {
        queue.async(flags: .barrier) { [weak self] in
            self?.cache.removeValue(forKey: id)
            self?.persist()
        }
    }

    func updateReview(for id: UUID) {
        queue.async(flags: .barrier) { [weak self] in
            guard var word = self?.cache[id] else { return }
            word.reviewCount += 1
            word.lastReviewed = Date()
            self?.cache[id] = word
            self?.persist()
        }
    }

    func searchWords(query: String) -> [SavedWord] {
        let lower = query.lowercased()
        return queue.sync {
            cache.values.filter { word in
                word.word.lowercased().contains(lower) ||
                word.definitions.contains { $0.meaning.contains(query) } ||
                (word.tags.contains { $0.lowercased().contains(lower) })
            }.sorted { $0.savedAt > $1.savedAt }
        }
    }

    func wordCount() -> Int {
        queue.sync { cache.count }
    }

    // MARK: - Export

    func exportToJSON() -> Data? {
        queue.sync {
            let words = Array(cache.values).sorted { $0.savedAt > $1.savedAt }
            return try? JSONEncoder().encode(words)
        }
    }

    // MARK: - Internal

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else {
            print("[Storage] 没有找到已保存数据，初始化为空")
            return
        }

        do {
            let words = try JSONDecoder().decode([SavedWord].self, from: data)
            var dict: [UUID: SavedWord] = [:]
            for word in words { dict[word.id] = word }
            cache = dict
            print("[Storage] 已加载 \(words.count) 个生词")
        } catch {
            print("[Storage] 数据解析失败: \(error)")
        }
    }

    private func persist() {
        let words = Array(cache.values)
        do {
            let data = try JSONEncoder().encode(words)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[Storage] 数据保存失败: \(error)")
        }
    }
}
