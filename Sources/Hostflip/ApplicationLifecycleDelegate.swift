import AppKit
import SwiftUI

@MainActor
final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    private var openMainWindow: (() -> Void)?
    private var opensMainWindowWhenReady = false

    func applicationDidFinishLaunching(_: Notification) {
        // A login-item launch stays silent in the menu bar (#37); direct launches
        // (Finder, Spotlight, Dock) keep opening the main window.
        guard !LoginItemLaunch.isCurrent else { return }
        requestMainWindow()
    }

    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        requestMainWindow()
        return true
    }

    func installOpenMainWindow(_ action: @escaping () -> Void) {
        openMainWindow = action
        guard opensMainWindowWhenReady else { return }
        opensMainWindowWhenReady = false
        action()
    }

    func requestMainWindow() {
        guard let openMainWindow else {
            opensMainWindowWhenReady = true
            return
        }
        openMainWindow()
    }
}

struct MainWindowActionInstaller: View {
    let applicationDelegate: ApplicationLifecycleDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                applicationDelegate.installOpenMainWindow {
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
    }
}
