import Foundation

/// Resolve dynamic interface labels without changing their stored values.
nonisolated func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
