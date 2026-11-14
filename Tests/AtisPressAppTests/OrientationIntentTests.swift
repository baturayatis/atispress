import XCTest
import ImpositionCore
@testable import AtisPressApp

@MainActor final class OrientationIntentTests:XCTestCase {
    func testDigital857x54On33x48AutomaticDoesNotReuseResolvedPortrait() throws {
        let model = Workspace()
        var project = Workspace.newProject()
        project.pages = [SourcePage(number:1,trimSize:Size(85.7,54),availableBleed:3)]
        // First import automatically chooses upright cards on portrait SRA3.
        let arranged = SmartAutoLayout.arrange(project)
        XCTAssertEqual(arranged.project.sheet.orientation,.portrait)
        XCTAssertFalse(try XCTUnwrap(arranged.project.autoLayout).isFixed(.orientation))
        model.project = arranged.project
        // Assignment in a test is seen as a manual edit; restore the actual automatic ownership.
        model.project.autoLayout = arranged.project.autoLayout
        XCTAssertEqual(model.workflowOrientation,.auto)
        XCTAssertEqual(model.project.autoLayout?.production,.digital)
        XCTAssertTrue(model.project.exportMarks.crop)
        model.selectWorkflowSheet("33×48")
        let plan = ImpositionPlanner.plan(model.project)
        let sheet = try XCTUnwrap(plan.sheets.first)
        XCTAssertEqual(sheet.repeatLayout?.copiesPerSheet,25)
        XCTAssertEqual(sheet.front.slots.first?.rotation,0)
        XCTAssertGreaterThan(sheet.size.width,sheet.size.height)
    }
    func testNewProjectsDoNotInheritManualOrientationAndExplicitChoiceIsPreserved() {
        let model = Workspace()
        XCTAssertEqual(model.project.sheet.orientation,.auto)
        model.selectWorkflowOrientation(.portrait)
        model.selectWorkflowSheet("33×48")
        XCTAssertEqual(model.workflowOrientation,.portrait)
        XCTAssertEqual(model.project.sheet.orientation,.portrait)
        XCTAssertEqual(Workspace.newProject().sheet.orientation,.auto)
        XCTAssertEqual(Workspace().workflowOrientation,.auto)
        model.selectWorkflowOrientation(.auto)
        XCTAssertFalse(model.project.autoLayout!.isFixed(.orientation))
        XCTAssertEqual(model.project.sheet.orientation,.auto)
    }
    func testRecommendationAndPlannerShareUprightTieRule() throws {
        var project = Workspace.newProject()
        project.pages = [SourcePage(number:1,trimSize:Size(85.7,54),availableBleed:3)]
        project.sheet.size = SheetPreset.cm33x48.size
        project.sheet.orientation = .portrait // A previously resolved automatic value.
        var state = AutoLayoutSettings.legacy
        state.production = .digital; state.manualFields.remove(.orientation)
        project.autoLayout = state
        let recommendation = SmartAutoLayout.arrange(project)
        let sheet = try XCTUnwrap(recommendation.plan.sheets.first)
        XCTAssertEqual(sheet.repeatLayout?.copiesPerSheet,25)
        XCTAssertEqual(sheet.front.slots.first?.rotation,0)
        XCTAssertEqual(sheet.size,Size(480,330))
        project.sheet.orientation = .auto
        XCTAssertEqual(ImpositionPlanner.plan(project).sheets,recommendation.plan.sheets)
    }

    func testOrientationChangeUpdatesPreviewAndAutomaticOwnershipRoundtrips() async throws {
        let model = Workspace()
        model.project.pages = [SourcePage(number:1,trimSize:Size(85.7,54),availableBleed:3)]
        model.selectWorkflowSheet("33×48")
        for orientation in [Orientation.portrait,.landscape,.auto] {
            model.selectWorkflowOrientation(orientation)
            for _ in 0..<300 where model.planning { try await Task.sleep(for:.milliseconds(10)) }
            let sheet = try XCTUnwrap(model.currentSheet)
            XCTAssertEqual(sheet.repeatLayout?.copiesPerSheet,25)
            XCTAssertEqual(sheet.repeatLayout?.columns,5); XCTAssertEqual(sheet.repeatLayout?.rows,5)
            XCTAssertEqual(sheet.front.slots.first?.rotation,orientation == .portrait ? 90 : 0)
            XCTAssertTrue(model.workflowOrientationSummary.contains(orientation == .portrait ? "Dikey" : "Yatay"))
            let restored = try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(model.project))
            XCTAssertEqual(restored.sheet.orientation,orientation)
            XCTAssertEqual(restored.autoLayout?.isFixed(.orientation),orientation != .auto)
        }
    }

}
