import XCTest
import SwiftUI
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class IconPanelTests:XCTestCase {
    private var root:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()}
    private func defaults() -> UserDefaults {
        let name="AtisPressIconPanels-"+UUID().uuidString,store=UserDefaults(suiteName:name)!
        addTeardownBlock {store.removePersistentDomain(forName:name)}
        return store
    }
    private func directory() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:url)}
        return url
    }
    private func fixture() throws -> URL {
        let url=try directory().appendingPathComponent("cards.pdf")
        var box=CGRect(x:0,y:0,width:85*72/25.4,height:55*72/25.4)
        let context=try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&box,nil))
        for number in 1...12 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray:Double(number)/16,alpha:1));context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    private func settle(_ model:Workspace) async throws {
        for _ in 0..<600 {
            if !model.loading && !model.planning && !model.autoArranging {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Workspace did not settle")
    }
    func testRegistryOwnsEveryLegacySettingAndAllAutomaticFieldsExactlyOnce() {
        for (editor,paths) in WorkflowSettingsBefore.byEditor {
            XCTAssertTrue(paths.isSubset(of:InspectorRegistry.settingsByEditor[editor] ?? []),editor)
        }
        let settings=InspectorRegistry.settings
        XCTAssertEqual(Set(settings.map(\.id)).count,settings.count)
        XCTAssertGreaterThanOrEqual(settings.count,269)
        for setting in settings {
            XCTAssertTrue(InspectorPanel.allCases.contains(setting.panel),setting.id)
            XCTAssertFalse(setting.panel.title.isEmpty)
        }
        XCTAssertEqual(InspectorRegistry.owner(editor:"InspectorView",path:"model.overlays.bleed"),.sheet)
        XCTAssertEqual(InspectorRegistry.owner(editor:"InspectorView",path:"sheet.margins.left"),.dimensions)
        XCTAssertEqual(InspectorRegistry.owner(editor:"InspectorView",path:"model.editableGeneratedBleed.enabled"),.dimensions)
        let fields=InspectorPanel.allCases.flatMap(InspectorRegistry.fields)
        XCTAssertEqual(Set(fields),Set(AutoLayoutField.allCases))
        XCTAssertEqual(fields.count,Set(fields).count)
    }

    func testSidebarSeparatesPressAndColorAndPreservesNumberShortcuts() {
        let model = Workspace(uiDefaults: defaults())
        let tabs = InspectorPanel.allCases
        XCTAssertEqual(tabs.map(\.title), ["İş", "Tabaka", "Montaj", "Ölçüler", "Kesim", "İş Ayır", "Seri No", "Baskı", "Renk", "Fiyat", "Çıktı"])
        XCTAssertEqual(InspectorPanel.neighbor(of: .job, step: -1, visible: tabs), .job)
        XCTAssertEqual(InspectorPanel.neighbor(of: .sheet, step: 1, visible: tabs), .montage)
        XCTAssertEqual(InspectorPanel.neighbor(of: .cut, step: 1, visible: tabs), .separation)
        XCTAssertEqual(InspectorPanel.neighbor(of: .output, step: 1, visible: tabs), .output)
        XCTAssertEqual(InspectorPanel.shortcuts.prefix(9).map(\.id), Array(1...9))
        XCTAssertEqual(InspectorPanel.shortcuts.prefix(9).map(\.group), [.jobBasics, .paper, .edges, .bleed, .printedMarks, .serialFields, .scale, .binding, .cost])
        let addedShortcuts = InspectorPanel.shortcuts.suffix(2)
        XCTAssertEqual(addedShortcuts.map(\.panel),[.press,.color])
        XCTAssertEqual(addedShortcuts.map(\.group),[.production,.tone])
        XCTAssertEqual(addedShortcuts.map(\.displayShortcut),["⌥⌘B","⌥⌘R"])
        XCTAssertTrue(addedShortcuts.allSatisfy { $0.isAvailable(for: model.project) })
        XCTAssertEqual(InspectorPanel.neighbor(of: .press,step: 1,visible: tabs),.color)
        XCTAssertEqual(InspectorPanel.neighbor(of: .color,step: -1,visible: tabs),.press)
        var book = Workspace.newProject()
        book.binding = .saddleStitch
        let bindingShortcut = InspectorPanel.shortcuts[7]
        XCTAssertFalse(bindingShortcut.isAvailable(for: model.project))
        XCTAssertTrue(bindingShortcut.isAvailable(for: book))
        XCTAssertEqual(bindingShortcut.destination(for: book), .cover)
        book.binding = .spiral
        XCTAssertTrue(bindingShortcut.isAvailable(for: book))
        XCTAssertEqual(bindingShortcut.destination(for: book), .binding)

        XCTAssertEqual(InspectorRegistry.owner(editor: "SourcePageTools", path: "hiddenGuideGroups"), .separation)
        XCTAssertEqual(InspectorRegistry.owner(editor: "TeamInspectorView", path: "manualLayouts"), .montage)
        XCTAssertEqual(InspectorRegistry.owner(editor: "InternalCutMarksView", path: "internalCutJobs"), .cut)
        XCTAssertEqual(InspectorRegistry.owner(.exportCrop), .cut)
        XCTAssertEqual(InspectorRegistry.owner(.exportColorBar), .color)
        XCTAssertEqual(InspectorRegistry.owner(.exportSheetInfo), .press)
        XCTAssertEqual(InspectorRegistry.owner(.exportTargets), .press)
        XCTAssertEqual(InspectorRegistry.owner(.exportTargetSize), .press)
        XCTAssertTrue(InspectorPanel.sheet.groups(for: model.project).contains(.preview))
        XCTAssertEqual(InspectorPanel.cut.groups(for: model.project),[.printedMarks,.internalCuts,.cutMeasures])
        XCTAssertEqual(InspectorPanel.press.groups(for: model.project),[.production,.registration,.sheetInfo])
        XCTAssertEqual(InspectorRegistry.owner(.columns), .montage)
        XCTAssertEqual(InspectorPanel.color.groups(for: model.project), [.tone, .colorControls, .colorSizes, .colorInfo])
        XCTAssertEqual(InspectorPanel.output.groups(for: model.project), [.output, .preflight])
        XCTAssertEqual(InspectorPanel.montage.groups(for: model.project), [.products, .placement, .jobFaces])
        model.setMode(.gang)
        XCTAssertEqual(InspectorPanel.montage.groups(for: model.project), [.products, .placement])
        model.ui.inspectorCollapsed = true
        model.reveal(ValidationIssue(.error, .gangLayout, "Ürün yerleşimi tabakaya sığmıyor."))
        XCTAssertEqual(model.ui.activePanel, .montage)
        XCTAssertEqual(model.ui.flyoutPanel, .montage)
    }

    func testDisclosureDefaultsShortcutOpeningAndLegacyPanelMigration() throws {
        let store = defaults()
        for (legacy, panel): (String, InspectorPanel) in [("edges", .dimensions), ("bleed", .dimensions),
            ("scaling", .dimensions), ("marks", .cut), ("binding", .montage), ("color", .color), ("press", .press)] {
            store.set(legacy, forKey: "atispress.ui.activePanel")
            XCTAssertEqual(UsabilitySettings(defaults: store).activePanel, panel)
        }
        let model = Workspace(uiDefaults: store)
        let before = try ProjectDocument(state: model.state).encoded()
        XCTAssertTrue(model.ui.isGroupExpanded(.edges, in: .dimensions, for: model.project))
        XCTAssertTrue(model.ui.isGroupExpanded(.bleed, in: .dimensions, for: model.project))
        XCTAssertFalse(model.ui.isGroupExpanded(.generatedBleed, in: .dimensions, for: model.project))
        XCTAssertFalse(model.ui.isGroupExpanded(.preview, in: .sheet, for: model.project))
        XCTAssertFalse(model.ui.isGroupExpanded(.colorSizes, in: .color, for: model.project))
        model.ui.inspectorCollapsed = true
        model.ui.jump(.dimensions, opening: .scale)
        XCTAssertEqual(model.ui.flyoutPanel, .dimensions)
        XCTAssertEqual(model.ui.groupRequest?.group, .scale)
        XCTAssertTrue(model.ui.isGroupExpanded(.scale, in: .dimensions, for: model.project))
        model.ui.setGroupExpanded(.scale, false)
        model.ui.jump(.color)
        model.ui.jump(.dimensions)
        XCTAssertFalse(model.ui.isGroupExpanded(.scale, in: .dimensions, for: model.project))
        XCTAssertEqual(try ProjectDocument(state: model.state).encoded(), before)
    }

    func testPanelSelectionFlyoutAndPersistenceDoNotEditProject() throws {
        let store=defaults(),model=Workspace(uiDefaults:store)
        let before=try ProjectDocument(state:model.state).encoded()
        XCTAssertEqual(model.ui.activePanel,.job)
        for panel in InspectorPanel.allCases {
            model.ui.jump(panel)
            XCTAssertEqual(model.ui.activePanel,panel)
            XCTAssertEqual(UsabilitySettings(defaults:store).activePanel,panel)
        }
        model.ui.inspectorCollapsed=true;model.ui.jump(.cut)
        XCTAssertEqual(model.ui.flyoutPanel,.cut)
        model.ui.railVisible=false
        XCTAssertFalse(model.ui.inspectorCollapsed);XCTAssertNil(model.ui.flyoutPanel)
        XCTAssertEqual(try ProjectDocument(state:model.state).encoded(),before)
    }
    func testEmptyWorkspaceNeverPlansOrDisplaysValidationErrors() async throws {
        let model=Workspace(uiDefaults:defaults())
        model.schedulePlan();try await settle(model)
        XCTAssertTrue(model.plan.sheets.isEmpty)
        XCTAssertTrue(model.plan.issues.isEmpty)
        XCTAssertTrue(model.workflowIssues.isEmpty)
        XCTAssertFalse(model.planning)
        XCTAssertFalse(model.canExportNow)
        XCTAssertFalse(model.plan.canExport)
        XCTAssertEqual(model.statusSummary,"PDF seçin")
    }
    func testGangJobsStillPlanWithoutTheLegacyPageArray() async throws {
        let model=Workspace(uiDefaults:defaults())
        var project=Workspace.newProject();project.binding = .gang
        var gang=GangSettings()
        gang.jobs=[GangJob(sourceID:UUID(),name:"Kart",front:SourcePage(number:1,trimSize:Size(85,55),availableBleed:3))]
        project.gang=gang;model.project=project
        try await settle(model)
        XCTAssertTrue(model.project.hasPanelItems)
        XCTAssertFalse(model.plan.sheets.isEmpty)
    }
    func testContextFollowsSelectionAndOverflowPreservesPriority() {
        let model=Workspace(uiDefaults:defaults())
        XCTAssertEqual(ContextPresentation.kind(model),.flat)
        model.project.binding = .saddleStitch
        XCTAssertEqual(ContextPresentation.kind(model),.book)
        model.project.binding = .spiral
        XCTAssertEqual(ContextPresentation.kind(model),.book)
        model.project.binding = .stepAndRepeat;model.selectedPages=[1]
        XCTAssertEqual(ContextPresentation.kind(model),.job)
        let field=SerialField();model.editableSerialFields=[field];model.selectedSerialID=field.id
        XCTAssertEqual(ContextPresentation.kind(model),.serial)
        model.showingPageSplit=true;XCTAssertEqual(ContextPresentation.kind(model),.split)
        model.showingPageSplit=false;model.showingSourceGuides=true
        XCTAssertEqual(ContextPresentation.kind(model),.guides)
        for kind in [ContextKind.flat,.book,.serial,.job,.split,.guides] {
            let controls=ContextPresentation.controls(kind)
            for width:CGFloat in [0,100,400,720,1180,2000] {
                let layout=ContextPresentation.layout(controls,width:width)
                XCTAssertLessThanOrEqual(layout.visible.count,8)
                XCTAssertEqual(layout.visible+layout.overflow,controls)
                XCTAssertEqual(layout.visible,Array(controls.prefix(layout.visible.count)))
                let occupied=layout.visible.reduce(CGFloat(0)){$0+$1.width+8}
                XCTAssertLessThanOrEqual(occupied,max(0,width-24-(layout.overflow.isEmpty ? 0:44)))
            }
        }
        XCTAssertEqual(ContextPresentation.layout(ContextPresentation.controls(.serial),width:2000).overflow,[.center])
    }
    func testSharedBindingsAreTwoWayAndEachChangeIsOneUndoStep() {
        let operations:[(ContextBindings)->Void] = [
            {$0.quantity.wrappedValue=123},
            {$0.orientation.wrappedValue = .landscape},
            {$0.production.wrappedValue = .offset},
            {$0.crop.wrappedValue.toggle()},
            {$0.bleed.wrappedValue=5},
            {$0.bleedEnabled.wrappedValue.toggle()},
            {$0.waste.wrappedValue=7},
            {$0.sheet.wrappedValue="A4"},
            {$0.arrangement.wrappedValue = .spaced}
        ]
        for operation in operations {
            let model=Workspace(uiDefaults:defaults()),bar=ContextBindings(model:model)
            let original=model.project
            operation(bar)
            XCTAssertNotEqual(model.project,original)
            model.undoEdit();XCTAssertEqual(model.project,original)
            XCTAssertFalse(model.canUndo,"A control edit must not leave a second undo entry")
        }
        let model=Workspace(uiDefaults:defaults()),bar=ContextBindings(model:model)
        model.basicQuantity=456;XCTAssertEqual(bar.quantity.wrappedValue,456)
        model.project.exportMarks.crop=false;XCTAssertFalse(bar.crop.wrappedValue)
        model.workflowBleed=6;XCTAssertEqual(bar.bleed.wrappedValue,6)
        var field=SerialField();field.position=Point(5,7);model.editableSerialFields=[field]
        let x=bar.serial(field.id,\.position.x,fallback:0)
        x.wrappedValue=24;XCTAssertEqual(model.editableSerialFields[0].position.x,24)
        model.editableSerialFields[0].position.x=13;XCTAssertEqual(x.wrappedValue,13)
        model.project.binding = .gang
        let page=SourcePage(number:1,trimSize:Size(85,55))
        let job=GangJob(sourceID:UUID(),name:"Kart",front:page)
        var gang=GangSettings();gang.jobs=[job];model.project.gang=gang;model.selectedGangJobID=job.id
        bar.quantity.wrappedValue=72;XCTAssertEqual(model.selectedGangJob?.quantity,72)
        XCTAssertEqual(model.project.stepAndRepeat.quantity,456)
    }
    func testDockAndContextViewStateKeepAllModePlansPDFsAndProjectRoundTripsIdentical() async throws {
        let sourceURL=try fixture(),source=try await PDFSource.open(sourceURL),dir=try directory()
        for mode in [BindingMethod.stepAndRepeat,.gang,.saddleStitch,.spiral] {
            let model=Workspace(bookmarkCreator:{try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)},uiDefaults:defaults())
            model.open(sourceURL,confirmChanges:false);try await settle(model)
            model.setMode(mode);try await settle(model)
            var project=Project(pages:source.pages.map(\.sourcePage),binding:mode,sheet:SheetSpec(size:Size(450,320),margins:Insets(left:10,right:10,top:10,bottom:10),gripperWidth:0,gutter:6),settings:ImpositionSettings(bleed:0))
            project.settings.generatedBleed.enabled=false
            project.settings.signatureSize = .eight
            project.autoLayout = .legacy
            project.stepAndRepeat.quantity=5
            if mode == .gang {project.gang=model.project.gang}
            model.project=project
            let state=try ProjectDocument(state:model.state).encoded(),before=ImpositionPlanner.plan(model.project)
            func pixels(_ plan:ImpositionPlan,_ name:String) throws -> [Data] {
                let file=dir.appendingPathComponent(mode.rawValue+name+".pdf")
                _ = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(file),marks:model.project.exportMarks)
                let doc=try XCTUnwrap(CGPDFDocument(file as CFURL))
                return try (1...doc.numberOfPages).map {number in
                    let bitmap=try XCTUnwrap(CGContext(data:nil,width:320,height:240,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                    let page=try XCTUnwrap(doc.page(at:number))
                    bitmap.setFillColor(CGColor(gray:1,alpha:1));bitmap.fill(CGRect(x:0,y:0,width:320,height:240))
                    bitmap.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(x:0,y:0,width:320,height:240),rotate:0,preserveAspectRatio:true));bitmap.drawPDFPage(page)
                    return Data(bytes:try XCTUnwrap(bitmap.data),count:bitmap.bytesPerRow*bitmap.height)
                }
            }
            let baseline=try pixels(before,"before")
            for panel in InspectorPanel.allCases {model.ui.jump(panel)}
            model.ui.inspectorCollapsed=true;model.ui.jump(.dimensions, opening: .scale)
            model.ui.railVisible=false
            model.selectedPages=[1];_ = ContextPresentation.kind(model);model.selectedPages=[]
            XCTAssertEqual(try ProjectDocument(state:model.state).encoded(),state)
            let after=ImpositionPlanner.plan(model.project)
            XCTAssertEqual(before.sheets,after.sheets);XCTAssertEqual(before.issues,after.issues)
            XCTAssertEqual(try pixels(after,"after"),baseline)
            let restored=try ProjectDocument.decode(state).state.project
            XCTAssertEqual(ImpositionPlanner.plan(restored).sheets,before.sheets)
            XCTAssertEqual(try pixels(ImpositionPlanner.plan(restored),"restored"),baseline)
        }
    }
    func testMinimumWindowAndNarrowContextRenderInLightAndDarkWithAccessibleLabels() async throws {
        let model=Workspace(uiDefaults:defaults()),dir=try directory(),url=try fixture()
        model.open(url,confirmChanges:false);try await settle(model)
        model.project.autoLayout = .legacy
        let prices=PricingStore(url:dir.appendingPathComponent("prices.json"))
        let artifacts=root.appendingPathComponent(".build/WorkflowQA")
        try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
        for scheme in [ColorScheme.light,.dark] {
            let host=NSHostingView(rootView:WorkspaceView(model:model,prices:prices).environment(\.colorScheme,scheme))
            host.appearance=NSAppearance(named:scheme == .light ? .aqua : .darkAqua)
            host.frame=CGRect(origin:.zero,size:DesignSystem.minimumWindow);host.layoutSubtreeIfNeeded()
            let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:artifacts.appendingPathComponent("ikon-panel-\(scheme == .light ? "light" : "dark").png"))
            XCTAssertEqual(bitmap.pixelsWide,1180);XCTAssertEqual(bitmap.pixelsHigh,800)
            model.editableSerialFields=[SerialField()];model.selectedSerialID=model.editableSerialFields.first?.id
            let bar=NSHostingView(rootView:ContextBar(model:model).environment(\.colorScheme,scheme))
            bar.appearance=host.appearance;bar.frame=CGRect(x:0,y:0,width:460,height:56);bar.layoutSubtreeIfNeeded()
            let narrow=try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in:bar.bounds));bar.cacheDisplay(in:bar.bounds,to:narrow)
            try narrow.representation(using:.png,properties:[:])?.write(to:artifacts.appendingPathComponent("ikon-context-narrow-\(scheme == .light ? "light" : "dark").png"))
            model.selectedSerialID=nil
        }
        let rail=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/InspectorRail.swift"))
        XCTAssertTrue(rail.contains(".accessibilityLabel(panel.title"));XCTAssertTrue(rail.contains(".onMoveCommand"));XCTAssertTrue(rail.contains(".focusable()"))
        let app=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/AtisPressApp.swift"))
        XCTAssertTrue(app.contains("KeyEquivalent(shortcut.key)"))
        for key in ["e","o"] {XCTAssertTrue(app.contains("keyboardShortcut(\""+key+"\")"))}
        XCTAssertTrue(app.contains("Simge çubuğunu göster"))
    }
}

extension IconPanelTests {
    func testEveryGroupCanBeOpenedInHostedPanelAcrossJobModes() async throws {
        let model = Workspace(uiDefaults: defaults())
        let prices = PricingStore(url: try directory().appendingPathComponent("prices.json"))
        model.open(try fixture(), confirmChanges: false)
        try await settle(model)
        for mode in [BindingMethod.stepAndRepeat, .gang, .saddleStitch, .perfectBound, .spiral] {
            model.setMode(mode)
            try await settle(model)
            if model.project.isBooklet { model.enableBookSettings(); try await settle(model) }
            if mode == .stepAndRepeat { model.addSerialField(); try await settle(model) }
            var seen = Set<InspectorGroup>()
            for panel in InspectorPanel.allCases {
                let groups = panel.groups(for: model.project)
                XCTAssertFalse(groups.isEmpty, panel.title)
                let host = NSHostingView(rootView: InspectorView(model: model, prices: prices))
                host.frame = CGRect(x: 0, y: 0, width: 350, height: 743)
                for group in groups {
                    XCTAssertTrue(seen.insert(group).inserted, group.title)
                    model.ui.jump(panel, opening: group)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(model.ui.activePanel, panel)
                    XCTAssertTrue(model.ui.isGroupExpanded(group, in: panel, for: model.project))
                }
            }
            XCTAssertTrue(seen.isSuperset(of: [.method, .placement, .scale, .internalCuts, .separation,
                                              .serialContent, .production, .tone, .colorControls, .preview, .colorSizes, .colorInfo, .registration, .sheetInfo, .preflight]))
            XCTAssertEqual(seen.contains(.cover), model.project.isBooklet || model.project.isLeafBinding)
        }
    }
    func testPanelAndContextTypographyAndNavigationDefinitions() throws {
        for file in ["InspectorRail","InspectorView","ContextBar"] {
            let text=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/"+file+".swift"))
            let pattern=try NSRegularExpression(pattern:#"size:\s*(\d+)"#)
            for match in pattern.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
                let value=Int((text as NSString).substring(with:match.range(at:1)))!
                XCTAssertGreaterThanOrEqual(value,12,file)
            }
            XCTAssertFalse(text.contains("scrollSpy"))
        }
        let rail=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/InspectorRail.swift"))
        XCTAssertFalse(rail.contains("Tümünü"));XCTAssertFalse(rail.contains("Ayarlar"))
        let inspector = try String(contentsOf: root.appendingPathComponent("Sources/AtisPressApp/InspectorView.swift"))
        XCTAssertTrue(inspector.contains("DisclosureGroup"))
        XCTAssertFalse(inspector.contains("Alt grup"))
        XCTAssertTrue(rail.contains(".onMoveCommand"));XCTAssertTrue(rail.contains(".accessibilityLabel"))
    }
}
