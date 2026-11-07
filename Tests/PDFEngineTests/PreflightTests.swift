import XCTest
import PDFEngine
import CoreGraphics

final class PreflightTests: XCTestCase {
    private func fixture(form: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let content = "q 72 0 0 72 10 10 cm \(form ? "/Fm1" : "/Im1") Do Q BT /F1 12 Tf 10 120 Td (Hello) Tj ET 1 1 1 1 k 10 10 10 10 re f /Spot cs 0.5 scn /GS1 gs 1 1 10 10 re f"
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Im1 5 0 R \(form ? "/Fm1 9 0 R" : "") >> /Font << /F1 6 0 R >> /ColorSpace << /Spot [/Separation /TestSpot /DeviceCMYK 7 0 R] >> /ExtGState << /GS1 8 0 R >> >> /Contents 4 0 R >>".utf8),
            Data("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream".utf8),
            Data("<< /Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 192 >>\nstream\n".utf8)+Data(repeating: 128,count: 192)+Data("\nendstream".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            Data("<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 1 0 0] /N 1 >>".utf8),
            Data("<< /Type /ExtGState /ca 0.5 /BM /Multiply >>".utf8)
        ]
        if form {
            let nested = "/Im1 Do"
            // No local Resources: scanner must inherit the page XObject dictionary.
            objects.append(Data("<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Matrix [2 0 0 2 0 0] /Length \(nested.utf8.count) >>\nstream\n\(nested)\nendstream".utf8))
        }
        var data = Data("%PDF-1.4\n".utf8),offsets = [Int]()
        for (index,object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index+1) 0 obj\n".utf8)); data.append(object); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n",offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: url)
        return url
    }
    func testRGBImageLowEffectiveDPIUnembeddedFontSpotTransparencyAndRichBlack() async throws {
        let source = try await PDFSource.open(fixture())
        let findings = source.preflight
        for code in ["rgb","dpi","font","spot","transparency","ink"] {
            XCTAssertTrue(findings.contains { $0.code == code && $0.page == 1 && $0.severity == .warning },"Missing \(code): \(findings)")
        }
        XCTAssertTrue(findings.contains { $0.code == "dpi" && $0.explanation.contains("8 dpi") })
        XCTAssertTrue(findings.contains { $0.code == "font" && $0.explanation.contains("Helvetica") })
        XCTAssertTrue(findings.contains { $0.severity == .unknown && $0.explanation.contains("kontrol edilemedi") })
        XCTAssertEqual(findings.filter { $0.code == "rgb" }.count,1)
    }
    func testNestedFormInheritsResourcesAndUsesCombinedPlacedScaleForDPI() async throws {
        let source = try await PDFSource.open(fixture(form: true))
        XCTAssertTrue(source.preflight.contains { $0.code == "rgb" })
        XCTAssertTrue(source.preflight.contains { $0.code == "dpi" && $0.explanation.contains("4 dpi") })
    }

}
