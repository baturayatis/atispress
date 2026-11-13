import XCTest
@testable import ImpositionCore

final class RescalingTests: XCTestCase {
    func project(_ mode: RescaleMode) -> Project {
        var p = Project(pages:[SourcePage(number:1,trimSize:Size(100,60),availableBleed:1)],sheet:SheetSpec(size:Size(220,160),gutter:6),
                        settings:ImpositionSettings(bleed:3,cropMarkLength:0,cropMarkOffset:0),stepAndRepeat:StepAndRepeatSettings(columns:2,rows:2,allowRotation:false,quantity:100))
        p.rescaleJobs = [RescaleJob(pages:[1],settings:RescaleSettings(target:Size(90,50),mode:mode))]
        return p
    }
    func testTargetTrimScaleAndRegeneratedBleedInAllModesWithoutChangingSource() throws {
        for mode in RescaleMode.allCases {
            let p = project(mode),plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport,"\(plan.issues)")
            let slot = try XCTUnwrap(plan.sheets.first?.front.slots.first),scale = try XCTUnwrap(slot.rescale)
            XCTAssertEqual(slot.size,Size(90,50)); XCTAssertEqual(p.pages[0].trimSize,Size(100,60))
            XCTAssertTrue(plan.generatedBleed.enabled); XCTAssertEqual(plan.generatedBleed.method,.automatic)
            XCTAssertEqual(scale.factors.width,mode == .fit ? 5/6 : 0.9,accuracy:0.000001)
            XCTAssertEqual(scale.factors.height,mode == .fill ? 0.9 : 5/6,accuracy:0.000001)
            XCTAssertEqual(scale.aspectWarning,mode == .stretch)
            XCTAssertEqual(slot.artworkClip?.size,Size(96,56))
            let auto = SmartAutoLayout.arrange(p)
            XCTAssertEqual(auto.project.pages,p.pages); XCTAssertEqual(auto.project.rescaleJobs,p.rescaleJobs)
            XCTAssertEqual(auto.plan.sheets.first?.front.slots.first?.rescale,scale)
            XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)),p)
        }
    }
    func testPerJobAndBookletScalingUsesTargetForEveryPanel() throws {
        var p = project(.fit)
        p.pages += [SourcePage(number:2,trimSize:Size(100,60)),SourcePage(number:3,trimSize:Size(85,55)),SourcePage(number:4,trimSize:Size(85,55))]
        p.rescaleJobs?[0].pages = [1,2]
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertEqual(plan.sheets[0].front.slots.first?.size,Size(90,50))
        XCTAssertEqual(plan.sheets[1].front.slots.first?.size,Size(85,55))
        p.pages = (1...12).map { SourcePage(number:$0,trimSize:Size(100,60)) }
        p.binding = .saddleStitch; p.book = BookSettings()
        p.rescaleJobs = [RescaleJob(pages:Array(1...12),settings:RescaleSettings())]
        let book = ImpositionPlanner.plan(p)
        XCTAssertTrue(book.canExport,"\(book.issues)")
        XCTAssertTrue(book.sheets.flatMap { $0.front.slots+$0.back.slots }.allSatisfy { $0.rescale?.settings.target == Size(90,50) })
    }
    func testAutomaticDuplexPairingSurvivesDifferentTargetsPerJob() {
        var p = project(.fit)
        p.pages = (1...4).map { SourcePage(number:$0,trimSize:Size(100,60)) }
        p.stepAndRepeat.pageLayout = PageLayoutSettings()
        p.rescaleJobs = [RescaleJob(pages:[1,2],settings:RescaleSettings())]
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport)
        XCTAssertEqual(plan.sheets.count,2)
        XCTAssertEqual(plan.sheets[0].back.slots.first?.sourcePageNumber,2)
        XCTAssertEqual(plan.sheets[1].back.slots.first?.sourcePageNumber,4)
        let auto = SmartAutoLayout.arrange(p)
        XCTAssertEqual(auto.project.stepAndRepeat.pageLayout,p.stepAndRepeat.pageLayout)
        XCTAssertEqual(auto.plan.sheets.count,2)
    }

    func testGangClonesOfSameSourceCanHaveDifferentTargets() throws {
        var p = project(.fit); p.binding = .gang; p.rescaleJobs = nil
        var first = GangJob(sourceID:UUID(),name:"Bir",front:p.pages[0]); first.quantity = 100; first.rescale = RescaleSettings(target:Size(90,50))
        var second = first; second.id = UUID(); second.name = "İki"; second.rescale = RescaleSettings(target:Size(85,55),mode:.fill)
        p.gang = GangSettings(); p.gang?.jobs = [first,second]
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport,"\(plan.issues)")
        let slots = try XCTUnwrap(plan.sheets.first).front.slots
        XCTAssertEqual(slots.first { $0.gangJobID == first.id }?.rescale?.settings.target,Size(90,50))
        XCTAssertEqual(slots.first { $0.gangJobID == second.id }?.rescale?.settings.target,Size(85,55))
    }

    func testRepeatedPDFPageSelectionsKeepIndependentFlatJobTargets() throws {
        var p = project(.fit)
        p.pages = [p.pages[0],p.pages[0]]
        p.stepAndRepeat.pageLayout = PageLayoutSettings(); p.stepAndRepeat.pageLayout?.mode = .simplex
        p.rescaleJobs = [RescaleJob(pages:[1],settings:RescaleSettings(target:Size(90,50)),jobIndex:0),RescaleJob(pages:[1],settings:RescaleSettings(target:Size(85,55)),jobIndex:1)]
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport)
        XCTAssertEqual(plan.sheets[0].front.slots.first?.rescale?.settings.target,Size(90,50))
        XCTAssertEqual(plan.sheets[1].front.slots.first?.rescale?.settings.target,Size(85,55))
    }

}
