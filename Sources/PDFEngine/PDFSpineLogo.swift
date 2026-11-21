import AppKit
import ImageIO
import ImpositionCore

extension PDFSpine {
    private final class LogoAsset: NSObject {
        let data: Data
        let format: SpineLogo.Format
        let lock = NSLock()
        let document: CGPDFDocument?
        let image: CGImage?
        let size: CGSize

        init?(data: Data, format: SpineLogo.Format) {
            self.data = data
            self.format = format
            if format == .pdf {
                guard let provider = CGDataProvider(data:data as CFData),
                      let document = CGPDFDocument(provider), document.isUnlocked,
                      document.allowsCopying, document.numberOfPages == 1,
                      let page = document.page(at:1) else { return nil }
                let box = page.getBoxRect(.trimBox).intersection(page.getBoxRect(.mediaBox))
                guard !box.isEmpty else { return nil }
                size = page.rotationAngle % 180 == 0 ? box.size : CGSize(width:box.height,height:box.width)
                self.document = document
                image = nil
            } else {
                guard let source = CGImageSourceCreateWithData(data as CFData,nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                      let w = properties[kCGImagePropertyPixelWidth] as? Int,
                      let h = properties[kCGImagePropertyPixelHeight] as? Int,
                      w > 0, h > 0, w <= 8192, h <= 8192, w*h <= 24_000_000,
                      let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { return nil }
                size = CGSize(width:image.width,height:image.height)
                self.image = image
                document = nil
            }
        }
    }

    private static let logos: NSCache<NSUUID,LogoAsset> = {
        let cache = NSCache<NSUUID,LogoAsset>()
        cache.totalCostLimit = 64*1024*1024
        return cache
    }()

    private static func logoAsset(_ logo: SpineLogo) -> LogoAsset? {
        let key = logo.id as NSUUID
        if let asset = logos.object(forKey:key), asset.format == logo.format, asset.data == logo.data { return asset }
        guard logo.data.count <= 16*1024*1024, let asset = LogoAsset(data:logo.data,format:logo.format) else { return nil }
        let cost = asset.image.map { $0.bytesPerRow*$0.height } ?? logo.data.count
        logos.setObject(asset,forKey:key,cost:cost)
        return asset
    }

    /// Ask AppKit for a PDF first. Some system SVG representations draw through an image.
    @MainActor public static func importSVGLogo(name: String,data: Data,in trim: CGRect) -> SpineLogo? {
        guard data.count <= 16*1024*1024, let image = NSImage(data:data) else { return nil }
        let size = image.size
        let longest = max(size.width,size.height)
        guard longest.isFinite, size.width > 0, size.height > 0 else { return nil }
        let factor = 2048/longest
        var bounds = CGRect(x:0,y:0,width:max(1,size.width*factor),height:max(1,size.height*factor))
        let dataBuffer = NSMutableData()
        if let consumer = CGDataConsumer(data:dataBuffer as CFMutableData),
           let pdf = CGContext(consumer:consumer,mediaBox:&bounds,nil) {
            pdf.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext:pdf,flipped:false)
            image.draw(in:bounds)
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
            pdf.closePDF()
            let result = dataBuffer as Data
            if let provider = CGDataProvider(data:result as CFData),
               let page = CGPDFDocument(provider)?.page(at:1),
               !hasImage(in:page.dictionary,depth:0),
               let logo = makeLogo(name:name,format:.pdf,data:result,in:trim) { return logo }
        }
        guard let raster = image.cgImage(forProposedRect:&bounds,context:nil,hints:nil),
              let png = NSBitmapImageRep(cgImage:raster).representation(using:.png,properties:[:]) else { return nil }
        return makeLogo(name:name,format:.convertedSVG,data:png,in:trim)
    }

    private static func hasImage(in dictionary: CGPDFDictionaryRef?,depth: Int) -> Bool {
        guard depth < 16 else { return true }
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        guard let dictionary, CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources), let resources,
              CGPDFDictionaryGetDictionary(resources,"XObject",&objects), let objects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(objects,{ _,object,_ in
            var stream: CGPDFStreamRef?
            guard !found, CGPDFObjectGetValue(object,.stream,&stream), let stream,
                  let item = CGPDFStreamGetDictionary(stream) else { return !found }
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(item,"Subtype",&subtype), let subtype, String(cString:subtype) == "Image" {
                found = true
            } else {
                found = hasImage(in:item,depth:depth+1)
            }
            return !found
        },nil)
        return found
    }

    public static func makeLogo(name: String,format: SpineLogo.Format,data: Data,in trim: CGRect) -> SpineLogo? {
        var logo = SpineLogo(name:name,format:format,data:data,width:1)
        guard let asset = logoAsset(logo), trim.width > 0, trim.height > 0 else { return nil }
        logo.width = min(trim.width,trim.height*asset.size.width/asset.size.height)*0.8
        return logo
    }

    public static func logoBounds(_ logo: SpineLogo,in trim: CGRect) -> CGRect? {
        logoPlacement(logo,in:trim)?.bounds
    }

    private static func logoPlacement(_ logo: SpineLogo,in trim: CGRect) -> (rect:CGRect, transform:CGAffineTransform, bounds:CGRect)? {
        guard logo.width.isFinite, logo.width > 0, logo.width <= 10_000,
              [logo.x,logo.y,logo.rotation].allSatisfy({ $0.isFinite }),
              let asset = logoAsset(logo) else { return nil }
        let height = logo.width*asset.size.height/asset.size.width
        let rect = CGRect(x:-logo.width/2,y:-height/2,width:logo.width,height:height)
        let rotation = CGAffineTransform(rotationAngle:logo.rotation.truncatingRemainder(dividingBy:360)*(.pi/180))
        let offset = CGAffineTransform(translationX:trim.midX+logo.x,y:trim.midY+logo.y)
        let transform = rotation.concatenating(offset)
        return (rect,transform,rect.applying(transform))
    }

    public static func logoWarning(_ logo: SpineLogo,in trim: CGRect) -> String? {
        guard let bounds = logoBounds(logo,in:trim) else { return "Logo dosyası veya ölçüsü geçersiz. Logoyu değiştirin." }
        let width = max(0,trim.minX-bounds.minX)+max(0,bounds.maxX-trim.maxX)
        let height = max(0,trim.minY-bounds.minY)+max(0,bounds.maxY-trim.maxY)
        guard width > 0.00001 || height > 0.00001 else { return nil }
        return String(format:"Logo taşıyor · En: %.4f mm · Boy: %.4f mm",locale:Locale(identifier:"tr_TR"),width,height)
    }

    static func drawLogo(_ logo: SpineLogo,in trim: CGRect,context: CGContext) {
        guard logoWarning(logo,in:trim) == nil, let placement = logoPlacement(logo,in:trim),
              let asset = logoAsset(logo) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(placement.transform)
        asset.lock.lock()
        defer { asset.lock.unlock() }
        if let page = asset.document?.page(at:1) {
            context.clip(to:placement.rect)
            PDFPreviewDrawing.draw(page,in:context,rect:placement.rect)
        } else if let image = asset.image {
            context.draw(image,in:placement.rect)
        }
    }
}
