import CoreGraphics
import ImpositionCore

public struct GeneratedBleedOverlay: PDFSlotOverlay {
    public let settings: GeneratedBleedSettings
    public let cache: PDFEdgeSampleCache
    /// Preview warms the cache off-main; export may sample its own independent CGPDFPage.
    public let sampleIfMissing: Bool
    public init(settings: GeneratedBleedSettings,cache: PDFEdgeSampleCache,sampleIfMissing: Bool = false) {
        self.settings = settings; self.cache = cache; self.sampleIfMissing = sampleIfMissing
    }
    public func draw(in context: CGContext,placement p: PDFSlotContext) throws {
        guard settings.enabled,p.slot.sourcePageNumber != nil,let page = p.sourcePage else { return }
        let trim = p.trimRect, art = p.artworkRect
        guard art.width > trim.width+0.000001 || art.height > trim.height+0.000001 else { return }
        context.saveGState(); defer { context.restoreGState() }
        // Replacement is confined outside trim, within the plan's per-item or block-perimeter clip.
        context.addRect(art); context.addRect(trim); context.clip(using: .evenOdd)
        if settings.method == .solidColor {
            context.setFillColor(Self.cgColor(settings.color)); context.fill(art); return
        }
        let samples: PDFPageEdgeSamples
        if let hit = cache.cached(page: page.pageNumber) { samples = hit }
        else if sampleIfMissing { samples = try cache.samples(for: page) }
        else { return }
        if settings.method == .mirror {
            try mirror(page,trim: trim,art: art,in: context)
        } else {
            let sides: [(SampleEdge,CGRect)] = [
                (.left,CGRect(x: art.minX,y: 0,width: max(0,-art.minX),height: trim.height)),
                (.right,CGRect(x: trim.maxX,y: 0,width: max(0,art.maxX-trim.maxX),height: trim.height)),
                (.bottom,CGRect(x: 0,y: art.minY,width: trim.width,height: max(0,-art.minY))),
                (.top,CGRect(x: 0,y: trim.maxY,width: trim.width,height: max(0,art.maxY-trim.maxY)))
            ]
            for (edge,rect) in sides where rect.width > 0 && rect.height > 0 {
                let strip = samples.strips[edge]!
                if let color = strip.uniformColor(tolerance: settings.tolerance) {
                    context.setFillColor(Self.cgColor(color)); context.fill(rect)
                } else {
                    // A single pixel column/row follows every edge position; never average a varied edge.
                    context.interpolationQuality = .none
                    context.draw(strip.edgePixels,in: rect)
                }
            }
        }
        for left in [true,false] {
            for top in [true,false] {
                let x = left ? art.minX : trim.maxX, y = top ? trim.maxY : art.minY
                let width = left ? -art.minX : art.maxX-trim.maxX
                let height = top ? art.maxY-trim.maxY : -art.minY
                if width > 0 && height > 0 {
                    context.setFillColor(Self.cgColor(samples.corner(left: left,top: top)))
                    context.fill(CGRect(x: x,y: y,width: width,height: height))
                }
            }
        }
    }
    private func mirror(_ page: CGPDFPage,trim: CGRect,art: CGRect,in context: CGContext) throws {
        let xs = Int(floor(art.minX/trim.width))..<Int(ceil(art.maxX/trim.width))
        let ys = Int(floor(art.minY/trim.height))..<Int(ceil(art.maxY/trim.height))
        guard xs.count <= 1024,ys.count <= 1024,xs.count*ys.count <= 4096 else { throw PDFExportError.invalidGeometry }
        for y in ys {
            for x in xs where x != 0 || y != 0 {
                context.saveGState()
                defer { context.restoreGState() }
                let tile = CGRect(x: Double(x)*trim.width,y: Double(y)*trim.height,width: trim.width,height: trim.height)
                context.clip(to: tile)
                let flipX = abs(x%2) == 1, flipY = abs(y%2) == 1
                context.translateBy(x: Double(x+(flipX ? 1 : 0))*trim.width,y: Double(y+(flipY ? 1 : 0))*trim.height)
                context.scaleBy(x: flipX ? -1 : 1,y: flipY ? -1 : 1)
                context.clip(to: trim)
                context.concatenate(page.getDrawingTransform(.trimBox,rect: trim,rotate: 0,preserveAspectRatio: true))
                context.drawPDFPage(page)
            }
        }
    }
    public static func cgColor(_ color: BleedColor) -> CGColor {
        let space: CGColorSpace
        switch color { case .cmyk: space = CGColorSpaceCreateDeviceCMYK(); case .rgb: space = CGColorSpace(name: CGColorSpace.sRGB)! }
        return CGColor(colorSpace: space,components: color.components.map { CGFloat($0) }+[1])!
    }
}
