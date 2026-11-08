import XCTest
import AppKit
import UniformTypeIdentifiers

import PDFKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class LeafWorkspaceTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    private func pdf(_ folder: URL,name: String = "source",count: Int = 9) throws -> URL {
        let url = folder.appendingPathComponent(name+".pdf")
        var box = CGRect(x:0,y:0,width:40*72/25.4,height:60*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&box,nil))
        for _ in 0..<count { context.beginPDFPage(nil); context.setFillColor(CGColor(gray:0.5,alpha:1)); context.fill(box); context.endPDFPage() }
        context.closePDF(); return url
    }
    private func model() -> Workspace { Workspace(bookmarkCreator:{ try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil) }) }
    private func settle(_ model: Workspace) async throws {
        // Native URL routing enqueues a MainActor task before starting the import.
        try await Task.sleep(for:.milliseconds(30))
        for _ in 0..<1500 {
            if !model.loading && !model.planning && !model.autoArranging && !model.samplingBleed && !model.checkingBindingStrips { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Leaf workspace did not settle")
    }
    func testEveryLeafSettingChangesPlanAndSchema13RoundtripKeepsPreviewAndExport() async throws {
        let folder = try folder(),workspace = model()
        workspace.open(try pdf(folder)); try await settle(workspace)
        workspace.setMode(.spiral)
        workspace.project.sheet = SheetSpec(size:Size(200,200),margins:Insets(left:15,right:15,top:15,bottom:15))
        workspace.project.settings.bleed = 0; workspace.project.exportMarks = .none
        workspace.project.stepAndRepeat.columns = 2; workspace.project.stepAndRepeat.rows = 2
        workspace.project.stepAndRepeat.allowRotation = false
        workspace.project.leafSettings.allowance = 6
        try await settle(workspace)
        XCTAssertTrue(workspace.canExportNow,"\(workspace.plan.issues)")
        let before = workspace.plan.sheets
        workspace.project.leafSettings.edge = .top; try await settle(workspace)
        XCTAssertNotEqual(before,workspace.plan.sheets)
        workspace.project.leafSettings.allowance = 8; try await settle(workspace)
        XCTAssertNotEqual(before,workspace.plan.sheets)
        workspace.project.leafSettings.holes = true; workspace.project.leafSettings.pitch = 10
        workspace.project.leafSettings.diameter = 2; workspace.project.leafSettings.offset = 4
        try await settle(workspace)
        let marks = try XCTUnwrap(workspace.plan.sheets.first).front.punchMarks
        XCTAssertFalse(marks.isEmpty)
        workspace.project.leafSettings.pitch = 15; try await settle(workspace)
        XCTAssertNotEqual(marks,workspace.plan.sheets.first?.front.punchMarks)
        workspace.project.leafSettings.diameter = 3; workspace.project.leafSettings.offset = 5
        workspace.project.binding = .wireO; try await settle(workspace)
        let url = folder.appendingPathComponent("leaf.atispress"); try workspace.saveProject(as:url)
        let decoded = try ProjectDocument.decode(Data(contentsOf:url))
        XCTAssertEqual(decoded.version,ProjectDocument.currentVersion)
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertEqual(opened.project,workspace.project); XCTAssertEqual(opened.plan.sheets,workspace.plan.sheets)
        XCTAssertFalse(opened.isModified)
        let output = try PDFExporter.export(plan:opened.plan,source:XCTUnwrap(opened.source),destination:.singlePDF(folder.appendingPathComponent("out.pdf")),marks:.none)
        XCTAssertEqual(output.sheetCount,2); XCTAssertEqual(output.pageCount,4)
        XCTAssertEqual(PDFDocument(url:output.files[0])?.pageCount,4)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        json["version"] = 12
        var state = try XCTUnwrap(json["state"] as? [String:Any]),p = try XCTUnwrap(state["project"] as? [String:Any])
        p.removeValue(forKey:"leafBinding"); state["project"] = p; json["state"] = state
        XCTAssertNil(try ProjectDocument.decode(JSONSerialization.data(withJSONObject:json)).state.project.leafBinding)
    }
    func testSeparateCoverPDFRestoresAndUsesSameBindingEdgeWithoutSpineOrCreep() async throws {
        let folder = try folder(),workspace = model()
        workspace.open(try pdf(folder,count:8)); try await settle(workspace)
        workspace.setMode(.wireO); workspace.project.leafSettings.edge = .right; workspace.project.leafSettings.allowance = 5
        workspace.loadCoverPDF(try pdf(folder,name:"cover",count:2)); try await settle(workspace)
        XCTAssertNil(workspace.error); XCTAssertTrue(workspace.plan.canExport,"\(workspace.plan.issues)")
        XCTAssertEqual(workspace.plan.sheets.filter { $0.leafInfo?.cover == true }.count,2)
        XCTAssertEqual(workspace.plan.readingOrder,[1,2,3,4,5,6,7,8])
        XCTAssertFalse(workspace.plan.issues.contains { $0.message.contains("Sırt") || $0.message.contains("kalınlığ") })
        let url = folder.appendingPathComponent("cover.atispress"); try workspace.saveProject(as:url)
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertEqual(opened.plan.sheets,workspace.plan.sheets)
    }
    func testNativeOpenURLsQueueWorksAtLaunchAndForRunningProject() async throws {
        let folder = try folder(),input = try pdf(folder,count:2),delegate = AppDelegate(),workspace = model()
        delegate.application(NSApplication.shared,open:[input]) // Arrives before SwiftUI connects workspace.
        delegate.workspace = workspace
        try await settle(workspace)
        XCTAssertEqual(workspace.source?.url,input)
        let project = folder.appendingPathComponent("native.atispress"); try workspace.saveProject(as:project)
        delegate.application(NSApplication.shared,open:[project])
        delegate.receiveOpenURLs([project]) // duplicate SwiftUI event must not ask twice
        try await settle(workspace)
        XCTAssertEqual(workspace.projectURL,project); XCTAssertNil(workspace.error); XCTAssertFalse(workspace.isModified)
    }
    func testBundleDeclaresOwnedEditableProjectUTIAndMatchingExtension() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:root.appendingPathComponent("packaging/Info.plist")),format:nil) as? [String:Any])
        let type = try XCTUnwrap((plist["CFBundleDocumentTypes"] as? [[String:Any]])?.first)
        XCTAssertEqual(type["CFBundleTypeRole"] as? String,"Editor"); XCTAssertEqual(type["LSHandlerRank"] as? String,"Owner")
        XCTAssertEqual(type["LSItemContentTypes"] as? [String],[UTType.atispress.identifier])
        let exported = try XCTUnwrap((plist["UTExportedTypeDeclarations"] as? [[String:Any]])?.first)
        XCTAssertEqual(exported["UTTypeIdentifier"] as? String,UTType.atispress.identifier)
        let tags = try XCTUnwrap(exported["UTTypeTagSpecification"] as? [String:Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String],["atispress"])
        XCTAssertEqual(exported["UTTypeConformsTo"] as? [String],["public.json"])
    }
    func testBindingBehaviorSchema14RoundtripLiveWarningsAndLegacyPreserveDefault() async throws {
        let folder = try folder(),workspace = model()
        workspace.open(try pdf(folder,count:3)); try await settle(workspace)
        workspace.setMode(.wireO)
        workspace.project.sheet = SheetSpec(size:Size(200,200))
        workspace.project.settings.bleed = 0; workspace.project.settings.cropMarkLength = 0; workspace.project.settings.safeAreaInset = 0
        workspace.project.stepAndRepeat.columns = 1; workspace.project.stepAndRepeat.rows = 1; workspace.project.stepAndRepeat.allowRotation = false
        workspace.project.leafSettings.allowance = 12
        for behavior in [BindingAllowanceBehavior.preserve,.shrink,.shift] {
            workspace.project.leafSettings.behavior = behavior
            try await settle(workspace)
            XCTAssertTrue(workspace.plan.canExport)
            let warnings = workspace.plan.issues.filter { $0.code == .bindingAllowance && $0.message.contains("beyaz olmayan") }
            XCTAssertEqual(warnings.isEmpty,behavior != .preserve)
            if behavior == .preserve { XCTAssertEqual(warnings.first?.affectedPages,[1,2,3]) }
            let url = folder.appendingPathComponent("behavior-\(behavior).atispress")
            try workspace.saveProject(as:url)
            let file = try ProjectDocument.decode(Data(contentsOf:url))
            XCTAssertEqual(file.version,14); XCTAssertEqual(file.state.project.leafSettings.behavior,behavior)
            let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
            XCTAssertEqual(opened.project,workspace.project)
            XCTAssertEqual(opened.plan.sheets,workspace.plan.sheets); XCTAssertFalse(opened.isModified)
            XCTAssertTrue(opened.plan.sheets.first?.leafInfo?.summary.contains(behavior.title) == true)
            if behavior == .preserve {
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]); json["version"] = 13
                var state = try XCTUnwrap(json["state"] as? [String:Any]),project = try XCTUnwrap(state["project"] as? [String:Any])
                var leaf = try XCTUnwrap(project["leafBinding"] as? [String:Any]); leaf.removeValue(forKey:"placementBehavior")
                project["leafBinding"] = leaf; state["project"] = project; json["state"] = state
                let legacy = try ProjectDocument.decode(JSONSerialization.data(withJSONObject:json))
                XCTAssertEqual(legacy.state.project.leafSettings.behavior,.preserve)
                XCTAssertEqual(ImpositionPlanner.plan(legacy.state.project).sheets,workspace.plan.sheets)
            }
        }
    }

}
