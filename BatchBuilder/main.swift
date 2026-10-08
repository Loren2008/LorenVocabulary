import Foundation
import CoreServices

// MARK: - SQLite 简易封装

final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) {
        if sqlite3_open(path, &db) != SQLITE_OK {
            print("❌ 无法打开数据库: \(String(cString: sqlite3_errmsg(db)))")
            exit(1)
        }
        createTable()
    }

    deinit { sqlite3_close(db) }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS words (
            word        TEXT PRIMARY KEY,
            phonetic    TEXT,
            definitions TEXT,
            source      TEXT
        );
        """
        exec(sql)
    }

    func wordExists(_ word: String) -> Bool {
        let sql = "SELECT 1 FROM words WHERE word = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, strdup(word), -1, free)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func insert(word: String, phonetic: String?, definitions: String, source: String) {
        let sql = "INSERT OR REPLACE INTO words (word, phonetic, definitions, source) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("   ⚠️ prepare failed")
            return
        }
        sqlite3_bind_text(stmt, 1, strdup(word), -1, free)
        if let p = phonetic { sqlite3_bind_text(stmt, 2, strdup(p), -1, free) }
        else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_text(stmt, 3, strdup(definitions), -1, free)
        sqlite3_bind_text(stmt, 4, strdup(source), -1, free)

        if sqlite3_step(stmt) != SQLITE_DONE {
            print("   ⚠️ insert failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
    }

    func count() -> Int {
        let sql = "SELECT COUNT(*) FROM words;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        var count: Int = 0
        if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        return count
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

// MARK: - macOS 词典查询

func lookupWord(_ word: String) -> (definitions: [[String: String]], source: String)? {
    let cfWord = word as NSString
    let range = DCSGetTermRangeInString(nil, cfWord, 0)
    guard range.length > 0 else { return nil }
    guard let def = DCSCopyTextDefinition(nil, cfWord, range)?.takeRetainedValue() else { return nil }
    let raw = def as String
    guard raw.count > 15 else { return nil }

    let defs = parseDefinitions(from: raw)
    guard !defs.isEmpty else { return nil }
    return (defs, "macos_dict")
}

func parseDefinitions(from raw: String) -> [[String: String]] {
    var result: [[String: String]] = []
    let parts = raw.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }

    for part in parts.dropFirst(2) {
        guard let (pos, defText) = splitPOS(from: part) else { continue }
        let items = splitNumberedItems(from: defText)
        let meanings: [String]

        if items.isEmpty {
            let cn = extractChinese(part)
            meanings = cn.isEmpty ? [String(part.prefix(20))] : [cn]
        } else {
            meanings = items.map { item in
                let cn = extractChinese(item)
                return cn.isEmpty ? String(item.prefix(20)) : cn
            }
        }

        for m in meanings where !m.isEmpty {
            result.append(["pos": pos, "meaning": m])
        }
    }

    return result
}

private func splitPOS(from text: String) -> (String, String)? {
    let knownPOS = ["phrasal verb", "auxiliary verb", "modal verb", "plural noun",
                    "cardinal number", "ordinal number",
                    "noun", "verb", "adjective", "adverb", "pronoun",
                    "preposition", "conjunction", "interjection",
                    "determiner", "exclamation", "abbreviation", "prefix", "suffix"]
    let lower = text.lowercased()
    for pos in knownPOS {
        if lower.hasPrefix(pos) {
            let after = String(text.dropFirst(pos.count)).trimmingCharacters(in: .whitespaces)
            return (pos, after)
        }
    }
    return nil
}

private func splitNumberedItems(from text: String) -> [String] {
    let pattern = "[①②③④⑤⑥⑦⑧⑨⑩]|[0-9]{1,2}\\.\\s"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [text] }
    let nsText = text as NSString
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    guard !matches.isEmpty else { return [] }

    var results: [String] = []
    for i in 0..<matches.count {
        let start = matches[i].range.location + matches[i].range.length
        let end = (i + 1 < matches.count) ? matches[i + 1].range.location : nsText.length
        let item = nsText.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        if !item.isEmpty { results.append(item) }
    }
    return results
}

private func extractChinese(_ text: String) -> String {
    let pattern = "[\\u4e00-\\u9fff\\u3400-\\u4dbf]+"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return "" }
    let nsText = text as NSString
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    var parts: [String] = []
    for m in matches {
        let s = nsText.substring(with: m.range)
        if s.count >= 2 && !s.allSatisfy({ $0.isASCII || $0.isNumber }) {
            parts.append(s)
        }
        if parts.count >= 2 { break }
    }
    let combined = parts.joined(separator: " · ")
    return combined.count > 20 ? String(combined.prefix(20)) : combined
}

// MARK: - 主流程

let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
let dbPath = "\(homeDir)/.ielts-vocab/words.db"
guard CommandLine.arguments.count > 1 else {
    print("用法: batch-builder /path/to/wordlist.txt")
    exit(2)
}
let inputFile = CommandLine.arguments[1]

print("""
═══════════════════════════════════════════
 IELTS-Vocab 批量词典构建器
═══════════════════════════════════════════
 数据库: \(dbPath)
 单词表: \(inputFile)
═══════════════════════════════════════════
""")

// 创建数据库目录
let dbDir = (dbPath as NSString).deletingLastPathComponent
try? FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)

let db = SQLiteDB(path: dbPath)

// 读取单词列表
guard let content = try? String(contentsOfFile: inputFile, encoding: .utf8) else {
    print("❌ 无法读取文件: \(inputFile)")
    print("   请将单词文件放在指定路径，或拖入终端作为参数")
    exit(1)
}

let allWords = content
    .components(separatedBy: .newlines)
    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    .filter { !$0.isEmpty && $0.rangeOfCharacter(from: .decimalDigits) == nil && $0.count > 1 }

let total = allWords.count
var success = 0
var skipped = 0
var failed = 0
var alreadyDone = db.count()

print("📋 共 \(total) 个单词，已存在 \(alreadyDone) 个")
print("")

let startTime = Date()

for (index, word) in allWords.enumerated() {
    let num = index + 1
    let pct = total > 0 ? num * 100 / total : 0

    // 跳过已存在的
    if db.wordExists(word) {
        skipped += 1
        if num % 100 == 0 {
            print("[\(num)/\(total) \(pct)%] ⏭️ 跳过已存在 (\(skipped) 个)")
        }
        continue
    }

    print("[\(num)/\(total) \(pct)%] 🔍 \(word)...", terminator: " ")

    if let (defs, source) = lookupWord(word) {
        // 序列化为 JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: defs, options: []),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            print("⚠️ JSON序列化失败")
            failed += 1
            continue
        }

        db.insert(word: word, phonetic: nil, definitions: jsonStr, source: source)
        print("✅ (\(defs.count)义)")
        success += 1
    } else {
        print("❌ 未收录")
        failed += 1
    }

    fflush(stdout)
}

let elapsed = Date().timeIntervalSince(startTime)
let finalCount = db.count()

print("""

═══════════════════════════════════════════
 ✅ 完成！
═══════════════════════════════════════════
 总词数:   \(total)
 成功:     \(success)
 跳过:     \(skipped)
 失败:     \(failed)
 数据库:   \(finalCount) 条记录
 耗时:     \(String(format: "%.1f", elapsed)) 秒
═══════════════════════════════════════════
""")
