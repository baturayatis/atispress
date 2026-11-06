import AppKit
import PDFKit
import ImpositionCore

public struct PDFPageInfo: Sendable, Identifiable {
    public let number: Int
    public let trimSize: Size
    public let availableBleed: Double?
    public let hasTrimBox: Bool
    public var id: Int { number }
    public var sourcePage: SourcePage {
        SourcePage(number: number, trimSize: trimSize, availableBleed: availableBleed)
    }
}

public enum PDFReadError: LocalizedError {
    case unreadable, locked, empty, invalidBox(Int)
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "PDF dosyası okunamadı."
        case .locked: return "Şifreli PDF açılamadı. Önce şifreyi kaldırın."
        case .empty: return "PDF dosyasında sayfa yok."
        case .invalidBox(let page): return "Sayfa \(page) için geçerli bir sayfa kutusu bulunamadı."
        }
    }
}

/// PDFKit stays on one serial queue. Main-thread vector drawing uses a separate CGPDFDocument.
/// Reading and rasterization never mutate the source file.
public final class PDFSource: @unchecked Sendable {
    public let id = UUID()
    public let url: URL
    public let pages: [PDFPageInfo]
    private let queue = DispatchQueue(label: "com.atispress.pdf-raster", qos: .userInitiated)
    private var rasterDocument: PDFDocument?
    private let scopedAccess: Bool
    private let cache = NSCache<NSString, PDFPageRaster>()

    private init(url: URL, pages: [PDFPageInfo], scopedAccess: Bool) {
        self.url = url; self.pages = pages; self.scopedAccess = scopedAccess
        cache.totalCostLimit = 64 * 1024 * 1024
    }
    deinit { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
    public static func open(_ url: URL) async throws -> PDFSource {
        let scopedAccess = url.startAccessingSecurityScopedResource()
        do { return try await Task.detached(priority: .userInitiated) {
            guard let document = CGPDFDocument(url as CFURL) else { throw PDFReadError.unreadable }
            if !document.isUnlocked && !document.unlockWithPassword("") { throw PDFReadError.locked }
            guard document.numberOfPages > 0 else { throw PDFReadError.empty }
            var pages: [PDFPageInfo] = []
            for number in 1...document.numberOfPages {
                try Task.checkCancellation()
                guard let page = document.page(at: number) else { throw PDFReadError.unreadable }
                let media = page.getBoxRect(.mediaBox).standardized
                let trim = page.getBoxRect(.trimBox).standardized.intersection(media)
                guard !trim.isNull, trim.width.isFinite, trim.height.isFinite,
                      trim.width > 0, trim.height > 0 else { throw PDFReadError.invalidBox(number) }
                let rotated = abs(page.rotationAngle % 180) == 90
                let scale = 25.4 / 72.0
                // PDF coordinates are points; inherited page rotation affects the displayed trim size.
                let size = Size((rotated ? trim.height : trim.width)*scale,
                                (rotated ? trim.width : trim.height)*scale)
                let explicitBleed = hasBox("BleedBox", page: page)
                let bleed = page.getBoxRect(.bleedBox).standardized.intersection(media)
                let amount: Double? = explicitBleed && !bleed.isNull ? max(0,min(
                    trim.minX-bleed.minX, bleed.maxX-trim.maxX,
                    trim.minY-bleed.minY, bleed.maxY-trim.maxY))*scale : nil
                pages.append(PDFPageInfo(number: number, trimSize: size, availableBleed: amount,
                                         hasTrimBox: hasBox("TrimBox", page: page)))
            }
            return PDFSource(url: url, pages: pages, scopedAccess: scopedAccess)
        }.value
        } catch {
            if scopedAccess { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
    private static func hasBox(_ key: String, page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return false }
        var array: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dictionary, key, &array)
    }
    public func cachedImage(page: Int, pixels: Int) -> NSImage? {
        cachedRaster(page: page,pixels: pixels)?.image
    }
    public func cachedRaster(page: Int,pixels: Int) -> PDFPageRaster? {
        cache.object(forKey: "\(page)-\(pixels)" as NSString)
    }
    /// Requested only by visible rows/slots. A bounded cache avoids rasterizing 1000 pages eagerly.
    public func image(page: Int, pixels: Int) async -> NSImage? {
        guard !Task.isCancelled, page > 0, page <= pages.count, (1...2048).contains(pixels) else { return nil }
        if let hit = cachedRaster(page: page, pixels: pixels) { return hit.image }
        let request = RasterRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !request.isCancelled else { continuation.resume(returning: nil); return }
                    if let hit = cachedRaster(page: page, pixels: pixels) {
                        continuation.resume(returning: hit.image); return
                    }
                    if rasterDocument == nil { rasterDocument = PDFDocument(url: url) }
                    let raster: PDFPageRaster? = autoreleasepool {
                        guard let pdfPage = rasterDocument?.page(at: page-1), let ref = pdfPage.pageRef else { return nil }
                        let size = pages[page-1].trimSize
                        let trim = CGRect(x: 0,y: 0,width: size.width,height: size.height)
                        let artwork = PDFPreviewDrawing.artworkGeometry(ref,trimRect: trim).artworkBounds
                        let scale = Double(pixels)/max(artwork.width,artwork.height)
                        guard scale.isFinite, scale > 0 else { return nil }
                        let width = max(1,Int(ceil(artwork.width*scale))), height = max(1,Int(ceil(artwork.height*scale)))
                        guard let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                        context.scaleBy(x: scale,y: scale); context.translateBy(x: -artwork.minX,y: -artwork.minY)
                        PDFPreviewDrawing.draw(ref,in: context,rect: trim)
                        guard let image = context.makeImage() else { return nil }
                        return PDFPageRaster(cgImage: image,bounds: CGRect(x: artwork.minX/trim.width,y: artwork.minY/trim.height,
                            width: artwork.width/trim.width,height: artwork.height/trim.height))
                    }
                    if let raster {
                        cache.setObject(raster,forKey: "\(page)-\(pixels)" as NSString,
                                        cost: raster.cgImage.bytesPerRow*raster.cgImage.height)
                    }
                    continuation.resume(returning: raster?.image)
                }
            }
        } onCancel: { request.cancel() }
    }
}

private final class RasterRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
