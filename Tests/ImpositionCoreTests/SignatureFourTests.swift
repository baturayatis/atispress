import XCTest
@testable import ImpositionCore

final class SignatureFourTests: XCTestCase {
    private func project(_ count: Int,binding: BindingMethod = .perfectBound) -> Project {
        var p = Project(pages:(1...count).map { SourcePage(number:$0,trimSize:Size(148,210),availableBleed:0) },binding:binding,sheet:SheetSpec(preset:.a4,orientation:.landscape))
        p.settings.signatureSize = .four; p.settings.bleed = 0; p.settings.cropMarkLength = 0; p.settings.cropMarkOffset = 3.5
        return p
    }
    /// Put the outside face down, flip the left physical panel over the right,
    /// then read the closed book from its outside front, bottom leaf to top.
    /// Face swapping and leaf stacking are simulated from sheet geometry.
    private func foldAndStack(_ plan: ImpositionPlan) throws -> [Int?] {
        struct Leaf {
            var up: Int?
            var down: Int?
            func flipped() -> Leaf { Leaf(up:down,down:up) }
        }
        var result: [Int?] = []
        for sheet in plan.sheets where sheet.bookInfo?.section != .cover {
            let f = sheet.front.slots.sorted { $0.x<$1.x },b = sheet.back.slots.sorted { $0.x<$1.x }
            XCTAssertEqual(f.count,2); XCTAssertEqual(b.count,2)
            guard f.count == 2,b.count == 2 else { continue }
            let left = Leaf(up:b[1].sourcePageNumber,down:f[0].sourcePageNumber)
            let right = Leaf(up:b[0].sourcePageNumber,down:f[1].sourcePageNumber)
            let folded = [left.flipped(),right]
            result += folded.reversed().flatMap { [$0.down,$0.up] }
        }
        return result
    }
    func testFourPagePerfectAndSewnSignaturesAreStackedAndFoldReadInOrder() throws {
        for binding in [BindingMethod.perfectBound,.sewn] {
            let p = project(12,binding:binding),plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport,"\(plan.issues)")
            XCTAssertEqual(plan.sheets.count,3); XCTAssertEqual(plan.signatureCount,3)
            XCTAssertEqual(plan.sheets[0].front.slots.map(\.sourcePageNumber),[4,1])
            XCTAssertEqual(plan.sheets[0].back.slots.map(\.sourcePageNumber),[2,3])
            XCTAssertEqual(plan.sheets[1].front.slots.map(\.sourcePageNumber),[8,5])
            XCTAssertEqual(plan.sheets.map(\.signatureNumbers),[[1],[2],[3]])
            XCTAssertEqual(try foldAndStack(plan),Array(1...12).map(Optional.init))
        }
    }
    func testAllManualBlankPositionPairsAndStartEndPassPhysicalFoldSimulation() throws {
        for binding in [BindingMethod.perfectBound,.sewn] {
            for a in 1..<12 { for b in (a+1)...12 {
                var p = project(10,binding:binding),setting = BlankPlacement(); setting.mode = .manual; setting.positions = [a,b]; p.blankPlacement = setting
                let plan = ImpositionPlanner.plan(p)
                XCTAssertTrue(plan.canExport,"\(plan.issues)")
                let read = try foldAndStack(plan)
                XCTAssertEqual(read.compactMap { $0 },Array(1...10))
                XCTAssertEqual(read.enumerated().filter { $0.element == nil }.map { $0.offset+1 },[a,b])
                XCTAssertEqual(read,plan.readingOrder)
            } }
            for mode in [BlankPlacement.Mode.start,.end] {
                var p = project(10,binding:binding),setting = BlankPlacement(); setting.mode = mode; p.blankPlacement = setting
                let plan = ImpositionPlanner.plan(p),read = try foldAndStack(plan)
                XCTAssertEqual(read.compactMap { $0 },Array(1...10))
                XCTAssertEqual(plan.blankPositions,mode == .start ? [1,2] : [11,12])
            }
        }
    }
    func test106PagesSeparateCoverSummaryHas27SignaturesTwoBlanksAnd56PDFSides() throws {
        for binding in [BindingMethod.perfectBound,.sewn] {
            var p = project(106,binding:binding)
            p.pages += (107...110).map { SourcePage(number:$0,trimSize:Size(148,210),availableBleed:0) }
            var book = BookSettings(); book.coverSourceID = UUID(); book.coverPDFPages = Array(107...110); book.auxiliaryPages = book.coverPDFPages
            // Explicit thin stock keeps a measured perfect-bound cover spread on A4.
            book.interiorPaper.microns = 10; p.book = book; p.coverMode = .separate
            let plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport,"\(plan.issues)")
            XCTAssertEqual(plan.signatureCount,27); XCTAssertEqual(plan.addedBlankPages,2); XCTAssertEqual(plan.blankPositions,[107,108])
            XCTAssertEqual(plan.sheets.count,28); XCTAssertEqual(plan.pdfSideCount(),56)
            XCTAssertTrue(plan.sheets[0].bookInfo?.summary.contains("27 forma (4 sayfa)") == true)
            XCTAssertTrue(plan.sheets[0].bookInfo?.summary.contains("PDF yüzü: 56") == true)
            XCTAssertEqual(try foldAndStack(plan).compactMap { $0 },Array(1...106))
        }
    }
    func testAutomaticCanSelectFourAndInvalidManualPositionsBlockWithoutChangingSettings() {
        var p = project(106); p.settings.signatureSize = .automatic
        XCTAssertEqual(ImpositionPlanner.plan(p).signaturePageCount,4)
        p.settings.signatureSize = .four
        for positions in [[1],[1,1],[0,108],[1,109],[1,2,3]] {
            var setting = BlankPlacement(); setting.mode = .manual; setting.positions = positions; p.blankPlacement = setting
            let plan = ImpositionPlanner.plan(p)
            XCTAssertFalse(plan.canExport); XCTAssertFalse(plan.sheets.isEmpty)
            XCTAssertEqual(p.blankPlacement?.positions,positions)
            XCTAssertEqual(plan.readingOrder.compactMap { $0 },Array(1...106))
        }
    }
    func testFourAndBlankSettingsRoundtripAndOldProjectsDefaultToEnd() throws {
        var p = project(106,binding:.sewn),setting = BlankPlacement(); setting.mode = .manual; setting.positions = [1,55]; p.blankPlacement = setting
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:data),p)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]); object.removeValue(forKey:"blankPlacement")
        let old = try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(old.blankPlacement); XCTAssertEqual(ImpositionPlanner.plan(old).blankPositions,[107,108])
    }
}
