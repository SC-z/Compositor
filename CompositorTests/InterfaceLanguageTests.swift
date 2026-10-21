import Foundation
import Testing
@testable import Compositor

struct InterfaceLanguageTests {
    @Test func recognizesAppLanguageOverrides() {
        #expect(InterfaceLanguage.selected(in: nil) == .system)
        #expect(InterfaceLanguage.selected(in: ["AppleLanguages": []]) == .system)
        #expect(InterfaceLanguage.selected(in: ["AppleLanguages": ["zh-Hans-CN"]]) == .simplifiedChinese)
        #expect(InterfaceLanguage.selected(in: ["AppleLanguages": ["en-GB", "zh-Hans"]]) == .english)
    }

    @Test func switchingPersistsAndFollowingSystemRemovesOnlyTheOverride() throws {
        let name = "InterfaceLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(42, forKey: "unrelated")

        InterfaceLanguage.simplifiedChinese.apply(to: defaults)
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String] == ["zh-Hans"])
        InterfaceLanguage.english.apply(to: defaults)
        let reopened = try #require(UserDefaults(suiteName: name))
        #expect(InterfaceLanguage.selected(in: reopened.persistentDomain(forName: name)) == .english)
        InterfaceLanguage.system.apply(to: defaults)
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
        #expect(defaults.integer(forKey: "unrelated") == 42)
        #expect(InterfaceLanguage.selected(in: defaults.persistentDomain(forName: name)) == .system)
    }

    @Test func languageNamesStayReadableInEitherLanguage() {
        #expect(InterfaceLanguage.simplifiedChinese.title == "简体中文")
        #expect(InterfaceLanguage.english.title == "English")
    }
}
