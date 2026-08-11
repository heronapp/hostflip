import XCTest
@testable import Hostflip
@testable import HostflipCore

/// The sidebar drop rules as pure values: every decision the drag-and-drop
/// mechanics used to make inline (edge geometry, validation, destination
/// indices) is exercised here without a view in sight.
final class SidebarDropPlanTests: XCTestCase {
    private let p1 = Profile.ID("p1")
    private let p2 = Profile.ID("p2")
    private let g1 = HostflipCore.Group.ID("g1")
    private let g2 = HostflipCore.Group.ID("g2")

    private var snapshot: SidebarDropPlan.Snapshot {
        let profiles: Set<Profile.ID> = [p1, p2]
        let groups: Set<HostflipCore.Group.ID> = [g1, g2]
        return SidebarDropPlan.Snapshot(
            profileExists: { profiles.contains($0) },
            groupExists: { groups.contains($0) },
            standaloneProfileCount: 3
        )
    }

    // MARK: - Edge geometry

    func testTopHalfMapsToBeforeAndBottomHalfToAfter() {
        XCTAssertEqual(SidebarDropPlan.Edge.at(CGPoint(x: 0, y: 9.9), height: 20), .before)
        XCTAssertEqual(SidebarDropPlan.Edge.at(CGPoint(x: 0, y: 10), height: 20), .after)
        XCTAssertEqual(SidebarDropPlan.Edge.at(CGPoint(x: 0, y: 19), height: 20), .after)
    }

    // MARK: - Profile row target

    func testProfileOverProfileRowProposesEdgeInsertion() {
        let target = SidebarDropPlan.Target.profileRow(p2, groupID: g1, index: 4)
        XCTAssertEqual(
            SidebarDropPlan.feedback(dragging: .profile(p1), over: target,
                                     at: CGPoint(x: 0, y: 2), height: 20, snapshot: snapshot),
            .profile(p2, .before)
        )
        XCTAssertEqual(
            SidebarDropPlan.move(dragging: .profile(p1), over: target,
                                 at: CGPoint(x: 0, y: 2), height: 20, snapshot: snapshot),
            .insertProfile(p1, toGroup: g1, at: 4)
        )
        XCTAssertEqual(
            SidebarDropPlan.move(dragging: .profile(p1), over: target,
                                 at: CGPoint(x: 0, y: 18), height: 20, snapshot: snapshot),
            .insertProfile(p1, toGroup: g1, at: 5)
        )
    }

    func testProfileRowInStandaloneAreaKeepsNilGroup() {
        let target = SidebarDropPlan.Target.profileRow(p2, groupID: nil, index: 0)
        XCTAssertEqual(
            SidebarDropPlan.move(dragging: .profile(p1), over: target,
                                 at: CGPoint(x: 0, y: 18), height: 20, snapshot: snapshot),
            .insertProfile(p1, toGroup: nil, at: 1)
        )
    }

    func testUnknownProfileOverProfileRowIsRejected() {
        let target = SidebarDropPlan.Target.profileRow(p2, groupID: g1, index: 0)
        let ghost = Profile.ID("deleted-mid-drag")
        XCTAssertNil(SidebarDropPlan.feedback(dragging: .profile(ghost), over: target,
                                              at: .zero, height: 20, snapshot: snapshot))
        XCTAssertNil(SidebarDropPlan.move(dragging: .profile(ghost), over: target,
                                          at: .zero, height: 20, snapshot: snapshot))
    }

    func testGroupOverProfileRowIsRejected() {
        let target = SidebarDropPlan.Target.profileRow(p2, groupID: g1, index: 0)
        XCTAssertNil(SidebarDropPlan.feedback(dragging: .group(g2), over: target,
                                              at: .zero, height: 20, snapshot: snapshot))
    }

    // MARK: - Standalone header target

    func testProfileOverStandaloneHeaderAppendsToStandaloneArea() {
        XCTAssertEqual(
            SidebarDropPlan.feedback(dragging: .profile(p1), over: .standaloneHeader,
                                     at: .zero, height: 20, snapshot: snapshot),
            .profileContainer(nil)
        )
        XCTAssertEqual(
            SidebarDropPlan.move(dragging: .profile(p1), over: .standaloneHeader,
                                 at: .zero, height: 20, snapshot: snapshot),
            .insertProfile(p1, toGroup: nil, at: 3)
        )
    }

    func testGroupOverStandaloneHeaderIsRejected() {
        XCTAssertNil(SidebarDropPlan.feedback(dragging: .group(g1), over: .standaloneHeader,
                                              at: .zero, height: 20, snapshot: snapshot))
    }

    // MARK: - Group header target

    func testProfileOverGroupHeaderAppendsToThatGroup() {
        let target = SidebarDropPlan.Target.groupHeader(g1, index: 0, memberCount: 2)
        XCTAssertEqual(
            SidebarDropPlan.feedback(dragging: .profile(p1), over: target,
                                     at: .zero, height: 20, snapshot: snapshot),
            .profileContainer(g1)
        )
        XCTAssertEqual(
            SidebarDropPlan.move(dragging: .profile(p1), over: target,
                                 at: .zero, height: 20, snapshot: snapshot),
            .insertProfile(p1, toGroup: g1, at: 2)
        )
    }

    func testGroupOverAnotherGroupHeaderProposesEdgeInsertion() {
        let target = SidebarDropPlan.Target.groupHeader(g1, index: 1, memberCount: 2)
        XCTAssertEqual(
            SidebarDropPlan.feedback(dragging: .group(g2), over: target,
                                     at: CGPoint(x: 0, y: 2), height: 20, snapshot: snapshot),
            .group(g1, .before)
        )
        XCTAssertEqual(
            SidebarDropPlan.move(dragging: .group(g2), over: target,
                                 at: CGPoint(x: 0, y: 18), height: 20, snapshot: snapshot),
            .insertGroup(g2, at: 2)
        )
    }

    func testGroupOverItsOwnHeaderIsRejected() {
        let target = SidebarDropPlan.Target.groupHeader(g1, index: 0, memberCount: 2)
        XCTAssertNil(SidebarDropPlan.feedback(dragging: .group(g1), over: target,
                                              at: .zero, height: 20, snapshot: snapshot))
        XCTAssertNil(SidebarDropPlan.move(dragging: .group(g1), over: target,
                                          at: .zero, height: 20, snapshot: snapshot))
    }

    func testUnknownGroupOverGroupHeaderIsRejected() {
        let target = SidebarDropPlan.Target.groupHeader(g1, index: 0, memberCount: 2)
        XCTAssertNil(SidebarDropPlan.feedback(dragging: .group(HostflipCore.Group.ID("ghost")),
                                              over: target, at: .zero, height: 20, snapshot: snapshot))
    }

    // MARK: - Feedback/move coherence

    func testFeedbackAndMoveAgreeOnAcceptance() {
        // A target that highlights must also produce a move, and vice versa —
        // the visual promise and the executed action can never diverge.
        let targets: [SidebarDropPlan.Target] = [
            .profileRow(p2, groupID: g1, index: 0),
            .profileRow(p2, groupID: nil, index: 1),
            .standaloneHeader,
            .groupHeader(g1, index: 0, memberCount: 2),
        ]
        let items: [SidebarDropPlan.Item] = [
            .profile(p1), .profile(Profile.ID("ghost")), .group(g1), .group(g2),
        ]
        for target in targets {
            for item in items {
                let feedback = SidebarDropPlan.feedback(dragging: item, over: target,
                                                        at: .zero, height: 20, snapshot: snapshot)
                let move = SidebarDropPlan.move(dragging: item, over: target,
                                                at: .zero, height: 20, snapshot: snapshot)
                XCTAssertEqual(feedback == nil, move == nil,
                               "divergence for \(item) over \(target)")
            }
        }
    }
}
