import Foundation
import CoreServices

/// macOS 内置词典服务 - 牛津/新牛津英汉双解
final class MacDictionaryService {
    static let shared = MacDictionaryService()

    private init() {}

    func lookup(_ word: String) -> String? {
        let cfWord = word as NSString
        let range = DCSGetTermRangeInString(nil, cfWord, 0)
        guard range.length > 0 else { return nil }
        guard let def = DCSCopyTextDefinition(nil, cfWord, range)?.takeRetainedValue() else { return nil }
        let text = def as String
        guard text.count > 15 else { return nil }
        return text
    }

    /// 解析词典文本为结构化 Definition
    func parseDefinitions(from raw: String) -> [DictionaryEntry.Definition] {
        var definitions: [DictionaryEntry.Definition] = []

        let parts = raw.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }

        for part in parts.dropFirst(2) {
            guard let (pos, defText) = splitPOS(from: part) else { continue }
            let items = splitNumberedItems(from: defText)
            if items.isEmpty {
                let (cn, ex) = extractChineseAndExample(from: part)
                if !cn.isEmpty {
                    definitions.append(DictionaryEntry.Definition(partOfSpeech: pos, meaning: cn, example: ex))
                }
            } else {
                for item in items {
                    let (cn, ex) = extractChineseAndExample(from: item)
                    if !cn.isEmpty {
                        definitions.append(DictionaryEntry.Definition(partOfSpeech: pos, meaning: cn, example: ex))
                    }
                }
            }
        }

        if definitions.isEmpty {
            for part in parts.dropFirst(2) {
                guard let (pos, _) = splitPOS(from: part) else { continue }
                let short = String(part.dropFirst(pos.count).trimmingCharacters(in: .whitespaces).prefix(40))
                if !short.isEmpty {
                    definitions.append(DictionaryEntry.Definition(partOfSpeech: pos, meaning: short))
                }
            }
        }

        return definitions
    }

    // MARK: - Private

    /// 同时提取中文释义和英文例句
    /// 格式: ① (English gloss) 中文▸ English example 中文
    private func extractChineseAndExample(from text: String) -> (chinese: String, example: String) {
        // 1) 找到所有 ▸ 后的英文例句
        var example = ""
        if let arrowIdx = text.firstIndex(of: "▸") {
            let afterArrow = String(text[text.index(after: arrowIdx)...]).trimmingCharacters(in: .whitespaces)
            // 例句是 ▸ 后的中文字符之前的英文部分
            let engExample = extractEnglish(afterArrow)
            if !engExample.isEmpty {
                example = engExample
            }
        }

        // 2) 提取中文释义
        let chinese = extractChinese(text)
        return (chinese, example)
    }

    /// 提取字符串开头的英文（直到遇到中文字符或标点）
    private func extractEnglish(_ text: String) -> String {
        var result = ""
        for ch in text {
            if ch.unicodeScalars.first.map({ $0.isASCII }) == true {
                if ch == "▸" { break }
                result.append(ch)
            } else {
                if result.count > 4 { break }
                result.append(ch)
                if result.count > 20 { break }
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 提取中文部分（保留作为基础方法）
    private func extractChinese(_ text: String) -> String {
        let pattern = "[\\u4e00-\\u9fff\\u3400-\\u4dbf]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return "" }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        var chineseParts: [String] = []
        for match in matches {
            let substr = nsText.substring(with: match.range)
            if substr.count >= 2 && !substr.allSatisfy({ $0.isASCII || $0.isNumber }) {
                chineseParts.append(substr)
            }
            if chineseParts.count >= 2 { break }
        }
        let combined = chineseParts.joined(separator: " · ")
        return combined.count > 20 ? String(combined.prefix(20)) : combined
    }

    private let knownPOS: [(String, String)] = [
        ("noun", "n."), ("verb", "v."), ("adjective", "adj."),
        ("adverb", "adv."), ("pronoun", "pron."), ("preposition", "prep."),
        ("conjunction", "conj."), ("interjection", "interj."),
        ("determiner", "det."), ("exclamation", "excl."),
        ("abbreviation", "abbr."), ("prefix", "pref."), ("suffix", "suf."),
        ("auxiliary verb", "aux."), ("modal verb", "modal"),
        ("phrasal verb", "phr.v."), ("plural noun", "pl.n."),
        ("cardinal number", "num."), ("ordinal number", "ord.")
    ]

    private func splitPOS(from text: String) -> (String, String)? {
        let lower = text.lowercased()
        for (fullName, _) in knownPOS {
            if lower.hasPrefix(fullName) {
                let after = String(text.dropFirst(fullName.count))
                    .trimmingCharacters(in: .whitespaces)
                return (fullName, after)
            }
        }
        return nil
    }

    private func splitNumberedItems(from text: String) -> [String] {
        // 按 ① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩ 或 1. 2. 分割
        let pattern = "[①②③④⑤⑥⑦⑧⑨⑩]|[0-9]{1,2}\\.\\s"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [text]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else { return [text] }

        var results: [String] = []
        for i in 0..<matches.count {
            let start = matches[i].range.location + matches[i].range.length
            let end = (i + 1 < matches.count) ? matches[i + 1].range.location : nsText.length
            let item = nsText.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            if !item.isEmpty {
                results.append(item)
            }
        }
        return results.isEmpty ? [text] : results
    }
}
