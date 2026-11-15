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
            if !model.loading && !model.planning && !model.autoArranging && !model.samplingBleed {return}
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
        let fields=InspectorPanel.allCases.flatMap(InspectorRegistry.fields)
        XCTAssertEqual(Set(fields),Set(AutoLayoutField.allCases))
        XCTAssertEqual(fields.count,Set(fields).count)
        for method in [BindingMethod.stepAndRepeat,.gang,.saddleStitch,.spiral] {
            var project=Workspace.newProject();project.binding=method
            XCTAssertEqual(InspectorPanel.visible(for:project).contains(.binding),project.isBooklet || project.isLeafBinding)
        }
        XCTAssertEqual(InspectorPanel.allCases.map(\.number),Array(1...9))
        let flat=InspectorPanel.visible(for:Workspace.newProject())
        XCTAssertEqual(InspectorPanel.neighbor(of:.job,step:-1,visible:flat),.job)
        XCTAssertEqual(InspectorPanel.neighbor(of:.scaling,step:1,visible:flat),.price)
        XCTAssertEqual(InspectorPanel.neighbor(of:.output,step:1,visible:flat),.output)
        XCTAssertEqual(InspectorPanel.neighbor(of:.serial,step:-1,visible:flat),.marks)
    }
    func testScrollSpySelectsVisibleSectionIncludingLastShortCard() {
        let frames:[InspectorPanel:CGRect] = [.job:CGRect(x:0,y:-160,width:400,height:150),.sheet:CGRect(x:0,y:-10,width:400,height:500),.bleed:CGRect(x:0,y:510,width:400,height:300)]
        XCTAssertEqual(InspectorRegistry.sectionInView(frames:frames,height:600),.sheet)
        XCTAssertEqual(InspectorRegistry.sectionInView(frames:[.job:CGRect(x:0,y:16,width:400,height:300)],height:600),.job)
        XCTAssertEqual(InspectorRegistry.sectionInView(frames:[.price:CGRect(x:0,y:-20,width:400,height:400),.output:CGRect(x:0,y:400,width:400,height:150)],height:600),.output)
        XCTAssertNil(InspectorRegistry.sectionInView(frames:[.job:CGRect(x:0,y:700,width:400,height:40)],height:600))
    }
    func testJumpAccordionFlyoutAndPersistenceDoNotEditProject() throws {
        let store=defaults(),model=Workspace(uiDefaults:store),before=try ProjectDocument(state:model.state).encoded()
        XCTAssertTrue(model.ui.railVisible);XCTAssertFalse(model.ui.accordion)
        let jump=model.ui.panelJump
        model.ui.jump(.marks)
        XCTAssertEqual(model.ui.activePanel,.marks);XCTAssertEqual(model.ui.flashingPanel,.marks)
        XCTAssertTrue(model.ui.expandedPanels.contains(.marks));XCTAssertNotEqual(model.ui.panelJump,jump)
        model.ui.accordion=true;model.ui.jump(.serial)
        XCTAssertEqual(model.ui.expandedPanels,[.serial])
        model.ui.jump(.scaling);XCTAssertEqual(model.ui.expandedPanels,[.scaling])
        model.ui.inspectorCollapsed=true;model.ui.jump(.price)
        XCTAssertEqual(model.ui.flyoutPanel,.price)
        model.ui.expandAllPanels();XCTAssertFalse(model.ui.accordion)
        XCTAssertEqual(model.ui.expandedPanels,Set(InspectorPanel.allCases))
        model.ui.collapseAllPanels();XCTAssertTrue(model.ui.expandedPanels.isEmpty)
        model.ui.accordion=true;model.ui.railVisible=false
        XCTAssertFalse(model.ui.inspectorCollapsed);XCTAssertNil(model.ui.flyoutPanel)
        let reopened=UsabilitySettings(defaults:store)
        XCTAssertFalse(reopened.railVisible);XCTAssertTrue(reopened.accordion)
        XCTAssertEqual(reopened.expandedPanels,model.ui.expandedPanels)
        model.ui.inspectorCollapsed=true
        XCTAssertTrue(model.ui.railVisible,"A collapsed inspector always leaves a reachable rail")
        XCTAssertEqual(try ProjectDocument(state:model.state).encoded(),before)
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
                XCTAssertLessThanOrEqual(occupied,max(0,width-16-(layout.overflow.isEmpty ? 0:44)))
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
            model.ui.accordion=true
            for panel in InspectorPanel.visible(for:model.project) {model.ui.jump(panel)}
            model.ui.inspectorCollapsed=true;model.ui.jump(.scaling)
            model.ui.railVisible=false;model.ui.expandAllPanels();model.ui.collapseAllPanels()
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
            XCTAssertEqual(bitmap.pixelsWide,1180);XCTAssertEqual(bitmap.pixelsHigh,760)
            model.editableSerialFields=[SerialField()];model.selectedSerialID=model.editableSerialFields.first?.id
            let bar=NSHostingView(rootView:ContextBar(model:model).environment(\.colorScheme,scheme))
            bar.appearance=host.appearance;bar.frame=CGRect(x:0,y:0,width:460,height:36);bar.layoutSubtreeIfNeeded()
            let narrow=try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in:bar.bounds));bar.cacheDisplay(in:bar.bounds,to:narrow)
            try narrow.representation(using:.png,properties:[:])?.write(to:artifacts.appendingPathComponent("ikon-context-narrow-\(scheme == .light ? "light" : "dark").png"))
            model.selectedSerialID=nil
        }
        let rail=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/InspectorRail.swift"))
        XCTAssertTrue(rail.contains(".accessibilityLabel(panel.title"));XCTAssertTrue(rail.contains(".onMoveCommand"));XCTAssertTrue(rail.contains(".focusable()"))
        let app=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/AtisPressApp.swift"))
        XCTAssertTrue(app.contains("KeyEquivalent(Character(String(panel.number)))"))
        for key in ["e","o"] {XCTAssertTrue(app.contains("keyboardShortcut(\""+key+"\")"))}
        XCTAssertTrue(app.contains("Simge çubuğunu göster"))
    }
}

private final class PanelTestWindow:NSWindow {
    override func constrainFrameRect(_ frameRect:NSRect,to screen:NSScreen?) -> NSRect {frameRect}
}

extension IconPanelTests {
    func testNativeInspectorScrollJumpAndScrollSpy() async throws {
        let model=Workspace(uiDefaults:defaults()),prices=PricingStore(url:try directory().appendingPathComponent("prices.json"))
        NSApplication.shared.finishLaunching()
        let host=NSHostingView(rootView:WorkspaceView(model:model,prices:prices))
        host.sizingOptions=[]
        host.frame=CGRect(origin:.zero,size:DesignSystem.minimumWindow)
        let window=PanelTestWindow(contentRect:host.bounds,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.contentView=host
        window.contentMinSize=DesignSystem.minimumWindow
        window.setContentSize(DesignSystem.minimumWindow)
        window.orderFront(nil)
        defer {window.contentView=nil;window.close()}
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(200))
        host.frame=CGRect(origin:.zero,size:DesignSystem.minimumWindow)
        host.layoutSubtreeIfNeeded()
        model.ui.jump(.output)
        try await Task.sleep(for:.milliseconds(700));host.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.ui.activePanel,.output)
        XCTAssertTrue(model.ui.expandedPanels.contains(.output))
        func views(_ parent:NSView) -> [NSView] {parent.subviews.flatMap{[$0]+views($0)}}
        let scrolls=views(host).compactMap{$0 as? NSScrollView}
        let inspector=try XCTUnwrap(scrolls.filter{$0.frame.width>350 && $0.frame.width<450}.max(by:{($0.documentView?.frame.height ?? 0)<($1.documentView?.frame.height ?? 0)}))
        XCTAssertGreaterThan(inspector.contentView.bounds.minY,0,"Jump should scroll the real inspector")
        inspector.contentView.scroll(to:.zero);inspector.reflectScrolledClipView(inspector.contentView)
        try await Task.sleep(for:.milliseconds(200));host.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.ui.activePanel,.job)
    }
}
