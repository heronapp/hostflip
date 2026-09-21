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

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" }
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                applicationDelegate.installOpenMainWindow {
                    // A window left on another Space follows the user to the active one
                    // instead of staying there or pulling them back to it.
                    mainWindow?.collectionBehavior.insert(.moveToActiveSpace)
                    openWindow(id: "main")
                    NSApp.activate()
                    // Activation is cooperative since macOS 14 and may be declined while
                    // another app is frontmost; ordering the window front does not depend on it.
                    mainWindow?.orderFrontRegardless()
                }
            }
    }
}
