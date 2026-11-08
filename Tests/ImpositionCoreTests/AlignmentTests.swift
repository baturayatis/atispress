import XCTest
@testable import ImpositionCore

final class AlignmentTests: XCTestCase {
    func testSRA3ZeroMarginAutomaticRotationFinds25UprightInsteadOf24Rotated() throws {
        var p = Project(pages:[SourcePage(number:1,trimSize:Size(86.7,54),availableBleed:3)],sheet:SheetSpec(preset:.sra3,orientation:.landscape))
        var state = AutoLayoutSettings(); state.sheetSelection = .fixed
        state.manualFields = [.sheetSize,.marginLeft,.marginRight,.marginTop,.marginBottom,.gripperWidth,.orientation]
        p.autoLayout = state
        let result = SmartAutoLayout.arrange(p)
        let sheet = try XCTUnwrap(result.plan.sheets.first),layout = try XCTUnwrap(sheet.repeatLayout)
        XCTAssertEqual(layout.copiesPerSheet,25)
        XCTAssertEqual(layout.columns,5); XCTAssertEqual(layout.rows,5)
        XCTAssertEqual(sheet.front.slots.first?.rotation,0)
    }
    private func cards() -> Project {
        var p = Project(pages:(1...2).map { SourcePage(number:$0,trimSize:Size(86.7,54),availableBleed:3) },
            sheet:SheetSpec(preset:.cm33x48,margins:Insets(left:10,right:10,top:10,bottom:10),gripperEdge:.bottom,gripperWidth:0,gutter:0,orientation:.landscape),
            stepAndRepeat:StepAndRepeatSettings(columns:5,rows:5,allowRotation:false))
        p.blockAlignment = .center; return p
    }
    func testCenteredUsableAreaCountsGripperOnceAndLegacyKeepsItsOrigin() throws {
        var p = cards(); p.sheet.gripperWidth = 12
        let centered = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
        let first = try XCTUnwrap(centered.front.slots.first)
        XCTAssertEqual(first.x,23.25,accuracy:0.00001)
        XCTAssertEqual(first.y,36,accuracy:0.00001) // usable bottom 22, top 320; center 171
        XCTAssertEqual(330-10-(first.y+270),first.y-22,accuracy:0.00001)
        p.alignment = nil
        let legacy = ImpositionPlanner.plan(p)
        p.blockAlignment = .gripper
        XCTAssertEqual(legacy.sheets,ImpositionPlanner.plan(p).sheets)
        XCTAssertEqual(legacy.sheets.first?.front.slots.first?.y,22+p.layoutExteriorReserve)
    }
    func testCenteredFrontBackReflectExactlyForAllTurnMethodsAndGripperEdges() throws {
        for method in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
            for edge in [Edge.bottom,.top,.left,.right] {
                var p = cards(); p.pages = (1...2).map { SourcePage(number:$0,trimSize:Size(30,20),availableBleed:3) }
                p.sheet.margins = Insets(left:11,right:17,top:13,bottom:19)
                p.sheet.gripperEdge = edge; p.sheet.gripperWidth = 12
                p.settings.turnMethod = method
                p.stepAndRepeat.columns = 4; p.stepAndRepeat.rows = 4
                let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,"\(plan.issues)")
                let sheet = try XCTUnwrap(plan.sheets.first)
                for (f,b) in zip(sheet.front.slots,sheet.back.slots) {
                    XCTAssertEqual(f.copyIndex,b.copyIndex)
                    XCTAssertEqual(b.x,sheet.backFlipsX ? sheet.size.width-f.x-f.size.width : f.x,accuracy:0.00001)
                    XCTAssertEqual(b.y,sheet.backFlipsX ? f.y : sheet.size.height-f.y-f.size.height,accuracy:0.00001)
                }
            }
        }
    }
    func testManualMarkOffsetIsNeverReducedForExtraCopyAndTiesPreferUpright() throws {
        var p = cards(); p.sheet = SheetSpec(preset:.sra3,orientation:.landscape)
        p.stepAndRepeat.columns = nil; p.stepAndRepeat.rows = nil; p.stepAndRepeat.allowRotation = true
        var state = AutoLayoutSettings(); state.sheetSelection = .fixed
        state.manualFields = [.sheetSize,.orientation,.marginLeft,.marginRight,.marginTop,.marginBottom,.gripperWidth,.cropOffset]
        p.settings.cropMarkOffset = 3.5; p.autoLayout = state
        let manual = SmartAutoLayout.arrange(p)
        XCTAssertEqual(manual.project.settings.cropMarkOffset,3.5)
        XCTAssertEqual(manual.plan.sheets.first?.repeatLayout?.copiesPerSheet,24)
        p.sheet.size = Size(200,200); p.settings.bleed = 0; p.settings.cropMarkLength = 0; p.exportMarks.crop = false
        p.pages = [SourcePage(number:1,trimSize:Size(40,30))]
        p.autoLayout?.manualFields.formUnion([.bleed,.cropLength,.exportCrop])
        XCTAssertEqual(SmartAutoLayout.arrange(p).plan.sheets.first?.front.slots.first?.rotation,0)
    }
    func testCenteredRotatedBookletBackPanelsAlignBehindFront() throws {
        var p = cards(); p.binding = .perfectBound
        p.pages = (1...4).map { SourcePage(number:$0,trimSize:Size(148,210),availableBleed:0) }
        p.sheet = SheetSpec(size:Size(230,330),orientation:.portrait)
        p.settings = ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0,signatureSize:.four)
        let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,"\(plan.issues)")
        let sheet = try XCTUnwrap(plan.sheets.first)
        let frontOne = try XCTUnwrap(sheet.front.slots.first { $0.sourcePageNumber==1 })
        let backTwo = try XCTUnwrap(sheet.back.slots.first { $0.sourcePageNumber==2 })
        XCTAssertEqual(frontOne.rotation,90); XCTAssertEqual(backTwo.rotation,270)
        XCTAssertEqual(backTwo.x,sheet.size.width-frontOne.x-frontOne.size.width,accuracy:0.00001)
        XCTAssertEqual(backTwo.y,frontOne.y,accuracy:0.00001)
    }

    func testAutomaticGangCentersWholeBlockAndManualCoordinatesArePreserved() throws {
        var p = cards(); p.binding = .gang
        p.sheet.margins = Insets(left:11,right:17,top:13,bottom:19); p.sheet.gripperWidth = 12
        var job = GangJob(sourceID:UUID(),name:"Kart",front:p.pages[0],back:p.pages[1]); job.quantity = 5
        var gang = GangSettings(); gang.jobs = [job]; p.gang = gang
        let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,"\(plan.issues)")
        let sheet = try XCTUnwrap(plan.sheets.first),slots = sheet.front.slots
        let left = slots.map(\.x).min()!,right = slots.map { $0.x+$0.size.width }.max()!
        let bottom = slots.map(\.y).min()!,top = slots.map { $0.y+$0.size.height }.max()!
        XCTAssertEqual(left-11,480-17-right,accuracy:0.00001)
        XCTAssertEqual(bottom-31,330-13-top,accuracy:0.00001)
        p.gang?.mode = .manual
        p.gang?.blocks = [GangBlock(jobID:job.id,origin:Point(30,50))]
        XCTAssertEqual(ImpositionPlanner.plan(p).sheets.first?.front.slots.first?.origin,Point(30,50))
    }
    func testAutomaticResetAlsoResetsMeasuredBookAndGangWithoutLosingJobContent() throws {
        var book = cards(); book.binding = .perfectBound
        book.pages = (1...4).map { SourcePage(number:$0,trimSize:Size(100,150)) }
        book.sheet.gutter = 19; book.blockAlignment = .gripper
        book.autoLayout = .legacy
        let resetBook = SmartAutoLayout.arrange(book,resetOverrides:true)
        XCTAssertEqual(resetBook.project.blockAlignment,.center)
        XCTAssertEqual(resetBook.project.sheet.gutter,6)
        XCTAssertTrue(resetBook.project.autoLayout!.manualFields.isEmpty)
        var gang = cards(); gang.binding = .gang; gang.autoLayout = .legacy
        var settings = GangSettings(); settings.mode = .manual
        var job = GangJob(sourceID:UUID(),name:"Özgün iş",front:gang.pages[0]); job.allowRotation = false
        job.quantity = 17; job.bleed = 0; job.serialFields = [SerialField(prefix:"JOB-")]
        settings.jobs = [job]; settings.blocks = [GangBlock(jobID:job.id,origin:Point(0,0))]; gang.gang = settings
        let resetGang = SmartAutoLayout.arrange(gang,resetOverrides:true)
        XCTAssertEqual(resetGang.project.gang?.mode,.automatic)
        XCTAssertTrue(resetGang.project.gang!.blocks.isEmpty)
        XCTAssertEqual(resetGang.project.gang?.jobs[0].quantity,17)
        XCTAssertEqual(resetGang.project.gang?.jobs[0].serialFields,job.serialFields)
        XCTAssertTrue(resetGang.project.gang!.jobs[0].allowRotation)
        XCTAssertEqual(resetGang.project.gang?.jobs[0].bleed,3)
        XCTAssertEqual(resetGang.project.blockAlignment,.center)
        XCTAssertTrue(resetGang.project.autoLayout!.manualFields.isEmpty)
    }

}
