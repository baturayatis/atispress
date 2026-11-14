import XCTest
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class UsabilityTests: XCTestCase {
    private func preferences() -> UserDefaults {
        let name = "atispress-ui-tests-"+UUID().uuidString
        let defaults = UserDefaults(suiteName:name)!
        addTeardownBlock { defaults.removePersistentDomain(forName:name) }
        return defaults
    }
    private func settle(_ model:Workspace) async throws {
        for _ in 0..<600 {
            if !model.loading && !model.planning && !model.autoArranging && !model.samplingBleed { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Workspace did not settle")
    }
    func testModeAndDisclosurePersistenceDoesNotIncludeTransientSearch() {
        let defaults = preferences(), first = UsabilitySettings(defaults:defaults)
        XCTAssertEqual(first.mode,.simple)
        first.mode = .advanced; first.setExpanded(.edges,false); first.search = "maşa"
        let second = UsabilitySettings(defaults:defaults)
        XCTAssertEqual(second.mode,.advanced); XCTAssertFalse(second.isExpanded(.edges)); XCTAssertEqual(second.search,"")
        second.mode = .simple
        XCTAssertEqual(UsabilitySettings(defaults:defaults).mode,.simple)
    }
    func testSearchMatchesTurkishSettingsAndSectionsAndTemporarilyExpands() {
        let ui = UsabilitySettings(defaults:preferences()); ui.mode = .advanced
        ui.setExpanded(.edges,false); ui.search = "MAŞA"
        XCTAssertTrue(ui.shows(.edges)); XCTAssertFalse(ui.shows(.serial)); XCTAssertTrue(ui.isExpanded(.edges))
        XCTAssertTrue(ui.matches(SettingGuidance.title(.gripperWidth))); XCTAssertFalse(ui.matches(SettingGuidance.title(.bleed)))
        ui.search = "kesim uzunluğu"
        XCTAssertTrue(ui.shows(.marks)); XCTAssertFalse(ui.shows(.sheet)); XCTAssertTrue(ui.matches(SettingGuidance.title(.cropLength)))
        ui.search = "Seri Numara"
        XCTAssertTrue(ui.matches("Başlangıç",section:.serial)); XCTAssertFalse(ui.matches("Maşa payı",section:.edges))
        ui.search = ""; XCTAssertFalse(ui.isExpanded(.edges))
        ui.focusSearch(); XCTAssertEqual(ui.mode,.advanced); XCTAssertEqual(ui.searchFocusRequest,1)
        ui.search = "olmayan ayar"; XCTAssertFalse(InspectorSection.allCases.contains(where:ui.shows))
    }
    func testModeSearchAndSectionsKeepHiddenAutomaticAndManualProjectValues() throws {
        let model = Workspace(uiDefaults:preferences())
        model.project.pages = (1...2).map { SourcePage(number:$0,trimSize:Size(85,55)) }
        let arranged = SmartAutoLayout.arrange(model.project)
        model.project = arranged.project
        model.project.sheet.margins.left = 17
        let project = model.project, plan = ImpositionPlanner.plan(project)
        let state = try ProjectDocument(state:model.state).encoded()
        for mode in [InspectorMode.simple,.advanced,.simple] {
            model.ui.mode = mode; model.ui.search = "maşa"; model.ui.setExpanded(.marks,false)
            XCTAssertEqual(model.project,project)
            XCTAssertEqual(ImpositionPlanner.plan(model.project).sheets,plan.sheets)
            XCTAssertEqual(try ProjectDocument(state:model.state).encoded(),state)
            XCTAssertEqual(model.project.autoLayout?.automaticFields,project.autoLayout?.automaticFields)
        }
        XCTAssertEqual(model.project.sheet.margins.left,17)
    }
    func testWarningsJumpToReferencedSheetOrRevealTheSetting() async throws {
        let model = Workspace(uiDefaults:preferences())
        model.project.pages = (1...4).map { SourcePage(number:$0,trimSize:Size(85,55)) }
        try await settle(model)
        let issue = ValidationIssue(.warning,.missingBleed,"Taşma",slot:SlotReference(sheet:1,side:.back,slot:0))
        model.reveal(issue)
        XCTAssertEqual(model.sheetIndex,1); XCTAssertEqual(model.side,.back)
        model.ui.mode = .simple; model.ui.search = "seri"
        model.reveal(ValidationIssue(.error,.exceedsSheet,"Sığmıyor"))
        XCTAssertEqual(model.ui.mode,.advanced); XCTAssertEqual(model.ui.revealedSection,.sheet)
        XCTAssertEqual(model.ui.search,""); XCTAssertTrue(model.ui.isExpanded(.sheet))
    }
    func testSectionResetIsScopedAndKeepsMeasuredInputsAndSeries() async throws {
        let model = Workspace(uiDefaults:preferences())
        model.project.pages = [SourcePage(number:1,trimSize:Size(85,55))]
        model.project.sheet.margins.left = 17; model.project.settings.bleed = 4
        try await settle(model)
        model.resetInspectorSection(.edges); try await settle(model)
        XCTAssertFalse(model.isManual(.marginLeft)); XCTAssertTrue(model.isManual(.bleed))
        XCTAssertEqual(model.project.settings.bleed,4)
        var field = SerialField(); field.start = 22; field.digitsAreManual = true
        model.project.serialFields = [field]
        model.resetInspectorSection(.serial)
        XCTAssertEqual(model.project.serialFields[0].start,22)
        XCTAssertFalse(model.project.serialFields[0].digitsAreManual)
        XCTAssertEqual(model.sectionBadge(.serial),"Otomatik")
        var book = BookSettings(); book.interiorPaper.microns = 100; book.selection.front = 3
        model.project.book = book
        model.resetInspectorSection(.binding)
        XCTAssertEqual(model.project.book?.interiorPaper.microns,100)
        XCTAssertNil(model.project.book?.selection.front)
        var cost = JobCostSettings(), selection = PriceSelection(UUID())
        selection.override = PriceEntry(kind:.paper); cost.paper = selection
        cost.copies = 100; cost.quote.note = "Deneme"
        model.project.costing = cost
        XCTAssertEqual(model.sectionBadge(.price),"Manuel")
        model.resetInspectorSection(.price)
        XCTAssertNil(model.project.costing?.paper?.override)
        XCTAssertEqual(model.project.costing?.paper?.id,selection.id)
        XCTAssertEqual(model.project.costing?.copies,100); XCTAssertEqual(model.project.costing?.quote.note,"Deneme")
        XCTAssertEqual(model.sectionBadge(.price),"Otomatik")
    }
    func testProductChoiceUsesExistingBindingAndIsRememberedPerProject() throws {
        let defaults = preferences(), model = Workspace(uiDefaults:defaults)
        model.project.pages = [SourcePage(number:1,trimSize:Size(90,50))]
        XCTAssertEqual(ProductKind.detect(model.project),.card)
        model.setProductKind(.form)
        XCTAssertEqual(model.project.binding,.stepAndRepeat); XCTAssertEqual(model.productKind,.form)
        let id = try XCTUnwrap(model.state.projectID)
        XCTAssertEqual(UsabilitySettings(defaults:defaults).productOverride(for:id),.form)
        model.setProductKind(.spiral)
        XCTAssertEqual(model.project.binding,.spiral)
        XCTAssertEqual(ProductKind.detect(model.project),.spiral)
    }
    func testExportPresetsOnlyChangeExistingMarkFlags() {
        var original = ExportMarks(); original.lineWidth = 0.7; original.color = .registration
        original.targetSize = 6; original.patchSize = 7
        for preset in ExportPreset.allCases {
            let result = preset.applying(to:original)
            XCTAssertEqual(result.lineWidth,original.lineWidth); XCTAssertEqual(result.color,original.color)
            XCTAssertEqual(result.targetSize,6); XCTAssertEqual(result.patchSize,7)
            XCTAssertTrue(result.crop); XCTAssertFalse(result.fullCut)
            XCTAssertEqual(result.fold,preset != .digital)
            XCTAssertEqual(result.bleed,preset == .proof); XCTAssertEqual(result.safeArea,preset == .proof)
            XCTAssertEqual(result.pageNumbers,preset == .proof); XCTAssertEqual(result.sheetInfo,preset != .digital)
            XCTAssertEqual(result.colorBar,preset == .press); XCTAssertEqual(result.registrationTargets,preset == .press)
        }
    }
    func testExistingPlanSnapshotAndRenderedExportStayIdenticalAcrossUIModesAndSaveOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("source.pdf")
        var media = CGRect(x:0,y:0,width:85*72/25.4,height:55*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&media,nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.setFillColor(CGColor(gray:0.4,alpha:1)); context.fill(media); context.endPDFPage() }
        context.closePDF()
        let defaults = preferences()
        func workspace() -> Workspace { Workspace(bookmarkCreator:{ try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil) },uiDefaults:defaults) }
        let model = workspace(); model.open(url,confirmChanges:false); try await settle(model)
        model.project = Project(pages:try XCTUnwrap(model.source).pages.map(\.sourcePage),sheet:SheetSpec(size:Size(220,160),margins:Insets(),gripperWidth:0,gutter:6),settings:ImpositionSettings(bleed:3,cropMarkLength:0,cropMarkOffset:0),stepAndRepeat:StepAndRepeatSettings(columns:2,rows:2,allowRotation:false,quantity:5))
        model.project.exportMarks = .none
        try await settle(model)
        let snapshot = model.plan
        XCTAssertEqual(snapshot.totalPressSheets,2); XCTAssertEqual(snapshot.sheets.count,1)
        XCTAssertEqual(snapshot.sheets[0].repeatLayout?.copiesPerSheet,4)
        XCTAssertEqual(snapshot.sheets[0].front.slots.map(\.sourcePageNumber),[1,1,1,1])
        XCTAssertEqual(snapshot.sheets[0].back.slots.map(\.sourcePageNumber),[2,2,2,2])
        func rendered(_ plan:ImpositionPlan,_ name:String) throws -> [Data] {
            let out = directory.appendingPathComponent(name+".pdf")
            _ = try PDFExporter.export(plan:plan,source:XCTUnwrap(model.source),destination:.singlePDF(out),marks:model.project.exportMarks)
            let pdf = try XCTUnwrap(CGPDFDocument(out as CFURL))
            return try (1...pdf.numberOfPages).map { number in
                let bitmap = try XCTUnwrap(CGContext(data:nil,width:320,height:240,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                let page = try XCTUnwrap(pdf.page(at:number))
                bitmap.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(x:0,y:0,width:320,height:240),rotate:0,preserveAspectRatio:true)); bitmap.drawPDFPage(page)
                return Data(bytes:try XCTUnwrap(bitmap.data),count:bitmap.bytesPerRow*bitmap.height)
            }
        }
        let before = try rendered(snapshot,"before")
        model.ui.mode = .simple; model.ui.search = "Taşma"; model.ui.setExpanded(.product,false)
        model.preparingExport = true; model.preparingExport = false // Opening/cancelling applies no preset.
        XCTAssertEqual(model.plan.sheets,snapshot.sheets)
        XCTAssertEqual(try rendered(model.plan,"after"),before)
        let saved = directory.appendingPathComponent("ui.atispress"); try model.saveProject(as:saved)
        let opened = workspace(); try await opened.loadProject(at:saved); try await settle(opened)
        XCTAssertEqual(opened.project,model.project); XCTAssertEqual(opened.plan.sheets,snapshot.sheets)
        XCTAssertEqual(opened.ui.mode,.simple)
    }
}
