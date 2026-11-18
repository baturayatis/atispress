import XCTest
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import zlib
import ImpositionCore
@testable import PDFEngine

final class ImageColorTests: XCTestCase {
    private func stream(_ dictionary: String, _ samples: Data) -> Data {
        Data("<< \(dictionary) /Length \(samples.count) >>\nstream\n".utf8) + samples + Data("\nendstream".utf8)
    }

    private func fixture() throws -> URL {
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
        return try writePDF(objects)
    }

    private func writePDF(_ objects: [Data]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("images.pdf")
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

    private func pixel(_ page: CGPDFPage, _ point: CGPoint) throws -> UInt8 {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 3,
                                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.translateBy(x: 1.5 - point.x, y: 1.5 - point.y)
        context.drawPDFPage(page)
        return try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)[4]
    }

    private func jpeg(samples: [UInt8], components: Int, profile: Data? = nil) throws -> Data {
        let width = 8, height = 8
        let data = Data((0..<(width * height)).flatMap { i in
            let start = i < width * height / 2 ? 0 : components
            return Array(samples[start..<(start + components)])
        })
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let space = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                         bitsPerPixel: components * 8, bytesPerRow: width * components, space: space,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let buffer = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let encoded = buffer as Data

        // Control ICC independently of the encoder's platform defaults.
        var result = Data([0xff, 0xd8])
        if let profile {
            let length = 16 + profile.count
            result.append(contentsOf: [0xff, 0xe2, UInt8(length >> 8), UInt8(length & 255)])
            result.append(contentsOf: "ICC_PROFILE\0".utf8)
            result.append(contentsOf: [1, 1])
            result.append(profile)
        }
        var offset = 2
        while encoded[offset + 1] != 0xda {
            let marker = encoded[offset + 1]
            let length = Int(encoded[offset + 2]) * 256 + Int(encoded[offset + 3])
            let end = offset + length + 2
            if marker != 0xe2 { result.append(encoded[offset..<end]) }
            offset = end
        }
        result.append(encoded[offset...])
        return result
    }

    func testDCTRGBGrayAndICCSharePreviewAndExportWithVectorText() async throws {
        let profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()) as Data
        let rgb = try jpeg(samples: [90, 40, 30, 180, 110, 90], components: 3, profile: profile)
        let gray = try jpeg(samples: [65, 150], components: 1)
        let plain = try jpeg(samples: [90, 40, 30, 180, 110, 90], components: 3)
        let imageDictionary = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /BitsPerComponent 8"
        let url = try writePDF([
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 140] /Resources << /Font << /F 5 0 R >> /XObject << /RGB 6 0 R /Gray 7 0 R /Plain 9 0 R /Custom 10 0 R /Embedded 11 0 R >> >> /Contents 4 0 R >>".utf8),
            stream("", Data("q 36 0 0 56 8 15 cm /RGB Do Q q 36 0 0 56 55 15 cm /Gray Do Q q 36 0 0 56 100 15 cm /Plain Do Q q 36 0 0 56 145 15 cm /Custom Do Q q 36 0 0 26 145 82 cm /Embedded Do Q BT /F 14 Tf 15 100 Td (Vector JPEG proof) Tj ET".utf8)),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            stream("\(imageDictionary) /ColorSpace [/ICCBased 8 0 R] /Filter /DCTDecode", rgb),
            stream("\(imageDictionary) /ColorSpace /DeviceGray /Filter [/DCTDecode] /DecodeParms [<< /ColorTransform 0 >>]", gray),
            stream("/N 3", profile),
            stream("\(imageDictionary) /ColorSpace /DeviceRGB /Filter /DCTDecode /DecodeParms << /ColorTransform 1 >>", plain),
            stream("\(imageDictionary) /ColorSpace /DeviceRGB /Filter /DCTDecode /DecodeParms << /ColorTransform 0 >>", plain),
            stream("\(imageDictionary) /ColorSpace /DeviceRGB /Filter /DCTDecode", rgb)
        ])
        let original = try Data(contentsOf: url)
        let source = try await PDFSource.open(url)
        var slot = Slot(sourcePageNumber: 1, origin: Point(8, 12), size: source.pages[0].trimSize)
        var adjustment = ImageColorAdjustment()
        adjustment.brightness = 0.20
        adjustment.contrast = 1.15
        adjustment.saturation = 0
        slot.imageColor = adjustment
        let plan = ImpositionPlan(sheets: [Sheet(size: Size(110, 85), front: Side(slots: [slot]), back: Side())])
        let variants = try PDFColorVariants.prepare(source: source, plan: plan)
        let preview = try XCTUnwrap(variants.page(for: slot), "\(variants.warnings)")
        let beforeDoc = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let before = try XCTUnwrap(beforeDoc.page(at: 1))
        let imageNames = try names(preview)
        XCTAssertTrue(imageNames.prefix(3).allSatisfy { $0.hasPrefix("AtisPressColor") }, "\(variants.warnings)")
        XCTAssertEqual(Array(imageNames.suffix(2)), ["Custom", "Embedded"])
        XCTAssertEqual(try samples(image(preview, name: "Custom")), plain)
        XCTAssertEqual(try samples(image(preview, name: "Embedded")), rgb)
        XCTAssertTrue(variants.warnings.contains { $0.contains("JPEG") })
        XCTAssertTrue(variants.warnings.contains { $0.contains("Doygunluk") })

        let rgbStream = try displayedImage(preview, at: 0)
        let rgbDict = try XCTUnwrap(CGPDFStreamGetDictionary(rgbStream))
        var spaces: CGPDFArrayRef?, preservedProfile: CGPDFStreamRef?, filter: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFDictionaryGetArray(rgbDict, "ColorSpace", &spaces))
        XCTAssertTrue(CGPDFArrayGetStream(try XCTUnwrap(spaces), 1, &preservedProfile))
        XCTAssertEqual(try samples(XCTUnwrap(preservedProfile)), profile)
        XCTAssertTrue(CGPDFDictionaryGetName(rgbDict, "Filter", &filter))
        XCTAssertEqual(filter.map { String(cString: $0) }, "FlateDecode")
        let rgbSamples = try samples(rgbStream)
        XCTAssertEqual(rgbSamples.count, 192)
        XCTAssertEqual(rgbSamples[0], rgbSamples[1])
        XCTAssertEqual(rgbSamples[1], rgbSamples[2])
        XCTAssertLessThan(rgbSamples[0], rgbSamples[191])
        let graySamples = try samples(displayedImage(preview, at: 1))
        XCTAssertEqual(graySamples.count, 64)
        XCTAssertEqual(graySamples[0], 107, accuracy: 2)
        XCTAssertEqual(graySamples[63], 204, accuracy: 2)

        let output = url.deletingLastPathComponent().appendingPathComponent("dct-output.pdf")
        let report = try PDFExporter.export(plan: plan, source: source, destination: .singlePDF(output), marks: .none)
        XCTAssertTrue(report.notes.contains { $0.contains("JPEG") })
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: output)).string?.contains("Vector JPEG proof") == true)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let outputDoc = try XCTUnwrap(CGPDFDocument(output as CFURL))
        let printed = try XCTUnwrap(outputDoc.page(at: 1))
        let pt = PDFPreviewDrawing.pointsPerMM
        for x in [20.0, 67, 112] {
            for y in [26.0, 60] {
                let p = CGPoint(x: x, y: y)
                XCTAssertGreaterThan(try pixel(preview, p), try pixel(before, p))
                XCTAssertEqual(try pixel(preview, p), try pixel(printed, CGPoint(x: x + pt * slot.x, y: y + pt * slot.y)), accuracy: 3)
            }
        }
        XCTAssertLessThan(try pixel(preview, CGPoint(x: 67, y: 60)), try pixel(preview, CGPoint(x: 67, y: 26)))
    }

    func testDCTRejectsMismatchedDimensionsAndUnsupportedSamplePrecision() throws {
        let jpeg = try jpeg(samples: [65, 150], components: 1)
        XCTAssertNil(try PDFJPEGImageSamples.decode(jpeg, width: 7, height: 8, components: 1, pdfICC: nil))
        XCTAssertNil(try PDFJPEGImageSamples.decode(jpeg, width: 8, height: 8, components: 3, pdfICC: nil))

        var non8Bit = jpeg
        let marker = try XCTUnwrap(non8Bit.range(of: Data([0xff, 0xc0])))
        non8Bit[marker.upperBound + 2] = 12
        XCTAssertNil(try PDFJPEGImageSamples.decode(non8Bit, width: 8, height: 8, components: 1, pdfICC: nil))

        XCTAssertNil(try PDFJPEGImageSamples.decode(jpeg.prefix(10), width: 8, height: 8, components: 1, pdfICC: nil))
    }

    private func cmykFixture(profile: Data, extra: String = "", flate: Bool = false) throws -> URL {
        let colorSpaces = "/ColorSpace << /Spot [/Separation /Brand /DeviceCMYK 9 0 R] >>"
        let extStates = "/ExtGState << /Overprint << /OP true /op true /OPM 1 >> >>"
        let image = "/Type /XObject /Subtype /Image /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace"
        let ink: [UInt8] = [0, 0, 0, 0, 70, 100, 130, 50]
        var imageData = Data(ink), filter = ""
        if flate {
            var length = compressBound(uLong(ink.count))
            var compressed = [UInt8](repeating: 0, count: Int(length))
            XCTAssertEqual(compress2(&compressed, &length, ink, uLong(ink.count), Z_DEFAULT_COMPRESSION), Z_OK)
            imageData = Data(compressed.prefix(Int(length)))
            filter = " /Filter /FlateDecode"
        }
        return try writePDF([
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 140] /Resources << /Font << /F 5 0 R >> /XObject << /Press 6 0 R /Device 8 0 R >> \(colorSpaces) \(extStates) >> /Contents 4 0 R >>".utf8),
            stream("", Data("\(extra) q 80 0 0 45 10 15 cm /Press Do Q q 80 0 0 45 100 15 cm /Device Do Q BT /F 12 Tf 10 100 Td (Vector CMYK proof) Tj ET".utf8)),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            stream("\(image) [/ICCBased 7 0 R]\(filter)", imageData),
            stream("/N 4", profile),
            stream("\(image) /DeviceCMYK", Data([0, 0, 0, 0, 60, 70, 30, 100])),
            Data("<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 0.75 0.5 0] /N 1 >>".utf8)
        ])
    }

    private func iccProfile(in image: CGPDFStreamRef, resources: CGPDFDictionaryRef? = nil) throws -> Data? {
        guard let imageDict = CGPDFStreamGetDictionary(image) else { return nil }
        var array: CGPDFArrayRef?, name: UnsafePointer<CChar>?
        if !CGPDFDictionaryGetArray(imageDict, "ColorSpace", &array),
           CGPDFDictionaryGetName(imageDict, "ColorSpace", &name), let name, let resources {
            var spaces: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resources, "ColorSpace", &spaces), let spaces {
                _ = CGPDFDictionaryGetArray(spaces, String(cString: name), &array)
            }
        }
        guard let array, CGPDFArrayGetName(array, 0, &name), let name, String(cString: name) == "ICCBased" else { return nil }
        var profile: CGPDFStreamRef?
        guard CGPDFArrayGetStream(array, 1, &profile), let profile else { return nil }
        return try samples(profile)
    }

    private func exportedProfiles(_ page: CGPDFPage) throws -> [Data] {
        func scan(_ parent: CGPDFDictionaryRef?, depth: Int) throws -> [Data] {
            var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
            guard depth < 8, let parent, CGPDFDictionaryGetDictionary(parent, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return [] }
            var streams: [CGPDFStreamRef] = []
            CGPDFDictionaryApplyBlock(objects, { _, value, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(value, .stream, &stream), let stream { streams.append(stream) }
                return true
            }, nil)
            return try streams.flatMap { stream in
                if let profile = try iccProfile(in: stream, resources: resources) { return [profile] }
                return try scan(CGPDFStreamGetDictionary(stream), depth: depth + 1)
            }
        }
        return try scan(page.dictionary, depth: 0)
    }

    func testProfiledCMYKAdjustsOnlyTheTargetImageAndPreservesICCInExport() async throws {
        let profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericCMYK)?.copyICCData()) as Data
        let url = try cmykFixture(profile: profile, flate: true)
        let original = try Data(contentsOf: url)
        let source = try await PDFSource.open(url)
        var slot = Slot(sourcePageNumber: 1, origin: Point(12, 12), size: source.pages[0].trimSize)
        var adjustment = ImageColorAdjustment()
        adjustment.brightness = 0.22
        adjustment.contrast = 1.1
        adjustment.saturation = 0.4
        slot.imageColor = adjustment
        let plan = ImpositionPlan(sheets: [Sheet(size: Size(110, 85), front: Side(slots: [slot]), back: Side())])
        let colors = try PDFColorVariants.prepare(source: source, plan: plan)
        let preview = try XCTUnwrap(colors.page(for: slot), "\(colors.warnings)")
        let edited = try displayedImage(preview, at: 0)
        let ink = try samples(edited)
        XCTAssertEqual(ink.count, 8)
        XCTAssertEqual(ink.prefix(4), Data([0, 0, 0, 0]), "Clamped white should keep its original inks")
        XCTAssertNotEqual(ink.suffix(4), Data([70, 100, 130, 50]))
        XCTAssertEqual(try iccProfile(in: edited), profile)
        XCTAssertEqual(try samples(displayedImage(preview, at: 1)), Data([0, 0, 0, 0, 60, 70, 30, 100]))
        XCTAssertTrue(colors.warnings.contains { $0.contains("profili olmayan CMYK") })
        XCTAssertTrue(colors.warnings.contains { $0.contains("mürekkep oranları") })

        let output = url.deletingLastPathComponent().appendingPathComponent("cmyk-output.pdf")
        _ = try PDFExporter.export(plan: plan, source: source, destination: .singlePDF(output), marks: .none)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: output)).string?.contains("Vector CMYK proof") == true)
        let outputDoc = try XCTUnwrap(CGPDFDocument(output as CFURL))
        let printed = try XCTUnwrap(outputDoc.page(at: 1))
        XCTAssertTrue(try exportedProfiles(printed).contains(profile))
        let point = CGPoint(x: 70, y: 32), pt = PDFPreviewDrawing.pointsPerMM
        func rgb(_ page: CGPDFPage, at point: CGPoint) throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.translateBy(x: 1.5 - point.x, y: 1.5 - point.y)
            context.drawPDFPage(page)
            let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual(data[19], 255, "The sample must cover opaque artwork")
            return Array(UnsafeBufferPointer(start: data + 16, count: 3))
        }
        let originalDoc = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let before = try rgb(XCTUnwrap(originalDoc.page(at: 1)), at: point)
        let after = try rgb(preview, at: point)
        XCTAssertGreaterThan(after.reduce(0) { $0 + Int($1) }, before.reduce(0) { $0 + Int($1) })
        let emitted = try rgb(printed, at: CGPoint(x: point.x + slot.x * pt, y: point.y + slot.y * pt))
        for (expected, actual) in zip(after, emitted) { XCTAssertEqual(expected, actual, accuracy: 3) }
    }

    func testCMYKSkipsInvalidICCSpotAndOverprint() async throws {
        let profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericCMYK)?.copyICCData()) as Data
        var damaged = profile
        let size = damaged.count
        damaged.replaceSubrange(0..<4, with: [0x7f, 0xff, 0xff, 0xff])
        XCTAssertEqual(damaged.count, size)
        let cases = [
            (damaged, "", "ICC profili doğrulanamayan"),
            (profile, "/Overprint gs 0 0 0 1 K 0 70 m 195 70 l S", "üst baskı"),
            (profile, "/Spot cs 1 scn 0 0 200 140 re f", "Spot renk")
        ]
        for (data, extra, reason) in cases {
            let url = try cmykFixture(profile: data, extra: extra)
            let source = try await PDFSource.open(url)
            var slot = Slot(sourcePageNumber: 1, origin: Point(8, 8), size: source.pages[0].trimSize)
            var adjustment = ImageColorAdjustment()
            adjustment.brightness = 0.25
            slot.imageColor = adjustment
            let plan = ImpositionPlan(sheets: [Sheet(size: Size(110, 85), front: Side(slots: [slot]), back: Side())])
            let prepared = try PDFColorVariants.prepare(source: source, plan: plan)
            XCTAssertNil(prepared.page(for: slot))
            XCTAssertTrue(prepared.warnings.contains { $0.contains(reason) }, "\(prepared.warnings)")
            if !extra.isEmpty {
                let output = url.deletingLastPathComponent().appendingPathComponent("unchanged-inks.pdf")
                let report = try PDFExporter.export(plan: plan, source: source, destination: .singlePDF(output), marks: .none)
                XCTAssertTrue(report.notes.contains { $0.contains(reason) })
                let contents = String(decoding: try Data(contentsOf: output), as: UTF8.self)
                let tokens = extra.contains(" gs") ? [#"/OP\s+true"#, #"/op\s+true"#, #"/OPM\s+1"#] : [#"/Separation\s+/Brand"#]
                for token in tokens { XCTAssertNotNil(contents.range(of: token, options: .regularExpression), token) }
            }
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
