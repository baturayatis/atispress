import XCTest
@testable import ImpositionCore

final class SmartAutoLayoutTests: XCTestCase {
    private func project(_ size: Size,stock: SheetPreset? = nil) -> Project {
        var p = Project(pages: [SourcePage(number: 1,trimSize: size,availableBleed: 0)],sheet: SheetSpec(preset: stock ?? .cm33x48))
        p.autoLayout = AutoLayoutSettings()
        if stock != nil { p.autoLayout?.manualFields.insert(.sheetSize) }
        return p
    }
    func testA4AndA5MatchTheirOwnFullSheetWithoutProductionMarks() throws {
        for (item,paper) in [(Size(210,297),SheetPreset.a4),(Size(210,148),.a5)] {
            let result = SmartAutoLayout.arrange(project(item))
            XCTAssertEqual(result.project.sheet.size,paper.size)
            XCTAssertEqual(result.project.sheet.margins,Insets())
            XCTAssertEqual(result.project.sheet.gripperWidth,0)
            XCTAssertEqual(result.project.settings.bleed,0)
            XCTAssertFalse(result.project.exportMarks.crop)
            XCTAssertEqual(result.project.autoLayout?.level,.fullSheet)
            XCTAssertTrue(result.project.autoLayout?.automaticFields.contains(.marginLeft) == true)
            XCTAssertEqual(result.plan.sheets.first?.repeatLayout?.copiesPerSheet,1)
            XCTAssertTrue(result.plan.canExport)
            XCTAssertTrue(result.summary.contains("tam sayfa"))
        }
    }
    func testStandardToleranceClipsWithoutScalingAndChecksBothOrientations() throws {
        for item in [Size(210.8,297.7),Size(297.7,210.8),Size(209.3,296.4)] {
            let result = SmartAutoLayout.arrange(project(item))
            let sheet = try XCTUnwrap(result.plan.sheets.first), slot = try XCTUnwrap(sheet.front.slots.first)
            XCTAssertEqual(result.project.sheet.size,SheetPreset.a4.size)
            XCTAssertEqual(sheet.repeatLayout?.copiesPerSheet,1)
            XCTAssertTrue(result.plan.canExport)
            let localSize = slot.rotation%180 == 0 ? slot.size : Size(slot.size.height,slot.size.width)
            XCTAssertEqual(localSize,item,"Source trim must not be scaled to the nominal paper")
            let clip = try XCTUnwrap(slot.artworkClip)
            XCTAssertGreaterThanOrEqual(clip.origin.x,0); XCTAssertGreaterThanOrEqual(clip.origin.y,0)
            XCTAssertLessThanOrEqual(clip.origin.x+clip.size.width,sheet.size.width+0.00001)
            XCTAssertLessThanOrEqual(clip.origin.y+clip.size.height,sheet.size.height+0.00001)
        }
    }
    func testCardOnChosen33x48KeepsFullComfortAndMarksOutsideBleed() throws {
        let result = SmartAutoLayout.arrange(project(Size(85,55),stock: .cm33x48))
        XCTAssertEqual(result.project.sheet.size,SheetPreset.cm33x48.size)
        XCTAssertEqual(result.project.autoLayout?.level,.full)
        XCTAssertEqual(result.project.sheet.margins,Insets(left: 10,right: 10,top: 10,bottom: 10))
        XCTAssertEqual(result.project.sheet.gripperWidth,0)
        XCTAssertEqual(result.project.sheet.gutter,2*result.project.settings.bleed)
        XCTAssertTrue(result.project.settings.generatedBleed.enabled)
        XCTAssertTrue(result.project.exportMarks.crop)
        XCTAssertGreaterThan(result.project.settings.cropMarkOffset,result.project.settings.bleed)
        XCTAssertGreaterThan(try XCTUnwrap(result.plan.sheets.first?.repeatLayout?.copiesPerSheet),1)
    }
    func testUnpinnedSmallItemMaximizesComfortableCapacityAndLargeItemUsesSmallestStock() {
        let card = SmartAutoLayout.arrange(project(Size(85,55)))
        XCTAssertEqual(card.project.sheet.size,SheetPreset.cm70x100.size)
        XCTAssertEqual(card.project.autoLayout?.level,.full)
        let large = SmartAutoLayout.arrange(project(Size(360,520)))
        XCTAssertEqual(large.project.sheet.size,SheetPreset.cm50x70.size)
        XCTAssertEqual(large.plan.sheets.first?.repeatLayout?.copiesPerSheet,1)
    }
    func testReducedAndClippedLevelsStopAtFirstFitAndOffsetKeepsMinimumGripper() {
        let reduced = SmartAutoLayout.arrange(project(Size(300,440),stock: .cm33x48))
        XCTAssertEqual(reduced.project.autoLayout?.level,.reduced)
        XCTAssertEqual(reduced.project.sheet.margins.left,5)
        XCTAssertTrue(reduced.project.exportMarks.crop)
        let clipped = SmartAutoLayout.arrange(project(Size(322,470),stock: .cm33x48))
        XCTAssertEqual(clipped.project.autoLayout?.level,.clipped)
        XCTAssertEqual(clipped.project.sheet.margins.left,3)
        XCTAssertFalse(clipped.project.exportMarks.crop)
        XCTAssertEqual(clipped.project.sheet.gutter,0)
        XCTAssertTrue(clipped.project.autoLayout?.clipBleedToSheet == true)
        var offset = project(Size(85,55),stock: .cm33x48); offset.autoLayout?.production = .offset
        let result = SmartAutoLayout.arrange(offset)
        XCTAssertEqual(result.project.sheet.gripperWidth,10)
        XCTAssertEqual(result.project.autoLayout?.level,.full)
    }
    func testOversizedItemGetsCustomComfortableStock() throws {
        let result = SmartAutoLayout.arrange(project(Size(850,1300)))
        XCTAssertEqual(result.presetName,"Özel")
        XCTAssertTrue(result.plan.canExport)
        XCTAssertEqual(result.project.autoLayout?.level,.full)
        XCTAssertGreaterThanOrEqual(result.project.sheet.size.width,850)
        XCTAssertGreaterThanOrEqual(result.project.sheet.size.height,1300)
        XCTAssertEqual(result.plan.sheets.first?.repeatLayout?.copiesPerSheet,1)
    }
    func testManualFieldsSurviveAndExplicitAutoResetsThem() {
        var p = project(Size(85,55))
        p.sheet.margins.left = 17
        p.settings.bleed = 2
        p.autoLayout?.manualFields = [.marginLeft,.bleed]
        let preserved = SmartAutoLayout.arrange(p)
        XCTAssertEqual(preserved.project.sheet.margins.left,17)
        XCTAssertEqual(preserved.project.settings.bleed,2)
        XCTAssertFalse(preserved.project.autoLayout?.automaticFields.contains(.marginLeft) == true)
        let reset = SmartAutoLayout.arrange(p,resetOverrides: true)
        XCTAssertEqual(reset.project.sheet.margins.left,10)
        XCTAssertEqual(reset.project.settings.bleed,3)
        XCTAssertTrue(reset.project.autoLayout?.manualFields.isEmpty == true)
    }
    func testFitFailureHasExactDiagnosticGeometryButCannotExport() throws {
        var p = project(Size(200,300),stock: .a5)
        p.autoLayout?.manualFields = Set(AutoLayoutField.allCases)
        p.sheet.margins = Insets(left: 5,right: 5,top: 5,bottom: 5)
        let result = SmartAutoLayout.arrange(p)
        XCTAssertFalse(result.plan.canExport)
        XCTAssertTrue(result.plan.sheets.isEmpty)
        let diagnostic = try XCTUnwrap(result.plan.diagnosticSheets.first)
        XCTAssertNotNil(diagnostic.diagnosticBounds)
        XCTAssertEqual(diagnostic.front.slots.first?.size,Size(200,300))
        XCTAssertTrue(result.plan.issues.contains { $0.message.contains("200.00×300.00") && $0.message.contains("148.00×210.00") && $0.message.contains("gereken") })
    }
}
