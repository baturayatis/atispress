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

    func testExplicitGridAndGripperAnchoredPerimeterForFlatAndGang() throws {
        for binding in [BindingMethod.stepAndRepeat, .gang] {
            var profile = MachineProfile.heidelberg
            profile.gap = 4
            for (rotation, columns, rows, angle) in [(MachineProfile.Rotation.zero, 2, 1, 0), (.zero, 4, 1, 0), (.ninety, 2, 2, 90)] {
                profile.rotation = rotation
                profile.columns = columns
                profile.rows = rows
                let plan = ImpositionPlanner.plan(project(profile: profile, binding: binding))
                XCTAssertTrue(plan.canExport, "\(plan.issues)")
                XCTAssertFalse(plan.hasBackContent)
                let sheet = try XCTUnwrap(plan.sheets.first)
                XCTAssertEqual(sheet.size, Size(510, 400))
                let slots = sheet.front.slots
                XCTAssertEqual(slots.count, columns*rows)
                XCTAssertTrue(slots.allSatisfy { $0.rotation == angle && $0.sourcePageNumber == 1 })
                let left = try XCTUnwrap(slots.map(\.x).min())
                let right = try XCTUnwrap(slots.map { $0.x+$0.size.width }.max())
                let bottom = try XCTUnwrap(slots.map(\.y).min())
                let top = try XCTUnwrap(slots.map { $0.y+$0.size.height }.max())
                XCTAssertEqual(left + right, 510, accuracy: 0.000001)
                XCTAssertEqual(bottom, 30, accuracy: 0.000001)
                let xs = Set(slots.map(\.x)).sorted()
                XCTAssertEqual(xs[1]-xs[0]-slots[0].size.width, 4, accuracy: 0.000001)
                let crops = sheet.front.marks.filter { $0.kind == .crop }
                let lowerHorizontal = crops.filter { $0.start.y == 30 && $0.end.y == 30 }
                XCTAssertEqual(lowerHorizontal.count, 2)
                XCTAssertTrue(lowerHorizontal.allSatisfy { abs($0.start.x-$0.end.x) == 2 })
                let lowerVertical = crops.filter { $0.start.x == $0.end.x && $0.start.y < 30 }
                XCTAssertFalse(lowerVertical.isEmpty)
                XCTAssertTrue(lowerVertical.allSatisfy { $0.start.y == 29 && $0.end.y == 27 })
                XCTAssertTrue(crops.contains { $0.start.y == top+1 && $0.end.y == top+3 })
                for mark in crops {
                    for point in [mark.start, mark.end] {
                        XCTAssertTrue(point.x < left || point.x > right || point.y < bottom || point.y > top)
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
                profile.columns = 2
                profile.rows = 2
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

    func testDefaultAndLegacyGridIsOneByOneAndOversizedGridDoesNotAutomaticallyShrink() {
        for binding in [BindingMethod.stepAndRepeat, .gang] {
            var profile = MachineProfile.heidelberg
            let initial = ImpositionPlanner.plan(project(profile: profile, binding: binding))
            XCTAssertTrue(initial.canExport)
            XCTAssertEqual(initial.sheets.first?.front.slots.count, 1)
            profile.rotation = .automatic
            profile.columns = nil
            profile.rows = nil
            let legacy = ImpositionPlanner.plan(project(profile: profile, binding: binding))
            XCTAssertTrue(legacy.canExport)
            XCTAssertEqual(legacy.sheets.first?.front.slots.count, 1)
            XCTAssertEqual(legacy.sheets.first?.front.slots.first?.rotation, 0)
            profile.rotation = .zero
            profile.columns = 5
            let input = project(profile: profile, binding: binding)
            XCTAssertFalse(ImpositionPlanner.plan(input).canExport)
            XCTAssertEqual(SmartAutoLayout.arrange(input, resetOverrides: true).project.machineProfile, profile)
        }
    }

    func testMixedJobsRequireUserPositionsAndKeepTheirRelativePlacement() throws {
        var profile = MachineProfile.heidelberg
        profile.rotation = .ninety
        profile.columns = 2
        profile.rows = 1
        var input = project(profile: profile, binding: .gang)
        var gang = try XCTUnwrap(input.gang)
        var other = GangJob(sourceID: UUID(), name: "Etiket", front: back)
        other.bleed = 0
        gang.jobs.append(other)
        input.gang = gang
        XCTAssertFalse(ImpositionPlanner.plan(input).canExport)

        gang.mode = .manual
        gang.blocks = [GangBlock(jobID: gang.jobs[0].id, origin: Point(12, 15)),
                       GangBlock(jobID: other.id, origin: Point(192, 15))]
        input.gang = gang
        let plan = ImpositionPlanner.plan(input)
        XCTAssertTrue(plan.canExport, "\(plan.issues)")
        let sheet = try XCTUnwrap(plan.sheets.first)
        let blocks = try XCTUnwrap(sheet.gangLayout?.blocks)
        XCTAssertEqual(blocks[1].origin.x-blocks[0].origin.x, 180)
        XCTAssertEqual(blocks[0].origin.y, 30)
        XCTAssertEqual(sheet.front.slots.count, 4)
        XCTAssertTrue(sheet.front.slots.allSatisfy { $0.rotation == 90 })
    }

    func testInvalidProfileCannotExport() {
        var profile = MachineProfile.heidelberg
        profile.gripperWidth = profile.size.height
        XCTAssertFalse(ImpositionPlanner.plan(project(profile: profile)).canExport)
    }
}
