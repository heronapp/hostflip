import SwiftUI

extension Notification.Name {
    /// Posted by the Edit menu to present the sidebar search field (#88).
    static let hostflipFindInAllProfiles = Notification.Name("hostflip.findInAllProfiles")
}

/// Edit menu "Find in All Profiles…" (⌘⇧F, #88). ⌘F stays with the editor's own find bar;
/// the global search lives in the sidebar, so the command only moves focus there.
struct SearchCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find in All Profiles…") {
                NotificationCenter.default.post(name: .hostflipFindInAllProfiles, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}
