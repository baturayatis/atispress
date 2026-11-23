import CoreGraphics
import ImageIO
import ImpositionCore
import UniformTypeIdentifiers
import XCTest
@testable import PDFEngine

final class ImageImportTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(_ type: UTType, in folder: URL, cmyk: Bool = false, alpha: Bool = false,
                         metadata: [CFString: Any] = [:]) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: cmyk ? CGColorSpace.genericCMYK : CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: cmyk ? CGImageAlphaInfo.none.rawValue :
                (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        let color: [CGFloat] = cmyk ? [0.8, 0.1, 0.1, 0.2, 1] : [1, 0, 0, 1]
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: color)))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: cmyk ? [0, 0, 0, 1, 1] : [0, 0, 1, 1])))
        context.fill(CGRect(x: 60, y: 0, width: 60, height: 60))
        if alpha { context.clear(CGRect(x: 0, y: 30, width: 120, height: 30)) }
        let url = folder.appendingPathComponent("source").appendingPathExtension(try XCTUnwrap(type.preferredFilenameExtension))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), metadata as CFDictionary)
        let finalized = CGImageDestinationFinalize(dest)
        if type == .heic, !finalized { throw XCTSkip("HEIC encoding is unavailable on this host") }
        XCTAssertTrue(finalized)
        return url
    }

    private func bitmap(_ width: Int, _ height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func render(_ page: CGPDFPage, into context: CGContext) {
        let bounds = page.getBoxRect(.mediaBox)
        context.scaleBy(x: CGFloat(context.width) / bounds.width, y: CGFloat(context.height) / bounds.height)
        context.drawPDFPage(page)
    }

    private func sample(_ context: CGContext, _ x: Int, _ y: Int) -> [UInt8] {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (context.height - 1 - y) * context.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }

    func testJPEGWithEXIFOrientationAndDPI() async throws {
        let untagged = try await ImageImport.inspect(fixture(.jpeg, in: folder()))
        XCTAssertEqual(untagged.dpiX, 300)
        let dir = try folder()
        let url = try fixture(.jpeg, in: dir, metadata: [
            kCGImagePropertyOrientation: 6, kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 240
        ])
        let info = try await ImageImport.inspect(url)
        XCTAssertEqual(info.pixelWidth, 60)
        XCTAssertEqual(info.pixelHeight, 120)
        XCTAssertEqual(info.dpiX, 240)
        XCTAssertEqual(info.dpiY, 300)
        XCTAssertEqual(info.effectiveDPI(info.defaultSettings), 240, accuracy: 0.01)
        let (source, warnings) = try await PDFSource.openImage(url, settings: info.defaultSettings)
        XCTAssertTrue(warnings.isEmpty, warnings.joined(separator: ", "))
        XCTAssertEqual(source.originalURL, url)
        XCTAssertTrue(source.protectedURLs.contains(url))
        XCTAssertEqual(source.pages[0].trimSize.width, 6.35, accuracy: 0.0001)
        XCTAssertEqual(source.pages[0].trimSize.height, 10.16, accuracy: 0.0001)
        let doc = try XCTUnwrap(CGPDFDocument(source.url as CFURL))
        let result = try bitmap(60, 120)
        try render(XCTUnwrap(doc.page(at: 1)), into: result)
        let jpegBytes = try Data(contentsOf: url)
        XCTAssertNotNil(try Data(contentsOf: source.url).range(of: jpegBytes))
        XCTAssertGreaterThan(sample(result, 30, 100)[0], 200)
        XCTAssertGreaterThan(sample(result, 30, 20)[2], 200)
        let plan = ImpositionPlanner.plan(Project(pages: source.pages.map(\.sourcePage), binding: .stepAndRepeat,
            sheet: SheetSpec(size: Size(68, 47)), settings: ImpositionSettings(bleed: 0, safeAreaInset: 0),
            stepAndRepeat: StepAndRepeatSettings(columns: 1, rows: 1, quantity: 1)))
        let output = dir.appendingPathComponent("imposed.pdf")
        _ = try PDFExporter.export(plan: plan, source: source, destination: .singlePDF(output), marks: .none)
        XCTAssertNotNil(try Data(contentsOf: output).range(of: jpegBytes))
    }

    func testPNGTransparencyAndCMYKProfileThroughDuplexExport() async throws {
        let dir = try folder()
        let png = try fixture(.png, in: dir, alpha: true)
        let tiff = try fixture(.tiff, in: dir, cmyk: true)
        let info = try await ImageImport.inspect(png)
        XCTAssertEqual(info.dpiX, 300)
        XCTAssertEqual(info.dpiY, 300)
        let size = ImagePrintSettings(widthMM: 24, heightMM: 12)
        XCTAssertLessThan(info.effectiveDPI(size), 150)
        let (front, pngWarnings) = try await PDFSource.openImage(png, settings: size)
        let (back, cmykWarnings) = try await PDFSource.openImage(tiff, settings: size)
        XCTAssertTrue(pngWarnings.isEmpty, pngWarnings.joined(separator: ", "))
        XCTAssertTrue(cmykWarnings.isEmpty, cmykWarnings.joined(separator: ", "))
        let merged = try await PDFSource.combine([front, back])
        XCTAssertEqual(merged.pages.count, 2)
        let bleed = GeneratedBleedSettings(enabled: true, method: .solidColor, color: .cmyk(0, 0, 0, 0))
        let plan = ImpositionPlanner.plan(Project(pages: merged.pages.map(\.sourcePage), binding: .stepAndRepeat,
            sheet: SheetSpec(size: Size(30, 42), margins: Insets(left: 3, right: 3, top: 3, bottom: 3), orientation: .portrait),
            settings: ImpositionSettings(bleed: 1, cropMarkLength: 1, cropMarkOffset: 1, generatedBleed: bleed),
            stepAndRepeat: StepAndRepeatSettings(columns: 1, rows: 1, quantity: 2)))
        XCTAssertTrue(plan.canExport, "\(plan.issues)")
        let output = dir.appendingPathComponent("output.pdf")
        var marks = ExportMarks.none
        marks.crop = true
        let exported = try PDFExporter.export(plan: plan, source: merged, destination: .singlePDF(output), marks: marks)
        XCTAssertEqual(exported.pageCount, 4)
        let input = try XCTUnwrap(CGPDFDocument(merged.url as CFURL))
        let document = try XCTUnwrap(CGPDFDocument(output as CFURL))
        let findings = PDFPreflight.inspect(document)
        XCTAssertTrue(findings.contains { $0.page == 1 && $0.code == "transparency" })
        XCTAssertFalse(findings.contains { $0.page == 2 && $0.code == "rgb" })
        XCTAssertTrue(findings.contains { $0.page == 2 && $0.explanation.contains("ICC profil") })
        let sheet = try XCTUnwrap(plan.sheets.first)
        XCTAssertEqual(sheet.size, Size(30, 42))
        XCTAssertTrue(sheet.front.marks.contains { $0.kind == .crop })
        for (index, kind) in [SideKind.front, .back].enumerated() {
            let actual = try bitmap(340, 235), expected = try bitmap(340, 235)
            try render(XCTUnwrap(document.page(at: index + 1)), into: actual)
            expected.scaleBy(x: CGFloat(expected.width) / sheet.size.width, y: CGFloat(expected.height) / sheet.size.height)
            let side = kind == .front ? sheet.front : sheet.back
            try PDFPlanRenderer.drawSide(side, sheet: sheet, document: input, in: expected,
                sheetIndex: 0, kind: kind, repetition: 0, options: .artworkOnly,
                overlays: [GeneratedBleedOverlay(settings: bleed, cache: merged.edgeSamples)])
            let slot = try XCTUnwrap(side.slots.first)
            XCTAssertEqual(slot.rotation, kind == .front ? 90 : 270)
            XCTAssertNotNil(slot.artworkClip)
            let x = Int((slot.x + slot.size.width / 2) * Double(actual.width) / sheet.size.width)
            let y = Int((slot.y + slot.size.height / 2) * Double(actual.height) / sheet.size.height)
            for offset in [-12, 12] {
                let a = sample(actual, x - 15, y + offset), b = sample(expected, x - 15, y + offset)
                XCTAssertEqual(a, b, "\(kind) \(sheet.size), \(x), \(y)")
            }
        }
    }

    func testHEICWhenAvailable() async throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(UTType.heic.identifier) == true else {
            throw XCTSkip("HEIC encoder unavailable")
        }
        let url = try fixture(.heic, in: folder())
        let info = try await ImageImport.inspect(url)
        let (source, _) = try await PDFSource.openImage(url, settings: info.defaultSettings)
        XCTAssertEqual(info.pixelWidth, 120)
        XCTAssertEqual(source.pages.count, 1)
    }

    func testWebPWhenAvailable() async throws {
        guard (CGImageSourceCopyTypeIdentifiers() as? [String])?.contains(UTType.webP.identifier) == true else {
            throw XCTSkip("WebP decoder unavailable")
        }
        let url = try folder().appendingPathComponent("source.webp")
        let webP = try XCTUnwrap(Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAAAfQ//73v/+BiOh/AAA="))
        try webP.write(to: url)
        let info = try await ImageImport.inspect(url)
        let (source, _) = try await PDFSource.openImage(url, settings: info.defaultSettings)
        XCTAssertEqual(info.pixelWidth, 1)
        XCTAssertEqual(source.pages.count, 1)
    }
}
