import XCTest
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class AutoLayoutWorkspaceTests: XCTestCase {
    private func workspace() -> Workspace {
        Workspace(bookmarkCreator: { try $0.bookmarkData(options: .minimalBookmark,includingResourceValuesForKeys: nil,relativeTo: nil) })
    }
    private func fixture(_ width: Double = 85,_ height: Double = 55) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var media = CGRect(x: 0,y: 0,width: width*72/25.4,height: height*72/25.4)
        let cg = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        for _ in 0..<2 {
            cg.beginPDFPage(nil); cg.setFillColor(CGColor(gray: 0.8,alpha: 1)); cg.fill(media); cg.endPDFPage()
        }
        cg.closePDF()
        return url
    }
    private func settle(_ model: Workspace) async throws {
        for _ in 0..<1000 {
            if !model.loading && !model.planning && !model.autoArranging && !model.samplingBleed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Automatic layout did not settle")
    }
    func testImportPicksA4FullSheetAndSourcePreviewStaysUsable() async throws {
        let model = workspace(), url = try fixture(210,297)
        model.open(url)
        try await settle(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.sheetPreset,Workspace.automaticSheetTitle)
        XCTAssertEqual(model.project.sheet.margins,Insets())
        XCTAssertEqual(model.currentSheet?.repeatLayout?.copiesPerSheet,1)
        XCTAssertEqual(model.project.autoLayout?.level,.fullSheet)
        XCTAssertEqual(model.autoLabel("Sol",.marginLeft),"Sol · Otomatik")
        XCTAssertTrue(model.canExportNow)
    }
    func testManualEditSurvivesReimportAndExplicitAutoClearsOverrides() async throws {
        let model = workspace()
        model.project.sheet.size = SheetPreset.cm33x48.size
        model.sheetPreset = "33×48"
        model.markManual(.sheetSize)
        model.open(try fixture(),confirmChanges: false)
        try await settle(model)
        XCTAssertEqual(model.project.autoLayout?.level,.full)
        XCTAssertEqual(model.sheetPreset,"33×48")
        model.project.sheet.margins.left = 17
        XCTAssertTrue(model.project.autoLayout?.manualFields.contains(.marginLeft) == true)
        XCTAssertEqual(model.autoLabel("Sol",.marginLeft),"Sol · Manuel")
        model.open(try fixture(90,60),confirmChanges: false)
        try await settle(model)
        XCTAssertEqual(model.project.sheet.margins.left,17)
        XCTAssertEqual(model.project.sheet.size,SheetPreset.cm33x48.size)
        model.autoArrange()
        try await settle(model)
        XCTAssertEqual(model.project.sheet.margins.left,10)
        XCTAssertTrue(model.project.autoLayout?.manualFields.isEmpty == true)
        XCTAssertEqual(model.project.sheet.size,SheetPreset.sra3.size)
        XCTAssertTrue(model.project.autoLayout?.summary?.contains("adet/tabaka") == true)
    }
    func testAutomaticChoicesProductionAndManualFlagsRoundtripWithoutRearranging() async throws {
        let model = workspace()
        model.open(try fixture(),confirmChanges: false)
        try await settle(model)
        model.project.sheet.margins.right = 19
        model.setProduction(.offset)
        try await settle(model)
        XCTAssertEqual(model.project.sheet.gripperWidth,10)
        XCTAssertEqual(model.project.sheet.margins.right,19)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".atispress")
        defer { try? FileManager.default.removeItem(at: url) }
        try model.saveProject(as: url)
        let restored = workspace()
        try await restored.loadProject(at: url)
        try await settle(restored)
        XCTAssertEqual(restored.project,model.project)
        XCTAssertEqual(restored.plan.sheets,model.plan.sheets)
        XCTAssertEqual(restored.project.autoLayout?.production,.offset)
        XCTAssertTrue(restored.project.autoLayout?.manualFields.contains(.marginRight) == true)
        XCTAssertFalse(restored.isModified)
        let file = try ProjectDocument.decode(Data(contentsOf: url))
        XCTAssertEqual(file.version,ProjectDocument.currentVersion)
    }
    func testVersionTwoWithoutAutoMetadataRetainsGeometry() throws {
        let model = workspace()
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectDocument(state: model.state).encoded()) as? [String:Any])
        data["version"] = 2
        var state = try XCTUnwrap(data["state"] as? [String:Any])
        var project = try XCTUnwrap(state["project"] as? [String:Any])
        project.removeValue(forKey: "autoLayout"); state["project"] = project; data["state"] = state
        let decoded = try ProjectDocument.decode(JSONSerialization.data(withJSONObject: data))
        XCTAssertNil(decoded.state.project.autoLayout)
        XCTAssertEqual(decoded.state.project.sheet,model.project.sheet)
    }
    func testFitFailureKeepsSourceAndShowsRedOutlineOutsidePaper() async throws {
        let model = workspace()
        model.open(try fixture(210,297))
        try await settle(model)
        model.project.sheet.size = SheetPreset.a5.size
        try await settle(model)
        XCTAssertFalse(model.canExportNow)
        XCTAssertNotNil(model.source)
        XCTAssertTrue(model.plan.sheets.isEmpty)
        let sheet = try XCTUnwrap(model.currentSheet)
        let outline = try XCTUnwrap(sheet.diagnosticBounds)
        XCTAssertTrue(model.highlightedSlots.contains(0))
        let canvas = SheetCanvasView()
        canvas.configure(sheet: sheet,side: sheet.front,source: nil,overlays: .artworkOnly,highlighted: [0])
        XCTAssertGreaterThan(canvas.frame.width,sheet.size.width*PDFPreviewDrawing.pointsPerMM+64)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: Int(ceil(canvas.frame.width)),pixelsHigh: Int(ceil(canvas.frame.height)),
            bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let x = Int((outline.origin.x+outline.size.width)*PDFPreviewDrawing.pointsPerMM+32)
        let y = Int((outline.origin.y+outline.size.height/2)*PDFPreviewDrawing.pointsPerMM+32)
        let color = try XCTUnwrap(rep.colorAt(x: x,y: rep.pixelsHigh-1-y)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent,0.65)
        XCTAssertLessThan(color.greenComponent,0.55)
    }
}
