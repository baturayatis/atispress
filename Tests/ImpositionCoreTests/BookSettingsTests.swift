import XCTest
@testable import ImpositionCore

final class BookSettingsTests: XCTestCase {
    func project(_ binding: BindingMethod = .saddleStitch,count: Int = 20) -> Project {
        var p = Project(pages:(1...count).map { SourcePage(number:$0,trimSize:Size(50,70),availableBleed:3) },binding:binding,sheet:SheetSpec(preset:.cm70x100,orientation:.portrait))
        p.settings.signatureSize = .eight
        var book = BookSettings(); book.interiorPaper.microns = 120; book.coverPaper.microns = 250
        p.book = book; return p
    }
    func testMeasuredSpineAndGrammageConversionHaveNoGuessedDefaults() throws {
        XCTAssertNil(PaperCaliper().millimetres)
        var paper = PaperCaliper(); paper.input = .grammage; paper.grammage = 80
        XCTAssertNil(paper.millimetres)
        paper.bulk = 1.25; XCTAssertEqual(try XCTUnwrap(paper.millimetres),0.1,accuracy:0.000001)
        let calculator: any SpineThicknessCalculating = MeasuredSpineCalculator(coverAllowance:0.4,adhesiveAllowance:0.6)
        XCTAssertEqual(calculator.thickness(pageCount:100,stockCaliper:0.12),7,accuracy:0.000001)
        XCTAssertEqual(MeasuredSpineCalculator().thickness(pageCount:100,stockCaliper:0.12),6,accuracy:0.000001)
        paper.bulk = -1; XCTAssertFalse(paper.isValid)
    }
    func testPerfectCoverSpreadSpineFlapsAndSelectedPanels() throws {
        var p = project(.perfectBound)
        p.book?.coverAllowance = 0.3; p.book?.adhesiveAllowance = 0.5; p.book?.leftFlap = 10; p.book?.rightFlap = 20
        let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,"\(plan.issues)")
        let cover = try XCTUnwrap(plan.sheets.first { $0.bookInfo?.section == .cover }),info = try XCTUnwrap(cover.bookInfo)
        XCTAssertEqual(info.interiorPageCount,16)
        XCTAssertEqual(try XCTUnwrap(info.spine),1.76,accuracy:0.000001)
        XCTAssertEqual(info.spreadSize.width,131.76,accuracy:0.000001); XCTAssertEqual(info.spreadSize.height,70)
        let back = try XCTUnwrap(cover.front.slots.first { $0.sourcePageNumber==20 }),front = try XCTUnwrap(cover.front.slots.first { $0.sourcePageNumber==1 })
        XCTAssertEqual(front.x-back.x,51.76,accuracy:0.000001)
        XCTAssertEqual(cover.front.slots.filter { $0.bookRegion=="Kulak" }.count,2)
        XCTAssertEqual(Set(cover.back.slots.compactMap(\.sourcePageNumber)),Set([2,19]))
        let interior = plan.sheets.filter { $0.bookInfo?.section == .interior }.flatMap { $0.front.slots+$0.back.slots }.compactMap(\.sourcePageNumber)
        XCTAssertEqual(interior.sorted(),Array(3...18))
        XCTAssertFalse(cover.front.marks.contains { $0.kind == .pageLabel && $0.label == "Sırt" },"Proof labels are not production artwork")
    }
    func testCreepIsMonotonicByNestedLeafEvenWhenManyLeavesShareOnePressSheet() throws {
        var p = project(); let unchanged = ImpositionPlanner.plan(p)
        p.book?.creepEnabled = true
        let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,"\(plan.issues)")
        let body = plan.sheets.filter { $0.bookInfo?.section == .interior }
        var shifts: [Int:Double] = [:]
        for slot in body.flatMap({ $0.front.slots+$0.back.slots }) {
            let leaf = try XCTUnwrap(slot.bookLeafIndex),left = try XCTUnwrap(slot.bookPanelIsLeft)
            XCTAssertEqual(slot.artworkOffset.x,(left ? 1 : -1)*(0.25+Double(leaf)*0.12),accuracy:0.000001)
            shifts[leaf] = abs(slot.artworkOffset.x)
        }
        XCTAssertEqual(shifts.keys.sorted(),[0,1,2,3])
        for leaf in 1...3 { XCTAssertGreaterThan(shifts[leaf]!,shifts[leaf-1]!) }
        XCTAssertEqual(try XCTUnwrap(body.first?.bookInfo?.maximumCreep),0.61,accuracy:0.000001)
        let before = unchanged.sheets.filter { $0.bookInfo?.section == .interior }.flatMap { $0.front.slots }
        let after = body.flatMap { $0.front.slots }
        XCTAssertEqual(before.map(\.origin),after.map(\.origin)); XCTAssertEqual(before.map(\.artworkClip),after.map(\.artworkClip))
        XCTAssertTrue(plan.sheets.filter { $0.bookInfo?.section == .cover }.flatMap { $0.front.slots+$0.back.slots }.allSatisfy { $0.artworkOffset==Point(0,0) })
    }
    func testCreepRespectsRotationAndSamePlateMetadataForEveryTurnStyle() {
        for turn in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
            var p = project(); p.settings.turnMethod = turn; p.book?.creepEnabled = true
            p.sheet.size = Size(240,180); p.sheet.orientation = .landscape
            let plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport,"\(plan.issues)")
            for slot in plan.sheets.filter({ $0.bookInfo?.section == .interior }).flatMap({ $0.front.slots+$0.back.slots }) {
                XCTAssertGreaterThan(abs(slot.artworkOffset.x),0)
                XCTAssertNotNil(slot.bookLeafIndex)
            }
        }
    }
    func testExcludedCoverSelectionBlankInsideAndInvalidCombinations() {
        var p = project(); p.coverMode = .excluded
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p.book?.selection.front = 3; p.book?.selection.back = 18; p.book?.selection.insideFront = 0; p.book?.selection.insideBack = 0
        XCTAssertEqual(p.bookInteriorPages.count,18)
        let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertFalse(plan.sheets.first { $0.bookInfo?.section == .cover }!.hasContent(on:.back))
        p.book?.selection.back = 3
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p.book?.selection.back = 999
        XCTAssertTrue(ImpositionPlanner.plan(p).issues.contains { $0.message.contains("etkin kaynakta yok") })
        p = project(.perfectBound); p.book?.interiorPaper.microns = nil
        let missing = ImpositionPlanner.plan(p); XCTAssertFalse(missing.canExport); XCTAssertFalse(missing.sheets.isEmpty)
        p = project(); p.book?.creepEnabled = true; p.book?.coverPaper.microns = nil
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p = project(.perfectBound); p.book?.creepEnabled = true
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
    }
    func testSeparateSpreadSizeMismatchWarnsExactValuesAndKeepsNativeSize() throws {
        var p = project(.perfectBound,count:8); p.coverMode = .separate
        p.pages += [SourcePage(number:9,trimSize:Size(101,70),availableBleed:3)]
        p.book?.coverSourceID = UUID(); p.book?.coverPDFPages = [9]; p.book?.auxiliaryPages = [9]; p.book?.coverArtwork = .spread
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertTrue(plan.issues.contains { $0.severity == .warning && $0.message.contains("101.00×70.00") && $0.message.contains("100.48×70.00") })
        let slot = try XCTUnwrap(plan.sheets.first { $0.bookInfo?.section == .cover }?.front.slots.first)
        XCTAssertEqual(slot.size,Size(101,70),"Mismatched PDF must not be silently scaled")
        XCTAssertEqual(try XCTUnwrap(slot.artworkClip?.size.width),106.48,accuracy:0.000001)
    }
    func testSettingsRoundtripAndOldProjectsKeepLegacyBookletPlan() throws {
        var p = project(.perfectBound); p.book?.coverArtwork = .spread; p.book?.leftFlap = 12
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)),p)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any]); object.removeValue(forKey:"book")
        let old = try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(old.book); XCTAssertTrue(ImpositionPlanner.plan(old).canExport)
        XCTAssertTrue(ImpositionPlanner.plan(old).sheets.allSatisfy { $0.bookInfo==nil && $0.front.slots.allSatisfy { $0.artworkOffset==Point(0,0) } })
    }
    func testCoverAndBodyFitDiagnosticsPointAtTheirOwnSection() throws {
        var p = project(.perfectBound); p.settings.signatureSize = .thirtyTwo
        p.sheet = SheetSpec(size:Size(160,120),orientation:.landscape)
        var plan = ImpositionPlanner.plan(p)
        XCTAssertFalse(plan.canExport)
        XCTAssertEqual(plan.sheets.first?.bookInfo?.section,.cover)
        XCTAssertEqual(plan.diagnosticSheets.first?.bookInfo?.section,.interior)
        let bodyRef = try XCTUnwrap(plan.issues.first { $0.slot != nil }?.slot)
        XCTAssertEqual(bodyRef.sheet,plan.sheets.count)
        p.sheet.size = Size(90,80)
        plan = ImpositionPlanner.plan(p)
        XCTAssertEqual(plan.diagnosticSheets.count,2)
        let coverRef = try XCTUnwrap(plan.issues.first { $0.message.hasPrefix("Kapak:") && $0.slot != nil }?.slot)
        XCTAssertEqual(coverRef.sheet,1)
        XCTAssertEqual(plan.diagnosticSheets[coverRef.sheet].bookInfo?.section,.cover)
    }

}
