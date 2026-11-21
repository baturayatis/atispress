import XCTest
import CoreGraphics
import CoreText
import PDFKit
import ImpositionCore
import PDFEngine

final class BookExportTests: XCTestCase {
    private let unit = 72.0/25.4
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    private func fixture(_ url: URL,count: Int,size: Size,prefix: String = "SRC") throws {
        var box = CGRect(x:0,y:0,width:size.width*unit,height:size.height*unit)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&box,nil))
        for i in 1...count {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(colorSpace:CGColorSpaceCreateDeviceCMYK(),components:[0,0,0,1,1])!)
            let text = String(format:"%@%02d",prefix,i)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,12,nil)]))
            context.textMatrix = .identity; context.textPosition = CGPoint(x:5*unit,y:20*unit); CTLineDraw(line,context)
            context.endPDFPage()
        }
        context.closePDF()
    }
    private static func images(_ dictionary: CGPDFDictionaryRef?) -> Int {
        guard let dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?,objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources),let resources,CGPDFDictionaryGetDictionary(resources,"XObject",&objects),let objects else { return 0 }
        var count = 0
        withUnsafeMutablePointer(to:&count) { pointer in
            CGPDFDictionaryApplyFunction(objects,{ _,object,info in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object,.stream,&stream),let stream,let d = CGPDFStreamGetDictionary(stream) else { return }
                var type: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(d,"Subtype",&type),let type { info!.assumingMemoryBound(to:Int.self).pointee += String(cString:type)=="Image" ? 1 : BookExportTests.images(d) }
            },pointer)
        }
        return count
    }
    func testCreepMovesExportedVectorTextExactlyAsPreviewPlanAndKeepsCoversIndependent() async throws {
        let folder = try folder(),url = folder.appendingPathComponent("book.pdf")
        try fixture(url,count:20,size:Size(50,70)); let source = try await PDFSource.open(url)
        var p = Project(pages:source.pages.map(\.sourcePage),binding:.saddleStitch,sheet:SheetSpec(size:Size(117,87),orientation:.landscape))
        var book = BookSettings(); book.interiorPaper.microns = 1000; book.coverPaper.microns = 500; book.creepEnabled = true; p.book = book
        p.settings.generatedBleed = GeneratedBleedSettings(enabled:true,method:.solidColor,color:.cmyk(0,0,0,0))
        let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertEqual(plan.sheets.count,5)
        let out = folder.appendingPathComponent("out.pdf"),result = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(out),marks:.none)
        XCTAssertEqual(result.pageCount,10)
        let pdf = try XCTUnwrap(PDFDocument(url:out)),cg = try XCTUnwrap(CGPDFDocument(out as CFURL))
        for (index,sheet) in plan.sheets.enumerated() {
            for (face,side) in [(0,sheet.front),(1,sheet.back)] {
                let page = try XCTUnwrap(pdf.page(at:index*2+face)),text = page.string ?? ""
                for slot in side.slots {
                    guard let number = slot.sourcePageNumber else { continue }
                    let label = String(format:"SRC%02d",number),range = (text as NSString).range(of:label)
                    XCTAssertNotEqual(range.location,NSNotFound)
                    guard range.location != NSNotFound else { continue }
                    let bounds = try XCTUnwrap(page.selection(for:range)).bounds(for:page)
                    XCTAssertEqual(bounds.minX,(slot.x+5+slot.artworkOffset.x)*unit,accuracy:1.5)
                    if sheet.bookInfo?.section == .cover { XCTAssertEqual(slot.artworkOffset,Point(0,0)) }
                }
                XCTAssertFalse(text.contains("Sırt")); XCTAssertFalse(text.contains("İç sayfalar"))
                XCTAssertEqual(Self.images(cg.page(at:index*2+face+1)?.dictionary),0)
            }
        }
    }
    func testSeparateCoverSpreadRemainsVectorAtNativeSizeAndInfoStripUsesSection() async throws {
        let folder = try folder(),insideURL = folder.appendingPathComponent("inside.pdf"),coverURL = folder.appendingPathComponent("cover.pdf")
        try fixture(insideURL,count:8,size:Size(50,70)); try fixture(coverURL,count:2,size:Size(115.48,70),prefix:"COVER")
        let inside = try await PDFSource.open(insideURL),cover = try await PDFSource.open(coverURL)
        let combined = try await PDFSource.combine([inside,cover],displayName:"Kitap ve kapak")
        var p = Project(pages:combined.pages.map(\.sourcePage),binding:.perfectBound,sheet:SheetSpec(preset:.cm50x70))
        p.settings.signatureSize = .eight
        var book = BookSettings(); book.interiorPaper.microns = 120; book.coverPaper.microns = 250; book.leftFlap = 10; book.rightFlap = 5
        book.coverSourceID = UUID(); book.coverPDFPages = [9,10]; book.auxiliaryPages = [9,10]; book.coverArtwork = .spread
        p.book = book; p.coverMode = .separate
        let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertFalse(plan.issues.contains { $0.message.contains("hesaplanan açılım") })
        let coverSheet = try XCTUnwrap(plan.sheets.first { $0.bookInfo?.section == .cover })
        XCTAssertEqual(try XCTUnwrap(coverSheet.bookInfo?.spine),0.48,accuracy:0.000001)
        XCTAssertEqual(try XCTUnwrap(coverSheet.bookInfo?.spreadSize.width),115.48,accuracy:0.001)
        XCTAssertTrue(PDFSheetInfoContext(jobName:"Kitap",sheetNumber:1,totalSheets:plan.totalPressSheets,side:.front).text(settings:SheetInfoSettings(),sheet:coverSheet).contains("Kapak"))
        let out = folder.appendingPathComponent("vector.pdf")
        let result = try PDFExporter.export(plan:plan,source:combined,destination:.singlePDF(out),marks:.none)
        let pdf = try XCTUnwrap(PDFDocument(url:out)),cg = try XCTUnwrap(CGPDFDocument(out as CFURL))
        XCTAssertEqual(result.sheetCount,plan.totalPressSheets)
        let text = pdf.string ?? ""; XCTAssertTrue(text.contains("COVER01")); XCTAssertTrue(text.contains("COVER02"))
        for i in 1...cg.numberOfPages { XCTAssertEqual(Self.images(cg.page(at:i)?.dictionary),0) }
        for i in 0..<pdf.pageCount { XCTAssertEqual(try XCTUnwrap(pdf.page(at:i)).bounds(for:.mediaBox).width,plan.sheets[i/2].size.width*unit,accuracy:0.01) }
    }
    func testSewnFourPage106WithSeparateCoverAndEveryBlankModeExportsPlannedVectorFaces() async throws {
        let folder = try folder(),bodyURL = folder.appendingPathComponent("inside106.pdf"),coverURL = folder.appendingPathComponent("cover4.pdf")
        try fixture(bodyURL,count:106,size:Size(148,210),prefix:"BODY")
        try fixture(coverURL,count:4,size:Size(148,210),prefix:"COVER")
        let body = try await PDFSource.open(bodyURL),cover = try await PDFSource.open(coverURL),source = try await PDFSource.combine([body,cover])
        var p = Project(pages:source.pages.map(\.sourcePage),binding:.sewn,sheet:SheetSpec(preset:.a4,orientation:.landscape))
        p.settings.signatureSize = .four; p.settings.bleed = 0; p.settings.cropMarkLength = 0; p.settings.cropMarkOffset = 3.5
        var book = BookSettings(); book.coverSourceID = UUID(); book.coverPDFPages = Array(107...110); book.auxiliaryPages = book.coverPDFPages
        p.book = book; p.coverMode = .separate
        for mode in [BlankPlacement.Mode.end,.start,.manual] {
            var setting = BlankPlacement(); setting.mode = mode; setting.positions = [1,55]; p.blankPlacement = setting
            let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,plan.issues.map(\.message).joined(separator:"\n"))
            XCTAssertEqual(plan.signatureCount,27); XCTAssertEqual(plan.addedBlankPages,2)
            let output = folder.appendingPathComponent("four-\(mode).pdf")
            let result = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(output),marks:.none)
            XCTAssertEqual(result.pageCount,56); XCTAssertEqual(result.sheetCount,28)
            let pdf = try XCTUnwrap(PDFDocument(url:output)),cg = try XCTUnwrap(CGPDFDocument(output as CFURL))
            for (index,sheet) in plan.sheets.enumerated() {
                for (face,side) in [(0,sheet.front),(1,sheet.back)] {
                    let page = try XCTUnwrap(pdf.page(at:index*2+face)),text = page.string ?? ""
                    for slot in side.slots {
                        guard let n = slot.sourcePageNumber else { continue }
                        let label = n<=106 ? String(format:"BODY%02d",n) : String(format:"COVER%02d",n-106)
                        XCTAssertTrue(text.contains(label),"Missing \(label) in form \(index+1)")
                    }
                    XCTAssertFalse(text.contains("Boş"),"Blank-position proof labels must not enter artwork")
                    XCTAssertEqual(page.bounds(for:.mediaBox).width,297*unit,accuracy:0.01)
                    XCTAssertEqual(page.bounds(for:.mediaBox).height,210*unit,accuracy:0.01)
                    XCTAssertEqual(Self.images(cg.page(at:index*2+face+1)?.dictionary),0)
                }
            }
        }
    }

}

extension BookExportTests {
    func testCoverPreparationExportsOnlySelectedArtworkAndMatchesVectorPreview() async throws {
        let folder = try folder()
        let url = folder.appendingPathComponent("panels.pdf")
        var box = CGRect(x:0,y:0,width:50*unit,height:70*unit)
        let writer = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&box,nil))
        for i in 1...3 {
            writer.beginPDFPage(nil)
            writer.setFillColor(PDFSpine.color(i == 1 ? .cmyk(1,0,0,0) : .cmyk(0,1,0,0)))
            writer.fill(box)
            writer.setFillColor(PDFSpine.color(i == 1 ? .cmyk(1,0.5,0,0) : .cmyk(0,0.5,0.7,0)))
            writer.fill(CGRect(x:0,y:box.midY,width:box.width,height:box.height/2))
            let font = CTFontCreateWithName("Helvetica" as CFString,10,nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:"PANEL\(i)",
                attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font]))
            writer.textMatrix = .identity
            writer.textPosition = CGPoint(x:15*unit,y:20*unit)
            CTLineDraw(line,writer)
            writer.endPDFPage()
        }
        writer.closePDF()
        let source = try await PDFSource.open(url)
        let before = try Data(contentsOf:url)
        let pages = source.pages.map(\.sourcePage)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        var project = Project(pages:pages,binding:.perfectBound,
            sheet:SheetSpec(size:Size(180,125),gripperWidth:7,orientation:.landscape))
        project.coverPreparation = CoverPreparationSettings()
        project.coverPreparation?.spineWidth = 10

        for (output,mode) in [(CoverPreparationPlanner.Output.spread,CoverPreparationSettings.SpineColorMode.automatic),
                              (.sheet,.automatic),(.spread,.manual)] {
            project.coverPreparation?.colorMode = mode
            let plan = CoverPreparationPlanner.plan(project,pages:pages,output:output)
            let sheet = try XCTUnwrap(plan.sheets.first)
            let marks: ExportMarks = output == .spread ? .none : ExportMarks()
            let out = folder.appendingPathComponent("\(output)-\(mode).pdf")
            let exported = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(out),marks:marks)
            XCTAssertEqual(exported.pageCount,1)
            let pdf = try XCTUnwrap(PDFDocument(url:out))
            XCTAssertTrue(pdf.string?.contains("PANEL1") == true)
            XCTAssertTrue(pdf.string?.contains("PANEL3") == true)
            XCTAssertFalse(pdf.string?.contains("PANEL2") == true)
            let page = try XCTUnwrap(CGPDFDocument(out as CFURL)?.page(at:1))
            XCTAssertEqual(Self.images(page.dictionary),0)
            XCTAssertEqual(page.getBoxRect(.mediaBox).width,sheet.size.width*unit,accuracy:0.01)
            XCTAssertEqual(page.getBoxRect(.mediaBox).height,sheet.size.height*unit,accuracy:0.01)
            func bitmap() throws -> CGContext {
                let width = Int(ceil(sheet.size.width*2))
                let height = Int(ceil(sheet.size.height*2))
                let context = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.scaleBy(x:2,y:2)
                return context
            }
            let preview = try bitmap()
            try PDFPlanRenderer.drawSide(sheet.front,sheet:sheet,document:document,in:preview,
                sheetIndex:0,kind:.front,repetition:0,options:.artworkOnly)
            PDFExportMarkRenderer.draw(side:sheet.front,sheet:sheet,in:preview,settings:marks,info:"")
            let printed = try bitmap()
            printed.scaleBy(x:1/unit,y:1/unit)
            printed.drawPDFPage(page)
            func sample(_ context: CGContext,_ point: CGPoint) -> [UInt8] {
                let index = (context.height-1-Int(point.y*2))*context.bytesPerRow+Int(point.x*2)*4
                return Array(UnsafeBufferPointer(start:context.data!.assumingMemoryBound(to:UInt8.self)+index,count:4))
            }
            let spine = try XCTUnwrap(sheet.front.slots.first { $0.spineArtwork != nil })
            let transform = PDFPreviewDrawing.slotTransform(spine)
            let samples = [CGPoint(x:2,y:10),CGPoint(x:8,y:10),CGPoint(x:2,y:60),CGPoint(x:8,y:60)]
                .map { $0.applying(transform) }
            XCTAssertEqual(Set(samples.map { sample(preview,$0) }).count,mode == .manual ? 1 : 4)
            for point in samples {
                XCTAssertEqual(sample(preview,point),sample(printed,point))
            }
            if output == .sheet {
                XCTAssertFalse(PDFExportMarkRenderer.geometry(side:sheet.front,sheet:sheet,settings:marks).segments.isEmpty)
            }
        }
        XCTAssertEqual(try Data(contentsOf:url),before)
    }
}

extension BookExportTests {
    func testCoverPreparationBlackSpineAndNativeColorExport() async throws {
        let folder = try folder()
        let url = folder.appendingPathComponent("black.pdf")
        var rect = CGRect(x:0,y:0,width:50*unit,height:70*unit)
        let writer = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&rect,nil))
        for black in [CGColor(gray:0,alpha:1),PDFSpine.color(.cmyk(0,0,0,1))] {
            writer.beginPDFPage(nil)
            writer.setFillColor(black)
            writer.fill(rect)
            writer.endPDFPage()
        }
        writer.closePDF()
        let source = try await PDFSource.open(url)
        let sourcePages = source.pages.map(\.sourcePage)
        var project = Project(pages:sourcePages,sheet:SheetSpec(size:Size(180,120)))
        project.coverPreparation = CoverPreparationSettings()
        project.coverPreparation?.spineWidth = 10.25
        project.coverPreparation?.pickedColor = .rgb(0.2,0.45,0.8)
        for mode in [CoverPreparationSettings.SpineColorMode.automatic,.picked,.manual] {
            project.coverPreparation?.colorMode = mode
            project.coverPreparation?.color = .cmyk(0,1,0,0)
            let plan = CoverPreparationPlanner.plan(project,pages:sourcePages,output:.spread)
            XCTAssertNil(PDFSpine.automaticEdgeWarning(in:plan,source:source))
            let out = folder.appendingPathComponent("\(mode).pdf")
            _ = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(out),marks:.none)
            let pdf = try XCTUnwrap(CGPDFDocument(out as CFURL))
            let page = try XCTUnwrap(pdf.page(at:1))
            XCTAssertEqual(Self.images(page.dictionary),0)
            let bitmap = try XCTUnwrap(CGContext(data:nil,width:442,height:280,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.scaleBy(x:4/unit,y:4/unit)
            bitmap.drawPDFPage(page)
            let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to:UInt8.self)
            func sample(_ column: Int) -> [UInt8] {
                Array(UnsafeBufferPointer(start:pixels+140*bitmap.bytesPerRow+4*column,count:4))
            }
            if mode == .automatic {
                for x in 195...246 {
                    let color = sample(x)
                    XCTAssertEqual(color[3],255,"x=\(x)")
                    XCTAssertLessThan(max(color[0],color[1],color[2]),45)
                }
            } else if mode == .picked {
                let color = sample(220)
                XCTAssertEqual(Double(color[0]),51,accuracy:2)
                XCTAssertEqual(Double(color[1]),115,accuracy:2)
                XCTAssertEqual(Double(color[2]),204,accuracy:2)
            } else {
                let color = sample(220)
                XCTAssertGreaterThan(color[0],color[1])
                XCTAssertGreaterThan(color[2],color[1])
            }
        }
    }

    func testCoverPreparationVectorLogoRotationAndTextPreflight() async throws {
        let folder = try folder()
        let url = folder.appendingPathComponent("cover.pdf")
        let logoFile = folder.appendingPathComponent("logo.pdf")
        try fixture(url,count:3,size:Size(50,70))
        try fixture(logoFile,count:1,size:Size(30,50),prefix:"LOGO")
        let source = try await PDFSource.open(url)
        let pages = source.pages.map(\.sourcePage)
        let trim = CGRect(x:0,y:0,width:16,height:70)
        var logo = try XCTUnwrap(PDFSpine.makeLogo(name:"logo.pdf",format:.pdf,data:Data(contentsOf:logoFile),in:trim))
        logo.width = 6; logo.rotation = 90; logo.x = 1; logo.y = 3
        let bounds = try XCTUnwrap(PDFSpine.logoBounds(logo,in:trim))
        XCTAssertEqual(bounds.width,10,accuracy:0.0001)
        XCTAssertEqual(bounds.height,6,accuracy:0.0001)
        XCTAssertEqual(bounds.midX,9,accuracy:0.0001)
        XCTAssertEqual(bounds.midY,38,accuracy:0.0001)
        var project = Project(pages:pages,sheet:SheetSpec(size:Size(180,125),orientation:.landscape))
        project.coverPreparation = CoverPreparationSettings()
        project.coverPreparation?.spineWidth = 16
        project.coverPreparation?.colorMode = .manual
        project.coverPreparation?.color = .cmyk(0,0,0,0)
        let vector = FreeSpineObject(content:.logo(logo))
        var block = SpineContent.TextBlock()
        block.text = "Çığ İŞ"
        block.size = 10
        block.y = 22
        var text = FreeSpineObject(content:.text(block))
        text.rotation = 12
        let textBounds = try XCTUnwrap(PDFSpine.objectBounds(text,in:trim))
        XCTAssertGreaterThan(textBounds.width,0)
        XCTAssertNil(PDFSpine.objectWarning(text,in:trim))
        for outlines in [true,false] {
            block.outlines = outlines
            text.content = .text(block)
            let otherTexts = [-24.0,-12,10].enumerated().map { index,y in
                var other = block
                other.text = "Ek\(index)"
                other.y = y
                return FreeSpineObject(content:.text(other))
            }
            project.coverPreparation?.spineObjects = [vector,text]+otherTexts
            let plan = CoverPreparationPlanner.plan(project,pages:pages,output:.sheet)
            XCTAssertTrue(PDFSpine.issues(in:plan).isEmpty)
            let out = folder.appendingPathComponent("logo-\(outlines).pdf")
            _ = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(out),marks:.none)
            let data = try XCTUnwrap(PDFDocument(url:out))
            XCTAssertTrue(data.string?.contains("LOGO01") == true)
            XCTAssertFalse(data.string?.contains("SRC02") == true)
            XCTAssertEqual(data.string?.contains("Çığ"),!outlines)
            let cg = try XCTUnwrap(CGPDFDocument(out as CFURL))
            XCTAssertEqual(Self.images(cg.page(at:1)?.dictionary),0)
        }
        logo.x = 20
        project.coverPreparation?.spineObjects = [FreeSpineObject(content:.logo(logo))]
        let overflow = CoverPreparationPlanner.plan(project,pages:pages,output:.spread)
        XCTAssertTrue(PDFSpine.issues(in:overflow).contains { $0.message.contains("Logo taşıyor") })
        XCTAssertThrowsError(try PDFExporter.export(plan:overflow,source:source,
            destination:.singlePDF(folder.appendingPathComponent("overflow.pdf"))))
    }

    @MainActor func testCoverPreparationSVGAndPNGLogoImport() async throws {
        let trim = CGRect(x:0,y:0,width:8,height:70)
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="30"><path d="M0 0H40V30Z" fill="#292929"/></svg>
        """.utf8)
        let imported = try XCTUnwrap(PDFSpine.importSVGLogo(name:"logo.svg",data:svg,in:trim))
        XCTAssertNil(PDFSpine.logoWarning(imported,in:trim))
        XCTAssertTrue([SpineLogo.Format.pdf,.convertedSVG].contains(imported.format))
        let png = try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aHAMAAAAASUVORK5CYII="))
        XCTAssertNotNil(PDFSpine.makeLogo(name:"logo.png",format:.png,data:png,in:trim))
        XCTAssertNil(PDFSpine.makeLogo(name:"broken.pdf",format:.pdf,data:Data(),in:trim))
    }
}
