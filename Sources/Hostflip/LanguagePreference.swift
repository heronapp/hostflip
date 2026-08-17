import Foundation

/// In-app language selection, mapped both ways onto the app-domain AppleLanguages
/// override — the same key and domain macOS's per-app language setting writes, so
/// the two entry points stay interchangeable (ADR-0011). Pure logic only; reading
/// and writing UserDefaults is the caller's job.
enum LanguagePreference: String, CaseIterable, Equatable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"

    /// Languages the app ships strings for; extend together with Packaging/Localization/.
    static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja"]

    /// The AppleLanguages override this selection stands for; system → nil (the
    /// caller deletes the key to fall back to the system language order).
    var overrideLanguages: [String]? {
        switch self {
        case .system:
            nil
        default:
            [rawValue]
        }
    }

    /// Resolves an existing app-domain override back to a selection; nil or empty
    /// means no override (system), an unsupported persisted language falls back to
    /// English rather than misreporting "system".
    init(override: [String]?) {
        guard let first = override?.first, !first.isEmpty else {
            self = .system
            return
        }
        self = Self.match(Locale(identifier: first))
            .flatMap(LanguagePreference.init(rawValue:)) ?? .english
    }

    /// The UI language this selection resolves to after a relaunch. For system,
    /// walks the full preference list for the first supported language (mirroring
    /// bundle resolution — never just the first entry); nothing matches → English.
    func effectiveLanguage(systemLanguages: [String]) -> String {
        switch self {
        case .system:
            for tag in systemLanguages {
                if let hit = Self.match(Locale(identifier: tag)) { return hit }
            }
            return "en"
        default:
            return rawValue
        }
    }

    /// Locale → supported canonical language, nil when unsupported. Chinese splits
    /// by script; Locale fills likely subtags (zh-TW → Hant, bare zh → Hans).
    static func match(_ locale: Locale) -> String? {
        guard let code = locale.language.languageCode?.identifier else { return nil }
        if code == "zh" {
            return locale.language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans"
        }
        return supportedLanguages.contains(code) ? code : nil
    }
}
