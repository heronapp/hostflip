import CoreGraphics
import HostflipCore

/// Pure drop-planning for the sidebar. Every rule of sidebar drag-and-drop —
/// edge geometry, validation, destination indices — lives behind these two
/// functions; the view renders the returned feedback and executes the returned
/// move, deciding nothing itself. `feedback` and `move` accept and reject in
/// lockstep: a target that highlights always produces a move.
enum SidebarDropPlan {
    /// What is being dragged, stripped of drag-session mechanics.
    enum Item: Hashable {
        case profile(Profile.ID)
        case group(HostflipCore.Group.ID)
    }

    /// The drop target the pointer is over, with the facts the rules need.
    enum Target: Equatable {
        /// A profile row; `index` is the row's position in its list.
        case profileRow(Profile.ID, groupID: HostflipCore.Group.ID?, index: Int)
        /// The "Standalone Profiles" section header.
        case standaloneHeader
        /// A group's header row; `index` is the group's position.
        case groupHeader(HostflipCore.Group.ID, index: Int, memberCount: Int)
    }

    /// Which half of the hovered row the pointer is in.
    enum Edge: Equatable {
        case before
        case after

        static func at(_ location: CGPoint, height: CGFloat) -> Self {
            location.y < height / 2 ? .before : .after
        }

        var boundaryOffset: Int {
            self == .before ? 0 : 1
        }
    }

    /// The visual promise shown while hovering.
    enum Feedback: Equatable {
        case profile(Profile.ID, Edge)
        case profileContainer(HostflipCore.Group.ID?)
        case group(HostflipCore.Group.ID, Edge)
    }

    /// The action to execute on drop.
    enum Move: Equatable {
        case insertProfile(Profile.ID, toGroup: HostflipCore.Group.ID?, at: Int)
        case insertGroup(HostflipCore.Group.ID, at: Int)
    }

    /// The workspace facts the rules consult. Existence is a query, not copied
    /// data: proposals fire on every hover event, and a dragged item may have
    /// been deleted mid-drag, so each call re-asks the live source without
    /// rebuilding ID sets per event.
    struct Snapshot {
        var profileExists: (Profile.ID) -> Bool
        var groupExists: (HostflipCore.Group.ID) -> Bool
        var standaloneProfileCount: Int
    }

    static func feedback(
        dragging item: Item,
        over target: Target,
        at location: CGPoint,
        height: CGFloat,
        snapshot: Snapshot
    ) -> Feedback? {
        switch (item, target) {
        case (.profile(let dragged), .profileRow(let rowProfile, _, _))
            where snapshot.profileExists(dragged):
            return .profile(rowProfile, .at(location, height: height))
        case (.profile(let dragged), .standaloneHeader)
            where snapshot.profileExists(dragged):
            return .profileContainer(nil)
        case (.profile(let dragged), .groupHeader(let groupID, _, _))
            where snapshot.profileExists(dragged):
            return .profileContainer(groupID)
        case (.group(let dragged), .groupHeader(let groupID, _, _))
            where dragged != groupID && snapshot.groupExists(dragged):
            return .group(groupID, .at(location, height: height))
        default:
            return nil
        }
    }

    static func move(
        dragging item: Item,
        over target: Target,
        at location: CGPoint,
        height: CGFloat,
        snapshot: Snapshot
    ) -> Move? {
        switch (item, target) {
        case (.profile(let dragged), .profileRow(_, let groupID, let index))
            where snapshot.profileExists(dragged):
            let edge = Edge.at(location, height: height)
            return .insertProfile(dragged, toGroup: groupID, at: index + edge.boundaryOffset)
        case (.profile(let dragged), .standaloneHeader)
            where snapshot.profileExists(dragged):
            return .insertProfile(dragged, toGroup: nil, at: snapshot.standaloneProfileCount)
        case (.profile(let dragged), .groupHeader(let groupID, _, let memberCount))
            where snapshot.profileExists(dragged):
            return .insertProfile(dragged, toGroup: groupID, at: memberCount)
        case (.group(let dragged), .groupHeader(let groupID, let index, _))
            where dragged != groupID && snapshot.groupExists(dragged):
            let edge = Edge.at(location, height: height)
            return .insertGroup(dragged, at: index + edge.boundaryOffset)
        default:
            return nil
        }
    }
}
