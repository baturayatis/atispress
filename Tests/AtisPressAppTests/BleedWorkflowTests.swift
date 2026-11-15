import XCTest
import SwiftUI
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class BleedWorkflowTests: XCTestCase {
    func testNewJobDefaultsAcrossEveryBindingAndCoverProduct() {
        let model = Workspace()
        for mode in [BindingMethod.stepAndRepeat, .gang, .saddleStitch, .perfectBound, .spiral, .wireO, .sewn] {
            model.setMode(mode)
            XCTAssertTrue(model.project.settings.generatedBleed.enabled, "\(mode)")
            XCTAssertEqual(model.project.settings.generatedBleed.method, .automatic)
            XCTAssertEqual(model.project.settings.bleed, 3)
        }
    }
    func testAmountLinkageAndWarningIncludingGangAndRealSourceBleed() {
        let model = Workspace()
        model.project.pages = [SourcePage(number:1,trimSize:Size(85,55),availableBleed:0)]
        model.project.settings.generatedBleed.enabled = false
        XCTAssertTrue(model.showsMissingBleedWarning)
        XCTAssertTrue(model.exportPreparationSummary.contains(Workspace.missingBleedWarning))
        model.workflowBleed = 4.5
        XCTAssertTrue(model.editableGeneratedBleed.enabled)
        XCTAssertEqual(model.workflowBleed,4.5)
        XCTAssertFalse(model.showsMissingBleedWarning)
        XCTAssertFalse(model.exportPreparationSummary.contains(Workspace.missingBleedWarning))
        model.project.settings.generatedBleed.enabled = false
        model.project.pages[0].availableBleed = 3
        XCTAssertFalse(model.showsMissingBleedWarning)
        model.project.pages[0].availableBleed = nil
        model.enableMissingBleed()
        XCTAssertFalse(model.showsMissingBleedWarning)
        model.setMode(.gang)
        var job = GangJob(sourceID:UUID(),name:"Kart",front:model.project.pages[0])
        job.generatedBleed.enabled = false
        model.project.gang?.jobs = [job]
        XCTAssertTrue(model.showsMissingBleedWarning)
        model.workflowBleed = 3.5
        XCTAssertTrue(model.editableGeneratedBleed.enabled)
        XCTAssertFalse(model.showsMissingBleedWarning)
        model.editableGeneratedBleed.enabled = false
        model.enableMissingBleed()
        XCTAssertFalse(model.showsMissingBleedWarning)
    }
    func testGuideRequiresEnabledAndPositiveAmountInBothCanvasPaths() {
        let canvas = SheetCanvasView()
        var project = Workspace.newProject()
        project.pages = [SourcePage(number:1,trimSize:Size(85,55),availableBleed:0)]
        for enabled in [false,true] {
            for amount in [0.0,3.0] {
                project.settings.bleed = amount
                project.settings.generatedBleed.enabled = enabled
                let sheet = ImpositionPlanner.plan(project).sheets[0]
                canvas.configure(sheet:sheet,side:sheet.front,source:nil,overlays:PDFRenderOptions(),highlighted:[],generatedBleed:project.settings.generatedBleed,bleedAmount:amount)
                XCTAssertEqual(canvas.visibleGuideMarks.contains { $0.kind == .bleed },enabled && amount > 0)
            }
        }
    }
    func testAutomaticMissingBleedStaysEnabledAcrossModes() {
        for mode in [BindingMethod.stepAndRepeat,.saddleStitch,.perfectBound,.spiral,.wireO] {
            var project = Workspace.newProject()
            project.pages = (1...16).map { SourcePage(number:$0,trimSize:Size(85,55),availableBleed:0) }
            project.binding = mode
            let result = SmartAutoLayout.arrange(project)
            XCTAssertTrue(result.project.settings.generatedBleed.enabled,"\(mode)")
            XCTAssertEqual(result.project.settings.bleed,3)
        }
    }

    func testDisabledAmountEditorAndSharedStepperBinding() throws {
        let model = Workspace()
        model.project.settings.generatedBleed.enabled = false
        let input = DimensionInput("Taşma payı",value:Binding(get:{model.workflowBleed},set:{model.workflowBleed = $0}),range:0...30,enabled:model.editableGeneratedBleed.enabled)
        XCTAssertFalse(input.enabled)
        input.value = 3.5
        XCTAssertTrue(model.editableGeneratedBleed.enabled)
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/InspectorControls.swift"),encoding:.utf8)
        XCTAssertTrue(code.contains(".disabled(!enabled).opacity(enabled ? 1 : 0.45)"))
    }
    func testIndependentCoversInheritDefaultAndExplicitOffSurvivesModeChanges() {
        let model = Workspace()
        model.project.pages = (1...20).map { SourcePage(number:$0,trimSize:Size(85,55),availableBleed:0) }
        for mode in [BindingMethod.saddleStitch,.perfectBound] {
            model.setMode(mode)
            model.project.book = BookSettings()
            model.project.book?.coverSourceID = UUID()
            model.project.book?.coverPDFPages = [1,2,3,4]
            model.project.book?.auxiliaryPages = [1,2,3,4]
            model.project.book?.interiorPaper.microns = 100
            model.project.book?.coverPaper.microns = 200
            model.project.coverMode = .separate
            let plan = ImpositionPlanner.plan(model.project)
            XCTAssertTrue(plan.generatedBleed.enabled)
            XCTAssertTrue(plan.sheets.contains { $0.bookInfo?.section == .cover })
        }
        model.project.settings.generatedBleed.enabled = false
        model.setMode(.saddleStitch)
        XCTAssertFalse(model.project.settings.generatedBleed.enabled)
    }

    func testGangGuideUsesJobToggleAndAmount() {
        let canvas = SheetCanvasView()
        var project = Workspace.newProject()
        project.binding = .gang
        project.gang = GangSettings()
        let page = SourcePage(number:1,trimSize:Size(85,55),availableBleed:0)
        for enabled in [false,true] {
            for amount in [0.0,3.0] {
                var job = GangJob(sourceID:UUID(),name:"Kart",front:page)
                job.quantity = 1; job.bleed = amount; job.generatedBleed.enabled = enabled
                project.gang?.jobs = [job]
                let sheet = ImpositionPlanner.plan(project).sheets[0]
                canvas.configure(sheet:sheet,side:sheet.front,source:nil,overlays:PDFRenderOptions(),highlighted:[],generatedBleed:project.settings.generatedBleed)
                XCTAssertEqual(canvas.visibleGuideMarks.contains { $0.kind == .bleed },enabled && amount > 0)
            }
        }
    }

}
