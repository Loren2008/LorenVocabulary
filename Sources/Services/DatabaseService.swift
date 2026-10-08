import Foundation
import CSQLite

/// SQLite 数据库服务 - 从预构建的本地词典数据库读取
final class DatabaseService {
    static let shared = DatabaseService()

    private var db: OpaquePointer?
    private var hasWordMetadata = false
    private var hasWordAliases = false

    private init() {
        // 优先项目本地，其次用户目录
        let paths = [
            Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("words.db") },
            Config.appSupportDir.appendingPathComponent("words.db").path
        ].compactMap { $0 }

        for path in paths {
            if FileManager.default.fileExists(atPath: path),
               sqlite3_open(path, &db) == SQLITE_OK {
                hasWordMetadata = tableExists("word_metadata")
                hasWordAliases = tableExists("word_aliases")
                print("[DB] ✅ 已连接: \(path)")
                return
            }
        }

        print("[DB] ⚠️ 数据库未找到")
        db = nil
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    /// 从数据库查询单词
    func lookup(_ word: String) -> DictionaryEntry? {
        guard let db = db else { return nil }

        for query in WordNormalizer.lookupCandidates(word) {
            if let entry = lookupExact(query, in: db) {
                return entry
            }
        }
        return nil
    }

    // MARK: - Lookup implementation

    private func lookupExact(_ query: String, in db: OpaquePointer) -> DictionaryEntry? {
        guard !query.isEmpty else { return nil }

        let sql: String
        if hasWordMetadata && hasWordAliases {
            sql = """
            SELECT COALESCE(m.display_word, w.word), w.phonetic, w.definitions,
                   w.phrases, w.ielts_examples, w.source, NULL, NULL, 0,
                   m.content_authenticity
            FROM words w
            LEFT JOIN word_metadata m ON m.word = w.word
            WHERE w.word = ?
            UNION ALL
            SELECT a.display_word, w.phonetic, w.definitions, w.phrases,
                   w.ielts_examples, w.source, a.lemma, a.form_type, 1,
                   m.content_authenticity
            FROM word_aliases a
            JOIN words w ON w.word = a.lemma
            LEFT JOIN word_metadata m ON m.word = w.word
            WHERE a.alias = ? AND NOT EXISTS (SELECT 1 FROM words WHERE word = ?)
            ORDER BY 9
            LIMIT 1;
            """
        } else if hasWordMetadata {
            sql = """
            SELECT COALESCE(m.display_word, w.word), w.phonetic, w.definitions,
                   w.phrases, w.ielts_examples, w.source, NULL, NULL, 0,
                   m.content_authenticity
            FROM words w
            LEFT JOIN word_metadata m ON m.word = w.word
            WHERE w.word = ?
            LIMIT 1;
            """
        } else {
            sql = """
            SELECT word, phonetic, definitions, phrases, ielts_examples, source,
                   NULL, NULL, 0, NULL
            FROM words WHERE word = ? LIMIT 1;
            """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, strdup(query), -1, free)
        if hasWordMetadata && hasWordAliases {
            sqlite3_bind_text(stmt, 2, strdup(query), -1, free)
            sqlite3_bind_text(stmt, 3, strdup(query), -1, free)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let dbWord = String(cString: sqlite3_column_text(stmt, 0))
        let phonetic: String? = {
            if let p = sqlite3_column_text(stmt, 1) { return String(cString: p) }
            return nil
        }()

        let defsJSON = columnString(stmt, 2)
        let phrasesJSON = columnString(stmt, 3)
        let ieltsJSON = columnString(stmt, 4)
        let source = columnString(stmt, 5) ?? "oxford"
        let contentAuthenticity = columnString(stmt, 9)

        // 解析释义
        var definitions: [DictionaryEntry.Definition] = []
        if let defs = parseJSON(defsJSON) {
            definitions = defs.compactMap { dict in
                guard let pos = dict["pos"], let meaning = dict["meaning"] else { return nil }
                return DictionaryEntry.Definition(
                    partOfSpeech: pos,
                    meaning: meaning,
                    example: dict["example"]
                )
            }
        }

        // 合法屈折词形在 word_aliases 中复用 lemma 的完整内容，同时明确
        // 告诉用户当前形式与原形的关系。
        if let lemma = columnString(stmt, 6), let formType = columnString(stmt, 7) {
            definitions.insert(
                DictionaryEntry.Definition(
                    partOfSpeech: "词形",
                    meaning: "\(lemma) 的\(localizedFormType(formType))",
                    example: nil
                ),
                at: 0
            )
        }

        guard !definitions.isEmpty else { return nil }

        // 解析词组
        var phrases: [DictionaryEntry.PhraseItem] = []
        if let arr = parseJSON(phrasesJSON) {
            phrases = arr.compactMap { dict in
                guard let text = dict["text"], let meaning = dict["meaning"] else { return nil }
                return DictionaryEntry.PhraseItem(
                    text: text,
                    meaning: meaning,
                    type: parsePhraseType(dict["type"] ?? "collocation")
                )
            }
        }

        // 解析 IELTS 语境例句，并根据 metadata 标示真实性
        var ielts: [DictionaryEntry.IELTSExample]? = nil
        if let arr = parseJSON(ieltsJSON), !arr.isEmpty {
            ielts = arr.compactMap { dict in
                guard let sentence = dict["sentence"] else { return nil }
                let displayMetadata = Self.ieltsDisplayMetadata(
                    storedSource: dict["source"],
                    storedYear: dict["year"],
                    contentAuthenticity: contentAuthenticity
                )
                return DictionaryEntry.IELTSExample(
                    sentence: sentence,
                    source: displayMetadata.source,
                    year: displayMetadata.year
                )
            }
            if ielts?.isEmpty == true { ielts = nil }
        }

        return DictionaryEntry(
            word: dbWord,
            phonetic: phonetic,
            definitions: definitions,
            phrases: phrases,
            ieltsExamples: ielts,
            source: source
        )
    }

    /// 数据库中可查询键总数（原词 + 合法变形，冲突键只计一次）
    func count() -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        let sql = hasWordAliases
            ? """
              SELECT COUNT(*) FROM (
                  SELECT word AS lookup_key FROM words
                  UNION
                  SELECT alias AS lookup_key FROM word_aliases
              );
              """
            : "SELECT COUNT(*) FROM words;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int(stmt, 0)) }
        return 0
    }

    /// 完整数据可查询键数。每个 JSON 列都必须至少有一个 App 能实际
    /// 解析的对象，而不是只判断“数组长度 > 0”。
    func fullCount() -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        let completePredicate = Self.completeDataPredicate(tableAlias: "w")
        let sql: String
        if hasWordAliases {
            // lookup 遇到原词/别名冲突时优先原词，因此别名分支也使用
            // 同样的 NOT EXISTS 规则，并用 UNION 对其余键去重。
            sql = """
            SELECT COUNT(*) FROM (
                SELECT w.word AS lookup_key
                FROM words w
                WHERE \(completePredicate)
                UNION
                SELECT a.alias AS lookup_key
                FROM word_aliases a
                JOIN words w ON w.word = a.lemma
                WHERE \(completePredicate)
                  AND NOT EXISTS (SELECT 1 FROM words direct WHERE direct.word = a.alias)
            );
            """
        } else {
            sql = "SELECT COUNT(*) FROM words w WHERE \(completePredicate);"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int(stmt, 0)) }
        return 0
    }

    // MARK: - Private

    private func tableExists(_ name: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, strdup(name), -1, free)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let stmt = stmt else { return nil }
        if let cstr = sqlite3_column_text(stmt, index) {
            return String(cString: cstr)
        }
        return nil
    }

    private func parseJSON(_ json: String?) -> [[String: String]]? {
        Self.parseJSONObjectArray(json)
    }

    /// 内部解析器对混合数组逐项容错：坏项不得拖垮同列的合法对象。
    /// 保留 internal 可见性，便于回归测试覆盖早期数据格式。
    static func parseJSONObjectArray(_ json: String?) -> [[String: String]]? {
        guard let json = json, !json.isEmpty, json != "[]",
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        // 兼容早期批处理留下的两类数据：单个对象误写成顶层，以及 year
        // 被写成 JSON 数字。逐项转换可避免一个坏字段拖垮整列内容。
        let rawItems: [[String: Any]]
        if let array = object as? [Any] {
            rawItems = array.compactMap { $0 as? [String: Any] }
        } else if let dictionary = object as? [String: Any] {
            rawItems = [dictionary]
        } else {
            return nil
        }

        let items = rawItems.compactMap { item -> [String: String]? in
            var strings: [String: String] = [:]
            for (key, value) in item {
                if let string = value as? String {
                    strings[key] = string
                } else if let number = value as? NSNumber {
                    strings[key] = number.stringValue
                }
            }
            return strings.isEmpty ? nil : strings
        }
        return items.isEmpty ? nil : items
    }

    /// 数据库只读显示层的真实性标记，不改写历史 JSON。
    /// 旧库没有 metadata 时仍原样显示，保持向后兼容。
    static func ieltsDisplayMetadata(
        storedSource: String?,
        storedYear: String?,
        contentAuthenticity: String?
    ) -> (source: String, year: String?) {
        switch contentAuthenticity {
        case "legacy_unverified":
            return ("历史数据 · 来源未核验", nil)
        case "generated_style":
            return ("AI-generated IELTS-style example", nil)
        default:
            return (storedSource ?? "IELTS", storedYear)
        }
    }

    /// 严格匹配 App 各列实际使用的必填字段：
    /// definitions(pos, meaning), phrases(text, meaning), ielts_examples(sentence)。
    private static func completeDataPredicate(tableAlias: String) -> String {
        func hasObject(in column: String, requiredFields: [String]) -> String {
            let qualified = "\(tableAlias).\(column)"
            let safeJSON = "CASE WHEN json_valid(\(qualified)) THEN \(qualified) ELSE '[]' END"
            let fields = requiredFields.map { field in
                "json_type(item.value, '$.\(field)') = 'text' " +
                "AND NULLIF(TRIM(json_extract(item.value, '$.\(field)')), '') IS NOT NULL"
            }.joined(separator: " AND ")
            return """
            json_valid(\(qualified))
            AND EXISTS (
                SELECT 1
                FROM json_each(\(safeJSON)) item
                WHERE item.type = 'object' AND \(fields)
            )
            """
        }

        return [
            hasObject(in: "definitions", requiredFields: ["pos", "meaning"]),
            hasObject(in: "phrases", requiredFields: ["text", "meaning"]),
            hasObject(in: "ielts_examples", requiredFields: ["sentence"])
        ].map { "(\($0))" }.joined(separator: " AND ")
    }

    private func parsePhraseType(_ type: String) -> DictionaryEntry.PhraseItem.PhraseType {
        switch type.lowercased() {
        case "formal": return .formal
        case "slang": return .slang
        case "idiom": return .idiom
        case "phrasal verb", "phrasalverb": return .phrasalVerb
        default: return .collocation
        }
    }

    private func localizedFormType(_ type: String) -> String {
        switch type {
        case "plural": return "复数形式"
        case "past": return "过去式"
        case "past_participle": return "过去分词"
        case "present_participle": return "现在分词"
        case "third_person_singular": return "第三人称单数"
        case "comparative": return "比较级"
        case "superlative": return "最高级"
        default: return "变形"
        }
    }
}
