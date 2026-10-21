import Foundation

/// Resolve dynamic interface labels without changing their stored values.
nonisolated func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

nonisolated enum InterfaceLanguage: String, CaseIterable {
    case system, simplifiedChinese = "zh-Hans", english = "en"

    var title: String {
        switch self {
        case .system: localized("Follow System")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    static func selected(in domain: [String: Any]?) -> Self {
        guard let language = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        if language == "zh-Hans" || language.hasPrefix("zh-Hans-") { return .simplifiedChinese }
        if language == "en" || language.hasPrefix("en-") { return .english }
        return .system
    }

    func apply(to defaults: UserDefaults) {
        // Removing the app override restores macOS language selection on the next launch.
        if self == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([rawValue], forKey: "AppleLanguages") }
    }
}
