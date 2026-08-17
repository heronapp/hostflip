import AppKit
import HostflipXPC
import Sparkle
import SwiftUI

struct ApplicationSettingsView: View {
    let store: WorkspaceStore
    let maintenanceStore: MaintenanceStore
    let dockIconStore: DockIconVisibilityStore
    let launchAtLoginStore: LaunchAtLoginStore
    let appearanceStore: AppearancePreferenceStore
    let updater: SPUUpdater

    // All four tabs share the classic settings-form look of Apple's own app
    // settings windows (right-aligned label column, controls left-aligned,
    // captions under their controls) — the app-settings convention, distinct
    // from the System Settings grouped cards. Top-aligned so switching tabs
    // never jumps; growth goes in as new rows — e.g. the appearance picker
    // in General.
    var body: some View {
        TabView {
            GeneralSettingsView(
                dockIconStore: dockIconStore,
                launchAtLoginStore: launchAtLoginStore,
                appearanceStore: appearanceStore
            )
            .frame(width: 500, height: 280, alignment: .top)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            // Second home of helper management alongside the toolbar popover (#41):
            // Settings is where users expect to find privileged-component removal,
            // e.g. before uninstalling. The extra height leaves room for feedback.
            HelperSettingsPane(store: store, maintenanceStore: maintenanceStore)
                .frame(width: 500, height: 180, alignment: .topLeading)
                .tabItem {
                    Label("Helper", systemImage: "gearshape.2")
                }

            CLIInstallSection()
                .frame(width: 500, height: 260, alignment: .topLeading)
                .tabItem {
                    Label("Command Line", systemImage: "terminal")
                }

            UpdatesSettingsView(updater: updater)
                .frame(width: 500, height: 150, alignment: .top)
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
    }
}

/// Everyday preferences; future rows join as more rows.
private struct GeneralSettingsView: View {
    let dockIconStore: DockIconVisibilityStore
    let launchAtLoginStore: LaunchAtLoginStore
    let appearanceStore: AppearancePreferenceStore

    @Environment(\.locale) private var locale
    @State private var languageSelection = GeneralSettingsView.storedLanguageSelection()

    var body: some View {
        Form {
            Picker(
                "Appearance",
                selection: Binding(
                    get: { appearanceStore.preference },
                    set: { appearanceStore.setPreference($0) }
                )
            ) {
                ForEach(AppearancePreference.allCases, id: \.rawValue) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            Text("Auto follows the system appearance.")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Languages name themselves and are deliberately untranslated;
            // only "System" localizes.
            Picker("Language", selection: $languageSelection) {
                Text("System").tag(LanguagePreference.system)
                Text(verbatim: "English").tag(LanguagePreference.english)
                Text(verbatim: "简体中文").tag(LanguagePreference.simplifiedChinese)
                Text(verbatim: "繁體中文").tag(LanguagePreference.traditionalChinese)
                Text(verbatim: "日本語").tag(LanguagePreference.japanese)
            }
            .onChange(of: languageSelection) { _, selection in
                if let languages = selection.overrideLanguages {
                    UserDefaults.standard.set(languages, forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                }
            }
            if needsRestart {
                HStack(spacing: 12) {
                    Text("Takes effect after relaunching hostflip.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Relaunch Now") { relaunch() }
                }
            }

            Picker(
                "Show Dock Icon",
                selection: Binding(
                    get: { dockIconStore.policy },
                    set: { dockIconStore.setPolicy($0) }
                )
            ) {
                ForEach(DockIconVisibilityPolicy.allCases, id: \.rawValue) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            Text("The menu bar icon is always shown.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLoginStore.isEnabled },
                set: { launchAtLoginStore.setEnabled($0) }
            ))
            Text("hostflip starts silently in the menu bar when you log in.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            // Reread on every window open — System Settings' per-app language
            // writes the same key and must be reflected here.
            languageSelection = Self.storedLanguageSelection()
        }
    }

    /// Reads the app-domain override via persistentDomain: array(forKey:) walks the
    /// search list and inherits the global language order, so it can never
    /// distinguish "follow system" from an override.
    private static func storedLanguageSelection() -> LanguagePreference {
        let domain = Bundle.main.bundleIdentifier
            .flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        return LanguagePreference(override: domain?["AppleLanguages"] as? [String])
    }

    /// Only prompts when the selection's post-relaunch language differs from this
    /// launch's — flipping between "System" and the language the system already
    /// resolves to stays quiet.
    private var needsRestart: Bool {
        let launchLanguage = LanguagePreference.match(locale) ?? "en"
        return languageSelection.effectiveLanguage(
            systemLanguages: systemLanguages(fallbackLanguage: launchLanguage)
        ) != launchLanguage
    }

    /// The full system language list, read from the global domain (the app domain's
    /// own override would shadow it); unreadable → this launch's language.
    private func systemLanguages(fallbackLanguage: String) -> [String] {
        let raw = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return raw as? [String] ?? [fallbackLanguage]
    }

    /// A detached shell waits for this process to exit, then reopens the bundle —
    /// the relaunch survives NSApp.terminate tearing this process down.
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open "$2""#,
            "hostflip-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundlePath
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// The discoverable home of update checking (#34); Sparkle owns the persisted
/// automatic-check preference, this view only mirrors it.
private struct UpdatesSettingsView: View {
    let updater: SPUUpdater
    @State private var automaticallyChecksForUpdates: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    var body: some View {
        Form {
            LabeledContent("Current Version") {
                Text("v\(HostflipBuild.version)")
                    .foregroundStyle(.secondary)
            }

            Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                    updater.automaticallyChecksForUpdates = newValue
                }

            CheckForUpdatesButton(updater: updater)
        }
        .padding(20)
    }
}

/// Sparkle drives the whole check-and-install flow with its own UI; this button only forwards the
/// click and mirrors `canCheckForUpdates` (false while a check or install is already in flight).
struct CheckForUpdatesButton: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
