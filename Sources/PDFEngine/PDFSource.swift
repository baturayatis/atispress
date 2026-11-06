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
/// No PDF export APIs exist in this module.
public final class PDFSource: @unchecked Sendable {
    public let id = UUID()
    public let url: URL
    public let pages: [PDFPageInfo]
    private let queue = DispatchQueue(label: "com.atispress.pdf-raster", qos: .userInitiated)
    private var rasterDocument: PDFDocument?
    private let scopedAccess: Bool
    private let cache = NSCache<NSString, NSImage>()

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
        cache.object(forKey: "\(page)-\(pixels)" as NSString)
    }
    /// Requested only by visible rows/slots. A bounded cache avoids rasterizing 1000 pages eagerly.
    public func image(page: Int, pixels: Int) async -> NSImage? {
        guard !Task.isCancelled, page > 0, page <= pages.count, (1...2048).contains(pixels) else { return nil }
        if let hit = cachedImage(page: page, pixels: pixels) { return hit }
        let request = RasterRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !request.isCancelled else { continuation.resume(returning: nil); return }
                    if let hit = cachedImage(page: page, pixels: pixels) {
                        continuation.resume(returning: hit); return
                    }
                    if rasterDocument == nil { rasterDocument = PDFDocument(url: url) }
                    let image: NSImage? = autoreleasepool {
                        guard let pdfPage = rasterDocument?.page(at: page-1) else { return nil }
                        // Match CGPDFPage vector drawing: annotations are outside the page content stream.
                        for annotation in pdfPage.annotations { pdfPage.removeAnnotation(annotation) }
                        return pdfPage.thumbnail(of: NSSize(width: pixels,height: pixels), for: .trimBox)
                    }
                    if let image {
                        cache.setObject(image, forKey: "\(page)-\(pixels)" as NSString, cost: pixels*pixels*4)
                    }
                    continuation.resume(returning: image)
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

/// This transforms one plan slot only; it never calculates imposition or placement.
public enum PDFPreviewDrawing {
    public static func slotTransform(_ slot: Slot) -> CGAffineTransform {
        let quarterTurn = slot.rotation % 180 != 0
        let w = quarterTurn ? slot.size.height : slot.size.width
        let h = quarterTurn ? slot.size.width : slot.size.height
        let angle = -Double(slot.rotation) * .pi / 180
        var transform = CGAffineTransform(rotationAngle: angle)
        if slot.mirrored { transform = transform.scaledBy(x: -1,y: 1) }
        let footprint = CGRect(x: 0,y: 0,width: w,height: h).applying(transform)
        transform.tx += slot.x-footprint.minX; transform.ty += slot.y-footprint.minY
        return transform
    }
    public static func draw(_ page: CGPDFPage, in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        context.concatenate(page.getDrawingTransform(.trimBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.restoreGState()
    }
}
