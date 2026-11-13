import XCTest
@testable import ImpositionCore

final class SaddleCoverOrderTests: XCTestCase {
    func testTwelvePageA4OuterFirstAndFoldInEveryCoverMode() throws {
        for mode in [CoverMode.included, .excluded, .separate] {
            var p = Project(pages: (1...12).map { SourcePage(number: $0, trimSize: Size(210,297), availableBleed: 3) }, binding: .saddleStitch,
                            sheet: SheetSpec(size: Size(420,297), margins: Insets(), gripperWidth: 0, gutter: 0, orientation: .landscape))
            p.exportMarks = .none; p.settings.cropMarkLength = 0
            p.coverMode = mode; p.book = BookSettings()
            if mode == .excluded {
                p.book?.selection.front = 1; p.book?.selection.insideFront = 2
                p.book?.selection.insideBack = 11; p.book?.selection.back = 12
            }
            if mode == .separate {
                p.book?.coverSourceID = UUID(); p.book?.coverPDFPages = [1,2,11,12]
            }
            let plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport, "\(mode): \(plan.issues)")
            XCTAssertEqual(plan.sheets.count, 3)
            let front = plan.sheets.map { $0.front.slots.sorted { $0.x < $1.x }.map(\.sourcePageNumber) }
            let back = plan.sheets.map { $0.back.slots.sorted { $0.x < $1.x }.map(\.sourcePageNumber) }
            XCTAssertEqual(front, [[12,1],[10,3],[8,5]], "\(mode)")
            XCTAssertEqual(back, [[2,11],[4,9],[6,7]], "\(mode)")
            // Fold each bifolium, nest in sheet-list order, then turn its leaves.
            let rectos = zip(front,back).flatMap { [$0.0[1],$0.1[0]] }
            let versos = zip(front,back).reversed().flatMap { [$0.1[1],$0.0[0]] }
            XCTAssertEqual((rectos+versos).compactMap { $0 }, Array(1...12), "fold \(mode)")
        }
    }
    func testPaddingStaysInsideCoverInEveryMode() throws {
        for mode in [CoverMode.included,.excluded,.separate] {
            var p = Project(pages:(1...10).map { SourcePage(number:$0,trimSize:Size(210,297)) },binding:.saddleStitch,
                            sheet:SheetSpec(size:Size(420,297),margins:Insets(),gripperWidth:0,orientation:.landscape))
            p.exportMarks = .none; p.settings.cropMarkLength = 0; p.book = BookSettings(); p.coverMode = mode
            if mode == .excluded { p.book?.selection.front = 1; p.book?.selection.insideFront = 2; p.book?.selection.insideBack = 9; p.book?.selection.back = 10 }
            if mode == .separate { p.book?.coverSourceID = UUID(); p.book?.coverPDFPages = [1,2,9,10] }
            let plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport); XCTAssertEqual(plan.addedBlankPages,2)
            let cover = try XCTUnwrap(plan.sheets.first)
            XCTAssertEqual(cover.bookInfo?.section,.cover)
            XCTAssertEqual(cover.front.slots.sorted { $0.x<$1.x }.map(\.sourcePageNumber),[10,1])
            XCTAssertEqual(cover.back.slots.sorted { $0.x<$1.x }.map(\.sourcePageNumber),[2,9])
            let front = plan.sheets.map { $0.front.slots.sorted { $0.x<$1.x }.map(\.sourcePageNumber) }
            let back = plan.sheets.map { $0.back.slots.sorted { $0.x<$1.x }.map(\.sourcePageNumber) }
            let before = zip(front,back).flatMap { [$0.0[1],$0.1[0]] }
            let after = zip(front,back).reversed().flatMap { [$0.1[1],$0.0[0]] }
            XCTAssertEqual((before+after).compactMap { $0 },Array(1...10))
            XCTAssertEqual((before+after).filter { $0 == nil }.count,2)
        }
    }

}
