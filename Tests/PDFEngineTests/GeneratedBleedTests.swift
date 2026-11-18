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
    func testAutomaticAndMirrorBothPreserveEdgeDepthAndTrim() async throws {
        let folder = try folder(), source = try await PDFSource.open(fixture([.depth],in: folder))
        var p = project(source); p.stepAndRepeat.columns = 1; p.stepAndRepeat.rows = 1
        let automatic = ImpositionPlanner.plan(p), (_,a) = try output(automatic,source: source,in: folder,name: "depth-edge")
        p.settings.generatedBleed.method = .mirror
        let mirrored = ImpositionPlanner.plan(p), (_,b) = try output(mirrored,source: source,in: folder,name: "mirror")
        let slot = automatic.sheets[0].front.slots[0]
        assertColor(a.color(slot.x-0.35,slot.y+5),[0,0,0])
        assertColor(b.color(slot.x-0.35,slot.y+5),[0,0,0])
        assertColor(a.color(slot.x+10,slot.y+5),b.color(slot.x+10,slot.y+5))
    }
    private func oxygenFixture(in folder: URL, size: Size, textured: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent("oxygen-vector-fixture.pdf")
        var trim = CGRect(x: 5*ppmm, y: 5*ppmm, width: size.width*ppmm, height: size.height*ppmm)
        var media = trim.insetBy(dx: -5*ppmm, dy: -5*ppmm)
        var bleed = CGRect(x: trim.minX-ppmm, y: trim.minY, width: trim.width+ppmm, height: trim.height)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)), mediaBox: &media, nil))
        for color in [BleedColor.rgb(0.12,0.35,0.8), .rgb(0.83,0.24,0.16)] {
            context.beginPDFPage([kCGPDFContextTrimBox: NSData(bytes: &trim, length: MemoryLayout<CGRect>.size),
                                  kCGPDFContextBleedBox: NSData(bytes: &bleed, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.translateBy(x: trim.minX, y: trim.minY)
            context.scaleBy(x: ppmm, y: ppmm)
            context.setFillColor(GeneratedBleedOverlay.cgColor(.rgb(0,0.7,0.25)))
            context.fill(CGRect(x: -1, y: 0, width: 1, height: size.height))
            context.setFillColor(GeneratedBleedOverlay.cgColor(color))
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
            context.fill(CGRect(x: 1, y: 2.5, width: 1, height: size.height - 3))
            if textured {
                for (x, y, color) in [
                    (-1.0, 18.0, BleedColor.rgb(0.15,0.1,0.65)), (size.width-2, 24.0, .rgb(0.1,0.6,0.35)),
                    (24.0, 1.0, .rgb(0.6,0,0.4)), (42.0, size.height-2, .rgb(0,0.6,0.7)),
                    (-1.0, 1.0, .rgb(0.55,0.2,0)), (-1.0, size.height-2, .rgb(0.15,0.2,0.7)),
                    (size.width-2, 1.0, .rgb(0,0.4,0.2)), (size.width-2, size.height-2, .rgb(0.35,0.2,0.65))
                ] {
                    context.setFillColor(GeneratedBleedOverlay.cgColor(color))
                    context.fill(CGRect(x: x,y: y,width: 1,height: 1))
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testOxygenSizedDuplexUsesVectorBleedAtThreeAndTenMillimeters() async throws {
        let folder = try folder()
        let input = try oxygenFixture(in: folder, size: Size(86.7,54))
        let source = try await PDFSource.open(input), original = try XCTUnwrap(CGPDFDocument(input as CFURL))
        for amount in [3.0,10.0] {
            var p = project(source,gutter: 2)
            p.pages = source.pages.map(\.sourcePage)
            p.sheet.size = Size(240,95)
            p.settings.bleed = amount
            p.stepAndRepeat = StepAndRepeatSettings(columns: 2, rows: 1, allowRotation: false, quantity: 2)
            p.stepAndRepeat.pageLayout = PageLayoutSettings()
            p.stepAndRepeat.pageLayout?.mode = .duplex
            let plan = ImpositionPlanner.plan(p), sheet = try XCTUnwrap(plan.sheets.first)
            XCTAssertTrue(plan.canExport, "\(plan.issues)")
            let (export, _) = try output(plan,source: source,in: folder,name: "oxygen-\(amount)")
            XCTAssertEqual(export.numberOfPages,2)
            let data = try Data(contentsOf: folder.appendingPathComponent("oxygen-\(amount).pdf"))
            XCTAssertNil(data.range(of: Data("/Subtype /Image".utf8)))
            for (side, kind, number) in [(sheet.front, SideKind.front, 1), (sheet.back, .back, 2)] {
                let preview = try Bitmap(sheet.size), printed = try Bitmap(sheet.size)
                try PDFPlanRenderer.drawSide(side, sheet: sheet, document: original, in: preview.context,
                                             sheetIndex: 0, kind: kind, repetition: 0, options: .artworkOnly,
                                             overlays: [GeneratedBleedOverlay(settings: plan.generatedBleed, cache: source.edgeSamples)])
                printed.context.scaleBy(x: 1/ppmm, y: 1/ppmm)
                printed.context.drawPDFPage(try XCTUnwrap(export.page(at: number)))
                let sorted = side.slots.sorted { $0.x < $1.x }
                let left = sorted[0], right = sorted[1]
                XCTAssertEqual(right.x-left.x-left.size.width, 2*amount+2, accuracy: 0.001)
                for slot in sorted {
                    XCTAssertEqual(slot.size.width,86.7,accuracy:0.001)
                    XCTAssertEqual(slot.size.height,54,accuracy:0.001)
                    let transform = PDFPreviewDrawing.slotTransform(slot)
                    func actual(_ x: Double,_ y: Double) -> [Double] {
                        let point = CGPoint(x:x,y:y).applying(transform)
                        let color = printed.color(point.x,point.y)
                        assertColor(color, preview.color(point.x,point.y))
                        return color
                    }
                    let base = number == 1 ? [0.12,0.35,0.8] : [0.83,0.24,0.16]
                    assertColor(actual(-0.45,15),[0,0.7,0.25]) // Real source bleed.
                    assertColor(actual(-1.5,15),[0,0.7,0.25]) // Reflect the real outer edge.
                    assertColor(actual(-amount+0.35,15),base)
                    assertColor(actual(-1.5,-1.5),[0,0.7,0.25]) // Both axes reflected in the corner.
                    assertColor(actual(-amount+0.35,-amount+0.35),base)
                    assertColor(actual(86.7+amount-0.35,54+amount-0.35),base)
                    assertColor(actual(10,15),base)
                    // Detect gaps independently of antialiasing differences at vector ink edges.
                    func assertCovered(_ x: Double,_ y: Double) {
                        let point = CGPoint(x:x,y:y).applying(transform)
                        for bitmap in [preview,printed] {
                            XCTAssertLessThan(bitmap.color(point.x,point.y).min() ?? 1,0.9)
                        }
                    }
                    for x in stride(from: -amount+0.2, to: 86.7+amount-0.15, by: 0.61) {
                        for y in [-amount+0.22,54+amount-0.22] { assertCovered(x,y) }
                    }
                    for y in stride(from: 0.25, to: 54, by: 0.61) {
                        for x in [-amount+0.22,86.7+amount-0.22] { assertCovered(x,y) }
                    }
                }
                assertColor(printed.color((left.x+left.size.width+right.x)/2,left.y+15),[1,1,1])
            }
        }
        XCTAssertNil(source.edgeSamples.cached(page:1))
        XCTAssertNil(source.edgeSamples.cached(page:2))
    }

    func testMirrorJoinsFollowTexturedSourceOnEveryEdgeAndCorner() async throws {
        let folder = try folder(), size = Size(86.7,54)
        let input = try oxygenFixture(in: folder, size: size, textured: true)
        let source = try await PDFSource.open(input), original = try XCTUnwrap(CGPDFDocument(input as CFURL))
        for amount in [3.0,10.0] {
            let slots = [1,2].map { page in
                var slot = Slot(sourcePageNumber: page, origin: Point(20.03,20.04), size: size,
                                artworkClip: Rect(x: 20.03-amount,y: 20.04-amount,width: size.width+2*amount,height: size.height+2*amount))
                if page == 2 {
                    slot.artworkOffset = Point(0.37,0.41)
                    slot.bindingTranslation = Point(0.12,0.13)
                }
                return slot
            }
            let sheet = Sheet(size: Size(140,100),front: Side(slots: [slots[0]]),back: Side(slots: [slots[1]]))
            let settings = GeneratedBleedSettings(enabled: true, method: .mirror)
            let plan = ImpositionPlan(sheets: [sheet], generatedBleed: settings)
            let (export, _) = try output(plan,source: source,in: folder,name: "mirror-joins-\(amount)")
            for (index, slot) in slots.enumerated() {
                let page = try XCTUnwrap(original.page(at: index+1))
                let preview = try Bitmap(sheet.size), pdf = try Bitmap(sheet.size)
                // Supplying a cached preview must not mix raster and vector at the join.
                let tinyRaster = try Bitmap(Size(1,1))
                let raster = PDFPageRaster(cgImage: try XCTUnwrap(tinyRaster.context.makeImage()),
                                           bounds: CGRect(x: 0,y: 0,width: 1,height: 1))
                try PDFPlanRenderer.drawSlot(slot,page: page,in: preview.context,
                    reference: SlotReference(sheet: 0,side: index == 0 ? .front : .back,slot: 0),raster: raster,
                    overlays: [GeneratedBleedOverlay(settings: settings,cache: source.edgeSamples)])
                pdf.context.scaleBy(x: 1/ppmm,y: 1/ppmm)
                pdf.context.drawPDFPage(try XCTUnwrap(export.page(at: index+1)))
                let artworkX = slot.x + slot.artworkOffset.x + slot.bindingTranslation.x
                let artworkY = slot.y + slot.artworkOffset.y + slot.bindingTranslation.y
                for (x,y,mirrorX,mirrorY,color) in [
                    (-0.5,18.5,true,false,[0.15,0.1,0.65]),
                    (size.width-1.5,24.5,true,false,[0.1,0.6,0.35]),
                    (24.5,1.5,false,true,[0.6,0,0.4]),
                    (42.5,size.height-1.5,false,true,[0,0.6,0.7]),
                    (-0.5,1.5,true,true,[0.55,0.2,0]),
                    (-0.5,size.height-1.5,true,true,[0.15,0.2,0.7]),
                    (size.width-1.5,1.5,true,true,[0,0.4,0.2]),
                    (size.width-1.5,size.height-1.5,true,true,[0.35,0.2,0.65])
                ] {
                    let rx = mirrorX ? 2*(x < 0 ? -1 : size.width)-x : x
                    let ry = mirrorY ? 2*(y < size.height/2 ? 0 : size.height)-y : y
                    for bitmap in [preview,pdf] {
                        assertColor(bitmap.color(artworkX+x,artworkY+y),color)
                        assertColor(bitmap.color(artworkX+rx,artworkY+ry),color)
                    }
                }
                // Probe the fractional joins, including the four points where tiles meet.
                for x in [-1.0,20,size.width] {
                    for y in [0.0,12,size.height] {
                        for bitmap in [preview,pdf] {
                            XCTAssertLessThan(bitmap.color(artworkX+x,artworkY+y).min() ?? 1,0.8)
                        }
                    }
                }
            }
        }
    }

    func testReflectionRepeatsWhenTrimIsNarrowerThanBleed() async throws {
        let folder = try folder(), input = try oxygenFixture(in: folder, size: Size(4,5))
        let source = try await PDFSource.open(input)
        let slot = Slot(sourcePageNumber: 1,origin: Point(15,15),size: source.pages[0].trimSize,
                        artworkClip: Rect(x: 5,y: 5,width: 24,height: 25))
        let plan = ImpositionPlan(sheets: [Sheet(size: Size(35,35),front: Side(slots: [slot]),back: Side())],
                                  generatedBleed: GeneratedBleedSettings(enabled: true))
        let (_,bitmap) = try output(plan,source: source,in: folder,name: "reflect-repeat")
        for distance in [3.5,8.5] {
            assertColor(bitmap.color(slot.x-distance,slot.y+3),[0,0,0])
        }
        for d in stride(from: 1.1,to: 10,by: 0.11) {
            XCTAssertLessThan(bitmap.color(slot.x-d,slot.y+2.2).min() ?? 1,0.9)
        }
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
