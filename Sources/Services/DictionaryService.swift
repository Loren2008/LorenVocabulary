import Foundation

/// 词典查询服务 - 本地缓存优先 + DeepSeek IELTS 风格例句补全
final class DictionaryService {
    static let shared = DictionaryService()

    private let session: URLSession
    private let memCache = NSCache<NSString, CacheEntry>()

    private final class CacheEntry {
        let entry: DictionaryEntry
        let timestamp: Date
        init(entry: DictionaryEntry) { self.entry = entry; self.timestamp = Date() }
        var isValid: Bool { Date().timeIntervalSince(timestamp) < 3600 }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
        memCache.countLimit = 200
    }

    // MARK: - 查词（缓存优先，秒出）

    func lookup(_ word: String) async throws -> DictionaryEntry {
        let word = WordNormalizer.normalize(word)
        guard !word.isEmpty else { throw DictError.parseError }
        let key = word as NSString

        // 1. 内存缓存
        if let cached = memCache.object(forKey: key), cached.isValid {
            return cached.entry
        }

        // 2. 本地文件缓存（毫秒级）
        if let local = LocalCacheService.shared.get(word) {
            memCache.setObject(CacheEntry(entry: local), forKey: key)
            return local
        }

        // 3. macOS 内置词典（牛津，毫秒级离线）
        if let rawDef = MacDictionaryService.shared.lookup(word) {
            let defs = MacDictionaryService.shared.parseDefinitions(from: rawDef)
            guard !defs.isEmpty else {
                // 解析失败，继续网络查询
                return try await networkLookup(word: word)
            }

            let entry = DictionaryEntry(
                word: word,
                phonetic: nil,
                audioURL: nil,
                definitions: defs,
                phrases: [],
                source: "oxford"
            )

            // 写入缓存（不含 DeepSeek 增强）
            LocalCacheService.shared.cache(entry)
            memCache.setObject(CacheEntry(entry: entry), forKey: key)

            // 后台异步增强（DeepSeek 中文翻译 + IELTS 例句）
            Task {
                let enhanced = (try? await DeepSeekService.shared.enhance(entry: entry)) ?? entry
                LocalCacheService.shared.cache(enhanced)
            }

            return entry
        }

        // 4. 网络查询（macOS 词典未收录时）
        return try await networkLookup(word: word)
    }

    // MARK: - 异步补全 IELTS 风格例句

    func enrichWithIELTS(word: String, completion: @escaping ([DictionaryEntry.IELTSExample]) -> Void) {
        let word = WordNormalizer.normalize(word)
        guard !word.isEmpty else {
            completion([])
            return
        }
        Task {
            let examples = await DeepSeekService.shared.fetchIELTSExamples(word: word)
            if !examples.isEmpty {
                LocalCacheService.shared.updateIELTS(word: word, examples: examples)
            }
            await MainActor.run {
                completion(examples)
            }
        }
    }

    // MARK: - 网络查词（备用）

    private func networkLookup(word: String) async throws -> DictionaryEntry {
        let entry: DictionaryEntry
        do {
            let base = try await fetchFromFreeDict(word)
            let enhanced = try await DeepSeekService.shared.enhance(entry: base)
            let imageURL = try? await ImageService.shared.fetchImage(for: word)
            var result = enhanced
            result.imageURL = imageURL ?? enhanced.imageURL
            entry = result
        } catch {
            entry = try await DeepSeekService.shared.lookupDirectly(word: word)
        }
        LocalCacheService.shared.cache(entry)
        return entry
    }

    private func fetchFromFreeDict(_ word: String) async throws -> DictionaryEntry {
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        let urlStr = "\(Config.freeDictBaseURL)/\(encoded)"
        guard let url = URL(string: urlStr) else { throw DictError.invalidURL }

        let (data, response) = try await session.data(from: url)

        guard let httpResp = response as? HTTPURLResponse else { throw DictError.networkError }
        if httpResp.statusCode == 404 {
            throw DictError.httpError(404)
        }
        guard httpResp.statusCode == 200 else { throw DictError.httpError(httpResp.statusCode) }

        let rawEntries = try JSONDecoder().decode([FreeDictEntry].self, from: data)
        return convertToDictEntry(word: word, rawEntries: rawEntries)
    }

    private func convertToDictEntry(word: String, rawEntries: [FreeDictEntry]) -> DictionaryEntry {
        var definitions: [DictionaryEntry.Definition] = []
        var phonetic: String?
        var audioURL: String?

        for entry in rawEntries {
            if phonetic == nil, let text = entry.phonetic { phonetic = text }
            for meaning in entry.meanings ?? [] {
                let pos = meaning.partOfSpeech ?? ""
                for def in meaning.definitions ?? [] {
                    guard let m = def.definition?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { continue }
                    definitions.append(DictionaryEntry.Definition(partOfSpeech: pos, meaning: m, example: def.example, synonyms: def.synonyms))
                }
            }
            if audioURL == nil {
                for phon in entry.phonetics ?? [] {
                    if let url = phon.audio, !url.isEmpty { audioURL = url; break }
                }
            }
        }

        return DictionaryEntry(word: word, phonetic: phonetic, audioURL: audioURL, definitions: definitions, phrases: [], source: "oxford")
    }
}

// MARK: - Free Dictionary API Models

private struct FreeDictEntry: Codable {
    let word: String?
    let phonetic: String?
    let phonetics: [Phonetic]?
    let meanings: [Meaning]?

    struct Phonetic: Codable {
        let text: String?
        let audio: String?
    }

    struct Meaning: Codable {
        let partOfSpeech: String?
        let definitions: [Definition]?
        struct Definition: Codable {
            let definition: String?
            let example: String?
            let synonyms: [String]?
        }
    }
}

enum DictError: LocalizedError {
    case invalidURL, networkError, httpError(Int), parseError
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的查询地址"
        case .networkError: return "网络连接失败"
        case .httpError(let code): return "服务返回错误 (HTTP \(code))"
        case .parseError: return "数据解析失败"
        }
    }
}
