import Foundation

/// 本地词典缓存 - 文件级 JSON 存储
final class LocalCacheService {
    static let shared = LocalCacheService()

    private let cacheDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        cacheDir = Config.appSupportDir.appendingPathComponent("cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// 缓存一个词典条目
    func cache(_ entry: DictionaryEntry) {
        let fileURL = cacheFileURL(for: entry.word)
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 查询缓存（磁盘 IO 通常 < 1ms）
    func get(_ word: String) -> DictionaryEntry? {
        let fileURL = cacheFileURL(for: word)
        guard let data = try? Data(contentsOf: fileURL),
              let entry = try? decoder.decode(DictionaryEntry.self, from: data) else {
            return nil
        }
        return entry
    }

    /// 检查是否已缓存
    func has(_ word: String) -> Bool {
        FileManager.default.fileExists(atPath: cacheFileURL(for: word).path)
    }

    /// 更新已有条目的 IELTS 例句（DeepSeek 异步返回后补全）
    func updateIELTS(word: String, examples: [DictionaryEntry.IELTSExample]) {
        guard let existing = get(word) else { return }
        var updated = existing
        updated.ieltsExamples = examples
        cache(updated)
    }

    /// 缓存数量
    func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path))?.count ?? 0
    }

    // MARK: - Private

    private func cacheFileURL(for word: String) -> URL {
        let safe = word.lowercased()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return cacheDir.appendingPathComponent("\(safe).json")
    }
}
