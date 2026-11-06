import AppKit
import ImpositionCore

public struct PDFArtworkGeometry {
    public let sourceBox: CGRect
    public let trimTransform: CGAffineTransform
    public var artworkBounds: CGRect { sourceBox.applying(trimTransform) }
}

/// One artwork path for low-zoom rasters, high-zoom preview and vector export.
public enum PDFPreviewDrawing {
    public static let pointsPerMM = 72.0/25.4
    public static func localTrim(_ slot: Slot) -> CGRect {
        let rotated = slot.rotation % 180 != 0
        return CGRect(x: 0,y: 0,width: rotated ? slot.size.height : slot.size.width,
                      height: rotated ? slot.size.width : slot.size.height)
    }
    public static func slotTransform(_ slot: Slot) -> CGAffineTransform {
        let local = localTrim(slot)
        var transform = CGAffineTransform(rotationAngle: -Double(slot.rotation) * .pi / 180)
        if slot.mirrored { transform = transform.scaledBy(x: -1,y: 1) }
        let footprint = local.applying(transform)
        transform.tx += slot.x-footprint.minX; transform.ty += slot.y-footprint.minY
        return transform
    }
    public static func hasExplicitBox(_ key: String, page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return false }
        var array: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dictionary,key,&array)
    }
    public static func artworkGeometry(_ page: CGPDFPage, trimRect: CGRect) -> PDFArtworkGeometry {
        func valid(_ rect: CGRect) -> Bool {
            !rect.isNull && rect.width.isFinite && rect.height.isFinite && rect.origin.x.isFinite &&
                rect.origin.y.isFinite && rect.width > 0 && rect.height > 0
        }
        let media = page.getBoxRect(.mediaBox).standardized
        let bleed = page.getBoxRect(.bleedBox).standardized
        let box: CGRect
        if hasExplicitBox("BleedBox",page: page), valid(bleed), !valid(media) || valid(bleed.intersection(media)) {
            box = valid(media) ? bleed.intersection(media) : bleed
        } else if valid(media) { box = media }
        else { box = page.getBoxRect(.trimBox).standardized }
        // Fitting BleedBox to the slot would move/scale the trim. Anchor TrimBox instead,
        // then clip in source coordinates to retain its surrounding artwork and /Rotate.
        return PDFArtworkGeometry(sourceBox: box,trimTransform:
            page.getDrawingTransform(.trimBox,rect: trimRect,rotate: 0,preserveAspectRatio: true))
    }
    public static func draw(_ page: CGPDFPage,in context: CGContext,rect: CGRect) {
        let geometry = artworkGeometry(page,trimRect: rect)
        context.saveGState()
        context.concatenate(geometry.trimTransform)
        context.clip(to: geometry.sourceBox)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}

/// Raster extent is normalized to the displayed trim (0...1), including negative bleed origins.
public final class PDFPageRaster: NSObject {
    public let cgImage: CGImage
    public let image: NSImage
    public let normalizedArtworkBounds: CGRect
    init(cgImage: CGImage, bounds: CGRect) {
        self.cgImage = cgImage; normalizedArtworkBounds = bounds
        image = NSImage(cgImage: cgImage,size: NSSize(width: cgImage.width,height: cgImage.height))
    }
}
