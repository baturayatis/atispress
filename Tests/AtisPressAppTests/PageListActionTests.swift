import XCTest
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class PageListActionTests:XCTestCase {
    private func folder() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:url)}
        return url
    }
    private func workspace() -> Workspace {
        let name="PageList-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        addTeardownBlock {defaults.removePersistentDomain(forName:name)}
        return Workspace(bookmarkCreator:{try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)},uiDefaults:defaults)
    }
    private func loaded() async throws -> Workspace {
        let url=try folder().appendingPathComponent("source.pdf")
        var box=CGRect(x:0,y:0,width:100*72/25.4,height:140*72/25.4)
        let context=try XCTUnwrap(CGContext(consumer:CGDataConsumer(url:url as CFURL)!,mediaBox:&box,nil))
        for n in 1...4 {
            context.beginPDFPage(nil);context.setFillColor(CGColor(red:Double(n)/5,green:0.2,blue:0.7,alpha:1));context.fill(box);context.endPDFPage()
        }
        context.closePDF()
        let model=workspace();model.open(url,confirmChanges:false);try await settle(model)
        model.project.settings.generatedBleed.enabled=false;model.project.settings.bleed=0
        try await settle(model);model.flushUndoEdits()
        return model
    }
    private func settle(_ model:Workspace) async throws {
        for _ in 0..<1000 {
            if !model.loading && !model.planning && !model.samplingBleed && !model.autoArranging {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Plan did not settle")
    }
    private func pixels(_ model:Workspace) throws -> [Data] {
        let file=try folder().appendingPathComponent("output.pdf")
        _ = try PDFExporter.export(plan:model.plan,source:try XCTUnwrap(model.source),destination:.singlePDF(file),marks:model.project.exportMarks)
        let bytes=try Data(contentsOf:file)
        XCTAssertNil(bytes.range(of:Data("/Subtype /Image".utf8)),"Page operations must preserve vector artwork")
        let document=try XCTUnwrap(CGPDFDocument(file as CFURL))
        return try (1...document.numberOfPages).map {index in
            let page=try XCTUnwrap(document.page(at:index))
            let bitmap=try XCTUnwrap(CGContext(data:nil,width:200,height:150,bitsPerComponent:8,bytesPerRow:800,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(CGColor(gray:1,alpha:1));bitmap.fill(CGRect(x:0,y:0,width:200,height:150))
            bitmap.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(x:0,y:0,width:200,height:150),rotate:0,preserveAspectRatio:true));bitmap.drawPDFPage(page)
            return Data(bytes:bitmap.data!,count:bitmap.bytesPerRow*bitmap.height)
        }
    }
    func testDuplexCopiesWholeProductAndReferencesOriginalSourcePages() async throws {
        let model=try await loaded(),original=try Data(contentsOf:model.source!.url)
        XCTAssertEqual(model.project.repeatJobs.count,2)
        model.duplicatePages([1]);try await settle(model)
        XCTAssertEqual(model.order,[1,2,5,6,3,4])
        XCTAssertEqual(model.project.repeatJobs.count,3)
        XCTAssertEqual(model.pageListTitle(5),"Sayfa 1 (kopya 2)")
        let copied=model.plan.sheets.filter{$0.repeatLayout?.jobIndex==1}
        XCTAssertFalse(copied.isEmpty)
        XCTAssertEqual(Set(copied.flatMap{$0.front.slots.compactMap(\.sourcePageNumber)}),[1])
        XCTAssertEqual(Set(copied.flatMap{$0.back.slots.compactMap(\.sourcePageNumber)}),[2])
        XCTAssertEqual(try Data(contentsOf:model.source!.url),original)
        _ = try pixels(model)
    }
    func testSinglePageCopiesCountBoundsAndLabels() async throws {
        let model=try await loaded()
        model.duplicatePages([2],copies:3,wholePairs:false);try await settle(model)
        XCTAssertEqual(model.order.count,7)
        XCTAssertEqual(model.pageListItems.filter{$0.sourcePage==2}.map(\.copyNumber).sorted(),[1,2,3,4])
        let count=model.order.count
        model.duplicatePages([1],copies:100);XCTAssertEqual(model.order.count,count)
        model.duplicatePages([1],copies:0);XCTAssertEqual(model.order.count,count)
    }
    func testCopiesRetainSerialAndPerJobScalingAndNinetyNineCopiesWork() async throws {
        let model=try await loaded()
        var field=SerialField();field.jobIndex=1;model.project.serialFields=[field]
        model.setScale(RescaleSettings(target:Size(80,110)),pages:[3,4],gangID:nil,jobIndex:1)
        try await settle(model)
        model.duplicatePages([1]);try await settle(model)
        XCTAssertEqual(model.project.serialFields.first?.jobIndex,2)
        XCTAssertEqual(model.project.scalingSettings(number:3,jobIndex:2)?.target,Size(80,110))
        model.duplicatePages([3]);try await settle(model)
        XCTAssertEqual(model.project.serialFields.count,2)
        XCTAssertEqual(Set(model.project.serialFields.map(\.jobIndex)),[2,3])
        let copy=try XCTUnwrap(model.pageListItems.last(where:{$0.sourcePage==3}))
        XCTAssertEqual(model.project.scalingSettings(number:copy.id,jobIndex:3)?.target,Size(80,110))
        let repeated=try await loaded()
        repeated.duplicatePages([1],copies:99);try await settle(repeated)
        XCTAssertEqual(repeated.order.count,202)
        XCTAssertEqual(repeated.pageListItems.filter{$0.sourcePage==1}.count,100)
    }
    func testEditedListCanAddGangSourcesAndSeparateCoverAndReopen() async throws {
        let gang=try await loaded()
        gang.duplicatePages([1]);try await settle(gang)
        gang.setMode(.gang);try await settle(gang)
        XCTAssertEqual(gang.project.gang?.jobs.count,3)
        gang.addGangPDFs([gang.source!.url]);try await settle(gang)
        XCTAssertNil(gang.error)
        XCTAssertEqual(gang.project.gang?.jobs.count,5)
        let gangFile=try folder().appendingPathComponent("gang.atispress")
        try gang.saveProject(as:gangFile)
        let reopened=workspace();try await reopened.loadProject(at:gangFile);try await settle(reopened)
        XCTAssertEqual(reopened.plan.sheets,gang.plan.sheets)
        _ = try pixels(reopened)
        let book=try await loaded();book.setMode(.saddleStitch);try await settle(book)
        book.insertBlankPages([1]);try await settle(book)
        let oldOrder=book.order
        book.loadCoverPDF(book.source!.url);try await settle(book)
        XCTAssertNil(book.error)
        XCTAssertEqual(Array(book.order.prefix(oldOrder.count)),oldOrder)
        let bookFile=try folder().appendingPathComponent("book.atispress")
        try book.saveProject(as:bookFile)
        let openedBook=workspace();try await openedBook.loadProject(at:bookFile);try await settle(openedBook)
        XCTAssertEqual(openedBook.project,book.project)
    }
    func testLegacySchemaNineteenOpensAndInvalidOccurrenceReferencesAreRejected() async throws {
        let model=try await loaded()
        var old=ProjectDocument(state:model.state);old.version=19
        let decoded=try ProjectDocument.decode(old.encoded())
        XCTAssertNil(decoded.state.project.pageItems)
        XCTAssertEqual(ImpositionPlanner.plan(decoded.state.project).sheets,model.plan.sheets)
        model.insertBlankPages([1]);try await settle(model)
        var malformed=ProjectDocument(state:model.state)
        malformed.state.project.pageItems![0].sourcePage=99
        XCTAssertThrowsError(try ProjectDocument.decode(malformed.encoded()))
    }
    func testDeletedOccurrenceIDsAreNeverReused() async throws {
        let model=try await loaded()
        model.duplicatePages([1]);try await settle(model)
        let copies=Set(model.pageListItems.filter{$0.copyNumber>1}.map(\.id))
        model.deletePages(copies);try await settle(model)
        model.insertBlankPages([1]);try await settle(model)
        XCTAssertTrue(copies.isDisjoint(with:model.selectedPages))
        let file=try folder().appendingPathComponent("ids.atispress")
        try model.saveProject(as:file)
        let reopened=workspace();try await reopened.loadProject(at:file);try await settle(reopened)
        let oldIDs=Set(reopened.order)
        reopened.insertBlankPages();try await settle(reopened)
        XCTAssertTrue(oldIDs.isDisjoint(with:reopened.selectedPages))
    }
    func testInvalidSelectionDoesNothingAndExhaustedIDsFailWithoutMutation() async throws {
        let model=try await loaded(),before=model.project
        model.duplicatePages([999]);model.deletePages([999]);model.movePages([999],toEnd:true)
        XCTAssertEqual(model.project,before)
        var maximum=before
        maximum.pageItems=[PageListItem(id:Int.max,sourcePage:1,size:model.source!.pages[0].trimSize,availableBleed:model.source!.pages[0].availableBleed)]
        model.commitPageList(maximum,order:[Int.max],included:[Int.max],selection:[Int.max])
        let saved=model.project
        model.duplicatePages([Int.max]);XCTAssertEqual(model.project,saved)
        XCTAssertNotNil(model.error)
        model.insertBlankPages([Int.max]);XCTAssertEqual(model.project,saved)
    }
    func testDeleteInclusionAndSelectionAreIndependent() async throws {
        let model=try await loaded()
        model.selectedPages=[1,2]
        XCTAssertEqual(model.pageActionSelection(1),[1,2]);XCTAssertEqual(model.pageActionSelection(3),[3])
        model.setIncluded(1,false);XCTAssertTrue(model.order.contains(1))
        model.setIncluded(1,true)
        model.deletePages([2]);try await settle(model)
        XCTAssertEqual(model.order,[3,4]);XCTAssertEqual(model.project.pages.map(\.number),[3,4])
        model.undoEdit();try await settle(model);XCTAssertEqual(model.order,[1,2,3,4])
        model.redoEdit();try await settle(model);XCTAssertEqual(model.order,[3,4])
        model.deletePages([3,4]);try await settle(model)
        XCTAssertTrue(model.order.isEmpty);XCTAssertFalse(model.plan.canExport)
    }
    func testBlankOrderBookletCountAndExplicitBlankExport() async throws {
        let model=try await loaded();model.setMode(.saddleStitch);try await settle(model)
        model.insertBlankPages([2],above:true);try await settle(model)
        XCTAssertEqual(model.order,[1,5,2,3,4])
        XCTAssertEqual(model.pageListTitle(5),"Boş")
        XCTAssertEqual(model.pageListItem(5)?.size,model.source?.pages[1].trimSize)
        XCTAssertEqual(model.project.pages.count,5);XCTAssertEqual(model.plan.addedBlankPages,3)
        XCTAssertTrue(model.pageListBookletSummary?.contains("5 sayfa") == true)
        XCTAssertTrue(model.plan.sheets.flatMap{$0.front.slots+$0.back.slots}.contains{$0.insertedBlank && $0.sourcePageNumber==nil})
        _ = try pixels(model)
        model.movePages([5,3],toEnd:false);try await settle(model)
        XCTAssertEqual(model.order,[5,3,1,2,4])
        model.move(IndexSet(integer:0),to:5);try await settle(model)
        XCTAssertEqual(model.order,[3,1,2,4,5])
        model.undoEdit();try await settle(model);XCTAssertEqual(model.order,[5,3,1,2,4])
    }
    func testActionsSaveOpenAndUndoRestoreIdenticalLegacyPlanAndPDF() async throws {
        for mode in [BindingMethod.stepAndRepeat,.saddleStitch,.spiral] {
            let model=try await loaded();model.setMode(mode);try await settle(model);model.flushUndoEdits()
            let original=model.project,plan=model.plan,bitmap=try pixels(model)
            model.duplicatePages([1],copies:2);try await settle(model)
            model.undoEdit();try await settle(model)
            XCTAssertEqual(model.project,original);XCTAssertEqual(model.plan.sheets,plan.sheets);XCTAssertEqual(try pixels(model),bitmap)
            model.redoEdit();try await settle(model)
            if mode == .saddleStitch {
                let copyIDs=Set(model.pageListItems.filter{$0.copyNumber>1}.map(\.id))
                XCTAssertTrue(copyIDs.isSubset(of:Set(model.plan.readingOrder.compactMap{$0})))
            }
            model.insertBlankPages([1]);try await settle(model)
            model.movePages(model.selectedPages,toEnd:true);try await settle(model)
            let file=try folder().appendingPathComponent("saved.atispress")
            try model.saveProject(as:file)
            let decoded=try ProjectDocument.decode(Data(contentsOf:file))
            XCTAssertEqual(decoded.version,20);XCTAssertEqual(decoded.state.sourcePageCount,4)
            let reopened=workspace();try await reopened.loadProject(at:file);try await settle(reopened)
            XCTAssertEqual(reopened.order,model.order);XCTAssertEqual(reopened.project,model.project)
            XCTAssertEqual(reopened.plan.sheets,model.plan.sheets);XCTAssertEqual(try pixels(reopened),try pixels(model))
        }
    }
}
