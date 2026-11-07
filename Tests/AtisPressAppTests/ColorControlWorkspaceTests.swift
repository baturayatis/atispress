import XCTest
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class ColorControlWorkspaceTests: XCTestCase {
    private func model() -> Workspace {
        Workspace(bookmarkCreator: { try $0.bookmarkData(options: .minimalBookmark,includingResourceValuesForKeys: nil,relativeTo: nil) })
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func fixture(_ folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("cards.pdf")
        var media = CGRect(x: 0,y: 0,width: 85*72/25.4,height: 55*72/25.4)
        let cg = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        for _ in 0..<2 { cg.beginPDFPage(nil); cg.setFillColor(CGColor(gray: 0.8,alpha: 1)); cg.fill(media); cg.endPDFPage() }
        cg.closePDF(); return url
    }
    private func settle(_ workspace: Workspace) async throws {
        for _ in 0..<500 {
            if !workspace.loading && !workspace.planning && !workspace.autoArranging && !workspace.samplingBleed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Color settings did not settle")
    }
    func testProductionDefaultsManualChoicesAndPreviewExportIndependence() async throws {
        let workspace = model()
        XCTAssertFalse(workspace.project.exportMarks.colorBar); XCTAssertFalse(workspace.project.exportMarks.registrationTargets)
        XCTAssertEqual(workspace.project.exportMarks.targetSize,5); XCTAssertEqual(workspace.project.exportMarks.patchSize,5)
        workspace.setPreviewColorBar(false)
        workspace.setProduction(.offset)
        XCTAssertTrue(workspace.project.exportMarks.colorBar); XCTAssertTrue(workspace.project.exportMarks.registrationTargets)
        XCTAssertFalse(workspace.overlays.colorBar); XCTAssertTrue(workspace.overlays.registrationTargets)
        XCTAssertEqual(workspace.autoLabel("Renk skalası",.exportColorBar),"Renk skalası · Otomatik")
        workspace.project.exportMarks.colorBar = false
        workspace.setProduction(.digital); workspace.setProduction(.offset)
        XCTAssertFalse(workspace.project.exportMarks.colorBar,"Manual export OFF survives production changes")
        XCTAssertTrue(workspace.project.exportMarks.registrationTargets)
        let saved = workspace.project.exportMarks
        workspace.setPreviewTargets(false); workspace.setPreviewColorBar(true)
        XCTAssertEqual(workspace.project.exportMarks,saved)
        var p = Project(pages: [SourcePage(number: 1,trimSize: Size(85,55))],sheet: SheetSpec(preset: .cm33x48))
        p.autoLayout = AutoLayoutSettings(); p.autoLayout?.production = .offset
        let automatic = SmartAutoLayout.arrange(p)
        XCTAssertTrue(automatic.project.exportMarks.colorBar); XCTAssertTrue(automatic.project.exportMarks.registrationTargets)
        let folder = try folder(); workspace.open(try fixture(folder),confirmChanges: false)
        try await settle(workspace)
        let slots = workspace.currentSide?.slots
        workspace.project.exportMarks.targetSize = 8; workspace.project.exportMarks.patchSize = 4
        XCTAssertFalse(workspace.planning)
        XCTAssertEqual(workspace.currentSide?.slots,slots)
    }
    func testSchemaSevenRoundtripAndVersionSixKeepsControlsOff() async throws {
        let folder = try folder(),workspace = model()
        workspace.open(try fixture(folder)); try await settle(workspace)
        workspace.setProduction(.offset); try await settle(workspace)
        workspace.project.sheet.gripperEdge = .left
        workspace.project.exportMarks.colorBar = true; workspace.project.exportMarks.registrationTargets = false
        workspace.project.exportMarks.targetSize = 9; workspace.project.exportMarks.patchSize = 4
        workspace.project.exportMarks.barSide = .opposite
        workspace.setPreviewColorBar(false); workspace.setPreviewTargets(true)
        try await settle(workspace)
        let url = folder.appendingPathComponent("controls.atispress")
        try workspace.saveProject(as: url)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf: url)).version,ProjectDocument.currentVersion)
        let restored = model(); try await restored.loadProject(at: url); try await settle(restored)
        XCTAssertEqual(restored.project,workspace.project)
        XCTAssertEqual(restored.overlays,workspace.overlays)
        XCTAssertEqual(restored.plan.sheets,workspace.plan.sheets)
        XCTAssertEqual(restored.currentSheet?.gripperEdge,.left)
        XCTAssertFalse(restored.isModified)
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String:Any])
        file["version"] = 6
        var state = try XCTUnwrap(file["state"] as? [String:Any]),project = try XCTUnwrap(state["project"] as? [String:Any])
        var marks = try XCTUnwrap(project["exportMarks"] as? [String:Any]),overlays = try XCTUnwrap(state["overlays"] as? [String:Any])
        marks.removeValue(forKey: "colorControls"); project["exportMarks"] = marks
        for key in ["colorBarVisible","targetsVisible","manualColorBar","manualTargets"] { overlays.removeValue(forKey: key) }
        state["project"] = project; state["overlays"] = overlays; file["state"] = state
        let legacyURL = folder.appendingPathComponent("legacy.atispress")
        try JSONSerialization.data(withJSONObject: file).write(to: legacyURL)
        let legacy = model(); try await legacy.loadProject(at: legacyURL); try await settle(legacy)
        XCTAssertFalse(legacy.project.exportMarks.colorBar); XCTAssertFalse(legacy.project.exportMarks.registrationTargets)
        XCTAssertFalse(legacy.overlays.colorBar); XCTAssertFalse(legacy.overlays.registrationTargets)
        XCTAssertFalse(legacy.isModified)
    }
    func testCanvasPreviewSwitchActuallyPaintsBarWhileExportIsOff() throws {
        let side = Side(slots: [Slot(sourcePageNumber: 1,origin: Point(30,30),size: Size(140,140))])
        let sheet = Sheet(size: Size(200,200),front: side,back: Side())
        var desired = ExportMarks.none; desired.colorBar = true
        let bar = try XCTUnwrap(PDFColorControlRenderer.geometry(sheet: sheet,settings: desired).patches.first?.bounds)
        func color(_ visible: Bool) throws -> NSColor {
            var overlays = PDFRenderOptions.artworkOnly; overlays.colorBar = visible
            let view = SheetCanvasView()
            view.configure(sheet: sheet,side: side,source: nil,overlays: overlays,highlighted: [],controlMarks: .none)
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: Int(ceil(view.frame.width)),pixelsHigh: Int(ceil(view.frame.height)),
                bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            view.draw(view.bounds); NSGraphicsContext.restoreGraphicsState()
            return try XCTUnwrap(rep.colorAt(x: Int(32+bar.midX*72/25.4),y: rep.pixelsHigh-1-Int(32+bar.midY*72/25.4))?.usingColorSpace(.deviceRGB))
        }
        XCTAssertGreaterThan(try color(false).redComponent,0.95)
        XCTAssertLessThan(try color(true).redComponent,0.8)
    }
}
