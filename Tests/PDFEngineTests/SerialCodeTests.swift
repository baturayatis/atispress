import XCTest
import CoreImage
import PDFKit
import ImpositionCore
import PDFEngine

final class SerialCodeTests: XCTestCase {
    private func field(_ kind: SerialCodeSettings.Kind = .qr) -> SerialField {
        var field = SerialField(start: 1,digits: 4,prefix: "S-",position: Point(8,8))
        field.kind = kind
        return field
    }
    private func placement(_ field: SerialField,index: Int = 0) -> SerialPlacement {
        SerialPlacement(field: field,slotIndex: 0,index: index,text: field.text(at: index) ?? "")
    }
    func testKnownMatrixMatchesAppleGeneratorAndQRHasUprightFinderPatterns() throws {
        for kind in [SerialCodeSettings.Kind.qr,.code128] {
            let content = "HELLO-0001"
            let filter = try XCTUnwrap(CIFilter(name: kind == .qr ? "CIQRCodeGenerator" : "CICode128BarcodeGenerator"))
            filter.setDefaults(); filter.setValue(Data(content.utf8),forKey: "inputMessage")
            if kind == .qr { filter.setValue("M",forKey: "inputCorrectionLevel") }
            else { filter.setValue(0,forKey: "inputQuietSpace"); filter.setValue(1,forKey: "inputBarcodeHeight") }
            let output = try XCTUnwrap(filter.outputImage)
            let context = CIContext(options: [.useSoftwareRenderer:true,.workingColorSpace:NSNull(),.outputColorSpace:NSNull()])
            let native = try XCTUnwrap(output.cgImage ?? context.createCGImage(output,from: output.extent))
            // Independent gray reference avoids assuming a particular native
            // generator pixel format (RGBA/BGRA/gray differ between OS versions).
            var bytes = [UInt8](repeating: 255,count: native.width*native.height)
            try bytes.withUnsafeMutableBytes { pixels in
                let bitmap = try XCTUnwrap(CGContext(data: pixels.baseAddress,width: native.width,height: native.height,bitsPerComponent: 8,
                    bytesPerRow: native.width,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: CGImageAlphaInfo.none.rawValue))
                bitmap.interpolationQuality = .none
                bitmap.draw(native,in: CGRect(x: 0,y: 0,width: native.width,height: native.height))
            }
            var minX = native.width,minY = native.height,maxX = -1,maxY = -1
            for y in 0..<native.height { for x in 0..<native.width where bytes[y*native.width+x] < 128 {
                minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x); maxY = max(maxY,y)
            } }
            var expected: [UInt8] = []
            for y in (kind == .qr ? minY...maxY : ((minY+maxY)/2)...((minY+maxY)/2)) {
                for x in minX...maxX { expected.append(bytes[y*native.width+x] < 128 ? 1 : 0) }
            }
            let matrix = try SerialCodeGenerator.shared.matrix(content: content,kind: kind)
            XCTAssertEqual(matrix.width,maxX-minX+1)
            XCTAssertEqual(matrix.modules,expected)
            if kind == .qr {
                XCTAssertEqual(matrix.width,matrix.height)
                for (left,top) in [(0,0),(matrix.width-7,0),(0,matrix.height-7)] {
                    for y in 0..<7 { for x in 0..<7 {
                        let dark = x == 0 || x == 6 || y == 0 || y == 6 || ((2...4).contains(x) && (2...4).contains(y))
                        XCTAssertEqual(matrix.isDark(x: left+x,y: top+y),dark)
                    } }
                }
            } else { XCTAssertEqual(matrix.height,1) }
        }
    }
    func testGeometryQuietZonesCorrectionAndSizeLongContentAndTrimWarnings() throws {
        var qr = field(); qr.codeSettings.width = 5
        XCTAssertTrue(PDFSerialCodeDrawing.warnings(placement(qr)).contains { $0.contains("0.33") && $0.contains("uzun") })
        qr.codeSettings.width = 25; qr.codeSettings.template = String(repeating: "HELLO",count: 10)
        let m = try PDFSerialCodeDrawing.geometry(placement(qr))
        qr.codeSettings.correction = .h
        let h = try PDFSerialCodeDrawing.geometry(placement(qr))
        XCTAssertGreaterThan(h.matrix.width,m.matrix.width)
        XCTAssertEqual(h.codeBounds.size,CGSize(width: 25,height: 25))
        XCTAssertTrue(h.rectangles.allSatisfy { $0.minX >= Double(h.quietZone)*h.moduleWidth-0.000001 && $0.maxX <= 25-Double(h.quietZone)*h.moduleWidth+0.000001 })
        qr.codeSettings.humanReadable = true; qr.position = Point(0,0)
        XCTAssertTrue(PDFSerialCodeDrawing.warnings(placement(qr),trim: CGSize(width: 30,height: 30)).contains { $0.contains("kesim dışına") })
        qr.codeSettings.template = String(repeating: "A",count: 5000)
        XCTAssertTrue(PDFSerialCodeDrawing.warnings(placement(qr)).contains { $0.contains("uzun") })
        var barcode = field(.code128); barcode.codeSettings.width = 8
        XCTAssertTrue(PDFSerialCodeDrawing.warnings(placement(barcode)).contains { $0.contains("0.25") })
        barcode.codeSettings.template = "Şube-1"
        XCTAssertTrue(PDFSerialCodeDrawing.warnings(placement(barcode)).contains { $0.contains("ASCII") })
    }
    func testHundredThousandSequentialAndStackGenerateOnlySampledSheetsQuickly() throws {
        let start = Date()
        for mode in [SerialField.Mode.sequential,.stack] {
            var p = Project(pages: [SourcePage(number: 1,trimSize: Size(85,55))],sheet: SheetSpec(size: Size(220,160)),
                settings: ImpositionSettings(bleed: 0,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1),
                stepAndRepeat: StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: 100_000))
            var qr = field(); qr.mode = mode; p.serialFields = [qr]
            let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first),recipe = try XCTUnwrap(sheet.serialPlan)
            XCTAssertEqual(sheet.front.slots.count,4); XCTAssertEqual(recipe.sheetCount,25_000)
            for repetition in [0,24_999] {
                let codes = recipe.placements(side: sheet.front,kind: .front,repetition: repetition)
                XCTAssertEqual(codes.count,4)
                for code in codes { XCTAssertFalse(try PDFSerialCodeDrawing.geometry(code).rectangles.isEmpty) }
            }
            let last = recipe.placements(side: sheet.front,kind: .front,repetition: 24_999).last!
            XCTAssertEqual(last.content,"S-100000")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start),2)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func source(_ folder: URL) async throws -> PDFSource {
        let url = folder.appendingPathComponent("vector.pdf")
        var media = CGRect(x: 0,y: 0,width: 85*72/25.4,height: 55*72/25.4)
        let cg = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        cg.beginPDFPage(nil); cg.setFillColor(CGColor(gray: 0.85,alpha: 1)); cg.fill(media); cg.endPDFPage(); cg.closePDF()
        return try await PDFSource.open(url)
    }
    private func imageCount(_ dictionary: CGPDFDictionaryRef,depth: Int = 0) -> Int {
        guard depth < 16 else { return 0 }
        var resources: CGPDFDictionaryRef?,objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources),let resources,
              CGPDFDictionaryGetDictionary(resources,"XObject",&objects),let objects else { return 0 }
        final class State { var count = 0; var forms: [CGPDFDictionaryRef] = [] }
        let state = State()
        CGPDFDictionaryApplyFunction(objects,{ _,object,info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef?,name: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(object,.stream,&stream),let stream,let dict = CGPDFStreamGetDictionary(stream),CGPDFDictionaryGetName(dict,"Subtype",&name),let name {
                if String(cString: name) == "Image" { state.count += 1 }
                else if String(cString: name) == "Form" { state.forms.append(dict) }
            }
        },Unmanaged.passUnretained(state).toOpaque())
        return state.count+state.forms.reduce(0) { $0+imageCount($1,depth: depth+1) }
    }
    private func raster(_ page: CGPDFPage) throws -> CGImage {
        let box = page.getBoxRect(.mediaBox),scale = 3.0
        let cg = try XCTUnwrap(CGContext(data: nil,width: Int(box.width*scale),height: Int(box.height*scale),bitsPerComponent: 8,bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.setFillColor(CGColor(gray: 1,alpha: 1)); cg.fill(CGRect(x: 0,y: 0,width: cg.width,height: cg.height))
        cg.scaleBy(x: scale,y: scale); cg.drawPDFPage(page)
        return try XCTUnwrap(cg.makeImage())
    }
    func testQRAndBarcodeExportAreVectorAndReadableTextMatchesPayload() async throws {
        let folder = try folder(),source = try await source(folder)
        for kind in [SerialCodeSettings.Kind.qr,.code128] {
            var p = Project(pages: source.pages.map(\.sourcePage),sheet: SheetSpec(size: Size(100,80)),
                settings: ImpositionSettings(bleed: 0,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1),
                stepAndRepeat: StepAndRepeatSettings(columns: 1,rows: 1,allowRotation: false,quantity: 2))
            var code = field(kind); code.codeSettings.humanReadable = true
            code.codeSettings.template = kind == .qr ? "https://site.com/k/{no}" : "{no}"
            p.serialFields = [code]
            let plan = ImpositionPlanner.plan(p),target = folder.appendingPathComponent("\(kind).pdf")
            let result = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),marks: .none)
            XCTAssertEqual(result.pageCount,2)
            let pdf = try XCTUnwrap(CGPDFDocument(target as CFURL)),text = try XCTUnwrap(PDFDocument(url: target)?.string)
            XCTAssertTrue(text.contains(kind == .qr ? "https://site.com/k/S-0001" : "S-0001"))
            XCTAssertTrue(text.contains("S-0002"))
            for number in 1...pdf.numberOfPages { XCTAssertEqual(imageCount(try XCTUnwrap(pdf.page(at: number)?.dictionary)),0) }
            // Verify the actual PDF's dark/white module cells independently of
            // path generation. Rasterization is test inspection only, not export.
            let rendered = try raster(XCTUnwrap(pdf.page(at: 1)))
            let data = try XCTUnwrap(rendered.dataProvider?.data),bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            let sheet = try XCTUnwrap(plan.sheets.first),slot = try XCTUnwrap(sheet.front.slots.first)
            let serial = try XCTUnwrap(sheet.serialPlan?.placements(side: sheet.front,kind: .front,repetition: 0).first)
            let geometry = try PDFSerialCodeDrawing.geometry(serial)
            func dark(_ local: CGPoint) -> Bool {
                let point = local.applying(PDFSerialDrawing.transform(serial)).applying(PDFPreviewDrawing.slotTransform(slot))
                let x = Int(point.x*72/25.4*3),y = rendered.height-1-Int(point.y*72/25.4*3)
                return bytes[y*rendered.bytesPerRow+x*4] < 128
            }
            for y in 0..<geometry.matrix.height { for x in 0..<geometry.matrix.width {
                let point = CGPoint(x: (Double(x+geometry.quietZone)+0.5)*geometry.moduleWidth,
                    y: kind == .qr ? geometry.codeBounds.height-(Double(y+geometry.quietZone)+0.5)*geometry.moduleWidth : geometry.codeBounds.height/2)
                XCTAssertEqual(dark(point),geometry.matrix.isDark(x: x,y: y),"Wrong exported module \(x),\(y)")
            } }
            XCTAssertFalse(dark(CGPoint(x: geometry.moduleWidth/2,y: geometry.codeBounds.height/2)),"Quiet zone must knock out underlying artwork")

        }
    }
}
