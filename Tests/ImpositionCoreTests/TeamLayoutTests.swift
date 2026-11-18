import XCTest
@testable import ImpositionCore

final class TeamLayoutTests: XCTestCase {
    private func project(count: Int, duplex: Bool = false, mixed: Bool = false) -> Project {
        let pages = (1...count).map { number in
            SourcePage(number: number, trimSize: mixed && number.isMultiple(of: 3) ? Size(66, 35) : Size(45, 40), availableBleed: 2)
        }
        var project = Project(pages: pages, binding: .gang, sheet: SheetSpec(preset: .a4))
        project.sheet.size = Size(170, 130)
        project.sheet.gutter = 4
        project.sheet.gripperWidth = 8
        project.sheet.margins = Insets(left: 4, right: 4, top: 4, bottom: 4)
        var team = TeamSettings()
        team.duplex = duplex
        team.quantity = 11
        team.waste.mode = .fixed
        team.waste.fixed = 2
        project.team = team
        var gang = GangSettings()
        let id = UUID()
        gang.jobs = stride(from: 0, to: count, by: duplex ? 2 : 1).map { index in
            var job = GangJob(sourceID: id, name: "Sayfa \(index + 1)", front: pages[index],
                              back: duplex && index + 1 < count ? pages[index + 1] : nil)
            job.bleed = 2
            return job
        }
        project.gang = gang
        return project
    }

    func testLargeMixedTeamsUseMultipleLayoutsWithoutPartialCopies() throws {
        for count in [13, 26, 70] {
            let project = project(count: count, mixed: true)
            let plan = ImpositionPlanner.plan(project)
            XCTAssertTrue(plan.canExport, "\(plan.issues)")
            XCTAssertGreaterThan(plan.sheets.count, 1)
            let summary = try XCTUnwrap(plan.teamSummary)
            XCTAssertTrue(summary.fastSolution)
            let capacity = try XCTUnwrap(summary.teamsPerLayout.first)
            let printed = plan.sheets.flatMap { $0.front.slots.compactMap(\.sourcePageNumber) }
            XCTAssertEqual(printed.sorted(), (1...count).flatMap { Array(repeating: $0, count: capacity) })
            XCTAssertEqual(plan.totalPressSheets, plan.sheets.count * (1 + 10 / capacity + 2))
            XCTAssertEqual(summary.plateCount, plan.sheets.count)
        }
    }

    func testRepeatsAreWholeAndRotationCanBeRequired() throws {
        var project = project(count: 3)
        project.sheet.size = Size(230, 160)
        let plan = ImpositionPlanner.plan(project)
        XCTAssertTrue(plan.canExport, "\(plan.issues)")
        let copies = try XCTUnwrap(plan.teamSummary?.teamsPerLayout.first)
        XCTAssertGreaterThan(copies, 1)
        XCTAssertEqual(plan.sheets.first?.front.slots.count, 3 * copies)

        project = self.project(count: 2)
        project.sheet.size = Size(64, 100)
        project.sheet.orientation = .portrait
        project.sheet.gripperWidth = 0
        project.settings.cropMarkLength = 0
        project.settings.cropMarkOffset = 0
        // Give the printable area room for only the rotated width.
        project.sheet.margins.left = 9
        project.sheet.margins.right = 9
        XCTAssertTrue(ImpositionPlanner.plan(project).canExport)
        project.team?.allowRotation = false
        XCTAssertFalse(ImpositionPlanner.plan(project).canExport)
    }

    func testDuplexRegistrationAndPlateCountsForEveryTurn() throws {
        for method in [TurnMethod.sheetwise, .workAndTurn, .workAndTumble] {
            var project = project(count: 13, duplex: true)
            project.settings.turnMethod = method
            let plan = ImpositionPlanner.plan(project)
            XCTAssertTrue(plan.canExport, "\(plan.issues)")
            for sheet in plan.sheets {
                for front in sheet.front.slots where front.itemSide == .front {
                    let back = try XCTUnwrap(sheet.back.slots.first {
                        $0.itemSide == .back && $0.copyIndex == front.copyIndex && $0.gangBlockID == front.gangBlockID
                    })
                    XCTAssertEqual(front.size, back.size)
                    XCTAssertEqual(back.sourcePageNumber, front.sourcePageNumber == 13 ? nil : front.sourcePageNumber.map { $0 + 1 })
                    XCTAssertEqual(back.x, sheet.backFlipsX ? sheet.size.width - front.x - front.size.width : front.x, accuracy: 0.000001)
                    XCTAssertEqual(back.y, sheet.backFlipsX ? front.y : sheet.size.height - front.y - front.size.height, accuracy: 0.000001)
                }
            }
            let plates = plan.sheets.count + (method == .sheetwise ? plan.sheets.filter { $0.hasContent(on: .back) }.count : 0)
            XCTAssertEqual(plan.teamSummary?.plateCount, plates)
        }
    }

    func testInvalidDuplexAndIncompleteManualLayoutBlockExport() throws {
        var project = project(count: 13, duplex: true, mixed: true)
        XCTAssertFalse(ImpositionPlanner.plan(project).canExport)
        project = self.project(count: 13)
        var manual = ImpositionPlanner.plan(project).sheets.compactMap { $0.gangLayout?.blocks }
        XCTAssertFalse(manual.isEmpty)
        manual[0].removeAll()
        project.team?.manualLayouts = manual
        XCTAssertFalse(ImpositionPlanner.plan(project).canExport)
    }

    func testCostUsesTeamQuantityPhysicalSheetsAndPlateCount() throws {
        var project = project(count: 26, duplex: true)
        let plan = ImpositionPlanner.plan(project)
        XCTAssertTrue(plan.canExport, "\(plan.issues)")
        var paper = PriceEntry(kind: .paper, name: "Kâğıt")
        paper.size = project.sheet.size
        paper.price = 2
        var press = PriceEntry(kind: .offset, name: "Ofset")
        press.colors = 4
        press.platePrice = 10
        press.setupPrice = 1
        press.price = 100
        var library = PriceLibrary()
        library.entries = [paper, press]
        library.margin = 0
        library.vat = 0
        var costing = JobCostSettings()
        costing.paper = PriceSelection(paper.id)
        costing.printing = PriceSelection(press.id)
        project.costing = costing
        let cost = CostCalculator.calculate(project: project, plan: plan, library: library)
        XCTAssertTrue(cost.missing.isEmpty, "\(cost.missing)")
        XCTAssertEqual(cost.quantity, 11)
        XCTAssertEqual(cost.sheets, plan.totalPressSheets)
        XCTAssertEqual(cost.lines.first { $0.name == "Ofset kalıp" }?.quantity,
                       Decimal(4 * (try XCTUnwrap(plan.teamSummary).plateCount)))
    }
}
