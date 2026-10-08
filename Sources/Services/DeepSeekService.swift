import Foundation

/// DeepSeek AI 服务 - 释义精简、词组补全、IELTS 风格例句生成
final class DeepSeekService {
    static let shared = DeepSeekService()

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config)
    }

    // MARK: - 直接查询（词典未收录时）

    func lookupDirectly(word: String) async throws -> DictionaryEntry {
        let prompt = """
        你是一位雅思（IELTS）备考专家，请为单词/词组「\(word)」生成一份权威、精炼的牛津词典风格释义。

        请严格按以下 JSON 格式返回（只返回 JSON，不要其他文字）：

        {
          "phonetic": "音标",
          "refined_definitions": [
            {"partOfSpeech": "词性", "meaning": "中文释义（精炼，不超过20字）", "example": "英文例句", "synonyms": ["同义词1"]}
          ],
          "phrases": [
            {"text": "词组", "meaning": "中文释义", "type": "formal/slang/idiom/phrasalVerb/collocation"}
          ]
        }

        要求：
        - 一词多义时列出所有常见义项，按使用频率排序
        - 例句选取雅思场景中常见的
        - 词组要包含正式用语和俚语/俗语
        - 释义务必精炼准确
        """

        let content = try await callAPI(prompt: prompt)
        let entry = try parseEnhancedJSON(word: word, json: content, source: "deepseek")
        guard !entry.definitions.isEmpty else { throw DeepSeekError.parseError }
        return entry
    }

    // MARK: - 仅获取 IELTS 风格例句（轻量，用于缓存命中的异步补全）

    func fetchIELTSExamples(word: String) async -> [DictionaryEntry.IELTSExample] {
        let prompt = """
        你是一位雅思（IELTS）备考专家。请为单词/词组「\(word)」生成原创的 IELTS 风格例句。

        请严格按以下 JSON 格式返回（只返回 JSON）：

        {
          "ielts_examples": [
            {"sentence": "原创 IELTS 风格英文例句", "source": "AI-generated IELTS-style example", "year": ""}
          ]
        }

        要求：
        - 最多生成2条，语境自然并适合雅思阅读或写作
        - 不得声称来自剑桥雅思或任何真实考题
        """

        do {
            let content = try await callAPI(prompt: prompt)
            let cleaned = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let start = cleaned.firstIndex(of: "{"),
                  let end = cleaned.lastIndex(of: "}"),
                  let data = String(cleaned[start...end]).data(using: .utf8),
                  let result = try? JSONDecoder().decode(IELTSOnlyResponse.self, from: data) else {
                return []
            }

            return (result.ielts_examples ?? []).map {
                DictionaryEntry.IELTSExample(
                    sentence: $0.sentence,
                    source: "AI-generated IELTS-style example",
                    year: nil
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - 释义增强 + 词组 + IELTS检索

    func enhance(entry: DictionaryEntry) async throws -> DictionaryEntry {
        let defsSummary = entry.definitions.map { d in
            "[\(d.partOfSpeech)] \(d.meaning)\(d.example.map { " | \($0)" } ?? "")"
        }.joined(separator: "\n")

        let prompt = """
        你是一位雅思（IELTS）备考专家。请为以下词典条目进行智能精简和补全。

        原始条目：
        单词: \(entry.word)
        现有释义:
        \(defsSummary)

        请严格按以下 JSON 格式返回（只返回 JSON）：

        {
          "refined_definitions": [
            {"partOfSpeech": "词性", "meaning": "精炼中文释义（不超过20字，精准抓核心义）", "example": "精炼英文例句（雅思场景优先）"}
          ],
          "phrases": [
            {"text": "词组/搭配", "meaning": "中文释义", "type": "formal/slang/idiom/phrasalVerb/collocation"}
          ],
          "ielts_examples": [
            {"sentence": "原创IELTS风格例句", "source": "AI-generated IELTS-style example", "year": ""}
          ]
        }

        要求：
        - 释义精简但准确，去掉冗余描述，合并相近义项
        - 一词多义保留所有核心义项，按使用频率排序
        - 词组覆盖：正式用语、俚语/俗语、动词短语、常见搭配
        - IELTS例句必须原创、自然；不得声称来自任何真实考题
        """

        let content = try await callAPI(prompt: prompt)
        return try parseEnhancedJSON(word: entry.word, json: content,
                                      source: entry.source, original: entry)
    }

    // MARK: - API 调用

    private func callAPI(prompt: String) async throws -> String {
        let url = URL(string: "\(Config.deepseekBaseURL)/chat/completions")!

        let request = DeepSeekRequest(
            model: "deepseek-v4-flash",
            messages: [
                DeepSeekRequest.Message(role: "system", content: "你是一位专业的雅思备考助手，擅长牛津词典风格的释义。回复必须严格遵循要求的JSON格式。"),
                DeepSeekRequest.Message(role: "user", content: prompt)
            ],
            thinking: DeepSeekRequest.Thinking(type: "disabled"),
            response_format: DeepSeekRequest.ResponseFormat(type: "json_object"),
            temperature: 0.3,
            max_tokens: 2000
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(Config.deepseekAPIKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResp = response as? HTTPURLResponse else {
            throw DeepSeekError.networkError
        }
        guard httpResp.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError.httpError(httpResp.statusCode, body)
        }

        let result = try decoder.decode(DeepSeekResponse.self, from: data)
        guard let content = result.choices?.first?.message?.content,
              !content.isEmpty else {
            throw DeepSeekError.emptyResponse
        }

        return content
    }

    // MARK: - JSON 解析

    private func parseEnhancedJSON(word: String, json: String, source: String,
                                     original: DictionaryEntry? = nil) throws -> DictionaryEntry {
        // 清理可能的 markdown 标记
        var cleaned = json
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 尝试找到 JSON 对象
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        guard let data = cleaned.data(using: .utf8) else {
            throw DeepSeekError.parseError
        }

        let enhanced = try JSONDecoder().decode(EnhancedEntry.self, from: data)

        var definitions: [DictionaryEntry.Definition] = []
        for rd in enhanced.refined_definitions ?? [] {
            definitions.append(DictionaryEntry.Definition(
                partOfSpeech: rd.partOfSpeech,
                meaning: rd.meaning,
                example: rd.example,
                synonyms: nil
            ))
        }

        // 如果没有增强释义，使用原始释义
        if definitions.isEmpty, let orig = original {
            definitions = orig.definitions
        }

        var phrases: [DictionaryEntry.PhraseItem] = []
        for rp in enhanced.phrases ?? [] {
            phrases.append(DictionaryEntry.PhraseItem(
                text: rp.text,
                meaning: rp.meaning,
                type: parsePhraseType(rp.type)
            ))
        }

        var ieltsExamples: [DictionaryEntry.IELTSExample]? = nil
        if let ie = enhanced.ielts_examples, !ie.isEmpty {
            ieltsExamples = ie.map { example in
                DictionaryEntry.IELTSExample(
                    sentence: example.sentence,
                    source: "AI-generated IELTS-style example",
                    year: nil
                )
            }
        }

        return DictionaryEntry(
            word: word,
            phonetic: enhanced.phonetic ?? original?.phonetic,
            audioURL: original?.audioURL,
            definitions: definitions,
            phrases: phrases,
            ieltsExamples: ieltsExamples,
            imageURL: original?.imageURL,
            source: source
        )
    }

    private func parsePhraseType(_ type: String) -> DictionaryEntry.PhraseItem.PhraseType {
        switch type.lowercased() {
        case "formal": return .formal
        case "slang": return .slang
        case "idiom": return .idiom
        case "phrasalverb", "phrasal_verb": return .phrasalVerb
        case "collocation": return .collocation
        default: return .collocation
        }
    }
}

// MARK: - Enhanced JSON Model

struct EnhancedEntry: Codable {
    let phonetic: String?
    let refined_definitions: [RefinedDef]?
    let phrases: [RefinedPhrase]?
    let ielts_examples: [RefinedIELTS]?

    struct RefinedDef: Codable {
        let partOfSpeech: String
        let meaning: String
        let example: String?
    }

    struct RefinedPhrase: Codable {
        let text: String
        let meaning: String
        let type: String
    }

    struct RefinedIELTS: Codable {
        let sentence: String
    }
}

// MARK: - IELTS 专用响应模型

struct IELTSOnlyResponse: Codable {
    let ielts_examples: [IELTSEx]?

    struct IELTSEx: Codable {
        let sentence: String
    }
}

enum DeepSeekError: LocalizedError {
    case networkError
    case httpError(Int, String)
    case emptyResponse
    case parseError

    var errorDescription: String? {
        switch self {
        case .networkError: return "AI 服务网络连接失败"
        case .httpError(let code, _): return "AI 服务返回错误 (HTTP \(code))"
        case .emptyResponse: return "AI 返回为空"
        case .parseError: return "AI 响应解析失败"
        }
    }
}
