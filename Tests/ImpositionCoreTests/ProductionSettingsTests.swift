import XCTest
import ImpositionCore

final class ProductionSettingsTests: XCTestCase {
    private func project(pages: Int = 2) -> Project {
        Project(pages: (1...pages).map { SourcePage(number: $0,trimSize: Size(20,30),availableBleed: 3) },
            sheet: SheetSpec(size: Size(100,100)),settings: ImpositionSettings(bleed: 0,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1),
            stepAndRepeat: StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: 10))
    }
    func testWasteArithmeticRoundingOverflowAndProductionSheetCount() throws {
        var waste = WasteSettings(); waste.percent = 5
        XCTAssertEqual(waste.quantities(for: 1000)?.waste,50)
        XCTAssertEqual(waste.quantities(for: 1001)?.total,1052)
        waste.percent = 0.1
        XCTAssertEqual(waste.quantities(for: 1000)?.waste,1)
        waste.mode = .fixed; waste.fixed = 5
        XCTAssertEqual(waste.quantities(for: 10)?.total,15)
        var p = project(); p.stepAndRepeat.waste = waste
        let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
        XCTAssertEqual(sheet.repeatCount,4)
        XCTAssertEqual(sheet.repeatLayout?.requestedQuantity,10)
        XCTAssertEqual(sheet.repeatLayout?.productionQuantity,15)
        XCTAssertEqual(sheet.productionSummary,"Adet 10 + fire 5 = 15 üretim, 4 tabaka")
        XCTAssertEqual(sheet.unnumberedCopiesDescription,"6")
        XCTAssertEqual(sheet.excessCopies,1)
        waste.fixed = Int.max
        XCTAssertNil(waste.quantities(for: 10))
        p.stepAndRepeat.waste = waste
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        waste.mode = .percent; waste.percent = 0
        XCTAssertEqual(waste.quantities(for: Int.max)?.total,Int.max)
        waste.percent = .infinity
        XCTAssertNil(waste.quantities(for: 10))
    }
    func testWasteNumberingBothModesRemainLazyAndStopAtRequestedOrProductionQuantity() throws {
        for mode in [SerialField.Mode.sequential,.stack] {
            for numberWaste in [false,true] {
                var p = project()
                var waste = WasteSettings(); waste.mode = .fixed; waste.fixed = 5; waste.numberCopies = numberWaste
                p.stepAndRepeat.waste = waste
                p.serialFields = [SerialField(mode: mode)]
                let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first), serials = try XCTUnwrap(sheet.serialPlan)
                XCTAssertEqual(serials.sheetCount,4); XCTAssertEqual(serials.quantity,numberWaste ? 15 : 10)
                let values = (0..<sheet.repeatCount).flatMap { serials.placements(side: sheet.front,kind: .front,repetition: $0) }.map(\.index).sorted()
                XCTAssertEqual(values,Array(0..<(numberWaste ? 15 : 10)))
                XCTAssertEqual(sheet.unnumberedCopiesDescription,numberWaste ? "1" : "6")
                XCTAssertEqual(sheet.front.slots.count,4)
            }
        }
    }
    func testAutomaticSidesEvenEqualOddAndMismatchedPagesAndManualOverride() {
        var p = project(pages: 4); p.stepAndRepeat.pageLayout = PageLayoutSettings()
        XCTAssertEqual(p.resolvedPageLayout,.duplex)
        XCTAssertEqual(p.repeatJobs.map { $0.back?.number },[2,4])
        p.pages.removeLast()
        XCTAssertEqual(p.resolvedPageLayout,.simplex)
        XCTAssertEqual(p.repeatJobs.map { $0.front.number },[1,2,3])
        XCTAssertTrue(p.repeatJobs.allSatisfy { $0.back == nil })
        p = project(pages: 4); p.stepAndRepeat.pageLayout = PageLayoutSettings()
        p.pages[1].trimSize = Size(21,30)
        XCTAssertEqual(p.resolvedPageLayout,.simplex)
        XCTAssertTrue(ImpositionPlanner.plan(p).canExport)
        p.stepAndRepeat.pageLayout?.mode = .duplex
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport,"Manual mismatched pairing retains the existing blocking fit rule")
    }
    func testPerJobOverrideSplitsOrJoinsWithoutDroppingAnyPageAndLegacyKeepsPairs() throws {
        var p = project(pages: 4); p.stepAndRepeat.pageLayout = PageLayoutSettings()
        p.stepAndRepeat.pageLayout?.overrides = [PageJobOverride(frontPage: 1,layout: .simplex)]
        XCTAssertEqual(p.repeatJobs.map { $0.front.number },[1,2,3])
        XCTAssertEqual(p.repeatJobs.map { $0.back?.number },[nil,nil,4])
        p.stepAndRepeat.pageLayout?.mode = .simplex
        p.stepAndRepeat.pageLayout?.overrides = [PageJobOverride(frontPage: 2,layout: .duplex)]
        XCTAssertEqual(p.repeatJobs.map { $0.front.number },[1,2,4])
        XCTAssertEqual(p.repeatJobs.map { $0.back?.number },[nil,3,nil])
        let consumed = p.repeatJobs.flatMap { [$0.front.number,$0.back?.number].compactMap { $0 } }
        XCTAssertEqual(consumed,[1,2,3,4])
        p = project(pages: 3)
        XCTAssertEqual(p.resolvedPageLayout,.duplex)
        XCTAssertEqual(p.repeatJobs.count,2)
        p.stepAndRepeat.pageLayout = PageLayoutSettings()
        p.serialFields = [SerialField(sides: .both)]
        let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
        XCTAssertFalse(sheet.hasContent(on: .back),"Explicit simplex prevents serial-only backs")
    }
}
