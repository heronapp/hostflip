import AppKit
import Foundation
import Observation

enum AppearancePreference: String, CaseIterable, Equatable {
    case auto
    case light
    case dark

    static let `default`: Self = .auto

    var title: String {
        switch self {
        case .auto:
            String(localized: "Auto")
        case .light:
            String(localized: "Light")
        case .dark:
            String(localized: "Dark")
        }
    }

    /// `nil` means no override: the app follows the system appearance.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .auto:
            nil
        case .light:
            .aqua
        case .dark:
            .darkAqua
        }
    }
}

@MainActor
@Observable
final class AppearancePreferenceStore {
    private static let preferenceKey = "appearancePreference"

    private(set) var preference: AppearancePreference

    private let savePreference: (String) -> Void
    private let applyAppearance: (NSAppearance.Name?) -> Void

    convenience init() {
        let defaults = UserDefaults.standard
        self.init(
            loadPreference: { defaults.string(forKey: Self.preferenceKey) },
            savePreference: { defaults.set($0, forKey: Self.preferenceKey) },
            applyAppearance: { name in
                DispatchQueue.main.async {
                    NSApp.appearance = name.flatMap(NSAppearance.init(named:))
                }
            }
        )
    }

    init(
        loadPreference: () -> String?,
        savePreference: @escaping (String) -> Void,
        applyAppearance: @escaping (NSAppearance.Name?) -> Void
    ) {
        let preference = loadPreference().flatMap(AppearancePreference.init(rawValue:)) ?? .default
        self.preference = preference
        self.savePreference = savePreference
        self.applyAppearance = applyAppearance
        applyAppearance(preference.appearanceName)
    }

    func setPreference(_ preference: AppearancePreference) {
        self.preference = preference
        savePreference(preference.rawValue)
        applyAppearance(preference.appearanceName)
    }
}
