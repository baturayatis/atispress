import Foundation
import CoreGraphics
import ImpositionCore

public struct GeneratedBleedOverlay: PDFSlotOverlay {
    public var jobSettings: [UUID:GeneratedBleedSettings] = [:]
    public let settings: GeneratedBleedSettings
    public let cache: PDFEdgeSampleCache
    public init(settings: GeneratedBleedSettings,cache: PDFEdgeSampleCache,jobSettings: [UUID:GeneratedBleedSettings] = [:]) {
        self.settings = settings; self.cache = cache; self.jobSettings = jobSettings
    }

    public var phase: PDFOverlayPhase { .underArtwork }

    public func mirrorsArtwork(in slot: Slot) -> Bool {
        let settings = slot.gangJobID.flatMap { jobSettings[$0] } ?? self.settings
        return settings.enabled && settings.method != .solidColor
    }

    public func draw(in context: CGContext,placement p: PDFSlotContext) throws {
        let settings = p.slot.gangJobID.flatMap { jobSettings[$0] } ?? self.settings
        guard settings.enabled,p.slot.sourcePageNumber != nil,let page = p.sourcePage else { return }
        let art = p.artworkRect
        let geometry = PDFPreviewDrawing.artworkGeometry(page, trimRect: p.trimRect)
        var transform = geometry.trimTransform
        var native = geometry.artworkBounds
        if let scale = p.slot.rescale {
            let sourceTrim = CGRect(x: 0, y: 0, width: scale.source.width, height: scale.source.height)
            let scaled = CGAffineTransform(a: scale.factors.width, b: 0, c: 0, d: scale.factors.height,
                                           tx: scale.artwork.origin.x, ty: scale.artwork.origin.y)
            let geometry = PDFPreviewDrawing.artworkGeometry(page, trimRect: sourceTrim)
            transform = geometry.trimTransform.concatenating(scaled)
            native = geometry.artworkBounds.applying(scaled)
        }
        guard !native.isEmpty, !native.contains(art) else { return }

        context.saveGState(); defer { context.restoreGState() }
        // Keep the source BleedBox intact, including transparent areas.
        if settings.method == .solidColor {
            Self.clipToMissingArtwork(art, protecting: native, in: context)
            context.setFillColor(Self.cgColor(settings.color))
            context.fill(art)
        } else {
            try mirror(page, domain: native, art: art, transform: transform, in: context)
        }
    }

    private static func clipToMissingArtwork(_ bounds: CGRect, protecting native: CGRect, in context: CGContext) {
        let protected = bounds.intersection(native)
        context.addRect(bounds)
        if !protected.isEmpty { context.addRect(protected) }
        context.clip(using: .evenOdd)
    }

    private func mirror(_ page: CGPDFPage, domain: CGRect, art: CGRect,
                        transform: CGAffineTransform, in context: CGContext) throws {
        let firstX = floor((art.minX-domain.minX)/domain.width), endX = ceil((art.maxX-domain.minX)/domain.width)
        let firstY = floor((art.minY-domain.minY)/domain.height), endY = ceil((art.maxY-domain.minY)/domain.height)
        // Extremely small trims can require thousands of overlapping PDF draws.
        // A sampled color is emitted as a vector fill in that case.
        guard (endX-firstX)*(endY-firstY) <= 4096,
              let left = Int(exactly: firstX), let right = Int(exactly: endX),
              let bottom = Int(exactly: firstY), let top = Int(exactly: endY) else {
            Self.clipToMissingArtwork(art, protecting: domain, in: context)
            let samples = try cache.samples(for: page)
            context.setFillColor(Self.cgColor(samples.averageEdgeColor))
            context.fill(art)
            return
        }
        // Millimetres in slot coordinates. The backing strips extend actual ink,
        // even when the PDF has nothing beyond the source edge.
        let overlap = 0.5/PDFPreviewDrawing.pointsPerMM
        let clipAllowance = 0.25/PDFPreviewDrawing.pointsPerMM
        let extensionWidth = overlap+clipAllowance
        func boundary(_ index: Int, min: CGFloat, max: CGFloat) -> CGFloat {
            index <= 0 ? min + CGFloat(index)*(max-min) : max + CGFloat(index-1)*(max-min)
        }
        func drawTile(_ target: CGRect, flipX: Bool, flipY: Bool) {
            context.translateBy(x: flipX ? target.maxX : target.minX,
                                y: flipY ? target.maxY : target.minY)
            context.scaleBy(x: (flipX ? -1 : 1)*target.width/domain.width,
                            y: (flipY ? -1 : 1)*target.height/domain.height)
            context.translateBy(x: -domain.minX, y: -domain.minY)
            context.concatenate(transform)
            context.drawPDFPage(page)
        }
        // Back every join first, then paint the unscaled reflections over it.
        for backing in [true,false] {
            for y in bottom..<top {
                for x in left..<right where x != 0 || y != 0 {
                    let x0 = boundary(x, min: domain.minX, max: domain.maxX)
                    let x1 = boundary(x+1, min: domain.minX, max: domain.maxX)
                    let y0 = boundary(y, min: domain.minY, max: domain.maxY)
                    let y1 = boundary(y+1, min: domain.minY, max: domain.maxY)
                    let tile = CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0)
                    let target = backing ? tile.insetBy(dx: -extensionWidth, dy: -extensionWidth) : tile
                    let clip = art.intersection(target)
                    guard !clip.isEmpty else { continue }
                    context.saveGState()
                    if backing {
                        let interior = tile.insetBy(dx: min(overlap,tile.width/2),
                                                   dy: min(overlap,tile.height/2))
                        Self.clipToMissingArtwork(clip, protecting: interior, in: context)
                    } else {
                        context.clip(to: clip)
                    }
                    // Odd tiles flip on their axis, including both axes at a corner.
                    drawTile(target, flipX: !x.isMultiple(of: 2), flipY: !y.isMultiple(of: 2))
                    context.restoreGState()
                }
            }
        }
    }

    public static func cgColor(_ color: BleedColor) -> CGColor {
        let space: CGColorSpace
        switch color { case .cmyk: space = CGColorSpaceCreateDeviceCMYK(); case .rgb: space = CGColorSpace(name: CGColorSpace.sRGB)! }
        return CGColor(colorSpace: space,components: color.components.map { CGFloat($0) }+[1])!
    }
}
