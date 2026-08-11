public struct BaseHosts: Equatable, Sendable {
    public var content: String

    public init(content: String) {
        self.content = content
    }
}

public struct Profile: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public let id: ID
    public var name: String
    public var content: String

    public init(id: ID, name: String, content: String) {
        self.id = id
        self.name = name
        self.content = content
    }
}

public struct Group: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public let id: ID
    public var name: String
    public var profiles: [Profile]

    public init(id: ID, name: String, profiles: [Profile]) {
        self.id = id
        self.name = name
        self.profiles = profiles
    }
}

public struct HostsCombination: Equatable, Sendable {
    public let baseHosts: BaseHosts
    public let profiles: [Profile]

    public init(baseHosts: BaseHosts, profiles: [Profile]) {
        self.baseHosts = baseHosts
        self.profiles = profiles
    }
}

public enum ActivationModelError: Error, Equatable, Sendable {
    case duplicateProfileID(Profile.ID)
    case unknownProfile(Profile.ID)
    case duplicateGroupID(Group.ID)
    case unknownGroup(Group.ID)
    case conflictingActiveProfiles(Group.ID)
}

public struct ActivationModel: Sendable {
    /// Base Hosts can be updated by the drift reconciliation flow but never deleted — the model has no operation to remove it.
    public var baseHosts: BaseHosts
    public private(set) var standaloneProfiles: [Profile]
    public private(set) var groups: [Group]
    public private(set) var activeProfileIDs: Set<Profile.ID>
    public private(set) var isPaused: Bool

    public init(
        baseHosts: BaseHosts,
        standaloneProfiles: [Profile],
        groups: [Group],
        activeProfileIDs: Set<Profile.ID> = [],
        isPaused: Bool = false
    ) throws {
        var profileIDs: Set<Profile.ID> = []
        for profile in standaloneProfiles + groups.flatMap(\.profiles) {
            guard profileIDs.insert(profile.id).inserted else {
                throw ActivationModelError.duplicateProfileID(profile.id)
            }
        }

        var groupIDs: Set<Group.ID> = []
        for group in groups {
            guard groupIDs.insert(group.id).inserted else {
                throw ActivationModelError.duplicateGroupID(group.id)
            }
        }

        if let unknownID = activeProfileIDs.first(where: { !profileIDs.contains($0) }) {
            throw ActivationModelError.unknownProfile(unknownID)
        }

        for group in groups {
            let activeInGroup = group.profiles.filter { activeProfileIDs.contains($0.id) }
            guard activeInGroup.count <= 1 else {
                throw ActivationModelError.conflictingActiveProfiles(group.id)
            }
        }

        self.baseHosts = baseHosts
        self.standaloneProfiles = standaloneProfiles
        self.groups = groups
        self.activeProfileIDs = activeProfileIDs
        self.isPaused = isPaused
    }

    public var effectiveCombination: HostsCombination {
        let profiles = isPaused
            ? []
            : (standaloneProfiles + groups.flatMap(\.profiles))
                .filter { activeProfileIDs.contains($0.id) }
        return HostsCombination(baseHosts: baseHosts, profiles: profiles)
    }

    // MARK: - Managing profiles

    /// A new profile lands as a standalone profile, inactive by default.
    public mutating func addProfile(id: Profile.ID, name: String, content: String) throws {
        guard !allProfiles.contains(where: { $0.id == id }) else {
            throw ActivationModelError.duplicateProfileID(id)
        }
        standaloneProfiles.append(Profile(id: id, name: name, content: content))
    }

    public mutating func renameProfile(_ profileID: Profile.ID, to name: String) throws {
        try mutateProfile(profileID) { $0.name = name }
    }

    public mutating func updateProfileContent(_ profileID: Profile.ID, content: String) throws {
        try mutateProfile(profileID) { $0.content = content }
    }

    public mutating func deleteProfile(_ profileID: Profile.ID) throws {
        _ = try removeProfileFromContainer(profileID)
        activeProfileIDs.remove(profileID)
    }

    /// Moves the profile to the end of a group (`nil` = the standalone area), keeping its active state where possible;
    /// the one exception: if the target group already has an active profile, the moved profile becomes inactive to preserve in-group mutual exclusion.
    public mutating func moveProfile(_ profileID: Profile.ID, toGroup groupID: Group.ID?) throws {
        if let groupID, !groups.contains(where: { $0.id == groupID }) {
            throw ActivationModelError.unknownGroup(groupID)
        }
        guard allProfiles.contains(where: { $0.id == profileID }) else {
            throw ActivationModelError.unknownProfile(profileID)
        }

        let profile = try removeProfileFromContainer(profileID)
        guard let groupID else {
            standaloneProfiles.append(profile)
            return
        }

        let index = groups.firstIndex(where: { $0.id == groupID })!
        if groups[index].profiles.contains(where: { activeProfileIDs.contains($0.id) }) {
            activeProfileIDs.remove(profileID)
        }
        groups[index].profiles.append(profile)
    }

    /// Moves the profile to the given position within its current container; out-of-range indices are clamped to the valid range.
    public mutating func moveProfile(_ profileID: Profile.ID, toIndex index: Int) throws {
        if let currentIndex = standaloneProfiles.firstIndex(where: { $0.id == profileID }) {
            let profile = standaloneProfiles.remove(at: currentIndex)
            standaloneProfiles.insert(profile, at: index.clamped(to: 0...standaloneProfiles.count))
            return
        }
        for groupIndex in groups.indices {
            if let currentIndex = groups[groupIndex].profiles.firstIndex(where: { $0.id == profileID }) {
                let profile = groups[groupIndex].profiles.remove(at: currentIndex)
                groups[groupIndex].profiles.insert(
                    profile,
                    at: index.clamped(to: 0...groups[groupIndex].profiles.count)
                )
                return
            }
        }
        throw ActivationModelError.unknownProfile(profileID)
    }

    // MARK: - Managing groups

    public mutating func addGroup(id: Group.ID, name: String) throws {
        guard !groups.contains(where: { $0.id == id }) else {
            throw ActivationModelError.duplicateGroupID(id)
        }
        groups.append(Group(id: id, name: name, profiles: []))
    }

    public mutating func renameGroup(_ groupID: Group.ID, to name: String) throws {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
            throw ActivationModelError.unknownGroup(groupID)
        }
        groups[index].name = name
    }

    /// Deleting a group = dissolving the container: member profiles are appended to the end of the standalone area, keeping their content and active state.
    public mutating func deleteGroup(_ groupID: Group.ID) throws {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
            throw ActivationModelError.unknownGroup(groupID)
        }
        standaloneProfiles.append(contentsOf: groups[index].profiles)
        groups.remove(at: index)
    }

    /// Moves the group to the given position; out-of-range indices are clamped to the valid range.
    public mutating func moveGroup(_ groupID: Group.ID, toIndex index: Int) throws {
        guard let currentIndex = groups.firstIndex(where: { $0.id == groupID }) else {
            throw ActivationModelError.unknownGroup(groupID)
        }
        let group = groups.remove(at: currentIndex)
        groups.insert(group, at: index.clamped(to: 0...groups.count))
    }

    private var allProfiles: [Profile] {
        standaloneProfiles + groups.flatMap(\.profiles)
    }

    private mutating func mutateProfile(
        _ profileID: Profile.ID,
        _ mutate: (inout Profile) -> Void
    ) throws {
        if let index = standaloneProfiles.firstIndex(where: { $0.id == profileID }) {
            mutate(&standaloneProfiles[index])
            return
        }
        for groupIndex in groups.indices {
            if let index = groups[groupIndex].profiles.firstIndex(where: { $0.id == profileID }) {
                mutate(&groups[groupIndex].profiles[index])
                return
            }
        }
        throw ActivationModelError.unknownProfile(profileID)
    }

    /// Removes the profile from its container (the standalone area or a group) and returns it.
    private mutating func removeProfileFromContainer(_ profileID: Profile.ID) throws -> Profile {
        if let index = standaloneProfiles.firstIndex(where: { $0.id == profileID }) {
            return standaloneProfiles.remove(at: index)
        }
        for groupIndex in groups.indices {
            if let index = groups[groupIndex].profiles.firstIndex(where: { $0.id == profileID }) {
                return groups[groupIndex].profiles.remove(at: index)
            }
        }
        throw ActivationModelError.unknownProfile(profileID)
    }

    // MARK: - Activation toggling

    public mutating func setPaused(_ isPaused: Bool) {
        self.isPaused = isPaused
    }

    public mutating func toggleProfile(_ profileID: Profile.ID) throws {
        if standaloneProfiles.contains(where: { $0.id == profileID }) {
            if activeProfileIDs.contains(profileID) {
                activeProfileIDs.remove(profileID)
            } else {
                activeProfileIDs.insert(profileID)
            }
            return
        }

        guard let group = groups.first(where: { group in
            group.profiles.contains(where: { $0.id == profileID })
        }) else {
            throw ActivationModelError.unknownProfile(profileID)
        }

        if activeProfileIDs.contains(profileID) {
            activeProfileIDs.remove(profileID)
            return
        }

        activeProfileIDs.subtract(group.profiles.map(\.id))
        activeProfileIDs.insert(profileID)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
