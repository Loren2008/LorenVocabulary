import Foundation

/// 全局配置管理
enum Config {
    private static let appConfig = AppConfig.load()
    private static let deepseekBaseURLDefaultsKey = "deepseekBaseURL"

    static var deepseekAPIKey: String {
        KeychainService.shared.readDeepSeekAPIKey() ?? appConfig.deepseekAPIKey
    }

    static var deepseekBaseURL: String {
        let stored = UserDefaults.standard.string(forKey: deepseekBaseURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored?.isEmpty == false ? stored! : appConfig.deepseekBaseURL
    }

    static var doubleTapInterval: Double { appConfig.doubleTapInterval }

    static let freeDictBaseURL = "https://api.dictionaryapi.dev/api/v2/entries/en"
    static let unsplashAccessKey = "" // 可选：Unsplash API 配图

    /// 支持的应用数据目录
    static var appSupportDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ielts-vocab")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var savedWordsFile: URL {
        appSupportDir.appendingPathComponent("saved_words.json")
    }

    static func saveDeepSeekSettings(apiKey: String, baseURL: String) throws {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if normalizedKey.isEmpty {
            try KeychainService.shared.deleteDeepSeekAPIKey()
        } else {
            try KeychainService.shared.saveDeepSeekAPIKey(normalizedKey)
        }
        UserDefaults.standard.set(normalizedURL, forKey: deepseekBaseURLDefaultsKey)
    }

    /// Moves an existing local plist key into Keychain on first launch after the
    /// settings migration. The plist remains untouched so migration is reversible.
    static func migrateLegacyAPIKeyToKeychainIfNeeded() {
        guard KeychainService.shared.readDeepSeekAPIKey() == nil else { return }
        let legacyKey = appConfig.deepseekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyKey.isEmpty, legacyKey != "YOUR_DEEPSEEK_API_KEY" else { return }
        try? KeychainService.shared.saveDeepSeekAPIKey(legacyKey)
    }
}
