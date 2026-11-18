import XCTest
import PDFKit
import ImpositionCore
@testable import PDFEngine

final class ImageColorTests: XCTestCase {
    private func stream(_ dictionary: String, _ samples: Data) -> Data {
        Data("<< \(dictionary) /Length \(samples.count) >>\nstream\n".utf8) + samples + Data("\nendstream".utf8)
    }

    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("images.pdf")
        let icc = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()) as Data
        let rgb = Data([80, 40, 20])
        let image = "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace"
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 140] /Resources << /Font << /F 6 0 R >> /XObject << /RGB 5 0 R /CMYK 7 0 R /ICC 8 0 R /Masked 10 0 R /Spot 12 0 R /Nested 14 0 R >> >> /Contents 4 0 R >>".utf8),
            stream("", Data("q 35 0 0 35 10 15 cm /RGB Do Q q 35 0 0 35 55 15 cm /CMYK Do Q q 35 0 0 35 100 15 cm /ICC Do Q q 35 0 0 35 145 15 cm /Masked Do Q q 30 0 0 20 10 65 cm /Spot Do Q q 35 0 0 25 55 65 cm /Nested Do Q BT /F 14 Tf 15 100 Td (Vector proof) Tj ET".utf8)),
            stream("\(image) /DeviceRGB", rgb),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            stream("\(image) /DeviceCMYK", Data([55, 55, 10, 20])),
            stream("\(image) [/ICCBased 9 0 R]", rgb),
            stream("/N 3", icc),
            stream("\(image) /DeviceRGB /SMask 11 0 R", rgb),
            stream("\(image) /DeviceGray", Data([128])),
            stream("\(image) [/Separation /TestSpot /DeviceCMYK 13 0 R]", Data([127])),
            Data("<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 0.75 0.5 0] /N 1 >>".utf8),
            stream("/Type /XObject /Subtype /Form /BBox [0 0 1 1]", Data("/RGB Do".utf8))
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(i + 1) 0 obj\n".utf8)); data.append(object); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: url)
        return url
    }

    private func image(_ page: CGPDFPage, name: String) throws -> CGPDFStreamRef {
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?, image: CGPDFStreamRef?
        let page = try XCTUnwrap(page.dictionary)
        XCTAssertTrue(CGPDFDictionaryGetDictionary(page, "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &objects))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(objects), name, &image))
        return try XCTUnwrap(image)
    }

    private func samples(_ stream: CGPDFStreamRef) throws -> Data {
        var format = CGPDFDataFormat.raw
        return try XCTUnwrap(CGPDFStreamCopyData(stream, &format)) as Data
    }

    private func names(_ page: CGPDFPage) throws -> [String] {
        let tokens = pdfTokens(try XCTUnwrap(pdfPageContent(page)))
        return tokens.indices.dropFirst().compactMap {
            tokens[$0].text == "Do" ? String(tokens[$0 - 1].text.dropFirst()) : nil
        }
    }

    private func displayedImage(_ page: CGPDFPage, at index: Int) throws -> CGPDFStreamRef {
        let name = try names(page)[index]
        return try image(page, name: name)
    }

    func testAdjustmentsPreserveVectorContentICCAndUnsupportedImageStreams() async throws {
        let url = try fixture()
        let original = try Data(contentsOf: url)
        let source = try await PDFSource.open(url)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        var adjustment = ImageColorAdjustment()
        adjustment.brightness = 0.1
        adjustment.contrast = 1.5
        adjustment.saturation = 0
        var slot = Slot(sourcePageNumber: 1, origin: Point(12, 12), size: source.pages[0].trimSize)
        slot.imageColor = adjustment
        let sheet = Sheet(size: Size(110, 85), front: Side(slots: [slot]), back: Side())
        let plan = ImpositionPlan(sheets: [sheet])
        let variants = try PDFColorVariants.prepare(source: source, plan: plan)
        let adjusted = try XCTUnwrap(variants.page(for: slot), "\(variants.warnings)")
        XCTAssertEqual(try samples(displayedImage(adjusted, at: 0)), Data([32, 32, 32]))
        XCTAssertEqual(try samples(displayedImage(adjusted, at: 2)), Data([32, 32, 32]))
        XCTAssertEqual(try samples(image(adjusted, name: "CMYK")), try samples(image(page, name: "CMYK")))
        XCTAssertEqual(try samples(image(adjusted, name: "Masked")), try samples(image(page, name: "Masked")))
        XCTAssertEqual(try samples(image(adjusted, name: "Spot")), try samples(image(page, name: "Spot")))
        XCTAssertEqual(try samples(image(adjusted, name: "Nested")), try samples(image(page, name: "Nested")))
        var restored = String(decoding: try XCTUnwrap(pdfPageContent(adjusted)), as: UTF8.self)
        for (new, old) in zip(try names(adjusted), try names(page)) {
            restored = restored.replacingOccurrences(of: "/\(new) Do", with: "/\(old) Do")
        }
        XCTAssertEqual(restored.trimmingCharacters(in: .whitespacesAndNewlines),
                       String(decoding: try XCTUnwrap(pdfPageContent(page)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(try samples(image(adjusted, name: "RGB")), try samples(image(page, name: "RGB")))
        let icc = try XCTUnwrap(CGPDFStreamGetDictionary(try displayedImage(adjusted, at: 2)))
        var array: CGPDFArrayRef?, profile: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(icc, "ColorSpace", &array))
        XCTAssertTrue(CGPDFArrayGetStream(try XCTUnwrap(array), 1, &profile))
        XCTAssertEqual(try samples(XCTUnwrap(profile)), try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()) as Data)
        XCTAssertTrue(variants.warnings.contains { $0.contains("CMYK") })
        XCTAssertTrue(variants.warnings.contains { $0.contains("Maskeli") })

        let output = url.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let report = try PDFExporter.export(plan: plan, source: source, destination: .singlePDF(output), marks: .none)
        XCTAssertEqual(report.pageCount, 1)
        XCTAssertTrue(report.notes.contains { $0.contains("CMYK") })
        let imposed = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(imposed.string?.contains("Vector proof") == true)
        XCTAssertEqual(try Data(contentsOf: url), original)

        // Sample the same image from the adjusted source and the exported slot.
        func pixel(_ page: CGPDFPage, _ point: CGPoint) throws -> UInt8 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 3,
                                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.translateBy(x: 1.5 - point.x, y: 1.5 - point.y)
            context.drawPDFPage(page)
            return try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)[4]
        }
        let printed = try XCTUnwrap(CGPDFDocument(output as CFURL)?.page(at: 1))
        let scale = PDFPreviewDrawing.pointsPerMM
        func outputPixel(_ point: CGPoint) throws -> UInt8 {
            try pixel(printed, CGPoint(x: point.x + slot.x * scale, y: point.y + slot.y * scale))
        }
        let point = CGPoint(x: 20, y: 25)
        XCTAssertNotEqual(try pixel(page, point), try outputPixel(point))
        XCTAssertEqual(try outputPixel(point), 32, accuracy: 3)
        for point in [CGPoint(x: 110, y: 25), CGPoint(x: 65, y: 25), CGPoint(x: 155, y: 25), CGPoint(x: 20, y: 75)] {
            XCTAssertEqual(try outputPixel(point), try pixel(adjusted, point), accuracy: 3)
        }
    }

    func testSamePageCanUseDifferentJobAdjustmentsAndResetIsOriginal() async throws {
        let url = try fixture(), source = try await PDFSource.open(url)
        var one = ImageColorAdjustment(), two = ImageColorAdjustment()
        one.brightness = 0.2
        two.brightness = -0.2
        var first = Slot(sourcePageNumber: 1, origin: Point(0, 0), size: source.pages[0].trimSize)
        first.imageColor = one
        var second = first
        second.imageColor = two
        var reset = first
        reset.imageColor = ImageColorAdjustment()
        let plan = ImpositionPlan(sheets: [Sheet(size: Size(200, 200), front: Side(slots: [first, second, reset]), back: Side())])
        let variants = try PDFColorVariants.prepare(source: source, plan: plan)
        XCTAssertEqual(try samples(displayedImage(XCTUnwrap(variants.page(for: first)), at: 0)), Data([131, 91, 71]))
        XCTAssertEqual(try samples(displayedImage(XCTUnwrap(variants.page(for: second)), at: 0)), Data([29, 0, 0]))
        XCTAssertNil(variants.page(for: reset))
    }
}
