import XCTest
import AppKit
import PDFEngine
import ImpositionCore
@testable import AtisPressApp

@MainActor
final class GangWorkspaceTests: XCTestCase {
    private func model() -> Workspace {
        Workspace(bookmarkCreator: { try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil) })
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    private func pdf(_ folder: URL,_ name: String,_ size: Size,pages: Int = 1) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var rect = CGRect(x:0,y:0,width:size.width*72/25.4,height:size.height*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&rect,nil))
        for _ in 0..<pages { context.beginPDFPage(nil); context.setFillColor(CGColor(gray:0.75,alpha:1)); context.fill(rect); context.endPDFPage() }
        context.closePDF(); return url
    }
    private func settle(_ model: Workspace) async throws {
        for _ in 0..<1000 {
            if !model.loading && !model.planning && !model.autoArranging && !model.samplingBleed { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Gang workspace did not settle")
    }
    func testMultiplePDFsSettingsSerialsAndManualPlanRoundtripSchemaNine() async throws {
        let folder = try folder(),a = try pdf(folder,"cards.pdf",Size(55,35),pages:2),b = try pdf(folder,"labels.pdf",Size(30,45))
        let workspace = model(); workspace.setMode(.gang); workspace.addGangPDFs([a,b]); try await settle(workspace)
        XCTAssertEqual(workspace.project.gang?.jobs.count,2)
        XCTAssertEqual(Set(workspace.project.gang!.jobs.map(\.tint)).count,2)
        let id = try XCTUnwrap(workspace.project.gang?.jobs.first?.id)
        workspace.selectedGangJobID = id
        workspace.editGangJob(id) { job in job.name = "Kartlar"; job.quantity = 100; job.waste.mode = .fixed; job.waste.fixed = 5; job.bleed = 2; job.generatedBleed.enabled = true; job.generatedBleed.method = .solidColor; job.tint = 0.7 }
        let fieldID = workspace.addSerialField(); workspace.editableSerialFields[0].kind = .qr; workspace.editableSerialFields[0].codeSettings.template = "https://site.test/{no}"; workspace.editableSerialFields[0].mode = .stack
        workspace.duplicateSerialField(fieldID); XCTAssertEqual(workspace.editableSerialFields.count,2)
        workspace.moveSerialField(fieldID,to:Point(12.4,8.8)); XCTAssertEqual(workspace.editableSerialFields[0].position,Point(12,9))
        workspace.setSerialEnd("0200",id:fieldID); XCTAssertEqual(workspace.selectedGangJob?.quantity,200)
        try await settle(workspace)
        workspace.manualGang(); try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport,"\(workspace.plan.issues)")
        let before = workspace.plan.sheets
        let url = folder.appendingPathComponent("gang.atispress"); try workspace.saveProject(as:url)
        let file = try ProjectDocument.decode(Data(contentsOf:url)); XCTAssertEqual(file.version,9); XCTAssertNil(file.state.source); XCTAssertEqual(file.state.gangSources?.count,2)
        XCTAssertEqual(file.state.gangSources?.map(\.reference.path),[a.path,b.path]); XCTAssertFalse(String(data:try Data(contentsOf:url),encoding:.utf8)!.contains("AtisPress-gang-"))
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertEqual(opened.project,workspace.project); XCTAssertEqual(opened.plan.sheets,before); XCTAssertFalse(opened.isModified)
        XCTAssertTrue(opened.preflightRows.contains { $0.explanation.contains("Kartlar") })
        let secondName = try XCTUnwrap(opened.project.gang?.jobs.last?.name)
        XCTAssertTrue(opened.preflightRows.filter { $0.explanation.hasPrefix(secondName+":") }.allSatisfy { $0.pages == [1] },"Preflight pages belong to the original PDF, not the temporary combined page offsets")
        XCTAssertThrowsError(try workspace.saveProject(as:a))
        XCTAssertThrowsError(try workspace.saveProject(as:b))
        workspace.editGangJob(id) { $0.quantity += 1 }; XCTAssertTrue(workspace.isModified)
    }
    func testMissingLinkedPDFRelinksAtomicallyAndRejectsWrongSource() async throws {
        let folder = try folder(),a = try pdf(folder,"a.pdf",Size(55,35)),b = try pdf(folder,"b.pdf",Size(45,60))
        let workspace = model(); workspace.setMode(.gang); workspace.addGangPDFs([a,b]); try await settle(workspace)
        let url = folder.appendingPathComponent("linked.atispress"); try workspace.saveProject(as:url)
        let copy = folder.appendingPathComponent("moved.pdf"); try FileManager.default.copyItem(at:b,to:copy); try FileManager.default.removeItem(at:b)
        let opened = model(),initial = opened.project
        do { try await opened.loadProject(at:url,relink:{ _ in a }); XCTFail("Mismatched source must not load") } catch { XCTAssertEqual(opened.project,initial) }
        var requests: [String] = []
        try await opened.loadProject(at:url,relink:{ reference in requests.append(reference.fileName); return copy }); try await settle(opened)
        XCTAssertEqual(requests,["b.pdf"]); XCTAssertEqual(opened.project.gang?.jobs.count,2); XCTAssertTrue(opened.isModified)
    }
    func testExistingPDFBecomesGangAndSwitchingModesDoesNotLoseLinkedSources() async throws {
        let folder = try folder(),a = try pdf(folder,"a.pdf",Size(55,35)),workspace = model()
        workspace.open(a); try await settle(workspace)
        workspace.setMode(.gang); try await settle(workspace)
        XCTAssertEqual(workspace.project.gang?.jobs.count,1); XCTAssertEqual(workspace.gangAssets.count,1)
        workspace.selectedGangJobID = workspace.project.gang?.jobs.first?.id; _ = workspace.addSerialField()
        workspace.project.sheet.gutter = 6
        workspace.setMode(.stepAndRepeat); try await settle(workspace)
        let url = folder.appendingPathComponent("dormant.atispress"); try workspace.saveProject(as:url)
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertEqual(opened.project.binding,.stepAndRepeat); XCTAssertEqual(opened.gangAssets.count,1)
        opened.setMode(.gang); try await settle(opened); XCTAssertEqual(opened.editableSerialFields.count,1)
        XCTAssertEqual(opened.project.sheet.gutter,6)
    }
    func testDragSnapsButDoesNotFixInvalidBlockAndPreviewTintIsVisible() async throws {
        let folder = try folder(),a = try pdf(folder,"a.pdf",Size(55,35)),workspace = model()
        workspace.setMode(.gang); workspace.addGangPDFs([a]); try await settle(workspace)
        let sheet = try XCTUnwrap(workspace.currentSheet),block = try XCTUnwrap(sheet.gangLayout?.blocks.first)
        workspace.moveGangBlock(block.id,to:Point(-8.4,-4.7)); try await settle(workspace)
        XCTAssertEqual(workspace.project.gang?.mode,.manual)
        XCTAssertEqual(workspace.project.gang?.blocks.first?.origin,Point(-8,-5)); XCTAssertFalse(workspace.plan.canExport)
        XCTAssertFalse(workspace.highlightedSlots.isEmpty)
        let canvas = SheetCanvasView(); canvas.configure(sheet:workspace.currentSheet!,side:workspace.currentSheet!.front,source:workspace.source,overlays:.artworkOnly,highlighted:workspace.highlightedSlots)
        XCTAssertGreaterThan(canvas.frame.width,sheet.size.width*72/25.4+64,"Off-sheet blocks stay visible")
        func bitmap(_ sheet: Sheet) throws -> Data {
            let view = SheetCanvasView(); view.configure(sheet:sheet,side:sheet.front,source:workspace.source,overlays:.artworkOnly,highlighted:[])
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(ceil(view.frame.width)),pixelsHigh:Int(ceil(view.frame.height)),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep); view.draw(view.bounds); NSGraphicsContext.restoreGraphicsState()
            return try XCTUnwrap(rep.representation(using:.png,properties:[:]))
        }
        var recolored = sheet; recolored.gangLayout?.jobs[0].job.tint = 0.95
        XCTAssertNotEqual(try bitmap(sheet),try bitmap(recolored))
    }
    func testActualBlockHitAndDragMapsBackCoordinatesToFrontAndSnaps() throws {
        let job = GangJob(sourceID:UUID(),name:"Kart",front:SourcePage(number:1,trimSize:Size(55,35)),back:SourcePage(number:2,trimSize:Size(55,35)))
        var project = Project(pages:[job.front,job.back!],binding:.gang,sheet:SheetSpec(preset:.sra3))
        var settings = GangSettings(); settings.jobs = [job]; project.gang = settings
        let sheet = try XCTUnwrap(ImpositionPlanner.plan(project).sheets.first),slot = try XCTUnwrap(sheet.back.slots.first)
        let canvas = SheetCanvasView(); canvas.configure(sheet:sheet,side:sheet.back,source:nil,overlays:.artworkOnly,highlighted:[],kind:.back)
        var moved: Point?,movedID: UUID?
        canvas.moveGangBlock = { id,p in movedID = id; moved = p }
        let center = CGPoint(x:32+(slot.x+slot.size.width/2)*72/25.4,y:32+(slot.y+slot.size.height/2)*72/25.4)
        func event(_ type: NSEvent.EventType,_ p: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:p,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1))
        }
        canvas.mouseDown(with:try event(.leftMouseDown,center))
        canvas.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:center.x+4.4*72/25.4,y:center.y+3.6*72/25.4)))
        canvas.mouseUp(with:try event(.leftMouseUp,center))
        let block = try XCTUnwrap(sheet.gangLayout?.blocks.first)
        XCTAssertEqual(movedID,block.id)
        XCTAssertEqual(moved,Point((block.origin.x-4.4).rounded(),(block.origin.y+3.6).rounded()))
    }

}
