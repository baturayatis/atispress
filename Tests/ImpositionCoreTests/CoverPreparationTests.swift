import XCTest
import ImpositionCore

final class CoverPreparationTests: XCTestCase {
    private let pages = (1...8).map { SourcePage(number:$0,trimSize:Size(210,297),availableBleed:3) }

    private func project() -> Project {
        var project = Project(pages:pages,binding:.perfectBound,
                              sheet:SheetSpec(size:Size(700,1000),gripperWidth:25,gutter:7,orientation:.portrait))
        project.coverPreparation = CoverPreparationSettings()
        project.coverPreparation?.sheet = project.sheet
        return project
    }

    func testDefaultSelectionZeroSpineAndManualCMYK() throws {
        var input = project()
        let baseline = ImpositionPlanner.plan(input)
        let zero = try XCTUnwrap(CoverPreparationPlanner.plan(input,pages:pages,output:.spread).sheets.first)
        XCTAssertEqual(zero.size,Size(420,297))
        XCTAssertEqual(zero.front.slots.compactMap(\.sourcePageNumber),[8,1])
        XCTAssertEqual(zero.front.slots[0].x+zero.front.slots[0].size.width,zero.front.slots[1].x)
        input.coverPreparation?.front = 3
        input.coverPreparation?.back = 6
        input.coverPreparation?.spineWidth = 10
        let spread = try XCTUnwrap(CoverPreparationPlanner.plan(input,pages:pages,output:.spread).sheets.first)
        XCTAssertEqual(spread.size,Size(430,297))
        XCTAssertEqual(spread.front.slots.map(\.sourcePageNumber),[6,nil,3])
        XCTAssertEqual(spread.front.slots.map(\.x),[0,210,220])
        XCTAssertEqual(spread.front.slots[1].spineArtwork?.content.extendEdges,true)
        XCTAssertEqual(ImpositionPlanner.plan(input).sheets,baseline.sheets)

        input.coverPreparation?.colorMode = .manual
        input.coverPreparation?.color = .cmyk(0.2,0.4,0.6,0.8)
        let manual = try XCTUnwrap(CoverPreparationPlanner.plan(input,pages:pages,output:.spread).sheets.first)
        XCTAssertEqual(manual.front.slots[1].spineArtwork?.content.color,.cmyk(0.2,0.4,0.6,0.8))
        XCTAssertEqual(manual.front.slots[1].spineArtwork?.content.extendEdges,false)
        input.coverPreparation?.colorMode = .picked
        input.coverPreparation?.pickedColor = .rgb(0.25,0.4,0.9)
        XCTAssertEqual(CoverPreparationPlanner.plan(input,pages:pages,output:.spread).sheets.first?
            .front.slots[1].spineArtwork?.content.color,.rgb(0.25,0.4,0.9))
        XCTAssertEqual(input.coverPreparation?.color,.cmyk(0.2,0.4,0.6,0.8))
        input.coverPreparation?.front = 99
        XCTAssertFalse(CoverPreparationPlanner.plan(input,pages:pages,output:.spread).canExport)
    }

    func testAutomaticRotationManualGridGripperBleedAndCutMarks() throws {
        var input = project()
        input.coverPreparation?.spineWidth = 10
        let plan = CoverPreparationPlanner.plan(input,pages:pages,output:.sheet)
        let sheet = try XCTUnwrap(plan.sheets.first)
        XCTAssertEqual(sheet.repeatLayout?.copiesPerSheet,4)
        XCTAssertEqual(Set(sheet.front.slots.map(\.rotation)),[90])
        XCTAssertFalse(sheet.hasContent(on:.back))
        XCTAssertEqual(sheet.front.slots.filter { $0.bookRegion == "Sırt" }.count,4)
        XCTAssertTrue(sheet.front.slots.compactMap(\.artworkClip).allSatisfy { $0.origin.y >= 25 })
        let backs = sheet.front.slots.filter { $0.bookRegion == "Arka kapak" }.sorted { $0.x < $1.x }
        XCTAssertEqual(backs[2].x-backs[0].x,297+7+6,accuracy:0.0001)
        XCTAssertTrue(sheet.front.marks.contains { $0.kind == .crop })
        input.coverPreparation?.grid.rotation = .zero
        XCTAssertEqual(CoverPreparationPlanner.plan(input,pages:pages,output:.sheet).sheets.first?.repeatLayout?.copiesPerSheet,3)

        input.coverPreparation?.sheet = SheetSpec(size:Size(482,355),gripperWidth:15,gutter:10,orientation:.landscape)
        input.coverPreparation?.grid.columns = 1
        input.coverPreparation?.grid.rows = 1
        let centered = try XCTUnwrap(CoverPreparationPlanner.plan(input,pages:pages,output:.sheet).sheets.first)
        input.coverPreparation?.grid.x = 5
        input.coverPreparation?.grid.y = -4
        let shifted = try XCTUnwrap(CoverPreparationPlanner.plan(input,pages:pages,output:.sheet).sheets.first)
        XCTAssertEqual(shifted.size,Size(482,355))
        XCTAssertEqual(shifted.front.slots[0].x-centered.front.slots[0].x,5,accuracy:0.0001)
        XCTAssertEqual(shifted.front.slots[0].y-centered.front.slots[0].y,-4,accuracy:0.0001)
        input.coverPreparation?.grid.x = 100
        XCTAssertFalse(CoverPreparationPlanner.plan(input,pages:pages,output:.sheet).canExport)
    }

    func testMachineProfileGripperAndEditableCoverPaperAndGap() throws {
        var input = project()
        var machine = MachineProfile(name:"Test",size:Size(700,1000))
        machine.gripperEdge = .left
        machine.gripperWidth = 27
        machine.gap = 11
        machine.faces = .workAndTurn
        input.machineProfile = machine
        input.coverPreparation?.sheet = nil
        let sheet = try XCTUnwrap(CoverPreparationPlanner.plan(input,pages:pages,output:.sheet).sheets.first)
        XCTAssertEqual(sheet.size,machine.size)
        XCTAssertEqual(sheet.gripperEdge,.left)
        XCTAssertEqual(sheet.repeatLayout?.copiesPerSheet,4)
        XCTAssertFalse(sheet.hasContent(on:.back))
        let backs = sheet.front.slots.filter { $0.bookRegion == "Arka kapak" }.sorted { $0.x < $1.x }
        XCTAssertEqual(backs[2].x-backs[0].x,297,accuracy:0.0001)
        XCTAssertTrue(sheet.front.slots.compactMap(\.artworkClip).allSatisfy { $0.origin.x >= machine.gripperWidth })
        input.coverPreparation?.sheet = SheetSpec(size:Size(690,990),gutter:11)
        let edited = try XCTUnwrap(CoverPreparationPlanner.plan(input,pages:pages,output:.sheet).sheets.first)
        XCTAssertEqual(edited.size,Size(690,990))
        XCTAssertEqual(edited.gripperEdge,.left)
        let movedBacks = edited.front.slots.filter { $0.bookRegion == "Arka kapak" }.sorted { $0.x < $1.x }
        XCTAssertEqual(movedBacks[2].x-movedBacks[0].x,308,accuracy:0.0001)
        XCTAssertEqual(input.machineProfile,machine)
    }

    func testDefaultSheetFitsDecimalCoverAndReportsExactShortfall() throws {
        let pages = [SourcePage(number:1,trimSize:Size(215.1,297.1),availableBleed:3),
                     SourcePage(number:2,trimSize:Size(215.1,297.1),availableBleed:3)]
        var input = Project(pages:pages,sheet:SheetSpec(size:Size(600,900),gutter:9),settings:ImpositionSettings(bleed:8))
        let defaults = CoverPreparationSettings()
        XCTAssertEqual(defaults.effectiveSheet(for:input).size,Size(330,480))
        XCTAssertEqual(defaults.effectiveSheet(for:input).gutter,0)
        XCTAssertTrue(defaults.useProjectMachine)
        XCTAssertEqual(defaults.grid.rotation,.automatic)
        let plan = CoverPreparationPlanner.plan(input,pages:pages,output:.sheet)
        let sheet = try XCTUnwrap(plan.sheets.first)
        XCTAssertTrue(plan.canExport)
        XCTAssertEqual(sheet.size,Size(330,480))
        XCTAssertEqual(sheet.repeatLayout?.copiesPerSheet,1)
        XCTAssertEqual(sheet.front.slots.first?.rotation,90)
        let art = sheet.front.slots.compactMap(\.artworkClip)
        XCTAssertEqual(try XCTUnwrap(art.first).size.width,303.1,accuracy:0.00001)
        input.coverPreparation = defaults
        input.coverPreparation?.sheet = SheetSpec(size:Size(300,480),orientation:.portrait)
        input.coverPreparation?.crop = false
        let blocked = CoverPreparationPlanner.plan(input,pages:pages,output:.sheet)
        XCTAssertFalse(blocked.canExport)
        let message = try XCTUnwrap(blocked.issues.first?.message)
        XCTAssertTrue(message.contains("303,100 × 436,200 mm"),message)
        XCTAssertTrue(message.contains("300,000 × 480,000 mm"),message)
        XCTAssertTrue(message.contains("en 3,100 mm"),message)
    }

}
