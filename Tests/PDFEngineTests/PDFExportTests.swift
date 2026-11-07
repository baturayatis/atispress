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
        plan = ImpositionPlanner.plan(project(source)); plan.sheets[0].repeatCount = Int.max
        XCTAssertThrowsError(try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(output),options: .artworkOnly))
        plan.sheets[0].repeatCount = 1
        let before = try Data(contentsOf: input)
        XCTAssertThrowsError(try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(input),options: .artworkOnly))
        XCTAssertEqual(try Data(contentsOf: input),before)
    }
    func testLegacyExportOptionsUseProductionMarksWithoutPreviewGuides() async throws {
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
                if enabled && y < 7 { XCTAssertLessThan(output.rgb(2,Double(y)).min()!,0.8) }
                else { assertColor(output.rgb(2,Double(y)),[1,1,1]) }
                // Preview remains colored/dashed; production is solid CMYK.
            }
            assertColor(output.rgb(0.05,25),[1,1,1])
            XCTAssertFalse(PDFDocument(url: target)?.string?.contains("TEST-42") ?? false,"Preview label anchors are not exported")
            try saveQA(target,name: "marks-\(enabled)")
        }
        for kind in [.crop,.fold,.bleed,.safeArea,.pageLabel,.margin,.gripper] as [MarkKind] {
            XCTAssertFalse(PDFRenderOptions.artworkOnly.shows(kind))
        }
    }
    func testProductionCropStrokesAvoidEveryBleedBoxAndWarnWhenClipped() async throws {
        let folder = try directory(), input = try fixture(in: folder)
        let source = try await PDFSource.open(input)
        for gutter in [0.0,1,10] {
            var p = project(source,binding: .stepAndRepeat)
            p.sheet.size = Size(130,110); p.sheet.gutter = gutter
            p.settings.cropMarkLength = 5; p.settings.cropMarkOffset = 3
            p.stepAndRepeat = StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false)
            let plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport)
            for sheet in plan.sheets {
                for side in [sheet.front,sheet.back] {
                    let result = PDFExportMarkRenderer.geometry(side: side,sheet: sheet,settings: ExportMarks())
                    XCTAssertFalse(result.segments.isEmpty)
                    let radius = 0.25/unit/2
                    for mark in result.segments {
                        let stroke = CGRect(x: min(mark.start.x,mark.end.x)-radius,
                            y: min(mark.start.y,mark.end.y)-radius,
                            width: abs(mark.end.x-mark.start.x)+2*radius,
                            height: abs(mark.end.y-mark.start.y)+2*radius)
                        for slot in side.slots {
                            let r = try XCTUnwrap(slot.artworkClip)
                            let box = CGRect(x: r.origin.x+0.00001,y: r.origin.y+0.00001,
                                width: r.size.width-0.00002,height: r.size.height-0.00002)
                            XCTAssertFalse(stroke.intersects(box))
                        }
                    }
                }
            }
        }
        let marks = [Mark(kind: .crop,start: Point(-5,10),end: Point(30,10))]
        let side = Side(slots: [Slot(sourcePageNumber: nil,origin: Point(5,5),size: Size(10,10),
                                    artworkClip: Rect(x: 2,y: 2,width: 16,height: 16))],marks: marks)
        let result = PDFExportMarkRenderer.geometry(side: side,sheet: Sheet(size: Size(25,25),front: side,back: Side()),settings: ExportMarks())
        XCTAssertEqual(result.warnings.count,2)
    }

    private final class MarkOperators {
        var strokes = 0
        var rgb = 0
        var cmyk: [[Double]] = []
        var nonSolid = false
        func scan(_ page: CGPDFPage) {
            let table = CGPDFOperatorTableCreate()!
            CGPDFOperatorTableSetCallback(table,"S") { _,info in
                Unmanaged<MarkOperators>.fromOpaque(info!).takeUnretainedValue().strokes += 1
            }
            for op in ["RG","rg"] {
                CGPDFOperatorTableSetCallback(table,op) { _,info in
                    Unmanaged<MarkOperators>.fromOpaque(info!).takeUnretainedValue().rgb += 1
                }
            }
            CGPDFOperatorTableSetCallback(table,"K") { scanner,info in
                var components: [Double] = []
                for _ in 0..<4 {
                    var value: CGPDFReal = 0
                    if CGPDFScannerPopNumber(scanner,&value) { components.insert(value,at: 0) }
                }
                Unmanaged<MarkOperators>.fromOpaque(info!).takeUnretainedValue().cmyk.append(components)
            }
            CGPDFOperatorTableSetCallback(table,"d") { scanner,info in
                var phase: CGPDFReal = 0, array: CGPDFArrayRef?
                _ = CGPDFScannerPopNumber(scanner,&phase)
                if CGPDFScannerPopArray(scanner,&array),let array,CGPDFArrayGetCount(array) > 0 {
                    Unmanaged<MarkOperators>.fromOpaque(info!).takeUnretainedValue().nonSolid = true
                }
            }
            let content = CGPDFContentStreamCreateWithPage(page)
            let scanner = CGPDFScannerCreate(content,table,Unmanaged.passUnretained(self).toOpaque())
            XCTAssertTrue(CGPDFScannerScan(scanner))
        }
    }
    func testProductionPDFUsesSolidCMYKMarksForBothColors() async throws {
        let folder = try directory(), input = try fixture(in: folder)
        let source = try await PDFSource.open(input)
        let side = Side(marks: [Mark(kind: .crop,start: Point(2,5),end: Point(20,5)),
                               Mark(kind: .fold,start: Point(2,10),end: Point(20,10))])
        let plan = ImpositionPlan(sheets: [Sheet(size: Size(30,30),front: side,back: Side())])
        for color in [ExportMarks.Color.black,.registration] {
            var settings = ExportMarks(); settings.color = color; settings.fold = true
            let target = folder.appendingPathComponent("solid-\(color).pdf")
            _ = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),marks: settings)
            let ops = MarkOperators()
            ops.scan(try XCTUnwrap(CGPDFDocument(target as CFURL)?.page(at: 1)))
            XCTAssertEqual(ops.strokes,2)
            XCTAssertEqual(ops.rgb,0)
            XCTAssertFalse(ops.nonSolid)
            XCTAssertTrue(ops.cmyk.contains(color == .black ? [0,0,0,1] : [1,1,1,1]))
        }
    }

    func testAllProductionMarksOffExportsNoMarkContent() async throws {
        let folder = try directory(), input = try fixture(in: folder)
        let source = try await PDFSource.open(input)
        let marks: [MarkKind] = [.crop,.fold,.bleed,.safeArea,.pageLabel,.margin,.gripper,.sharedCut]
        let side = Side(marks: marks.map { Mark(kind: $0,start: Point(2,5),end: Point(20,5),label: "NO-MARK") })
        let sheet = Sheet(size: Size(30,30),front: side,back: side)
        let target = folder.appendingPathComponent("no-marks.pdf")
        _ = try PDFExporter.export(plan: ImpositionPlan(sheets: [sheet]),source: source,
            destination: .singlePDF(target),marks: .none)
        let doc = try XCTUnwrap(CGPDFDocument(target as CFURL))
        let page = try XCTUnwrap(doc.page(at: 1))
        let ops = MarkOperators(); ops.scan(page)
        XCTAssertEqual(ops.strokes,0)
        XCTAssertTrue(ops.cmyk.isEmpty)
        let output = try render(page)
        for y in stride(from: 0.5,to: 30.0,by: 0.5) {
            for x in stride(from: 0.5,to: 30.0,by: 0.5) { assertColor(output.rgb(x,y),[1,1,1]) }
        }
        XCTAssertFalse(PDFDocument(url: target)?.string?.contains("NO-MARK") ?? false)
        XCTAssertTrue(PDFExportMarkRenderer.geometry(side: side,sheet: sheet,settings: .none).segments.isEmpty)
    }

    func testSerialExportVectorTextAndPositionsMatchEveryPlannedPhysicalSheet() async throws {
        let folder = try directory(), input = try fixture(in: folder)
        let source = try await PDFSource.open(input)
        for mode in [SerialField.Mode.sequential,.stack] {
            var p = project(source,binding: .stepAndRepeat)
            p.sheet.size = Size(100,100); p.sheet.gutter = 3
            p.stepAndRepeat = StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: 10)
            p.serialFields = [SerialField(start: 101,digits: 4,prefix: "SER-",suffix: "-X",font: "Helvetica",size: 9,
                sides: .both,position: Point(3,15),mode: mode)]
            let plan = ImpositionPlanner.plan(p), sheet = try XCTUnwrap(plan.sheets.first)
            XCTAssertTrue(plan.canExport)
            let target = folder.appendingPathComponent("serial-\(mode).pdf")
            _ = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),marks: .none)
            let document = try XCTUnwrap(PDFDocument(url: target))
            XCTAssertEqual(document.pageCount,6)
            XCTAssertEqual(imageObjects(try XCTUnwrap(CGPDFDocument(target as CFURL))),0,"Numbers must remain vector text")
            for repetition in 0..<3 {
                for (face,side) in [(SideKind.front,sheet.front),(.back,sheet.back)] {
                    let page = try XCTUnwrap(document.page(at: repetition*2+(face == .front ? 0 : 1)))
                    let text = try XCTUnwrap(page.string)
                    let placements = try XCTUnwrap(sheet.serialPlan).placements(side: side,kind: face,repetition: repetition)
                    for serial in placements {
                        let range = (text as NSString).range(of: serial.text)
                        XCTAssertNotEqual(range.location,NSNotFound,"Missing \(serial.text) on sheet \(repetition+1)")
                        guard range.location != NSNotFound else { continue }
                        let selection = try XCTUnwrap(page.selection(for: range))
                        let rect = selection.bounds(for: page)
                        let slot = side.slots[serial.slotIndex]
                        // Unrotated fixture: local baseline anchor must be placed at trim origin + position.
                        XCTAssertEqual(rect.minX,(slot.x+serial.position.x)*unit,accuracy: 1.5)
                        XCTAssertLessThanOrEqual(rect.minY,(slot.y+serial.position.y)*unit+1)
                        XCTAssertGreaterThanOrEqual(rect.maxY,(slot.y+serial.position.y)*unit+2)
                        XCTAssertGreaterThan(rect.width,5)
                    }
                    XCTAssertFalse(text.contains("SER-0111-X"),"Overproduced copies must not receive serials")
                    let corePDF = try XCTUnwrap(CGPDFDocument(target as CFURL)?.page(at: repetition*2+(face == .front ? 1 : 2)))
                    let exported = try render(corePDF)
                    let preview = try Bitmap(width: sheet.size.width,height: sheet.size.height)
                    try PDFPlanRenderer.drawSide(side,sheet: sheet,document: XCTUnwrap(CGPDFDocument(input as CFURL)),
                        in: preview.context,sheetIndex: 0,kind: face,repetition: repetition,options: .artworkOnly)
                    // Compare pixels around the real serial baseline, using the shared live-preview renderer.
                    for serial in placements {
                        let slot = side.slots[serial.slotIndex]
                        for dx in stride(from: 0.0,to: 16.0,by: 0.5) {
                            assertColor(preview.rgb(slot.x+serial.position.x+dx,slot.y+serial.position.y+1),
                                        exported.rgb(slot.x+serial.position.x+dx,slot.y+serial.position.y+1))
                        }
                    }
                }
            }
        }
    }

    func testSerialRotationsMirrorsAndStyleKeepVectorTextAtPlanPositions() async throws {
        let folder = try directory(), input = try fixture(in: folder,count: 1)
        let source = try await PDFSource.open(input)
        let field = SerialField(digits: 0,prefix: "R",font: "Courier",size: 8,color: .rgb(0.8,0.1,0.2),
                                rotation: 30,sides: .both,position: Point(5,12))
        let slots = [Slot(sourcePageNumber: 1,origin: Point(10,10),size: Size(20,30),copyIndex: 0),
                     Slot(sourcePageNumber: 1,origin: Point(40,10),size: Size(30,20),rotation: 90,copyIndex: 1),
                     Slot(sourcePageNumber: 1,origin: Point(10,50),size: Size(20,30),rotation: 180,mirrored: true,copyIndex: 2)]
        var sheet = Sheet(size: Size(90,90),front: Side(slots: slots),back: Side())
        sheet.serialPlan = SerialNumberPlan(fields: [field],quantity: 3,capacity: 3,sheetCount: 1)
        let target = folder.appendingPathComponent("serial-rotated.pdf")
        _ = try PDFExporter.export(plan: ImpositionPlan(sheets: [sheet]),source: source,destination: .singlePDF(target),marks: .none)
        let page = try XCTUnwrap(PDFDocument(url: target)?.page(at: 0))
        let text = try XCTUnwrap(page.string)
        for serial in sheet.serialPlan!.placements(side: sheet.front,kind: .front,repetition: 0) {
            let range = (text as NSString).range(of: serial.text)
            XCTAssertNotEqual(range.location,NSNotFound)
            guard range.location != NSNotFound else { continue }
            let actual = try XCTUnwrap(page.selection(for: range)).bounds(for: page)
            let expected = PDFSerialDrawing.bounds(serial).applying(PDFSerialDrawing.transform(serial))
                .applying(PDFPreviewDrawing.slotTransform(slots[serial.slotIndex]))
            if !slots[serial.slotIndex].mirrored {
                XCTAssertEqual(actual.midX,expected.midX*unit,accuracy: 2)
                XCTAssertEqual(actual.midY,expected.midY*unit,accuracy: 2)
            }
            // PDFKit selections mismeasure reflected text. Check actual colored glyph
            // pixels against the planned glyph footprint for every transform as well.
            let bitmap = try render(XCTUnwrap(CGPDFDocument(target as CFURL)?.page(at: 1)))
            let slot = slots[serial.slotIndex]
            var ink = CGRect.null
            for y in stride(from: slot.y,to: slot.y+slot.size.height,by: 0.15) {
                for x in stride(from: slot.x,to: slot.x+slot.size.width,by: 0.15) {
                    let rgb = bitmap.rgb(x,y)
                    if rgb[0] > 0.6 && rgb[1] < 0.3 && rgb[2] < 0.4 { ink = ink.union(CGRect(x: x,y: y,width: 0.15,height: 0.15)) }
                }
            }
            XCTAssertFalse(ink.isNull)
            let glyph = PDFSerialDrawing.glyphBounds(serial).applying(PDFSerialDrawing.transform(serial))
                .applying(PDFPreviewDrawing.slotTransform(slot))
            XCTAssertEqual(ink.midX,glyph.midX,accuracy: 0.4)
            XCTAssertEqual(ink.midY,glyph.midY,accuracy: 0.4)
        }
        XCTAssertEqual(imageObjects(try XCTUnwrap(CGPDFDocument(target as CFURL))),0)
    }

    func testAutoFullSheetExportMediaBoxMatchesChosenPaper() async throws {
        let folder = try directory(), input = folder.appendingPathComponent("a4-source.pdf")
        var media = CGRect(x: 0,y: 0,width: 210*unit,height: 297*unit)
        let cg = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: input as CFURL)),mediaBox: &media,nil))
        cg.beginPDFPage(nil); cg.setFillColor(CGColor(gray: 0.6,alpha: 1)); cg.fill(media); cg.endPDFPage(); cg.closePDF()
        let source = try await PDFSource.open(input)
        let project = Project(pages: source.pages.map(\.sourcePage),sheet: SheetSpec(preset: .cm33x48))
        let auto = SmartAutoLayout.arrange(project)
        XCTAssertEqual(auto.project.sheet.size,SheetPreset.a4.size)
        let file = folder.appendingPathComponent("auto.pdf")
        _ = try PDFExporter.export(plan: auto.plan,source: source,destination: .singlePDF(file),marks: auto.project.exportMarks)
        let document = try XCTUnwrap(CGPDFDocument(file as CFURL))
        let bounds = try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(bounds.width,auto.plan.sheets[0].size.width*unit,accuracy: 0.001)
        XCTAssertEqual(bounds.height,auto.plan.sheets[0].size.height*unit,accuracy: 0.001)
        XCTAssertEqual(bounds.width,210*unit,accuracy: 0.001)
        XCTAssertEqual(bounds.height,297*unit,accuracy: 0.001)
    }
    func testAutomaticComfortMarksFitWithoutClippingAnyBleed() throws {
        var p = Project(pages: [SourcePage(number: 1,trimSize: Size(85,55),availableBleed: 0)],sheet: SheetSpec(preset: .cm33x48))
        p.autoLayout = AutoLayoutSettings(); p.autoLayout?.manualFields = [.sheetSize]
        p.stepAndRepeat.arrangement = .spaced
        let result = SmartAutoLayout.arrange(p)
        XCTAssertEqual(result.project.autoLayout?.level,.full)
        for sheet in result.plan.sheets {
            for side in [sheet.front,sheet.back] {
                let geometry = PDFExportMarkRenderer.geometry(side: side,sheet: sheet,settings: result.project.exportMarks)
                XCTAssertTrue(geometry.warnings.isEmpty)
                XCTAssertFalse(geometry.segments.isEmpty)
            }
        }
    }

    func testHugeExportHasNoPageCapAndDoesNotExpandRepetitionArrays() async throws {
        let folder = try directory(), input = try fixture(in: folder)
        let source = try await PDFSource.open(input)
        var plan = ImpositionPlanner.plan(project(source))
        plan.sheets[0].repeatCount = Int.max/4
        let target = folder.appendingPathComponent("huge.pdf")
        // Reach the very first slot immediately, then intentionally stop. A quantity-sized
        // repetitions array or the old 20,000-page cap would fail before this hook.
        XCTAssertThrowsError(try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(target),marks: .none,overlays: [FailingOverlay()])) { error in
            guard case FailingOverlay.Failure.intentional = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".atispress-") })
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
        XCTAssertEqual(result.pageCount,3)
        let document = try XCTUnwrap(CGPDFDocument(target as CFURL))
        let first = try render(XCTUnwrap(document.page(at: 1)))
        assertColor(first.rgb(8,25),[0,1,1])
        let text = try XCTUnwrap(PDFDocument(url: target)?.string)
        for i in 1...3 { XCTAssertTrue(text.contains("S\(i)")) }
        XCTAssertEqual(imageObjects(document),0)
        try saveQA(target,name: "extensions")
    }
    func testSinglePageSerialJobExportsOnlyFrontsInBothDestinations() async throws {
        let folder = try directory(), input = try fixture(in: folder,count: 1)
        let source = try await PDFSource.open(input)
        var p = project(source,binding: .stepAndRepeat)
        p.sheet.size = Size(100,100)
        p.stepAndRepeat = StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: 10)
        p.serialFields = [SerialField(prefix: "FORM-",size: 9,position: Point(3,15))]
        let plan = ImpositionPlanner.plan(p), sheet = try XCTUnwrap(plan.sheets.first)
        XCTAssertTrue(plan.canExport); XCTAssertFalse(plan.hasBackContent)
        for perSheet in [false,true] {
            let output = folder.appendingPathComponent("fronts.pdf")
            let destination: PDFExportDestination = perSheet ? .perSheet(directory: folder,baseName: "fronts") : .singlePDF(output)
            // Even explicitly requesting blank backs cannot add them to a wholly simplex job.
            let result = try PDFExporter.export(plan: plan,source: source,destination: destination,marks: .none,includeBlankBacks: true)
            XCTAssertEqual(result.pageCount,3); XCTAssertEqual(result.sheetCount,3)
            XCTAssertEqual(result.notes,["Arka yüz boş: çıktıya eklenmedi."])
            XCTAssertEqual(result.files.count,perSheet ? 3 : 1)
            for repetition in 0..<3 {
                let document = try XCTUnwrap(PDFDocument(url: perSheet ? result.files[repetition] : output))
                XCTAssertEqual(document.pageCount,perSheet ? 1 : 3)
                let page = try XCTUnwrap(document.page(at: perSheet ? 0 : repetition))
                let text = page.string ?? ""
                for serial in sheet.serialPlan!.placements(side: sheet.front,kind: .front,repetition: repetition) {
                    XCTAssertTrue(text.contains(serial.text),"Missing \(serial.text)")
                    let bounds = try XCTUnwrap(page.selection(for: (text as NSString).range(of: serial.text))).bounds(for: page)
                    let slot = sheet.front.slots[serial.slotIndex]
                    XCTAssertEqual(bounds.minX,(slot.x+serial.position.x)*unit,accuracy: 1.5)
                }
                XCTAssertFalse(text.contains("FORM-0011"))
            }
        }
    }
    func testMixedJobsRetainBlankBacksByDefaultAndCanOmitThemInBothDestinations() async throws {
        let folder = try directory(), input = try fixture(in: folder,count: 3)
        let source = try await PDFSource.open(input)
        var p = project(source,binding: .stepAndRepeat)
        p.sheet.size = Size(100,100)
        p.stepAndRepeat = StepAndRepeatSettings(columns: 1,rows: 1,allowRotation: false,quantity: 2)
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.hasBackContent); XCTAssertTrue(plan.hasBlankBacks)
        for include in [true,false] {
            for perSheet in [false,true] {
                let base = "mixed-\(include)-\(perSheet)"
                let destination: PDFExportDestination = perSheet ? .perSheet(directory: folder,baseName: base) : .singlePDF(folder.appendingPathComponent(base+".pdf"))
                let result: PDFExportResult
                if include {
                    result = try PDFExporter.export(plan: plan,source: source,destination: destination,marks: .none)
                } else {
                    result = try PDFExporter.export(plan: plan,source: source,destination: destination,marks: .none,includeBlankBacks: false)
                }
                XCTAssertEqual(result.pageCount,include ? 8 : 6)
                XCTAssertEqual(result.sheetCount,4)
                if perSheet {
                    for (index,file) in result.files.enumerated() {
                        let pdf = try XCTUnwrap(CGPDFDocument(file as CFURL))
                        XCTAssertEqual(pdf.numberOfPages,index < 2 || include ? 2 : 1)
                        try checkSlots(plan.sheets[index/2].front.slots,on: XCTUnwrap(pdf.page(at: 1)))
                        if index >= 2 && include {
                            assertColor(try render(XCTUnwrap(pdf.page(at: 2))).rgb(50,50),[1,1,1])
                        }
                    }
                } else {
                    let pdf = try XCTUnwrap(CGPDFDocument(result.files[0] as CFURL))
                    XCTAssertEqual(pdf.numberOfPages,result.pageCount)
                    try checkSlots(plan.sheets[0].back.slots,on: XCTUnwrap(pdf.page(at: 2)))
                    try checkSlots(plan.sheets[1].front.slots,on: XCTUnwrap(pdf.page(at: 5)))
                    if include { assertColor(try render(XCTUnwrap(pdf.page(at: 6))).rgb(50,50),[1,1,1]) }
                }
            }
        }
    }
    func testSerialOnlyBacksAndSamePlateContentAreNotDropped() async throws {
        let folder = try directory(), input = try fixture(in: folder,count: 1)
        let source = try await PDFSource.open(input)
        for method in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
            var p = project(source,binding: .stepAndRepeat)
            p.sheet.size = Size(100,100); p.settings.turnMethod = method
            p.stepAndRepeat = StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: 10)
            if method == .sheetwise { p.serialFields = [SerialField(prefix: "BACK-",sides: .back,position: Point(3,15))] }
            let plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.hasBackContent)
            let result = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(folder.appendingPathComponent("backs-\(method).pdf")),marks: .none,includeBlankBacks: false)
            XCTAssertEqual(result.pageCount,6); XCTAssertTrue(result.notes.isEmpty)
            let pdf = try XCTUnwrap(PDFDocument(url: result.files[0]))
            if method == .sheetwise { XCTAssertTrue(pdf.page(at: 1)?.string?.contains("BACK-0001") == true) }
        }
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
