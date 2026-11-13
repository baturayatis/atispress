import XCTest
import ImpositionCore
@testable import AtisPressApp

@MainActor
final class ScalingInspectorTests: XCTestCase {
    private func workspace(_ sizes:[Size]) -> Workspace {
        let model = Workspace()
        model.project.pages = sizes.enumerated().map { SourcePage(number:$0.offset+1,trimSize:$0.element) }
        model.project.stepAndRepeat.pageLayout = PageLayoutSettings()
        model.project.stepAndRepeat.pageLayout?.mode = .simplex
        return model
    }
    func testIdenticalSizesAreGroupedAndSummaryUsesAllJobs() {
        let model = workspace(Array(repeating:Size(100,60),count:6))
        XCTAssertEqual(model.groupedScalingRows.count,1)
        XCTAssertEqual(model.scalingSummary,"6 iş farklı ebatta — ölçekle")
        model.updateScaling { $0.enabled = true; $0.defaults.mode = .fill }
        XCTAssertEqual(model.groupedScalingRows[0].title,"İş 1-6: 100×60 → 90×50")
        XCTAssertEqual(model.scalingSummary,"6 iş · %90 ölçek")
        model.setScale(RescaleSettings(target:Size(85,55),mode:.stretch),pages:[2],gangID:nil,jobIndex:1)
        XCTAssertEqual(model.groupedScalingRows.count,2)
        XCTAssertEqual(model.scalingSummary,"6 iş · %85–%92 ölçek")
        XCTAssertEqual(model.project.rescale(for:1,jobIndex:0)?.settings.mode,.fill)
        XCTAssertEqual(model.project.rescale(for:2,jobIndex:1)?.settings.mode,.stretch)
        model.setScale(nil,pages:[3],gangID:nil,jobIndex:2)
        XCTAssertNil(model.project.rescale(for:3,jobIndex:2))
        XCTAssertNotNil(model.project.rescale(for:4,jobIndex:3))
    }
    func testLegacyBroadFlagBecomesIndependentRepeatedJobOverrides() {
        let model = workspace([Size(100,60),Size(100,60)])
        model.project.pages[1].number = 1
        model.project.rescaleJobs = [RescaleJob(pages:[1],settings:RescaleSettings(mode:.fill))]
        let before = ImpositionPlanner.plan(model.project)
        model.project.migrateScaling()
        XCTAssertEqual(ImpositionPlanner.plan(model.project).sheets,before.sheets)
        XCTAssertEqual(model.project.scaling?.overrides.map(\.jobIndex),[0,1])
        model.setScale(nil,pages:[1],gangID:nil,jobIndex:0)
        XCTAssertNil(model.project.rescale(for:1,jobIndex:0))
        XCTAssertEqual(model.project.rescale(for:1,jobIndex:1)?.settings.mode,.fill)
    }
    func testMatchingSizesAndEmptySummary() {
        let model = workspace([Size(90,50),Size(90.01,50)])
        XCTAssertEqual(model.scalingSummary,"Tüm işler hedef ebatta")
        XCTAssertTrue(model.groupedScalingRows.allSatisfy { $0.title.contains("ebat uygun") })
        model.project.pages = []
        XCTAssertEqual(model.scalingSummary,"Tüm işler hedef ebatta")
    }
    func testVersion17MigrationPreservesPlanAndRoundtrip() throws {
        let model = workspace([Size(100,60),Size(100,60),Size(100,60)])
        model.project.rescaleJobs = [RescaleJob(pages:[1],settings:RescaleSettings(mode:.fill),jobIndex:0),RescaleJob(pages:[2],settings:RescaleSettings(target:Size(85,55),mode:.stretch),jobIndex:1)]
        // A source reference permits testing document decoding without filesystem resolution.
        var state = model.state
        state.order = [1,2,3]; state.included = [1,2,3]
        state.source = ProjectSource(path:"/fixture.pdf",bookmark:Data(),fileName:"fixture.pdf",fileSize:0)
        let legacyPlan = ImpositionPlanner.plan(model.project)
        var file = ProjectDocument(state:state); file.version = 17
        let migrated = try ProjectDocument.decode(file.encoded())
        XCTAssertEqual(migrated.state.project.scaling?.enabled,false)
        XCTAssertEqual(migrated.state.project.scaling?.overrides.count,2)
        XCTAssertNil(migrated.state.project.rescaleJobs)
        var project = migrated.state.project; project.pages = model.project.pages
        let migratedPlan = ImpositionPlanner.plan(project)
        XCTAssertEqual(migratedPlan.sheets,legacyPlan.sheets)
        XCTAssertEqual(migratedPlan.issues,legacyPlan.issues)
        XCTAssertEqual(migratedPlan.generatedBleed,legacyPlan.generatedBleed)
        file = ProjectDocument(state:migrated.state)
        XCTAssertEqual(try ProjectDocument.decode(file.encoded()),file)
        model.project = project
        model.updateScaling { $0.enabled = true }
        model.setScale(nil,pages:[3],gangID:nil,jobIndex:2)
        state.project = model.project
        let current = ProjectDocument(state:state)
        XCTAssertEqual(try ProjectDocument.decode(current.encoded()),current)
    }
}
