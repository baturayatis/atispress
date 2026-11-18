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
    case unreadable, locked, empty, copyRestricted, metadataMismatch, invalidBox(Int)
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Dosya bozuk veya sayfa yok."
        case .copyRestricted: return "Kopyalama kısıtlı"
        case .metadataMismatch: return "Ebat uyuşmuyor"
        case .locked: return "Şifreli PDF (parola gerekli)"
        case .empty: return "PDF dosyasında sayfa yok."
        case .invalidBox(let page): return "Sayfa \(page) için geçerli bir sayfa kutusu bulunamadı."
        }
    }
}

/// PDFKit stays on one serial queue. Main-thread vector drawing uses a separate CGPDFDocument.
/// Reading and rasterization never mutate the source file.
public final class PDFSource: @unchecked Sendable {
    var originalPDFDetails:String?
    private var encryptedOrigin:URL?
    private var encryptedOriginAccess=false
    public var originalURL:URL {encryptedOrigin ?? url}
    func retainUnlockedOrigin(_ origin:URL,folder:URL,scoped:Bool,pages:[PDFPageInfo]) {
        encryptedOrigin=origin;encryptedOriginAccess=scoped;temporaryDirectory=folder;self.pages=pages
        for i in guides.groups.indices {guides.groups[i].canHide=false}
    }
    private var usesCellMetadata=false
    private var preparedGuideURL:URL?
    public var guidePreviewURL:URL { preparedGuideURL ?? (linkedSources.count == 1 ? linkedSources[0].guidePreviewURL : preparationInput.url) }
    private var preparationParent:PDFSource?
    public var preparationInput:PDFSource { preparationParent?.preparationInput ?? (linkedSources.count == 1 ? linkedSources[0].preparationInput : self) }
    public private(set) var guides:PDFGuideAnalysis
    private var linkedSources: [PDFSource] = []
    private var compositeTitle: String?
    private var temporaryDirectory: URL?
    public var protectedURLs: [URL] { if let encryptedOrigin {return [encryptedOrigin,url]};if let preparationParent { return preparationParent.protectedURLs+[url]+(preparedGuideURL.map{[$0]} ?? []) };return linkedSources.isEmpty ? [url] : linkedSources.flatMap(\.protectedURLs)+[url] }
    public var displayName: String { compositeTitle ?? (linkedSources.isEmpty ? originalURL.lastPathComponent : "Karışık iş (\(linkedSources.count) PDF)") }
    public let bindingStripCache = PDFBindingStripCache()
    public let edgeSamples = PDFEdgeSampleCache()
    public let id = UUID()
    public let url: URL
    public private(set) var pages: [PDFPageInfo]
    public let preflight: [PDFPreflightFinding]
    private let queue = DispatchQueue(label: "com.atispress.pdf-raster", qos: .userInitiated)
    private var rasterDocument: PDFDocument?
    private let scopedAccess: Bool
    private let cache = NSCache<NSString, PDFPageRaster>()

    private init(url: URL, pages: [PDFPageInfo], scopedAccess: Bool,preflight: [PDFPreflightFinding]) {
        self.url = url; self.pages = pages; self.scopedAccess = scopedAccess; self.preflight = preflight
        if let document=CGPDFDocument(url as CFURL) {
            var analysis=PDFGuideDetector.inspect(document)
            if !PDFGuideEditor.supports(url) || !PDFGuideEditor.canVerify(document) { for i in analysis.groups.indices { analysis.groups[i].canHide=false } }
            guides=analysis
        } else {guides=PDFGuideAnalysis()}
        cache.totalCostLimit = 64 * 1024 * 1024
    }
    deinit {
        if encryptedOriginAccess {encryptedOrigin?.stopAccessingSecurityScopedResource()}
        if scopedAccess { url.stopAccessingSecurityScopedResource() }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
    /// PDFKit copies page objects without rasterizing artwork. The originals remain linked and protected.
    public static func combine(_ sources: [PDFSource],displayName: String? = nil) async throws -> PDFSource {
        guard !sources.isEmpty else { throw PDFReadError.empty }
        if sources.count==1,sources[0].usesCellMetadata {return sources[0]}
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AtisPress-gang-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        do {
            let url = folder.appendingPathComponent((displayName ?? "Karışık iş")+".pdf")
            try await Task.detached(priority: .userInitiated) {
                let merged = PDFDocument()
                for source in sources {
                    try Task.checkCancellation()
                    do {
                        let doc = try readableDocument(source.url)
                        guard let original=CGPDFDocument(source.url as CFURL) else {throw PDFReadError.unreadable}
                        for i in 0..<doc.pageCount {
                            let page=try copiedPage(doc,original:original,index:i)
                            merged.insert(page,at: merged.pageCount)
                        }
                    } catch is CancellationError {throw CancellationError()}
                    catch {throw PDFLoadFailure.classify(error,url:source.originalURL,stage:"PDFKit sayfa kopyalama")}

                }
                guard merged.write(to: url) else { throw PDFReadError.unreadable }
            }.value
            let combined = try await open(url,preparedCells:sources.allSatisfy{$0.usesCellMetadata})
            let expected=sources.flatMap(\.pages)
            guard let written=CGPDFDocument(url as CFURL) else {throw PDFReadError.unreadable}
            try validateCopiedMetadata(combined.pages,expected:expected,written:written)
            combined.pages=expected.enumerated().map {PDFPageInfo(number:$0.offset+1,trimSize:$0.element.trimSize,availableBleed:$0.element.availableBleed,hasTrimBox:$0.element.hasTrimBox)}
            combined.linkedSources = sources; combined.temporaryDirectory = folder; combined.compositeTitle = displayName
            return combined
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    public func prepared(_ settings:SourcePreparationSettings) async throws -> PDFSource {
        guard settings.split == nil || settings.separation == nil else { throw SourcePreparationError.unsupportedSource }
        let input=preparationInput
        if !settings.hasPreparedProducts && settings.hiddenGuideGroups.isEmpty { return input }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("atispress-prepared-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        do {
            var url=input.url
            var guideURL:URL?
            if !settings.hiddenGuideGroups.isEmpty {
                let hidden=folder.appendingPathComponent("hidden.pdf")
                try await Task.detached(priority:.userInitiated) {try PDFGuideEditor.hiddenCopy(source:input.url,destination:hidden,analysis:input.guides,groups:Set(settings.hiddenGuideGroups))}.value
                url=hidden;guideURL=hidden
            }
            if let split=settings.split {
                let splitURL=folder.appendingPathComponent("cells.pdf"),from=url
                try await Task.detached(priority:.userInitiated) {try PDFSourcePreparation.split(source:from,destination:splitURL,settings:split)}.value
                url=splitURL
            } else if let separation = settings.separation {
                let output = folder.appendingPathComponent("regions.pdf"), from = url
                try await Task.detached(priority: .userInitiated) {
                    try PDFSourcePreparation.separate(source: from, destination: output, settings: separation)
                }.value
                url = output
            }
            let result=try await PDFSource.open(url,preparedCells:settings.hasPreparedProducts)
            result.preparationParent=input;result.preparedGuideURL=guideURL;result.temporaryDirectory=folder;result.compositeTitle=input.displayName
            return result
        } catch {try? FileManager.default.removeItem(at:folder);throw error}
    }
    public static func open(_ url: URL,preparedCells:Bool = false) async throws -> PDFSource {
        let scopedAccess = url.startAccessingSecurityScopedResource()
        do {
            let encrypted=try await Task.detached(priority:.userInitiated) {
                try coordinatedRead(url) { readURL in
                    let kit=try readableDocument(readURL)
                    return kit.isEncrypted
                }
            }.value
            if encrypted {
                let result=try await openWithPassword(url,password:"")
                if scopedAccess {url.stopAccessingSecurityScopedResource()}
                return result
            }
            return try await Task.detached(priority: .userInitiated) {
            guard let document = CGPDFDocument(url as CFURL) else { throw PDFReadError.unreadable }
            if !document.isUnlocked && !document.unlockWithPassword("") { throw PDFReadError.locked }
            guard document.numberOfPages > 0 else { throw PDFReadError.empty }
            let pages=try pageMetadata(document,preparedCells:preparedCells)
            let result=PDFSource(url: url, pages: pages, scopedAccess: scopedAccess,preflight: PDFPreflight.inspect(document));result.usesCellMetadata=preparedCells;return result
        }.value
        } catch {
            if scopedAccess { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
    static func pageMetadata(_ document:CGPDFDocument,preparedCells:Bool = false) throws -> [PDFPageInfo] {
        guard document.numberOfPages>0 else {throw PDFReadError.empty}
        var pages: [PDFPageInfo] = []
        for number in 1...document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { throw PDFReadError.unreadable }
            let boxes = PDFPreviewDrawing.sourceBoxes(page)
            let trim = boxes.trim
            guard !trim.isNull, trim.width.isFinite, trim.height.isFinite,
                  trim.width > 0, trim.height > 0 else { throw PDFReadError.invalidBox(number) }
            let rotated = abs(page.rotationAngle % 180) == 90
            let scale = 25.4 / 72.0
            // PDF coordinates are points; inherited page rotation affects the displayed trim size.
            let size = Size((rotated ? trim.height : trim.width)*scale,
                            (rotated ? trim.width : trim.height)*scale)
            func canonical(_ v:Double) -> Double {preparedCells ? (v*10_000).rounded()/10_000:v}
            let amount = boxes.bleed.map { bleed in min(
                trim.minX-bleed.minX, bleed.maxX-trim.maxX,
                trim.minY-bleed.minY, bleed.maxY-trim.maxY)*scale }
                ?? (PDFPreviewDrawing.hasExplicitBox("BleedBox", page: page) &&
                    page.getBoxRect(.bleedBox).intersection(page.getBoxRect(.mediaBox)).isNull == false ? 0 : nil)
            pages.append(PDFPageInfo(number: number, trimSize: Size(canonical(size.width),canonical(size.height)), availableBleed: amount.map(canonical),
                                     hasTrimBox: hasBox("TrimBox", page: page)))
        }
        return pages
    }
    static func validateCopiedMetadata(_ actualPages:[PDFPageInfo],expected:[PDFPageInfo],written:CGPDFDocument) throws {
        // PDFKit serializes box coordinates with finite decimal precision.
        // Validate that serialization noise is below 0.1 µm, then retain
        // original metadata so planning never accumulates rounding drift.
        func close(_ a:Double,_ b:Double)->Bool {abs(a-b)<=0.0001}
        guard actualPages.count==expected.count else {throw PDFReadError.metadataMismatch}
        for (index,pair) in zip(actualPages,expected).enumerated() {
            let (actual,original)=pair
            guard close(actual.trimSize.width,original.trimSize.width),close(actual.trimSize.height,original.trimSize.height) else {throw PDFReadError.metadataMismatch}
            if let amount=original.availableBleed {
                // PDFKit omits a BleedBox equal to its PDF default. Check
                // the effective box geometry against the declared source
                // bleed before retaining that source's known metadata.
                guard let page=written.page(at:index+1) else {throw PDFReadError.unreadable}
                let media=page.getBoxRect(.mediaBox).standardized
                let trim=page.getBoxRect(.trimBox).standardized.intersection(media)
                let bleed=page.getBoxRect(.bleedBox).standardized.intersection(media)
                let effective=max(0,min(trim.minX-bleed.minX,bleed.maxX-trim.maxX,trim.minY-bleed.minY,bleed.maxY-trim.maxY))*25.4/72
                guard !trim.isNull,!bleed.isNull,close(effective,amount) else {throw PDFReadError.metadataMismatch}
            } else if actual.availableBleed != nil {throw PDFReadError.metadataMismatch}
        }
    }
    static func copiedPage(_ document:PDFDocument,original:CGPDFDocument,index:Int) throws -> PDFPage {
        guard let page=document.page(at:index)?.copy() as? PDFPage else {throw PDFReadError.copyRestricted}
        guard let originalPage=original.page(at:index+1) else {throw PDFReadError.unreadable}
        // PDFPage.copy() can omit explicit BleedBox/ArtBox. Restore declared
        // boxes before serialization, keeping missing boxes missing.
        page.setBounds(originalPage.getBoxRect(.mediaBox),for:.mediaBox)
        for (key,box,kitBox) in [("CropBox",CGPDFBox.cropBox,PDFDisplayBox.cropBox),("TrimBox",.trimBox,.trimBox),("BleedBox",.bleedBox,.bleedBox),("ArtBox",.artBox,.artBox)] where hasBox(key,page:originalPage) {
            page.setBounds(originalPage.getBoxRect(box),for:kitBox)
        }
        page.rotation=Int(originalPage.rotationAngle)
        return page
    }
    private static func hasBox(_ key: String, page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return false }
        var array: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dictionary, key, &array)
    }
    public func prepareGeneratedBleed(pages numbers: [Int],scaled:[(Int,ArtworkRescale)] = []) async throws {
        let request = RasterRequest()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                queue.async { [self] in
                    do {
                        if rasterDocument == nil { rasterDocument = try? Self.readableDocument(url) }
                        for number in Set(numbers) where edgeSamples.cached(page: number) == nil {
                            guard !request.isCancelled else { throw CancellationError() }
                            guard let page = rasterDocument?.page(at: number-1)?.pageRef else { throw PDFExportError.missingPage(number) }
                            _ = try edgeSamples.samples(for: page)
                        }
                        for (number,scale) in scaled where edgeSamples.cached(page:number,rescale:scale)==nil {
                            guard !request.isCancelled else {throw CancellationError()}
                            guard let page=rasterDocument?.page(at:number-1)?.pageRef else {throw PDFExportError.missingPage(number)}
                            _ = try edgeSamples.samples(for:page,rescale:scale)
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { request.cancel() }
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
                    if rasterDocument == nil { rasterDocument = try? Self.readableDocument(url) }
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
