import Foundation

// MARK: - 词典条目完整模型

struct DictionaryEntry: Codable {
    var word: String
    var phonetic: String?
    var audioURL: String?
    var definitions: [Definition]
    var phrases: [PhraseItem]
    var ieltsExamples: [IELTSExample]?
    var imageURL: String?
    var source: String = "oxford"

    struct Definition: Codable, Identifiable, Hashable {
        var id = UUID()
        var partOfSpeech: String
        var meaning: String
        var example: String?
        var synonyms: [String]?
    }

    struct PhraseItem: Codable, Identifiable, Hashable {
        var id = UUID()
        var text: String
        var meaning: String
        var type: PhraseType

        enum PhraseType: String, Codable {
            case formal
            case slang
            case idiom
            case phrasalVerb
            case collocation
        }
    }

    struct IELTSExample: Codable, Identifiable, Hashable {
        var id = UUID()
        var sentence: String
        var source: String
        var year: String?
    }
}

// MARK: - 用户保存的生词

struct SavedWord: Codable, Identifiable, Hashable {
    var id = UUID()
    var word: String
    var phonetic: String?
    var definitions: [SavedDefinition]
    var phrases: [DictionaryEntry.PhraseItem]?
    var ieltsExamples: [DictionaryEntry.IELTSExample]?
    var imageURL: String?
    var savedAt: Date
    var reviewCount: Int = 0
    var lastReviewed: Date?
    var notes: String?
    var tags: [String] = []

    struct SavedDefinition: Codable, Identifiable, Hashable {
        var id = UUID()
        var partOfSpeech: String
        var meaning: String
        var example: String?
    }
}

// MARK: - DeepSeek API 模型

struct DeepSeekRequest: Codable {
    let model: String
    let messages: [Message]
    let thinking: Thinking?
    let response_format: ResponseFormat?
    let temperature: Double
    let max_tokens: Int

    struct Message: Codable {
        let role: String
        let content: String
    }

    struct Thinking: Codable {
        let type: String
    }

    struct ResponseFormat: Codable {
        let type: String
    }
}

struct DeepSeekResponse: Codable {
    let choices: [Choice]?

    struct Choice: Codable {
        let message: Message?

        struct Message: Codable {
            let content: String?
        }
    }
}

// MARK: - 配置

struct AppConfig: Codable {
    var deepseekAPIKey: String
    var deepseekBaseURL: String
    var doubleTapInterval: Double

    static func load() -> AppConfig {
        let defaultPath = Bundle.main.path(forResource: "Config", ofType: "plist")
        let userConfigDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ielts-vocab")
        let userConfigPath = userConfigDir.appendingPathComponent("Config.plist")

        // 优先读取用户配置
        if let userData = try? Data(contentsOf: userConfigPath),
           let userConfig = try? PropertyListDecoder().decode(AppConfig.self, from: userData) {
            return userConfig
        }

        // 回退到默认配置
        if let path = defaultPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let config = try? PropertyListDecoder().decode(AppConfig.self, from: data) {
            return config
        }

        // 硬回退
        return AppConfig(
            deepseekAPIKey: "",
            deepseekBaseURL: "https://api.deepseek.com/v1",
            doubleTapInterval: 0.4
        )
    }
}
