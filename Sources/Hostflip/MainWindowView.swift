import AppKit
import HostflipCore
import SwiftUI
import UniformTypeIdentifiers

/// Main window (the two-pane skeleton decided in #6): a sidebar source list + a full-height editor on the right.
/// #20 pins Base Hosts on top, #21 adds the standalone profiles section, #22 adds group management, moving between groups, and reordering.
struct MainWindowView: View {
    /// The sidebar selects the object being edited; activation controls are handled separately and never change the selection.
    enum SidebarItem: Hashable {
        case systemHosts
        case baseHosts
        case profile(Profile.ID)
    }

    private enum SidebarDragItem: Hashable {
        private static let profilePrefix = "hostflip-profile:"
        private static let groupPrefix = "hostflip-group:"

        case profile(Profile.ID)
        case group(HostflipCore.Group.ID)

        var payload: String {
            switch self {
            case .profile(let profileID): Self.profilePrefix + profileID.rawValue
            case .group(let groupID): Self.groupPrefix + groupID.rawValue
            }
        }

        var provider: NSItemProvider {
            NSItemProvider(object: payload as NSString)
        }

        /// The drag identity with session mechanics stripped, for SidebarDropPlan.
        var planItem: SidebarDropPlan.Item {
            switch self {
            case .profile(let profileID): .profile(profileID)
            case .group(let groupID): .group(groupID)
            }
        }
    }

    private struct SidebarDragSourceModifier: ViewModifier {
        @Binding var draggedItem: SidebarDragItem?
        @Binding var feedback: SidebarDropPlan.Feedback?
        @Binding var hoveredItem: SidebarDragItem?
        @State private var isHovering = false
        let item: SidebarDragItem
        let name: String

        func body(content: Content) -> some View {
            content
                .contentShape(Rectangle())
                .onHover { hovering in
                    guard hovering != isHovering else { return }
                    isHovering = hovering
                    if hovering {
                        // Same stale-drag cleanup as the row-level hover handlers:
                        // hover events cannot arrive while a drag session is tracking.
                        if draggedItem != nil {
                            draggedItem = nil
                            feedback = nil
                        }
                        hoveredItem = item
                        NSCursor.openHand.push()
                    } else {
                        if hoveredItem == item {
                            hoveredItem = nil
                        }
                        NSCursor.pop()
                    }
                }
                .onDisappear {
                    if isHovering {
                        NSCursor.pop()
                        isHovering = false
                    }
                    if hoveredItem == item {
                        hoveredItem = nil
                    }
                }
                .onDrag({
                    draggedItem = item
                    return item.provider
                }) {
                    Text(name)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .onDisappear {
                            Task { @MainActor in
                                await Task.yield()
                                guard draggedItem == item else { return }
                                draggedItem = nil
                                feedback = nil
                            }
                        }
                }
                .help("Drag to Move")
                .accessibilityHint("Drag to move")
        }
    }

    private struct SidebarDropTargetModifier: ViewModifier {
        @Binding var feedback: SidebarDropPlan.Feedback?
        @Binding var draggedItem: SidebarDragItem?
        @State private var height: CGFloat = 1
        let proposal: (SidebarDragItem, CGPoint, CGFloat) -> SidebarDropPlan.Feedback?
        let perform: (SidebarDragItem, CGPoint, CGFloat) -> Bool

        func body(content: Content) -> some View {
            content
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { height = geometry.size.height }
                            .onChange(of: geometry.size.height) { height = geometry.size.height }
                    }
                }
                .onDrop(
                    of: [.plainText],
                    delegate: SidebarDropTargetDelegate(
                        feedback: $feedback,
                        draggedItem: $draggedItem,
                        height: height,
                        proposal: proposal,
                        perform: perform
                    )
                )
        }
    }

    private struct SidebarDropTargetDelegate: DropDelegate {
        @Binding var feedback: SidebarDropPlan.Feedback?
        @Binding var draggedItem: SidebarDragItem?
        let height: CGFloat
        let proposal: (SidebarDragItem, CGPoint, CGFloat) -> SidebarDropPlan.Feedback?
        let perform: (SidebarDragItem, CGPoint, CGFloat) -> Bool

        func validateDrop(info: DropInfo) -> Bool {
            proposedFeedback(info: info) != nil
        }

        func dropEntered(info: DropInfo) {
            feedback = proposedFeedback(info: info)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            guard let proposedFeedback = proposedFeedback(info: info) else {
                feedback = nil
                return DropProposal(operation: .forbidden)
            }
            feedback = proposedFeedback
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            feedback = nil
        }

        func performDrop(info: DropInfo) -> Bool {
            defer {
                feedback = nil
                draggedItem = nil
            }
            guard let item = dragItem(info: info) else { return false }
            return perform(item, info.location, height)
        }

        private func proposedFeedback(info: DropInfo) -> SidebarDropPlan.Feedback? {
            guard let item = dragItem(info: info) else { return nil }
            return proposal(item, info.location, height)
        }

        private func dragItem(info: DropInfo) -> SidebarDragItem? {
            guard !info.itemProviders(for: [.plainText]).isEmpty else { return nil }
            return draggedItem
        }
    }

    let store: WorkspaceStore
    let maintenanceStore: MaintenanceStore
    @State private var selection: SidebarItem? = .baseHosts
    /// The profile pending deletion confirmation; a non-nil value shows the confirmation dialog.
    @State private var profilePendingDeletion: Profile?
    @State private var profilePendingNameFocus: Profile.ID?
    @State private var groupPendingRename: HostflipCore.Group.ID?
    @State private var groupNameDraft = ""
    @State private var groupPendingDeletion: HostflipCore.Group?
    /// Sidebar view state only, never part of the workspace model: groups the user
    /// folded up. Absence means expanded, so new groups start open.
    @State private var collapsedGroups: Set<HostflipCore.Group.ID> = []
    @State private var draggedSidebarItem: SidebarDragItem?
    @State private var sidebarDropFeedback: SidebarDropPlan.Feedback?
    @State private var hoveredSidebarItem: SidebarDragItem?
    @State private var hoveredSidebarActions: SidebarDragItem?
    @FocusState private var focusedGroupName: HostflipCore.Group.ID?
    @FocusState private var focusedSidebarActions: SidebarDragItem?
    /// The row name's custom tap gesture (it coexists with the drag source) selects
    /// without giving the list first-responder status the way a native row click
    /// does; tracking focus lets that gesture hand it back, so the selection shows
    /// emphasized and the Return shortcut is live right after a click.
    @FocusState private var sidebarHasFocus: Bool

    /// Live workspace queries: each proposal re-asks the store (items can
    /// vanish mid-drag), reusing its existing lookups instead of copying IDs.
    private var dropPlanSnapshot: SidebarDropPlan.Snapshot {
        SidebarDropPlan.Snapshot(
            profileExists: { store.profile($0) != nil },
            groupExists: { groupID in store.groups.contains { $0.id == groupID } },
            standaloneProfileCount: store.standaloneProfiles.count
        )
    }

    /// One drop target, fully wired: SidebarDropPlan decides, the view renders
    /// and executes.
    private func sidebarDropTarget(_ target: SidebarDropPlan.Target) -> SidebarDropTargetModifier {
        SidebarDropTargetModifier(
            feedback: $sidebarDropFeedback,
            draggedItem: $draggedSidebarItem,
            proposal: { item, location, height in
                SidebarDropPlan.feedback(
                    dragging: item.planItem, over: target,
                    at: location, height: height, snapshot: dropPlanSnapshot
                )
            },
            perform: { item, location, height in
                guard let move = SidebarDropPlan.move(
                    dragging: item.planItem, over: target,
                    at: location, height: height, snapshot: dropPlanSnapshot
                ) else { return false }
                switch move {
                case .insertProfile(let profileID, let groupID, let index):
                    store.insertProfile(profileID, toGroup: groupID, at: index)
                case .insertGroup(let groupID, let index):
                    store.insertGroup(groupID, at: index)
                }
                return true
            }
        )
    }

    private var presentation: MainWindowPresentation {
        MainWindowPresentation(
            isPaused: store.isPaused,
            hasHostsDrift: store.hasHostsDrift,
            helperStatus: maintenanceStore.helperStatus,
            switchFeedback: store.switchFeedback,
            backgroundSyncError: store.backgroundSyncError,
            profileCount: store.standaloneProfiles.count + store.groups.reduce(0) { $0 + $1.profiles.count },
            isSwitching: store.isSwitching
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("hostflip")
        .modifier(HideWindowToolbarTitle())
        .onAppear {
            store.loadIfNeeded()
            // The window opens with the sidebar holding key focus, so the default
            // selection shows emphasized and Return works before any click.
            // defaultFocus does not reach a List inside NavigationSplitView on
            // macOS, and setting FocusState during view installation is dropped —
            // defer it one runloop turn.
            DispatchQueue.main.async { sidebarHasFocus = true }
        }
        .task(id: store.switchFeedback) {
            await maintenanceStore.refreshHelperStatus()
            guard store.switchFeedback == .merged else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard store.switchFeedback == .merged else { return }
            store.clearSwitchFeedback()
        }
        .onChange(of: store.switchFeedback) {
            if store.switchFeedback == .baseHostsReplaced {
                selection = .baseHosts
            }
        }
        // App activation, not scenePhase: on macOS the phase only flips when every
        // window closes, so returning from System Settings never triggered it.
        // SMAppService posts no status-change notification; re-reading on activation
        // is the DTS-recommended way to catch toggles made in System Settings.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            store.refreshSystemHosts()
            Task { await maintenanceStore.refreshHelperStatus() }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HelperToolbarControl(store: store, maintenanceStore: maintenanceStore)
            }

            ToolbarItem(placement: .automatic) {
                Toggle("Enable hostflip", isOn: Binding(
                    get: { !store.isPaused },
                    set: { store.setPaused(!$0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(store.model == nil || store.isSwitching || store.hasHostsDrift)
                .help(store.isPaused ? "Resume hostflip" : "Pause hostflip")
                .accessibilityLabel("Enable hostflip")
                .padding(.trailing, 8)
            }
            .hidingSharedBackgroundWhenAvailable()
        }
        .background {
            NativeToolbarFlexibleSpace(trailingItemCount: 1)
        }
        .confirmationDialog(
            "Delete “\(profilePendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let profile = profilePendingDeletion else { return }
                store.deleteProfile(profile.id)
                if selection == .profile(profile.id) {
                    selection = .baseHosts
                }
            }
        } message: {
            Text("The profile’s content will be removed. Base hosts and other profiles are not affected.")
        }
        .confirmationDialog(
            "Delete “\(groupPendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { groupPendingDeletion != nil },
                set: { if !$0 { groupPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                guard let group = groupPendingDeletion else { return }
                store.deleteGroup(group.id)
            }
        } message: {
            if let group = groupPendingDeletion {
                if group.profiles.isEmpty {
                    Text("The empty group will be deleted. Base hosts and other groups are not affected.")
                } else {
                    Text("Its \(group.profiles.count) profile\(group.profiles.count == 1 ? "" : "s") will move to Standalone Profiles in the current order. Their content and active state will be preserved. Base hosts and other groups are not affected.")
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Label {
                Text("System Hosts")
            } icon: {
                Image(systemName: "cpu")
                    .foregroundStyle(.blue)
            }
            .tag(SidebarItem.systemHosts)
            Label("Base Hosts", systemImage: "lock.fill")
                .tag(SidebarItem.baseHosts)
            Section {
                if !presentation.showsEmptyState {
                    ForEach(store.standaloneProfiles) { profile in
                        sidebarProfileRow(
                            profile,
                            groupID: nil,
                            index: store.standaloneProfiles.firstIndex(where: { $0.id == profile.id }) ?? 0
                        )
                    }
                }
            } header: {
                Text("Standalone Profiles")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .modifier(sidebarDropTarget(.standaloneHeader))
                    .overlay {
                        if sidebarDropFeedback == .profileContainer(nil) {
                            containerDropIndicator
                        }
                    }
            }
            ForEach(Array(store.groups.enumerated()), id: \.element.id) { groupIndex, group in
                // Collapse is drawn by hand (conditional rows + own chevron): the native
                // Section(isExpanded:) chevron fights the custom header's trailing
                // controls and reflows them when collapsed.
                Section {
                    if !collapsedGroups.contains(group.id) {
                        ForEach(group.profiles) { profile in
                            sidebarProfileRow(
                                profile,
                                groupID: group.id,
                                index: group.profiles.firstIndex(where: { $0.id == profile.id }) ?? 0
                            )
                        }
                    }
                    if sidebarDropFeedback == .group(group.id, .after) {
                        insertionDropIndicator
                    }
                } header: {
                    groupHeader(group, index: groupIndex)
                }
            }
        }
        .listStyle(.sidebar)
        .focused($sidebarHasFocus)
        .onKeyPress(.return) {
            toggleSelectedProfileActivation() ? .handled : .ignored
        }
        .overlay {
            if presentation.showsEmptyState {
                sidebarEmptyState
                    .offset(y: 24)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 236)
        .safeAreaInset(edge: .bottom, spacing: 0) { newItemBar }
    }

    /// Return on the sidebar mirrors clicking the selected profile's activation
    /// control. Returns false when the key is not for us — no profile selected,
    /// activation disabled, or a group rename field waiting for its Return.
    private func toggleSelectedProfileActivation() -> Bool {
        guard groupPendingRename == nil,
              case .profile(let profileID) = selection,
              store.profile(profileID) != nil,
              !presentation.activationControlsDisabled else { return false }
        store.setProfileActive(profileID, !store.isActive(profileID))
        return true
    }

    private func toggleGroupCollapsed(_ id: HostflipCore.Group.ID) {
        withAnimation {
            if collapsedGroups.contains(id) {
                collapsedGroups.remove(id)
            } else {
                collapsedGroups.insert(id)
            }
        }
    }

    private var sidebarEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No Profiles Yet")
                .fontWeight(.semibold)
            Text("Create a profile to switch hosts without changing Base Hosts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
            Button("Create Profile") {
                createProfile()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }

    /// Global create entry at the bottom left (#6): new profiles land in the standalone area; new groups start empty.
    private var newItemBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Menu {
                    Button {
                        createProfile()
                    } label: {
                        Label("New Profile", systemImage: "doc.badge.plus")
                    }
                    .keyboardShortcut("n", modifiers: [.command])
                    Button {
                        createGroup()
                    } label: {
                        Label("New Group", systemImage: "folder.badge.plus")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        // The list scrolls under this inset; without a backing material the rows
        // show through and collide with the New button.
        .background(.bar)
    }

    private func sidebarProfileRow(
        _ profile: Profile,
        groupID: HostflipCore.Group.ID?,
        index: Int
    ) -> some View {
        let item = SidebarDragItem.profile(profile.id)
        let isSelected = selection == .profile(profile.id)
        return HStack(spacing: 4) {
            profileActivationControl(profile, groupID: groupID, isSelected: isSelected)
            HStack(spacing: 0) {
                Text(profile.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .modifier(SidebarDragSourceModifier(
                draggedItem: $draggedSidebarItem,
                feedback: $sidebarDropFeedback,
                hoveredItem: $hoveredSidebarItem,
                item: item,
                name: profile.name
            ))
            .highPriorityGesture(
                TapGesture().onEnded {
                    selection = .profile(profile.id)
                    sidebarHasFocus = true
                }
            )
            .accessibilityLabel(profile.name)
            .accessibilityHint("Select for editing. Drag to move.")
            ZStack {
                Menu {
                    profileActionButtons(profile, groupID: groupID, index: index)
                } label: {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .focused($focusedSidebarActions, equals: item)
                .help("Profile Actions")
                .accessibilityLabel("Actions for \(profile.name)")
                if hoveredSidebarActions == item {
                    Circle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 22, height: 22)
                        .allowsHitTesting(false)
                }
                Image(systemName: "ellipsis")
                    .foregroundStyle(
                        isSelected ? Color.white : Color(nsColor: .labelColor)
                    )
                    .opacity(sidebarActionsAreVisible(for: item) ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .onHover { updateSidebarActionHover(item, hovering: $0) }
        }
            .contentShape(Rectangle())
            .onHover { updateSidebarHover(item, hovering: $0) }
            .background {
                if sidebarHoverBackgroundIsVisible(for: item, isSelected: isSelected) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .tag(SidebarItem.profile(profile.id))
            .modifier(sidebarDropTarget(.profileRow(profile.id, groupID: groupID, index: index)))
            .overlay(alignment: .top) {
                if sidebarDropFeedback == .profile(profile.id, .before) {
                    insertionDropIndicator
                }
            }
            .overlay(alignment: .bottom) {
                if sidebarDropFeedback == .profile(profile.id, .after) {
                    insertionDropIndicator
                }
            }
            .contextMenu {
                profileActionButtons(profile, groupID: groupID, index: index)
            }
    }

    private func createProfile() {
        guard let profileID = store.createStandaloneProfile() else { return }
        selection = .profile(profileID)
        profilePendingNameFocus = profileID
    }

    private func createProfile(in groupID: HostflipCore.Group.ID) {
        guard let profileID = store.createProfile(in: groupID) else { return }
        selection = .profile(profileID)
        profilePendingNameFocus = profileID
    }


    private func createGroup() {
        guard let groupID = store.createGroup(),
              let group = store.groups.first(where: { $0.id == groupID }) else { return }
        beginRenaming(group)
    }

    @ViewBuilder
    private func groupHeader(_ group: HostflipCore.Group, index: Int) -> some View {
        let item = SidebarDragItem.group(group.id)
        HStack(spacing: 4) {
            if groupPendingRename == group.id {
                TextField("Group Name", text: $groupNameDraft)
                    .textFieldStyle(.plain)
                    .focused($focusedGroupName, equals: group.id)
                    .onSubmit { commitGroupRename(group) }
                    .onExitCommand { cancelGroupRename() }
                    .onChange(of: focusedGroupName) {
                        if focusedGroupName != group.id, groupPendingRename == group.id {
                            commitGroupRename(group)
                        }
                    }
            } else {
                HStack(spacing: 0) {
                    Text(group.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .modifier(SidebarDragSourceModifier(
                    draggedItem: $draggedSidebarItem,
                    feedback: $sidebarDropFeedback,
                    hoveredItem: $hoveredSidebarItem,
                    item: item,
                    name: group.name
                ))
                // Scoped to the name area so it can never race the ⋯ menu or the
                // chevron button for a click.
                .onTapGesture { toggleGroupCollapsed(group.id) }
            }
            ZStack {
                Menu {
                    groupActionButtons(group, index: index)
                } label: {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .focused($focusedSidebarActions, equals: item)
                .help("Group Actions")
                .accessibilityLabel("Actions for \(group.name)")
                if hoveredSidebarActions == item {
                    Circle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 22, height: 22)
                        .allowsHitTesting(false)
                }
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .opacity(sidebarActionsAreVisible(for: item) ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .onHover { updateSidebarActionHover(item, hovering: $0) }
            // Always-visible chevron in a fixed trailing slot (group names vary in
            // width, so a name-adjacent chevron would wander); the hover-only ⋯ sits
            // just inside it. A tap gesture, not a Button: a Button's action runs in
            // its own transaction, which drops withAnimation on the list's row diff.
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(collapsedGroups.contains(group.id) ? 0 : 90))
                .frame(width: 16, height: 28)
                .contentShape(Rectangle())
                .onTapGesture { toggleGroupCollapsed(group.id) }
                .help(collapsedGroups.contains(group.id) ? "Expand Group" : "Collapse Group")
                .accessibilityLabel(
                    collapsedGroups.contains(group.id)
                        ? "Expand \(group.name)" : "Collapse \(group.name)"
                )
                .accessibilityAddTraits(.isButton)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { updateSidebarHover(item, hovering: $0) }
        .background {
            if sidebarHoverBackgroundIsVisible(for: item, isSelected: false) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        // Counter the inner breathing-room padding so the title text left-aligns
        // with the plain "Standalone Profiles" header; the hover box extends left.
        .padding(.leading, -6)
        .padding(.trailing, 6)
        .modifier(sidebarDropTarget(
            .groupHeader(group.id, index: index, memberCount: group.profiles.count)
        ))
        .overlay {
            if sidebarDropFeedback == .profileContainer(group.id) {
                containerDropIndicator
            }
        }
        .overlay(alignment: .top) {
            if sidebarDropFeedback == .group(group.id, .before) {
                insertionDropIndicator
            }
        }
        .contextMenu {
            groupActionButtons(group, index: index)
        }
    }

    @ViewBuilder
    private func groupActionButtons(_ group: HostflipCore.Group, index: Int) -> some View {
        Button("New Profile") {
            createProfile(in: group.id)
        }
        Divider()
        Button("Rename Group…") {
            beginRenaming(group)
        }
        Button("Move Up") {
            store.moveGroup(group.id, toIndex: index - 1)
        }
        .disabled(index == 0)
        Button("Move Down") {
            store.moveGroup(group.id, toIndex: index + 1)
        }
        .disabled(index >= store.groups.count - 1)
        Divider()
        Button("Delete Group…", role: .destructive) {
            groupPendingDeletion = group
        }
    }

    private func beginRenaming(_ group: HostflipCore.Group) {
        groupNameDraft = group.name
        groupPendingRename = group.id
        Task { @MainActor in
            await Task.yield()
            focusedGroupName = group.id
        }
    }

    private func commitGroupRename(_ group: HostflipCore.Group) {
        store.renameGroup(group.id, to: groupNameDraft)
        groupPendingRename = nil
        focusedGroupName = nil
    }

    private func cancelGroupRename() {
        groupPendingRename = nil
        focusedGroupName = nil
    }

    @ViewBuilder
    private func profileActionButtons(
        _ profile: Profile,
        groupID: HostflipCore.Group.ID?,
        index: Int
    ) -> some View {
        Button("Rename Profile…") {
            selection = .profile(profile.id)
            profilePendingNameFocus = profile.id
        }
        Button("Move Up") {
            store.moveProfile(profile.id, toGroup: groupID, at: index - 1)
        }
        .disabled(index == 0)
        Button("Move Down") {
            store.moveProfile(profile.id, toGroup: groupID, at: index + 1)
        }
        .disabled(index >= profileCount(in: groupID) - 1)
        Menu("Move To") {
            Button("Standalone Profiles") {
                store.moveProfile(profile.id, toGroup: nil, at: store.standaloneProfiles.count)
            }
            .disabled(groupID == nil)
            ForEach(store.groups) { group in
                Button(group.name) {
                    store.moveProfile(profile.id, toGroup: group.id, at: group.profiles.count)
                }
                .disabled(groupID == group.id)
            }
        }
        Divider()
        // Deletion is disabled while a switch is in flight: the switch must be replayed on the latest model at commit time.
        Button("Delete Profile…", role: .destructive) {
            profilePendingDeletion = profile
        }
        .disabled(store.isSwitching)
    }

    private func profileCount(in groupID: HostflipCore.Group.ID?) -> Int {
        if let groupID {
            return store.groups.first(where: { $0.id == groupID })?.profiles.count ?? 0
        }
        return store.standaloneProfiles.count
    }

    private func profileActivationControl(
        _ profile: Profile,
        groupID: HostflipCore.Group.ID?,
        isSelected: Bool
    ) -> some View {
        let isActive = store.isActive(profile.id)
        let systemImage: String
        if groupID == nil {
            systemImage = isActive ? "checkmark.square.fill" : "square"
        } else {
            systemImage = isActive ? "largecircle.fill.circle" : "circle"
        }
        return Button {
            guard !presentation.activationControlsDisabled else { return }
            store.setProfileActive(profile.id, !isActive)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(
                    isSelected ? Color.primary : isActive ? Color.accentColor : Color.secondary
                )
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(presentation.activationControlsDimmed)
        .opacity(presentation.profilesAreEffective ? 1 : 0.55)
        .accessibilityLabel(isActive ? "Deactivate \(profile.name)" : "Activate \(profile.name)")
        .accessibilityValue(isActive ? "Active" : "Inactive")
    }

    private func sidebarActionsAreVisible(for item: SidebarDragItem) -> Bool {
        draggedSidebarItem == nil
            && (hoveredSidebarItem == item
                || hoveredSidebarActions == item
                || focusedSidebarActions == item)
    }

    private func sidebarHoverBackgroundIsVisible(
        for item: SidebarDragItem,
        isSelected: Bool
    ) -> Bool {
        !isSelected
            && draggedSidebarItem == nil
            && (hoveredSidebarItem == item || hoveredSidebarActions == item)
    }

    private func updateSidebarHover(_ item: SidebarDragItem, hovering: Bool) {
        if hovering {
            clearStaleDragState()
            hoveredSidebarItem = item
        } else if hoveredSidebarItem == item {
            hoveredSidebarItem = nil
        }
    }

    private func updateSidebarActionHover(_ item: SidebarDragItem, hovering: Bool) {
        if hovering {
            clearStaleDragState()
            hoveredSidebarActions = item
        } else if hoveredSidebarActions == item {
            hoveredSidebarActions = nil
        }
    }

    /// Hover events are never delivered while an AppKit drag session is tracking, so
    /// drag state still set when one arrives means the drag ended outside every drop
    /// target (the drag preview's onDisappear is unreliable for cancelled drags).
    /// Left in place, it suppresses hover highlights and the row action buttons.
    private func clearStaleDragState() {
        guard draggedSidebarItem != nil else { return }
        draggedSidebarItem = nil
        sidebarDropFeedback = nil
    }

    private var insertionDropIndicator: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 2)
            .allowsHitTesting(false)
    }

    private var containerDropIndicator: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.accentColor, lineWidth: 2)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var detail: some View {
        if selection == .systemHosts {
            VStack(spacing: 0) {
                MainWindowStateBanner(store: store, presentation: presentation)
                SystemHostsViewerPane(store: store)
            }
        } else if let loadError = store.loadError {
            ContentUnavailableView(
                "Cannot Open Workspace",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else {
            VStack(spacing: 0) {
                MainWindowStateBanner(store: store, presentation: presentation)
                if case .profile(let profileID) = selection, let profile = store.profile(profileID) {
                    ProfileEditorPane(
                        store: store,
                        profile: profile,
                        presentation: presentation,
                        focusName: profilePendingNameFocus == profile.id,
                        nameFocusConsumed: {
                            if profilePendingNameFocus == profile.id {
                                profilePendingNameFocus = nil
                            }
                        },
                        requestDeletion: { profilePendingDeletion = profile }
                    )
                    .id(profile.id) // Rebuild the pane when the profile changes so the name draft never leaks across profiles
                } else {
                    BaseHostsViewerPane(store: store)
                }
            }
        }
    }
}

private struct HelperToolbarControl: View {
    let store: WorkspaceStore
    let maintenanceStore: MaintenanceStore
    @State private var popoverPresenter = HelperPopoverPresenter()

    var body: some View {
        Button {
            popoverPresenter.toggle(store: store, maintenanceStore: maintenanceStore)
        } label: {
            HelperStatusLabel(status: maintenanceStore.helperStatus)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .help("Open Maintenance")
        .background(HelperPopoverAnchor(presenter: popoverPresenter))
    }
}

/// SwiftUI `.popover` rebuilds its host NSToolbarItem when it opens; using NSPopover
/// directly keeps the native look while keeping the trailing items from briefly shifting during the rebuild.
@MainActor
private final class HelperPopoverPresenter: NSObject, NSPopoverDelegate {
    weak var anchorView: NSView?
    private var popover: NSPopover?

    func toggle(store: WorkspaceStore, maintenanceStore: MaintenanceStore) {
        if popover?.isShown == true {
            close()
            return
        }
        guard let anchorView else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: HelperMaintenanceView(
                store: store,
                maintenanceStore: maintenanceStore,
                onDismiss: { [weak self] in self?.close() }
            )
        )
        self.popover = popover
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        popover = nil
    }

    private func close() {
        popover?.performClose(nil)
    }
}

private struct HelperPopoverAnchor: NSViewRepresentable {
    let presenter: HelperPopoverPresenter

    func makeCoordinator() -> HelperPopoverPresenter {
        presenter
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        presenter.anchorView = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: HelperPopoverPresenter) {
        if coordinator.anchorView === nsView {
            coordinator.anchorView = nil
        }
    }
}

/// The single status banner below the title bar: persistent states and action feedback share the same slot to avoid duplicate warnings.
private struct MainWindowStateBanner: View {
    let store: WorkspaceStore
    let presentation: MainWindowPresentation
    @State private var isReviewing = false

    var body: some View {
        if let banner = presentation.banner {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    switch banner {
                    case .paused:
                        Label(
                            "Paused — selections are saved but not applied to the system hosts file.",
                            systemImage: "pause.circle.fill"
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        Spacer(minLength: 12)
                    case .hostsDrift:
                        Label(
                            "System hosts changed outside hostflip. Review the drift to continue switching.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        Spacer(minLength: 12)
                        Button("Review Drift") {
                            isReviewing = true
                        }
                        .controlSize(.small)
                        .fixedSize()
                    case .approvalRequired:
                        Label(
                            "Helper approval is required before switching profiles.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        Spacer(minLength: 12)
                        Button("Open System Settings…") {
                            store.openApprovalSettings()
                        }
                        .controlSize(.small)
                        .fixedSize()
                    case .backgroundSyncError(let message):
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        Spacer(minLength: 12)
                    case .switchFeedback(let feedback):
                        feedbackContent(feedback)
                    }
                    dismissButton(for: banner)
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                Divider()
            }
            .sheet(isPresented: $isReviewing) {
                HostsDriftReviewSheet(store: store)
            }
        }
    }

    @ViewBuilder
    private func dismissButton(for banner: MainWindowPresentation.Banner) -> some View {
        switch banner {
        case .switchFeedback:
            Button {
                store.clearSwitchFeedback()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss Status")
        case .backgroundSyncError:
            Button {
                store.clearBackgroundSyncError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss Status")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func feedbackContent(_ feedback: SwitchFeedback) -> some View {
        switch feedback {
        case .merged:
            EmptyView() // Success feedback only shows briefly in the toolbar and never occupies the problem banner.
        case .baseHostsReplaced:
            Label(feedback.message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(2)
            Spacer(minLength: 12)
        case .needsApproval:
            Label(feedback.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button("Open System Settings…") {
                store.openApprovalSettings()
            }
            .controlSize(.small)
            .fixedSize()
        case .unavailable:
            Label(feedback.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
            Spacer(minLength: 12)
        case .hostsDrift:
            Label(feedback.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button("Review Drift") {
                isReviewing = true
            }
            .controlSize(.small)
            .fixedSize()
        case .failed:
            Label(feedback.message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer(minLength: 12)
        }
    }
}

/// The reconciliation sheet the user opens deliberately: shows the same snapshot of the observed
/// state and maps each choice to WorkspaceStore's public reconcile entry points; on failure the
/// sheet stays open so the user can retry against the latest state.
private struct HostsDriftReviewSheet: View {
    let store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingUseSystemHostsAsBase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Hosts Drift")
                    .font(.title2.bold())
                Text("Review what changed outside hostflip before switching profiles again.")
                    .foregroundStyle(.secondary)
            }

            Group {
                if let comparison = store.hostsDriftComparison {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            diffCountLabel(
                                "+\(comparison.diffSummary.additions) in system hosts",
                                color: .green
                            )
                            diffCountLabel(
                                "−\(comparison.diffSummary.removals) expected",
                                color: .red
                            )
                            Spacer()
                        }

                        GeometryReader { viewport in
                            ScrollView([.horizontal, .vertical]) {
                                // A lazy stack collapses to a near-zero width proposal inside a
                                // horizontal-axis ScrollView, wrapping every row character by character.
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(comparison.diffRows.enumerated()), id: \.offset) { _, row in
                                        diffRow(row)
                                    }
                                }
                                // A two-axis ScrollView centers undersized content; proposing at
                                // least the viewport pins the rows top-leading and stripes them
                                // across the full width.
                                .frame(
                                    minWidth: viewport.size.width,
                                    minHeight: viewport.size.height,
                                    alignment: .topLeading
                                )
                                .textSelection(.enabled)
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

                        Label(
                            "Recommended: add drifted lines to Base Hosts so they are preserved. Discarding replaces the system file with hostflip’s active state.",
                            systemImage: "info.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView(
                        "Diff Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("hostflip could not read the current system hosts file.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = store.reconciliationError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if let reason = store.useSystemHostsAsBaseUnavailableReason {
                Label(reason, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            HStack {
                if store.isReconciling {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reconciling…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Later") {
                    store.reconcileHosts(.later)
                    dismiss()
                }
                Button("Use System Hosts as Base…", role: .destructive) {
                    isConfirmingUseSystemHostsAsBase = true
                }
                .disabled(
                    store.hostsDriftComparison == nil
                        || store.isReconciling
                        || store.useSystemHostsAsBaseUnavailableReason != nil
                )
                Button("Discard Drift", role: .destructive) {
                    store.reconcileHosts(.overwriteDriftWithActiveState)
                }
                .disabled(store.hostsDriftComparison == nil || store.isReconciling)
                Button("Add to Base Hosts") {
                    store.reconcileHosts(.addDriftLinesToBaseHosts)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.hostsDriftComparison == nil || store.isReconciling)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
        .interactiveDismissDisabled(store.isReconciling)
        .confirmationDialog(
            "Use the current System Hosts as Base Hosts?",
            isPresented: $isConfirmingUseSystemHostsAsBase,
            titleVisibility: .visible
        ) {
            Button("Use System Hosts as Base", role: .destructive) {
                store.useSystemHostsAsBase()
            }
        } message: {
            Text("This replaces the current Base Hosts without creating an undo copy. The original hosts.orig backup and /etc/hosts will not be changed.")
        }
        .onChange(of: store.hasHostsDrift) {
            if !store.hasHostsDrift {
                dismiss()
            }
        }
    }

    private func diffCountLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func diffRow(_ row: HostsDriftDiffRow) -> some View {
        let color: Color = row.kind == .added ? .green : .red
        let symbol = row.kind == .added ? "+" : "−"
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(row.lineNumber)")
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
            Text(symbol)
                .foregroundStyle(color)
                .frame(width: 12)
            Text(row.text.isEmpty ? " " : row.text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09))
    }
}

/// Read-only system hosts pane: the content always comes from /etc/hosts and takes no part in workspace editing.
private struct SystemHostsViewerPane: View {
    let store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Hosts")
                        .font(.headline)
                    Text("/etc/hosts · Read Only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if let content = store.systemHostsContent {
                HostsEditor(
                    text: Binding(get: { content }, set: { _ in }),
                    isEditable: false
                )
            } else {
                ContentUnavailableView {
                    Label("Cannot Read System Hosts", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(store.systemHostsReadError ?? "The current /etc/hosts content is unavailable.")
                } actions: {
                    Button("Retry") {
                        store.refreshSystemHosts()
                    }
                }
            }
        }
    }
}

/// Read-only Base Hosts pane: the content can only be updated, in a controlled way, through the drift reconciliation flow.
private struct BaseHostsViewerPane: View {
    let store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Base Hosts")
                        .font(.headline)
                    Text("Protected · Read Only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Always Active", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            HostsEditor(
                text: Binding(get: { store.baseHostsContent }, set: { _ in }),
                isEditable: false
            )
        }
    }
}

/// Profile editor pane: the header holds the renamable profile name, an ownership caption, and
/// the "make active" pill; the body is the highlighting editor. Renames apply on commit or focus
/// loss, never rewriting the profile file per keystroke.
private struct ProfileEditorPane: View {
    let store: WorkspaceStore
    let profile: Profile
    let presentation: MainWindowPresentation
    let focusName: Bool
    let nameFocusConsumed: () -> Void
    let requestDeletion: () -> Void
    @State private var draftName: String
    @FocusState private var nameFieldFocused: Bool

    init(
        store: WorkspaceStore,
        profile: Profile,
        presentation: MainWindowPresentation,
        focusName: Bool,
        nameFocusConsumed: @escaping () -> Void,
        requestDeletion: @escaping () -> Void
    ) {
        self.store = store
        self.profile = profile
        self.presentation = presentation
        self.focusName = focusName
        self.nameFocusConsumed = nameFocusConsumed
        self.requestDeletion = requestDeletion
        _draftName = State(initialValue: profile.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Profile Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .focused($nameFieldFocused)
                        .onSubmit(commitRename)
                        .onChange(of: nameFieldFocused) {
                            if !nameFieldFocused { commitRename() }
                        }
                        .onExitCommand {
                            draftName = profile.name
                            nameFieldFocused = false
                        }
                    Text(locationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SaveErrorText(store: store)
                if store.isSwitching {
                    ProgressView()
                        .controlSize(.small)
                }
                activePill
                Button {
                    requestDeletion()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(store.isSwitching)
                .help("Delete Profile")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            HostsEditor(text: Binding(
                get: { store.profile(profile.id)?.content ?? "" },
                set: { store.updateProfileContent(profile.id, content: $0) }
            ))
        }
        .onAppear { focusNameIfRequested() }
        .onChange(of: focusName) { focusNameIfRequested() }
    }

    private var activePill: some View {
        let isSelectedActive = store.isActive(profile.id)
        let isEffective = isSelectedActive && presentation.profilesAreEffective
        return Button {
            guard !presentation.activationControlsDisabled else { return }
            store.setProfileActive(profile.id, !isSelectedActive)
        } label: {
            Label(
                isSelectedActive ? (isEffective ? "Active" : "Saved Active") : "Make Active",
                systemImage: isSelectedActive ? "checkmark.circle.fill" : "circle"
            )
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    isEffective ? AnyShapeStyle(.green.opacity(0.2)) : AnyShapeStyle(.quaternary),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(presentation.activationControlsDimmed)
    }

    private var locationDescription: String {
        if let group = store.group(containing: profile.id) {
            return "Group: \(group.name) · One profile active at a time"
        }
        return "Standalone profile · Toggles independently"
    }

    private func commitRename() {
        store.renameProfile(profile.id, to: draftName)
        // An empty or whitespace-only name is ignored; the draft falls back to the actual name
        draftName = store.profile(profile.id)?.name ?? draftName
    }

    private func focusNameIfRequested() {
        guard focusName else { return }
        Task { @MainActor in
            await Task.yield()
            nameFieldFocused = true
            nameFocusConsumed()
        }
    }
}

/// SwiftUI has no trailing Toolbar placement on macOS; inserting a native flexible-space into
/// the existing NSToolbar keeps the last group of items pinned to the right edge of the title bar.
private struct NativeToolbarFlexibleSpace: NSViewRepresentable {
    let trailingItemCount: Int

    func makeNSView(context: Context) -> ToolbarFlexibleSpaceInstallerView {
        let view = ToolbarFlexibleSpaceInstallerView()
        view.trailingItemCount = trailingItemCount
        return view
    }

    func updateNSView(_ nsView: ToolbarFlexibleSpaceInstallerView, context: Context) {
        nsView.trailingItemCount = trailingItemCount
        nsView.scheduleInstallation()
    }
}

private final class ToolbarFlexibleSpaceInstallerView: NSView {
    var trailingItemCount = 1
    private weak var observedToolbar: NSToolbar?
    private var isInstalling = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            stopObservingToolbar()
            return
        }
        scheduleInstallation()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func scheduleInstallation() {
        DispatchQueue.main.async { [weak self] in
            self?.installSpace()
        }
    }

    @objc private func toolbarItemsDidChange(_: Notification) {
        guard !isInstalling else { return }
        scheduleInstallation()
    }

    private func installSpace() {
        guard let toolbar = window?.toolbar else { return }
        observe(toolbar)

        let existingIndex = toolbar.items.firstIndex(where: {
            $0.itemIdentifier == .flexibleSpace
        })
        let itemCountWithoutSpace = toolbar.items.count - (existingIndex == nil ? 0 : 1)
        let insertionIndex = max(itemCountWithoutSpace - trailingItemCount, 0)
        guard existingIndex != insertionIndex else { return }

        isInstalling = true
        defer { isInstalling = false }
        if let existingIndex {
            toolbar.removeItem(at: existingIndex)
        }
        toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: insertionIndex)
    }

    private func observe(_ toolbar: NSToolbar) {
        guard observedToolbar !== toolbar else { return }
        stopObservingToolbar()
        observedToolbar = toolbar
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toolbarItemsDidChange(_:)),
            name: NSToolbar.willAddItemNotification,
            object: toolbar
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toolbarItemsDidChange(_:)),
            name: NSToolbar.didRemoveItemNotification,
            object: toolbar
        )
    }

    private func stopObservingToolbar() {
        guard let observedToolbar else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSToolbar.willAddItemNotification,
            object: observedToolbar
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSToolbar.didRemoveItemNotification,
            object: observedToolbar
        )
        self.observedToolbar = nil
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func hidingSharedBackgroundWhenAvailable() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

private struct HideWindowToolbarTitle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// Failure copy for a local workspace save (empty on success).
private struct SaveErrorText: View {
    let store: WorkspaceStore

    var body: some View {
        if let saveError = store.saveError {
            Text(saveError)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
