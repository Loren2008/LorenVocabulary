import CoreServices
import Foundation

/// 从 stdin 逐行读取候选词，只输出被当前 macOS 词典完整命中的词。
/// 输入与输出均为 UTF-8，一行一个词，便于 Python 候选生成器批量调用。
///
/// `--english-headword` 模式还要求返回定义的词头与输入完全一致。
/// 这会排除安装的中文词典将 `shouting` 按拼音误命中为“收听”一类情况。
private let requireEnglishHeadword = CommandLine.arguments.contains("--english-headword")

private func normalized(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping
        .lowercased(with: Locale(identifier: "en_US_POSIX"))
}

private func definitionStartsWithHeadword(_ definition: String, word: String) -> Bool {
    let definition = normalized(definition.trimmingCharacters(in: .whitespacesAndNewlines))
    let word = normalized(word)
    guard definition.hasPrefix(word) else { return false }

    let boundary = definition.index(definition.startIndex, offsetBy: word.count)
    guard boundary < definition.endIndex else { return true }
    let next = definition[boundary]
    return !next.isLetter && !next.isNumber && next != "'" && next != "-"
}

private func dictionaryHasExactTerm(_ word: String) -> Bool {
    let text = word as CFString
    let length = CFStringGetLength(text)
    guard length > 0 else { return false }

    let termRange = DCSGetTermRangeInString(nil, text, 0)
    guard termRange.location == 0, termRange.length == length else { return false }

    let fullRange = CFRange(location: 0, length: length)
    guard let definition = DCSCopyTextDefinition(nil, text, fullRange)?.takeRetainedValue() else {
        return false
    }
    let definitionText = definition as String
    guard definitionText.count > 15 else { return false }
    return !requireEnglishHeadword || definitionStartsWithHeadword(definitionText, word: word)
}

while let line = readLine() {
    let word = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if dictionaryHasExactTerm(word) {
        print(word)
    }
}
