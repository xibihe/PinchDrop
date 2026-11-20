import SwiftUI

enum AppLanguage: String, CaseIterable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"

    static let key = "displayLanguage"
    static var preferred: Self { Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .chinese : .english }
    static var current: Self { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? preferred }
    func text(_ chinese: String, _ english: String) -> String { self == .chinese ? chinese : english }
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.key) private var language = AppLanguage.preferred
    var body: some View {
        Picker(language.text("语言", "Language"), selection: $language) {
            Text(verbatim: "中文").tag(AppLanguage.chinese)
            Text(verbatim: "English").tag(AppLanguage.english)
        }.pickerStyle(.segmented)
    }
}
