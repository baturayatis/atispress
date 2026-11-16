import XCTest
import AppKit
import PDFKit
import SwiftUI
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class PDFInsertionTests:XCTestCase {
    private func folder() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:url)}
        return url
    }
    private func fixture(_ name:String="base",count:Int=2,size:Size=Size(85,55),password:String? = nil) throws -> URL {
        let url=try folder().appendingPathComponent(name+".pdf")
        var box=CGRect(x:0,y:0,width:size.width*72/25.4,height:size.height*72/25.4)
        var options:[String:Any]=[:]
        if let password {options[kCGPDFContextUserPassword as String]=password;options[kCGPDFContextOwnerPassword as String]="owner"}
        let context=try XCTUnwrap(CGContext(consumer:CGDataConsumer(url:url as CFURL)!,mediaBox:&box,options as CFDictionary))
        for index in 0..<count {
            context.beginPDFPage(nil);context.setFillColor(CGColor(red:Double(index+1)/Double(count+1),green:0.2,blue:0.7,alpha:1));context.fill(box);context.endPDFPage()
        }
        context.closePDF();return url
    }
    private func workspace()->Workspace {
        let name="PDFInsertion-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        addTeardownBlock {defaults.removePersistentDomain(forName:name)}
        return Workspace(bookmarkCreator:{try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)},uiDefaults:defaults)
    }
    private func settle(_ model:Workspace) async throws {
        for _ in 0..<1200 {
            if !model.loading && !model.planning && !model.preparingSource && !model.samplingBleed && !model.autoArranging {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Workspace did not settle")
    }
    private func loaded() async throws -> Workspace {
        let model=workspace();model.open(try fixture(),confirmChanges:false);try await settle(model)
        model.project.settings.bleed=0;model.project.settings.generatedBleed.enabled=false;try await settle(model)
        model.flushUndoEdits();return model
    }
    private func draft(_ model:Workspace,count:Int=2,size:Size=Size(85,55),position:PageInsertionPosition = .end,anchor:Int? = nil) async throws -> PDFInsertionDraft {
        let url=try fixture("added",count:count,size:size),pdf=try await PDFSource.open(url)
        return PDFInsertionDraft(sources:[PDFInsertSource(url:url,pdf:pdf,selected:Set(1...count))],anchor:anchor,position:position)
    }
    private func outputPixels(_ model:Workspace) throws -> [Data] {
        let url=try folder().appendingPathComponent("result.pdf")
        _ = try PDFExporter.export(plan:model.plan,source:XCTUnwrap(model.source),destination:.singlePDF(url),marks:model.project.exportMarks)
        let document=try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertNil(try Data(contentsOf:url).range(of:Data("/Subtype /Image".utf8)))
        return try (1...document.numberOfPages).map {index in
            let page=try XCTUnwrap(document.page(at:index)),ctx=try XCTUnwrap(CGContext(data:nil,width:160,height:120,bitsPerComponent:8,bytesPerRow:640,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:160,height:120))
            ctx.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(x:0,y:0,width:160,height:120),rotate:0,preserveAspectRatio:true));ctx.drawPDFPage(page)
            return Data(bytes:ctx.data!,count:ctx.bytesPerRow*ctx.height)
        }
    }
    func testInsertionPositionsAdjustPairBoundariesAndUndoIsSingleStep() async throws {
        for position in PageInsertionPosition.allCases {
            let model=try await loaded(),before=model.project,plan=model.plan,pixels=try outputPixels(model)
            let value=try await draft(model,position:position,anchor:position == .above ? 2:1)
            let point=model.pageInsertionPoint(value)
            XCTAssertEqual(point.index,(position == .above || position == .start) ? 0:2)
            XCTAssertEqual(point.adjusted,position == .above || position == .below)
            try await model.insertPagePDFs(value,mode:.pairs);try await settle(model)
            XCTAssertEqual(model.project.repeatJobs.count,2)
            XCTAssertEqual(model.pageSideTitle(1),"Ön");XCTAssertEqual(model.pageSideTitle(2),"Arka")
            XCTAssertEqual(model.pageSourceRecords.count,2)
            let inserted=Set(model.selectedPages)
            XCTAssertEqual(Set(model.plan.sheets.flatMap{$0.front.slots+$0.back.slots}.compactMap(\.sourceID)).count,2)
            model.undoEdit();try await settle(model)
            XCTAssertEqual(model.project,before);XCTAssertEqual(model.plan.sheets,plan.sheets);XCTAssertEqual(try outputPixels(model),pixels)
            model.redoEdit();try await settle(model);XCTAssertEqual(model.selectedPages.intersection(inserted).count,0)
            XCTAssertEqual(model.order.count,4)
        }
    }
    func testOddChoicesAndCancelAndMultiplePDFOrdering() async throws {
        for mode in [PageInsertionMode.fronts,.pairs,.singles,.cancel] {
            let model=try await loaded(),before=model.project
            let value=try await draft(model,count:3)
            try await model.insertPagePDFs(value,mode:mode);try await settle(model)
            if mode == .cancel {XCTAssertEqual(model.project,before);continue}
            XCTAssertEqual(model.order.count,mode == .fronts ? 8:mode == .pairs ? 6:5)
            XCTAssertEqual(model.project.repeatJobs.count,mode == .pairs ? 3:4)
            XCTAssertEqual(model.project.stepAndRepeat.pageLayout?.mode,before.stepAndRepeat.pageLayout?.mode)
            XCTAssertEqual(model.pageSideTitle(2),"Arka")
            _ = try outputPixels(model)
        }
        let model=try await loaded()
        var value=try await draft(model,count:2)
        let third=try fixture("third",count:2),pdf=try await PDFSource.open(third)
        value.sources.append(PDFInsertSource(url:third,pdf:pdf,selected:[2]))
        try await model.insertPagePDFs(value,mode:.singles);try await settle(model)
        XCTAssertEqual(model.order.suffix(3).compactMap{model.pageListItem($0)?.localPage},[1,2,2])
        XCTAssertEqual(model.pageSourceRecords.count,3)
    }
    func testEveryListActionKeepsOriginalCardSidesAndWarnsOnBackLoss() async throws {
        let legacy=try await loaded()
        legacy.setJobPageLayout(frontPage:1,mode:.simplex);try await settle(legacy)
        XCTAssertTrue(legacy.requiresBacklessConfirmation)
        let model=try await loaded()
        model.selectedPages=[1];XCTAssertEqual(model.pageSideTitle(2),"Arka")
        model.insertBlankPages([1]);try await settle(model)
        XCTAssertEqual(model.pageSideTitle(1),"Ön");XCTAssertEqual(model.pageSideTitle(2),"Arka")
        model.movePages([2],toEnd:false);try await settle(model)
        XCTAssertEqual(model.project.repeatJobs.first?.front.number,1)
        XCTAssertEqual(model.project.repeatJobs.first?.back?.number,2)
        model.setIncluded(2,false);try await settle(model)
        XCTAssertEqual(model.pageSideTitle(2),"Arka");XCTAssertTrue(model.requiresBacklessConfirmation)
        XCTAssertTrue(model.exportPreparationSummary.contains("Arka yüz yok"));XCTAssertTrue(model.statusSummary.contains("Arka yüz yok"))
        model.setIncluded(2,true);try await settle(model);XCTAssertFalse(model.requiresBacklessConfirmation)
        model.setIncluded(1,false);try await settle(model)
        XCTAssertEqual(model.pageSideTitle(2),"Arka")
        XCTAssertFalse(model.plan.readingOrder.contains(1))
        XCTAssertTrue(model.plan.sheets.flatMap{$0.front.slots}.allSatisfy{$0.sourcePageNumber != 1})
        XCTAssertTrue(model.plan.sheets.flatMap{$0.back.slots}.contains{$0.sourcePageNumber==2})
        model.setIncluded(1,true);try await settle(model)
        model.duplicatePages([1]);try await settle(model)
        XCTAssertEqual(model.pageSideTitle(1),"Ön");XCTAssertEqual(model.pageSideTitle(2),"Arka")
        model.deletePages(model.selectedPages);try await settle(model)
        model.setPageLayout(.simplex);try await settle(model);XCTAssertTrue(model.requiresBacklessConfirmation)
        model.makePageListDuplex();try await settle(model);XCTAssertFalse(model.requiresBacklessConfirmation)
    }
    func testDifferentSizeChoicesScaleCancellationAndBookletPadding() async throws {
        let model=try await loaded(),before=model.project
        let value=try await draft(model,size:Size(148,210))
        XCTAssertTrue(model.insertionHasDifferentSize(value))
        try await model.insertPagePDFs(value,mode:.pairs,sizeChoice:.cancel);XCTAssertEqual(model.project,before)
        try await model.insertPagePDFs(value,mode:.pairs,sizeChoice:.scale);try await settle(model)
        XCTAssertNotNil(model.importScalePages)
        model.finishPDFImportScaling(accepted:false);try await settle(model);XCTAssertEqual(model.project,before)
        try await model.insertPagePDFs(value,mode:.pairs,sizeChoice:.scale);try await settle(model)
        model.applyScaleWindow(RescaleSettings(target:before.pages[0].trimSize),all:false,row:1);try await settle(model)
        XCTAssertTrue(model.plan.canExport);XCTAssertNil(model.importScalePages)
        model.undoEdit();try await settle(model);XCTAssertEqual(model.project,before)
        try await model.insertPagePDFs(value,mode:.pairs,sizeChoice:.gang);try await settle(model)
        XCTAssertEqual(model.project.binding,.gang);XCTAssertEqual(model.project.gang?.jobs.count,2)
        let book=try await loaded();book.setMode(.saddleStitch);try await settle(book)
        let added=try await draft(book,count:1)
        try await book.insertPagePDFs(added,mode:.singles);try await settle(book)
        XCTAssertEqual(book.project.pages.count,3);XCTAssertEqual(book.plan.addedBlankPages,1)
        XCTAssertTrue(book.pageListBookletSummary?.contains("3 sayfa") == true)
    }
    func testTwoSourcesRoundtripCopiesShareSourceAndRelinkMissingFile() async throws {
        let model=try await loaded(),value=try await draft(try await loaded())
        try await model.insertPagePDFs(value,mode:.pairs);try await settle(model)
        let added=model.selectedPages
        model.duplicatePages(added);try await settle(model)
        XCTAssertEqual(model.pageSourceRecords.count,2)
        let sourceIDs=Set(model.pageListItems.filter{added.contains($0.id)}.compactMap(\.sourceID))
        XCTAssertEqual(sourceIDs.count,1)
        let saved=try folder().appendingPathComponent("two.atispress");try model.saveProject(as:saved)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf:saved)).version,21)
        let moved=value.sources[0].url.deletingLastPathComponent().appendingPathComponent("moved.pdf")
        try FileManager.default.moveItem(at:value.sources[0].url,to:moved)
        let opened=workspace()
        try await opened.loadProject(at:saved,relink:{_ in moved});try await settle(opened)
        XCTAssertEqual(opened.plan.sheets,model.plan.sheets)
        XCTAssertEqual(try outputPixels(opened),try outputPixels(model))
    }
    func testRemovingAndRelinkingSourcesKeepsReferencesConsistent() async throws {
        let model=try await loaded(),value=try await draft(try await loaded())
        try await model.insertPagePDFs(value,mode:.pairs);try await settle(model)
        let id=try XCTUnwrap(model.pageSourceRecords.last?.id)
        let replacement=try fixture("replacement")
        try await model.relinkPageSource(id,url:replacement);try await settle(model)
        XCTAssertEqual(model.pageSourceRecords.last?.reference.path,replacement.path)
        let before=model.project
        try await model.removePageSource(id);try await settle(model)
        XCTAssertEqual(model.pageSourceRecords.count,1);XCTAssertEqual(model.order.count,2)
        model.undoEdit();try await settle(model);XCTAssertEqual(model.project,before);XCTAssertEqual(model.pageSourceRecords.count,2)
    }
    func testPasswordPDFIsUnlockedAndPasswordNeverSaved() async throws {
        let password="gizli-test-parolasi",url=try fixture("locked",password:password)
        do {_ = try await PDFSource.open(url);XCTFail("Locked file must ask for a password")} catch PDFReadError.locked {}
        let model=try await loaded()
        let pdf=try await model.openPagePDF(url,password:{_ in password})
        XCTAssertEqual(pdf.originalURL,url)
        let value=PDFInsertionDraft(sources:[PDFInsertSource(url:url,pdf:pdf,selected:[1,2])],anchor:nil,position:.end)
        try await model.insertPagePDFs(value,mode:.pairs);try await settle(model)
        let file=try folder().appendingPathComponent("encrypted.atispress");try model.saveProject(as:file)
        XCTAssertFalse(String(decoding:try Data(contentsOf:file),as:UTF8.self).contains(password))
        let opened=workspace();try await opened.loadProject(at:file,password:{_ in password});try await settle(opened)
        XCTAssertEqual(opened.plan.sheets,model.plan.sheets)
    }
    func testEmptyProjectImportSharedSourcesAndLastRemoval() async throws {
        let model=workspace(),value=try await draft(model)
        XCTAssertTrue(model.insertionUsesDuplex(value))
        try await model.insertPagePDFs(value,mode:.pairs);try await settle(model)
        XCTAssertEqual(model.pageSideTitle(model.order[0]),"Ön")
        XCTAssertEqual(model.pageSideTitle(model.order[1]),"Arka")
        try await model.insertPagePDFs(value,mode:.pairs);try await settle(model)
        XCTAssertEqual(model.pageSourceRecords.count,1)
        XCTAssertEqual(Set(model.pageListItems.compactMap(\.sourceID)).count,1)
        let id=try XCTUnwrap(model.pageSourceRecords.first?.id)
        try await model.removePageSource(id);try await settle(model)
        XCTAssertTrue(model.order.isEmpty);XCTAssertNil(model.source)
        model.undoEdit();try await settle(model)
        XCTAssertEqual(model.order.count,4);XCTAssertNotNil(model.source)
    }
    func testInterleavedPairsInsertionAndDeletedFrontKeepsBack() async throws {
        let model=try await loaded(),value=try await draft(try await loaded())
        try await model.insertPagePDFs(value,mode:.pairs);try await settle(model)
        let added=model.order[2]
        model.movePages([added],toEnd:false);try await settle(model)
        let incoming=try await draft(model,position:.below,anchor:1)
        XCTAssertEqual(model.pageInsertionPoint(incoming).index,4)
        model.deletePages([1],wholePairs:false);try await settle(model)
        XCTAssertEqual(model.pageSideTitle(2),"Arka")
        let item=try XCTUnwrap(model.pageListItem(2))
        let blank=try XCTUnwrap(model.pageListItems.first{$0.pairID==item.pairID && $0.side == .front})
        XCTAssertNil(blank.sourcePage)
        XCTAssertEqual(model.project.stepAndRepeat.pageLayout?.mode,.automatic)
    }
    func testUnreadableWrongPasswordAndCancellationLeaveProjectIntact() async throws {
        let model=try await loaded(),before=model.project
        let url=try fixture("password",password:"secret")
        do {_ = try await model.openPagePDF(url,password:{_ in "wrong"});XCTFail("Wrong password accepted")} catch PDFReadError.locked {}
        do {_ = try await model.openPagePDF(url,password:{_ in nil});XCTFail("Cancellation ignored")} catch is CancellationError {}
        let invalid=try folder().appendingPathComponent("broken.pdf")
        try Data("unreadable".utf8).write(to:invalid)
        do {_ = try await model.openPagePDF(invalid);XCTFail("Unreadable PDF accepted")} catch PDFReadError.unreadable {}
        XCTAssertEqual(model.project,before)
    }
    func testMixedSizeGangRoundtripUsesEachPhysicalSourcePage() async throws {
        let model=try await loaded(),value=try await draft(try await loaded(),size:Size(148,210))
        try await model.insertPagePDFs(value,mode:.pairs,sizeChoice:.gang);try await settle(model)
        let file=try folder().appendingPathComponent("mixed.atispress")
        try model.saveProject(as:file)
        let opened=workspace();try await opened.loadProject(at:file);try await settle(opened)
        XCTAssertEqual(opened.plan.sheets,model.plan.sheets)
        XCTAssertEqual(try outputPixels(opened),try outputPixels(model))
        XCTAssertEqual(opened.pageListItem(model.order.last!)?.size,value.sources[0].pdf.pages.last?.trimSize)
    }
    func testRanges() {
        XCTAssertEqual(PDFPageRange.parse("1-4, 7",count:7),[1,2,3,4,7])
        XCTAssertEqual(PDFPageRange.parse("1 - 4, 7",count:7),[1,2,3,4,7])
        XCTAssertNil(PDFPageRange.parse("1-9",count:7));XCTAssertNil(PDFPageRange.parse("3-1",count:7))
        XCTAssertNil(PDFPageRange.parse("1,,2",count:7));XCTAssertEqual(PDFPageRange.parse("",count:7),[])
    }
}
