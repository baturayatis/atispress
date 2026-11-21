import XCTest
import ImpositionCore

final class SpineCoverTests: XCTestCase {
    private func project(_ binding: BindingMethod) -> Project {
        var project = Project(pages:(1...10).map { SourcePage(number:$0,trimSize:Size(50,70),availableBleed:3) },
                              binding:binding,sheet:SheetSpec(size:Size(150,110),orientation:.landscape))
        var book = BookSettings()
        book.automaticCover = true
        project.book = book
        return project
    }

    func testAutomaticBindingsAndManualSpreadWidthsWithoutPaperThickness() throws {
        for binding in [BindingMethod.perfectBound,.spiral,.wireO,.sewn] {
            for width in [0.0, 2.5, 12.75] {
                var input = project(binding)
                input.book?.spineWidth = width
                let plan = ImpositionPlanner.plan(input)
                XCTAssertTrue(plan.canExport,"\(binding): \(plan.issues)")
                let cover = try XCTUnwrap(plan.sheets.first)
                XCTAssertEqual(cover.bookInfo?.section,.cover)
                XCTAssertEqual(cover.bookInfo?.spreadSize,Size(100+width,70))
                XCTAssertEqual(cover.front.slots.compactMap(\.sourcePageNumber),[10,1])
                XCTAssertEqual(cover.front.slots.filter { $0.bookRegion == "Sırt" }.count,width > 0 ? 1 : 0)
                let coverPages = Set([1,10])
                XCTAssertTrue(plan.sheets.dropFirst().allSatisfy {
                    ($0.front.slots+$0.back.slots).compactMap(\.sourcePageNumber).allSatisfy { !coverPages.contains($0) }
                })
            }
        }
        var saddle = project(.saddleStitch)
        XCTAssertFalse(ImpositionPlanner.plan(saddle).sheets.contains { $0.bookInfo?.section == .cover })
        saddle.book?.separateSaddleCover = true
        saddle.book?.spineWidth = 12
        let plan = ImpositionPlanner.plan(saddle)
        XCTAssertEqual(plan.sheets.first?.bookInfo?.spreadSize,Size(100,70))
        XCTAssertEqual(plan.sheets.first?.bookInfo?.spine,0)
    }

    func testPreparedSpreadBypassesSpineAndBlankModePreservesSlots() throws {
        var input = project(.perfectBound)
        input.book?.spineWidth = 6
        let baseline = ImpositionPlanner.plan(input)
        input.book?.spineContent = SpineContent()
        XCTAssertEqual(ImpositionPlanner.plan(input).sheets,baseline.sheets)

        input.pages.append(SourcePage(number:11,trimSize:Size(106,70),availableBleed:3))
        input.book?.coverSourceID = UUID()
        input.book?.coverPDFPages = [11]
        input.book?.auxiliaryPages = [11]
        input.book?.coverArtwork = .spread
        input.book?.spineContent?.mode = .color
        input.book?.spineContent?.foldMarks = true
        let plan = ImpositionPlanner.plan(input)
        let cover = try XCTUnwrap(plan.sheets.first)
        XCTAssertTrue(plan.canExport)
        XCTAssertEqual(cover.front.slots.count,1)
        XCTAssertEqual(cover.front.slots.first?.sourcePageNumber,11)
        XCTAssertNil(cover.front.slots.first?.spineArtwork)
        XCTAssertFalse(cover.front.marks.contains { $0.kind == .spineFold })
    }

    func testSpineCalculator() {
        var calculator = SpineCalculation(pageCount:101,microns:120,coverAllowance:0.25,glueAllowance:0.17)
        XCTAssertEqual(calculator.result ?? -1,6.48,accuracy:0.000001)
        calculator.microns = nil
        XCTAssertNil(calculator.result)
        calculator.microns = 120
        calculator.glueAllowance = -.infinity
        XCTAssertNil(calculator.result)
    }
}
