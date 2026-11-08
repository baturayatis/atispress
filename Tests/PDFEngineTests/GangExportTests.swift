import XCTest
import CoreGraphics
import PDFKit
import ImpositionCore
import PDFEngine

final class GangExportTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    private func source(_ url: URL,size: Size,color: [CGFloat],pages: Int = 1) async throws -> PDFSource {
        var media = CGRect(x:0,y:0,width:size.width*72/25.4,height:size.height*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&media,nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(colorSpace:CGColorSpaceCreateDeviceCMYK(),components:color+[1])!)
            context.fill(media); context.endPDFPage()
        }
        context.closePDF(); return try await PDFSource.open(url)
    }
    private static func imageCount(_ dictionary: CGPDFDictionaryRef?) -> Int {
        guard let dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?,objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources),let resources,
              CGPDFDictionaryGetDictionary(resources,"XObject",&objects),let objects else { return 0 }
        var count = 0
        withUnsafeMutablePointer(to:&count) { pointer in
            CGPDFDictionaryApplyFunction(objects,{ _,object,info in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object,.stream,&stream),let stream,let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var type: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(dictionary,"Subtype",&type),let type {
                    let count = String(cString:type)=="Image" ? 1 : GangExportTests.imageCount(dictionary)
                    info!.assumingMemoryBound(to:Int.self).pointee += count
                }
            },pointer)
        }
        return count
    }
    func testMultipleSourcesRemainVectorAndEveryJobsSerialsMatchSharedPlan() async throws {
        let folder = try folder()
        let a = try await source(folder.appendingPathComponent("a.pdf"),size:Size(60,40),color:[1,0,0,0],pages:2)
        let b = try await source(folder.appendingPathComponent("b.pdf"),size:Size(45,65),color:[0,1,0,0])
        let combined = try await PDFSource.combine([a,b])
        XCTAssertEqual(combined.pages.count,3); XCTAssertTrue(combined.protectedURLs.contains(a.url)); XCTAssertTrue(combined.protectedURLs.contains(b.url))
        var project = Project(pages:combined.pages.map(\.sourcePage),binding:.gang,sheet:SheetSpec(preset:.cm33x48,margins:Insets(left:15,right:15,top:15,bottom:15),gripperWidth:0,gutter:0))
        var j1 = GangJob(sourceID:UUID(),name:"Mavi",front:project.pages[0],back:project.pages[1]); j1.quantity = 75; j1.bleed = 0; j1.serialFields = [SerialField(prefix:"AA-",sides:.both,position:Point(10,10))]
        var j2 = GangJob(sourceID:UUID(),name:"Mor",front:project.pages[2]); j2.quantity = 50; j2.bleed = 0; j2.serialFields = [SerialField(prefix:"BB-",position:Point(10,10),mode:.stack)]
        var qr = SerialField(position:Point(5,15)); qr.kind = .qr; qr.codeSettings.width = 15; qr.codeSettings.height = 15; qr.codeSettings.template = "https://site.test/{no}"; j2.serialFields.append(qr)
        var gang = GangSettings(); gang.jobs = [j1,j2]; project.gang = gang
        let plan = ImpositionPlanner.plan(project),sheet = try XCTUnwrap(plan.sheets.first)
        XCTAssertTrue(plan.canExport,"\(plan.issues)")
        let url = folder.appendingPathComponent("out.pdf")
        let result = try PDFExporter.export(plan:plan,source:combined,destination:.singlePDF(url),marks:.none)
        XCTAssertEqual(result.pageCount,sheet.repeatCount*2)
        let pdf = try XCTUnwrap(PDFDocument(url:url)),cg = try XCTUnwrap(CGPDFDocument(url as CFURL))
        for r in 0..<sheet.repeatCount {
            for (kind,face) in [(SideKind.front,sheet.front),(.back,sheet.back)] {
                let page = try XCTUnwrap(pdf.page(at:r*2+(kind == .front ? 0 : 1))),text = page.string ?? ""
                for serial in sheet.serialPlacements(side:face,kind:kind,repetition:r) where serial.field.kind == .text {
                    let range = (text as NSString).range(of:serial.text)
                    XCTAssertNotEqual(range.location,NSNotFound,"Missing \(serial.text)")
                    guard range.location != NSNotFound else { continue }
                    let actual = try XCTUnwrap(page.selection(for:range)).bounds(for:page)
                    let slot = face.slots[serial.slotIndex]
                    let mm = PDFSerialDrawing.bounds(serial).applying(PDFSerialDrawing.transform(serial)).applying(PDFPreviewDrawing.slotTransform(slot))
                    let expected = mm.applying(CGAffineTransform(scaleX:72/25.4,y:72/25.4))
                    XCTAssertEqual(actual.minX,expected.minX,accuracy:2)
                    XCTAssertEqual(actual.maxX,expected.maxX,accuracy:2)
                    XCTAssertEqual(actual.minY,expected.minY,accuracy:2)
                    XCTAssertEqual(actual.maxY,expected.maxY,accuracy:2)
                }
            }
        }
        var info = SheetInfoSettings(); info.jobName = "Toplu üretim"
        let strip = PDFSheetInfoContext(jobName:"ignored",sheetNumber:1,totalSheets:sheet.repeatCount,side:.front).text(settings:info,sheet:sheet)
        XCTAssertTrue(strip.contains("Mavi, Mor")); XCTAssertTrue(strip.contains("Toplu üretim"))
        for i in 1...cg.numberOfPages { XCTAssertEqual(Self.imageCount(cg.page(at:i)?.dictionary),0) }
        XCTAssertEqual(sheet.gangJobNames,"Mavi, Mor")
        XCTAssertTrue(sheet.back.slots.filter { $0.gangJobID==j2.id }.allSatisfy { $0.sourcePageNumber==nil })
        XCTAssertThrowsError(try PDFExporter.export(plan:plan,source:combined,destination:.singlePDF(a.url),marks:.none))
        XCTAssertThrowsError(try PDFExporter.export(plan:plan,source:combined,destination:.singlePDF(b.url),marks:.none))
    }
    func testGuillotineMarksNeverTouchAnyArtworkOrBleedAndSingleSidesStayFrontOnly() async throws {
        let folder = try folder(),a = try await source(folder.appendingPathComponent("a.pdf"),size:Size(55,35),color:[0,0,0,1])
        var project = Project(pages:a.pages.map(\.sourcePage),binding:.gang,sheet:SheetSpec(preset:.sra3,margins:Insets(left:10,right:10,top:10,bottom:10),gripperWidth:0,gutter:0))
        var settings = GangSettings()
        for i in 0..<3 { var job = GangJob(sourceID:UUID(),name:"İş \(i)",front:project.pages[0]); job.quantity = 50+i*10; job.generatedBleed.enabled = true; job.generatedBleed.method = .solidColor; settings.jobs.append(job) }
        project.gang = settings
        let plan = ImpositionPlanner.plan(project),sheet = try XCTUnwrap(plan.sheets.first)
        XCTAssertTrue(plan.canExport,"\(plan.issues)")
        let geometry = PDFExportMarkRenderer.geometry(side:sheet.front,sheet:sheet,settings:ExportMarks())
        XCTAssertFalse(geometry.segments.isEmpty)
        for mark in geometry.segments {
            let segment = CGRect(x:min(mark.start.x,mark.end.x),y:min(mark.start.y,mark.end.y),width:abs(mark.start.x-mark.end.x),height:abs(mark.start.y-mark.end.y)).insetBy(dx:-0.001,dy:-0.001)
            for slot in sheet.front.slots {
                let r = try XCTUnwrap(slot.artworkClip)
                XCTAssertFalse(segment.intersects(CGRect(x:r.origin.x,y:r.origin.y,width:r.size.width,height:r.size.height)))
            }
        }
        let result = try PDFExporter.export(plan:plan,source:a,destination:.singlePDF(folder.appendingPathComponent("out.pdf")),marks:.none)
        XCTAssertEqual(result.pageCount,sheet.repeatCount)
        XCTAssertTrue(result.notes.contains { $0.contains("Arka yüz boş") })
        let perSheet = folder.appendingPathComponent("sheets"); try FileManager.default.createDirectory(at:perSheet,withIntermediateDirectories:true)
        let split = try PDFExporter.export(plan:plan,source:a,destination:.perSheet(directory:perSheet,baseName:"gang"),marks:.none)
        for file in split.files { XCTAssertEqual(PDFDocument(url:file)?.pageCount,1) }
    }
}
