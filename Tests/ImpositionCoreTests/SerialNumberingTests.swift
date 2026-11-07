import XCTest
@testable import ImpositionCore

final class SerialNumberingTests: XCTestCase {
    private func project(quantity: Int = 10,mode: SerialField.Mode = .sequential) -> Project {
        var p = Project(pages: [1,2].map { SourcePage(number: $0,trimSize: Size(20,30)) },
            sheet: SheetSpec(size: Size(100,100),gutter: 1),
            settings: ImpositionSettings(bleed: 0,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1),
            stepAndRepeat: StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: quantity))
        p.serialFields = [SerialField(sides: .both,mode: mode)]
        return p
    }
    func testSequentialUsesTotalQuantityAndPairsPhysicalFrontBackCopies() throws {
        let plan = ImpositionPlanner.plan(project())
        XCTAssertTrue(plan.canExport)
        let sheet = try XCTUnwrap(plan.sheets.first), serials = try XCTUnwrap(sheet.serialPlan)
        XCTAssertEqual(sheet.repeatCount,3)
        let expected = [["0001","0002","0003","0004"],["0005","0006","0007","0008"],["0009","0010"]]
        for repetition in 0..<3 {
            let front = serials.placements(side: sheet.front,kind: .front,repetition: repetition)
            let back = serials.placements(side: sheet.back,kind: .back,repetition: repetition)
            XCTAssertEqual(front.map(\.text),expected[repetition])
            XCTAssertEqual(back.map(\.text),front.map(\.text))
            XCTAssertEqual(back.map { sheet.back.slots[$0.slotIndex].copyIndex },front.map { sheet.front.slots[$0.slotIndex].copyIndex })
        }
        XCTAssertEqual(serials.range(field: serials.fields[0],repetition: 2),"0009 – 0010")
    }
    func testCutAndStackSmallGridWithPartialQuantityProducesOrderedPiles() throws {
        let sheet = try XCTUnwrap(ImpositionPlanner.plan(project(mode: .stack)).sheets.first)
        let serials = try XCTUnwrap(sheet.serialPlan)
        let expected = [["0001","0004","0007","0010"],["0002","0005","0008"],["0003","0006","0009"]]
        for repetition in 0..<3 {
            XCTAssertEqual(serials.placements(side: sheet.front,kind: .front,repetition: repetition).map(\.text),expected[repetition])
        }
        // Cut each grid position into a pile, first press sheet at the top, then concatenate piles.
        let cutStack = (0..<4).flatMap { copy in
            (0..<3).compactMap { serials.ordinal(copy: copy,repetition: $0,mode: .stack) }
        }
        XCTAssertEqual(cutStack,Array(0..<10))
        XCTAssertEqual(serials.range(field: serials.fields[0],repetition: 0),"0001 – 0010")
        XCTAssertEqual(serials.range(field: serials.fields[0],repetition: 2),"0003 – 0009")
        XCTAssertNil(serials.ordinal(copy: 3,repetition: 2,mode: .stack))
    }
    func testFieldsPerJobSidesAndNilQuantity() throws {
        var p = project()
        p.pages += [3,4].map { SourcePage(number: $0,trimSize: Size(20,30)) }
        p.stepAndRepeat.quantity = nil
        p.serialFields = [SerialField(prefix: "F-",sides: .front),SerialField(start: 100,prefix: "B-",sides: .back),
                          SerialField(jobIndex: 1,start: 500,prefix: "JOB2-",sides: .both)]
        let plan = ImpositionPlanner.plan(p)
        XCTAssertEqual(plan.sheets.count,2)
        let first = plan.sheets[0], second = plan.sheets[1]
        XCTAssertEqual(first.serialPlan?.quantity,4)
        XCTAssertEqual(first.serialPlan?.placements(side: first.front,kind: .front,repetition: 0).map(\.text),["F-0001","F-0002","F-0003","F-0004"])
        XCTAssertEqual(first.serialPlan?.placements(side: first.back,kind: .back,repetition: 0).map(\.text),["B-0100","B-0101","B-0102","B-0103"])
        XCTAssertEqual(second.serialPlan?.placements(side: second.front,kind: .front,repetition: 0).first?.text,"JOB2-0500")
    }
    func testSamePlateUsesItemSidesAndStableCopyIdentity() throws {
        for method in [TurnMethod.workAndTurn,.workAndTumble] {
            var p = project(); p.settings.turnMethod = method
            let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
            let serials = try XCTUnwrap(sheet.serialPlan)
            for repetition in 0..<sheet.repeatCount {
                XCTAssertEqual(serials.placements(side: sheet.front,kind: .front,repetition: repetition).map(\.text),
                               serials.placements(side: sheet.back,kind: .back,repetition: repetition).map(\.text))
            }
            p.serialFields[0].sides = .front
            let frontOnly = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
            for serial in frontOnly.serialPlan!.placements(side: frontOnly.front,kind: .front,repetition: 0) {
                XCTAssertEqual(frontOnly.front.slots[serial.slotIndex].sourcePageNumber,1)
            }
        }
    }
    func testSidesDoNotDependOnSourcePageIdentityAndCanNumberBlankReverse() throws {
        var p = project()
        p.pages[1].number = 1 // identical PDF page used for both item faces
        p.serialFields[0].sides = .back
        let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
        XCTAssertEqual(sheet.serialPlan?.placements(side: sheet.front,kind: .front,repetition: 0).count,0)
        XCTAssertEqual(sheet.serialPlan?.placements(side: sheet.back,kind: .back,repetition: 0).count,4)
        p.pages.removeLast()
        let onePage = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
        XCTAssertTrue(onePage.back.slots.allSatisfy { $0.sourcePageNumber == nil })
        XCTAssertEqual(onePage.serialPlan?.placements(side: onePage.back,kind: .back,repetition: 0).count,4)
    }
    func testFormattingOverflowValidationAndLiveRecipeKeepsSlotGeometry() {
        let field = SerialField(start: -5,step: 2,digits: 3,prefix: "T-",suffix: "-X")
        XCTAssertEqual(field.text(at: 0),"T--005-X")
        XCTAssertEqual(field.text(at: 3),"T-001-X")
        var p = project(), changed = p
        let plan = ImpositionPlanner.plan(p)
        changed.serialFields[0] = field
        let updated = ImpositionPlanner.updatingSerials(in: plan,project: changed)
        XCTAssertEqual(plan.sheets[0].front,updated.sheets[0].front)
        XCTAssertEqual(updated.sheets[0].serialPlan?.fields,[field])
        p.serialFields[0].start = Int64.max
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p.serialFields[0].start = 1; p.serialFields[0].size = .nan
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
    }
}
