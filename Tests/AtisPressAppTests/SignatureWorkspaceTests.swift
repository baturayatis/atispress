import XCTest
import AppKit
import PDFEngine
import ImpositionCore
@testable import AtisPressApp

@MainActor
final class SignatureWorkspaceTests: XCTestCase {
    private func model() -> Workspace {
        Workspace(bookmarkCreator:{ try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil) })
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    private func pdf(_ url: URL,count: Int) throws {
        var rect = CGRect(x:0,y:0,width:148*72/25.4,height:210*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&rect,nil))
        for _ in 0..<count { context.beginPDFPage(nil); context.setFillColor(CGColor(gray:0.4,alpha:1)); context.fill(CGRect(x:10,y:10,width:10,height:10)); context.endPDFPage() }
        context.closePDF()
    }
    private func settle(_ workspace: Workspace) async throws {
        for _ in 0..<1000 {
            if !workspace.loading && !workspace.planning && !workspace.autoArranging && !workspace.samplingBleed { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Signature workspace did not settle")
    }
    func testSewnFourManualBlankChoicesLiveSummaryAndSchemaElevenRoundtrip() async throws {
        let folder = try folder(),body = folder.appendingPathComponent("body.pdf"),cover = folder.appendingPathComponent("cover.pdf")
        try pdf(body,count:106); try pdf(cover,count:4)
        let workspace = model(); workspace.open(body); try await settle(workspace)
        workspace.setMode(.sewn); workspace.enableBookSettings(); workspace.loadCoverPDF(cover); try await settle(workspace)
        workspace.project.sheet = SheetSpec(preset:.a4,orientation:.landscape)
        workspace.project.settings.signatureSize = .four
        workspace.project.settings.bleed = 0; workspace.project.settings.cropMarkLength = 0; workspace.project.settings.cropMarkOffset = 3.5
        workspace.project.exportMarks.crop = true
        try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport,workspace.plan.issues.map(\.message).joined(separator:"\n"))
        XCTAssertEqual(workspace.plan.signatureCount,27); XCTAssertEqual(workspace.plan.blankPositions,[107,108])
        workspace.blankSettings.mode = .manual; try await settle(workspace)
        XCTAssertFalse(workspace.plan.canExport)
        workspace.setBlankPosition(1,selected:true); workspace.setBlankPosition(55,selected:true); try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport)
        XCTAssertEqual(workspace.plan.blankPositions,[1,55]); XCTAssertNil(workspace.plan.readingOrder[0]); XCTAssertNil(workspace.plan.readingOrder[54])
        XCTAssertEqual(workspace.plan.sheets[0].blankPositions,[1]); XCTAssertEqual(workspace.plan.sheets[13].blankPositions,[55])
        XCTAssertTrue(workspace.currentSheet?.bookInfo?.summary.contains("27 forma (4 sayfa)") == true)
        XCTAssertTrue(workspace.currentSheet?.bookInfo?.summary.contains("PDF yüzü: 56") == true)
        let saved = folder.appendingPathComponent("sewn.atispress"); try workspace.saveProject(as:saved)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf:saved)).version,ProjectDocument.currentVersion)
        let restored = model(); try await restored.loadProject(at:saved); try await settle(restored)
        XCTAssertEqual(restored.project,workspace.project); XCTAssertEqual(restored.plan.sheets,workspace.plan.sheets)
        XCTAssertEqual(restored.plan.readingOrder,workspace.plan.readingOrder); XCTAssertFalse(restored.isModified)
        restored.blankSettings.mode = .start; try await settle(restored)
        XCTAssertEqual(restored.plan.blankPositions,[1,2]); XCTAssertTrue(restored.isModified)
        restored.blankSettings.mode = .end; try await settle(restored)
        XCTAssertEqual(restored.plan.blankPositions,[107,108])
        restored.blankSettings.mode = .manual; try await settle(restored)
        XCTAssertEqual(restored.plan.blankPositions,[1,55],"Keep remembered manual positions when changing placement mode")
    }
    func testCropOffsetWithZeroLengthOrDisabledMarksDoesNotBlockLiveBooklet() async throws {
        let folder = try folder(),source = folder.appendingPathComponent("a5.pdf"); try pdf(source,count:106)
        let workspace = model(); workspace.open(source); try await settle(workspace); workspace.setMode(.saddleStitch)
        workspace.project.sheet = SheetSpec(preset:.a4,orientation:.landscape)
        workspace.project.settings.bleed = 0; workspace.project.settings.cropMarkLength = 0; workspace.project.settings.cropMarkOffset = 3.5
        workspace.project.exportMarks.crop = true; try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport,workspace.plan.issues.map(\.message).joined(separator:"\n"))
        workspace.project.settings.cropMarkLength = 5; try await settle(workspace)
        XCTAssertFalse(workspace.plan.canExport)
        workspace.project.exportMarks.crop = false; try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport)
        workspace.project.exportMarks.registrationTargets = true; try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport,"Other optional marks must not restore a phantom crop reserve or reject PDF point rounding")
        workspace.project.exportMarks.registrationTargets = false; try await settle(workspace)
        let saved = folder.appendingPathComponent("legacy.atispress"); try workspace.saveProject(as:saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:saved)) as? [String:Any]); object["version"] = 10
        try JSONSerialization.data(withJSONObject:object).write(to:saved)
        let old = model(); try await old.loadProject(at:saved); try await settle(old)
        XCTAssertNil(old.project.blankPlacement); XCTAssertEqual(old.plan.blankPositions,[107,108])
        XCTAssertEqual(old.project.binding,.saddleStitch); XCTAssertEqual(old.project.sheet,workspace.project.sheet)
    }
}
