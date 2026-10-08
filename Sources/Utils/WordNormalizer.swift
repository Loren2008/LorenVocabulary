import Foundation

/// 统一所有查词入口的键，避免大小写、全角字符、智能引号
/// 和选区外围标点造成离线漏查。
enum WordNormalizer {
    private static let englishLocale = Locale(identifier: "en_US_POSIX")

    /// 给缓存、系统词典和网络回退使用的单一键。
    ///
    /// 数据库查询不应只使用这个值；它会先通过 `lookupCandidates`
    /// 尝试未剔除边界符号的 canonical 键。
    static func normalize(_ rawValue: String) -> String {
        guard let canonical = canonicalize(rawValue) else { return "" }
        return stripOuterPunctuation(from: canonical)
    }

    /// 数据库查询顺序：先查完整 canonical 词条，再查剔除选区包装
    /// 标点的回退键。这会保留 `.NET`、`C++`、`C#`、`#hashtag`、`'tis`
    /// 这些本身以符号开头或结尾的合法词条。
    static func lookupCandidates(_ rawValue: String) -> [String] {
        guard let canonical = canonicalize(rawValue), containsAlphanumeric(canonical) else { return [] }

        // 中间候选先只去掉明确的包装符，所以 `(C++)` 仍能命中
        // `c++`；最后再使用传统的全边界标点回退，兼容只收录 `net`
        // 而没有收录 `.net` 的旧数据。
        let wrapperStripped = stripOuterPunctuation(from: canonical)
        let broadFallback = stripAllBoundarySymbols(from: wrapperStripped)

        var candidates: [String] = []
        for candidate in [canonical, wrapperStripped, broadFallback]
            where !candidate.isEmpty && !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }

    private static func canonicalize(_ rawValue: String) -> String? {
        // NFKC 同时收敛全角字母/符号和兼容字形（如 ligature）。
        var value = rawValue.precomposedStringWithCompatibilityMapping

        // 排版软件常把 ASCII 撇号和连字符自动替换成 Unicode 变体。
        for apostrophe in ["\u{2018}", "\u{2019}", "\u{02BC}", "\u{FF07}"] {
            value = value.replacingOccurrences(of: apostrophe, with: "'")
        }
        for hyphen in ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}", "\u{FF0D}"] {
            value = value.replacingOccurrences(of: hyphen, with: "-")
        }

        // 合并换行、制表符和连续空格，保留合法的多词词条。
        value = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased(with: englishLocale)

        return value.isEmpty ? nil : value
    }

    private static func stripOuterPunctuation(from canonical: String) -> String {
        guard containsAlphanumeric(canonical) else { return "" }

        var value = canonical

        // 先剔除成对的外围引号/括号。先做这一步可以使 `(C++)`
        // 回退为 `c++`，而不是破坏合法的结尾加号。
        let wrapperPairs: [(Character, Character)] = [
            ("(", ")"), ("[", "]"), ("{", "}"), ("<", ">"),
            ("\"", "\""), ("'", "'"), ("“", "”"), ("「", "」"),
            ("『", "』"), ("《", "》")
        ]
        var removedPair = true
        while removedPair, value.count >= 2 {
            removedPair = false
            guard let first = value.first, let last = value.last else { break }
            if wrapperPairs.contains(where: { $0.0 == first && $0.1 == last }) {
                value.removeFirst()
                value.removeLast()
                removedPair = true
            }
        }

        guard containsAlphanumeric(value) else { return "" }

        // 单个起始符号可以是词条本身的一部分。只在它紧跟字母/数字时保留，
        // 因此多个句点或破折号仍会被当作选区包装。
        let preserveLeadingBoundary: Bool = {
            let characters = Array(value)
            guard characters.count >= 2, isAlphanumeric(characters[1]) else { return false }
            switch characters[0] {
            case ".", "#", "+", "-":
                return true
            case "'":
                return characters.last != "'"
            default:
                return false
            }
        }()

        if !preserveLeadingBoundary {
            while let first = value.first, !isAlphanumeric(first) {
                value.removeFirst()
            }
        }

        // C++ / C# 和以所有格撇号结尾的形式需要保留边界符号。
        // 逗号、句号、引号等其余结尾标点则继续剔除。
        while let last = value.last, !isAlphanumeric(last) {
            if last == "+" || last == "#" || last == "'" {
                break
            }
            value.removeLast()
        }

        return containsAlphanumeric(value) ? value : ""
    }

    private static func containsAlphanumeric(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func stripAllBoundarySymbols(from value: String) -> String {
        var result = value
        while let first = result.first, !isAlphanumeric(first) {
            result.removeFirst()
        }
        while let last = result.last, !isAlphanumeric(last) {
            result.removeLast()
        }
        return result
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
