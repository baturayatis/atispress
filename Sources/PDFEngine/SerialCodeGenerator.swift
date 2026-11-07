import Foundation
import CoreImage
import CoreGraphics
import ImpositionCore

public struct CodeModuleRun: Equatable, Sendable {
    public let row: Int
    public let start: Int
    public let count: Int
}
/// Row zero is the top row. Generator-provided padding is removed; the field's
/// explicit quiet-zone setting is applied later in millimetre geometry.
public struct CodeModuleMatrix: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let modules: [UInt8]
    public let runs: [CodeModuleRun]
    public func isDark(x: Int,y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height && modules[y*width+x] != 0
    }
    init(width: Int,height: Int,modules: [UInt8]) {
        self.width = width; self.height = height; self.modules = modules
        var runs: [CodeModuleRun] = []
        for row in 0..<height {
            var x = 0
            while x < width {
                if modules[row*width+x] == 0 { x += 1; continue }
                let start = x
                while x < width && modules[row*width+x] != 0 { x += 1 }
                runs.append(CodeModuleRun(row: row,start: start,count: x-start))
            }
        }
        self.runs = runs
    }
}
public enum SerialCodeError: LocalizedError, Sendable {
    case empty, tooLong, asciiOnly, unavailable, bitmapUnavailable
    public var errorDescription: String? {
        switch self {
        case .empty: return "Kod içeriği boş; kod çıktıya eklenmedi."
        case .tooLong: return "İçerik çok uzun veya seçilen kod türüyle kodlanamıyor; kod çıktıya eklenmedi."
        case .asciiOnly: return "Code 128 yalnız ASCII karakterlerini destekler; QR kod seçin. Kod çıktıya eklenmedi."
        case .unavailable: return "Apple kod üreteci kullanılamadı; kod çıktıya eklenmedi."
        case .bitmapUnavailable: return "Kod modülleri okunamadı; kod çıktıya eklenmedi."
        }
    }
}
/// CIFilter objects are local to each request. NSCache is thread-safe and bounded;
/// only matrices needed for visible/exported copies or endpoint validation exist.
public final class SerialCodeGenerator: @unchecked Sendable {
    public static let shared = SerialCodeGenerator()
    private final class Entry: NSObject {
        let result: Result<CodeModuleMatrix,SerialCodeError>
        init(_ result: Result<CodeModuleMatrix,SerialCodeError>) { self.result = result }
    }
    private let cache = NSCache<NSString,Entry>()
    private let context = CIContext(options: [.useSoftwareRenderer:true,.workingColorSpace:NSNull(),.outputColorSpace:NSNull(),.cacheIntermediates:false])
    public init() { cache.countLimit = 256; cache.totalCostLimit = 16*1024*1024 }
    public func matrix(content: String,kind: SerialCodeSettings.Kind,correction: SerialCodeSettings.Correction = .m) throws -> CodeModuleMatrix {
        let key = "\(kind.rawValue)|\(correction.rawValue)|\(content)" as NSString
        if let cached = cache.object(forKey: key) { return try cached.result.get() }
        let result: Result<CodeModuleMatrix,SerialCodeError>
        do { result = .success(try generate(content: content,kind: kind,correction: correction)) }
        catch let error as SerialCodeError { result = .failure(error) }
        catch { result = .failure(.bitmapUnavailable) }
        let cost: Int
        switch result { case .success(let matrix): cost = matrix.modules.count+matrix.runs.count*24+content.utf8.count
        case .failure: cost = min(content.utf8.count,4096)+128 }
        // Do not retain oversized keys for unencodable user content.
        if content.utf8.count <= 4096 { cache.setObject(Entry(result),forKey: key,cost: cost) }
        return try result.get()
    }
    private func generate(content: String,kind: SerialCodeSettings.Kind,correction: SerialCodeSettings.Correction) throws -> CodeModuleMatrix {
        guard !content.isEmpty else { throw SerialCodeError.empty }
        guard kind != .text else { throw SerialCodeError.unavailable }
        let data: Data
        if kind == .code128 {
            guard let ascii = content.data(using: .ascii,allowLossyConversion: false) else { throw SerialCodeError.asciiOnly }
            data = ascii
        } else { data = Data(content.utf8) }
        guard data.count <= (kind == .qr ? 4096 : 1024) else { throw SerialCodeError.tooLong }
        guard let filter = CIFilter(name: kind == .qr ? "CIQRCodeGenerator" : "CICode128BarcodeGenerator") else { throw SerialCodeError.unavailable }
        filter.setDefaults(); filter.setValue(data,forKey: "inputMessage")
        if kind == .qr { filter.setValue(correction.rawValue,forKey: "inputCorrectionLevel") }
        else { filter.setValue(0,forKey: "inputQuietSpace"); filter.setValue(1,forKey: "inputBarcodeHeight") }
        guard let output = filter.outputImage else { throw SerialCodeError.tooLong }
        // These Apple generators expose their native module image. Prefer it to
        // avoid color resampling/GPU requirements; CIContext is the public fallback.
        guard let image = output.cgImage ?? context.createCGImage(output,from: output.extent,format: .RGBA8,colorSpace: nil),
              image.width > 0,image.height > 0,image.width <= 20_000,image.height <= 512 else { throw SerialCodeError.bitmapUnavailable }
        let width = image.width,height = image.height
        var pixels = [UInt8](repeating: 255,count: width*height*4)
        let copied = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let bitmap = CGContext(data: bytes.baseAddress,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,
                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            bitmap.interpolationQuality = .none; bitmap.setBlendMode(.copy)
            bitmap.draw(image,in: CGRect(x: 0,y: 0,width: width,height: height))
            return true
        }
        guard copied else { throw SerialCodeError.bitmapUnavailable }
        var minX = width,minY = height,maxX = -1,maxY = -1
        for y in 0..<height { for x in 0..<width where pixels[(y*width+x)*4] < 128 {
            minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y)
        } }
        guard maxX >= minX,maxY >= minY else { throw SerialCodeError.bitmapUnavailable }
        let columns = maxX-minX+1,rows = kind == .qr ? maxY-minY+1 : 1
        var modules: [UInt8] = []; modules.reserveCapacity(columns*rows)
        for row in 0..<rows {
            let y = kind == .qr ? minY+row : (minY+maxY)/2
            for x in minX...maxX { modules.append(pixels[(y*width+x)*4] < 128 ? 1 : 0) }
        }
        return CodeModuleMatrix(width: columns,height: rows,modules: modules)
    }
}
