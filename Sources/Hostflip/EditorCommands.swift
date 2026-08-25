import AppKit
import SwiftUI

/// Edit menu "Toggle Comment" (#86): dispatched down the responder chain to the focused
/// `HostsTextView`. SwiftUI's Commands cannot validate through the responder chain, so the
/// item follows the focus state the text view publishes.
struct EditorCommands: Commands {
    private let focus = HostsEditorFocus.shared

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Toggle Comment") {
                NSApp.sendAction(#selector(HostsTextView.toggleComment(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(!focus.isEditableEditorFocused)
        }
    }
}
