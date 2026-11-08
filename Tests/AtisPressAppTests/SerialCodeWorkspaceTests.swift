import XCTest
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class SerialCodeWorkspaceTests: XCTestCase {
    private func model() -> Workspace {
        Workspace(bookmarkCreator: { try $0.bookmarkData(options: .minimalBookmark,includingResourceValuesForKeys: nil,relativeTo: nil) })
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func source(_ folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("forms.pdf")
        var media = CGRect(x: 0,y: 0,width: 85*72/25.4,height: 55*72/25.4)
        let cg = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        cg.beginPDFPage(nil); cg.setFillColor(CGColor(gray: 0.8,alpha: 1)); cg.fill(media); cg.endPDFPage(); cg.closePDF()
        return url
    }
    private func settle(_ model: Workspace) async throws {
        for _ in 0..<500 {
            if !model.loading && !model.planning && !model.autoArranging && !model.samplingBleed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Code workspace did not settle")
    }
    func testSchemaEightRestoresEveryCodeSettingAndOldFieldsRemainText() async throws {
        let folder = try folder(),workspace = model()
        workspace.open(try source(folder)); try await settle(workspace)
        workspace.project.stepAndRepeat.columns = 2; workspace.project.stepAndRepeat.rows = 2
        workspace.project.stepAndRepeat.quantity = 100_000
        var qr = SerialField(prefix: "Q-",suffix: "-A",font: "Menlo-Regular",rotation: 90,sides: .both,position: Point(8,35),mode: .stack)
        qr.kind = .qr; qr.codeSettings.template = "https://site.com/k/{no}"
        qr.codeSettings.width = 27; qr.codeSettings.height = 18; qr.codeSettings.correction = .h
        qr.codeSettings.quietZone = 6; qr.codeSettings.humanReadable = true; qr.codeSettings.humanFontSize = 7
        qr.color = .cmyk(0.1,0.2,0,0.9)
        var barcode = SerialField(jobIndex: 0,prefix: "B-",rotation: 180,position: Point(60,35))
        barcode.kind = .code128; barcode.codeSettings.width = 50; barcode.codeSettings.height = 12
        barcode.codeSettings.quietZone = 12; barcode.codeSettings.template = "{no}"
        workspace.project.serialFields = [qr,barcode,SerialField(prefix: "TEXT-")]
        try await settle(workspace)
        let url = folder.appendingPathComponent("codes.atispress")
        try workspace.saveProject(as: url)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf: url)).version,ProjectDocument.currentVersion)
        let restored = model(); try await restored.loadProject(at: url); try await settle(restored)
        XCTAssertEqual(restored.project,workspace.project)
        XCTAssertEqual(restored.plan.sheets,workspace.plan.sheets)
        XCTAssertEqual(restored.serialCodeWarnings,workspace.serialCodeWarnings)
        XCTAssertFalse(restored.isModified)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String:Any])
        document["version"] = 7
        var state = try XCTUnwrap(document["state"] as? [String:Any]),project = try XCTUnwrap(state["project"] as? [String:Any])
        var fields = try XCTUnwrap(project["serialFields"] as? [[String:Any]])
        for index in fields.indices { fields[index].removeValue(forKey: "code") }
        project["serialFields"] = fields; state["project"] = project; document["state"] = state
        let oldURL = folder.appendingPathComponent("legacy.atispress")
        try JSONSerialization.data(withJSONObject: document).write(to: oldURL)
        let legacy = model(); try await legacy.loadProject(at: oldURL); try await settle(legacy)
        XCTAssertTrue(legacy.project.serialFields.allSatisfy { $0.kind == .text && $0.code == nil })
        XCTAssertFalse(legacy.isModified)
    }
    func testLiveCodeEditsWarningsAndDuplicationPreserveLayout() async throws {
        let folder = try folder(),workspace = model()
        workspace.open(try source(folder)); try await settle(workspace)
        let id = workspace.addSerialField(),slots = workspace.currentSide?.slots
        workspace.project.serialFields[0].kind = .qr
        workspace.project.serialFields[0].codeSettings.width = 3
        XCTAssertFalse(workspace.planning)
        XCTAssertEqual(workspace.currentSide?.slots,slots)
        XCTAssertTrue(workspace.serialCodeWarnings.contains { $0.contains("0.33") })
        workspace.project.serialFields[0].position = Point(84,54)
        XCTAssertTrue(workspace.serialCodeWarnings.contains { $0.contains("kesim dışına") })
        workspace.duplicateSerialField(id)
        XCTAssertEqual(workspace.project.serialFields[1].code,workspace.project.serialFields[0].code)
        XCTAssertNotEqual(workspace.project.serialFields[1].id,id)
        XCTAssertEqual(workspace.currentSide?.slots,slots)
    }
    func testQRAndBarcodeHitTestingUseRotatedCodeBoundsAndSnapLikeText() throws {
        for kind in [SerialCodeSettings.Kind.qr,.code128] {
            var field = SerialField(rotation: 90,position: Point(10,35)); field.kind = kind
            field.codeSettings.width = 20; field.codeSettings.height = 12
            let slot = Slot(sourcePageNumber: 1,origin: Point(10,15),size: Size(55,85),rotation: 90,copyIndex: 0)
            var sheet = Sheet(size: Size(110,130),front: Side(slots: [slot]),back: Side())
            sheet.serialPlan = SerialNumberPlan(fields: [field],quantity: 1,capacity: 1,sheetCount: 1)
            let canvas = SheetCanvasView(); canvas.configure(sheet: sheet,side: sheet.front,source: nil,overlays: .artworkOnly,highlighted: [])
            var selected: UUID?,moved: Point?
            canvas.selectSerial = { selected = $0 }; canvas.moveSerial = { _,point in moved = point }
            let serial = SerialPlacement(field: field,slotIndex: 0,index: 0,text: "0001")
            let down = CGPoint(x: 3,y: 3).applying(PDFSerialDrawing.transform(serial))
            func event(_ type: NSEvent.EventType,_ point: CGPoint) throws -> NSEvent {
                let p = point.applying(PDFPreviewDrawing.slotTransform(slot))
                return try XCTUnwrap(NSEvent.mouseEvent(with: type,location: CGPoint(x: 32+p.x*72/25.4,y: 32+p.y*72/25.4),modifierFlags: [],
                    timestamp: 0,windowNumber: 0,context: nil,eventNumber: 1,clickCount: 1,pressure: 1))
            }
            canvas.mouseDown(with: try event(.leftMouseDown,down))
            XCTAssertEqual(selected,field.id)
            canvas.mouseDragged(with: try event(.leftMouseDragged,CGPoint(x: down.x+4.4,y: down.y-3.6)))
            XCTAssertEqual(moved,Point(14,31))
            canvas.mouseUp(with: try event(.leftMouseUp,down))
        }
    }
}
