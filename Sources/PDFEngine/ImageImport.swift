import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImagePrintSettings: Codable, Equatable, Sendable {
    public var widthMM: Double
    public var heightMM: Double
    public var lockAspectRatio: Bool

    public init(widthMM: Double, heightMM: Double, lockAspectRatio: Bool = true) {
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.lockAspectRatio = lockAspectRatio
    }

    public var isValid: Bool {
        [widthMM, heightMM].allSatisfy { $0 > 0 && ($0 * PDFPreviewDrawing.pointsPerMM).isFinite }
    }
}

public enum ImageImportError: LocalizedError {
    case unreadable, invalidSize, unsupportedColor, cmyk, writeFailed
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Görsel okunamadı. Dosya bozuk olabilir veya biçim bu macOS sürümünde desteklenmiyor."
        case .invalidSize: return "Görselin baskı ölçüsü geçersiz."
        case .unsupportedColor: return "Görselin renk uzayı baskı için desteklenmiyor."
        case .cmyk: return "Görselin CMYK renk uzayı PDF’de korunamadı."
        case .writeFailed: return "Görsel için çalışma PDF’si oluşturulamadı."
        }
    }
}

public struct ImageImportInfo: Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let dpiX: Double
    public let dpiY: Double
    public let warnings: [String]
    fileprivate let orientation: Int
    fileprivate let colorModel: String?
    fileprivate let profileName: String?
    fileprivate let depth: Int
    fileprivate let hasAlpha: Bool
    fileprivate let index: Int

    public var defaultSettings: ImagePrintSettings {
        ImagePrintSettings(widthMM: Double(pixelWidth) * 25.4 / dpiX,
                           heightMM: Double(pixelHeight) * 25.4 / dpiY, lockAspectRatio: true)
    }

    public func effectiveDPI(_ settings: ImagePrintSettings) -> Double {
        min(Double(pixelWidth) * 25.4 / settings.widthMM, Double(pixelHeight) * 25.4 / settings.heightMM)
    }
}

public enum ImageImport {
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "webp"]

    public static let contentTypes: [UTType] = [.jpeg, .png, .tiff, .heic, .webP]
    private static let types = Set(contentTypes.map(\.identifier))

    public static func accepts(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }

    public static func inspect(_ url: URL) async throws -> ImageImportInfo {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try await Task.detached(priority: .userInitiated) {
            try PDFSource.coordinatedRead(url) { try info(source($0)) }
        }.value
    }

    static func write(_ url: URL, to output: URL, settings: ImagePrintSettings) throws -> [String] {
        guard settings.isValid else { throw ImageImportError.invalidSize }
        return try PDFSource.coordinatedRead(url) { readURL in
            let source = try source(readURL)
            let info = try info(source)
            guard let image = CGImageSourceCreateImageAtIndex(source, info.index, nil) else {
                throw ImageImportError.unreadable
            }
            let model = image.colorSpace?.model
            if info.colorModel == (kCGImagePropertyColorModelCMYK as String), model != .cmyk {
                throw ImageImportError.cmyk
            }
            guard model == .rgb || model == .monochrome || model == .cmyk || model == .indexed else {
                throw ImageImportError.unsupportedColor
            }
            var box = CGRect(x: 0, y: 0, width: settings.widthMM * PDFPreviewDrawing.pointsPerMM,
                             height: settings.heightMM * PDFPreviewDrawing.pointsPerMM)
            guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else {
                throw ImageImportError.writeFailed
            }
            context.beginPDFPage(nil)
            context.scaleBy(x: box.width, y: box.height)
            context.concatenate(transform(info.orientation))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            context.endPDFPage()
            context.closePDF()

            let encoded = try embeddedImage(output, width: image.width, height: image.height)
            if model == .cmyk, encoded.components != 4 { throw ImageImportError.cmyk }
            var warnings = info.warnings
            if info.colorModel == (kCGImagePropertyColorModelLab as String), model != .lab {
                warnings.append("Lab renk uzayı ImageIO tarafından dönüştürüldü. Baskı renklerini kontrol edin.")
            }
            if encoded.depth < info.depth {
                warnings.append("Görselin renk derinliği PDF’de azaltıldı.")
            }
            if info.hasAlpha && !encoded.hasMask {
                warnings.append("Görselin saydamlık kanalı PDF’de korunamadı.")
            }
            if let profile = image.colorSpace?.copyICCData() as Data?, encoded.profile != profile {
                warnings.append("Renk profili PDF’ye birebir aktarılamadı. Baskı renklerini kontrol edin.")
            } else if info.profileName != nil, encoded.profile == nil {
                warnings.append("Gömülü renk profili PDF’ye aktarılamadı.")
            }
            if model == .cmyk, encoded.profile == nil {
                warnings.append("CMYK bileşenleri korundu. Gömülü profil yoksa baskı renkleri çıktı aygıtına bağlıdır.")
            }
            return warnings
        }
    }

    private static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source), types.contains(type as String) else {
            throw ImageImportError.unreadable
        }
        return source
    }

    private static func info(_ source: CGImageSource) throws -> ImageImportInfo {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int, height > 0 else {
            throw ImageImportError.unreadable
        }
        func dpi(_ key: CFString) -> Double? {
            guard let value = properties[key as String] as? Double, value.isFinite, value > 0 else { return nil }
            return value
        }
        let x = dpi(kCGImagePropertyDPIWidth)
        let y = dpi(kCGImagePropertyDPIHeight)
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        let swap = (5...8).contains(orientation)
        let warnings = CGImageSourceGetCount(source) > 1 ? ["Görselin yalnızca birincil karesi kullanılır."] : []
        return ImageImportInfo(pixelWidth: swap ? height : width, pixelHeight: swap ? width : height,
                               dpiX: (swap ? y ?? x : x ?? y) ?? 300, dpiY: (swap ? x ?? y : y ?? x) ?? 300,
                               warnings: warnings, orientation: orientation,
                               colorModel: properties[kCGImagePropertyColorModel as String] as? String,
                               profileName: properties[kCGImagePropertyProfileName as String] as? String,
                               depth: properties[kCGImagePropertyDepth as String] as? Int ?? 0,
                               hasAlpha: properties[kCGImagePropertyHasAlpha as String] as? Bool ?? false, index: index)
    }

    // EXIF orientations in bottom-left PDF coordinates. The image pixels are never rotated or resized.
    private static func transform(_ orientation: Int) -> CGAffineTransform {
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1, ty: 1)
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        default: return .identity
        }
    }

    private struct EmbeddedImage {
        var components = 0
        var profile: Data?
        var depth = 0
        var hasMask = false
    }

    private static func embeddedImage(_ url: URL, width: Int, height: Int) throws -> EmbeddedImage {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1), let dictionary = page.dictionary else {
            throw ImageImportError.writeFailed
        }
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else {
            throw ImageImportError.writeFailed
        }
        var image: CGPDFDictionaryRef?
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream) else { return true }
            guard let stream, let candidate = CGPDFStreamGetDictionary(stream) else { return true }
            var w = 0, h = 0
            if CGPDFDictionaryGetInteger(candidate, "Width", &w), CGPDFDictionaryGetInteger(candidate, "Height", &h),
               w == width, h == height {
                image = candidate
                return false
            }
            return true
        }, nil)
        guard let image else { throw ImageImportError.writeFailed }
        var name: UnsafePointer<CChar>?
        var result = EmbeddedImage()
        var softMask: CGPDFStreamRef?, mask: CGPDFObjectRef?
        result.hasMask = CGPDFDictionaryGetStream(image, "SMask", &softMask) ||
            CGPDFDictionaryGetObject(image, "Mask", &mask)
        CGPDFDictionaryGetInteger(image, "BitsPerComponent", &result.depth)
        if CGPDFDictionaryGetName(image, "ColorSpace", &name), let name, String(cString: name) == "DeviceCMYK" {
            result.components = 4
            return result
        }
        var space: CGPDFArrayRef?, profile: CGPDFStreamRef?
        if !CGPDFDictionaryGetArray(image, "ColorSpace", &space),
           CGPDFDictionaryGetName(image, "ColorSpace", &name), let name {
            var spaces: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resources, "ColorSpace", &spaces), let spaces {
                CGPDFDictionaryGetArray(spaces, name, &space)
            }
        }
        if let space, CGPDFArrayGetName(space, 0, &name), let name, String(cString: name) == "ICCBased",
           CGPDFArrayGetStream(space, 1, &profile), let profile, let dictionary = CGPDFStreamGetDictionary(profile) {
            CGPDFDictionaryGetInteger(dictionary, "N", &result.components)
            var format = CGPDFDataFormat.raw
            result.profile = CGPDFStreamCopyData(profile, &format) as Data?
        }
        return result
    }
}
