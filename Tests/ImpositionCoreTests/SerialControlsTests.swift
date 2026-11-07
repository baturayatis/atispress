import XCTest
@testable import ImpositionCore

final class SerialControlsTests: XCTestCase {
    private func project(_ quantity: Int) -> Project {
        var p = Project(pages: [1,2].map { SourcePage(number: $0,trimSize: Size(20,30),availableBleed: 0) },
            sheet: SheetSpec(size: Size(100,100),gutter: 1),
            settings: ImpositionSettings(bleed: 0,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1),
            stepAndRepeat: StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: quantity))
        p.serialFields = [SerialField(mode: .stack)]
        return p
    }
    func testNumberRangeAndEndNumberQuantityMath() throws {
        var field = SerialField()
        XCTAssertEqual(try field.quantity(endingAt: 500),500)
        XCTAssertEqual(field.rangeDescription(quantity: 500,sheetCount: 6),"Numara aralığı: 0001 → 0500 (500 adet, 6 tabaka)")
        field.start = 100; field.step = 5
        XCTAssertEqual(try field.quantity(endingAt: 145),10)
        XCTAssertEqual(field.value(at: 9),145)
        XCTAssertThrowsError(try field.quantity(endingAt: 144))
        field.step = -5
        XCTAssertEqual(try field.quantity(endingAt: 55),10)
        XCTAssertThrowsError(try field.quantity(endingAt: 145))
        field.step = 0
        XCTAssertThrowsError(try field.quantity(endingAt: 100))
    }
    func testAutoDigitsGrowAndFixedDigitsWarnWithoutTruncating() throws {
        var p = project(10_001)
        let plan = ImpositionPlanner.plan(p), field = try XCTUnwrap(plan.sheets.first?.serialPlan?.fields.first)
        XCTAssertEqual(field.digits,5)
        XCTAssertEqual(field.digitNote(quantity: 10_001),"Basamak 5'e çıkarıldı")
        XCTAssertEqual(field.text(at: 10_000),"10001")
        p.serialFields[0].digitsAreManual = true
        let fixed = ImpositionPlanner.plan(p)
        XCTAssertEqual(fixed.sheets.first?.serialPlan?.fields.first?.digits,4)
        XCTAssertTrue(fixed.issues.contains { $0.code == .serialNumbering && $0.message.contains("elle 4") })
        XCTAssertEqual(fixed.sheets.first?.serialPlan?.fields.first?.text(at: 10_000),"10001")
        XCTAssertTrue(fixed.canExport)
    }
    func testHundredThousandStackComputesOnlyRequestedSheetsQuickly() throws {
        let begin = Date()
        let plan = ImpositionPlanner.plan(project(100_000))
        let sheet = try XCTUnwrap(plan.sheets.first), recipe = try XCTUnwrap(sheet.serialPlan)
        XCTAssertEqual(plan.sheets.count,1)
        XCTAssertEqual(sheet.front.slots.count,4)
        XCTAssertEqual(sheet.repeatCount,25_000)
        XCTAssertEqual(recipe.fields.first?.digits,6)
        XCTAssertEqual(recipe.range(field: recipe.fields[0],repetition: 0),"000001 – 075001")
        XCTAssertEqual(recipe.range(field: recipe.fields[0],repetition: 24_999),"025000 – 100000")
        for r in 24_900..<25_000 { XCTAssertNotNil(recipe.range(field: recipe.fields[0],repetition: r)) }
        XCTAssertLessThan(Date().timeIntervalSince(begin),1,"No quantity-sized expansion is allowed")
    }
    func testQuantityAndNumbersBeyondPreviousLimitsStayLazy() throws {
        var p = project(10_000_000_000)
        p.serialFields[0].start = 9_999_999
        p.serialFields[0].mode = .sequential
        let plan = ImpositionPlanner.plan(p), recipe = try XCTUnwrap(plan.sheets.first?.serialPlan)
        XCTAssertTrue(plan.canExport)
        XCTAssertEqual(recipe.sheetCount,2_500_000_000)
        XCTAssertEqual(recipe.fields[0].value(at: 9_999_999_999),10_009_999_998)
        XCTAssertEqual(plan.sheets[0].front.slots.count,4)
        // Intermediate signed multiplication may overflow even when the final value fits.
        var field = SerialField(start: Int64.min,step: Int64.max)
        XCTAssertEqual(field.value(at: 2),Int64.max-1)
        field.start = Int64.max; field.step = Int64.min
        XCTAssertEqual(try field.quantity(endingAt: -1),2)
        XCTAssertEqual(field.value(at: 1),-1)
    }
    func testNearMachineLimitRangeAndOverproductionDoNotOverflow() throws {
        var p = project(Int.max)
        p.serialFields = []
        let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
        XCTAssertEqual(sheet.excessCopies,1)
        XCTAssertEqual(sheet.producedQuantityDescription,String(UInt64(Int.max)+1))
        let recipe = SerialNumberPlan(fields: [SerialField(digits: 1)],quantity: Int.max,capacity: 4,sheetCount: sheet.repeatCount)
        XCTAssertNotNil(recipe.range(field: recipe.fields[0],repetition: sheet.repeatCount-1))
        XCTAssertNil(recipe.ordinal(copy: 3,repetition: sheet.repeatCount-1,mode: .sequential))
    }
    func testWarningsAreGroupedBySourcePagesAndSuppressedWithGeneratedBleed() {
        var p = project(100_000)
        p.settings.bleed = 3
        p.pages = (1...12).map { SourcePage(number: $0,trimSize: Size(20,30),availableBleed: 0) }
        let ordinary = ImpositionPlanner.plan(p)
        let warnings = ordinary.displayIssues.filter { $0.code == .missingBleed }
        XCTAssertEqual(warnings.count,1)
        XCTAssertEqual(warnings.first?.message,"12 sayfada taşma payı eksik: 1-12")
        XCTAssertEqual(warnings.first?.affectedPages,Array(1...12))
        XCTAssertGreaterThan(warnings.first?.affectedSlots.count ?? 0,12)
        p.settings.generatedBleed.enabled = true
        let generated = ImpositionPlanner.plan(p)
        XCTAssertFalse(generated.issues.contains { $0.code == .missingBleed })
        XCTAssertFalse(generated.displayIssues.contains { $0.code == .missingBleed })
    }
}
