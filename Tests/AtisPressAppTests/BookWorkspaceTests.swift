import XCTest
import AppKit
import PDFKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class BookWorkspaceTests: XCTestCase {
    private func model() -> Workspace {
        Workspace(bookmarkCreator:{ try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil) })
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    private func fixture(_ folder: URL,_ name: String,count: Int,size: Size) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var rect = CGRect(x:0,y:0,width:size.width*72/25.4,height:size.height*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&rect,nil))
        for _ in 0..<count { context.beginPDFPage(nil); context.setFillColor(CGColor(gray:0.3,alpha:1)); context.fill(CGRect(x:rect.width*0.1,y:rect.height*0.1,width:rect.width*0.2,height:rect.height*0.7)); context.endPDFPage() }
        context.closePDF(); return url
    }
    private func settle(_ workspace: Workspace) async throws {
        for _ in 0..<1000 {
            if !workspace.loading && !workspace.planning && !workspace.autoArranging && !workspace.samplingBleed { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Book workspace did not settle")
    }
    private func prepare(_ workspace: Workspace,_ source: URL,binding: BindingMethod) async throws {
        workspace.open(source); try await settle(workspace); workspace.setMode(binding)
        workspace.enableBookSettings(); workspace.bookSettings.interiorPaper.microns = 120; workspace.bookSettings.coverPaper.microns = 250
        workspace.project.sheet = SheetSpec(preset:.cm50x70)
        workspace.project.settings.signatureSize = .eight
        try await settle(workspace)
    }
    func testSchemaTenRoundtripEveryBookSettingAndSharedPlan() async throws {
        let folder = try folder(),pdf = try fixture(folder,"book.pdf",count:20,size:Size(50,70)),workspace = model()
        try await prepare(workspace,pdf,binding:.perfectBound)
        workspace.project.coverMode = .excluded
        var selection = CoverSelection(); selection.front = 3; selection.insideFront = 4; selection.insideBack = 17; selection.back = 18
        workspace.bookSettings.selection = selection
        workspace.bookSettings.interiorPaper.input = .grammage; workspace.bookSettings.interiorPaper.grammage = 90; workspace.bookSettings.interiorPaper.bulk = 1.3
        workspace.bookSettings.coverPaper.input = .grammage; workspace.bookSettings.coverPaper.grammage = 250; workspace.bookSettings.coverPaper.bulk = 1.2
        workspace.bookSettings.coverAllowance = 0.4; workspace.bookSettings.adhesiveAllowance = 0.3
        workspace.bookSettings.leftFlap = 12; workspace.bookSettings.rightFlap = 18
        try await settle(workspace); workspace.showBookSection(.cover)
        XCTAssertEqual(workspace.currentSheet?.bookInfo?.section,.cover)
        XCTAssertTrue(workspace.plan.canExport,"\(workspace.plan.issues)")
        let url = folder.appendingPathComponent("book.atispress"); try workspace.saveProject(as:url)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf:url)).version,ProjectDocument.currentVersion)
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertEqual(opened.project,workspace.project); XCTAssertEqual(opened.plan.sheets,workspace.plan.sheets); XCTAssertFalse(opened.isModified)
        XCTAssertEqual(opened.currentSheet?.bookInfo?.section,.cover)
        opened.bookSettings.adhesiveAllowance = 0.6; try await settle(opened)
        XCTAssertTrue(opened.isModified); XCTAssertNotEqual(opened.currentSheet?.bookInfo?.spreadSize,workspace.currentSheet?.bookInfo?.spreadSize)
        opened.autoArrange(); try await settle(opened); XCTAssertEqual(opened.bookSettings,opened.project.book)
    }
    func testSeparateCoverLinkRoundtripRelinkAndOverwriteProtection() async throws {
        let folder = try folder(),body = try fixture(folder,"inside.pdf",count:8,size:Size(50,70)),cover = try fixture(folder,"cover.pdf",count:2,size:Size(100.48,70)),workspace = model()
        try await prepare(workspace,body,binding:.perfectBound)
        workspace.loadCoverPDF(cover); try await settle(workspace)
        workspace.bookSettings.coverArtwork = .spread; try await settle(workspace)
        XCTAssertEqual(workspace.project.coverMode,.separate); XCTAssertTrue(workspace.plan.canExport,"\(workspace.plan.issues)")
        XCTAssertEqual(workspace.project.bookInteriorPages.count,8); XCTAssertEqual(workspace.gangAssets.count,2)
        XCTAssertFalse(workspace.preflightRows.contains { $0.explanation.contains("Sayfa boyutları farklı") },"A separate cover spread is intentionally wider than interior pages")
        let url = folder.appendingPathComponent("linked.atispress"); try workspace.saveProject(as:url)
        let state = try ProjectDocument.decode(Data(contentsOf:url)).state
        XCTAssertEqual(state.linkedSources?.map(\.reference.path),[body.path,cover.path]); XCTAssertNil(state.source)
        XCTAssertFalse(String(data:try Data(contentsOf:url),encoding:.utf8)!.contains("AtisPress-gang-"))
        XCTAssertThrowsError(try workspace.saveProject(as:body)); XCTAssertThrowsError(try workspace.saveProject(as:cover))
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertEqual(opened.project,workspace.project); XCTAssertEqual(opened.plan.sheets,workspace.plan.sheets)
        XCTAssertEqual(opened.source?.displayName,"Kitap ve kapak")
        let moved = folder.appendingPathComponent("moved-cover.pdf"); try FileManager.default.copyItem(at:cover,to:moved); try FileManager.default.removeItem(at:cover)
        let relinked = model(); var names: [String] = []
        try await relinked.loadProject(at:url,relink:{ ref in names.append(ref.fileName); return moved }); try await settle(relinked)
        XCTAssertEqual(names,["cover.pdf"]); XCTAssertTrue(relinked.isModified); XCTAssertEqual(relinked.plan.sheets,workspace.plan.sheets)
        let untouched = model(),before = untouched.project
        do { try await untouched.loadProject(at:url,relink:{ _ in body }); XCTFail("Wrong cover must not load") } catch { XCTAssertEqual(untouched.project,before) }
    }
    func testLegacyVersionNineKeepsItsOriginalBookletAndNewSettingsAreOptIn() async throws {
        let folder = try folder(),pdf = try fixture(folder,"legacy.pdf",count:16,size:Size(50,70)),workspace = model()
        workspace.open(pdf); try await settle(workspace); workspace.setMode(.saddleStitch); try await settle(workspace)
        XCTAssertNil(workspace.project.book)
        let url = folder.appendingPathComponent("legacy.atispress"); try workspace.saveProject(as:url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]); object["version"] = 9
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertNil(opened.project.book); XCTAssertEqual(opened.plan.sheets,workspace.plan.sheets); XCTAssertFalse(opened.isModified)
        opened.enableBookSettings(); XCTAssertNil(opened.bookSettings.interiorPaper.millimetres); XCTAssertNil(opened.bookSettings.coverPaper.millimetres)
        try await settle(opened); XCTAssertTrue(opened.plan.sheets.contains { $0.bookInfo?.section == .cover })
    }
    func testCreepAndPaperInputsChangePreviewPixelsAndSummaryLive() async throws {
        let folder = try folder(),pdf = try fixture(folder,"creep.pdf",count:20,size:Size(50,70)),workspace = model()
        try await prepare(workspace,pdf,binding:.saddleStitch)
        workspace.project.sheet = SheetSpec(size:Size(120,90),orientation:.landscape)
        workspace.bookSettings.interiorPaper.microns = 1000; workspace.bookSettings.coverPaper.microns = 500
        try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport,"\(workspace.plan.issues)")
        let off = try XCTUnwrap(workspace.currentSheet)
        workspace.bookSettings.creepEnabled = true; try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport,"\(workspace.plan.issues)")
        let on = try XCTUnwrap(workspace.currentSheet)
        XCTAssertNotEqual(off.front.slots.map(\.artworkOffset),on.front.slots.map(\.artworkOffset))
        func bitmap(_ sheet: Sheet) throws -> Data {
            let view = SheetCanvasView(); view.configure(sheet:sheet,side:sheet.front,source:workspace.source,overlays:.artworkOnly,highlighted:[])
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(ceil(view.frame.width)),pixelsHigh:Int(ceil(view.frame.height)),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep); view.draw(view.bounds); NSGraphicsContext.restoreGraphicsState()
            return try XCTUnwrap(rep.representation(using:.png,properties:[:]))
        }
        XCTAssertNotEqual(try bitmap(off),try bitmap(on))
        let before = on.bookInfo?.summary; workspace.bookSettings.coverPaper.microns = 700; try await settle(workspace)
        XCTAssertNotEqual(workspace.currentSheet?.bookInfo?.summary,before)
        workspace.bookSettings.interiorPaper.microns = nil; try await settle(workspace)
        XCTAssertFalse(workspace.canExportNow); XCTAssertTrue(workspace.currentSheet?.bookInfo?.summary.contains("hesaplanamadı") == true)
    }
    func testExplicitZeroGutterIsNotReplacedWhenEnteringBookletMode() {
        let workspace = model()
        // The inspector marks an explicit edit even if 0 was already displayed.
        workspace.markManual(.gutter); workspace.project.sheet.gutter = 0
        workspace.setMode(.saddleStitch)
        XCTAssertEqual(workspace.project.sheet.gutter,0,"First booklet entry must not replace a user's zero with the legacy 6 mm default")
    }

    func testA5Booklet106PagePDFSeparateCoverOnManualA4AndAllZeroClearances() async throws {
        let folder = try folder(),body = try fixture(folder,"A5-106.pdf",count:106,size:SheetPreset.a5.size),cover = try fixture(folder,"A5-cover.pdf",count:4,size:SheetPreset.a5.size),workspace = model()
        try await prepare(workspace,body,binding:.saddleStitch)
        workspace.loadCoverPDF(cover); try await settle(workspace)
        workspace.project.exportMarks.crop = true
        workspace.project.settings.cropMarkLength = 5; workspace.project.settings.cropMarkOffset = 3.5
        workspace.sheetPreset = "A4"
        workspace.project.sheet = SheetSpec(preset:.a4,margins:Insets(),gripperWidth:0,gutter:0,orientation:.landscape)
        workspace.project.settings.bleed = 3
        // Leave preview crop length/offset intact: disabling output marks must
        // not secretly keep their fit padding or overwrite the user's gutter.
        workspace.project.exportMarks = .none; workspace.overlays = .artworkOnly
        try await settle(workspace)
        XCTAssertEqual(workspace.project.sheet.gutter,0)
        XCTAssertTrue(workspace.plan.canExport,workspace.plan.issues.map(\.message).joined(separator:"\n"))
        XCTAssertEqual(workspace.plan.sheets.count,28)
        XCTAssertEqual(workspace.plan.addedBlankPages,2)
        XCTAssertTrue(workspace.plan.diagnosticSheets.isEmpty)
        XCTAssertEqual(workspace.plan.sheets.first?.size,Size(297,210))
        workspace.project.exportMarks.crop = true; try await settle(workspace)
        XCTAssertFalse(workspace.plan.canExport,"Enabling crop marks must re-evaluate the full-sheet fit")
        workspace.project.exportMarks = .none; try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport)
        XCTAssertEqual(workspace.overlays,.artworkOnly)
        XCTAssertEqual(workspace.project.settings.cropMarkLength,5)
        let saved = folder.appendingPathComponent("A5-106.atispress"); try workspace.saveProject(as:saved)
        let restored = model(); try await restored.loadProject(at:saved); try await settle(restored)
        XCTAssertTrue(restored.plan.canExport)
        XCTAssertEqual(restored.project.sheet.gutter,0)
        XCTAssertEqual(restored.plan.sheets,workspace.plan.sheets)
        let output = folder.appendingPathComponent("A5-106-A4.pdf")
        let result = try PDFExporter.export(plan:restored.plan,source:XCTUnwrap(restored.source),destination:.singlePDF(output),marks:.none)
        XCTAssertEqual(result.sheetCount,28); XCTAssertEqual(result.pageCount,56)
        let document = try XCTUnwrap(PDFDocument(url:output))
        for i in 0..<document.pageCount {
            let box = try XCTUnwrap(document.page(at:i)).bounds(for:.mediaBox)
            XCTAssertEqual(box.width,297*72/25.4,accuracy:0.01)
            XCTAssertEqual(box.height,210*72/25.4,accuracy:0.01)
        }
    }

}
