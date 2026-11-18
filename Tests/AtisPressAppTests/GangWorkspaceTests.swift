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
    private func pdf(_ folder: URL,_ name: String,_ size: Size,pages: Int = 1, distinctPages: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var rect = CGRect(x:0,y:0,width:size.width*72/25.4,height:size.height*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&rect,nil))
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: distinctPages ? CGFloat(page) / CGFloat(pages) : 0.75, alpha: 1))
            context.fill(rect)
            context.endPDFPage()
        }
        context.closePDF(); return url
    }
    private func settle(_ model: Workspace) async throws {
        for _ in 0..<1000 {
            if !model.loading && !model.planning && !model.autoArranging && !model.samplingBleed && !model.preparingColorPreview { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Gang workspace did not settle")
    }
    func testTeamImportPairPlacementProjectRoundTripAndVectorExport() async throws {
        let directory = try folder()
        let input = try pdf(directory, "team.pdf", Size(55, 35), pages: 13, distinctPages: true)
        let workspace = model()
        workspace.open(input)
        try await settle(workspace)
        XCTAssertTrue(workspace.showingTeamImportChoice)
        XCTAssertEqual(workspace.project.binding, .stepAndRepeat)
        XCTAssertNil(workspace.project.team)
        workspace.startTeam()
        workspace.project.sheet.size = Size(160, 135)
        workspace.project.sheet.orientation = .portrait
        workspace.basicQuantity = 3
        workspace.setTeamDuplex(true)
        let first = try XCTUnwrap(workspace.project.gang?.jobs.first)
        workspace.swapTeamPage(jobID: first.id, side: .back, with: 4)
        XCTAssertEqual(workspace.project.gang?.jobs.first?.back?.number, 4)
        XCTAssertEqual(workspace.project.gang?.jobs.dropFirst().first?.back?.number, 2)
        try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport, "\(workspace.plan.issues)")
        XCTAssertGreaterThan(workspace.plan.sheets.count, 1)
        workspace.manualGang()
        try await settle(workspace)
        let last = try XCTUnwrap(workspace.project.gang?.jobs.last)
        workspace.swapTeamPlacements(first.id, last.id)
        try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport, "\(workspace.plan.issues)")
        XCTAssertTrue(workspace.plan.sheets[0].front.slots.contains { $0.sourcePageNumber == last.front.number })
        let saved = directory.appendingPathComponent("team.atispress")
        try workspace.saveProject(as: saved)
        let document = try ProjectDocument.decode(Data(contentsOf: saved))
        XCTAssertEqual(document.version, ProjectDocument.currentVersion)
        XCTAssertEqual(document.state.gangSources?.count, 1)
        XCTAssertNotNil(document.state.project.team?.manualLayouts)
        let opened = model()
        try await opened.loadProject(at: saved)
        try await settle(opened)
        XCTAssertEqual(opened.project, workspace.project)
        XCTAssertEqual(opened.plan.sheets, workspace.plan.sheets)
        XCTAssertEqual(opened.plan.teamSummary, workspace.plan.teamSummary)
        let source = try XCTUnwrap(opened.source)
        let plan = opened.plan
        let output = directory.appendingPathComponent("imposed.pdf")
        let export = try await Task.detached {
            try PDFExporter.export(plan: plan, source: source, destination: .singlePDF(output), marks: .none)
        }.value
        XCTAssertEqual(export.sheetCount, plan.totalPressSheets)
        XCTAssertEqual(export.pageCount, 2 * plan.totalPressSheets)
        let rendered = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(rendered.numberOfPages, export.pageCount)
        let verification = try await Task.detached {
            try ExportVerification.check(files: export.files, plan: plan, source: source,
                                         marks: .none, includeBlankBacks: true)
        }.value
        XCTAssertTrue(verification.passed, "\(verification.differences)")
    }

    func testVersion21ClassicProjectOpensWithIdenticalPlan() async throws {
        let directory = try folder()
        let input = try pdf(directory, "classic.pdf", Size(55, 35), pages: 2)
        let workspace = model()
        workspace.open(input)
        try await settle(workspace)
        let saved = directory.appendingPathComponent("classic.atispress")
        try workspace.saveProject(as: saved)
        var legacy = try ProjectDocument.decode(Data(contentsOf: saved))
        legacy.version = 21
        try legacy.encoded().write(to: saved)
        let opened = model()
        try await opened.loadProject(at: saved)
        try await settle(opened)
        XCTAssertEqual(opened.project, workspace.project)
        XCTAssertEqual(opened.plan.sheets, workspace.plan.sheets)
        XCTAssertEqual(opened.plan.teamSummary, workspace.plan.teamSummary)
        XCTAssertNil(opened.project.team)
    }

    func testInternalCutSettingsRoundTripAndVersion22Defaults() async throws {
        let directory = try folder()
        let input = try pdf(directory, "cuts.pdf", Size(150, 50), pages: 2)
        let workspace = model()
        workspace.open(input)
        try await settle(workspace)
        let url = directory.appendingPathComponent("cuts.atispress")
        try workspace.saveProject(as: url)
        var legacy = try ProjectDocument.decode(Data(contentsOf: url))
        legacy.version = 22
        try legacy.encoded().write(to: url)
        let reopened = model()
        try await reopened.loadProject(at: url)
        try await settle(reopened)
        XCTAssertNil(reopened.project.internalCutJobs)
        XCTAssertEqual(reopened.plan.sheets, workspace.plan.sheets)
        var cuts = InternalCutMarks()
        cuts.horizontal.enabled = true
        cuts.vertical.enabled = true
        cuts.vertical.position = .custom
        cuts.vertical.offsets = [50, 100]
        workspace.project.internalCutJobs = [1: cuts]
        workspace.startTeam()
        XCTAssertEqual(workspace.project.gang?.jobs.first?.internalCuts, cuts)
        XCTAssertNil(workspace.project.gang?.jobs.last?.internalCuts)
        try await settle(workspace)
        try workspace.saveProject(as: url)
        try await reopened.loadProject(at: url)
        try await settle(reopened)
        XCTAssertEqual(reopened.project, workspace.project)
        XCTAssertEqual(reopened.plan.sheets, workspace.plan.sheets)
        XCTAssertTrue(reopened.plan.sheets.flatMap { $0.front.marks }.contains { $0.kind == .internalCut })
    }

    func testLiveImageColorPreviewSaveOpenAndLegacyDefaults() async throws {
        let directory = try folder()
        let input = directory.appendingPathComponent("images.pdf")
        let data = Data([80, 40, 20, 120, 80, 50, 50, 100, 140, 200, 140, 100])
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 24,
                                          bytesPerRow: 6, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        var box = CGRect(x: 0, y: 0, width: 120, height: 75)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: input as CFURL)), mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()

        let workspace = model()
        workspace.open(input)
        try await settle(workspace)
        let saved = directory.appendingPathComponent("color.atispress")
        try workspace.saveProject(as: saved)
        var legacy = try ProjectDocument.decode(Data(contentsOf: saved))
        legacy.version = 24
        try legacy.encoded().write(to: saved)
        let reopened = model()
        try await reopened.loadProject(at: saved)
        try await settle(reopened)
        XCTAssertNil(reopened.project.imageColorJobs)
        XCTAssertEqual(reopened.plan.sheets, workspace.plan.sheets)

        var adjustment = ImageColorAdjustment()
        adjustment.brightness = 0.16
        workspace.project.imageColorJobs = [1: adjustment]
        try await settle(workspace)
        let slot = try XCTUnwrap(workspace.plan.sheets.first?.front.slots.first)
        XCTAssertEqual(slot.imageColor, adjustment)
        XCTAssertNotNil(workspace.previewColors?.page(for: slot), "\(workspace.colorVariants?.warnings ?? [])")
        workspace.previewOriginalColors = true
        XCTAssertNil(workspace.previewColors)
        XCTAssertNotNil(workspace.colorVariants?.page(for: slot))
        try workspace.saveProject(as: saved)
        try await reopened.loadProject(at: saved)
        try await settle(reopened)
        XCTAssertEqual(reopened.project.imageColorJobs, [1: adjustment])
        XCTAssertEqual(reopened.plan.sheets, workspace.plan.sheets)
        XCTAssertNotNil(reopened.previewColors?.page(for: slot))
        var selected = ImageColorAdjustment()
        selected.cmykProfileID = String(repeating: "a", count: 64)
        workspace.project.imageColorJobs = [1: selected]
        try await settle(workspace)
        try workspace.saveProject(as: saved)
        try await reopened.loadProject(at: saved)
        try await settle(reopened)
        XCTAssertEqual(reopened.project.imageColorJobs, [1: selected])
        XCTAssertEqual(reopened.plan.sheets.first?.front.slots.first?.imageColor, selected)
        reopened.project.imageColorJobs = nil
        try await settle(reopened)
        XCTAssertNil(reopened.previewColors)
        XCTAssertNil(reopened.plan.sheets.first?.front.slots.first?.imageColor)
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
        let file = try ProjectDocument.decode(Data(contentsOf:url)); XCTAssertEqual(file.version,ProjectDocument.currentVersion); XCTAssertNil(file.state.source); XCTAssertEqual(file.state.gangSources?.count,2)
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
