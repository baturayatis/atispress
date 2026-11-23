import XCTest
import AppKit
import PDFKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class BookWorkspaceTests: XCTestCase {
    private func model(uiDefaults: UserDefaults = .standard) -> Workspace {
        Workspace(bookmarkCreator:{ try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil) },uiDefaults:uiDefaults)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    private func fixture(_ folder: URL,_ name: String,count: Int,size: Size) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var rect = CGRect(x:0,y:0,width:size.width*72/25.4,height:size.height*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&rect,nil))
        for _ in 0..<count { context.beginPDFPage(nil); context.setFillColor(CGColor(gray:0.3,alpha:1)); context.fill(CGRect(x:rect.width*0.1,y:rect.height*0.1,width:rect.width*0.2,height:rect.height*0.7)); context.endPDFPage() }
        context.closePDF(); return url
    }
    private func settle(_ workspace: Workspace) async throws {
        for _ in 0..<1000 {
            if !workspace.loading && !workspace.planning && !workspace.autoArranging { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Book workspace did not settle")
    }
    private func prepare(_ workspace: Workspace,_ source: URL,binding: BindingMethod) async throws {
        workspace.open(source); try await settle(workspace); workspace.setMode(binding)
        workspace.enableBookSettings(); workspace.bookSettings.interiorPaper.microns = 120; workspace.bookSettings.coverPaper.microns = 250
        workspace.project.sheet = SheetSpec(preset:.cm50x70)
        workspace.project.settings.signatureSize = .eight
        try await settle(workspace)
    }
    func testCoverPreparationRightPanelAndProjectRoundTripDoNotChangeInterior() async throws {
        let folder = try folder()
        let pdf = try fixture(folder,"cover-preparation.pdf",count:8,size:Size(50,70))
        let workspace = model()
        workspace.open(pdf); try await settle(workspace)
        workspace.setProductionBinding(.perfectBound)
        workspace.project.sheet = SheetSpec(preset:.cm50x70)
        try await settle(workspace)
        let interior = workspace.plan.sheets
        let pages = workspace.project.pages
        let url = folder.appendingPathComponent("cover.atispress")
        try workspace.saveProject(as:url)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        old["version"] = 29
        try JSONSerialization.data(withJSONObject:old).write(to:url)
        let suite = "atispress-cover-preparation-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let reopened = model(uiDefaults:defaults)
        try await reopened.loadProject(at:url); try await settle(reopened)
        XCTAssertNil(reopened.project.coverPreparation)
        XCTAssertEqual(reopened.plan.sheets,interior)
        XCTAssertEqual(reopened.coverPreparationPlan(.spread).sheets.first?.front.slots.compactMap(\.sourcePageNumber),[8,1])
        reopened.ui.jump(.coverPreparation)
        XCTAssertEqual(reopened.ui.activePanel.title,"Kapak")
        XCTAssertEqual(reopened.ui.activePanel.groups(for:reopened.project),[.coverPreparation])
        XCTAssertFalse(reopened.isModified)
        reopened.coverPreparation.front = 2
        reopened.coverPreparation.back = 7
        reopened.coverPreparation.spineWidth = 6
        reopened.coverPreparation.colorMode = .manual
        reopened.coverPreparation.color = .cmyk(0,0.3,0.8,0.1)
        reopened.coverPreparation.colorMode = .picked
        reopened.coverPreparation.pickedColor = .rgb(0.15,0.25,0.4)
        var text = SpineContent.TextBlock()
        text.text = "İğne ve Çığ"
        text.autoFit = true
        reopened.coverPreparation.spineText = [.top:text]
        let logoFile = try fixture(folder,"logo.pdf",count:1,size:Size(10,10))
        reopened.coverPreparation.spineLogo = try XCTUnwrap(PDFSpine.makeLogo(name:"logo.pdf",format:.pdf,
            data:Data(contentsOf:logoFile),in:CGRect(x:0,y:0,width:6,height:70)))
        let trim = CGRect(x:0,y:0,width:6,height:70)
        let oldTextBounds = try XCTUnwrap(PDFSpine.layout(text,at:.top,in:trim)).bounds
        let legacy = try ProjectDocument(version:30,state:reopened.state).encoded()
        let migrated = try XCTUnwrap(ProjectDocument.decode(legacy).state.project.coverPreparation)
        XCTAssertNil(migrated.spineText)
        XCTAssertNil(migrated.spineLogo)
        XCTAssertEqual(migrated.spineObjects?.count,2)
        XCTAssertEqual(PDFSpine.objectBounds(try XCTUnwrap(migrated.spineObjects?.first),in:trim),oldTextBounds)
        reopened.coverPreparation = migrated
        let original = reopened.preparedSpineObjects
        let logo = try XCTUnwrap(original.last)
        let bounds = try XCTUnwrap(PDFSpine.objectBounds(logo,in:trim))
        let gesture = SpineObjectInteraction(bounds:bounds,unit:0.5)
        let move = gesture.edited(logo,handle:.move,start:gesture.center,
                                  current:CGPoint(x:gesture.center.x+0.2,y:gesture.center.y+5.8))
        XCTAssertEqual(move.x,0)
        XCTAssertEqual(move.y,6)
        let resize = gesture.edited(logo,handle:.resize,start:gesture.resize,
                                   current:CGPoint(x:gesture.center.x+2*(gesture.resize.x-gesture.center.x),
                                                   y:gesture.center.y+2*(gesture.resize.y-gesture.center.y)))
        XCTAssertEqual(resize.size,2*logo.size,accuracy:0.00001)
        let rotated = gesture.edited(move,handle:.rotate,start:gesture.rotate,
                                    current:CGPoint(x:gesture.center.x-10,y:gesture.center.y))
        XCTAssertEqual(rotated.rotation,90)
        reopened.beginUndoGroup()
        reopened.editPreparedSpine(rotated)
        reopened.endUndoGroup()
        XCTAssertEqual(reopened.preparedSpineObjects.last,rotated)
        reopened.undoEdit()
        XCTAssertEqual(reopened.preparedSpineObjects,original)
        reopened.redoEdit()
        XCTAssertEqual(reopened.preparedSpineObjects.last,rotated)
        reopened.deletePreparedSpine(logo.id)
        XCTAssertEqual(reopened.preparedSpineObjects.count,1)
        reopened.undoEdit()
        try await settle(reopened)
        XCTAssertEqual(reopened.preparedSpineObjects.last,rotated)
        reopened.coverPreparation.bleed = 1
        reopened.coverPreparation.crop = false
        reopened.coverPreviewOutput = .spread
        let controls = ContextBindings(model:reopened)
        controls.sheetDimension(\.width).wrappedValue = 240
        controls.sheetDimension(\.height).wrappedValue = 170
        controls.orientation.wrappedValue = .landscape
        reopened.updateCoverImposition { $0.gap = 5 }
        XCTAssertEqual(reopened.coverPreviewOutput,.sheet)
        XCTAssertEqual(reopened.coverPreparationPlan(.sheet).sheets.first?.size,Size(240,170))
        reopened.coverPreparation.grid.columns = 1
        reopened.coverPreparation.grid.rows = 1
        reopened.coverPreparation.grid.x = 2
        XCTAssertEqual(reopened.project.pages,pages)
        try await settle(reopened)
        let updatedInterior = reopened.plan.sheets
        XCTAssertEqual(updatedInterior,ImpositionPlanner.plan(reopened.project).sheets)
        XCTAssertTrue(reopened.coverPreparationPlan(.sheet).canExport)
        XCTAssertFalse(reopened.coverPreparationMarks(.sheet).crop)
        try reopened.saveProject()
        let loaded = model()
        try await loaded.loadProject(at:url); try await settle(loaded)
        XCTAssertEqual(loaded.project.coverPreparation,reopened.project.coverPreparation)
        XCTAssertEqual(loaded.coverPreparationPlan(.spread).sheets,reopened.coverPreparationPlan(.spread).sheets)
        XCTAssertEqual(loaded.coverPreparationPlan(.sheet).sheets,reopened.coverPreparationPlan(.sheet).sheets)
        XCTAssertEqual(loaded.plan.sheets,updatedInterior)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf:url)).version,ProjectDocument.currentVersion)
    }

    func testCoverPreparationSharedControlsSyncThroughTabsAndLegacyMigration() async throws {
        let folder = try folder()
        let url = try fixture(folder,"stock.pdf",count:4,size:Size(100,140))
        let suite = "CoverStock."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let model = model(uiDefaults:defaults)
        model.open(url); try await settle(model)
        let toolbar = ContextBindings(model:model)
        model.ui.jump(.coverPreparation)
        toolbar.sheet.wrappedValue = "33×48"
        for (orientation,size) in [(Orientation.landscape,Size(480,330)),(.portrait,Size(330,480))] {
            toolbar.orientation.wrappedValue = orientation
            XCTAssertEqual(model.coverPreparationPlan(.sheet).sheets.first?.size,size)
        }
        toolbar.sheet.wrappedValue = "70×100"
        toolbar.orientation.wrappedValue = .landscape
        XCTAssertEqual(model.coverPreparationPlan(.sheet).sheets.first?.size,Size(1000,700))
        try await settle(model)
        XCTAssertEqual(model.currentSheet?.size,Size(1000,700))
        XCTAssertEqual(model.coverPreparation.effectiveSheet(for:model.project).orientation,.landscape)
        model.ui.jump(.job)
        model.ui.jump(.coverPreparation)
        XCTAssertEqual(toolbar.orientation.wrappedValue,.landscape)
        model.selectWorkflowOrientation(.portrait)
        XCTAssertEqual(toolbar.orientation.wrappedValue,.portrait)
        XCTAssertEqual(model.coverPreparationPlan(.sheet).sheets.first?.size,Size(700,1000))
        try await settle(model)
        XCTAssertEqual(model.currentSheet?.size,Size(700,1000))
        toolbar.orientation.wrappedValue = .auto
        XCTAssertTrue(model.coverPreparationPlan(.sheet).canExport)

        toolbar.machine.wrappedValue = MachineProfile.heidelberg.id
        XCTAssertEqual(model.project.machineProfile?.id,MachineProfile.heidelberg.id)
        XCTAssertEqual(model.coverPreparation.effectiveSheet(for:model.project).size,Size(700,1000))
        model.selectMachineProfile(nil)
        XCTAssertNil(toolbar.machine.wrappedValue)
        model.setWorkflowSheetDimension(\.width,812.5)
        XCTAssertEqual(toolbar.sheetDimension(\.width).wrappedValue,812.5)
        XCTAssertEqual(toolbar.sheet.wrappedValue,"Özel ölçü…")
        XCTAssertEqual(model.coverPreparationPlan(.spread).sheets.first?.front.slots.compactMap(\.sourcePageNumber),[4,1])
        model.coverPreparation.crop = false
        toolbar.crop.wrappedValue = true
        toolbar.registration.wrappedValue = true
        let sheetPlan = model.coverPreparationPlan(.sheet)
        let coverSheet = try XCTUnwrap(sheetPlan.sheets.first)
        let printMarks = model.coverPreparationMarks(.sheet)
        XCTAssertTrue(printMarks.crop)
        XCTAssertTrue(printMarks.registrationTargets)
        XCTAssertFalse(PDFColorControlRenderer.geometry(sheet:coverSheet,settings:printMarks).targets.isEmpty)
        XCTAssertFalse(model.coverPreparationMarks(.spread).registrationTargets)
        let out = folder.appendingPathComponent("marked-cover.pdf")
        let result = try PDFExporter.export(plan:sheetPlan,source:XCTUnwrap(model.source),destination:.singlePDF(out),marks:printMarks)
        XCTAssertEqual(result.pageCount,1)
        XCTAssertEqual(Set(coverSheet.front.slots.compactMap(\.sourcePageNumber)),[1,4])
        try await settle(model)
        let file = folder.appendingPathComponent("stock.atispress")
        try model.saveProject(as:file)
        let restored = self.model(uiDefaults:defaults)
        try await restored.loadProject(at:file); try await settle(restored)
        XCTAssertEqual(restored.project.sharedSheet,model.project.sharedSheet)
        XCTAssertEqual(restored.coverPreparationPlan(.sheet).sheets,model.coverPreparationPlan(.sheet).sheets)

        var legacy = model.state
        var cover = CoverPreparationSettings()
        cover.sheet = SheetSpec(size:Size(455,620),gutter:7,orientation:.landscape)
        cover.useProjectMachine = false
        cover.machine = MachineProfile.heidelberg
        legacy.project.coverPreparation = cover
        let migrated = try ProjectDocument.decode(ProjectDocument(version:31,state:legacy).encoded()).state.project
        XCTAssertEqual(migrated.sharedSheet.size,Size(455,620))
        XCTAssertEqual(migrated.sharedSheetOrientation,.landscape)
        XCTAssertEqual(migrated.machineProfile?.id,MachineProfile.heidelberg.id)
        XCTAssertEqual(migrated.coverPreparation?.gap,7)
        XCTAssertNil(migrated.coverPreparation?.sheet)
        XCTAssertNil(migrated.coverPreparation?.machine)
    }

    func testCoverPreparationCanvasDragSnapsInRotatedSheetCoordinates() async throws {
        let folder = try folder()
        let pdf = try fixture(folder,"drag.pdf",count:2,size:Size(50,70))
        let workspace = model()
        workspace.open(pdf); try await settle(workspace)
        workspace.coverPreparation.spineWidth = 15
        workspace.coverPreparation.grid.rotation = .ninety
        workspace.coverPreparation.grid.columns = 1
        workspace.coverPreparation.grid.rows = 1
        var text = SpineContent.TextBlock()
        text.text = "Çığ"
        let object = FreeSpineObject(content:.text(text))
        workspace.addPreparedSpine(object)
        let plan = workspace.coverPreparationPlan(.sheet)
        let sheet = try XCTUnwrap(plan.sheets.first)
        let spine = try XCTUnwrap(sheet.front.slots.first { $0.spineArtwork != nil })
        let bounds = try XCTUnwrap(PDFSpine.objectBounds(object,in:PDFPreviewDrawing.localTrim(spine)))
        let canvas = SheetCanvasView()
        canvas.preparedSpineModel = workspace
        canvas.beginEdit = workspace.beginUndoGroup
        canvas.endEdit = workspace.endUndoGroup
        canvas.configure(sheet:sheet,side:sheet.front,source:workspace.source,overlays:.artworkOnly,highlighted:[])
        let window = NSWindow(contentRect:canvas.bounds,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = canvas
        let slotTransform = PDFPreviewDrawing.slotTransform(spine)
        func mouse(_ type: NSEvent.EventType,_ local: CGPoint) throws -> NSEvent {
            let paper = local.applying(slotTransform)
            let view = CGPoint(x:32+paper.x*PDFPreviewDrawing.pointsPerMM,y:32+paper.y*PDFPreviewDrawing.pointsPerMM)
            return try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(view,to:nil),modifierFlags:[],
                timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        let center = CGPoint(x:bounds.midX,y:bounds.midY)
        let target = CGPoint(x:center.x+1.21,y:center.y+6.85)
        canvas.mouseDown(with:try mouse(.leftMouseDown,center))
        canvas.mouseDragged(with:try mouse(.leftMouseDragged,target))
        canvas.mouseUp(with:try mouse(.leftMouseUp,target))
        XCTAssertEqual(workspace.selectedPreparedSpineID,object.id)
        XCTAssertEqual(workspace.preparedSpineObjects.first?.x,1)
        XCTAssertEqual(workspace.preparedSpineObjects.first?.y,7)
        workspace.undoEdit()
        XCTAssertEqual(workspace.preparedSpineObjects.first,object)
    }

    func testModernCoverSpineBindingImportReplacementRemovalAndRoundTrip() async throws {
        let folder = try folder()
        let body = try fixture(folder,"body.pdf",count:10,size:Size(50,70))
        let cover = try fixture(folder,"spread.pdf",count:1,size:Size(108,70))
        let replacement = try fixture(folder,"panels.pdf",count:2,size:Size(50,70))
        let workspace = model()
        workspace.open(body); try await settle(workspace)
        workspace.setProductionBinding(.perfectBound)
        workspace.project.sheet = SheetSpec(preset:.cm50x70)
        try await settle(workspace)
        XCTAssertEqual(workspace.spineWidth,0)
        XCTAssertEqual(workspace.coverSheetTitle(at:0),"Kapak 1")
        XCTAssertTrue(workspace.canExportNow)
        XCTAssertEqual(InspectorPanel.montage.groups(for:workspace.project).filter {
            [.cover,.bookPaper,.spine].contains($0)
        },[])
        XCTAssertEqual(ContextControl.cover.title,"Sırt (mm)")
        XCTAssertTrue(ContextPresentation.controls(.book).contains(.cover))

        let context = ContextBindings(model:workspace)
        context.spine.wrappedValue = 8
        XCTAssertEqual(workspace.spineWidth,8)
        workspace.spineWidth = 7
        XCTAssertEqual(context.spine.wrappedValue,7)
        context.spine.wrappedValue = 8
        workspace.spineContent.mode = .text
        var block = SpineContent.TextBlock()
        block.text = "ĞÜÇ İŞ"
        block.autoFit = true
        workspace.spineContent.blocks[.middle] = block
        workspace.beginUndoGroup()
        workspace.moveSpineBlock(.middle,to:Point(1.2,-2.4))
        workspace.endUndoGroup()
        XCTAssertEqual(workspace.spineContent.blocks[.middle]?.x,1)
        XCTAssertEqual(workspace.spineContent.blocks[.middle]?.y,-2)
        workspace.undoEdit()
        XCTAssertEqual(workspace.spineContent.blocks[.middle],block)
        try await settle(workspace)

        workspace.loadCoverPDF(cover,automatic:true); try await settle(workspace)
        XCTAssertTrue(workspace.canExportNow,"\(workspace.plan.issues)")
        XCTAssertEqual(workspace.bookSettings.coverArtwork,.spread)
        XCTAssertEqual(workspace.pageSourceRecords.map(\.reference.fileName),["body.pdf","spread.pdf"])
        XCTAssertNil(workspace.plan.sheets.first?.front.slots.first?.spineArtwork)
        workspace.loadCoverPDF(replacement,automatic:true); try await settle(workspace)
        XCTAssertEqual(workspace.bookSettings.coverArtwork,.panels)
        XCTAssertEqual(workspace.pageSourceRecords.map(\.reference.fileName),["body.pdf","panels.pdf"])
        XCTAssertTrue(workspace.canExportNow,"\(workspace.plan.issues)")
        XCTAssertNotNil(workspace.plan.sheets.first?.front.slots.first { $0.spineArtwork != nil })
        let url = folder.appendingPathComponent("spine.atispress")
        try workspace.saveProject(as:url)
        let reopened = model()
        try await reopened.loadProject(at:url); try await settle(reopened)
        XCTAssertEqual(reopened.plan.sheets,workspace.plan.sheets)
        XCTAssertEqual(reopened.spineContent,workspace.spineContent)
        XCTAssertEqual(ContextBindings(model:reopened).spine.wrappedValue,8)

        try await reopened.removePageSource(XCTUnwrap(reopened.bookSettings.coverSourceID))
        try await settle(reopened)
        XCTAssertEqual(reopened.pageSourceRecords.map(\.reference.fileName),["body.pdf"])
        XCTAssertNil(reopened.bookSettings.coverSourceID)
        XCTAssertEqual(reopened.project.automaticCoverMode,.excluded)
        XCTAssertTrue(reopened.canExportNow,"\(reopened.plan.issues)")
        XCTAssertEqual(reopened.plan.sheets.first?.front.slots.compactMap(\.sourcePageNumber),[10,1])
    }

    func testSchema27MeasuredSpineRetainsCoverModeAndPlan() async throws {
        let folder = try folder()
        let pdf = try fixture(folder,"legacy-measured.pdf",count:12,size:Size(50,70))
        let workspace = model()
        try await prepare(workspace,pdf,binding:.perfectBound)
        workspace.bookSettings.leftFlap = 4
        workspace.bookSettings.coverAllowance = 0.3
        try await settle(workspace)
        let file = folder.appendingPathComponent("old.atispress")
        try workspace.saveProject(as:file)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        json["version"] = 27
        try JSONSerialization.data(withJSONObject:json).write(to:file)
        let reopened = model()
        try await reopened.loadProject(at:file); try await settle(reopened)
        XCTAssertEqual(reopened.project.coverMode,workspace.project.coverMode)
        XCTAssertEqual(reopened.plan.sheets,workspace.plan.sheets)
        XCTAssertEqual(reopened.spineWidth,0.78,accuracy:0.00001)
        XCTAssertEqual(reopened.spineContent.mode,.empty)
        XCTAssertFalse(reopened.isModified)
        try reopened.saveProject()
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf:file)).version,ProjectDocument.currentVersion)
    }

    func testSchemaTenRoundtripEveryBookSettingAndSharedPlan() async throws {
        let folder = try folder(),pdf = try fixture(folder,"book.pdf",count:20,size:Size(50,70)),workspace = model()
        try await prepare(workspace,pdf,binding:.perfectBound)
        workspace.project.coverMode = .excluded
        var selection = CoverSelection(); selection.front = 3; selection.insideFront = 4; selection.insideBack = 17; selection.back = 18
        workspace.bookSettings.selection = selection
        workspace.bookSettings.interiorPaper.input = .grammage; workspace.bookSettings.interiorPaper.grammage = 90; workspace.bookSettings.interiorPaper.bulk = 1.3
        workspace.bookSettings.coverPaper.input = .grammage; workspace.bookSettings.coverPaper.grammage = 250; workspace.bookSettings.coverPaper.bulk = 1.2
        workspace.bookSettings.coverAllowance = 0.4; workspace.bookSettings.adhesiveAllowance = 0.3
        workspace.bookSettings.leftFlap = 12; workspace.bookSettings.rightFlap = 18
        try await settle(workspace); workspace.showBookSection(.cover)
        XCTAssertEqual(workspace.currentSheet?.bookInfo?.section,.cover)
        XCTAssertTrue(workspace.plan.canExport,"\(workspace.plan.issues)")
        let url = folder.appendingPathComponent("book.atispress"); try workspace.saveProject(as:url)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf:url)).version,ProjectDocument.currentVersion)
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertEqual(opened.project,workspace.project); XCTAssertEqual(opened.plan.sheets,workspace.plan.sheets); XCTAssertFalse(opened.isModified)
        XCTAssertEqual(opened.currentSheet?.bookInfo?.section,.cover)
        opened.bookSettings.adhesiveAllowance = 0.6; try await settle(opened)
        XCTAssertTrue(opened.isModified); XCTAssertNotEqual(opened.currentSheet?.bookInfo?.spreadSize,workspace.currentSheet?.bookInfo?.spreadSize)
        opened.autoArrange(); try await settle(opened); XCTAssertEqual(opened.bookSettings,opened.project.book)
    }
    func testSeparateCoverLinkRoundtripRelinkAndOverwriteProtection() async throws {
        let folder = try folder(),body = try fixture(folder,"inside.pdf",count:8,size:Size(50,70)),cover = try fixture(folder,"cover.pdf",count:2,size:Size(100.48,70)),workspace = model()
        try await prepare(workspace,body,binding:.perfectBound)
        workspace.loadCoverPDF(cover); try await settle(workspace)
        workspace.bookSettings.coverArtwork = .spread; try await settle(workspace)
        XCTAssertEqual(workspace.project.coverMode,.separate); XCTAssertTrue(workspace.plan.canExport,"\(workspace.plan.issues)")
        XCTAssertEqual(workspace.project.bookInteriorPages.count,8); XCTAssertEqual(workspace.gangAssets.count,2)
        XCTAssertFalse(workspace.preflightRows.contains { $0.explanation.contains("Sayfa boyutları farklı") },"A separate cover spread is intentionally wider than interior pages")
        let url = folder.appendingPathComponent("linked.atispress"); try workspace.saveProject(as:url)
        let state = try ProjectDocument.decode(Data(contentsOf:url)).state
        XCTAssertEqual(state.linkedSources?.map(\.reference.path),[body.path,cover.path]); XCTAssertNil(state.source)
        XCTAssertFalse(String(data:try Data(contentsOf:url),encoding:.utf8)!.contains("AtisPress-gang-"))
        XCTAssertThrowsError(try workspace.saveProject(as:body)); XCTAssertThrowsError(try workspace.saveProject(as:cover))
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertEqual(opened.project,workspace.project); XCTAssertEqual(opened.plan.sheets,workspace.plan.sheets)
        XCTAssertEqual(opened.source?.displayName,"Kitap ve kapak")
        let moved = folder.appendingPathComponent("moved-cover.pdf"); try FileManager.default.copyItem(at:cover,to:moved); try FileManager.default.removeItem(at:cover)
        let relinked = model(); var names: [String] = []
        try await relinked.loadProject(at:url,relink:{ ref in names.append(ref.fileName); return moved }); try await settle(relinked)
        XCTAssertEqual(names,["cover.pdf"]); XCTAssertTrue(relinked.isModified); XCTAssertEqual(relinked.plan.sheets,workspace.plan.sheets)
        let untouched = model(),before = untouched.project
        do { try await untouched.loadProject(at:url,relink:{ _ in body }); XCTFail("Wrong cover must not load") } catch { XCTAssertEqual(untouched.project,before) }
    }
    func testLegacyVersionNineKeepsItsOriginalBookletAndNewSettingsAreOptIn() async throws {
        let folder = try folder(),pdf = try fixture(folder,"legacy.pdf",count:16,size:Size(50,70)),workspace = model()
        workspace.open(pdf); try await settle(workspace); workspace.setMode(.saddleStitch); try await settle(workspace)
        XCTAssertNil(workspace.project.book)
        let url = folder.appendingPathComponent("legacy.atispress"); try workspace.saveProject(as:url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]); object["version"] = 9
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertNil(opened.project.book); XCTAssertEqual(opened.plan.sheets,workspace.plan.sheets); XCTAssertFalse(opened.isModified)
        opened.enableBookSettings(); XCTAssertNil(opened.bookSettings.interiorPaper.millimetres); XCTAssertNil(opened.bookSettings.coverPaper.millimetres)
        try await settle(opened); XCTAssertTrue(opened.plan.sheets.contains { $0.bookInfo?.section == .cover })
    }
    func testCreepAndPaperInputsChangePreviewPixelsAndSummaryLive() async throws {
        let folder = try folder(),pdf = try fixture(folder,"creep.pdf",count:20,size:Size(50,70)),workspace = model()
        try await prepare(workspace,pdf,binding:.saddleStitch)
        workspace.project.sheet = SheetSpec(size:Size(120,90),orientation:.landscape)
        workspace.bookSettings.interiorPaper.microns = 1000; workspace.bookSettings.coverPaper.microns = 500
        try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport,"\(workspace.plan.issues)")
        workspace.sheetIndex = try XCTUnwrap(workspace.displaySheets.firstIndex { $0.bookInfo?.section == .interior })
        let off = try XCTUnwrap(workspace.currentSheet)
        workspace.bookSettings.creepEnabled = true; try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport,"\(workspace.plan.issues)")
        let on = try XCTUnwrap(workspace.currentSheet)
        XCTAssertNotEqual(off.front.slots.map(\.artworkOffset),on.front.slots.map(\.artworkOffset))
        func bitmap(_ sheet: Sheet) throws -> Data {
            let view = SheetCanvasView(); view.configure(sheet:sheet,side:sheet.front,source:workspace.source,overlays:.artworkOnly,highlighted:[])
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(ceil(view.frame.width)),pixelsHigh:Int(ceil(view.frame.height)),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep); view.draw(view.bounds); NSGraphicsContext.restoreGraphicsState()
            return try XCTUnwrap(rep.representation(using:.png,properties:[:]))
        }
        XCTAssertNotEqual(try bitmap(off),try bitmap(on))
        let before = on.bookInfo?.summary; workspace.bookSettings.coverPaper.microns = 700; try await settle(workspace)
        XCTAssertNotEqual(workspace.currentSheet?.bookInfo?.summary,before)
        workspace.bookSettings.interiorPaper.microns = nil; try await settle(workspace)
        XCTAssertTrue(workspace.canExportNow); XCTAssertTrue(workspace.currentSheet?.bookInfo?.summary.contains("hesaplanamadı") == true)
    }
    func testNewProjectImport106A5ThenBookletOnManualA4HasNoFoldGutter() async throws {
        let folder = try folder(),pdf = try fixture(folder,"new-A5-106.pdf",count:106,size:.init(148,210))
        for binding in [BindingMethod.saddleStitch,.perfectBound] {
            let workspace = model()
            XCTAssertEqual(workspace.project.binding,.stepAndRepeat)
            workspace.open(pdf); try await settle(workspace)
            XCTAssertEqual(workspace.project.pages.count,106)
            XCTAssertFalse(workspace.isManual(.gutter))
            workspace.setMode(binding)
            XCTAssertEqual(workspace.project.sheet.gutter,0)
            XCTAssertFalse(workspace.isManual(.gutter),"Mode switching is not a manual gutter edit")
            workspace.sheetPreset = "A4"; workspace.markManual(.sheetSize)
            workspace.project.sheet.size = SheetPreset.a4.size
            workspace.project.sheet.orientation = .landscape
            workspace.project.sheet.margins = Insets(); workspace.project.sheet.gripperWidth = 0
            workspace.project.settings.bleed = 0; workspace.project.exportMarks = .none
            // Deliberately never edit gutter: reproduce a fresh import/mode switch.
            try await settle(workspace)
            XCTAssertTrue(workspace.plan.canExport,workspace.plan.issues.map(\.message).joined(separator:"\n"))
            XCTAssertEqual(workspace.plan.sheets.count,27)
            XCTAssertEqual(workspace.plan.addedBlankPages,2)
            let first = try XCTUnwrap(workspace.plan.sheets.first)
            let slots = first.front.slots.sorted { $0.x<$1.x }
            XCTAssertEqual(slots.count,2)
            if slots.count==2 { XCTAssertEqual(slots[1].x-slots[0].x-slots[0].size.width,0,accuracy:0.00001) }
            let output = try PDFExporter.export(plan:workspace.plan,source:XCTUnwrap(workspace.source),
                destination:.singlePDF(folder.appendingPathComponent("new-A4-\(binding.rawValue).pdf")),marks:.none)
            XCTAssertEqual(output.sheetCount,27); XCTAssertEqual(output.pageCount,54)
            let exported = try XCTUnwrap(PDFDocument(url:output.files[0]))
            for index in 0..<exported.pageCount {
                let box = try XCTUnwrap(exported.page(at:index)).bounds(for:.mediaBox)
                XCTAssertEqual(box.width,297*72/25.4,accuracy:0.01)
                XCTAssertEqual(box.height,210*72/25.4,accuracy:0.01)
            }
        }
    }

    func testFlatAndGangGuttersStayIndependentAcrossBookletModesAndSaveOpen() async throws {
        let folder = try folder(),pdf = try fixture(folder,"flat.pdf",count:2,size:Size(40,60)),workspace = model()
        workspace.open(pdf); try await settle(workspace)
        workspace.project.sheet.gutter = 4
        workspace.setMode(.saddleStitch); XCTAssertEqual(workspace.project.sheet.gutter,0)
        workspace.setMode(.gang); XCTAssertEqual(workspace.project.sheet.gutter,0,"Never copy a flat or booklet gutter into a new gang job")
        workspace.project.sheet.gutter = 8
        workspace.setMode(.perfectBound); XCTAssertEqual(workspace.project.sheet.gutter,0)
        try await settle(workspace)
        let url = folder.appendingPathComponent("independent.atispress"); try workspace.saveProject(as:url)
        // An old remembered booklet gap must not leak into either flat mode.
        var file = try ProjectDocument.decode(Data(contentsOf:url)); file.state.bookletGutter = 6
        try file.encoded().write(to:url)
        let opened = model(); try await opened.loadProject(at:url); try await settle(opened)
        XCTAssertFalse(opened.isModified)
        opened.setMode(.stepAndRepeat); XCTAssertEqual(opened.project.sheet.gutter,4)
        opened.setMode(.saddleStitch); XCTAssertEqual(opened.project.sheet.gutter,0)
        opened.setMode(.gang); XCTAssertEqual(opened.project.sheet.gutter,8)
        opened.setMode(.perfectBound); XCTAssertEqual(opened.project.sheet.gutter,0)
        opened.setMode(.stepAndRepeat); XCTAssertEqual(opened.project.sheet.gutter,4)
    }

    func testExplicitZeroGutterIsNotReplacedWhenEnteringBookletMode() {
        let workspace = model()
        // The inspector marks an explicit edit even if 0 was already displayed.
        workspace.markManual(.gutter); workspace.project.sheet.gutter = 0
        workspace.setMode(.saddleStitch)
        XCTAssertEqual(workspace.project.sheet.gutter,0,"First booklet entry must not replace a user's zero with the legacy 6 mm default")
    }

    func testA5Booklet106PagePDFSeparateCoverOnManualA4AndAllZeroClearances() async throws {
        let folder = try folder(),body = try fixture(folder,"A5-106.pdf",count:106,size:SheetPreset.a5.size),cover = try fixture(folder,"A5-cover.pdf",count:4,size:SheetPreset.a5.size),workspace = model()
        try await prepare(workspace,body,binding:.saddleStitch)
        workspace.loadCoverPDF(cover); try await settle(workspace)
        workspace.project.exportMarks.crop = true
        workspace.project.settings.cropMarkLength = 5; workspace.project.settings.cropMarkOffset = 3.5
        workspace.sheetPreset = "A4"
        workspace.project.sheet = SheetSpec(preset:.a4,margins:Insets(),gripperWidth:0,gutter:0,orientation:.landscape)
        workspace.project.settings.bleed = 3
        // Leave preview crop length/offset intact: disabling output marks must
        // not secretly keep their fit padding or overwrite the user's gutter.
        workspace.project.exportMarks = .none; workspace.overlays = .artworkOnly
        try await settle(workspace)
        XCTAssertEqual(workspace.project.sheet.gutter,0)
        XCTAssertTrue(workspace.plan.canExport,workspace.plan.issues.map(\.message).joined(separator:"\n"))
        XCTAssertEqual(workspace.plan.sheets.count,28)
        XCTAssertEqual(workspace.plan.addedBlankPages,2)
        XCTAssertTrue(workspace.plan.diagnosticSheets.isEmpty)
        XCTAssertEqual(workspace.plan.sheets.first?.size,Size(297,210))
        workspace.project.exportMarks.crop = true; try await settle(workspace)
        XCTAssertFalse(workspace.plan.canExport,"Enabling crop marks must re-evaluate the full-sheet fit")
        workspace.project.exportMarks = .none; try await settle(workspace)
        XCTAssertTrue(workspace.plan.canExport)
        XCTAssertEqual(workspace.overlays,.artworkOnly)
        XCTAssertEqual(workspace.project.settings.cropMarkLength,5)
        let saved = folder.appendingPathComponent("A5-106.atispress"); try workspace.saveProject(as:saved)
        let restored = model(); try await restored.loadProject(at:saved); try await settle(restored)
        XCTAssertTrue(restored.plan.canExport)
        XCTAssertEqual(restored.project.sheet.gutter,0)
        XCTAssertEqual(restored.plan.sheets,workspace.plan.sheets)
        let output = folder.appendingPathComponent("A5-106-A4.pdf")
        let result = try PDFExporter.export(plan:restored.plan,source:XCTUnwrap(restored.source),destination:.singlePDF(output),marks:.none)
        XCTAssertEqual(result.sheetCount,28); XCTAssertEqual(result.pageCount,56)
        let document = try XCTUnwrap(PDFDocument(url:output))
        for i in 0..<document.pageCount {
            let box = try XCTUnwrap(document.page(at:i)).bounds(for:.mediaBox)
            XCTAssertEqual(box.width,297*72/25.4,accuracy:0.01)
            XCTAssertEqual(box.height,210*72/25.4,accuracy:0.01)
        }
    }

}

extension BookWorkspaceTests {
    func testKapakFirstLastOnlyAndSelectedSourcesRoundTrip() async throws {
        let folder = try folder()
        let workspace = model()
        let pdf = try fixture(folder,"12-sayfa.pdf",count:12,size:Size(50,70))
        workspace.open(pdf,confirmChanges:false)
        try await settle(workspace)
        XCTAssertTrue(workspace.hasCoverArtworkContext)
        workspace.project.sheet = SheetSpec(size:Size(300,400))
        let original = workspace.project.pages
        workspace.activateCoverSource(.firstAndLast)
        for width in [0.0, 4, 13.25] {
            workspace.spineWidth = width
            let spread = workspace.coverPreparationPlan(.spread)
            let sheet = try XCTUnwrap(spread.sheets.first)
            XCTAssertEqual(sheet.front.slots.compactMap(\.sourcePageNumber),[12,1])
            XCTAssertEqual(sheet.size.width,100+width,accuracy:0.001)
            XCTAssertEqual(sheet.size.height,70,accuracy:0.001)
            XCTAssertEqual(sheet.front.previewMarks.filter { $0.kind == .fold }.count,width > 0 ? 2 : 0)
        }
        try await settle(workspace)
        let cover = try XCTUnwrap(workspace.plan.sheets.first(where: \.isPreparedCover))
        XCTAssertGreaterThan(cover.repeatLayout?.copiesPerSheet ?? 0,1)
        XCTAssertFalse(cover.exportsBack(keepingBlankBacks:true))
        let interior = workspace.plan.sheets.filter { !$0.isPreparedCover }
        XCTAssertEqual(Set(interior.flatMap { ($0.front.slots+$0.back.slots).compactMap(\.sourcePageNumber) }),Set(2...11))

        workspace.coverPreparation.onlyCover = true
        try await settle(workspace)
        XCTAssertTrue(workspace.canExportNow)
        XCTAssertTrue(workspace.plan.sheets.allSatisfy(\.isPreparedCover))
        XCTAssertEqual(workspace.project.pages,original)
        XCTAssertTrue(workspace.exportPreparationSummary.contains("İç sayfalar: basılmayacak"))

        workspace.activateCoverSource(.selectedPages)
        workspace.coverPreparation.front = 3
        workspace.coverPreparation.back = 8
        workspace.coverPreparation.colorMode = .manual
        workspace.coverPreparation.color = .cmyk(0.4,0.1,0,0)
        workspace.coverPreparation.foldMarks = true
        try await settle(workspace)
        XCTAssertEqual(workspace.coverPreparationPlan(.spread).sheets.first?.front.slots.compactMap(\.sourcePageNumber),[8,3])
        let url = folder.appendingPathComponent("kapak.atispress")
        try workspace.saveProject(as:url)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf:url)).version,ProjectDocument.currentVersion)
        let reopened = model()
        try await reopened.loadProject(at:url)
        try await settle(reopened)
        XCTAssertEqual(reopened.plan.sheets,workspace.plan.sheets)
        XCTAssertEqual(reopened.project.coverPreparation,workspace.project.coverPreparation)
    }

    func testKapakTwoPageFileAndExternalCoverPDF() async throws {
        let folder = try folder()
        let panels = try fixture(folder,"yuzler.pdf",count:2,size:Size(50,70))
        let prepared = try fixture(folder,"hazir.pdf",count:1,size:Size(107,70))
        let workspace = model()
        workspace.open(panels,confirmChanges:false)
        try await settle(workspace)
        workspace.project.sheet = SheetSpec(size:Size(300,400))
        workspace.activateCoverSource(.coverFile)
        try await settle(workspace)
        XCTAssertTrue(workspace.canExportNow)
        XCTAssertEqual(workspace.coverPreparationPlan(.spread).sheets.first?.front.slots.compactMap(\.sourcePageNumber),[2,1])
        XCTAssertTrue(workspace.plan.sheets.allSatisfy(\.isPreparedCover))

        workspace.activateCoverSource(.separatePDF)
        workspace.spineWidth = 7
        workspace.loadCoverPDF(prepared,automatic:true)
        try await settle(workspace)
        let spread = try XCTUnwrap(workspace.coverPreparationPlan(.spread).sheets.first)
        XCTAssertEqual(spread.front.slots.compactMap(\.sourcePageNumber),[3])
        XCTAssertEqual(spread.size.width,107,accuracy:0.001)
        XCTAssertTrue(workspace.canExportNow)
        workspace.spineWidth = 9
        XCTAssertTrue(workspace.coverPreparationPlan(.spread).issues.contains { $0.message.contains("Beklenen") })
        workspace.spineWidth = 7
        let url = folder.appendingPathComponent("hazir.atispress")
        try workspace.saveProject(as:url)
        let reopened = model()
        try await reopened.loadProject(at:url)
        try await settle(reopened)
        XCTAssertEqual(reopened.coverPreparationPlan(.spread).sheets,[spread])
        reopened.loadCoverPDF(panels,automatic:true)
        try await settle(reopened)
        XCTAssertEqual(reopened.coverPreparationPlan(.spread).sheets.first?.front.slots.compactMap(\.sourcePageNumber),[4,3])
        reopened.activateCoverSource(.selectedPages)
        reopened.coverPreparation.front = reopened.project.book?.coverPDFPages.first
        reopened.coverPreparation.back = reopened.project.pages.first?.number
        XCTAssertEqual(reopened.coverPreparationPlan(.spread).sheets.first?.front.slots.compactMap(\.sourcePageNumber),[1,3])
    }

    func testKapakMarksBleedAndFitUseExistingSheetPlan() async throws {
        let folder = try folder()
        let workspace = model()
        workspace.open(try fixture(folder,"marks.pdf",count:2,size:Size(90,130)),confirmChanges:false)
        try await settle(workspace)
        workspace.project.sheet = SheetSpec(size:Size(450,400))
        workspace.activateCoverSource(.coverFile)
        workspace.spineWidth = 10
        workspace.coverPreparation.grid.columns = 1
        workspace.coverPreparation.grid.rows = 1
        workspace.coverPreparation.grid.rotation = .zero
        workspace.coverPreparation.foldMarks = true
        workspace.coverPreparation.colorMode = .manual
        workspace.coverPreparation.color = .cmyk(0,1,0,0)
        workspace.project.exportMarks.crop = true
        workspace.project.settings.cropMarkLength = 4
        workspace.project.exportMarks.lineWidth = 1
        workspace.project.settings.bleed = 3
        workspace.project.settings.generatedBleed.enabled = true
        let plan = workspace.coverPreparationPlan(.sheet)
        let sheet = try XCTUnwrap(plan.sheets.first)
        let slots = sheet.front.slots
        XCTAssertEqual(slots.count,3)
        for slot in slots {
            let clip = try XCTUnwrap(slot.artworkClip)
            XCTAssertEqual(clip.size.height-slot.size.height,6,accuracy:0.001)
        }
        let spine = try XCTUnwrap(slots.first { $0.bookRegion == "Sırt" })
        XCTAssertEqual(spine.artworkClip?.size.width,10)
        XCTAssertEqual(spine.spineArtwork?.content.color,.cmyk(0,1,0,0))
        let marks = PDFExportMarkRenderer.geometry(side:sheet.front,sheet:sheet,settings:workspace.project.exportMarks).segments
        XCTAssertEqual(marks.filter { $0.kind == .spineFold }.count,4)
        XCTAssertFalse(marks.filter { $0.kind == .crop }.isEmpty)
        let output = folder.appendingPathComponent("marks-export.pdf")
        _ = try PDFExporter.export(plan:plan,source:XCTUnwrap(workspace.source),destination:.singlePDF(output),
                                   marks:workspace.project.exportMarks)
        let doc = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(doc.numberOfPages,1)
        let pixelsPerMM = 4.0
        let width = Int(sheet.size.width*pixelsPerMM)
        let height = Int(sheet.size.height*pixelsPerMM)
        let bitmap = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,
            bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray:1,alpha:1))
        bitmap.fill(CGRect(x:0,y:0,width:width,height:height))
        bitmap.scaleBy(x:pixelsPerMM/PDFPreviewDrawing.pointsPerMM,y:pixelsPerMM/PDFPreviewDrawing.pointsPerMM)
        bitmap.drawPDFPage(try XCTUnwrap(doc.page(at:1)))
        let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to:UInt8.self)
        func pixel(_ x: Double,_ y: Double,_ channel: Int) -> UInt8 {
            let row = height-1-Int(y*pixelsPerMM)
            return bytes[row*bitmap.bytesPerRow+Int(x*pixelsPerMM)*4+channel]
        }
        for kind in [MarkKind.spineFold,.crop] {
            let mark = try XCTUnwrap(marks.first { $0.kind == kind })
            XCTAssertLessThan(pixel((mark.start.x+mark.end.x)/2,(mark.start.y+mark.end.y)/2,0),245)
        }
        XCTAssertLessThan(pixel(spine.x+5,spine.y-1.5,1),180)
        workspace.project.sheet = SheetSpec(size:Size(120,120))
        let tooSmall = workspace.coverPreparationPlan(.sheet)
        XCTAssertFalse(tooSmall.canExport)
        XCTAssertTrue(tooSmall.issues.contains { $0.message.contains("En yakın uygun hazır tabaka") })
    }
}


extension BookWorkspaceTests {
    func testKapakMachineGripperAndQuantity() async throws {
        let folder = try folder()
        let workspace = model()
        workspace.open(try fixture(folder,"makine.pdf",count:2,size:Size(80,120)),confirmChanges:false)
        try await settle(workspace)
        workspace.activateCoverSource(.coverFile)
        workspace.project.setSharedSheetSize(Size(450,320))
        var profile = MachineProfile.heidelberg
        profile.gripperEdge = .top
        profile.gripperWidth = 25
        workspace.selectMachineProfile(profile)
        workspace.project.settings.bleed = 3
        workspace.project.settings.generatedBleed.enabled = true
        workspace.coverPreparation.grid.rotation = .zero
        workspace.project.stepAndRepeat.quantity = 25
        try await settle(workspace)
        let sheet = try XCTUnwrap(workspace.plan.sheets.first)
        let capacity = try XCTUnwrap(sheet.repeatLayout?.copiesPerSheet)
        XCTAssertTrue(sheet.isPreparedCover)
        XCTAssertEqual(sheet.gripperEdge,.top)
        XCTAssertGreaterThan(capacity,1)
        XCTAssertEqual(sheet.repeatCount,(25+capacity-1)/capacity)
        XCTAssertTrue(sheet.front.slots.allSatisfy { slot in
            guard let clip = slot.artworkClip else { return false }
            return clip.origin.y+clip.size.height <= sheet.size.height-25+0.001
        })
        XCTAssertEqual(workspace.project.machineProfile?.gripperWidth,25)
    }

    func testKapakLogoRotationPercentDPIAndLimit() async throws {
        let folder = try folder()
        let workspace = model()
        workspace.open(try fixture(folder,"kapak-logo.pdf",count:2,size:Size(50,70)),confirmChanges:false)
        try await settle(workspace)
        workspace.activateCoverSource(.coverFile)
        workspace.spineWidth = 10
        let trim = CGRect(x:0,y:0,width:10,height:70)
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,
            bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:0,bitsPerPixel:0))
        for x in 0..<8 {
            for y in 0..<8 { image.setColor(.red,atX:x,y:y) }
        }
        let jpeg = try XCTUnwrap(image.representation(using:.jpeg,properties:[:]))
        let raster = try XCTUnwrap(PDFSpine.makeLogo(name:"logo.jpg",format:.jpg,data:jpeg,in:trim))
        var placed = PDFSpine.rotatedLogo(raster,in:trim)
        XCTAssertEqual(placed.rotation,90)
        XCTAssertNil(PDFSpine.logoWarning(placed,in:trim))
        placed.spineWidthPercent = 50
        let object = FreeSpineObject(content:.logo(placed))
        workspace.addPreparedSpine(object)
        workspace.spineWidth = 12
        let spread = workspace.coverPreparationPlan(.spread)
        let spine = try XCTUnwrap(spread.sheets.first?.front.slots.first { $0.spineArtwork != nil })
        let printed = try XCTUnwrap(spine.spineArtwork?.objects.first)
        XCTAssertEqual(printed.size,6,accuracy:0.001)
        XCTAssertTrue(spread.issues.contains { $0.severity == .warning && $0.message.contains("33,9 dpi") })
        var moved = printed
        moved.x = 8
        workspace.beginUndoGroup()
        workspace.editPreparedSpine(moved)
        workspace.endUndoGroup()
        let overflow = workspace.coverPreparationPlan(.spread)
        XCTAssertTrue(overflow.canExport)
        XCTAssertTrue(overflow.issues.contains { $0.severity == .warning && $0.message.contains("5,0000 mm") })
        workspace.undoEdit()
        XCTAssertEqual(workspace.preparedSpineObjects.first?.x,0)
        for _ in 0..<3 { workspace.addPreparedSpine(FreeSpineObject(content:.logo(raster))) }
        XCTAssertEqual(workspace.preparedLogoCount,3)
        XCTAssertEqual(workspace.error,"Sırta en fazla 3 logo eklenebilir.")
    }
}
