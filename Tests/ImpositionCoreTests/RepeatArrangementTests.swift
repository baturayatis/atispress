import XCTest
import ImpositionCore

final class RepeatArrangementTests: XCTestCase {
    private func card() -> Project {
        var p = Project(pages: [SourcePage(number: 1,trimSize: Size(85,55),availableBleed: 0)],sheet: SheetSpec(preset: .sra3))
        p.autoLayout = AutoLayoutSettings()
        return p
    }
    func testDefaultAutomaticLayoutIsAdjacentWithPerimeterOnlyBleed() throws {
        let result = SmartAutoLayout.arrange(card())
        XCTAssertTrue(result.plan.canExport)
        XCTAssertEqual(result.project.stepAndRepeat.arrangement,.adjacent)
        XCTAssertEqual(result.project.sheet.gutter,0)
        XCTAssertTrue(result.project.autoLayout!.automaticFields.contains(.gutter))
        XCTAssertTrue(result.project.settings.generatedBleed.enabled)
        XCTAssertTrue(result.plan.issues.contains { $0.code == .sharedCutBleed })
        let sheet = try XCTUnwrap(result.plan.sheets.first), layout = try XCTUnwrap(sheet.repeatLayout)
        let bleed = result.project.settings.bleed
        for slot in sheet.front.slots {
            let clip = try XCTUnwrap(slot.artworkClip), grid = try XCTUnwrap(slot.gridPosition)
            XCTAssertEqual(slot.x-clip.origin.x,grid.column == 0 ? bleed : 0,accuracy: 0.00001)
            XCTAssertEqual(slot.y-clip.origin.y,grid.row == 0 ? bleed : 0,accuracy: 0.00001)
            XCTAssertEqual(clip.origin.x+clip.size.width-slot.x-slot.size.width,grid.column == layout.columns-1 ? bleed : 0,accuracy: 0.00001)
            XCTAssertEqual(clip.origin.y+clip.size.height-slot.y-slot.size.height,grid.row == layout.rows-1 ? bleed : 0,accuracy: 0.00001)
        }
        XCTAssertFalse(sheet.hasContent(on: .back))
    }
    func testSpacedAndCustomArrangementAndExplicitAutomaticReset() {
        var p = card(); p.stepAndRepeat.arrangement = .spaced
        let spaced = SmartAutoLayout.arrange(p)
        XCTAssertEqual(spaced.project.sheet.gutter,2*spaced.project.settings.bleed)
        p.stepAndRepeat.arrangement = .custom; p.sheet.gutter = 7
        XCTAssertEqual(SmartAutoLayout.arrange(p).project.sheet.gutter,7)
        let reset = SmartAutoLayout.arrange(p,resetOverrides: true)
        XCTAssertEqual(reset.project.stepAndRepeat.arrangement,.adjacent)
        XCTAssertEqual(reset.project.sheet.gutter,0)
    }
    func testLegacyArrangementDecodesWithoutChangingSavedGutter() throws {
        var p = card(); p.sheet.gutter = 7
        p.autoLayout?.manualFields.insert(.gutter)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String:Any])
        var repeatSettings = try XCTUnwrap(object["stepAndRepeat"] as? [String:Any])
        repeatSettings.removeValue(forKey: "arrangement")
        object["stepAndRepeat"] = repeatSettings
        let legacy = try JSONDecoder().decode(Project.self,from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.stepAndRepeat.arrangement)
        XCTAssertNil(legacy.includeBlankBacks)
        XCTAssertEqual(legacy.sheet.gutter,7)
        XCTAssertEqual(SmartAutoLayout.arrange(legacy).project.sheet.gutter,7)
    }
}
