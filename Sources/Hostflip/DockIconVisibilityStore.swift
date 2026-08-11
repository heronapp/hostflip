import AppKit
import Foundation
import Observation

enum DockIconVisibilityPolicy: String, CaseIterable, Equatable {
    case whenMainWindowIsOpen
    case always
    case never

    static let `default`: Self = .whenMainWindowIsOpen

    var title: String {
        switch self {
        case .whenMainWindowIsOpen:
            "When Main Window Is Open"
        case .always:
            "Always"
        case .never:
            "Never"
        }
    }

    func showsDockIcon(mainWindowIsOpen: Bool) -> Bool {
        switch self {
        case .whenMainWindowIsOpen:
            mainWindowIsOpen
        case .always:
            true
        case .never:
            false
        }
    }
}

@MainActor
@Observable
final class DockIconVisibilityStore {
    private static let preferenceKey = "dockIconVisibilityPolicy"

    private(set) var policy: DockIconVisibilityPolicy

    private(set) var mainWindowIsOpen: Bool
    private let savePolicy: (String) -> Void
    private let applyDockIconVisibility: (Bool) -> Void

    convenience init() {
        let defaults = UserDefaults.standard
        self.init(
            mainWindowIsOpen: true,
            loadPolicy: { defaults.string(forKey: Self.preferenceKey) },
            savePolicy: { defaults.set($0, forKey: Self.preferenceKey) },
            applyDockIconVisibility: { isVisible in
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(isVisible ? .regular : .accessory)
                }
            }
        )
    }

    init(
        mainWindowIsOpen: Bool,
        loadPolicy: () -> String?,
        savePolicy: @escaping (String) -> Void,
        applyDockIconVisibility: @escaping (Bool) -> Void
    ) {
        let policy = loadPolicy().flatMap(DockIconVisibilityPolicy.init(rawValue:)) ?? .default
        self.policy = policy
        self.mainWindowIsOpen = mainWindowIsOpen
        self.savePolicy = savePolicy
        self.applyDockIconVisibility = applyDockIconVisibility
        applyDockIconVisibility(policy.showsDockIcon(mainWindowIsOpen: mainWindowIsOpen))
    }

    func setPolicy(_ policy: DockIconVisibilityPolicy) {
        self.policy = policy
        savePolicy(policy.rawValue)
        applyDockIconVisibility(policy.showsDockIcon(mainWindowIsOpen: mainWindowIsOpen))
    }

    func mainWindowDidClose() {
        guard mainWindowIsOpen else { return }
        mainWindowIsOpen = false
        applyDockIconVisibility(policy.showsDockIcon(mainWindowIsOpen: false))
    }

    func mainWindowDidOpen() {
        guard !mainWindowIsOpen else { return }
        mainWindowIsOpen = true
        applyDockIconVisibility(policy.showsDockIcon(mainWindowIsOpen: true))
    }
}
