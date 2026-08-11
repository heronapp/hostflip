import SwiftUI

struct ApplicationSettingsView: View {
    let dockIconStore: DockIconVisibilityStore

    var body: some View {
        TabView {
            Form {
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
            }
            .padding(20)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
        }
        .frame(width: 460, height: 150)
    }
}
