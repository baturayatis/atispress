import XCTest
import PDFKit
import ImpositionCore
@testable import PDFEngine

final class GeneratedBleedTests: XCTestCase {
    private enum Pattern { case solid, split, depth, cmyk }
    private let ppmm = PDFPreviewDrawing.pointsPerMM
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(_ patterns: [Pattern],in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("edges.pdf")
        var media = CGRect(x: 0,y: 0,width: 40*ppmm,height: 30*ppmm)
        var trim = CGRect(x: 5*ppmm,y: 5*ppmm,width: 30*ppmm,height: 20*ppmm)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        for pattern in patterns {
            let box = NSData(bytes: &trim,length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextTrimBox:box,kCGPDFContextBleedBox:box] as CFDictionary)
            context.saveGState()
            context.translateBy(x: trim.minX,y: trim.minY); context.scaleBy(x: ppmm,y: ppmm)
            let base: BleedColor = pattern == .cmyk ? .cmyk(0.2,0.4,0,0.1) : .rgb(0.85,0.1,0.05)
            context.setFillColor(GeneratedBleedOverlay.cgColor(base)); context.fill(CGRect(x: 0,y: 0,width: 30,height: 20))
            if pattern == .split {
                context.setFillColor(GeneratedBleedOverlay.cgColor(.rgb(0.05,0.1,0.9)))
                context.fill(CGRect(x: 0,y: 10,width: 30,height: 10))
            }
            if pattern == .depth {
                context.setFillColor(CGColor(gray: 0,alpha: 1)); context.fill(CGRect(x: 0.25,y: 0,width: 0.25,height: 20))
            }
            context.restoreGState(); context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    private func project(_ source: PDFSource,gutter: Double = 0) -> Project {
        Project(pages: [source.pages[0].sourcePage],binding: .stepAndRepeat,
            sheet: SheetSpec(size: Size(130,90),margins: Insets(left: 5,right: 5,top: 5,bottom: 5),gutter: gutter,orientation: .landscape),
            settings: ImpositionSettings(bleed: 3,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1,
                generatedBleed: GeneratedBleedSettings(enabled: true)),
            stepAndRepeat: StepAndRepeatSettings(columns: 3,rows: 2,allowRotation: false))
    }
    private final class Bitmap {
        let context: CGContext
        let scale = 12.0
        init(_ size: Size) throws {
            context = try XCTUnwrap(CGContext(data: nil,width: Int(ceil(size.width*scale)),height: Int(ceil(size.height*scale)),bitsPerComponent: 8,
                bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(CGColor(gray: 1,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: context.width,height: context.height))
            context.scaleBy(x: scale,y: scale)
        }
        func color(_ x: Double,_ y: Double) -> [Double] {
            let column = max(0,min(context.width-1,Int(x*scale))),row = max(0,min(context.height-1,Int(y*scale)))
            let data = context.data!.assumingMemoryBound(to: UInt8.self),offset = (context.height-1-row)*context.bytesPerRow+column*4
            return (0..<3).map { Double(data[offset+$0])/255 }
        }
    }
    private func assertColor(_ actual: [Double],_ expected: [Double],file: StaticString = #filePath,line: UInt = #line) {
        for c in 0..<3 { XCTAssertEqual(actual[c],expected[c],accuracy: 0.09,file: file,line: line) }
    }
    private func output(_ plan: ImpositionPlan,source: PDFSource,in directory: URL,name: String) throws -> (CGPDFDocument,Bitmap) {
        let url = directory.appendingPathComponent(name+".pdf")
        _ = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(url),options: .artworkOnly)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL)),bitmap = try Bitmap(plan.sheets[0].size)
        bitmap.context.scaleBy(x: 1/ppmm,y: 1/ppmm); bitmap.context.drawPDFPage(try XCTUnwrap(document.page(at: 1)))
        if let path = ProcessInfo.processInfo.environment["ATISPRESS_GENERATED_QA"] {
            let folder = URL(fileURLWithPath: path,isDirectory: true)
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            try Data(contentsOf: url).write(to: folder.appendingPathComponent(name+".pdf"))
            let image = try XCTUnwrap(bitmap.context.makeImage())
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:])).write(to: folder.appendingPathComponent(name+".png"))
        }
        return (document,bitmap)
    }
    func testUniformAndVariedEdgesUseStripRangeAndKeepEdgePixels() async throws {
        let folder = try folder(), source = try await PDFSource.open(fixture([.solid,.split,.depth],in: folder))
        try await source.prepareGeneratedBleed(pages: [1,2,3])
        let solid = try XCTUnwrap(source.edgeSamples.cached(page: 1))
        for strip in solid.strips.values { XCTAssertNotNil(strip.uniformColor(tolerance: 0.02)) }
        let split = try XCTUnwrap(source.edgeSamples.cached(page: 2))
        XCTAssertNil(split.strips[.left]?.uniformColor(tolerance: 0.02))
        XCTAssertNil(split.strips[.right]?.uniformColor(tolerance: 0.02))
        XCTAssertNotNil(split.strips[.top]?.uniformColor(tolerance: 0.02))
        XCTAssertNotNil(split.strips[.bottom]?.uniformColor(tolerance: 0.02))
        XCTAssertNotNil(split.strips[.left]?.uniformColor(tolerance: 1))
        let depth = try XCTUnwrap(source.edgeSamples.cached(page: 3))
        XCTAssertNil(depth.strips[.left]?.uniformColor(tolerance: 0.02))
        XCTAssertFalse(solid.usesCMYK)
        try await source.prepareGeneratedBleed(pages: [1,1])
        XCTAssertTrue(source.edgeSamples.cached(page: 1) === solid)
    }
    func testAutoFollowsNonUniformEdgeAndUsesCornerColors() async throws {
        let folder = try folder(), source = try await PDFSource.open(fixture([.split],in: folder))
        var p = project(source)
        p.stepAndRepeat.columns = 1; p.stepAndRepeat.rows = 1
        let plan = ImpositionPlanner.plan(p), (_,bitmap) = try output(plan,source: source,in: folder,name: "automatic-edge")
        let slot = plan.sheets[0].front.slots[0]
        assertColor(bitmap.color(slot.x-1,slot.y+5),[0.85,0.1,0.05])
        assertColor(bitmap.color(slot.x-1,slot.y+15),[0.05,0.1,0.9])
        assertColor(bitmap.color(slot.x-1,slot.y-1),[0.85,0.1,0.05])
        assertColor(bitmap.color(slot.x-1,slot.y+21),[0.05,0.1,0.9])
        assertColor(bitmap.color(slot.x-4,slot.y+5),[1,1,1])
        _ = await source.image(page: 1,pixels: 128)
        let preview = try Bitmap(plan.sheets[0].size)
        let page = try XCTUnwrap(CGPDFDocument(source.url as CFURL)?.page(at: 1))
        try PDFPlanRenderer.drawSlot(slot,page: page,in: preview.context,reference: SlotReference(sheet: 0,side: .front,slot: 0),
            raster: source.cachedRaster(page: 1,pixels: 128),
            overlays: [GeneratedBleedOverlay(settings: plan.generatedBleed,cache: source.edgeSamples)])
        for y in [slot.y-1,slot.y+5,slot.y+15,slot.y+21] {
            assertColor(preview.color(slot.x-1,y),bitmap.color(slot.x-1,y))
        }
    }
    func testThreeByTwoBlockHasOnlyOuterBleedAndPreviewMatchesExport() async throws {
        let folder = try folder(), source = try await PDFSource.open(fixture([.solid],in: folder))
        var p = project(source); p.settings.generatedBleed.method = .solidColor; p.settings.generatedBleed.color = .rgb(0,1,0)
        let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first)
        let (_,bitmap) = try output(plan,source: source,in: folder,name: "touching-block")
        let document = try XCTUnwrap(CGPDFDocument(source.url as CFURL)),preview = try Bitmap(sheet.size)
        let overlay = GeneratedBleedOverlay(settings: plan.generatedBleed,cache: source.edgeSamples)
        try PDFPlanRenderer.drawSide(sheet.front,sheet: sheet,document: document,in: preview.context,sheetIndex: 0,kind: .front,
                                     repetition: 0,options: .artworkOnly,overlays: [overlay])
        let first = sheet.front.slots[0]
        assertColor(bitmap.color(first.x-1,first.y+5),[0,1,0])
        assertColor(bitmap.color(first.x+31,first.y+5),[0.85,0.1,0.05]) // Neighbor's trim, no inner generated band.
        for slot in sheet.front.slots {
            assertColor(bitmap.color(slot.x+15,slot.y+10),[0.85,0.1,0.05])
        }
        for x in stride(from: 0.7,to: sheet.size.width,by: 3.1) {
            for y in stride(from: 0.7,to: sheet.size.height,by: 3.1) { assertColor(bitmap.color(x,y),preview.color(x,y)) }
        }
        let last = sheet.front.slots[5]
        assertColor(bitmap.color(last.x+31,last.y+10),[0,1,0])
        assertColor(bitmap.color(first.x-4,first.y+5),[1,1,1])
    }
    func testSpacedGridHasIndependentFourSidedBleed() async throws {
        let folder = try folder(), source = try await PDFSource.open(fixture([.solid],in: folder))
        var p = project(source,gutter: 2); p.settings.generatedBleed.method = .solidColor; p.settings.generatedBleed.color = .rgb(0,1,0)
        let plan = ImpositionPlanner.plan(p), (_,bitmap) = try output(plan,source: source,in: folder,name: "spaced-items")
        for slot in plan.sheets[0].front.slots {
            for (x,y) in [(slot.x-1,slot.y+10),(slot.x+31,slot.y+10),(slot.x+15,slot.y-1),(slot.x+15,slot.y+21)] {
                assertColor(bitmap.color(x,y),[0,1,0])
            }
        }
        let first = plan.sheets[0].front.slots[0]
        assertColor(bitmap.color(first.x+34,first.y+10),[1,1,1]) // Clear gutter between two 3 mm bleed bands.
    }
    func testMirrorDiffersFromEdgeStretchAndNeverChangesTrim() async throws {
        let folder = try folder(), source = try await PDFSource.open(fixture([.depth],in: folder))
        var p = project(source); p.stepAndRepeat.columns = 1; p.stepAndRepeat.rows = 1
        let automatic = ImpositionPlanner.plan(p), (_,a) = try output(automatic,source: source,in: folder,name: "depth-edge")
        p.settings.generatedBleed.method = .mirror
        let mirrored = ImpositionPlanner.plan(p), (_,b) = try output(mirrored,source: source,in: folder,name: "mirror")
        let slot = automatic.sheets[0].front.slots[0]
        assertColor(a.color(slot.x-0.35,slot.y+5),[0.85,0.1,0.05])
        assertColor(b.color(slot.x-0.35,slot.y+5),[0,0,0])
        assertColor(a.color(slot.x+10,slot.y+5),b.color(slot.x+10,slot.y+5))
    }
    func testNativeCMYKCanBeSampledAndEmittedAsCMYKVectorFills() async throws {
        let folder = try folder(), source = try await PDFSource.open(fixture([.cmyk],in: folder))
        try await source.prepareGeneratedBleed(pages: [1])
        let samples = try XCTUnwrap(source.edgeSamples.cached(page: 1))
        XCTAssertTrue(samples.usesCMYK)
        for strip in samples.strips.values {
            guard case .cmyk(let c,let m,let y,let k) = try XCTUnwrap(strip.uniformColor(tolerance: 0.02)) else { return XCTFail("CMYK expected") }
            for (a,b) in zip([c,m,y,k],[0.2,0.4,0,0.1]) { XCTAssertEqual(a,b,accuracy: 0.02) }
        }
        var p = project(source); p.stepAndRepeat.columns = 1; p.stepAndRepeat.rows = 1
        let plan = ImpositionPlanner.plan(p), (document,_) = try output(plan,source: source,in: folder,name: "cmyk-vector")
        XCTAssertTrue(PDFColorProbe.canReadNativeCMYK(try XCTUnwrap(document.page(at: 1))))
        let data = try Data(contentsOf: folder.appendingPathComponent("cmyk-vector.pdf"))
        XCTAssertNil(data.range(of: Data("/Subtype /Image".utf8)))
    }
    func testGeneratedBleedFollowsRotatedMirroredSlotClips() async throws {
        let folder = try folder(), source = try await PDFSource.open(fixture([.split],in: folder))
        for rotation in [0,90,180,270] {
            for mirrored in [false,true] {
                let width = rotation%180 == 0 ? 30.0 : 20.0, height = rotation%180 == 0 ? 20.0 : 30.0
                let slot = Slot(sourcePageNumber: 1,origin: Point(10,10),size: Size(width,height),rotation: rotation,mirrored: mirrored,
                    artworkClip: Rect(x: 7,y: 7,width: width+6,height: height+6))
                let plan = ImpositionPlan(sheets: [Sheet(size: Size(60,60),front: Side(slots: [slot]),back: Side())],
                    generatedBleed: GeneratedBleedSettings(enabled: true))
                let (_,bitmap) = try output(plan,source: source,in: folder,name: "transform-\(rotation)-\(mirrored)")
                for (localY,color) in [(5.0,[0.85,0.1,0.05]),(15.0,[0.05,0.1,0.9])] {
                    let x = mirrored ? 31.0 : -1.0, point: (Double,Double)
                    switch rotation {
                    case 90: point = (localY,30-x)
                    case 180: point = (30-x,20-localY)
                    case 270: point = (20-localY,x)
                    default: point = (x,localY)
                    }
                    assertColor(bitmap.color(slot.x+point.0,slot.y+point.1),color)
                }
                assertColor(bitmap.color(6,20),[1,1,1])
            }
        }
    }

}
