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
    /// Sheet-space page placement, applied outside the existing slot rotation.
    public static func bindingTransform(_ slot: Slot) -> CGAffineTransform {
        CGAffineTransform(a:slot.bindingScale,b:0,c:0,d:slot.bindingScale,
            tx:slot.x*(1-slot.bindingScale)+slot.bindingTranslation.x,
            ty:slot.y*(1-slot.bindingScale)+slot.bindingTranslation.y)
    }
    public static func hasExplicitBox(_ key: String, page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return false }
        var array: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dictionary,key,&array)
    }
    static func sourceBoxes(_ page: CGPDFPage) -> (trim: CGRect, bleed: CGRect?) {
        let media = page.getBoxRect(.mediaBox).standardized
        let trim = page.getBoxRect(.trimBox).standardized.intersection(media)
        var array: CGPDFArrayRef?
        guard let dictionary = page.dictionary, CGPDFDictionaryGetArray(dictionary, "BleedBox", &array),
              let array, CGPDFArrayGetCount(array) == 4 else { return (trim, nil) }
        var values = [CGPDFReal](repeating: 0, count: 4)
        for index in values.indices {
            guard CGPDFArrayGetNumber(array, index, &values[index]), values[index].isFinite else { return (trim, nil) }
        }
        guard values[2] > values[0], values[3] > values[1] else { return (trim, nil) }
        let box = CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
            .intersection(media)
        // A malformed BleedBox must never clip any part of the actual trim.
        guard !trim.isEmpty, !box.isEmpty, box.insetBy(dx: -0.00001, dy: -0.00001).contains(trim) else {
            return (trim, nil)
        }
        return (trim, box.union(trim))
    }

    public static func artworkGeometry(_ page: CGPDFPage, trimRect: CGRect) -> PDFArtworkGeometry {
        let boxes = sourceBoxes(page)
        // Fitting BleedBox to the slot would move/scale the trim. Anchor TrimBox instead,
        // then clip in source coordinates to retain its surrounding artwork and /Rotate.
        return PDFArtworkGeometry(sourceBox: boxes.bleed ?? boxes.trim,trimTransform:
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
