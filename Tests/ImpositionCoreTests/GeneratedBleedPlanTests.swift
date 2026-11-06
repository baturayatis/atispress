import XCTest
import ImpositionCore

final class GeneratedBleedPlanTests: XCTestCase {
    private func project(gutter: Double) -> Project {
        Project(pages: [SourcePage(number: 1,trimSize: Size(30,20),availableBleed: 0)],binding: .stepAndRepeat,
            sheet: SheetSpec(size: Size(130,90),margins: Insets(left: 5,right: 5,top: 5,bottom: 5),gutter: gutter,orientation: .landscape),
            settings: ImpositionSettings(bleed: 3,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1,
                generatedBleed: GeneratedBleedSettings(enabled: true)),
            stepAndRepeat: StepAndRepeatSettings(columns: 3,rows: 2,allowRotation: false))
    }
    func testTouchingThreeByTwoGeneratesPerimeterOnlyAndSharedCuts() throws {
        let p = project(gutter: 0), plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport); XCTAssertEqual(plan.generatedBleed.method,.automatic)
        let side = try XCTUnwrap(plan.sheets.first?.front)
        XCTAssertEqual(side.slots.count,6)
        var generatedArea = 0.0
        for slot in side.slots {
            let clip = try XCTUnwrap(slot.artworkClip), grid = try XCTUnwrap(slot.gridPosition)
            XCTAssertEqual(slot.x-clip.origin.x,grid.column == 0 ? 3 : 0,accuracy: 0.00001)
            XCTAssertEqual(clip.origin.x+clip.size.width-slot.x-slot.size.width,grid.column == 2 ? 3 : 0,accuracy: 0.00001)
            XCTAssertEqual(slot.y-clip.origin.y,grid.row == 0 ? 3 : 0,accuracy: 0.00001)
            XCTAssertEqual(clip.origin.y+clip.size.height-slot.y-slot.size.height,grid.row == 1 ? 3 : 0,accuracy: 0.00001)
            generatedArea += clip.size.width*clip.size.height-slot.size.width*slot.size.height
        }
        XCTAssertEqual(generatedArea,(90+6)*(40+6)-90*40,accuracy: 0.00001)
        XCTAssertEqual(side.marks.filter { $0.kind == .sharedCut }.count,3)
        XCTAssertEqual(side.marks.filter { $0.kind == .bleed }.count,4)
    }
    func testSpacedGridGetsFourSidesAndSmallGutterWarning() throws {
        let plan = ImpositionPlanner.plan(project(gutter: 2))
        XCTAssertTrue(plan.canExport)
        XCTAssertTrue(plan.issues.contains { $0.code == .insufficientGutter && $0.severity == .warning })
        for slot in try XCTUnwrap(plan.sheets.first?.front.slots) {
            let clip = try XCTUnwrap(slot.artworkClip)
            XCTAssertEqual(slot.x-clip.origin.x,3,accuracy: 0.00001)
            XCTAssertEqual(slot.y-clip.origin.y,3,accuracy: 0.00001)
            XCTAssertEqual(clip.size.width-slot.size.width,6,accuracy: 0.00001)
            XCTAssertEqual(clip.size.height-slot.size.height,6,accuracy: 0.00001)
        }
        XCTAssertFalse(plan.sheets[0].front.marks.contains { $0.kind == .sharedCut })
        XCTAssertFalse(ImpositionPlanner.plan(project(gutter: 6)).issues.contains { $0.code == .insufficientGutter })
    }
    func testBlockOuterMarginMustFitBleedAndSettingsAreValidated() {
        var p = project(gutter: 0)
        p.sheet = SheetSpec(size: Size(90,40),orientation: .landscape)
        let plan = ImpositionPlanner.plan(p)
        XCTAssertFalse(plan.canExport); XCTAssertTrue(plan.issues.contains { $0.code == .exceedsSheet })
        p = project(gutter: 0); p.settings.generatedBleed.tolerance = .nan
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
    }
}
