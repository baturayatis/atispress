import XCTest
@testable import ImpositionCore

final class GangLayoutTests: XCTestCase {
    func project() -> Project {
        let pages = [SourcePage(number:1,trimSize:Size(60,40)),SourcePage(number:2,trimSize:Size(80,55)),SourcePage(number:3,trimSize:Size(35,90)),SourcePage(number:4,trimSize:Size(60,40))]
        var p = Project(pages:pages,binding:.gang,sheet:SheetSpec(preset:.cm33x48,margins:Insets(left:10,right:10,top:10,bottom:10),gripperWidth:0,gutter:0))
        var settings = GangSettings()
        settings.jobs = pages.prefix(3).enumerated().map { i,page in
            var j = GangJob(sourceID:UUID(),name:"İş \(i+1)",front:page,back:i == 0 ? pages[3] : nil)
            j.quantity = [1000,700,400][i]; j.generatedBleed.enabled = true; j.serialFields = [SerialField(prefix:"J\(i)-",mode:.stack)]
            return j
        }
        p.gang = settings; return p
    }
    private func overlaps(_ a: Rect,_ b: Rect) -> Bool {
        min(a.origin.x+a.size.width,b.origin.x+b.size.width)>max(a.origin.x,b.origin.x)+0.000001 && min(a.origin.y+a.size.height,b.origin.y+b.size.height)>max(a.origin.y,b.origin.y)+0.000001
    }
    func testThreeUnlikeJobsPackWithoutOverlapAndAllCopiesUseCommonSheetCount() throws {
        let p = project(),plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport,"\(plan.issues)")
        let sheet = try XCTUnwrap(plan.sheets.first),layout = try XCTUnwrap(sheet.gangLayout)
        XCTAssertEqual(layout.jobs.count,3)
        XCTAssertEqual(sheet.repeatCount,GangPlanner.sheetCount(required:layout.jobs.map(\.required),copies:layout.jobs.map(\.copiesPerSheet)))
        for (i,slot) in sheet.front.slots.enumerated() {
            for other in sheet.front.slots.dropFirst(i+1) {
                XCTAssertFalse(overlaps(Rect(x:slot.x,y:slot.y,width:slot.size.width,height:slot.size.height),Rect(x:other.x,y:other.y,width:other.size.width,height:other.size.height)))
                XCTAssertFalse(overlaps(try XCTUnwrap(slot.artworkClip),Rect(x:other.x,y:other.y,width:other.size.width,height:other.size.height)))
            }
        }
        for result in layout.jobs { XCTAssertEqual(result.surplus,UInt64(sheet.repeatCount*result.copiesPerSheet-result.required)) }
        let again = ImpositionPlanner.plan(p)
        XCTAssertEqual(sheet,again.sheets.first,"Automatic block IDs and placement must be stable across save/open")
    }
    func testFormulaIncludesFireAndDoesNotOverflowForLargeQuantities() {
        XCTAssertEqual(GangPlanner.sheetCount(required:[100,250,32],copies:[4,10,3]),25)
        XCTAssertEqual(GangPlanner.sheetCount(required:[Int.max],copies:[2]),Int.max/2+1)
        XCTAssertNil(GangPlanner.sheetCount(required:[1],copies:[0]))
        var p = project(); p.gang?.jobs[0].waste.mode = .fixed; p.gang?.jobs[0].waste.fixed = 50
        let result = ImpositionPlanner.plan(p).sheets.first?.gangLayout?.jobs.first
        XCTAssertEqual(result?.required,1050)
        XCTAssertEqual(result?.serialPlan.quantity,1000)
        p.gang?.jobs[0].waste.numberCopies = true
        XCTAssertEqual(ImpositionPlanner.plan(p).sheets.first?.gangLayout?.jobs.first?.serialPlan.quantity,1050)
    }
    func testGuillotineRejectsBentCutAndInterlockingWindmill() {
        XCTAssertFalse(GangPlanner.isStraightCut([Point(0,0),Point(10,0),Point(10,10)]))
        XCTAssertTrue(GangPlanner.isStraightCut([Point(0,0),Point(10,0),Point(20,0)]))
        let windmill = [Rect(x:0,y:2,width:2,height:1),Rect(x:2,y:1,width:1,height:2),Rect(x:1,y:0,width:2,height:1),Rect(x:0,y:0,width:1,height:2),Rect(x:1,y:1,width:1,height:1)]
        XCTAssertNil(GangPlanner.guillotineCuts(windmill,within:Rect(x:0,y:0,width:3,height:3)))
        // An L-shaped arrangement can be cut with two straight cuts; it is the knife path that must not bend.
        XCTAssertNotNil(GangPlanner.guillotineCuts([Rect(x:0,y:0,width:1,height:2),Rect(x:1,y:0,width:1,height:1)],within:Rect(x:0,y:0,width:2,height:2)))
    }
    func testManualOverlapAndMarginErrorsKeepUserCoordinates() throws {
        var p = project(); let first = p.gang!.jobs[0],second = p.gang!.jobs[1]
        p.gang?.mode = .manual
        let thirdID = p.gang!.jobs[2].id
        p.gang?.blocks = [GangBlock(jobID:first.id,origin:Point(-5,20)),GangBlock(jobID:second.id,origin:Point(0,20)),GangBlock(jobID:thirdID,origin:Point(100,100))]
        let plan = ImpositionPlanner.plan(p)
        XCTAssertFalse(plan.canExport)
        XCTAssertEqual(plan.sheets.first?.gangLayout?.blocks.first?.origin,Point(-5,20))
        XCTAssertTrue(plan.issues.contains { $0.message.contains("çakışıyor") })
        XCTAssertTrue(plan.issues.contains { $0.message.contains("sınırını aşıyor") })
    }
    func testMixedBackAlignmentAndSamePlateFacesForEveryTurnAndGripper() throws {
        for turn in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] { for edge in [Edge.bottom,.left] {
            var p = project(); p.settings.turnMethod = turn; p.sheet.gripperEdge = edge
            let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first)
            XCTAssertTrue(plan.canExport,"\(plan.issues)")
            for f in sheet.front.slots where f.itemSide == .front {
                let b = try XCTUnwrap(sheet.back.slots.first { $0.gangJobID==f.gangJobID && $0.copyIndex==f.copyIndex && $0.itemSide == .back })
                if sheet.backFlipsX { XCTAssertEqual(b.x,sheet.size.width-f.x-f.size.width,accuracy:0.000001); XCTAssertEqual(b.y,f.y) }
                else { XCTAssertEqual(b.y,sheet.size.height-f.y-f.size.height,accuracy:0.000001); XCTAssertEqual(b.x,f.x) }
                if f.gangJobID==p.gang!.jobs[0].id { XCTAssertEqual(b.sourcePageNumber,4) } else { XCTAssertNil(b.sourcePageNumber); XCTAssertTrue(sheet.serialRecipe(for:b)!.placements(slot:b,slotIndex:0,kind:.back,repetition:0).isEmpty) }
            }
        } }
    }
    func testHundredThousandSerialsAreLazyAndPerJobIndependent() throws {
        var p = project(); for i in p.gang!.jobs.indices { p.gang!.jobs[i].quantity = 100_000 }
        let start = Date(),sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
        for result in sheet.gangLayout!.jobs {
            let field = result.serialPlan.fields[0],r = result.serialPlan
            XCTAssertEqual(r.ordinal(copy:0,repetition:0,mode:.stack),0)
            XCTAssertEqual(r.ordinal(copy:1,repetition:0,mode:.stack),r.sheetCount)
            XCTAssertNotNil(r.range(field:field,repetition:r.sheetCount-1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start),10)
        XCTAssertLessThan(sheet.front.slots.count,1000)
    }
    func testSettingsRoundtripAndLegacyOptionalDefaults() throws {
        let p = project(),data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:data),p)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]); json.removeValue(forKey:"gang"); json["binding"] = "stepAndRepeat"
        XCTAssertNil(try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:json)).gang)
    }
    func testEightJobSearchAndManualGutterAreBounded() throws {
        var p = project(),gang = p.gang!
        gang.jobs = (0..<8).map { i in
            var job = GangJob(sourceID:UUID(),name:"İş \(i)",front:SourcePage(number:1,trimSize:Size(Double(25+i*3),Double(35+i*2))))
            job.quantity = 100_000; job.bleed = 0; return job
        }
        p.gang = gang
        let start = Date(),plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertLessThan(Date().timeIntervalSince(start),15)
        p = project(); p.sheet.gutter = 1
        let invalid = ImpositionPlanner.plan(p)
        XCTAssertFalse(invalid.canExport)
        XCTAssertTrue(invalid.issues.contains { $0.message.contains("en az 6") })
        XCTAssertEqual(p.sheet.gutter,1)
    }
    func testGroupedBleedWarningsOnlyIncludeAffectedJobsPages() {
        var p = project()
        p.gang?.jobs[1].generatedBleed.enabled = false
        let plan = ImpositionPlanner.plan(p),warnings = plan.displayIssues.filter { $0.code == .missingBleed }
        XCTAssertEqual(warnings.count,1)
        XCTAssertEqual(warnings.first?.affectedPages,[2])
        XCTAssertTrue(warnings.first?.message.contains("İş 2") == true)
    }

    func testArtworkOnlyUpdatePreservesSlicingSolutionAndPerJobOwnership() throws {
        var p = project(); let old = ImpositionPlanner.plan(p),slots = try XCTUnwrap(old.sheets.first?.front.slots)
        p.gang?.jobs[1].serialFields[0].prefix = "CHANGED-"
        p.gang?.jobs[1].tint = 0.9; p.gang?.jobs[1].name = "Yeni iş"
        let refreshed = ImpositionPlanner.updatingSerials(in:old,project:p),sheet = try XCTUnwrap(refreshed.sheets.first)
        XCTAssertEqual(sheet.front.slots,slots)
        XCTAssertEqual(sheet.repeatCount,old.sheets.first?.repeatCount)
        XCTAssertEqual(sheet.gangLayout?.jobs[1].job.name,"Yeni iş")
        XCTAssertTrue(sheet.serialPlacements(side:sheet.front,kind:.front,repetition:0).contains { $0.text.hasPrefix("CHANGED-") })
        XCTAssertEqual(p.gang?.mode,.automatic,"Updating artwork must not switch project intent to manual")
    }

}
