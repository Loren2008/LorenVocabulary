import Foundation

/// 输出 Apple/CLDR 提供的地区、语言与时区地名。每行是一个 JSON 对象。
struct LocaleTerm: Encodable {
    let displayWord: String
    let category: String
    let source: String
}

let english = Locale(identifier: "en_US")
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

var terms: [String: LocaleTerm] = [:]

for region in Locale.Region.isoRegions {
    let identifier = region.identifier
    guard let name = english.localizedString(forRegionCode: identifier), !name.isEmpty else { continue }
    terms["region:\(name)"] = LocaleTerm(
        displayWord: name,
        category: "proper_noun",
        source: "Apple/CLDR:ISO-region"
    )
}

for languageCode in Locale.LanguageCode.isoLanguageCodes {
    let identifier = languageCode.identifier
    guard let name = english.localizedString(forLanguageCode: identifier), !name.isEmpty else { continue }
    terms["language:\(name)"] = LocaleTerm(
        displayWord: name,
        category: "proper_noun",
        source: "Apple/CLDR:ISO-language"
    )
}

for identifier in TimeZone.knownTimeZoneIdentifiers {
    guard let component = identifier.split(separator: "/").last else { continue }
    let name = String(component).replacingOccurrences(of: "_", with: " ")
    guard name.count >= 2, name.rangeOfCharacter(from: .letters) != nil else { continue }
    terms["timezone:\(name)"] = LocaleTerm(
        displayWord: name,
        category: "proper_noun",
        source: "Apple/CLDR:time-zone"
    )
}

for key in terms.keys.sorted() {
    guard let term = terms[key], let data = try? encoder.encode(term),
          let line = String(data: data, encoding: .utf8) else { continue }
    print(line)
}
