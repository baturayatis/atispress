import CoreGraphics
import ImpositionCore

/// Artwork remains a PDF draw under an affine transform. Only edge strips use
/// the existing sampled-edge method; a page is never converted to an image.
public enum PDFRescaleDrawing {
    static func rect(_ r: Rect) -> CGRect { CGRect(x:r.origin.x,y:r.origin.y,width:r.size.width,height:r.size.height) }
    public static func draw(_ page: CGPDFPage,scale: ArtworkRescale,in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        let r = scale.artwork
        context.translateBy(x:r.origin.x,y:r.origin.y)
        context.scaleBy(x:scale.factors.width,y:scale.factors.height)
        PDFPreviewDrawing.draw(page,in:context,rect:CGRect(x:0,y:0,width:scale.source.width,height:scale.source.height))
    }
    static func fillEdges(_ samples: PDFPageEdgeSamples,inner: CGRect,outer: CGRect,tolerance: Double,in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.addRect(outer); context.addRect(inner); context.clip(using:.evenOdd)
        let sides: [(SampleEdge,CGRect)] = [
            (.left,CGRect(x:outer.minX,y:inner.minY,width:max(0,inner.minX-outer.minX),height:inner.height)),
            (.right,CGRect(x:inner.maxX,y:inner.minY,width:max(0,outer.maxX-inner.maxX),height:inner.height)),
            (.bottom,CGRect(x:inner.minX,y:outer.minY,width:inner.width,height:max(0,inner.minY-outer.minY))),
            (.top,CGRect(x:inner.minX,y:inner.maxY,width:inner.width,height:max(0,outer.maxY-inner.maxY)))
        ]
        for (edge,r) in sides where r.width>0 && r.height>0 {
            let strip = samples.strips[edge]!
            if let color = strip.uniformColor(tolerance:tolerance) {
                context.setFillColor(GeneratedBleedOverlay.cgColor(color)); context.fill(r)
            } else { context.interpolationQuality = .none; context.draw(strip.edgePixels,in:r) }
        }
        for left in [true,false] { for top in [true,false] {
            let r = CGRect(x:left ? outer.minX : inner.maxX,y:top ? inner.maxY : outer.minY,
                           width:max(0,left ? inner.minX-outer.minX : outer.maxX-inner.maxX),
                           height:max(0,top ? outer.maxY-inner.maxY : inner.minY-outer.minY))
            context.setFillColor(GeneratedBleedOverlay.cgColor(samples.corner(left:left,top:top))); context.fill(r)
        } }
    }
}
