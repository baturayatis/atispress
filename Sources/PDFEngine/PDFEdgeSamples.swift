import Foundation
import CoreGraphics
import ImpositionCore

public enum SampleEdge: CaseIterable, Sendable { case left, right, bottom, top }
public struct EdgeStrip: @unchecked Sendable {
    public let edgePixels: CGImage
    public let isCMYK: Bool
    public let firstColor: BleedColor
    public let lastColor: BleedColor
    let memoryCost: Int
    private let minimum: [UInt8]
    private let maximum: [UInt8]
    private let representative: BleedColor
    init(context: CGContext,edge: SampleEdge,isCMYK: Bool) throws {
        guard let data = context.data,let space = context.colorSpace else { throw PDFExportError.cannotCreatePDF }
        self.isCMYK = isCMYK
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        func color(_ offset: Int) -> BleedColor {
            let v = (0..<4).map { Double(bytes[offset+$0])/255 }
            return isCMYK ? .cmyk(v[0],v[1],v[2],v[3]) : .rgb(v[0],v[1],v[2])
        }
        var lo = [UInt8](repeating: 255,count: 4),hi = [UInt8](repeating: 0,count: 4)
        for row in 0..<context.height {
            for column in 0..<context.width {
                let offset = row*context.bytesPerRow+column*4
                for c in 0..<(isCMYK ? 4 : 3) { lo[c] = min(lo[c],bytes[offset+c]); hi[c] = max(hi[c],bytes[offset+c]) }
            }
        }
        minimum = lo; maximum = hi
        representative = color((context.height/2)*context.bytesPerRow+(context.width/2)*4)
        let vertical = edge == .left || edge == .right
        let length = vertical ? context.height : context.width
        var line = [UInt8](); line.reserveCapacity(length*4)
        var offsets: [Int] = []
        for index in 0..<length {
            let x = vertical ? (edge == .left ? 0 : context.width-1) : index
            let y = vertical ? index : (edge == .top ? 0 : context.height-1)
            let offset = y*context.bytesPerRow+x*4
            if index == 0 || index == length-1 { offsets.append(offset) }
            for c in 0..<4 { line.append(bytes[offset+c]) }
        }
        firstColor = color(offsets[0]); lastColor = color(offsets.last!)
        let width = vertical ? 1 : length,height = vertical ? length : 1
        guard let provider = CGDataProvider(data: Data(line) as CFData),
              let image = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
                space: space,bitmapInfo: context.bitmapInfo,provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent) else {
            throw PDFExportError.cannotCreatePDF
        }
        edgePixels = image; memoryCost = line.count+256
    }
    public func uniformColor(tolerance: Double) -> BleedColor? {
        for c in 0..<(isCMYK ? 4 : 3) {
            if Double(maximum[c]-minimum[c])/255 > tolerance { return nil }
        }
        return representative
    }
}
public final class PDFPageEdgeSamples: NSObject, @unchecked Sendable {
    public let strips: [SampleEdge:EdgeStrip]
    public let usesCMYK: Bool
    public let memoryCost: Int
    init(page: CGPDFPage,rescale: ArtworkRescale? = nil) throws {
        usesCMYK = PDFColorProbe.canReadNativeCMYK(page)
        let box = page.getBoxRect(.trimBox).intersection(page.getBoxRect(.mediaBox))
        let rotated = abs(page.rotationAngle%180) == 90
        let sourceTrim = CGRect(x: 0,y: 0,width: (rotated ? box.height : box.width)/PDFPreviewDrawing.pointsPerMM,
                          height: (rotated ? box.width : box.height)/PDFPreviewDrawing.pointsPerMM)
        let trim = rescale.map { CGRect(x:0,y:0,width:$0.settings.target.width,height:$0.settings.target.height) } ?? sourceTrim
        let raw = rescale?.settings.mode == .fit ? try PDFPageEdgeSamples(page:page) : nil
        guard trim.width.isFinite,trim.height.isFinite,trim.width > 0,trim.height > 0 else { throw PDFReadError.invalidBox(page.pageNumber) }
        var results: [SampleEdge:EdgeStrip] = [:], cost = 0
        for edge in SampleEdge.allCases {
            try Task.checkCancellation()
            let depth = min(0.5,min(trim.width,trim.height))
            let rect: CGRect
            switch edge {
            case .left: rect = CGRect(x: 0,y: 0,width: depth,height: trim.height)
            case .right: rect = CGRect(x: trim.width-depth,y: 0,width: depth,height: trim.height)
            case .bottom: rect = CGRect(x: 0,y: 0,width: trim.width,height: depth)
            case .top: rect = CGRect(x: 0,y: trim.height-depth,width: trim.width,height: depth)
            }
            let width = Int(ceil(rect.width*600/25.4)),height = Int(ceil(rect.height*600/25.4))
            guard width > 0,height > 0,width <= 250_000,height <= 250_000 else { throw PDFReadError.invalidBox(page.pageNumber) }
            let space = usesCMYK ? CGColorSpaceCreateDeviceCMYK() : CGColorSpace(name: CGColorSpace.sRGB)!
            let flags = usesCMYK ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: 0,
                                          space: space,bitmapInfo: flags) else { throw PDFExportError.cannotCreatePDF }
            context.setFillColor(CGColor(colorSpace: space,components: usesCMYK ? [0,0,0,0,1] : [1,1,1,1])!)
            context.fill(CGRect(x: 0,y: 0,width: width,height: height))
            context.scaleBy(x: Double(width)/rect.width,y: Double(height)/rect.height)
            context.translateBy(x: -rect.minX,y: -rect.minY)
            if let rescale {
                if let raw { PDFRescaleDrawing.fillEdges(raw,inner:PDFRescaleDrawing.rect(rescale.artwork),outer:trim,tolerance:0.02,in:context) }
                PDFRescaleDrawing.draw(page,scale:rescale,in:context)
            } else {
                context.concatenate(page.getDrawingTransform(.trimBox,rect: trim,rotate: 0,preserveAspectRatio: true))
                context.drawPDFPage(page)
            }
            let strip = try EdgeStrip(context: context,edge: edge,isCMYK: usesCMYK)
            results[edge] = strip; cost += strip.memoryCost
        }
        strips = results; memoryCost = cost
    }
    public func corner(left: Bool,top: Bool) -> BleedColor {
        let strip = strips[left ? .left : .right]!
        return top ? strip.firstColor : strip.lastColor
    }
}
/// A separate instance belongs to each immutable PDFSource. Samples do not depend on tolerance/method.
public final class PDFEdgeSampleCache: @unchecked Sendable {
    private let lock = NSLock()
    private let cache = NSCache<NSNumber,PDFPageEdgeSamples>()
    private let scaledCache = NSCache<NSString,PDFPageEdgeSamples>()
    public init() { scaledCache.totalCostLimit = 64*1024*1024; cache.totalCostLimit = 64*1024*1024 }
    public func cached(page: Int) -> PDFPageEdgeSamples? { cache.object(forKey: NSNumber(value: page)) }
    private func scaledKey(page:Int,rescale:ArtworkRescale) -> NSString {
        "\(page):\(rescale.source.width):\(rescale.source.height):\(rescale.settings.target.width):\(rescale.settings.target.height):\(rescale.settings.mode.rawValue)" as NSString
    }
    public func cached(page:Int,rescale:ArtworkRescale) -> PDFPageEdgeSamples? { scaledCache.object(forKey:scaledKey(page:page,rescale:rescale)) }
    public func samples(for page: CGPDFPage,rescale: ArtworkRescale) throws -> PDFPageEdgeSamples {
        let key = scaledKey(page:page.pageNumber,rescale:rescale)
        lock.lock(); defer { lock.unlock() }
        if let hit = scaledCache.object(forKey:key) { return hit }
        let samples = try PDFPageEdgeSamples(page:page,rescale:rescale)
        scaledCache.setObject(samples,forKey:key,cost:samples.memoryCost)
        return samples
    }
    public func samples(for page: CGPDFPage) throws -> PDFPageEdgeSamples {
        lock.lock(); defer { lock.unlock() }
        if let hit = cached(page: page.pageNumber) { return hit }
        let samples = try PDFPageEdgeSamples(page: page)
        cache.setObject(samples,forKey: NSNumber(value: page.pageNumber),cost: samples.memoryCost)
        return samples
    }
}
