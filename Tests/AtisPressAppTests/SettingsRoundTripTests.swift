import XCTest
import CoreFoundation
import SwiftUI
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

/// The frozen reachability registry supplies the field names. Codable paths supply
/// concrete writable storage (including nested and per-job fields) for each mode.
@MainActor final class SettingsRoundTripTests:XCTestCase {
    struct Leaf { var path:[String]; var value:Any; var name:String { path.joined(separator:".") } }
    private func fixture(_ mode:BindingMethod) -> Project {
        var p = Workspace.newProject()
        p.pages = (1...12).map { SourcePage(number:$0,trimSize:Size(85,55),availableBleed:3) }
        p.binding = mode; p.autoLayout = .legacy
        p.sheet = SheetSpec(size:Size(330,480),margins:Insets(left:10,right:10,top:10,bottom:10),gripperWidth:5,gutter:6)
        p.settings.generatedBleed.enabled = false
        p.stepAndRepeat.quantity = 10; p.stepAndRepeat.columns = 2; p.stepAndRepeat.rows = 2
        p.stepAndRepeat.pageLayout = PageLayoutSettings(); p.stepAndRepeat.pageLayout?.mode = .duplex
        p.stepAndRepeat.waste = WasteSettings(); p.stepAndRepeat.waste?.fixed = 2
        p.book = BookSettings(); p.book?.interiorPaper.microns = 100; p.book?.coverPaper.microns = 200
        p.book?.interiorPaper.grammage = 80; p.book?.interiorPaper.bulk = 1.2
        p.book?.selection.front = 1; p.book?.selection.back = 12; p.book?.selection.insideFront = 2; p.book?.selection.insideBack = 11
        p.leafBinding = LeafBindingSettings(); p.leafBinding?.allowance = 10; p.leafBinding?.pitch = 6; p.leafBinding?.diameter = 3; p.leafBinding?.offset = 5; p.leafBinding?.behavior = .preserve
        p.blankPlacement = BlankPlacement(); p.blankPlacement?.positions = [1]
        var serial = SerialField(); serial.code = SerialCodeSettings(); serial.code?.quietZone = 4; serial.rangeDistribution = .copy; serial.backNumber = .same; serial.endNumberEnabled = false
        p.serialFields = [serial]; p.sheetInfo = SheetInfoSettings(); p.sheetInfo?.jobName = "Deneme"
        p.exportMarks.colorControls = ColorControlSettings(); p.includeBlankBacks = false; p.allSheetsPreview = false
        p.scaling = ScalingSettings(); p.scaling?.overrides = [ScalingOverride(pages:[1,2],jobIndex:0,settings:RescaleSettings())]
        p.scaling?.overrides = []
        p.costing = JobCostSettings(); p.costing?.copies = 100; p.costing?.margin = 20; p.costing?.vat = 20
        var gang = GangSettings()
        var job = GangJob(sourceID:UUID(),name:"Kart",front:p.pages[0],back:p.pages[1]); job.quantity = 10; job.serialFields = [serial]
        gang.jobs = [job]; gang.blocks = [GangBlock(jobID:job.id,origin:Point(20,20))]; p.gang = gang
        return p
    }
    private func object<T:Encodable>(_ value:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
    private func decode(_ object:Any) throws -> Project { try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:object,options:.sortedKeys)) }
    private func leaves(_ value:Any,_ path:[String] = []) -> [Leaf] {
        if let d = value as? [String:Any] { return d.keys.sorted().flatMap { leaves(d[$0]!,path+[$0]) } }
        if let a = value as? [Any] { return a.enumerated().flatMap { leaves($0.element,path+[String($0.offset)]) } }
        return [Leaf(path:path,value:value)]
    }
    private func setting(_ value:Any,path:[String],to replacement:Any) -> Any {
        guard let first = path.first else { return replacement }
        if var d = value as? [String:Any] { d[first] = setting(d[first]!,path:Array(path.dropFirst()),to:replacement); return d }
        var a = value as! [Any]; let i = Int(first)!; a[i] = setting(a[i],path:Array(path.dropFirst()),to:replacement); return a
    }
    private var enumCandidates:[String] {
        // Read all case names and explicit raw strings from the actual model source;
        // decodability selects only values belonging to the field's own enum.
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ImpositionCore")
        let text = ((try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []).compactMap { try? String(contentsOf:$0,encoding:.utf8) }.joined(separator:"\n")
        let r = try! NSRegularExpression(pattern:#"\b[A-Za-z][A-Za-z0-9_]*\b|"[^"\n]{1,50}""#)
        let ns = text as NSString
        return Array(Set(r.matches(in:text,range:NSRange(location:0,length:ns.length)).map { ns.substring(with:$0.range).trimmingCharacters(in:CharacterSet(charactersIn:"\"")) })).sorted()
    }
    private func alternative(_ leaf:Leaf,in root:Any,candidates:[String]) -> Any? {
        if let n = leaf.value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return !n.boolValue }
            return n.doubleValue+1
        }
        if let s = leaf.value as? String {
            if UUID(uuidString:s) != nil { return nil }
            for candidate in [s+"x"]+candidates where candidate != s {
                if (try? decode(setting(root,path:leaf.path,to:candidate))) != nil { return candidate }
            }
        }
        return nil
    }
    private func preview(_ project:Project,_ overlays:PDFRenderOptions,_ focus:WorkflowFocus? = nil) -> String {
        let plan = ImpositionPlanner.plan(project)
        return plan.sheets.map { sheet in
            [SideKind.front,.back].map { kind in
                let side = kind == .front ? sheet.front : sheet.back
                let canvas = SheetCanvasView(); canvas.focusArea = focus
                canvas.configure(sheet:sheet,side:side,source:nil,overlays:overlays,highlighted:[],generatedBleed:plan.generatedBleed,controlMarks:project.exportMarks,bleedAmount:project.settings.bleed)
                let guide = canvas.visibleGuideMarks.filter { overlays.shows($0.kind) }
                let production = PDFExportMarkRenderer.geometry(side:side,sheet:sheet,settings:project.exportMarks).segments
                let colors = PDFColorControlRenderer.geometry(sheet:sheet,settings:project.exportMarks,kind:kind)
                return String(reflecting:guide)+String(reflecting:production)+String(reflecting:side.punchMarks)+String(reflecting:colors)+String(reflecting:overlays)
            }.joined(separator:"\n")
        }.joined(separator:"\n")
    }
    func testEveryRegistryBackedWritableFieldRoundTripsInEveryJobType() throws {
        let names = Set(WorkflowSettingsBefore.byEditor.values.flatMap { Array($0) }.flatMap { (value:String) in value.components(separatedBy:".") })
        let candidates = enumCandidates
        var report:[String] = ["mode,setting,changed"]
        for mode in [BindingMethod.stepAndRepeat,.gang,.saddleStitch,.spiral] {
            let m = Workspace(); m.project = fixture(mode)
            let original = try object(m.project), plan = ImpositionPlanner.plan(m.project), baseline = preview(m.project,m.overlays)
            let fields = leaves(original).filter { leaf in
                !leaf.path.contains("autoLayout") && !leaf.path.contains("pages") && !["id","sourceID","number","availableBleed"].contains(leaf.path.last!) && leaf.path.contains(where:names.contains)
            }
            var exercised = 0
            for field in fields {
                guard let value = alternative(field,in:original,candidates:candidates),let changed = try? decode(setting(original,path:field.path,to:value)) else { continue }
                m.project = changed
                _ = ImpositionPlanner.plan(m.project); _ = preview(m.project,m.overlays,m.ui.focusedArea)
                // Restore just this field in the current project, not the whole baseline.
                m.project = try decode(setting(try object(m.project),path:field.path,to:field.value))
                let restored = ImpositionPlanner.plan(m.project)
                XCTAssertEqual(restored.sheets,plan.sheets,"\(mode): \(field.name)")
                XCTAssertEqual(restored.issues,plan.issues,"\(mode): \(field.name)")
                XCTAssertEqual(preview(m.project,m.overlays,m.ui.focusedArea),baseline,"\(mode): \(field.name)")
                exercised += 1; report.append("\(mode),\(field.name),yes")
            }
            XCTAssertGreaterThan(exercised,150,"Registry-backed concrete fields must not silently disappear")
        }
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try report.joined(separator:"\n").write(to:root.appendingPathComponent(".build/settings-round-trips.csv"),atomically:true,encoding:.utf8)
    }
    func testEveryPairOfTogglesInEachRegistryCardIsOrderIndependent() throws {
        let names = Set(WorkflowSettingsBefore.byEditor.values.flatMap { Array($0) }.flatMap { (value:String) in value.components(separatedBy:".") })
        for mode in [BindingMethod.stepAndRepeat,.gang,.saddleStitch,.spiral] {
            let m = Workspace(); m.project = fixture(mode)
            let root = try object(m.project), baseline = preview(m.project,m.overlays), plan = ImpositionPlanner.plan(m.project)
            let booleans = leaves(root).filter { leaf in
                guard let n = leaf.value as? NSNumber else { return false }
                return CFGetTypeID(n) == CFBooleanGetTypeID() && !leaf.path.contains("autoLayout") && leaf.path.contains(where:names.contains)
            }
            // Group by storage card/editor; test cross-editor printed controls as
            // one group as well, since they appear in both card 3 and details.
            var groups = Dictionary(grouping:booleans) { leaf in leaf.path.first == "exportMarks" ? "printed" : leaf.path.first! }
            groups["card3"] = booleans.filter { $0.name == "settings.generatedBleed.enabled" || $0.name == "exportMarks.crop" }
            groups["leafCard"] = booleans.filter { $0.path.first == "leafBinding" || $0.name == "stepAndRepeat.allowRotation" }
            groups["infoCard"] = booleans.filter { $0.path.first == "sheetInfo" || $0.name == "exportMarks.sheetInfo" }
            for group in groups.values {
                for a in group.indices { for b in group.indices where b>a {
                    let x = group[a], y = group[b]
                    m.project = try decode(setting(root,path:x.path,to:!(x.value as! NSNumber).boolValue))
                    m.project = try decode(setting(try object(m.project),path:y.path,to:!(y.value as! NSNumber).boolValue))
                    m.project = try decode(setting(try object(m.project),path:x.path,to:x.value))
                    m.project = try decode(setting(try object(m.project),path:y.path,to:y.value))
                    XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,plan.sheets,"\(mode): \(x.name) + \(y.name)")
                    XCTAssertEqual(preview(m.project,m.overlays),baseline,"\(mode): \(x.name) + \(y.name)")
                } }
            }
        }
    }
    func testPrintedTogglesAndEveryGuideAreIndependent() {
        for mode in [BindingMethod.stepAndRepeat,.gang,.saddleStitch,.spiral] {
            let m = Workspace(); m.project = fixture(mode)
            m.overlays.colorBar = false; m.overlays.registrationTargets = false
            let baseline = m.overlays
            let fields:[(WritableKeyPath<ExportMarks,Bool>,AutoLayoutField)] = [(\.crop,.exportCrop),(\.fold,.exportFold),(\.colorBar,.exportColorBar),(\.registrationTargets,.exportTargets),(\.sheetInfo,.exportSheetInfo),(\.safeArea,.exportSafeArea),(\.bleed,.exportBleed),(\.pageNumbers,.exportPageNumbers),(\.fullCut,.exportFullCut)]
            for (key,field) in fields {
                let original = m.project.exportMarks[keyPath:key]
                let binding = m.autoBinding(Binding(get:{m.project.exportMarks[keyPath:key]},set:{m.project.exportMarks[keyPath:key] = $0}),field)
                binding.wrappedValue = !original; binding.wrappedValue = original
                XCTAssertEqual(m.overlays,baseline,"\(mode): \(field)")
            }
            let project = m.project
            for key in [\PDFRenderOptions.crop,\.fold,\.bleed,\.safeArea,\.pageNumbers,\.sheetBoundary,\.pressGuides,\.punch,\.colorBar,\.registrationTargets] {
                m.overlays[keyPath:key].toggle(); m.overlays[keyPath:key].toggle()
                XCTAssertEqual(m.project,project); XCTAssertEqual(m.overlays,baseline)
            }
        }
    }
    func testEveryInspectorGuideDimensionAndLeafControlRoundTripsWithoutLayerSideEffects() {
        let m = Workspace(); m.project = fixture(.spiral)
        m.overlays = .artworkOnly
        func check<T:Equatable>(_ name:String,_ binding:Binding<T>,_ changed:T) {
            let value = binding.wrappedValue, plan = ImpositionPlanner.plan(m.project), geometry = preview(m.project,m.overlays), layers = m.overlays
            binding.wrappedValue = changed
            XCTAssertEqual(m.overlays,layers,name)
            _ = preview(m.project,m.overlays)
            binding.wrappedValue = value
            XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,plan.sheets,name)
            XCTAssertEqual(preview(m.project,m.overlays),geometry,name)
        }
        for (key,field) in [(\ImpositionSettings.bleed,AutoLayoutField.bleed),(\.cropMarkLength,.cropLength),(\.cropMarkOffset,.cropOffset),(\.safeAreaInset,.safeArea)] {
            check(field.rawValue,m.guideDimensionBinding(key,field:field),m.project.settings[keyPath:key]+1)
        }
        check("leaf.edge",m.leafSettingBinding(\.edge),.top)
        check("leaf.behavior",m.leafSettingBinding(\.behavior),.shrink)
        check("leaf.holes",m.leafSettingBinding(\.holes),true)
        for key in [\LeafBindingSettings.allowance,\.pitch,\.diameter,\.offset] { check("leaf.\(key)",m.leafSettingBinding(key),11) }
        let layers = m.overlays
        let mode = m.project.binding
        m.setMode(.saddleStitch); m.setMode(mode)
        XCTAssertEqual(m.overlays,layers,"binding/pageNumbers")
        m.setProduction(.offset); m.setProduction(.digital)
        XCTAssertEqual(m.overlays,layers,"production/colorBar/targets")
    }
    func testEveryPairOfGuideTogglesRoundTripsWithoutChangingPrintedSettings() {
        let keys:[WritableKeyPath<PDFRenderOptions,Bool>] = [\.crop,\.fold,\.bleed,\.safeArea,\.pageNumbers,\.sheetBoundary,\.pressGuides,\.punch,\.colorBar,\.registrationTargets]
        for mode in [BindingMethod.stepAndRepeat,.gang,.saddleStitch,.spiral] {
            let m = Workspace(); m.project = fixture(mode)
            m.overlays.colorBar = false; m.overlays.registrationTargets = false
            let baseline = preview(m.project,m.overlays), marks = m.project.exportMarks
            for i in keys.indices { for j in keys.indices where j>i {
                m.overlays[keyPath:keys[i]].toggle(); m.overlays[keyPath:keys[j]].toggle()
                _ = preview(m.project,m.overlays)
                m.overlays[keyPath:keys[i]].toggle(); m.overlays[keyPath:keys[j]].toggle()
                XCTAssertEqual(preview(m.project,m.overlays),baseline)
                XCTAssertEqual(m.project.exportMarks,marks)
            } }
        }
    }

    func testOptionalCountsCustomGutterCoverModeAndLayoutSwitchesPreserveInactiveValues() throws {
        let m = Workspace(); m.project = fixture(.stepAndRepeat)
        func checkOptional(_ name:String,_ value:Binding<Int?>) {
            let binding = m.optionalCountBinding(value,name:name,defaultValue:17)
            let before = ImpositionPlanner.plan(m.project)
            let original = value.wrappedValue
            binding.wrappedValue = false; binding.wrappedValue = true
            XCTAssertEqual(value.wrappedValue,original,name)
            XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,before.sheets,name)
        }
        checkOptional("columns",Binding(get:{m.project.stepAndRepeat.columns},set:{m.project.stepAndRepeat.columns = $0}))
        checkOptional("rows",Binding(get:{m.project.stepAndRepeat.rows},set:{m.project.stepAndRepeat.rows = $0}))
        checkOptional("quantity",Binding(get:{m.project.stepAndRepeat.quantity},set:{m.project.stepAndRepeat.quantity = $0}))
        m.project.sheet.gutter = 9; m.project.stepAndRepeat.arrangement = .custom
        let custom = ImpositionPlanner.plan(m.project)
        m.setRepeatArrangement(.adjacent); m.setRepeatArrangement(.custom)
        XCTAssertEqual(m.project.sheet.gutter,9)
        XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,custom.sheets)
        m.project.serialFields[0].sides = .both
        let serials = m.project.serialFields, duplex = ImpositionPlanner.plan(m.project)
        m.setPageLayout(.simplex); m.setPageLayout(.duplex)
        XCTAssertEqual(m.project.serialFields,serials)
        XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,duplex.sheets)
        m.setMode(.saddleStitch)
        m.project.book?.selection.front = 3; m.project.book?.selection.insideFront = 4
        let selection = m.bookSettings.selection, book = ImpositionPlanner.plan(m.project)
        m.setCoverMode(.separate); m.setCoverMode(.included)
        XCTAssertEqual(m.bookSettings.selection,selection)
        XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,book.sheets)
    }
    func testBleedAmountLinkageCanBeRevertedWithoutChangingGuides() {
        for mode in [BindingMethod.stepAndRepeat,.gang,.saddleStitch,.spiral] {
            let m = Workspace(); m.project = fixture(mode)
            m.editableGeneratedBleed.enabled = false
            let amount = m.workflowBleed, plan = ImpositionPlanner.plan(m.project), overlays = m.overlays
            m.workflowBleed = amount+0.5
            XCTAssertTrue(m.editableGeneratedBleed.enabled)
            m.workflowBleed = amount
            XCTAssertFalse(m.editableGeneratedBleed.enabled)
            XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,plan.sheets)
            XCTAssertEqual(m.overlays,overlays)
            m.workflowBleed = amount // Typing the same amount still activates generation.
            XCTAssertTrue(m.editableGeneratedBleed.enabled)
        }
    }

    func testSerialTypeAndManualDigitsAndFixedWasteRoundTrips() {
        let m = Workspace(); m.project = fixture(.stepAndRepeat)
        m.project.serialFields[0].code = nil; m.project.serialFields[0].color = .rgb(1,0,0)
        let id = m.project.serialFields[0].id
        let before = ImpositionPlanner.plan(m.project), original = m.project.serialFields
        let kind = m.serialKindBinding(id)
        for type in [SerialCodeSettings.Kind.qr,.code128] {
            kind.wrappedValue = type
            kind.wrappedValue = .text
            XCTAssertEqual(m.project.serialFields,original)
            XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,before.sheets)
        }
        m.project.stepAndRepeat.quantity = 1234
        m.setSerialDigits(1,id:id)
        m.project.serialFields[0].fixedDigits = nil // Legacy manual fallback must round-trip too.
        let manual = m.project.serialFields
        let digits = m.serialManualDigitsBinding(id)
        digits.wrappedValue = false
        XCTAssertGreaterThan(m.project.serialFields[0].digits,1)
        digits.wrappedValue = true
        XCTAssertEqual(m.project.serialFields,manual)
        var waste = m.workflowWaste; waste.mode = .fixed; waste.fixed = 7; m.workflowWaste = waste
        let fixed = ImpositionPlanner.plan(m.project), percentage = m.workflowWastePercent
        m.workflowWastePercent = percentage+1
        XCTAssertEqual(m.workflowWaste.mode,.percent)
        m.workflowWastePercent = percentage
        XCTAssertEqual(m.workflowWaste.mode,.fixed)
        XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,fixed.sheets)
        m.setJobPageLayout(frontPage:1,mode:.simplex)
        m.setJobPageLayout(frontPage:1,mode:.automatic)
        XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,fixed.sheets)
    }

}
