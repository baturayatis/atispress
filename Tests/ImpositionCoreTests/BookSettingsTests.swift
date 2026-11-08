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

    func testA5Booklet106PagesSeparateCoverFitsManualA4WithZeroFoldGutterAndMarksOff() throws {
        var p = Project(pages:(1...110).map { SourcePage(number:$0,trimSize:SheetPreset.a5.size,availableBleed:3) },binding:.saddleStitch,
                        sheet:SheetSpec(preset:.a4,margins:Insets(),gripperWidth:0,gutter:0,orientation:.landscape))
        p.coverMode = .separate; p.exportMarks = .none
        p.settings.cropMarkLength = 0; p.settings.cropMarkOffset = 0
        // Keep the normal 3 mm bleed. Zero sheet clearances must clip its outer
        // extent, not turn it into an unrequested 6 mm between fold neighbors.
        var book = BookSettings(); book.coverSourceID = UUID(); book.coverPDFPages = [107,108,109,110]; book.auxiliaryPages = book.coverPDFPages
        p.book = book
        var auto = AutoLayoutSettings(); auto.sheetSelection = .fixed; auto.manualFields = [.sheetSize,.marginLeft,.marginRight,.marginTop,.marginBottom,.gripperWidth,.gutter,.exportCrop]
        p.autoLayout = auto
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport,plan.issues.map(\.message).joined(separator:"\n"))
        XCTAssertEqual(p.sheet.gutter,0)
        XCTAssertEqual(plan.addedBlankPages,2)
        let interiors = plan.sheets.filter { $0.bookInfo?.section == .interior }
        XCTAssertEqual(interiors.count,27)
        XCTAssertEqual(plan.sheets.filter { $0.bookInfo?.section == .cover }.count,1)
        XCTAssertTrue(plan.diagnosticSheets.isEmpty)
        let first = try XCTUnwrap(interiors.first),slots = first.front.slots.sorted { $0.x<$1.x }
        XCTAssertEqual(first.size,Size(297,210)); XCTAssertEqual(slots.count,2)
        XCTAssertEqual(slots[1].x-slots[0].x-slots[0].size.width,0,accuracy:0.000001)
        XCTAssertEqual(slots.map { $0.x+$0.size.width }.max()!-slots.map(\.x).min()!,296,accuracy:0.000001)
        XCTAssertTrue(plan.sheets.flatMap { $0.front.slots+$0.back.slots }.allSatisfy { slot in
            guard let r = slot.artworkClip else { return false }
            return r.origin.x>=0 && r.origin.y>=0 && r.origin.x+r.size.width<=297.000001 && r.origin.y+r.size.height<=210.000001
        })
        p.sheet.gutter = 6
        let spaced = ImpositionPlanner.plan(p)
        XCTAssertFalse(spaced.canExport,"An explicitly requested 6 mm gap really needs 302 mm and must not be silently removed")
        XCTAssertTrue(spaced.issues.contains { $0.message.contains("gereken 302.00×210.00") })
    }

    func testA5Booklet106ManualA4ZeroBleedAndZeroLengthCropDoesNotReserveOffset() {
        var p = Project(pages:(1...106).map { SourcePage(number:$0,trimSize:Size(148,210),availableBleed:0) },binding:.saddleStitch,
                        sheet:SheetSpec(preset:.a4,margins:Insets(),gripperWidth:0,gutter:0,orientation:.landscape))
        p.settings.bleed = 0; p.settings.cropMarkLength = 0; p.settings.cropMarkOffset = 3.5
        p.exportMarks.crop = true // Açık · Otomatik; no actual stroke when length is zero.
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport,plan.issues.map(\.message).joined(separator:"\n"))
        XCTAssertEqual(p.layoutExteriorReserve,0)
        XCTAssertEqual(plan.sheets.count,27)
        p.settings.cropMarkLength = 5
        let marked = ImpositionPlanner.plan(p)
        XCTAssertFalse(marked.canExport)
        XCTAssertTrue(marked.issues.contains { $0.message.contains("gereken 313.00×227.00") && $0.message.contains("kullanılabilir 297.00×210.00") },"Required size includes marks once; usable size must exclude margins only")
        p.exportMarks.crop = false
        XCTAssertTrue(ImpositionPlanner.plan(p).canExport,"Disabled crop marks must reserve nothing even with a saved nonzero length/offset")
    }

}
