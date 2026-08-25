import AppKit
import SwiftUI

/// Edit menu "Toggle Comment" (#86): dispatched down the responder chain to the focused
/// `HostsTextView`. SwiftUI's Commands cannot validate through the responder chain, so the
/// item follows the focused scene value the detail pane derives from the editor's focus.
struct EditorCommands: Commands {
    @FocusedValue(\.isHostsEditorEditable) private var isEditorEditable

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Toggle Comment") {
                NSApp.sendAction(#selector(HostsTextView.toggleComment(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(isEditorEditable != true)
        }
    }
}
