import XCTest
import PDFKit
import PDFEngine
import ImpositionCore

final class PDFSourceTests: XCTestCase {
    func testBoxesRotationAndRaster() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 100,height: 160))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0,y: 0,width: 100,height: 160).fill(); image.unlockFocus()
        let page = try XCTUnwrap(PDFPage(image: image))
        page.setBounds(CGRect(x: 0,y: 0,width: 220,height: 320),for: .mediaBox)
        page.setBounds(CGRect(x: 10,y: 10,width: 200,height: 300),for: .trimBox)
        page.setBounds(CGRect(x: 4,y: 4,width: 212,height: 312),for: .bleedBox)
        page.rotation = 90
        document.insert(page,at: 0)
        XCTAssertTrue(document.write(to: url)) // Test fixture only; production contains no export.
        let source = try await PDFSource.open(url)
        XCTAssertEqual(source.pages.count,1)
        XCTAssertEqual(source.pages[0].trimSize.width,300*25.4/72,accuracy: 0.001)
        XCTAssertEqual(source.pages[0].trimSize.height,200*25.4/72,accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(source.pages[0].availableBleed),6*25.4/72,accuracy: 0.001)
        XCTAssertTrue(source.pages[0].hasTrimBox)
        let raster = await source.image(page: 1,pixels: 128)
        XCTAssertNotNil(raster); XCTAssertNotNil(source.cachedImage(page: 1,pixels: 128))
    }
    func testMissingBleedIsUnknownAndMediaBoxIsFallback() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var rect = CGRect(x: 0,y: 0,width: 144,height: 216)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer,mediaBox: &rect,nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let source = try await PDFSource.open(url)
        XCTAssertNil(source.pages[0].availableBleed)
        XCTAssertFalse(source.pages[0].hasTrimBox)
        XCTAssertEqual(source.pages[0].trimSize.width,50.8,accuracy: 0.0001)
        let invalid = await source.image(page: 0,pixels: 128)
        XCTAssertNil(invalid)
    }
    func testUnreadablePDFReportsTurkishError() async throws {
        do {
            _ = try await PDFSource.open(URL(fileURLWithPath: "/nonexistent-atispress-test.pdf"))
            XCTFail("Expected unreadable PDF error")
        } catch {
            XCTAssertEqual(error.localizedDescription,"PDF dosyası okunamadı.")
        }
    }
    func testSlotTransformsPreservePlanFootprint() {
        for rotation in [0,90,180,270] {
            for mirrored in [false,true] {
                let slot = Slot(sourcePageNumber: 1,origin: Point(13,27),size: Size(100,150),rotation: rotation,mirrored: mirrored)
                let local = CGRect(x: 0,y: 0,width: rotation%180 == 0 ? 100 : 150,height: rotation%180 == 0 ? 150 : 100)
                let rect = local.applying(PDFPreviewDrawing.slotTransform(slot))
                XCTAssertEqual(rect.minX,13,accuracy: 0.0001); XCTAssertEqual(rect.minY,27,accuracy: 0.0001)
                XCTAssertEqual(rect.width,100,accuracy: 0.0001); XCTAssertEqual(rect.height,150,accuracy: 0.0001)
                XCTAssertEqual(PDFPreviewDrawing.slotTransform(slot).determinant < 0,mirrored)
            }
        }
    }
}
private extension CGAffineTransform { var determinant: CGFloat { a*d-b*c } }
