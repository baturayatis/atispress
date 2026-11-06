import XCTest
import PDFKit
import PDFEngine
import ImpositionCore

final class PDFExportTests: XCTestCase {
    private let unit = PDFPreviewDrawing.pointsPerMM
    private let colors: [(Double,Double,Double)] = [(0.1,0.25,0.9),(0.1,0.75,0.2),(0.95,0.4,0.05),(0.6,0.1,0.8),
                                                   (0,0.65,0.7),(0.85,0.1,0.1),(0.8,0.7,0.1),(0.35,0.35,0.35)]
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(in directory: URL,count: Int = 2,bleedBox: Bool = true,rotation: Int = 0) throws -> URL {
        let url = directory.appendingPathComponent("source.pdf")
        var media = CGRect(x: 5,y: 7,width: 20*unit+40,height: 30*unit+50)
        var trim = CGRect(x: 15,y: 27,width: 20*unit,height: 30*unit)
        var bleed = trim.insetBy(dx: -8,dy: -8)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        for number in 1...count {
            var boxes: [CFString:Any] = [kCGPDFContextTrimBox:NSData(bytes: &trim,length: MemoryLayout<CGRect>.size)]
            if bleedBox { boxes[kCGPDFContextBleedBox] = NSData(bytes: &bleed,length: MemoryLayout<CGRect>.size) }
            context.beginPDFPage(boxes as CFDictionary)
            context.setFillColor(CGColor(gray: 0.7,alpha: 1)); context.fill(media)
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,components: [1,0,1,1])!); context.fill(bleed)
            let color = colors[(number-1)%colors.count]
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,components: [color.0,color.1,color.2,1])!); context.fill(trim)
            context.setFillColor(CGColor(gray: 0,alpha: 1))
            context.fill(CGRect(x: trim.minX+unit,y: trim.maxY-3*unit,width: 2*unit,height: 2*unit))
            context.endPDFPage()
        }
        context.closePDF()
        if rotation != 0 {
            let document = try XCTUnwrap(PDFDocument(url: url))
            for index in 0..<count { document.page(at: index)?.rotation = rotation }
            XCTAssertTrue(document.write(to: url))
        }
        return url
    }
    private func project(_ source: PDFSource, binding: BindingMethod = .saddleStitch) -> Project {
        Project(pages: source.pages.map(\.sourcePage),binding: binding,
            sheet: SheetSpec(size: Size(47,37),orientation: .landscape),
            settings: ImpositionSettings(bleed: 3,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1))
    }
    private final class Bitmap {
        let context: CGContext
        let scale: Double
        init(width: Double,height: Double,scale: Double = 6) throws {
            self.scale = scale
            context = try XCTUnwrap(CGContext(data: nil,width: Int(ceil(width*scale)),height: Int(ceil(height*scale)),
                bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(CGColor(gray: 1,alpha: 1))
            context.fill(CGRect(x: 0,y: 0,width: context.width,height: context.height))
            context.scaleBy(x: scale,y: scale)
        }
        func rgb(_ x: Double,_ y: Double) -> [Double] {
            let data = context.data!.assumingMemoryBound(to: UInt8.self)
            let ix = max(0,min(context.width-1,Int(x*scale))), iy = max(0,min(context.height-1,Int(y*scale)))
            let offset = (context.height-1-iy)*context.bytesPerRow+ix*4
            return (0..<3).map { Double(data[offset+$0])/255 }
        }
    }
    private func render(_ page: CGPDFPage) throws -> Bitmap {
        let media = page.getBoxRect(.mediaBox)
        let result = try Bitmap(width: media.width/unit,height: media.height/unit)
        result.context.scaleBy(x: 1/unit,y: 1/unit); result.context.drawPDFPage(page)
        return result
    }
    private func assertColor(_ actual: [Double],_ expected: [Double],file: StaticString = #filePath,line: UInt = #line) {
        for i in 0..<3 { XCTAssertEqual(actual[i],expected[i],accuracy: 0.09,file: file,line: line) }
    }
    private func checkSlots(_ slots: [Slot],on page: CGPDFPage) throws {
        let bitmap = try render(page)
        for slot in slots {
            guard let number = slot.sourcePageNumber else {
                assertColor(bitmap.rgb(slot.x+slot.size.width/2,slot.y+slot.size.height/2),[1,1,1]); continue
            }
            let color = colors[(number-1)%colors.count]
            assertColor(bitmap.rgb(slot.x+slot.size.width/2,slot.y+slot.size.height/2),[color.0,color.1,color.2])
            // Independent corner mapping checks source placement, clockwise rotations and local reflection.
            let w = slot.rotation%180 == 0 ? slot.size.width : slot.size.height
            let h = slot.rotation%180 == 0 ? slot.size.height : slot.size.width
            let x = slot.mirrored ? w-2 : 2.0, y = h-2
            let point: (Double,Double)
            switch slot.rotation {
            case 90: point = (y,w-x)
            case 180: point = (w-x,h-y)
            case 270: point = (h-y,x)
            default: point = (x,y)
            }
            assertColor(bitmap.rgb(slot.x+point.0,slot.y+point.1),[0,0,0])
        }
    }
    private final class ImageResources {
        var count = 0
        private var seen = Set<CGPDFDictionaryRef>()
        func scan(_ owner: CGPDFDictionaryRef) {
            guard seen.insert(owner).inserted else { return }
            var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(owner,"Resources",&resources),let resources,
                  CGPDFDictionaryGetDictionary(resources,"XObject",&objects),let objects else { return }
            CGPDFDictionaryApplyFunction(objects,{ _,object,info in
                guard let info else { return }
                let collector = Unmanaged<ImageResources>.fromOpaque(info).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object,.stream,&stream),let stream else { return }
                guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var name: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(dictionary,"Subtype",&name),let name,String(cString: name) == "Image" {
                    collector.count += 1
                }
                collector.scan(dictionary)
            },Unmanaged.passUnretained(self).toOpaque())
        }
    }
    private func imageObjects(_ document: CGPDFDocument) -> Int {
        let resources = ImageResources()
        for index in 1...document.numberOfPages {
            if let dictionary = document.page(at: index)?.dictionary { resources.scan(dictionary) }
        }
        return resources.count
    }
    private func saveQA(_ file: URL,name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["ATISPRESS_EXPORT_QA"] else { return }
        let directory = URL(fileURLWithPath: path,isDirectory: true)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name+".pdf")
        try Data(contentsOf: file).write(to: target)
        let doc = try XCTUnwrap(CGPDFDocument(target as CFURL))
        for index in 1...min(2,doc.numberOfPages) {
            let bitmap = try render(XCTUnwrap(doc.page(at: index)))
            let png = NSBitmapImageRep(cgImage: try XCTUnwrap(bitmap.context.makeImage())).representation(using: .png,properties: [:])!
            try png.write(to: directory.appendingPathComponent("\(name)-\(index).png"))
        }
    }
    func testBookletExportPageOrderSizeSlotPositionsAndVectorContent() async throws {
        let folder = try directory(), input = try fixture(in: folder,count: 8)
        let source = try await PDFSource.open(input)
        let plan = ImpositionPlanner.plan(project(source))
        XCTAssertTrue(plan.canExport); XCTAssertEqual(plan.sheets.count,2)
        let target = folder.appendingPathComponent("booklet.pdf")
        let result = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),options: .artworkOnly)
        let document = try XCTUnwrap(CGPDFDocument(target as CFURL))
        XCTAssertEqual(document.numberOfPages,plan.sheets.count*2)
        XCTAssertEqual(result.pageCount,4)
        for (index,sheet) in plan.sheets.enumerated() {
            for (offset,side) in [sheet.front,sheet.back].enumerated() {
                let page = try XCTUnwrap(document.page(at: index*2+offset+1))
                XCTAssertEqual(page.getBoxRect(.mediaBox).width,sheet.size.width*unit,accuracy: 0.001)
                XCTAssertEqual(page.getBoxRect(.mediaBox).height,sheet.size.height*unit,accuracy: 0.001)
                try checkSlots(side.slots,on: page)
            }
        }
        XCTAssertEqual(imageObjects(document),0,"Vector fixture must not become a bitmap")
        try saveQA(target,name: "booklet")
    }
    func testFlatWorkStylesAndSeparatePhysicalSheetPDFs() async throws {
        let folder = try directory(), input = try fixture(in: folder)
        let source = try await PDFSource.open(input)
        for method in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
            var p = project(source,binding: .stepAndRepeat)
            p.sheet.size = Size(110,90); p.sheet.gutter = 2
            p.settings.turnMethod = method
            p.stepAndRepeat = StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: 9)
            let plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport); XCTAssertEqual(plan.totalPressSheets,3)
            let directory = folder.appendingPathComponent("\(method)",isDirectory: true)
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false)
            let result = try PDFExporter.export(plan: plan,source: source,destination: .perSheet(directory: directory,baseName: "cards"),options: .artworkOnly)
            XCTAssertEqual(result.files.count,3); XCTAssertEqual(result.pageCount,6)
            for file in result.files {
                let doc = try XCTUnwrap(CGPDFDocument(file as CFURL))
                XCTAssertEqual(doc.numberOfPages,2)
                try checkSlots(plan.sheets[0].front.slots,on: XCTUnwrap(doc.page(at: 1)))
                try checkSlots(plan.sheets[0].back.slots,on: XCTUnwrap(doc.page(at: 2)))
            }
            let combined = folder.appendingPathComponent("combined-\(method).pdf")
            _ = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(combined),options: .artworkOnly)
            let whole = try XCTUnwrap(CGPDFDocument(combined as CFURL))
            XCTAssertEqual(whole.numberOfPages,6)
            try checkSlots(plan.sheets[0].front.slots,on: XCTUnwrap(whole.page(at: 5)))
            try checkSlots(plan.sheets[0].back.slots,on: XCTUnwrap(whole.page(at: 6)))
            try saveQA(result.files[0],name: "cards-\(method)")
        }
    }
    func testBleedIsPreservedWithTrimAnchorAndMediaFallback() async throws {
        for explicit in [true,false] {
            let folder = try directory(), input = try fixture(in: folder,count: 1,bleedBox: explicit)
            let source = try await PDFSource.open(input)
            let slot = Slot(sourcePageNumber: 1,origin: Point(10,10),size: source.pages[0].trimSize,
                            artworkClip: Rect(x: 6,y: 6,width: 28,height: 38))
            let plan = ImpositionPlan(sheets: [Sheet(size: Size(45,55),front: Side(slots: [slot]),back: Side())])
            let file = folder.appendingPathComponent("bleed.pdf")
            _ = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(file),options: .artworkOnly)
            let bitmap = try render(XCTUnwrap(CGPDFDocument(file as CFURL)?.page(at: 1)))
            assertColor(bitmap.rgb(9,25),[1,0,1]) // Outside trim, inside bleed.
            assertColor(bitmap.rgb(12,38),[0,0,0]) // Trim corner remains anchored at (10,10).
            assertColor(bitmap.rgb(6.6,25),explicit ? [1,1,1] : [0.7,0.7,0.7])
            let image = await source.image(page: 1,pixels: 512)
            XCTAssertNotNil(image)
            let raster = try XCTUnwrap(source.cachedRaster(page: 1,pixels: 512))
            let preview = try Bitmap(width: 45,height: 55)
            try PDFPlanRenderer.drawSlot(slot,page: nil,in: preview.context,reference: SlotReference(sheet: 0,side: .front,slot: 0),raster: raster)
            assertColor(preview.rgb(9,25),bitmap.rgb(9,25))
            assertColor(preview.rgb(12,38),bitmap.rgb(12,38))
            try saveQA(file,name: explicit ? "bleed" : "media-fallback")
        }
    }
    func testRotatedSourceAndMirroredSlotsRetainBleed() async throws {
        let folder = try directory(), input = try fixture(in: folder,count: 1,rotation: 90)
        let source = try await PDFSource.open(input)
        XCTAssertEqual(source.pages[0].trimSize.width,30,accuracy: 0.001)
        let slot = Slot(sourcePageNumber: 1,origin: Point(10,10),size: Size(30,20),mirrored: true,
                        artworkClip: Rect(x: 7,y: 7,width: 36,height: 26))
        let file = folder.appendingPathComponent("rotation.pdf")
        let plan = ImpositionPlan(sheets: [Sheet(size: Size(50,40),front: Side(slots: [slot]),back: Side())])
        _ = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(file),options: .artworkOnly)
        let bitmap = try render(XCTUnwrap(CGPDFDocument(file as CFURL)?.page(at: 1)))
        assertColor(bitmap.rgb(12,28),[0,0,0]) // Source /Rotate, then slot-local horizontal reflection.
        assertColor(bitmap.rgb(9,20),[1,0,1])
    }
    func testInvalidPlanMissingPageLimitsAndSourceOverwriteAreRejected() async throws {
        let folder = try directory(), input = try fixture(in: folder)
        let source = try await PDFSource.open(input), output = folder.appendingPathComponent("out.pdf")
        var plan = ImpositionPlanner.plan(project(source))
        plan.issues.append(ValidationIssue(.error,.invalidInput,"Hata"))
        XCTAssertThrowsError(try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(output),options: .artworkOnly))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        plan.issues = []; plan.sheets[0].front.slots[0].sourcePageNumber = 999
        XCTAssertThrowsError(try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(output),options: .artworkOnly))
        plan = ImpositionPlanner.plan(project(source)); plan.sheets[0].repeatCount = 10_001
        XCTAssertThrowsError(try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(output),options: .artworkOnly))
        plan.sheets[0].repeatCount = 1
        let before = try Data(contentsOf: input)
        XCTAssertThrowsError(try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(input),options: .artworkOnly))
        XCTAssertEqual(try Data(contentsOf: input),before)
    }
    func testAllOverlaySwitchesUseSharedRenderer() async throws {
        let folder = try directory(), input = try fixture(in: folder,count: 1)
        let source = try await PDFSource.open(input)
        let kinds: [MarkKind] = [.crop,.fold,.bleed,.safeArea,.margin]
        let marks = kinds.enumerated().map { index,kind in
            Mark(kind: kind,start: Point(1,Double(index+3)),end: Point(4,Double(index+3)))
        } + [Mark(kind: .pageLabel,start: Point(22,48),end: Point(22,48),label: "TEST-42")]
        let sheet = Sheet(size: Size(45,55),front: Side(marks: marks),back: Side())
        let plan = ImpositionPlan(sheets: [sheet])
        for enabled in [false,true] {
            let options = enabled ? PDFRenderOptions(crop: true,fold: true,bleed: true,safeArea: true,
                pageNumbers: true,sheetBoundary: true,pressGuides: true) : .artworkOnly
            let target = folder.appendingPathComponent("marks-\(enabled).pdf")
            _ = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),options: options)
            let page = try XCTUnwrap(CGPDFDocument(target as CFURL)?.page(at: 1))
            let output = try render(page)
            let preview = try Bitmap(width: 45,height: 55)
            PDFPlanRenderer.drawMarks(marks,sheetSize: sheet.size,in: preview.context,options: options)
            for y in 3...7 {
                if enabled { XCTAssertLessThan(output.rgb(2,Double(y)).min()!,0.8) }
                else { assertColor(output.rgb(2,Double(y)),[1,1,1]) }
                assertColor(output.rgb(2,Double(y)),preview.rgb(2,Double(y)))
            }
            if enabled { XCTAssertLessThan(output.rgb(0.05,25).min()!,0.8) }
            else { assertColor(output.rgb(0.05,25),[1,1,1]) }
            XCTAssertEqual(PDFDocument(url: target)?.string?.contains("TEST-42") ?? false,enabled)
            try saveQA(target,name: "marks-\(enabled)")
        }
        for kind in [.crop,.fold,.bleed,.safeArea,.pageLabel,.margin,.gripper] as [MarkKind] {
            XCTAssertFalse(PDFRenderOptions.artworkOnly.shows(kind))
        }
    }
    private struct GeneratedBleed: PDFSlotOverlay {
        var phase: PDFOverlayPhase { .underArtwork }
        func draw(in context: CGContext,placement: PDFSlotContext) {
            guard placement.slot.sourcePageNumber != nil else { return }
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,components: [0,1,1,1])!)
            context.fill(placement.artworkRect)
        }
    }
    private struct SerialOverlay: PDFSlotOverlay {
        func draw(in context: CGContext,placement: PDFSlotContext) {
            guard placement.slot.sourcePageNumber != nil else { return }
            PDFPlanRenderer.drawLabel("S\(placement.repetition+1)",at: CGPoint(x: 10,y: 15),size: 2,
                                      color: CGColor(gray: 0,alpha: 1),in: context)
        }
    }
    func testVectorExtensionsCanAddGeneratedBleedAndSerialsWithoutPlanChanges() async throws {
        let folder = try directory(), input = try fixture(in: folder,count: 1)
        let pdf = try XCTUnwrap(PDFDocument(url: input)), page = try XCTUnwrap(pdf.page(at: 0))
        page.setBounds(page.bounds(for: .trimBox),for: .bleedBox)
        XCTAssertTrue(pdf.write(to: input))
        let source = try await PDFSource.open(input)
        let slot = Slot(sourcePageNumber: 1,origin: Point(10,10),size: source.pages[0].trimSize,
                        artworkClip: Rect(x: 7,y: 7,width: 26,height: 36))
        let plan = ImpositionPlan(sheets: [Sheet(size: Size(45,55),front: Side(slots: [slot]),back: Side(),repeatCount: 3)])
        let target = folder.appendingPathComponent("extensions.pdf")
        let result = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),options: .artworkOnly,
                                           overlays: [GeneratedBleed(),SerialOverlay()])
        XCTAssertEqual(result.pageCount,6)
        let document = try XCTUnwrap(CGPDFDocument(target as CFURL))
        let first = try render(XCTUnwrap(document.page(at: 1)))
        assertColor(first.rgb(8,25),[0,1,1])
        let text = try XCTUnwrap(PDFDocument(url: target)?.string)
        for i in 1...3 { XCTAssertTrue(text.contains("S\(i)")) }
        XCTAssertEqual(imageObjects(document),0)
        try saveQA(target,name: "extensions")
    }
    private struct FailingOverlay: PDFSlotOverlay {
        enum Failure: Error { case intentional }
        func draw(in context: CGContext,placement: PDFSlotContext) throws { throw Failure.intentional }
    }
    func testAtomicReplacementAndFailedExportLeavesExistingOutputUntouched() async throws {
        let folder = try directory(), input = try fixture(in: folder)
        let source = try await PDFSource.open(input)
        let plan = ImpositionPlanner.plan(project(source))
        let target = folder.appendingPathComponent("existing.pdf"), sentinel = Data("existing contents".utf8)
        try sentinel.write(to: target)
        XCTAssertThrowsError(try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),options: .artworkOnly,
                                                  overlays: [FailingOverlay()]))
        XCTAssertEqual(try Data(contentsOf: target),sentinel)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".atispress-") })
        _ = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),options: .artworkOnly)
        XCTAssertNotNil(CGPDFDocument(target as CFURL))
        let separate = folder.appendingPathComponent("separate",isDirectory: true)
        try FileManager.default.createDirectory(at: separate,withIntermediateDirectories: false)
        let collision = separate.appendingPathComponent("cards-tabaka-0001.pdf")
        try sentinel.write(to: collision)
        XCTAssertThrowsError(try PDFExporter.export(plan: plan,source: source,
            destination: .perSheet(directory: separate,baseName: "cards"),options: .artworkOnly))
        XCTAssertEqual(try Data(contentsOf: collision),sentinel)
    }

    func testPerfectBoundSignaturesAndBookletWorkStylesMatchEverySlot() async throws {
        let folder = try directory(), input = try fixture(in: folder,count: 32)
        let source = try await PDFSource.open(input)
        for signature in [SignatureSize.sixteen,.thirtyTwo] {
            for method in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
                var p = project(source,binding: .perfectBound)
                p.sheet.size = Size(350,300)
                p.settings.signatureSize = signature; p.settings.turnMethod = method
                let plan = ImpositionPlanner.plan(p)
                XCTAssertTrue(plan.canExport)
                let target = folder.appendingPathComponent("perfect-\(signature)-\(method).pdf")
                _ = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),options: .artworkOnly)
                let document = try XCTUnwrap(CGPDFDocument(target as CFURL))
                XCTAssertEqual(document.numberOfPages,plan.totalPressSheets*2)
                for (index,sheet) in plan.sheets.enumerated() {
                    try checkSlots(sheet.front.slots,on: XCTUnwrap(document.page(at: index*2+1)))
                    try checkSlots(sheet.back.slots,on: XCTUnwrap(document.page(at: index*2+2)))
                }
                if method == .sheetwise { try saveQA(target,name: "perfect-\(signature)") }
            }
        }
    }

    func testEmbeddedImagesAreRetainedWithoutConvertingVectorPagesToBitmaps() async throws {
        let folder = try directory(), input = folder.appendingPathComponent("image.pdf")
        let bitmap = try Bitmap(width: 2,height: 2)
        bitmap.context.setFillColor(CGColor(gray: 0,alpha: 1)); bitmap.context.fill(CGRect(x: 0,y: 0,width: 1,height: 1))
        var media = CGRect(x: 0,y: 0,width: 20*unit,height: 30*unit)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: input as CFURL)),mediaBox: &media,nil))
        context.beginPDFPage(nil); context.draw(try XCTUnwrap(bitmap.context.makeImage()),in: media)
        context.endPDFPage(); context.closePDF()
        XCTAssertGreaterThan(imageObjects(try XCTUnwrap(CGPDFDocument(input as CFURL))),0)
        let source = try await PDFSource.open(input)
        let plan = ImpositionPlanner.plan(project(source))
        let target = folder.appendingPathComponent("retained.pdf")
        _ = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),options: .artworkOnly)
        XCTAssertGreaterThan(imageObjects(try XCTUnwrap(CGPDFDocument(target as CFURL))),0)
    }

}
