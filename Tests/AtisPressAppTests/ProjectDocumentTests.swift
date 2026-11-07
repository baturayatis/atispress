import XCTest
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class ProjectDocumentTests: XCTestCase {
    // ScopedBookmarksAgent is unavailable in the restricted XCTest host. Keep the
    // real file/bookmark roundtrip, injecting only native bookmark creation.
    private func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .minimalBookmark,includingResourceValuesForKeys: nil,relativeTo: nil)
    }
    private func workspace() -> Workspace { Workspace(bookmarkCreator: bookmark) }
    private func fixture() throws -> (URL,URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("kartlar.pdf")
        var media = CGRect(x: 0,y: 0,width: 85*72/25.4,height: 55*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: pdf as CFURL)),mediaBox: &media,nil))
        for number in 1...6 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: Double(number)/6,green: 0.3,blue: 0.6,alpha: 1))
            context.fill(media); context.endPDFPage()
        }
        context.closePDF()
        return (folder,pdf)
    }
    private func settle(_ model: Workspace) async throws {
        for _ in 0..<500 {
            if !model.loading && !model.planning && !model.samplingBleed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Workspace did not settle")
    }
    private func populated() async throws -> (Workspace,URL,URL) {
        let (folder,pdf) = try fixture()
        let model = workspace()
        model.open(pdf)
        try await settle(model)
        XCTAssertNotNil(model.source)
        model.setMode(.perfectBound)
        model.project.sheet = SheetSpec(size: Size(701,999),margins: Insets(left: 11,right: 12,top: 13,bottom: 14),
                                       gripperEdge: .left,gripperWidth: 8,gutter: 9,orientation: .landscape)
        model.sheetPreset = "Özel"
        model.project.settings = ImpositionSettings(bleed: 4,cropMarkLength: 6,cropMarkOffset: 5,safeAreaInset: 7,
            signatureSize: .eight,turnMethod: .workAndTurn,
            generatedBleed: GeneratedBleedSettings(enabled: true,method: .solidColor,tolerance: 0.13,color: .cmyk(0.2,0.3,0.4,0.5)))
        model.project.blankPagePolicy = .append
        model.project.coverMode = .included
        model.project.stepAndRepeat = StepAndRepeatSettings(columns: 2,rows: 3,allowRotation: false,quantity: 1234)
        model.project.exportMarks.crop = false
        model.project.exportMarks.fold = true; model.project.exportMarks.bleed = true
        model.project.exportMarks.safeArea = true; model.project.exportMarks.pageNumbers = true
        model.project.exportMarks.sheetInfo = true; model.project.exportMarks.fullCut = true
        model.project.exportMarks.lineWidth = 0.35; model.project.exportMarks.color = .registration
        model.move(IndexSet(integer: 4),to: 0)
        model.setIncluded(3,false); model.setIncluded(4,false)
        model.overlays = .artworkOnly
        model.side = .back
        try await settle(model)
        return (model,folder,pdf)
    }
    private func renderedPages(_ url: URL) throws -> [Data] {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        return try (1...document.numberOfPages).map { number in
            let page = try XCTUnwrap(document.page(at: number))
            let context = try XCTUnwrap(CGContext(data: nil,width: 400,height: 400,bitsPerComponent: 8,
                bytesPerRow: 1600,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let rect = CGRect(x: 0,y: 0,width: 400,height: 400)
            context.setFillColor(CGColor(gray: 1,alpha: 1)); context.fill(rect)
            context.concatenate(page.getDrawingTransform(.mediaBox,rect: rect,rotate: 0,preserveAspectRatio: true))
            context.drawPDFPage(page)
            return Data(bytes: try XCTUnwrap(context.data),count: context.bytesPerRow*context.height)
        }
    }
    func testVersionedJSONRoundtripAndUnknownVersionRejected() async throws {
        let (model,_,_) = try await populated()
        let file = ProjectDocument(state: model.state)
        let data = try file.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
        XCTAssertEqual(object["version"] as? Int,1)
        XCTAssertEqual(try ProjectDocument.decode(data),file)
        XCTAssertFalse(try XCTUnwrap(file.state.source).bookmark.isEmpty)
        var future = object; future["version"] = 999
        XCTAssertThrowsError(try ProjectDocument.decode(JSONSerialization.data(withJSONObject: future))) { error in
            guard case ProjectFileError.unsupportedVersion(999) = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertThrowsError(try ProjectDocument.decode(Data("{}".utf8)))
        var corrupt = file; corrupt.state.order = [1,1]
        XCTAssertThrowsError(try ProjectDocument.decode(corrupt.encoded()))
    }
    func testSaveOpenRestoresSettingsSelectionAndExactPlanWithoutDefaultsOverriding() async throws {
        let (model,folder,_) = try await populated()
        XCTAssertTrue(model.isModified)
        let projectURL = folder.appendingPathComponent("baski.atispress")
        try model.saveProject(as: projectURL)
        XCTAssertFalse(model.isModified)
        let restored = workspace()
        try await restored.loadProject(at: projectURL)
        try await settle(restored)
        XCTAssertFalse(restored.isModified)
        XCTAssertEqual(restored.project,model.project)
        XCTAssertEqual(restored.order,model.order); XCTAssertEqual(restored.included,model.included)
        XCTAssertEqual(restored.overlays,model.overlays); XCTAssertEqual(restored.side,.back)
        XCTAssertEqual(restored.sheetPreset,"Özel")
        XCTAssertEqual(restored.plan.sheets,model.plan.sheets)
        XCTAssertEqual(restored.plan.issues,model.plan.issues)
        XCTAssertEqual(restored.plan.generatedBleed,model.plan.generatedBleed)
        XCTAssertEqual(restored.projectURL,projectURL)
        let beforePDF = folder.appendingPathComponent("before.pdf"), afterPDF = folder.appendingPathComponent("after.pdf")
        _ = try PDFExporter.export(plan: model.plan,source: XCTUnwrap(model.source),destination: .singlePDF(beforePDF),
            marks: model.project.exportMarks,jobName: "Roundtrip")
        _ = try PDFExporter.export(plan: restored.plan,source: XCTUnwrap(restored.source),destination: .singlePDF(afterPDF),
            marks: restored.project.exportMarks,jobName: "Roundtrip")
        XCTAssertEqual(try renderedPages(beforePDF),try renderedPages(afterPDF),"Restored project must export identical rendered pages")
        restored.project.exportMarks.crop.toggle()
        XCTAssertTrue(restored.isModified)
        restored.project.exportMarks.crop.toggle()
        XCTAssertFalse(restored.isModified)
        restored.overlays.bleed.toggle(); XCTAssertTrue(restored.isModified)
        try restored.saveProject()
        XCTAssertFalse(restored.isModified)
        // Save As preserves the original and switches future saves to the new URL.
        let original = try Data(contentsOf: projectURL)
        let copy = folder.appendingPathComponent("kopya.atispress")
        try restored.saveProject(as: copy)
        XCTAssertEqual(restored.projectURL,copy)
        XCTAssertEqual(try Data(contentsOf: projectURL),original)
    }
    func testMissingFileAndRelinkPreserveSettingsAndCancelKeepsCurrentProject() async throws {
        let (model,folder,pdf) = try await populated()
        let file = folder.appendingPathComponent("kayip.atispress")
        try model.saveProject(as: file)
        let replacement = folder.appendingPathComponent("yeniden-baglanan.pdf")
        try FileManager.default.copyItem(at: pdf,to: replacement)
        try FileManager.default.removeItem(at: pdf)
        XCTAssertNil(model.state.source?.resolve())
        let restored = workspace(), before = Workspace.newProject()
        do { try await restored.loadProject(at: file); XCTFail("Missing PDF should require relink") }
        catch { guard case ProjectFileError.missingSource = error else { return XCTFail("Wrong error: \(error)") } }
        XCTAssertEqual(restored.project,before)
        do { try await restored.loadProject(at: file,relink: { _ in nil }); XCTFail("Expected cancel") }
        catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertEqual(restored.project,before)
        try await restored.loadProject(at: file,relink: { reference in
            XCTAssertEqual(reference.fileName,"kartlar.pdf")
            XCTAssertGreaterThan(reference.fileSize,0)
            return replacement
        })
        try await settle(restored)
        XCTAssertTrue(restored.isModified)
        XCTAssertEqual(restored.source?.url,replacement)
        XCTAssertEqual(restored.project,model.project)
        XCTAssertEqual(restored.plan.sheets,model.plan.sheets)
        try restored.saveProject()
        XCTAssertFalse(restored.isModified)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf: file)).state.source?.path,replacement.path)
    }
    func testChangedSizeRequiresRelinkAndBookmarkPathFallback() throws {
        let (_,pdf) = try fixture()
        var reference = try ProjectSource.capture(pdf,createBookmark: bookmark)
        reference.bookmark = Data() // path fallback for an unusable bookmark
        XCTAssertEqual(reference.resolve(),pdf)
        reference.fileSize += 1
        XCTAssertNil(reference.resolve())
    }
    func testCloseDecisionRequiresSuccessfulSaveAndCancelPreservesEdits() {
        let model = workspace()
        model.project.settings.bleed = 8
        XCTAssertTrue(model.isModified)
        var saves = 0
        XCTAssertFalse(model.resolveUnsavedChanges(.cancel) { saves += 1; return true })
        XCTAssertTrue(model.resolveUnsavedChanges(.discard) { saves += 1; return true })
        XCTAssertEqual(saves,0)
        XCTAssertFalse(model.resolveUnsavedChanges(.save) { saves += 1; return false })
        XCTAssertTrue(model.resolveUnsavedChanges(.save) { saves += 1; return true })
        XCTAssertEqual(saves,2)
        XCTAssertTrue(model.isModified)
    }
    func testFailedSaveDoesNotReplaceExistingProjectOrPDF() async throws {
        let (model,folder,pdf) = try await populated()
        let url = folder.appendingPathComponent("atomic.atispress")
        try model.saveProject(as: url)
        let original = try Data(contentsOf: url), source = try Data(contentsOf: pdf)
        model.project.pages = [] // intentionally inconsistent selection
        XCTAssertThrowsError(try model.saveProject())
        XCTAssertEqual(try Data(contentsOf: url),original)
        XCTAssertThrowsError(try model.saveProject(as: pdf))
        XCTAssertEqual(try Data(contentsOf: pdf),source)
        XCTAssertTrue(model.isModified)
    }

    func testEmptyProjectAndNewProjectDefaults() async throws {
        let (folder,_) = try fixture()
        let model = workspace()
        XCTAssertFalse(model.isModified)
        XCTAssertEqual(model.project.binding,.stepAndRepeat)
        XCTAssertEqual(model.project.sheet.size,Size(330,480)); XCTAssertEqual(model.sheetPreset,"33×48")
        let url = folder.appendingPathComponent("bos.atispress")
        try model.saveProject(as: url)
        let restored = workspace()
        try await restored.loadProject(at: url)
        try await settle(restored)
        XCTAssertEqual(restored.project,model.project)
        XCTAssertNil(restored.source); XCTAssertFalse(restored.isModified)
        restored.project.sheet.size = Size(700,1000)
        restored.sheetPreset = "70×100"
        restored.setMode(.saddleStitch)
        try restored.saveProject()
        restored.createNewProject()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(restored.plan.issues.isEmpty)
        XCTAssertFalse(restored.planning)
        XCTAssertEqual(restored.project,Workspace.newProject())
        XCTAssertNil(restored.projectURL); XCTAssertFalse(restored.isModified)
    }
}
