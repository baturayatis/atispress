import XCTest
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class EditingServicesTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    private func pdf(_ dir: URL,count: Int = 6) throws -> URL {
        let url = dir.appendingPathComponent("source.pdf")
        var box = CGRect(x:0,y:0,width:80*72/25.4,height:50*72/25.4)
        let cg = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&box,nil))
        for _ in 0..<count { cg.beginPDFPage(nil); cg.setFillColor(CGColor(gray:0.7,alpha:1)); cg.fill(box); cg.endPDFPage() }
        cg.closePDF(); return url
    }
    private func model(_ dir: URL,persist: Bool = false,interval: TimeInterval = 30) -> Workspace {
        let m = Workspace(bookmarkCreator:{ try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil) })
        if persist { m.startPersistence(recovery:RecoveryStore(directory:dir.appendingPathComponent("Recovery")),presetLibrary:PresetStore(url:dir.appendingPathComponent("library.json")),autosaveInterval:interval) }
        return m
    }
    private func settle(_ m: Workspace) async throws {
        try await Task.sleep(for:.milliseconds(25))
        for _ in 0..<1500 {
            if !m.loading && !m.planning && !m.autoArranging && !m.samplingBleed && !m.checkingBindingStrips { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Editing state did not settle")
    }
    func testRecoveryWritesUnsavedSourceAndRestoresExactlyWithoutOverwritingSavedFile() async throws {
        let dir = try folder(),input = try pdf(dir),m = model(dir,persist:true)
        m.open(input); try await settle(m)
        m.project.sheet.margins.left = 13; try await settle(m)
        try m.autosaveNow()
        let store = RecoveryStore(directory:dir.appendingPathComponent("Recovery")),record = try XCTUnwrap(store.records().first)
        XCTAssertNil(record.originalProjectPath); XCTAssertEqual(record.document.state.source?.path,input.path)
        XCTAssertEqual(record.document.version,15)
        let restored = model(dir,persist:true)
        try await restored.restoreRecovery(record); try await settle(restored)
        XCTAssertEqual(restored.project,m.project); XCTAssertEqual(restored.plan.sheets,m.plan.sheets)
        XCTAssertNil(restored.projectURL); XCTAssertTrue(restored.isModified)
        let saved = dir.appendingPathComponent("job.atispress"); try restored.saveProject(as:saved)
        let bytes = try Data(contentsOf:saved)
        XCTAssertTrue(try store.records().isEmpty)
        restored.project.sheet.margins.left = 17; try await settle(restored); try restored.autosaveNow()
        XCTAssertEqual(try Data(contentsOf:saved),bytes)
        XCTAssertEqual(try store.records().first?.originalProjectPath,saved.path)
        let recoveredSaved = model(dir,persist:true)
        try await recoveredSaved.restoreRecovery(XCTUnwrap(store.records().first)); try await settle(recoveredSaved)
        XCTAssertEqual(recoveredSaved.projectURL,saved); XCTAssertTrue(recoveredSaved.isModified)
        XCTAssertEqual(recoveredSaved.project.sheet.margins.left,17)
        recoveredSaved.cleanRecoveryForNormalQuit(); m.cleanRecoveryForNormalQuit(); restored.cleanRecoveryForNormalQuit()
        XCTAssertTrue(try store.records().isEmpty)
    }
    func testDebouncedAndPeriodicAutosaveAndNormalQuitLeaveNoRecovery() async throws {
        let dir = try folder(),m = model(dir,persist:true,interval:0.08),store = RecoveryStore(directory:dir.appendingPathComponent("Recovery"))
        m.project.sheet.margins.left = 12 // unsaved project without a PDF is recoverable too
        try await Task.sleep(for:.milliseconds(180))
        XCTAssertEqual(try store.records().first?.document.state.project.sheet.margins.left,12,"Periodic save fires before the 900 ms edit debounce")
        m.cleanRecoveryForNormalQuit()
        XCTAssertTrue(try store.records().isEmpty)
        m.startPersistence(recovery:store,presetLibrary:PresetStore(url:dir.appendingPathComponent("library.json")))
        m.project.sheet.margins.left = 19
        try await Task.sleep(for:.milliseconds(1100))
        XCTAssertEqual(try store.records().first?.document.state.project.sheet.margins.left,19,"Debounced save fires well before 30 seconds")
        m.cleanRecoveryForNormalQuit(); try await Task.sleep(for:.milliseconds(1000))
        XCTAssertTrue(try store.records().isEmpty,"A cancelled debounce must not resurrect recovery after clean quit")
    }
    func testUndoRedoSettingsPageOrderSelectionAndSerialsRestoreExactPlan() async throws {
        let dir = try folder(),m = model(dir)
        m.open(try pdf(dir)); try await settle(m)
        let baseline = m.project,basePlan = m.plan.sheets,order = m.order
        m.project.sheet.margins.left = 23; try await settle(m)
        let edited = m.project,editedPlan = m.plan.sheets
        m.undoEdit(); try await settle(m); XCTAssertEqual(m.project,baseline); XCTAssertEqual(m.plan.sheets,basePlan)
        m.redoEdit(); try await settle(m); XCTAssertEqual(m.project,edited); XCTAssertEqual(m.plan.sheets,editedPlan)
        m.move(IndexSet(integer:2),to:0); try await settle(m)
        let moved = m.project,movedPlan = m.plan.sheets
        m.undoEdit(); try await settle(m); XCTAssertEqual(m.order,order); XCTAssertEqual(m.project,edited)
        m.redoEdit(); try await settle(m); XCTAssertEqual(m.project,moved); XCTAssertEqual(m.plan.sheets,movedPlan)
        m.setIncluded(3,false); try await settle(m); XCTAssertFalse(m.included.contains(3))
        m.undoEdit(); try await settle(m); XCTAssertTrue(m.included.contains(3)); XCTAssertEqual(m.plan.sheets,movedPlan)
        m.project.serialFields = [SerialField(prefix:"UNDO-",position:Point(3,10))]; try await settle(m)
        let serial = m.project,serialPlan = m.plan.sheets
        m.undoEdit(); try await settle(m); XCTAssertTrue(m.project.serialFields.isEmpty); XCTAssertEqual(m.plan.sheets,movedPlan)
        m.redoEdit(); try await settle(m); XCTAssertEqual(m.project,serial); XCTAssertEqual(m.plan.sheets,serialPlan)
    }
    func testLongBlockDragIsOneUndoStepAndJobEditAlsoUndoes() async throws {
        let dir = try folder(),m = model(dir)
        m.open(try pdf(dir,count:2)); try await settle(m); m.setMode(.gang); try await settle(m)
        m.manualGang(); try await settle(m); m.flushUndoEdits()
        let baseline = m.project,basePlan = m.plan.sheets,id = try XCTUnwrap(m.project.gang?.blocks.first?.id),origin = try XCTUnwrap(m.project.gang?.blocks.first?.origin)
        m.beginUndoGroup()
        m.moveGangBlock(id,to:Point(origin.x+1,origin.y+1)); try await Task.sleep(for:.milliseconds(750))
        m.moveGangBlock(id,to:Point(origin.x+2,origin.y+2)); try await Task.sleep(for:.milliseconds(750))
        m.moveGangBlock(id,to:Point(origin.x+3,origin.y+3)); m.endUndoGroup(); try await settle(m)
        let moved = m.project
        m.undoEdit(); try await settle(m); XCTAssertEqual(m.project,baseline); XCTAssertEqual(m.plan.sheets,basePlan)
        m.redoEdit(); try await settle(m); XCTAssertEqual(m.project,moved)
        m.project.gang?.jobs[0].name = "Yeni iş adı"; try await settle(m)
        m.undoEdit(); try await settle(m); XCTAssertEqual(m.project,moved)
    }
    func testPresetAllowListApplyCrudPackAndProvenanceRoundtrip() async throws {
        let dir = try folder(),m = model(dir,persist:true)
        m.open(try pdf(dir)); try await settle(m)
        XCTAssertEqual(m.presets.map(\.name),["Kartvizit 33x48 ofset","A4 form dijital","A4 spiral form","Amerikan cilt A5 forma 4"])
        m.project.stepAndRepeat.quantity = 12345
        var waste = WasteSettings(); waste.mode = .fixed; waste.fixed = 55; m.project.stepAndRepeat.waste = waste
        m.project.serialFields = [SerialField(prefix:"KEEP-")]
        m.project.sheet.margins.left = 16
        let preset = try m.savePreset(name:"Özel ayar")
        let source = m.state.source,order = m.order,included = m.included,serials = m.project.serialFields
        m.project.sheet.margins.left = 27
        m.applyPreset(preset); try await settle(m)
        m.undoEdit(); try await settle(m); XCTAssertEqual(m.project.sheet.margins.left,27)
        m.redoEdit(); try await settle(m)
        XCTAssertEqual(m.project.sheet.margins.left,16)
        XCTAssertEqual(m.state.source,source); XCTAssertEqual(m.order,order); XCTAssertEqual(m.included,included)
        XCTAssertEqual(m.project.stepAndRepeat.quantity,12345); XCTAssertEqual(m.project.stepAndRepeat.waste,waste); XCTAssertEqual(m.project.serialFields,serials)
        XCTAssertEqual(m.autoLabel("Sol",.marginLeft),"Sol · Hazır ayar")
        XCTAssertFalse(m.project.autoLayout!.manualFields.contains(.marginLeft))
        let file = dir.appendingPathComponent("preset-job.atispress"); try m.saveProject(as:file)
        let reopened = model(dir); try await reopened.loadProject(at:file); try await settle(reopened)
        XCTAssertEqual(reopened.plan.sheets,m.plan.sheets); XCTAssertEqual(reopened.autoLabel("Sol",.marginLeft),"Sol · Hazır ayar")
        let auto = SmartAutoLayout.arrange(m.project)
        XCTAssertEqual(auto.project.sheet.margins.left,16,"Import recomputation preserves preset ownership")
        m.autoArrange(resetOverrides:true); try await settle(m)
        XCTAssertNil(m.project.autoLayout?.presetFields); XCTAssertTrue(m.project.autoLayout!.manualFields.isEmpty)
        XCTAssertEqual(m.project.stepAndRepeat.quantity,12345)
        try m.renamePreset(preset.id,to:"Yeni ad"); try m.duplicatePreset(preset.id)
        XCTAssertEqual(m.presets.last?.name,"Yeni ad kopyası")
        let pack = dir.appendingPathComponent("settings.atispresetpack"); try m.exportPresets(to:pack)
        let bytes = try Data(contentsOf:pack),json = String(decoding:bytes,as:UTF8.self)
        XCTAssertFalse(json.contains("quantity")); XCTAssertFalse(json.contains("serialFields")); XCTAssertFalse(json.contains("bookmark")); XCTAssertFalse(json.contains("source.pdf"))
        let otherDir = try folder(),other = model(otherDir,persist:true)
        let count = other.presets.count; try other.importPresets(from:pack)
        XCTAssertEqual(Array(other.presets.dropFirst(count)).map(\.settings),m.presets.map(\.settings))
        for p in m.presets { try m.deletePreset(p.id) }
        XCTAssertTrue(m.presets.isEmpty)
        XCTAssertTrue(try PresetStore(url:dir.appendingPathComponent("library.json")).load().isEmpty,"Deleted examples stay deleted")
        m.cleanRecoveryForNormalQuit(); other.cleanRecoveryForNormalQuit()
    }
    func testTypingOneSerialFieldCoalescesWhileCheckboxActionsStaySeparate() async throws {
        let dir = try folder(),m = model(dir)
        m.open(try pdf(dir,count:2)); try await settle(m)
        m.addSerialField(); try await settle(m); m.flushUndoEdits()
        let baseline = m.project.serialFields
        for text in ["A","AB","ABC"] {
            m.project.serialFields[0].prefix = text
            try await Task.sleep(for:.milliseconds(80))
        }
        m.undoEdit(); try await settle(m); XCTAssertEqual(m.project.serialFields,baseline)
        m.redoEdit(); try await settle(m); XCTAssertEqual(m.project.serialFields[0].prefix,"ABC")
        let original = m.project.exportMarks.crop
        m.project.exportMarks.crop = !original; try await settle(m)
        m.project.exportMarks.crop = original; try await settle(m)
        m.undoEdit(); try await settle(m); XCTAssertEqual(m.project.exportMarks.crop,!original)
        m.redoEdit(); try await settle(m); XCTAssertEqual(m.project.exportMarks.crop,original)
    }
    func testRecoveryRestoresGangSourcesBlocksAndSerialFields() async throws {
        let dir = try folder(),m = model(dir,persist:true)
        m.open(try pdf(dir,count:2)); try await settle(m)
        m.setMode(.gang); try await settle(m); m.manualGang(); try await settle(m)
        m.project.gang?.jobs[0].serialFields = [SerialField(prefix:"REC-")]
        m.project.gang?.jobs[0].quantity = 31
        try await settle(m)
        try m.autosaveNow()
        let store = RecoveryStore(directory:dir.appendingPathComponent("Recovery")),record = try XCTUnwrap(store.records().first)
        XCTAssertEqual(record.document.state.gangSources?.count,1)
        let restored = model(dir,persist:true)
        try await restored.restoreRecovery(record); try await settle(restored)
        XCTAssertEqual(restored.project,m.project); XCTAssertEqual(restored.plan.sheets,m.plan.sheets)
        XCTAssertEqual(restored.project.gang?.jobs[0].quantity,31)
        XCTAssertEqual(restored.project.gang?.jobs[0].serialFields.first?.prefix,"REC-")
        restored.cleanRecoveryForNormalQuit(); m.cleanRecoveryForNormalQuit()
    }

    func testBuiltInPresetsFitTheirNamedProductsAndVersion14StillOpensWithoutProjectID() throws {
        let examples = PresetStore.examples()
        for (index,preset) in examples.enumerated() {
            let size = index == 0 ? Size(85,55) : index == 3 ? Size(148.0000001,210.0000001) : Size(210.0000001,297.0000001)
            let pages = (1...(index == 3 ? 4 : 2)).map { SourcePage(number:$0,trimSize:size,availableBleed:3) }
            let base = Project(pages:pages,sheet:SheetSpec(preset:.sra3))
            let p = preset.settings.apply(to:base,name:preset.name),auto = SmartAutoLayout.arrange(p)
            XCTAssertTrue(auto.plan.canExport,"\(preset.name): \(auto.plan.issues)")
            XCTAssertEqual(auto.project.sheet,preset.settings.sheet)
            XCTAssertEqual(auto.project.autoLayout?.trimTolerance,p.autoLayout?.trimTolerance)
        }
        let m = Workspace()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:ProjectDocument(state:m.state).encoded()) as? [String:Any])
        json["version"] = 14
        var state = try XCTUnwrap(json["state"] as? [String:Any]); state.removeValue(forKey:"projectID"); json["state"] = state
        let old = try ProjectDocument.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(old.state.projectID)
        XCTAssertEqual(old.state.project,m.project)
    }

    func testNativeTextEditingFocusGroupsLongTypingAndDerivedDigitChanges() async throws {
        let dir = try folder(),m = model(dir)
        m.open(try pdf(dir,count:2)); try await settle(m)
        m.addSerialField(); try await settle(m); m.flushUndoEdits()
        let baseline = m.project
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        let field = NSTextField(frame:NSRect(x:10,y:10,width:100,height:24)); window.contentView?.addSubview(field)
        let coordinator = ProjectWindowControl.Coordinator(model:m); coordinator.attach(window)
        NotificationCenter.default.post(name:NSControl.textDidBeginEditingNotification,object:field)
        m.project.stepAndRepeat.quantity = 99999
        try await Task.sleep(for:.milliseconds(750))
        m.project.stepAndRepeat.quantity = 999999
        try await Task.sleep(for:.milliseconds(750))
        NotificationCenter.default.post(name:NSControl.textDidEndEditingNotification,object:field)
        try await settle(m)
        XCTAssertEqual(m.project.serialFields[0].digits,6)
        m.undoEdit(); try await settle(m); XCTAssertEqual(m.project,baseline)
        m.redoEdit(); try await settle(m); XCTAssertEqual(m.project.stepAndRepeat.quantity,999999)
        XCTAssertEqual(m.project.serialFields[0].digits,6)
        withExtendedLifetime(coordinator) {}
    }

}
