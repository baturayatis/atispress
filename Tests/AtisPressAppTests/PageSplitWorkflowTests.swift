import XCTest
import AppKit
import SwiftUI
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class PageSplitWorkflowTests:XCTestCase {
    private func fixture() throws -> (URL,URL) {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("dort-kart.pdf"),pt=PDFPreviewDrawing.pointsPerMM
        var media=CGRect(x:0,y:0,width:192*pt,height:112*pt)
        let c=try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&media,nil))
        let data=Data(bytes:&media,count:MemoryLayout<CGRect>.size)
        c.beginPDFPage([kCGPDFContextBleedBox:data] as CFDictionary);c.scaleBy(x:pt,y:pt)
        c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:192,height:112))
        c.setLineWidth(0.3/pt)
        for row in 0..<2 {for column in 0..<2 {
            for (inset,color) in [(0.0,CGColor(red:1,green:0,blue:1,alpha:1)),(3.0,CGColor(red:1,green:0.6,blue:0.8,alpha:1)),(6.0,CGColor(red:0.5,green:0.8,blue:1,alpha:1))] {
                c.setStrokeColor(color);c.stroke(CGRect(x:Double(column)*96+inset,y:Double(row)*56+inset,width:96-2*inset,height:56-2*inset))
            }
        }}
        c.endPDFPage();c.closePDF();return (dir,url)
    }
    private func workspace() -> Workspace {Workspace(bookmarkCreator:{try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)})}
    private func settle(_ m:Workspace) async throws {
        for _ in 0..<600 {if !m.loading && !m.planning && !m.preparingSource && !m.autoArranging {return};try await Task.sleep(for:.milliseconds(10))};XCTFail("Preparation did not settle")
    }
    func testArtworkSeparationPersistsAssignmentsAndExportsTheSameTeamPlan() async throws {
        let (directory, url) = try fixture()
        let model = workspace()
        model.open(url, confirmChanges: false)
        try await settle(model)
        let classic = model.project
        let oldURL = directory.appendingPathComponent("old.atispress")
        try model.saveProject(as: oldURL)
        var legacy = try ProjectDocument.decode(Data(contentsOf: oldURL))
        legacy.version = 23
        try legacy.encoded().write(to: oldURL)
        let old = workspace()
        try await old.loadProject(at: oldURL)
        try await settle(old)
        XCTAssertEqual(old.project, classic)
        XCTAssertNil(old.project.sourcePreparation?.separation)

        let input = try XCTUnwrap(model.preparationInput)
        let proposals = input.guides.artworkCandidates(size: input.pages[0].trimSize)
        XCTAssertEqual(proposals.count, 4, "Trim \(input.pages[0].trimSize), frames \(input.guides.learned.map(\.outer))")
        XCTAssertTrue(proposals.allSatisfy { $0.assignment == nil })
        _ = ArtworkSeparationView(model: model, input: input)
        XCTAssertEqual(model.project, classic)

        var draft = ArtworkSeparation()
        let bleed = Insets(left: 3, right: 3, top: 3, bottom: 3)
        draft.regions = [
            ArtworkRegion(crop: Rect(x: 0, y: 0, width: 96, height: 56), bleed: bleed, assignment: SplitCell(product: 2)),
            ArtworkRegion(crop: Rect(x: 96, y: 56, width: 96, height: 56), bleed: bleed, assignment: SplitCell(product: 2, side: .back)),
            ArtworkRegion(crop: Rect(x: 96, y: 0, width: 88, height: 50), bleed: bleed, assignment: SplitCell(product: 7))
        ]
        model.basicQuantity = 2
        var preparation = SourcePreparationSettings(sourceID: model.preparationSourceID)
        var simplex = draft
        simplex.regions.remove(at: 1)
        preparation.separation = simplex
        model.project.settings.turnMethod = .workAndTurn
        try await model.applySourcePreparation(preparation)
        try await settle(model)
        XCTAssertEqual(model.project.settings.turnMethod, .sheetwise)
        XCTAssertFalse(model.plan.hasBackContent)

        preparation.separation = draft
        try await model.applySourcePreparation(preparation)
        try await settle(model)
        XCTAssertNil(model.project.team)
        XCTAssertEqual(model.project.gang?.jobs.map(\.splitProduct), [2, 7])
        XCTAssertEqual(model.project.gang?.jobs.map { $0.back?.number }, [2, nil])
        let jobIDs = model.project.gang?.jobs.map(\.id)

        draft.asTeam = true
        preparation.separation = draft
        try await model.applySourcePreparation(preparation)
        try await settle(model)
        XCTAssertEqual(model.project.gang?.jobs.map(\.id), jobIDs)
        XCTAssertEqual(model.project.team?.duplex, true)
        XCTAssertTrue(model.plan.canExport, "\(model.plan.issues)")
        XCTAssertEqual(model.plan.teamSummary?.pageCount, 3)
        let saved = directory.appendingPathComponent("separated.atispress")
        try model.saveProject(as: saved)
        let file = try ProjectDocument.decode(Data(contentsOf: saved))
        XCTAssertEqual(file.version, ProjectDocument.currentVersion)
        XCTAssertEqual(file.state.project.sourcePreparation, preparation)
        XCTAssertEqual(file.state.gangSources?.first?.reference.path, url.path)
        XCTAssertEqual(file.state.gangSources?.first?.pageCount, 1)
        let reopened = workspace()
        try await reopened.loadProject(at: saved)
        try await settle(reopened)
        XCTAssertEqual(reopened.project, model.project)
        XCTAssertEqual(reopened.plan.sheets, model.plan.sheets)
        let prepared = try XCTUnwrap(reopened.source)
        let plan = reopened.plan
        let output = directory.appendingPathComponent("artwork.pdf")
        let verification = try await Task.detached {
            let exported = try PDFExporter.export(plan: plan, source: prepared, destination: .singlePDF(output), marks: .none)
            return try ExportVerification.check(files: exported.files, plan: plan, source: prepared, marks: .none, includeBlankBacks: true)
        }.value
        XCTAssertTrue(verification.passed, "\(verification.differences)")
    }

    func testConfirmedSplitCreatesProductsPersistsOriginalAndReopensSchema19() async throws {
        let (dir,url)=try fixture(),m=workspace();m.open(url,confirmChanges:false);try await settle(m)
        let original=m.project
        let split=try XCTUnwrap(m.suggestedPageSplit)
        XCTAssertEqual(split.columns,2);XCTAssertEqual(split.rows,2)
        let view=PageSplitView(model:m,input:try XCTUnwrap(m.preparationInput))
        XCTAssertEqual(view.settings,split);XCTAssertEqual(m.project,original,"Opening the window must not apply")
        m.useLearnedSourceTrim(try XCTUnwrap(m.preparationInput?.guides.learned.first))
        let learnedDraft=PageSplitView(model:m,input:m.preparationInput!)
        XCTAssertEqual(learnedDraft.settings.explicitTrim?.width ?? 0,90,accuracy:0.001)
        XCTAssertEqual(learnedDraft.settings.cellBleed,3,accuracy:0.001)
        XCTAssertEqual(m.project,original,"Learning transfers a draft, not production")
        var preparation=SourcePreparationSettings();preparation.split=split;preparation.ignoreSplitSuggestion=true
        try await m.applySourcePreparation(preparation);try await settle(m)
        XCTAssertEqual(m.project.binding,.gang);XCTAssertEqual(m.project.gang?.jobs.count,2)
        XCTAssertEqual(m.project.gang?.jobs.map(\.front.number),[1,3]);XCTAssertEqual(m.project.gang?.jobs.compactMap{$0.back?.number},[2,4])
        XCTAssertTrue(m.plan.canExport,"\(m.plan.issues)")
        let id=try XCTUnwrap(m.project.gang?.jobs.first?.id)
        m.editGangJob(id) {job in job.quantity=17;var f=SerialField();f.kind = .qr;f.sides = .both;job.serialFields=[f]}
        m.overlays.generatedBleedTint=true
        let pink=Set(m.preparationInput!.guides.groups.filter{$0.role=="kesim"}.map(\.id))
        preparation.hiddenGuideGroups=pink.sorted()
        m.setScale(RescaleSettings(target:Size(80,45)),pages:[1,2],gangID:id)
        let beforeScaling=m.project.scaling
        let beforeJobs=m.project.gang
        try await m.applySourcePreparation(preparation);try await settle(m)
        XCTAssertEqual(m.project.gang,beforeJobs,"Hiding must preserve product quantities, IDs and QR fields")
        XCTAssertEqual(m.project.scaling,beforeScaling)
        XCTAssertEqual(m.hiddenSourceGuideCount,4)
        XCTAssertTrue(m.exportPreparationSummary.contains("4 kılavuz çizgisi gizlendi"))
        let file=dir.appendingPathComponent("split.atispress");try m.saveProject(as:file)
        let decoded=try ProjectDocument.decode(Data(contentsOf:file))
        XCTAssertEqual(decoded.version,ProjectDocument.currentVersion);XCTAssertEqual(decoded.state.project.sourcePreparation,preparation)
        XCTAssertEqual(decoded.state.gangSources?.first?.reference.path,url.path)
        XCTAssertEqual(decoded.state.gangSources?.first?.pageCount,1,"Stored reference counts original, never temporary cells")
        let opened=workspace();try await opened.loadProject(at:file);try await settle(opened)
        XCTAssertEqual(opened.project,m.project)
        XCTAssertEqual(opened.plan.sheets,m.plan.sheets)
        XCTAssertEqual(opened.overlays.generatedBleedTint,true)
        XCTAssertEqual(opened.source?.preparationInput.url,url)
        XCTAssertTrue(opened.source!.protectedURLs.contains(url))
        XCTAssertEqual(opened.hiddenSourceGuideCount,4)
        XCTAssertTrue(opened.canSplitSource)
    }
    func testGuideHideShowEachHasOneUndoAndDoesNotChangePlan() async throws {
        let (_,url)=try fixture(),m=workspace();m.open(url,confirmChanges:false);try await settle(m)
        let baseline=m.plan.sheets,project=m.project
        m.flushUndoEdits()
        var p=SourcePreparationSettings();p.hiddenGuideGroups=m.preparationInput!.guides.groups.filter{$0.role=="kesim"}.map(\.id)
        try await m.applySourcePreparation(p);try await settle(m)
        XCTAssertEqual(m.plan.sheets,baseline)
        XCTAssertEqual(m.hiddenSourceGuideCount,4)
        XCTAssertTrue(m.canUndo)
        m.undoEdit();try await settle(m)
        XCTAssertEqual(m.project,project);XCTAssertEqual(m.hiddenSourceGuideCount,0);XCTAssertEqual(m.plan.sheets,baseline)
        m.redoEdit();try await settle(m)
        XCTAssertEqual(m.hiddenSourceGuideCount,4)
        p.hiddenGuideGroups=[]
        try await m.applySourcePreparation(p);try await settle(m)
        XCTAssertEqual(m.hiddenSourceGuideCount,0)
        m.undoEdit();try await settle(m)
        XCTAssertEqual(m.hiddenSourceGuideCount,4)
        m.includeAll(false);try await settle(m)
        p.hiddenGuideGroups=[]
        try await m.applySourcePreparation(p);try await settle(m)
        XCTAssertTrue(m.included.isEmpty);XCTAssertTrue(m.project.pages.isEmpty)
        XCTAssertEqual(m.order,[1],"Guide changes must not reinclude or reorder source pages")
    }
    func testOldSchema18WithoutNewSettingsOpensAndNoFeaturePlanPDFSnapshotStaysIdentical() async throws {
        let (dir,url)=try fixture(),m=workspace();m.open(url,confirmChanges:false);try await settle(m)
        let file=dir.appendingPathComponent("legacy.atispress");try m.saveProject(as:file)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]);json["version"]=18
        var state=try XCTUnwrap(json["state"] as? [String:Any]),p=try XCTUnwrap(state["project"] as? [String:Any]),overlays=try XCTUnwrap(state["overlays"] as? [String:Any])
        p.removeValue(forKey:"sourcePreparation");overlays.removeValue(forKey:"generatedBleedTint");state["project"]=p;state["overlays"]=overlays;json["state"]=state
        try JSONSerialization.data(withJSONObject:json).write(to:file)
        let before=m.plan.sheets
        func pixels(_ model:Workspace,_ name:String) throws -> [Data] {
            let out=dir.appendingPathComponent(name+".pdf")
            _=try PDFExporter.export(plan:model.plan,source:XCTUnwrap(model.source),destination:.singlePDF(out),marks:.none)
            let d=try XCTUnwrap(CGPDFDocument(out as CFURL))
            return try (1...d.numberOfPages).map {n in
                let c=try XCTUnwrap(CGContext(data:nil,width:330,height:480,bitsPerComponent:8,bytesPerRow:1320,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:330,height:480))
                let page=try XCTUnwrap(d.page(at:n));c.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(x:0,y:0,width:330,height:480),rotate:0,preserveAspectRatio:true));c.drawPDFPage(page)
                return Data(bytes:try XCTUnwrap(c.data),count:c.bytesPerRow*c.height)
            }
        }
        let baseline=try pixels(m,"before")
        let loaded=workspace();try await loaded.loadProject(at:file);try await settle(loaded)
        XCTAssertNil(loaded.project.sourcePreparation);XCTAssertNil(loaded.overlays.generatedBleedTint)
        XCTAssertEqual(loaded.plan.sheets,before);XCTAssertEqual(try pixels(loaded,"after"),baseline)
        loaded.dismissPageSplitSuggestion();try await settle(loaded)
        XCTAssertNil(loaded.suggestedPageSplit);XCTAssertEqual(loaded.plan.sheets,before)
        XCTAssertEqual(try pixels(loaded,"dismissed"),baseline)
    }
    func testBleedTextsTintAndScreenCropWidth() {
        let m=workspace(),pages=[SourcePage(number:1,trimSize:Size(90,50),availableBleed:0)]
        var settings=GeneratedBleedSettings(enabled:true,method:.solidColor,color:.rgb(1,0,0))
        XCTAssertEqual(m.bleedResult(pages:pages,enabled:true,amount:3,settings:settings,adjacent:false),"Taşma: her kartın 4 kenarında üretildi")
        XCTAssertEqual(m.bleedResult(pages:pages,enabled:true,amount:3,settings:settings,adjacent:true),"Taşma: bloğun dış çevresinde (bitişik dizilim)")
        settings.color = .cmyk(0,0,0,0)
        XCTAssertEqual(m.bleedResult(pages:pages,enabled:true,amount:3,settings:settings,adjacent:false),"Taşma: kenar rengi beyaz, taşma beyaz çıkar")
        XCTAssertTrue(m.bleedResult(pages:pages,enabled:false,amount:3,settings:settings,adjacent:false).hasPrefix("Kaynak taşması eksik veya yok."))
        m.overlays = .artworkOnly;m.overlays.generatedBleedTint=true;XCTAssertTrue(m.hasPreviewGuides)
        for zoom in [0.04,0.25,1,2.5] {for backing in [1.0,2.0] {
            let width=SheetCanvasView.cropStrokeWidth(lineWidth:0.25,zoom:zoom,backing:backing)
            XCTAssertGreaterThanOrEqual(width*PDFPreviewDrawing.pointsPerMM*zoom*backing,1.5-0.000001)
        }}
    }
    func testNewEditorsReachableAndWindowArtifacts() async throws {
        let (_,url)=try fixture(),m=workspace();m.open(url,confirmChanges:false);try await settle(m)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let inspector=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/InspectorView.swift")),view=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/WorkspaceView.swift")),layers=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/PreviewLayersView.swift"))
        XCTAssertTrue(inspector.contains("SourcePageTools(model:model)"));XCTAssertTrue(view.contains("PageSplitView(model:model"));XCTAssertTrue(view.contains("SourceGuidesView(model:model"));XCTAssertTrue(layers.contains("Üretilen taşma"))
        let dir=root.appendingPathComponent(".build/WorkflowQA");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let preview=try XCTUnwrap(SourceImage.render(m.preparationInput!,page:1))
        let cg=try XCTUnwrap(preview.cgImage(forProposedRect:nil,context:nil,hints:nil)),bitmap=NSBitmapImageRep(cgImage:cg)
        let raw=try XCTUnwrap(bitmap.bitmapData),bpp=bitmap.samplesPerPixel
        let y=bitmap.pixelsHigh/4
        XCTAssertTrue((0..<3).contains {x in let i=y*bitmap.bytesPerRow+x*bpp;return raw[i]>200 && raw[i+2]>200 && raw[i+1]<245},"Source preview must fill the coordinate canvas, even when upscaling the original PDF")
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:dir.appendingPathComponent("source-grid-preview.png"))
        for (name,scheme) in [("light",ColorScheme.light),("dark",.dark)] {
            let content=PageSplitView(model:m,input:m.preparationInput!).environment(\.colorScheme,scheme)
            let host=NSHostingView(rootView:content);host.frame=NSRect(x:0,y:0,width:985,height:700);host.layoutSubtreeIfNeeded()
            let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep)
            try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:dir.appendingPathComponent("page-split-"+name+".png"))
            let guide=NSHostingView(rootView:SourceGuidesView(model:m,input:m.preparationInput!).environment(\.colorScheme,scheme))
            guide.frame=NSRect(x:0,y:0,width:970,height:690);guide.layoutSubtreeIfNeeded()
            let gr=try XCTUnwrap(guide.bitmapImageRepForCachingDisplay(in:guide.bounds));guide.cacheDisplay(in:guide.bounds,to:gr)
            try XCTUnwrap(gr.representation(using:.png,properties:[:])).write(to:dir.appendingPathComponent("source-guides-"+name+".png"))
        }
    }
}
