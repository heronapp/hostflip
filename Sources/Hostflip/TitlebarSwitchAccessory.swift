import AppKit
import SwiftUI

/// SwiftUI has no trailing Toolbar placement on macOS (ToolbarSpacer needs macOS 26), and any
/// item living in the SwiftUI-managed NSToolbar shifts while SwiftUI rebuilds its items. A
/// titlebar accessory pinned to the trailing edge sits outside the toolbar entirely, so the
/// switch never moves no matter how often the toolbar is rebuilt.
struct TitlebarSwitchAccessory: NSViewRepresentable {
    let store: WorkspaceStore

    func makeNSView(context: Context) -> TitlebarSwitchInstallerView {
        TitlebarSwitchInstallerView(store: store)
    }

    func updateNSView(_ nsView: TitlebarSwitchInstallerView, context: Context) {}
}

final class TitlebarSwitchInstallerView: NSView {
    private let store: WorkspaceStore
    private var accessory: NSTitlebarAccessoryViewController?

    init(store: WorkspaceStore) {
        self.store = store
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let accessory, accessory.view.window !== window {
            accessory.removeFromParent()
            self.accessory = nil
        }
        guard let window, accessory == nil else { return }

        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = .trailing
        let hostingView = NSHostingView(rootView: TitlebarSwitchToggle(store: store))
        hostingView.setFrameSize(hostingView.fittingSize)
        controller.view = hostingView
        window.addTitlebarAccessoryViewController(controller)
        accessory = controller
    }
}

private struct TitlebarSwitchToggle: View {
    let store: WorkspaceStore

    var body: some View {
        Toggle("Enable hostflip", isOn: Binding(
            get: { !store.isPaused },
            set: { enabled in
                // Same split as activationControlsDisabled/Dimmed: the sub-second
                // in-flight switch only guards clicks — disabling on it would flash
                // the control dim on every profile toggle.
                guard !store.isSwitching else { return }
                store.setPaused(!enabled)
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(store.model == nil || store.hasHostsDrift)
        .help(store.isPaused ? "Resume hostflip" : "Pause hostflip")
        .accessibilityLabel("Enable hostflip")
        .padding(.trailing, 8)
    }
}
