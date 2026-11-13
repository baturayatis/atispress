import XCTest
@testable import ImpositionCore

final class SerialDistributionTests: XCTestCase {
    func project(mode:SerialField.Mode = .sequential) -> Project {
        var p = Project(pages:[1,2].map { SourcePage(number:$0,trimSize:Size(90,50)) },sheet:SheetSpec(size:Size(220,160)),
                        settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0),stepAndRepeat:StepAndRepeatSettings(columns:2,rows:1,allowRotation:false,quantity:100))
        var field = SerialField(digits:0,sides:.both,mode:mode); field.distribution = .block
        p.serialFields = [field]; return p
    }
    func testTwoBlocksEachGetConsecutiveHundredInBothOrdersAndBackRules() throws {
        for mode in [SerialField.Mode.sequential,.stack] {
            for rule in [SerialField.BackNumber.same,.consecutive] {
                var p = project(mode:mode); p.serialFields[0].backNumbering = rule
                let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first),recipe = try XCTUnwrap(sheet.serialPlan)
                XCTAssertTrue(plan.canExport,"\(plan.issues)"); XCTAssertEqual(sheet.repeatCount,100)
                for block in 0..<2 {
                    let front = try XCTUnwrap(sheet.front.slots.first { $0.copyIndex == block })
                    let back = try XCTUnwrap(sheet.back.slots.first { $0.copyIndex == block })
                    let first = try XCTUnwrap(recipe.placements(slot:front,slotIndex:0,kind:.front,repetition:0).first)
                    let last = try XCTUnwrap(recipe.placements(slot:front,slotIndex:0,kind:.front,repetition:99).first)
                    XCTAssertEqual(first.field.value(at:first.index),Int64(rule == .same ? block*100+1 : block*200+1))
                    XCTAssertEqual(last.index-first.index,rule == .same ? 99 : 198)
                    let reverse = try XCTUnwrap(recipe.placements(slot:back,slotIndex:0,kind:.back,repetition:0).first)
                    XCTAssertEqual(reverse.index-first.index,rule == .same ? 0 : 1)
                }
                if rule == .same { XCTAssertEqual(recipe.blockRanges(field:p.serialFields[0]),["Blok 1: 1 – 100","Blok 2: 101 – 200"]) }
            }
        }
    }
    func testBlockOverflowZeroStepAndManualDigitsBlockExportAndCopyModeRestoresCount() throws {
        var p = project(); p.serialFields[0].start = Int64.max-100
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p.serialFields[0].start = 1; p.serialFields[0].step = 0
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p.serialFields[0].step = 1; p.serialFields[0].fixedDigits = true; p.serialFields[0].digits = 2
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p.serialFields[0].fixedDigits = false
        var ninety = p; ninety.stepAndRepeat.quantity = 90
        let padded = ImpositionPlanner.plan(ninety).sheets[0]
        XCTAssertEqual(padded.serialPlan?.fields.first?.digits,3)
        XCTAssertEqual(padded.serialPlacements(side:padded.front,kind:.front,repetition:0).first?.text,"001")
        let blocks = ImpositionPlanner.plan(p); p.serialFields[0].distribution = .copy
        let copy = ImpositionPlanner.updatingSerials(in:blocks,project:p)
        XCTAssertEqual(copy.sheets.first?.repeatCount,50)
        XCTAssertEqual(copy.sheets,ImpositionPlanner.plan(p).sheets)
    }
    func testGangBlocksHaveIndependentRangesAndJobOverlapIsValidated() throws {
        var p = project(); p.binding = .gang; p.gang = GangSettings(); p.gang?.mode = .manual
        var job = GangJob(sourceID:UUID(),name:"Bilet",front:p.pages[0],back:p.pages[1]); job.quantity = 100; job.bleed = 0; job.serialFields = p.serialFields
        p.gang?.jobs = [job]
        p.gang?.blocks = [GangBlock(jobID:job.id,origin:Point(10,10)),GangBlock(jobID:job.id,origin:Point(110,10))]
        let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first)
        XCTAssertTrue(plan.canExport,"\(plan.issues)"); XCTAssertEqual(sheet.repeatCount,100)
        XCTAssertEqual(sheet.serialPlacements(side:sheet.front,kind:.front,repetition:99).map { $0.field.value(at:$0.index)! },[100,200])
        var second = job; second.id = UUID(); second.name = "İş 2"
        job.serialFields[0].distribution = .job; second.serialFields[0].distribution = .job
        p.gang?.jobs = [job,second]; p.gang?.blocks[1].jobID = second.id
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p.gang?.jobs[1].serialFields[0].start = 101
        XCTAssertTrue(ImpositionPlanner.plan(p).canExport)
    }
    func testFlatJobRangesDoNotOverlapAndBlockCostsCountAllProducts() {
        var p = project()
        var second = SerialField(jobIndex:1,start:50,sides:.both); second.distribution = .job
        p.pages += [3,4].map { SourcePage(number:$0,trimSize:Size(90,50)) }
        p.serialFields[0].distribution = .job; p.serialFields.append(second)
        XCTAssertTrue(ImpositionPlanner.plan(p).issues.contains { $0.message.contains("aralıkları çakışıyor") })
        p.serialFields[1].start = 101
        XCTAssertTrue(ImpositionPlanner.plan(p).canExport)
        p = project()
        var library = PriceLibrary(); library.margin = 0; library.vat = 0
        let result = CostCalculator.calculate(project:p,plan:ImpositionPlanner.plan(p),library:library)
        XCTAssertEqual(result.quantity,200)
        XCTAssertEqual(ImpositionPlanner.plan(p).sheets[0].unnumberedCopiesDescription,"0")
    }

    func testBlockCountersContinueAcrossGangJobsAndExplicitCollisionsAreRejected() throws {
        var p = project(); p.binding = .gang; p.gang = GangSettings(); p.gang?.mode = .manual
        var first = GangJob(sourceID:UUID(),name:"Bir",front:p.pages[0],back:p.pages[1]); first.quantity = 100; first.bleed = 0; first.serialFields = p.serialFields
        var second = first; second.id = UUID(); second.name = "İki"
        p.gang?.jobs = [first,second]
        p.gang?.blocks = [GangBlock(jobID:first.id,origin:Point(10,10)),GangBlock(jobID:second.id,origin:Point(110,10))]
        let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first)
        XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertEqual(sheet.serialPlacements(side:sheet.front,kind:.front,repetition:0).map { $0.field.value(at:$0.index)! },[1,101])
        XCTAssertEqual(sheet.serialPlacements(side:sheet.front,kind:.front,repetition:99).map { $0.field.value(at:$0.index)! },[100,200])
        p.gang?.jobs[1].serialFields[0].start = 50
        XCTAssertTrue(ImpositionPlanner.plan(p).issues.contains { $0.message.contains("aralıkları çakışıyor") })
        var flat = project(); flat.pages += [3,4].map { SourcePage(number:$0,trimSize:Size(90,50)) }
        var field = SerialField(jobIndex:1,digits:0,sides:.both); field.distribution = .block
        flat.serialFields.append(field)
        let flatPlan = ImpositionPlanner.plan(flat)
        XCTAssertTrue(flatPlan.canExport)
        XCTAssertEqual(flatPlan.sheets[1].serialPlan?.fields.first?.start,201)
    }

}
