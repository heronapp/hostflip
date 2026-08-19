import Foundation

/// The one-shot flag behind the first-launch SwitchHosts import suggestion (#75,
/// ADR-0013): the offer is made at most once, ever — marking happens when the suggestion
/// is shown, so accepting, declining, and quitting mid-alert all count as the one offer.
struct SwitchHostsImportSuggestion {
    private static let offeredKey = "switchHostsImportSuggestionOffered"

    private let loadOffered: () -> Bool
    private let saveOffered: () -> Void

    init() {
        let defaults = UserDefaults.standard
        self.init(
            loadOffered: { defaults.bool(forKey: Self.offeredKey) },
            saveOffered: { defaults.set(true, forKey: Self.offeredKey) }
        )
    }

    init(loadOffered: @escaping () -> Bool, saveOffered: @escaping () -> Void) {
        self.loadOffered = loadOffered
        self.saveOffered = saveOffered
    }

    var wasOffered: Bool {
        loadOffered()
    }

    func markOffered() {
        saveOffered()
    }
}
