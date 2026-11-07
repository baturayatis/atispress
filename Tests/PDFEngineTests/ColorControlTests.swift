import XCTest
import CoreGraphics
import PDFEngine
import ImpositionCore

final class ColorControlTests: XCTestCase {
    private func sheet() -> Sheet {
        let front = Side(slots: [Slot(sourcePageNumber: 1,origin: Point(30,50),size: Size(240,300),
            artworkClip: Rect(x: 27,y: 47,width: 246,height: 306))],marks: [
                Mark(kind: .crop,start: Point(20,50),end: Point(25,50)),
                Mark(kind: .crop,start: Point(30,36),end: Point(30,41))])
        let back = Side(slots: [Slot(sourcePageNumber: 1,origin: Point(35,45),size: Size(230,310),
            artworkClip: Rect(x: 32,y: 42,width: 236,height: 316))],marks: [
                Mark(kind: .crop,start: Point(275,50),end: Point(280,50))])
        return Sheet(size: Size(300,400),front: front,back: back)
    }
    private var marks: ExportMarks {
        var settings = ExportMarks.none; settings.colorBar = true; settings.registrationTargets = true
        return settings
    }
    func testControlsAvoidBothFacesBleedAndCropAndBarUsesEveryGripperEdge() throws {
        for gripper in [Edge.bottom,.top,.left,.right] {
            for opposite in [false,true] {
                var sheet = sheet(); sheet.gripperEdge = gripper; sheet.backFlipsX = gripper == .bottom || gripper == .top
                var marks = marks; marks.barSide = opposite ? .opposite : .gripper
                let geometry = PDFColorControlRenderer.geometry(sheet: sheet,settings: marks)
                XCTAssertTrue(geometry.warnings.isEmpty)
                XCTAssertEqual(geometry.patches.count,12); XCTAssertEqual(geometry.targets.count,4)
                for rect in geometry.bounds {
                    XCTAssertTrue(CGRect(x: 0,y: 0,width: 300,height: 400).contains(rect))
                    for side in [sheet.front,sheet.back] {
                        for slot in side.slots {
                            let bleed = try XCTUnwrap(slot.artworkClip)
                            XCTAssertFalse(rect.intersects(CGRect(x: bleed.origin.x,y: bleed.origin.y,width: bleed.size.width,height: bleed.size.height)))
                        }
                        var reserve = marks; reserve.crop = true
                        for tick in PDFExportMarkRenderer.geometry(side: side,sheet: sheet,settings: reserve).segments {
                            let stroke = marks.lineWidth/PDFPreviewDrawing.pointsPerMM
                            let box = CGRect(x: min(tick.start.x,tick.end.x)-stroke/2,y: min(tick.start.y,tick.end.y)-stroke/2,
                                width: abs(tick.end.x-tick.start.x)+stroke,height: abs(tick.end.y-tick.start.y)+stroke)
                            XCTAssertFalse(rect.intersects(box))
                        }
                    }
                }
                for target in geometry.targets {
                    if target.edge == .bottom || target.edge == .top { XCTAssertEqual(target.center.x,150,accuracy: 0.00001) }
                    else { XCTAssertEqual(target.center.y,200,accuracy: 0.00001) }
                    XCTAssertFalse(try XCTUnwrap(geometry.barBounds).intersects(target.bounds))
                }
                let bar = try XCTUnwrap(geometry.barBounds)
                let edge: Edge = opposite ? (gripper == .bottom ? .top : gripper == .top ? .bottom : gripper == .left ? .right : .left) : gripper
                switch edge {
                case .bottom: XCTAssertLessThan(bar.maxY,42)
                case .top: XCTAssertGreaterThan(bar.minY,358)
                case .left: XCTAssertLessThan(bar.maxX,27)
                case .right: XCTAssertGreaterThan(bar.minX,273)
                }
                let secondFace = PDFColorControlRenderer.geometry(sheet: sheet,settings: marks,kind: .back)
                let aligned = CGRect(x: sheet.backFlipsX ? 300-bar.maxX : bar.minX,
                    y: sheet.backFlipsX ? bar.minY : 400-bar.maxY,width: bar.width,height: bar.height)
                XCTAssertEqual(secondFace.barBounds,aligned,"Back placement must align through the physical turn")
            }
        }
    }
    func testExactPatchDefinitionsSizesAndStableVisibilityAndInfoStripClearance() throws {
        let expected: [[Double]] = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1],
            [0.5,0,0,0],[0,0.5,0,0],[0,0,0.5,0],[0,0,0,0.5],[1,1,0,0],[0,1,1,0],[1,0,1,0],[0.5,0.4,0.4,0]]
        XCTAssertEqual(PDFColorControlRenderer.patchDefinitions.map(\.cmyk),expected)
        var settings = marks; settings.targetSize = 7; settings.patchSize = 8
        let sheet = sheet(),geometry = PDFColorControlRenderer.geometry(sheet: sheet,settings: settings)
        XCTAssertEqual(geometry.targets.first?.size,7)
        XCTAssertTrue(geometry.patches.allSatisfy { $0.bounds.width == 8 && $0.bounds.height == 8 })
        settings.registrationTargets = false
        let hidden = PDFColorControlRenderer.geometry(sheet: sheet,settings: settings)
        XCTAssertEqual(hidden.barBounds,geometry.barBounds)
        XCTAssertTrue(hidden.targets.isEmpty)
        settings = marks; settings.sheetInfo = true
        let controls = PDFColorControlRenderer.geometry(sheet: sheet,settings: settings)
        let info = try XCTUnwrap(PDFSheetInfo.placement(text: "İş · Tabaka 1 / 2 · Ofset",side: sheet.front,sheet: sheet,marks: settings))
        XCTAssertTrue(controls.bounds.allSatisfy { !$0.intersects(info.bounds) })
    }
    func testNoRoomSkipsControlsWithWarningsAndPartialMarginsKeepFittingTargets() {
        let full = Side(slots: [Slot(sourcePageNumber: 1,origin: Point(0,0),size: Size(300,400))])
        let sheet = Sheet(size: Size(300,400),front: full,back: full)
        let geometry = PDFColorControlRenderer.geometry(sheet: sheet,settings: marks)
        XCTAssertTrue(geometry.patches.isEmpty); XCTAssertTrue(geometry.targets.isEmpty)
        XCTAssertTrue(geometry.warnings.contains { $0.contains("Diz işaretleri") })
        XCTAssertTrue(geometry.warnings.contains { $0.contains("Renk skalası") })
        let partial = Side(slots: [Slot(sourcePageNumber: 1,origin: Point(0,20),size: Size(300,380))])
        let fitting = PDFColorControlRenderer.geometry(sheet: Sheet(size: Size(300,400),front: partial,back: partial),settings: marks)
        XCTAssertEqual(fitting.targets.map(\.edge),[.bottom])
        XCTAssertEqual(fitting.patches.count,12)
        XCTAssertFalse(fitting.warnings.isEmpty)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func source(_ folder: URL) async throws -> PDFSource {
        let url = folder.appendingPathComponent("gray.pdf")
        var media = CGRect(x: 0,y: 0,width: 20*72/25.4,height: 30*72/25.4)
        let cg = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        cg.beginPDFPage(nil); cg.setFillColor(CGColor(gray: 0.8,alpha: 1)); cg.fill(media); cg.endPDFPage(); cg.closePDF()
        return try await PDFSource.open(url)
    }
    private final class Operators {
        var fills: [[Double]] = [],strokes: [[Double]] = [],rectangles: [[Double]] = [],rgb = 0
        var cmykFill = false
        func scan(_ page: CGPDFPage) {
            let table = CGPDFOperatorTableCreate()!
            defer { CGPDFOperatorTableRelease(table) }
            CGPDFOperatorTableSetCallback(table,"k") { scanner,info in
                let value = Unmanaged<Operators>.fromOpaque(info!).takeUnretainedValue()
                value.fills.append(Operators.components(scanner)); value.cmykFill = true
            }
            CGPDFOperatorTableSetCallback(table,"K") { scanner,info in
                let value = Unmanaged<Operators>.fromOpaque(info!).takeUnretainedValue()
                value.strokes.append(Operators.components(scanner))
            }
            CGPDFOperatorTableSetCallback(table,"g") { _,info in Unmanaged<Operators>.fromOpaque(info!).takeUnretainedValue().cmykFill = false }
            CGPDFOperatorTableSetCallback(table,"re") { scanner,info in
                let value = Unmanaged<Operators>.fromOpaque(info!).takeUnretainedValue()
                let rect = Operators.components(scanner)
                if value.cmykFill { value.rectangles.append(rect) }
            }
            for op in ["rg","RG"] { CGPDFOperatorTableSetCallback(table,op) { _,info in Unmanaged<Operators>.fromOpaque(info!).takeUnretainedValue().rgb += 1 } }
            let content = CGPDFContentStreamCreateWithPage(page)
            defer { CGPDFContentStreamRelease(content) }
            let scanner = CGPDFScannerCreate(content,table,Unmanaged.passUnretained(self).toOpaque())
            defer { CGPDFScannerRelease(scanner) }
            XCTAssertTrue(CGPDFScannerScan(scanner))
        }
        static func components(_ scanner: CGPDFScannerRef) -> [Double] {
            var values: [Double] = []
            for _ in 0..<4 { var value: CGPDFReal = 0; if CGPDFScannerPopNumber(scanner,&value) { values.insert(value,at: 0) } }
            return values
        }
    }
    func testExportWritesExactVectorCMYKPatchesAndRegistrationTargetsAndNoRoomNotes() async throws {
        let folder = try folder(),source = try await source(folder)
        var sheet = sheet()
        let output = folder.appendingPathComponent("controls.pdf")
        let result = try PDFExporter.export(plan: ImpositionPlan(sheets: [sheet]),source: source,destination: .singlePDF(output),marks: marks)
        XCTAssertEqual(result.pageCount,2)
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL)),ops = Operators()
        ops.scan(try XCTUnwrap(pdf.page(at: 1)))
        XCTAssertEqual(ops.rgb,0)
        for patch in PDFColorControlRenderer.patchDefinitions {
            XCTAssertTrue(ops.fills.contains { values in values.count == 4 && zip(values,patch.cmyk).allSatisfy { abs($0-$1) < 0.000001 } },"Missing exact CMYK patch \(patch.name): \(ops.fills)")
        }
        XCTAssertTrue(ops.strokes.contains([1,1,1,1]),"Targets always use registration, even with black export marks")
        let back = Operators(); back.scan(try XCTUnwrap(pdf.page(at: 2)))
        XCTAssertEqual(ops.rectangles.count,12); XCTAssertEqual(back.rectangles.count,12)
        for (frontRect,backRect) in zip(ops.rectangles,back.rectangles) {
            let expected = [300*72/25.4-frontRect[0]-frontRect[2],frontRect[1],frontRect[2],frontRect[3]]
            for (actual,value) in zip(backRect,expected) { XCTAssertEqual(actual,value,accuracy: 0.0002,"Bar patches align through the sheet turn") }
        }
        sheet.back = Side()
        let simplex = try PDFExporter.export(plan: ImpositionPlan(sheets: [sheet]),source: source,
            destination: .singlePDF(folder.appendingPathComponent("front.pdf")),marks: marks)
        XCTAssertEqual(simplex.pageCount,1,"Control marks must not create an empty back")
        let noRoom = Side(slots: [Slot(sourcePageNumber: 1,origin: Point(0,0),size: Size(300,400))])
        let skipped = try PDFExporter.export(plan: ImpositionPlan(sheets: [Sheet(size: Size(300,400),front: noRoom,back: Side())]),source: source,
            destination: .singlePDF(folder.appendingPathComponent("skipped.pdf")),marks: marks)
        XCTAssertTrue(skipped.notes.contains { $0.contains("Renk skalası") })
        XCTAssertTrue(skipped.notes.contains { $0.contains("Diz işaretleri") })
        let empty = Operators(); empty.scan(try XCTUnwrap(CGPDFDocument(skipped.files[0] as CFURL)?.page(at: 1)))
        XCTAssertTrue(empty.fills.isEmpty); XCTAssertTrue(empty.strokes.isEmpty)
    }
    func testPreviewSwitchesRenderControlsButCompatibilityExportIgnoresThem() async throws {
        let folder = try folder(),source = try await source(folder),sheet = sheet()
        var options = PDFRenderOptions.artworkOnly; options.colorBar = true; options.registrationTargets = true
        let url = folder.appendingPathComponent("preview.pdf")
        var media = CGRect(x: 0,y: 0,width: 300*72/25.4,height: 400*72/25.4)
        let cg = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        cg.beginPDFPage(nil); cg.scaleBy(x: 72/25.4,y: 72/25.4)
        try PDFPlanRenderer.drawSide(sheet.front,sheet: sheet,document: XCTUnwrap(CGPDFDocument(source.url as CFURL)),in: cg,
            sheetIndex: 0,kind: .front,repetition: 0,options: options)
        cg.endPDFPage(); cg.closePDF()
        let preview = Operators(); preview.scan(try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1)))
        XCTAssertEqual(preview.fills.count,12)
        let result = try PDFExporter.export(plan: ImpositionPlan(sheets: [sheet]),source: source,
            destination: .singlePDF(folder.appendingPathComponent("export.pdf")),options: options)
        let exported = Operators(); exported.scan(try XCTUnwrap(CGPDFDocument(result.files[0] as CFURL)?.page(at: 1)))
        XCTAssertTrue(exported.fills.isEmpty); XCTAssertTrue(exported.strokes.isEmpty)
    }
}
