import XCTest
import ImpositionCore

final class MachineProfileTests: XCTestCase {
    private let front = SourcePage(number: 1, trimSize: Size(118, 80))
    private let back = SourcePage(number: 2, trimSize: Size(118, 80))

    private func project(profile: MachineProfile, binding: BindingMethod = .stepAndRepeat) -> Project {
        var project = Project(pages: [front, back], binding: binding, sheet: SheetSpec(size: Size(210, 297)),
                              settings: ImpositionSettings(bleed: 0, cropMarkLength: 2, cropMarkOffset: 1))
        project.machineProfile = profile
        if binding == .gang {
            var gang = GangSettings()
            var job = GangJob(sourceID: UUID(), name: "Kart", front: front, back: back)
            job.quantity = 1
            job.bleed = 0
            gang.jobs = [job]
            project.gang = gang
        }
        return project
    }

    func testRotationCapacityAndCenteredPerimeterForFlatAndGang() throws {
        for binding in [BindingMethod.stepAndRepeat, .gang] {
            var profile = MachineProfile.heidelberg
            profile.gap = 4
            for (rotation, count, angle) in [(MachineProfile.Rotation.zero, 16, 0), (.ninety, 18, 90), (.automatic, 18, 90)] {
                profile.rotation = rotation
                let plan = ImpositionPlanner.plan(project(profile: profile, binding: binding))
                XCTAssertTrue(plan.canExport, "\(plan.issues)")
                XCTAssertFalse(plan.hasBackContent)
                let sheet = try XCTUnwrap(plan.sheets.first)
                XCTAssertEqual(sheet.size, Size(510, 400))
                let slots = sheet.front.slots
                XCTAssertEqual(slots.count, count)
                XCTAssertTrue(slots.allSatisfy { $0.rotation == angle && $0.sourcePageNumber == 1 })
                let left = try XCTUnwrap(slots.map(\.x).min())
                let right = try XCTUnwrap(slots.map { $0.x+$0.size.width }.max())
                let bottom = try XCTUnwrap(slots.map(\.y).min())
                let top = try XCTUnwrap(slots.map { $0.y+$0.size.height }.max())
                XCTAssertEqual(left + right, 510, accuracy: 0.000001)
                XCTAssertEqual(bottom + top, 430, accuracy: 0.000001)
                let xs = Set(slots.map(\.x)).sorted()
                XCTAssertEqual(xs[1]-xs[0]-slots[0].size.width, 4, accuracy: 0.000001)
                let crops = sheet.front.marks.filter { $0.kind == .crop }
                XCTAssertFalse(crops.isEmpty)
                for mark in crops {
                    for point in [mark.start, mark.end] {
                        XCTAssertTrue(point.x < left || point.x > right || point.y < bottom || point.y > top)
                        XCTAssertGreaterThanOrEqual(point.y, 30)
                    }
                }
            }
        }
    }

    func testWorkAndTurnRetainsPhysicalPairAndGripperOnEachEdge() throws {
        for binding in [BindingMethod.stepAndRepeat, .gang] {
            for edge in [Edge.bottom, .top, .left, .right] {
                var profile = MachineProfile.heidelberg
                profile.faces = .workAndTurn
                profile.rotation = .ninety
                profile.gripperEdge = edge
                let plan = ImpositionPlanner.plan(project(profile: profile, binding: binding))
                XCTAssertTrue(plan.canExport, "\(plan.issues)")
                let sheet = try XCTUnwrap(plan.sheets.first)
                let flipsX = edge == .bottom || edge == .top
                XCTAssertEqual(sheet.backFlipsX, flipsX)
                let backs = Dictionary(uniqueKeysWithValues: sheet.back.slots.map { ($0.copyIndex, $0) })
                for slot in sheet.front.slots {
                    let reverse = try XCTUnwrap(backs[slot.copyIndex])
                    XCTAssertEqual(reverse.sourcePageNumber, slot.sourcePageNumber == 1 ? 2 : 1)
                    XCTAssertEqual(reverse.x, flipsX ? 510-slot.x-slot.size.width : slot.x, accuracy: 0.000001)
                    XCTAssertEqual(reverse.y, flipsX ? slot.y : 400-slot.y-slot.size.height, accuracy: 0.000001)
                    XCTAssertEqual(reverse.rotation, ((flipsX ? 360 : 540)-slot.rotation)%360)
                    switch edge {
                    case .bottom: XCTAssertGreaterThanOrEqual(slot.y, 30)
                    case .top: XCTAssertLessThanOrEqual(slot.y+slot.size.height, 370)
                    case .left: XCTAssertGreaterThanOrEqual(slot.x, 30)
                    case .right: XCTAssertLessThanOrEqual(slot.x+slot.size.width, 480)
                    }
                }
            }
        }
    }

    func testInvalidProfileCannotExport() {
        var profile = MachineProfile.heidelberg
        profile.gripperWidth = profile.size.height
        XCTAssertFalse(ImpositionPlanner.plan(project(profile: profile)).canExport)
    }
}
