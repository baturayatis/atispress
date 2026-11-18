import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes only the PDF image stream. Samples are stored back by the existing
/// Flate writer with the image dictionary's original color space.
enum PDFJPEGImageSamples {
    private struct Header {
        var width = 0
        var height = 0
        var components = 0
        var profile: Data?

        init?(_ data: Data) {
            guard data.count >= 4, data[0] == 0xff, data[1] == 0xd8 else { return nil }
            var offset = 2
            var profileParts: [Int: Data] = [:]
            var profileCount = 0
            var transform: UInt8?
            var jfif = false
            var foundScan = false
            var identifiers: [UInt8] = []
            while offset < data.count, data[offset] == 0xff {
                while offset < data.count, data[offset] == 0xff { offset += 1 }
                guard offset < data.count else { return nil }
                let marker = data[offset]
                offset += 1
                if marker == 0xda {
                    foundScan = true
                    break
                }
                guard offset + 2 <= data.count else { return nil }
                let length = Int(data[offset]) * 256 + Int(data[offset + 1])
                guard length >= 2, length <= data.count - offset else { return nil }
                let payload = offset + 2
                let end = offset + length
                switch marker {
                case 0xc0, 0xc1, 0xc2: // Sequential and progressive Huffman DCT
                    guard components == 0, end - payload >= 6, data[payload] == 8 else { return nil }
                    height = Int(data[payload + 1]) * 256 + Int(data[payload + 2])
                    width = Int(data[payload + 3]) * 256 + Int(data[payload + 4])
                    components = Int(data[payload + 5])
                    guard components == 1 || components == 3, end - payload == 6 + 3 * components else { return nil }
                    identifiers = (0..<components).map { data[payload + 6 + 3 * $0] }
                case 0xe0:
                    jfif = data[payload..<end].starts(with: "JFIF\0".utf8) || jfif
                case 0xe2 where data[payload..<end].starts(with: "ICC_PROFILE\0".utf8):
                    guard end - payload > 14 else { return nil }
                    let index = Int(data[payload + 12]), count = Int(data[payload + 13])
                    guard index > 0, index <= count, profileCount == 0 || profileCount == count,
                          profileParts[index] == nil else { return nil }
                    profileCount = count
                    profileParts[index] = data.subdata(in: (payload + 14)..<end)
                case 0xee where data[payload..<end].starts(with: "Adobe".utf8):
                    guard end - payload >= 12, transform == nil else { return nil }
                    transform = data[payload + 11]
                default: break
                }
                offset = end
            }
            guard foundScan, width > 0, height > 0, components > 0 else { return nil }
            if components == 3 {
                if let transform {
                    guard transform <= 1 else { return nil }
                } else {
                    // Without an Adobe marker PDF expects YCbCr. Reject RGB
                    // identifiers without that marker rather than guessing.
                    guard identifiers == [1, 2, 3] || (jfif && identifiers != [82, 71, 66]) else { return nil }
                }
            } else if let transform, transform != 0 { return nil }
            if profileCount > 0 {
                guard profileParts.count == profileCount else { return nil }
                profile = (1...profileCount).compactMap { profileParts[$0] }.reduce(into: Data()) { $0.append($1) }
            }
        }
    }

    static func decode(_ data: Data, width: Int, height: Int, components: Int, pdfICC: Data?) throws -> Data? {
        guard let header = Header(data), header.width == width, header.height == height,
              header.components == components,
              header.profile == nil || header.profile == pdfICC,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == width, image.height == height, image.bitsPerComponent == 8,
              image.colorSpace?.model == (components == 1 ? .monochrome : .rgb) else { return nil }

        try Task.checkCancellation()
        // DCT produces component values. Retag the decoder bitmap so drawing
        // it to the sample buffer cannot apply a second ICC conversion.
        let space = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let stride = components == 1 ? 1 : 4
        let bitmapInfo = components == 1 ? CGImageAlphaInfo.none.rawValue :
            CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let samplesImage = image.copy(colorSpace: space),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * stride, space: space, bitmapInfo: bitmapInfo),
              let bytes = context.data else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(samplesImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        if components == 1 { return Data(bytes: bytes, count: width * height) }
        let sourceBytes = bytes.assumingMemoryBound(to: UInt8.self)
        var samples = Data(count: width * height * 3)
        try samples.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            let target = buffer.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                if i.isMultiple(of: 4096) { try Task.checkCancellation() }
                target[i * 3] = sourceBytes[i * 4]
                target[i * 3 + 1] = sourceBytes[i * 4 + 1]
                target[i * 3 + 2] = sourceBytes[i * 4 + 2]
            }
        }
        return samples
    }
}
