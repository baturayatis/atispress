import XCTest
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class ProductionWorkspaceTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func model() -> Workspace {
        Workspace(bookmarkCreator: { try $0.bookmarkData(options: .minimalBookmark,includingResourceValuesForKeys: nil,relativeTo: nil) })
    }
    private func fixture(_ folder: URL,count: Int = 3) throws -> URL {
        let url = folder.appendingPathComponent("forms.pdf")
        var media = CGRect(x: 0,y: 0,width: 20*72/25.4,height: 30*72/25.4)
        let cg = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        for _ in 0..<count {
            cg.beginPDFPage(nil)
            cg.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),components: [1,0,0,1])!)
            cg.fill(media); cg.endPDFPage()
        }
        cg.closePDF(); return url
    }
    private func settle(_ model: Workspace) async throws {
        for _ in 0..<500 {
            if !model.loading && !model.planning && !model.autoArranging && !model.samplingBleed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Workspace did not settle")
    }
    func testDefaultsAutomaticSidesJobOverrideAndSerialAnchor() async throws {
        let workspace = model(), folder = try folder()
        XCTAssertEqual(workspace.pageLayoutMode,.automatic)
        XCTAssertEqual(workspace.project.stepAndRepeat.waste?.percent,0)
        XCTAssertEqual(workspace.project.stepAndRepeat.waste?.numberCopies,false)
        workspace.open(try fixture(folder))
        try await settle(workspace)
        XCTAssertEqual(workspace.project.resolvedPageLayout,.simplex)
        XCTAssertEqual(workspace.plan.sheets.count,3)
        XCTAssertTrue(workspace.pageLayoutSummary.contains("Otomatik"))
        workspace.sheetIndex = 2
        let id = workspace.addSerialField()
        workspace.setJobPageLayout(frontPage: 1,mode: .duplex)
        try await settle(workspace)
        XCTAssertEqual(workspace.plan.sheets.count,2)
        let field = try XCTUnwrap(workspace.project.serialFields.first { $0.id == id })
        XCTAssertEqual(field.jobIndex,1,"Serial field follows source front page 3 after regrouping")
        workspace.setJobPageLayout(frontPage: 1,mode: .simplex)
        try await settle(workspace)
        XCTAssertEqual(workspace.plan.sheets.count,3)
        XCTAssertEqual(workspace.project.serialFields[0].jobIndex,2)
    }
    func testSplittingAndJoiningDuplexPreservesSerialsOnTheirSourceFaces() async throws {
        let workspace = model(), folder = try folder()
        workspace.open(try fixture(folder,count: 4))
        try await settle(workspace)
        let id = workspace.addSerialField()
        workspace.project.serialFields[0].sides = .both
        workspace.setJobPageLayout(frontPage: 1,mode: .simplex)
        try await settle(workspace)
        XCTAssertEqual(workspace.project.serialFields.count,2)
        XCTAssertEqual(workspace.project.serialFields.map(\.jobIndex),[0,1])
        XCTAssertTrue(workspace.project.serialFields.allSatisfy { $0.sides == .front })
        XCTAssertEqual(workspace.project.serialFields[0].id,id)
        workspace.setJobPageLayout(frontPage: 1,mode: .duplex)
        try await settle(workspace)
        XCTAssertEqual(workspace.project.serialFields.map(\.jobIndex),[0,0])
        XCTAssertEqual(workspace.project.serialFields.map(\.sides),[.front,.back])
        let sheet = try XCTUnwrap(workspace.plan.sheets.first)
        XCTAssertEqual(sheet.serialPlan?.placements(side: sheet.front,kind: .front,repetition: 0).count,sheet.front.slots.count)
        XCTAssertEqual(sheet.serialPlan?.placements(side: sheet.back,kind: .back,repetition: 0).count,sheet.back.slots.count)
    }
    func testWasteUpdatesCountsDigitWidthAndInformationSummaryWithoutPreviewRepack() async throws {
        let workspace = model(), folder = try folder()
        workspace.open(try fixture(folder,count: 2))
        try await settle(workspace)
        workspace.project.stepAndRepeat.columns = 2; workspace.project.stepAndRepeat.rows = 2
        workspace.project.stepAndRepeat.quantity = 9999
        workspace.addSerialField()
        var waste = WasteSettings(); waste.mode = .fixed; waste.fixed = 6; waste.numberCopies = true
        workspace.project.stepAndRepeat.waste = waste
        try await settle(workspace)
        XCTAssertEqual(workspace.currentSheet?.repeatCount,2502)
        XCTAssertEqual(workspace.serialNumberedQuantity(job: 0),10005)
        XCTAssertEqual(workspace.project.serialFields[0].digits,5)
        XCTAssertTrue(workspace.currentSheet?.productionSummary?.contains("Adet 9999 + fire 6 = 10005 üretim, 2502 tabaka") == true)
        XCTAssertEqual(workspace.serialSheetCount(job: 0),2502)
        let slots = workspace.currentSheet?.front.slots
        workspace.infoJobName = "Özel iş"
        workspace.sheetInfoBinding(\.date).wrappedValue = false
        XCTAssertFalse(workspace.planning)
        XCTAssertEqual(workspace.currentSheet?.front.slots,slots)
        XCTAssertTrue(workspace.sheetInfoText(sheet: workspace.currentSheet!).contains("Özel iş"))
    }
    func testPreflightGroupsPagesReactsToProductionAndSuppressesGeneratedBleedWarning() async throws {
        let workspace = model(), folder = try folder()
        workspace.open(try fixture(folder,count: 2))
        try await settle(workspace)
        let rgb = try XCTUnwrap(workspace.preflightRows.first { $0.id.contains("rgb") })
        XCTAssertEqual(rgb.pages,[1,2]); XCTAssertEqual(rgb.severity,.notice)
        XCTAssertFalse(workspace.preflightRows.contains { $0.id.contains("bleed") })
        workspace.setProduction(.offset)
        try await settle(workspace)
        XCTAssertEqual(workspace.preflightRows.first { $0.id.contains("rgb") }?.severity,.warning)
        workspace.project.settings.generatedBleed.enabled = false
        try await settle(workspace)
        let bleed = try XCTUnwrap(workspace.preflightRows.first { $0.id.contains("bleed") })
        XCTAssertEqual(bleed.pages,[1,2])
        XCTAssertTrue(workspace.canExportNow)
    }
    func testAllProductionSettingsRoundtripAndVersionFiveMigrationKeepsLegacyPairs() async throws {
        let folder = try folder(), source = try fixture(folder)
        let workspace = model(); workspace.open(source)
        try await settle(workspace)
        workspace.setPageLayout(.simplex)
        workspace.setJobPageLayout(frontPage: 2,mode: .duplex)
        workspace.project.stepAndRepeat.quantity = 11
        var waste = WasteSettings(); waste.mode = .percent; waste.percent = 12.5; waste.fixed = 7; waste.numberCopies = true
        workspace.project.stepAndRepeat.waste = waste
        var info = SheetInfoSettings(); info.jobName = "Kalıcı iş"; info.date = false; info.sheetSize = false; info.showJobName = false
        info.sheetNumber = false; info.side = false; info.production = false
        workspace.project.sheetInfo = info; workspace.project.exportMarks.sheetInfo = true
        workspace.addSerialField()
        try await settle(workspace)
        let url = folder.appendingPathComponent("all.atispress")
        try workspace.saveProject(as: url)
        let decoded = try ProjectDocument.decode(Data(contentsOf: url))
        XCTAssertEqual(decoded.version,6)
        let restored = model(); try await restored.loadProject(at: url); try await settle(restored)
        XCTAssertEqual(restored.project,workspace.project)
        XCTAssertEqual(restored.plan.sheets,workspace.plan.sheets)
        XCTAssertEqual(restored.source?.preflight,workspace.source?.preflight)
        XCTAssertFalse(restored.isModified)
        // A version-5 project has the former consecutive-pair contract, even with an odd page count.
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String:Any])
        document["version"] = 5
        var state = try XCTUnwrap(document["state"] as? [String:Any]),project = try XCTUnwrap(state["project"] as? [String:Any])
        var repeatSettings = try XCTUnwrap(project["stepAndRepeat"] as? [String:Any])
        repeatSettings.removeValue(forKey: "waste"); repeatSettings.removeValue(forKey: "pageLayout")
        project["stepAndRepeat"] = repeatSettings; project.removeValue(forKey: "sheetInfo")
        state["project"] = project; document["state"] = state
        let legacyURL = folder.appendingPathComponent("legacy.atispress")
        try JSONSerialization.data(withJSONObject: document).write(to: legacyURL)
        let legacy = model(); try await legacy.loadProject(at: legacyURL); try await settle(legacy)
        XCTAssertNil(legacy.project.stepAndRepeat.waste); XCTAssertNil(legacy.project.sheetInfo)
        XCTAssertEqual(legacy.project.resolvedPageLayout,.duplex)
        XCTAssertEqual(legacy.project.repeatJobs.count,2)
        XCTAssertFalse(legacy.isModified)
    }
}
