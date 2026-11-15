import XCTest
import CoreGraphics
import SwiftUI
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class PresentationReviewTests:XCTestCase {
    func testTRFormatterAndCoreMessagePresentation() {
        XCTAssertEqual(TRFormat.dimension(0),"0")
        XCTAssertEqual(TRFormat.dimension(12.34),"12,3")
        XCTAssertEqual(TRFormat.dimension(12.346,detail:true),"12,35")
        XCTAssertEqual(TRFormat.dimension(330),"330")
        XCTAssertEqual(TRFormat.size(330,480),"330 × 480 mm")
        XCTAssertEqual(TRFormat.presentation("Maşa 0.0 mm · alan 12.30 mm"),"Maşa 0 mm · alan 12,3 mm")
    }
    func testMockedReleaseAndSemanticVersionComparison() throws {
        XCTAssertNil(ReleaseVersion("")); XCTAssertNil(ReleaseVersion("v")); XCTAssertNil(ReleaseVersion("1.2.3-"))
        XCTAssertTrue(try AppHelp.updateAvailable(data:Data(#"{"tag_name":"v0.2.0"}"#.utf8),current:"0.1.9"))
        XCTAssertFalse(try AppHelp.updateAvailable(data:Data(#"{"tag_name":"v0.1.0"}"#.utf8),current:"0.1.0"))
        XCTAssertFalse(try AppHelp.updateAvailable(data:Data(#"{"tag_name":"v0.1.0-beta.2"}"#.utf8),current:"0.1.0"))
        XCTAssertLessThan(ReleaseVersion("1.0.0-beta.2")!,ReleaseVersion("1.0.0-beta.11")!)
        XCTAssertGreaterThan(ReleaseVersion("v1.10.0")!,ReleaseVersion("1.9.9")!)
        XCTAssertThrowsError(try AppHelp.updateAvailable(data:Data(#"{"tag_name":"unknown"}"#.utf8),current:"0.1.0"))
    }
    func testDiagnosticsExcludePathsNamesPDFAndSerialContent() throws {
        var project = Workspace.newProject()
        project.serialFields = [SerialField(prefix:"PDF-PRIVATE-CONTENT-/Users/private")]
        project.sheetInfo = SheetInfoSettings()
        project.sheetInfo?.jobName = "/Users/private/artwork.pdf"
        let warning = ValidationIssue(.warning,.missingBleed,"/Users/private PDF-PRIVATE-CONTENT")
        let data = try AppHelp.diagnostics(project:project,issues:[warning])
        for secret in ["/Users/","artwork.pdf","PDF-PRIVATE-CONTENT","file://"] { XCTAssertFalse(data.contains(secret)) }
        XCTAssertTrue(data.contains("appVersion")); XCTAssertTrue(data.contains("macOS")); XCTAssertTrue(data.contains("settings")); XCTAssertTrue(data.contains("missingBleed"))
    }
    func testCollapsePersistenceManualLineAndSingleBleedRow() throws {
        let key = UUID().uuidString,defaults = UserDefaults(suiteName:key)!
        defer { defaults.removePersistentDomain(forName:key) }
        let ui = UsabilitySettings(defaults:defaults)
        XCTAssertTrue(ui.collapsedCards.isEmpty)
        ui.collapsedCards.insert("Hangi kâğıda basılacak?")
        XCTAssertEqual(UsabilitySettings(defaults:defaults).collapsedCards,ui.collapsedCards)
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/InspectorView.swift"),encoding:.utf8)
        XCTAssertEqual(code.components(separatedBy:"Text(\"Taşma payı\")").count-1,1)
        XCTAssertFalse(code.contains("measurement(\"Taşma\"")); XCTAssertFalse(code.contains("AutomaticPill("))
        let card = try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/DesignSystem.swift"),encoding:.utf8)
        XCTAssertTrue(card.contains("ayar manuel · Otomatiğe döndür"))
    }
    func testTurnControlOnlyForDuplexAndNormalJobHasNoWarnings() async throws {
        let m = Workspace()
        m.project = Project(pages:[SourcePage(number:1,trimSize:Size(85,55),availableBleed:3)],sheet:SheetSpec(preset:.sra3),settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0))
        for _ in 0..<100 where m.planning { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(m.showsTurnControl); XCTAssertTrue(m.workflowIssues.isEmpty)
        m.project.pages.append(SourcePage(number:2,trimSize:Size(85,55),availableBleed:3))
        for _ in 0..<100 where m.planning { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(m.showsTurnControl)
    }
    func testExportVerificationChecksNormalAndTamperedPDF() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("source.pdf")
        var media = CGRect(x:0,y:0,width:85*72/25.4,height:55*72/25.4)
        let ctx = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&media,nil))
        for _ in 0..<2 { ctx.beginPDFPage(nil); ctx.setFillColor(CGColor(gray:0.4,alpha:1)); ctx.fill(CGRect(x:10,y:10,width:50,height:80)); ctx.endPDFPage() }; ctx.closePDF()
        let source = try await PDFSource.open(url)
        var project = Project(pages:source.pages.map(\.sourcePage),sheet:SheetSpec(size:Size(220,160)),settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0),stepAndRepeat:StepAndRepeatSettings(columns:2,rows:2,quantity:4))
        project.exportMarks = .none
        let plan = ImpositionPlanner.plan(project),output = folder.appendingPathComponent("output.pdf")
        _ = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(output),marks:.none)
        XCTAssertTrue(try ExportVerification.check(files:[output],plan:plan,source:source,marks:.none,includeBlankBacks:true).passed)
        let tampered = folder.appendingPathComponent("tampered.pdf")
        let doc = try XCTUnwrap(CGPDFDocument(output as CFURL))
        media = doc.page(at:1)!.getBoxRect(.mediaBox)
        let writer = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:tampered as CFURL)),mediaBox:&media,nil))
        for n in 1...doc.numberOfPages { writer.beginPDFPage(nil); writer.saveGState(); writer.translateBy(x:24,y:0); writer.drawPDFPage(doc.page(at:n)!); writer.restoreGState(); writer.endPDFPage() }; writer.closePDF()
        let verification = try ExportVerification.check(files:[tampered],plan:plan,source:source,marks:.none,includeBlankBacks:true)
        XCTAssertFalse(verification.passed); XCTAssertTrue(verification.label.contains("konum"))
        let wrongSize = folder.appendingPathComponent("wrong-size.pdf")
        media = CGRect(x:0,y:0,width:50,height:50)
        let wrong = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:wrongSize as CFURL)),mediaBox:&media,nil)); wrong.beginPDFPage(nil); wrong.endPDFPage(); wrong.closePDF()
        let differences = try ExportVerification.check(files:[wrongSize],plan:plan,source:source,marks:.none,includeBlankBacks:true).label
        XCTAssertTrue(differences.contains("Sayfa sayısı")); XCTAssertTrue(differences.contains("ölçüsü"))
    }
}

extension PresentationReviewTests {
    func testLoadedMinimumWindowAndFreePositionSaveOpenAndLiveCanvasRetention() async throws {
        let m = try await SerialDragTests().fixture()
        m.moveSerialField(m.editableSerialFields[0].id,to:Point(12.25,8.75),snap:false)
        var state = m.state; state.order = [1,2]; state.included = [1,2]
        let doc = AllSheetsDocument(),scroll = AllSheetsScrollView(frame:NSRect(x:0,y:0,width:600,height:500))
        scroll.documentView = doc; doc.model = m; doc.updateGeometry(); doc.refreshVisible()
        let first = try XCTUnwrap(doc.subviews.flatMap(\.subviews).compactMap { $0 as? SheetCanvasView }.first)
        m.selectedSerialID = nil
        m.moveSerialField(m.editableSerialFields[0].id,to:Point(16.25,10.75),snap:false)
        XCTAssertFalse(doc.updateGeometry(),"Serial edit must not trigger auto-fit or rebuild the drag receiver")
        doc.refreshVisible()
        XCTAssertTrue(first.superview != nil)
        m.ui.focusedArea = .gripper; doc.updateGeometry(); doc.refreshVisible()
        XCTAssertEqual(first.focusArea,.gripper)
        XCTAssertNotNil(first.moveSerial); XCTAssertNotNil(first.selectSerial); XCTAssertNotNil(first.beginEdit); XCTAssertNotNil(first.endEdit)
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let qa = root.appendingPathComponent(".build/WorkflowQA")
        try FileManager.default.createDirectory(at:qa,withIntermediateDirectories:true)
        let url = qa.appendingPathComponent("serial-drag-source.pdf")
        var media = CGRect(x:0,y:0,width:85*72/25.4,height:55*72/25.4)
        let pdf = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&media,nil))
        for _ in 0..<2 {
            pdf.beginPDFPage(nil); pdf.setFillColor(CGColor(red:0.9,green:0.95,blue:0.95,alpha:1)); pdf.fill(media)
            pdf.setFillColor(CGColor(red:0.1,green:0.4,blue:0.5,alpha:1)); pdf.fill(CGRect(x:70,y:40,width:100,height:55)); pdf.endPDFPage()
        }; pdf.closePDF()
        state.project = m.project
        let loadedSource = try await PDFSource.open(url)
        state.project.pages = loadedSource.pages.map(\.sourcePage)
        state.source = try ProjectSource.capture(url,createBookmark:{ _ in Data() })
        state.project.allSheetsPreview = true
        XCTAssertEqual(try ProjectDocument.decode(ProjectDocument(state:state).encoded()).state.project.serialFields[0].position,Point(16.25,10.75))
        try ProjectDocument(state:state).encoded().write(to:qa.appendingPathComponent("serial-drag.atispress"))
        m.open(qa.appendingPathComponent("serial-drag.atispress"),confirmChanges:false)
        for _ in 0..<200 where m.source == nil || m.planning || m.loading { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(m.source); XCTAssertNil(m.error)
        m.ui.expandedAddons = [.serial]; m.ui.detailsExpanded = false
        let prices = PricingStore(url:qa.appendingPathComponent("qa-prices.json"))
        for color in [ColorScheme.light,.dark] {
            let host = NSHostingView(rootView:WorkspaceView(model:m,prices:prices).environment(\.colorScheme,color))
            host.frame = CGRect(origin:.zero,size:DesignSystem.minimumWindow); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds)); host.cacheDisplay(in:host.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:qa.appendingPathComponent(color == .light ? "serial-light.png" : "serial-dark.png"))
            XCTAssertEqual(host.frame.size,DesignSystem.minimumWindow)
        }
    }
}

extension PresentationReviewTests {
    func testCardResetAppliesAllFieldsWithoutLosingEarlierGangResets() async throws {
        let m = try await SerialDragTests().fixture()
        var job = GangJob(sourceID:UUID(),name:"Deneme",front:m.project.pages[0])
        job.bleed = 1
        job.generatedBleed.enabled = true; job.generatedBleed.method = .mirror
        job.generatedBleed.tolerance = 0.8; job.generatedBleed.color = .cmyk(1,0,0,0)
        var gang = GangSettings(); gang.jobs = [job]
        m.project.gang = gang; m.project.binding = .gang; m.selectedGangJobID = job.id
        let fields:[AutoLayoutField] = [.generatedEnabled,.generatedMethod,.generatedTolerance,.generatedColor]
        m.project.autoLayout?.manualFields.formUnion(fields)
        m.returnToAutomatic(fields)
        let result = try XCTUnwrap(m.project.gang?.jobs.first)
        XCTAssertFalse(result.generatedBleed.enabled)
        XCTAssertEqual(result.generatedBleed.method,.automatic)
        XCTAssertEqual(result.generatedBleed.tolerance,0.02)
        XCTAssertEqual(result.generatedBleed.color,.cmyk(0,0,0,0))
        for field in fields { XCTAssertFalse(m.isManual(field)) }
    }
}

extension PresentationReviewTests {
    func testRelease021MetadataAndUpdateComparisonStayAligned() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf:root.appendingPathComponent("packaging/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any])
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String,"0.2.1")
        XCTAssertEqual(plist["CFBundleVersion"] as? String,"3")
        XCTAssertEqual(AppHelp.version,"0.2.1"); XCTAssertEqual(AppHelp.buildNumber,"3")
        XCTAssertFalse(try AppHelp.updateAvailable(data:Data(#"{"tag_name":"v0.2.1"}"#.utf8)))
        XCTAssertFalse(try AppHelp.updateAvailable(data:Data(#"{"tag_name":"v0.1.0"}"#.utf8)))
        XCTAssertTrue(try AppHelp.updateAvailable(data:Data(#"{"tag_name":"v0.2.2"}"#.utf8)))
        for name in ["build_app.sh","make_dmg.sh"] {
            let script = try String(contentsOf:root.appendingPathComponent("scripts/"+name),encoding:.utf8)
            XCTAssertTrue(script.contains("packaging/Info.plist"))
            XCTAssertTrue(script.contains("CFBundleShortVersionString")); XCTAssertTrue(script.contains("CFBundleVersion"))
        }
    }
}
