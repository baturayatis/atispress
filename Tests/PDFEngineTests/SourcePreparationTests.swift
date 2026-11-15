import XCTest
import AppKit
import ImpositionCore
@testable import PDFEngine

final class SourcePreparationTests:XCTestCase {
    func fixture(raster:Bool = false,damage:Bool = false,margin:Double = 0) throws -> (URL,URL) {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("illustrator-2x2.pdf"),pt=PDFPreviewDrawing.pointsPerMM
        var media=CGRect(x:0,y:0,width:(192+2*margin)*pt,height:(112+2*margin)*pt)
        let context=try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&media,nil))
        let box=Data(bytes:&media,count:MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextBleedBox:box,kCGPDFContextTrimBox:box] as CFDictionary)
        let c:CGContext
        if raster {c=try XCTUnwrap(CGContext(data:nil,width:1152,height:672,bitsPerComponent:8,bytesPerRow:4608,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));c.scaleBy(x:6,y:6)}
        else {c=context;c.scaleBy(x:pt,y:pt)}
        for i in 0..<4 {
            let x=Double(i%2)*96+margin,y=Double(1-i/2)*56+margin
            c.setFillColor(CGColor(red:0.95-Double(i)*0.1,green:0.95,blue:0.9,alpha:1));c.fill(CGRect(x:x,y:y,width:96,height:56))
            c.setLineWidth(0.3/pt)
            for (inset,color) in [(0.0,CGColor(red:1,green:0,blue:1,alpha:1)),(3.0,CGColor(red:1,green:0.6,blue:0.8,alpha:1)),(6.0,CGColor(red:0.5,green:0.8,blue:1,alpha:1))] {
                c.setStrokeColor(color);c.stroke(CGRect(x:x+inset,y:y+inset,width:96-2*inset,height:56-2*inset))
            }
            c.setStrokeColor(CGColor(gray:0,alpha:1));c.move(to:CGPoint(x:x+15,y:y+12));c.addLine(to:CGPoint(x:x+25,y:y+12));c.strokePath()
            c.setFillColor(CGColor(red:damage ? 0.4:Double(i%2),green:Double(i/2),blue:0.2,alpha:1));c.fill(CGRect(x:x+20,y:y+20,width:10,height:10))
        }
        if raster {context.draw(try XCTUnwrap(c.makeImage()),in:media)}
        context.endPDFPage();context.closePDF();return (dir,url)
    }
    func testDetectLearnHitAndMultiUpSuggestion() async throws {
        let (_,url)=try fixture(),source=try await PDFSource.open(url),a=source.guides
        XCTAssertEqual(a.count,12);XCTAssertEqual(a.groups.count,3)
        XCTAssertTrue(a.groups.allSatisfy(\.canHide))
        XCTAssertEqual(Set(a.groups.map(\.role)),["taşma sınırı","kesim","güvenli alan"])
        XCTAssertEqual(a.learned.count,4)
        for learned in a.learned {XCTAssertEqual(learned.trim.width,90,accuracy:0.001);XCTAssertEqual(learned.trim.height,50,accuracy:0.001);XCTAssertEqual(learned.bleed,3,accuracy:0.001)}
        let suggestion=try XCTUnwrap(a.suggestion(size:source.pages[0].trimSize))
        XCTAssertEqual(suggestion.columns,2);XCTAssertEqual(suggestion.rows,2)
        XCTAssertNotNil(a.hit(page:1,point:Point(3,20)))
        XCTAssertNil(a.hit(page:1,point:Point(18,12),tolerance:0.1),"Ordinary black artwork is not a guide")
        XCTAssertNil(PDFGuideAnalysis().suggestion(size:Size(90,50)))
        XCTAssertNil(PDFGuideAnalysis().suggestion(size:Size(210,297)))
    }
    func testSplitPairsCellsAndKeepsVectorTrimBleedAndGangBackRegistration() async throws {
        let (dir,url)=try fixture(),source=try await PDFSource.open(url)
        var settings=SourcePreparationSettings();settings.split=source.guides.suggestion(size:source.pages[0].trimSize)
        let prepared=try await source.prepared(settings)
        XCTAssertEqual(prepared.pages.count,4)
        for page in prepared.pages {XCTAssertEqual(page.trimSize.width,90,accuracy:0.001);XCTAssertEqual(page.trimSize.height,50,accuracy:0.001);XCTAssertEqual(try XCTUnwrap(page.availableBleed),3,accuracy:0.001)}
        XCTAssertEqual(prepared.preparationInput.url,url)
        XCTAssertNil(try Data(contentsOf:prepared.url).range(of:Data("/Subtype /Image".utf8)))
        let products=PDFSourcePreparation.products(settings.split!)
        let document=try XCTUnwrap(CGPDFDocument(prepared.url as CFURL))
        for n in 1...4 {
            let c=try XCTUnwrap(CGContext(data:nil,width:360,height:200,bitsPerComponent:8,bytesPerRow:1440,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            c.scaleBy(x:4,y:4);PDFPreviewDrawing.draw(try XCTUnwrap(document.page(at:n)),in:c,rect:CGRect(x:0,y:0,width:90,height:50))
            let pixel=c.data!.assumingMemoryBound(to:UInt8.self),offset=100*c.bytesPerRow+100*4
            if (n-1)%2==0 {XCTAssertLessThan(Int(pixel[offset]),80)} else {XCTAssertGreaterThan(Int(pixel[offset]),180)}
            if (n-1)/2==0 {XCTAssertLessThan(Int(pixel[offset+1]),80)} else {XCTAssertGreaterThan(Int(pixel[offset+1]),180)}
        }
        XCTAssertEqual(products.map(\.front),[1,3]);XCTAssertEqual(products.compactMap(\.back),[2,4])
        for method in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
            var p=Project(pages:prepared.pages.map(\.sourcePage),binding:.gang,sheet:SheetSpec(size:Size(330,480),margins:Insets(left:10,right:10,top:10,bottom:10),gutter:16),settings:ImpositionSettings(turnMethod:method))
            var gang=GangSettings()
            for product in products {var job=GangJob(sourceID:settings.sourceID,name:"Ürün \(product.number)",front:prepared.pages[product.front-1].sourcePage,back:product.back.map{prepared.pages[$0-1].sourcePage});job.quantity=4;gang.jobs.append(job)}
            p.gang=gang
            let plan=ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport,"\(method): \(plan.issues)")
            for sheet in plan.sheets {for front in sheet.front.slots {
                guard let id=front.gangJobID,let n=front.sourcePageNumber else {continue}
                let expected=n%2==1 ? n+1:n-1
                let backs=sheet.back.slots.filter{$0.gangJobID==id && $0.sourcePageNumber==expected}
                XCTAssertFalse(backs.isEmpty)
                // The existing turn transformation reflects physical cut positions.
                let x = method == .workAndTumble ? front.x:sheet.size.width-front.x-front.size.width
                let y = method == .workAndTumble ? sheet.size.height-front.y-front.size.height:front.y
                XCTAssertTrue(backs.contains{abs($0.x-x)<0.001 && abs($0.y-y)<0.001},"\(method): back behind front")
            }}
            let out=dir.appendingPathComponent("export-\(method).pdf")
            _=try PDFExporter.export(plan:plan,source:prepared,destination:.singlePDF(out),marks:.none)
            XCTAssertNil(try Data(contentsOf:out).range(of:Data("/Subtype /Image".utf8)))
        }
    }
    func testHidingSelectedStrokesPreservesEveryOutsidePixelAndOtherGroups() async throws {
        let (dir,url)=try fixture(),source=try await PDFSource.open(url)
        let selected=Set(source.guides.groups.filter{$0.role=="kesim"}.map(\.id)),out=dir.appendingPathComponent("hidden.pdf")
        try PDFGuideEditor.hiddenCopy(source:url,destination:out,analysis:source.guides,groups:selected)
        let hidden=try await PDFSource.open(out)
        XCTAssertEqual(hidden.guides.count,8)
        XCTAssertFalse(hidden.guides.groups.contains{$0.role=="kesim"})
        let a=try XCTUnwrap(CGPDFDocument(url as CFURL)),b=try XCTUnwrap(CGPDFDocument(out as CFURL))
        XCTAssertTrue(try PDFGuideEditor.outsidePixelsIdentical(original:a.page(at:1)!,modified:b.page(at:1)!,page:1,analysis:source.guides,groups:selected,pixelsPerMM:6))
        XCTAssertNil(try Data(contentsOf:out).range(of:Data("/Subtype /Image".utf8)))
    }
    func testPresetColumnAndSimplexAndInvalidGrid() {
        var s=PageSplitSettings(size:Size(192,112))
        s.assign(.column)
        XCTAssertEqual(s.cells.map(\.product),[1,2,1,2]);XCTAssertEqual(s.cells.map(\.side),[.front,.front,.back,.back])
        s.assign(.simplex);XCTAssertEqual(s.cells.map(\.product),[1,2,3,4]);XCTAssertTrue(s.cells.allSatisfy{$0.side == .front})
        s.verticalCuts=[0];XCTAssertNotNil(s.validation(size:Size(192,112)))
        s=PageSplitSettings(size:Size(192,112));s.cells[0].product=nil;XCTAssertNotNil(s.validation(size:Size(192,112)))
    }
    func testNoPreparationIsIdentityAndRasterFramesCannotBeHidden() async throws {
        let (_,url)=try fixture(raster:true),source=try await PDFSource.open(url)
        XCTAssertEqual(source.guides.count,0)
        XCTAssertTrue(source.guides.rasterFramesSuspected)
        let original=try Data(contentsOf:url)
        let unchanged=try await source.prepared(SourcePreparationSettings())
        XCTAssertTrue(unchanged === source);XCTAssertEqual(try Data(contentsOf:unchanged.url),original)
        do {let out=url.deletingLastPathComponent().appendingPathComponent("unsafe.pdf");try PDFGuideEditor.hiddenCopy(source:url,destination:out,analysis:source.guides,groups:["raster-frame"]);XCTFail("Raster guide removal must refuse")} catch {XCTAssertEqual(error.localizedDescription,SourcePreparationError.unsafeGuides.localizedDescription)}
    }
    func testPixelGuardRejectsArtworkDamageEvenInsideAnOuterFrame() async throws {
        let (_,url)=try fixture(),(_,bad)=try fixture(damage:true)
        let source=try await PDFSource.open(url),a=try XCTUnwrap(CGPDFDocument(url as CFURL)),b=try XCTUnwrap(CGPDFDocument(bad as CFURL))
        XCTAssertFalse(try PDFGuideEditor.outsidePixelsIdentical(original:a.page(at:1)!,modified:b.page(at:1)!,page:1,analysis:source.guides,groups:Set(source.guides.groups.map(\.id)),pixelsPerMM:4))
    }
    func testNamedOCGLayerDetectionAndTransparencyRefusal() async throws {
        let (dir,_)=try fixture()
        for transparent in [false,true] {
            let content="q /OC /G1 BDC /GS gs 0.3 w 0 G 10 10 100 50 re S EMC Q"
            let gs=transparent ? " /ExtGState << /GS << /Type /ExtGState /CA 0.5 >> >>":""
            let stream=transparent ? content:content.replacingOccurrences(of:"/GS gs ",with:"")
            let objects=["<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] /D << /ON [5 0 R] >> >> >>","<< /Type /Pages /Count 1 /Kids [3 0 R] >>","<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Properties << /G1 5 0 R >> "+gs+" >> /Contents 4 0 R >>","<< /Length \(stream.utf8.count) >>\nstream\n"+stream+"\nendstream","<< /Type /OCG /Name (Trim Guide) >>"]
            var pdf=Data("%PDF-1.4\n".utf8),offsets:[Int]=[]
            for (i,obj) in objects.enumerated() {offsets.append(pdf.count);pdf.append(Data("\(i+1) 0 obj\n\(obj)\nendobj\n".utf8))}
            let xref=pdf.count;pdf.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8));for offset in offsets {pdf.append(Data(String(format:"%010d 00000 n \n",offset).utf8))};pdf.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
            let url=dir.appendingPathComponent("layer-\(transparent).pdf");try pdf.write(to:url)
            let source=try await PDFSource.open(url)
            XCTAssertEqual(source.guides.count,1)
            XCTAssertEqual(source.guides.groups.first?.layer,"Trim Guide")
            XCTAssertEqual(source.guides.groups.first?.role,"kesim")
            XCTAssertEqual(source.guides.groups.first?.canHide,!transparent)
            if !transparent {
                try PDFGuideEditor.hiddenCopy(source:url,destination:dir.appendingPathComponent("opaque-hidden.pdf"),analysis:source.guides,groups:Set(source.guides.groups.map(\.id)))
            }
            if transparent {
                do {try PDFGuideEditor.hiddenCopy(source:url,destination:dir.appendingPathComponent("refused.pdf"),analysis:source.guides,groups:Set(source.guides.groups.map(\.id)));XCTFail("Transparency must refuse")} catch {XCTAssertEqual(error.localizedDescription,SourcePreparationError.unsafeGuides.localizedDescription)}
            }
        }
    }

    func testNestedFormFramesAreDetectedAndLearnedButReadOnly() async throws {
        let (dir,_)=try fixture(),pt=PDFPreviewDrawing.pointsPerMM
        var stream="0.3 w "
        for i in 0..<4 {for (inset,color) in [(0.0,"1 0 1"),(3.0,"1 0.6 0.8"),(6.0,"0.5 0.8 1")] {
            stream+="\(color) RG \((Double(i%2)*96+inset)*pt) \((Double(i/2)*56+inset)*pt) \((96-2*inset)*pt) \((56-2*inset)*pt) re S "
        }}
        let objects=["<< /Type /Catalog /Pages 2 0 R >>","<< /Type /Pages /Count 1 /Kids [3 0 R] >>","<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(192*pt) \(112*pt)] /Resources << /XObject << /F1 5 0 R >> >> /Contents 4 0 R >>","<< /Length 6 >>\nstream\n/F1 Do\nendstream","<< /Type /XObject /Subtype /Form /BBox [0 0 \(192*pt) \(112*pt)] /Resources << >> /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"]
        var pdf=Data("%PDF-1.4\n".utf8),offsets:[Int]=[]
        for (i,obj) in objects.enumerated() {offsets.append(pdf.count);pdf.append(Data("\(i+1) 0 obj\n\(obj)\nendobj\n".utf8))}
        let xref=pdf.count;pdf.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8));for offset in offsets {pdf.append(Data(String(format:"%010d 00000 n \n",offset).utf8))};pdf.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let wrapped=dir.appendingPathComponent("form.pdf");try pdf.write(to:wrapped)
        let source=try await PDFSource.open(wrapped)
        XCTAssertEqual(source.guides.count,12)
        XCTAssertTrue(source.guides.groups.allSatisfy{!$0.canHide})
        XCTAssertEqual(source.guides.learned.count,4)
        XCTAssertNotNil(source.guides.hit(page:1,point:Point(3,20)))
        XCTAssertEqual(source.guides.suggestion(size:source.pages[0].trimSize)?.columns,2)
    }

    func testGridAndGuideFieldsRoundTripAndPreparationOrderIsIndependent() async throws {
        let (_,url)=try fixture(),source=try await PDFSource.open(url)
        var p=SourcePreparationSettings();p.split=source.guides.suggestion(size:source.pages[0].trimSize)
        func pixels(_ s:PDFSource) throws -> [Data] {
            let d=try XCTUnwrap(CGPDFDocument(s.url as CFURL))
            return try (1...d.numberOfPages).map {n in
                let c=try XCTUnwrap(CGContext(data:nil,width:384,height:224,bitsPerComponent:8,bytesPerRow:1536,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:384,height:224))
                let page=d.page(at:n)!;c.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(x:0,y:0,width:384,height:224),rotate:0,preserveAspectRatio:true));c.drawPDFPage(page)
                return Data(bytes:c.data!,count:c.bytesPerRow*c.height)
            }
        }
        let baseline=try await source.prepared(p),reference=try pixels(baseline)
        let edits:[(inout PageSplitSettings)->Void] = [{$0.verticalCuts[0]+=0.5},{$0.horizontalCuts[0]+=0.5},{$0.explicitTrim?.width+=0.5},{$0.assign(.column)},{$0.assign(.simplex)},{$0.cells[1].product=nil},{$0.explicitTrim=nil;$0.cellBleed=2}]
        for edit in edits {
            var changed=p;edit(&changed.split!)
            let result=try await baseline.prepared(changed);_ = try pixels(result)
            let reverted=try await result.prepared(p)
            XCTAssertEqual(reverted.pages.map(\.sourcePage),baseline.pages.map(\.sourcePage))
            XCTAssertEqual(try pixels(reverted),reference)
        }
        var hidden=p;hidden.hiddenGuideGroups=source.guides.groups.filter{$0.role=="kesim"}.map(\.id)
        let splitThenHide=try await baseline.prepared(hidden)
        var hideOnly=hidden;hideOnly.split=nil
        let filtered=try await source.prepared(hideOnly),hideThenSplit=try await filtered.prepared(hidden)
        XCTAssertEqual(try pixels(splitThenHide),try pixels(hideThenSplit))
    }

    func testLearnedTrimCentersSurviveOuterPageMarginsAndOriginalOverwriteIsRefused() async throws {
        let (_,url)=try fixture(margin:8),source=try await PDFSource.open(url)
        var p=SourcePreparationSettings();p.split=source.guides.suggestion(size:source.pages[0].trimSize)
        XCTAssertEqual(p.split?.learnedTrimCenters?.count,4)
        let result=try await source.prepared(p)
        XCTAssertEqual(result.pages.map(\.trimSize),Array(repeating:Size(90,50),count:4))
        XCTAssertTrue(result.pages.allSatisfy{abs(($0.availableBleed ?? 0)-3)<0.001})
        let doc=try XCTUnwrap(CGPDFDocument(result.url as CFURL)),pt=PDFPreviewDrawing.pointsPerMM
        // Left and right products have different source whitespace; their trim
        // boxes must follow the learned frames rather than centering in the cell.
        XCTAssertGreaterThan(doc.page(at:1)!.getBoxRect(.trimBox).minX,10*pt)
        XCTAssertEqual(doc.page(at:2)!.getBoxRect(.trimBox).minX,3*pt,accuracy:0.001)
        let data=try Data(contentsOf:url)
        do {try PDFSourcePreparation.split(source:url,destination:url,settings:p.split!);XCTFail("Source overwrite")} catch {XCTAssertTrue(error is PDFExportError)}
        do {try PDFGuideEditor.hiddenCopy(source:url,destination:url,analysis:source.guides,groups:Set(source.guides.groups.map(\.id)));XCTFail("Source overwrite")} catch {XCTAssertTrue(error is PDFExportError)}
        XCTAssertEqual(try Data(contentsOf:url),data)
    }

}
