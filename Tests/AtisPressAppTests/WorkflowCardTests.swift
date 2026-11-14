import XCTest
import SwiftUI
import AppKit
import PDFEngine
import ImpositionCore
@testable import AtisPressApp

@MainActor
final class WorkflowCardTests:XCTestCase {
    private var root:URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func source(_ name:String) throws -> String { try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/"+name+".swift"),encoding:.utf8) }
    private func preferences() -> UserDefaults {
        let name = "atispress-workflow-tests-"+UUID().uuidString, defaults = UserDefaults(suiteName:name)!
        addTeardownBlock { defaults.removePersistentDomain(forName:name) }; return defaults
    }
    func testEveryPreRedesignSettingBindingAndEditorRemainsReachable() throws {
        let editors = WorkflowSettingsBefore.byEditor.keys
        let sources = try editors.map(source)
        let combined = sources.joined(separator:"\n")
        let regex = try NSRegularExpression(pattern:#"\b(?:project|field|paper|book|settings|waste|selection|entry)\.(?:wrappedValue\.)?([A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*)"#)
        let ns = combined as NSString
        var after = Set(regex.matches(in:combined,range:NSRange(location:0,length:ns.length)).map { ns.substring(with:$0.range(at:1)) })
        let overlayRegex = try NSRegularExpression(pattern:#"\bmodel\.((?:overlays|editableGeneratedBleed|editableSerialFields|bookSettings|blankSettings)(?:\.[A-Za-z_][A-Za-z_0-9]*)*|sheetPreset|repeatArrangement|pageLayoutMode|infoJobName)"#)
        for match in overlayRegex.matches(in:combined,range:NSRange(location:0,length:ns.length)) { after.insert("model."+ns.substring(with:match.range(at:1))) }
        let keyPathRegex = try NSRegularExpression(pattern:#"\\\.([A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*)"#)
        for match in keyPathRegex.matches(in:combined,range:NSRange(location:0,length:ns.length)) { after.insert("keyPath."+ns.substring(with:match.range(at:1))) }
        let before = Set(WorkflowSettingsBefore.byEditor.values.flatMap { $0 })
        XCTAssertTrue(before.isSubset(of:after),"Lost setting keys: \(before.subtracting(after).sorted())")
        XCTAssertEqual(WorkflowSettingsBefore.byEditor.values.reduce(0) { $0+$1.count },257)
        // Follow editor references from the actual inspector, not from the inventory.
        var reachable:Set<String> = ["InspectorView"]
        var pending = ["InspectorView"]
        while let current = pending.popLast() {
            let code = try source(current)
            for editor in editors where !reachable.contains(editor) && code.contains(editor+"(") { reachable.insert(editor); pending.append(editor) }
        }
        // BlankPlacementView.swift contains the public BlankPlacementInspector type.
        if try source("InspectorView").contains("BlankPlacementInspector(") { reachable.insert("BlankPlacementView") }
        XCTAssertEqual(Set(editors).subtracting(reachable),[])
        for field in AutoLayoutField.allCases { XCTAssertTrue(combined.contains("."+field.rawValue),"Automatic setting missing: \(field)") }
    }
    func testSingleScreenHasNoModeTabBarOrPermanentSearchAndIncludesPaperChipsAndQuantityUnits() throws {
        let inspector = try source("InspectorView"), workspace = try source("WorkspaceView"), app = try source("AtisPressApp")
        for code in [inspector,workspace,app] {
            XCTAssertFalse(code.contains("TabView(")); XCTAssertFalse(code.contains("tabItem"))
            XCTAssertFalse(code.contains("TextField(\"Ayar ara\"")); XCTAssertFalse(code.contains("ui.mode"))
        }
        XCTAssertEqual(WorkflowPresentation.sheetChips,["Otomatik","A4","A3","SRA3","33×48","35×50","50×70","70×100","Özel ölçü…"])
        XCTAssertTrue(inspector.contains("Text(\"Adet\")")); XCTAssertTrue(inspector.contains("Text(\"adet\")")); XCTAssertTrue(inspector.contains("örn. 1000"))
        XCTAssertTrue(workspace.contains("PDF’i Hazırla")); XCTAssertTrue(app.contains("keyboardShortcut(\"e\")"))
    }
    func testBindingCardOnlyForBookCatalogAndLeafProducts() {
        for product in ProductKind.allCases { XCTAssertEqual(WorkflowPresentation.showsBindingCard(product),[ProductKind.book,.catalog,.spiral,.wireO].contains(product)) }
        var project = Workspace.newProject(); project.pages = [SourcePage(number:1,trimSize:Size(86.7,54))]
        XCTAssertEqual(ProductKind.detect(project),.card)
    }
    func testAddonExpansionPersistenceAndPreviewFocusNeverChangeProject() throws {
        let defaults = preferences(), model = Workspace(uiDefaults:defaults)
        let before = try ProjectDocument(state:model.state).encoded()
        for addon in WorkflowAddon.allCases { model.ui.expandedAddons.insert(addon); XCTAssertTrue(model.ui.expandedAddons.contains(addon)) }
        model.ui.detailsExpanded = true; model.ui.focusedArea = .gripper
        XCTAssertEqual(try ProjectDocument(state:model.state).encoded(),before)
        let reopened = UsabilitySettings(defaults:defaults)
        XCTAssertEqual(reopened.expandedAddons,Set(WorkflowAddon.allCases)); XCTAssertTrue(reopened.detailsExpanded)
        XCTAssertNil(reopened.focusedArea)
        XCTAssertEqual(WorkflowPresentation.focus(.marginLeft),.margins)
        XCTAssertEqual(WorkflowPresentation.focus(.gripperWidth),.gripper)
        XCTAssertEqual(WorkflowPresentation.focus(.gutter),.gutter)
        XCTAssertEqual(WorkflowPresentation.focus(.bleed),.bleed)
        XCTAssertEqual(WorkflowPresentation.focus(.cropLength),.marks)
    }
    func testDefaultPageLabelsAndSavedExplicitOverlayArePreserved() throws {
        let model = Workspace(uiDefaults:preferences()); XCTAssertFalse(model.overlays.pageNumbers)
        model.setMode(.perfectBound); XCTAssertTrue(model.overlays.pageNumbers)
        model.overlays.pageNumbers = false
        XCTAssertEqual(try ProjectDocument.decode(ProjectDocument(state:model.state).encoded()).state.overlays.pageNumbers,false)
    }
    func testBrandTextPairsMeet45ContrastInBothAppearances() {
        func luminance(_ hex:UInt32) -> Double {
            let values = [Double((hex>>16)&255),Double((hex>>8)&255),Double(hex&255)].map { value -> Double in let v = value/255; return v<=0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
            return values[0]*0.2126+values[1]*0.7152+values[2]*0.0722
        }
        for palette in [DesignSystem.lightPairs,DesignSystem.darkPairs] {
            for (name,pair) in palette { let a = luminance(pair.0),b = luminance(pair.1); XCTAssertGreaterThanOrEqual((max(a,b)+0.05)/(min(a,b)+0.05),4.5,name) }
        }
    }
    func testNativeLayoutBuildsAtMinimumSizeInLightAndDarkWithInlineDetails() throws {
        let model = Workspace(uiDefaults:preferences())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        let prices = PricingStore(url:url)
        for scheme in [ColorScheme.light,.dark] {
            model.ui.detailsExpanded = true; model.ui.expandedAddons = Set(WorkflowAddon.allCases)
            let host = NSHostingView(rootView:WorkspaceView(model:model,prices:prices).environment(\.colorScheme,scheme))
            host.appearance = NSAppearance(named:scheme == .light ? .aqua : .darkAqua)
            host.frame = CGRect(origin:.zero,size:DesignSystem.minimumWindow)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.frame.width,1180); XCTAssertEqual(host.frame.height,760)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
            host.cacheDisplay(in:host.bounds,to:bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide,0); XCTAssertGreaterThan(bitmap.pixelsHigh,0)
            let artifact = root.appendingPathComponent(".build/WorkflowQA")
            try FileManager.default.createDirectory(at:artifact,withIntermediateDirectories:true)
            try bitmap.representation(using:.png,properties:[:])?.write(to:artifact.appendingPathComponent(scheme == .light ? "light.png" : "dark.png"))
            XCTAssertTrue(try source("InspectorView").contains("ScrollView {"))
        }
    }
    func testExistingProjectPlanAndPDFSnapshotAreUnchangedByCardState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let sourceURL = directory.appendingPathComponent("existing.pdf")
        var media = CGRect(x:0,y:0,width:85*72/25.4,height:55*72/25.4)
        let pdf = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:sourceURL as CFURL)),mediaBox:&media,nil))
        for _ in 0..<2 { pdf.beginPDFPage(nil); pdf.setFillColor(CGColor(gray:0.4,alpha:1)); pdf.fill(media); pdf.endPDFPage() }; pdf.closePDF()
        let source = try await PDFSource.open(sourceURL)
        let model = Workspace(uiDefaults:preferences())
        model.project = Project(pages:source.pages.map(\.sourcePage),sheet:SheetSpec(size:Size(220,160),margins:Insets(),gripperWidth:0,gutter:6),settings:ImpositionSettings(bleed:3,cropMarkLength:0,cropMarkOffset:0),stepAndRepeat:StepAndRepeatSettings(columns:2,rows:2,allowRotation:false,quantity:5))
        model.project.exportMarks = .none
        let beforeProject = model.project, before = ImpositionPlanner.plan(model.project)
        func render(_ plan:ImpositionPlan,_ name:String) throws -> [Data] {
            let out = directory.appendingPathComponent(name+".pdf")
            _ = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(out),marks:model.project.exportMarks)
            let document = try XCTUnwrap(CGPDFDocument(out as CFURL))
            return try (1...document.numberOfPages).map { number in
                let bitmap = try XCTUnwrap(CGContext(data:nil,width:320,height:240,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.setFillColor(CGColor(gray:1,alpha:1)); bitmap.fill(CGRect(x:0,y:0,width:320,height:240))
                let page = try XCTUnwrap(document.page(at:number))
                bitmap.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(x:0,y:0,width:320,height:240),rotate:0,preserveAspectRatio:true)); bitmap.drawPDFPage(page)
                return Data(bytes:try XCTUnwrap(bitmap.data),count:bitmap.bytesPerRow*bitmap.height)
            }
        }
        let pixels = try render(before,"before")
        model.ui.expandedAddons = Set(WorkflowAddon.allCases); model.ui.detailsExpanded = true; model.ui.focusedArea = .bleed
        model.refreshWorkflowRecommendation()
        try await Task.sleep(for:.milliseconds(240))
        XCTAssertEqual(model.project,beforeProject)
        let after = ImpositionPlanner.plan(model.project)
        XCTAssertEqual(after.sheets,before.sheets); XCTAssertEqual(after.issues,before.issues)
        XCTAssertEqual(after.totalPressSheets,2); XCTAssertEqual(after.sheets.first?.repeatLayout?.copiesPerSheet,4)
        XCTAssertEqual(try render(after,"after"),pixels)
    }
    func testWarningNavigationOpensCorrespondingInlineSettings() async throws {
        let model = Workspace(uiDefaults:preferences())
        model.reveal(ValidationIssue(.warning,.serialNumbering,"Seri"))
        XCTAssertEqual(model.ui.revealedSection,.serial)
        model.reveal(ValidationIssue(.error,.exceedsSheet,"Tabaka"))
        XCTAssertEqual(model.ui.revealedSection,.sheet)
        model.revealWorkflowIssue(ValidationIssue(.warning,.missingBleed,"Eksik taşma"))
        XCTAssertEqual(model.ui.revealedSection,.marks); XCTAssertEqual(model.ui.focusedArea,.bleed)
        let before = model.project
        model.ui.detailsExpanded = true
        XCTAssertEqual(model.project,before)
    }
}
