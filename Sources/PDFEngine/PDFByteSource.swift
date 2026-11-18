import CoreGraphics
import Darwin
import Foundation

/// Random-access PDF bytes shared by the guide parser and Quartz.
final class PDFByteSource {
    private let handle: FileHandle
    let count: Int

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let length = try handle.seekToEnd()
        guard let count = Int(exactly: length) else { throw PDFClassicFile.StructureError.offsetLimit }
        self.count = count
        self.handle = handle
    }

    private func copy(to buffer: UnsafeMutableRawBufferPointer, at offset: Int) -> Int {
        guard offset >= 0, offset < count, let destination = buffer.baseAddress else { return 0 }
        let length = min(buffer.count, count - offset)
        var copied = 0
        while copied < length {
            let size = pread(handle.fileDescriptor, destination.advanced(by: copied), length - copied, off_t(offset + copied))
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else { break }
            copied += size
        }
        return copied
    }

    func read(_ range: Range<Int>) -> Data {
        guard range.lowerBound >= 0, range.upperBound <= count else { return Data() }
        var bytes = Data(count: range.count)
        let length = bytes.withUnsafeMutableBytes { copy(to: $0, at: range.lowerBound) }
        bytes.count = length
        return bytes
    }

    func contains(_ needle: Data) throws -> Bool {
        guard !needle.isEmpty else { return true }
        let chunk = 256 * 1024
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let end = offset + min(count - offset, chunk + needle.count - 1)
            let bytes = read(offset..<end)
            guard bytes.count == end - offset else { throw CocoaError(.fileReadUnknown) }
            if bytes.range(of: needle) != nil { return true }
            offset += min(chunk, count - offset)
        }
        return false
    }

    func document() -> CGPDFDocument? {
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, length in
                guard let info, let offset = Int(exactly: position) else { return 0 }
                let source = Unmanaged<PDFByteSource>.fromOpaque(info).takeUnretainedValue()
                return source.copy(to: UnsafeMutableRawBufferPointer(start: buffer, count: length), at: offset)
            },
            releaseInfo: { info in
                if let info { Unmanaged<PDFByteSource>.fromOpaque(info).release() }
            })
        let retained = Unmanaged.passRetained(self)
        guard let provider = CGDataProvider(directInfo: retained.toOpaque(), size: off_t(count), callbacks: &callbacks) else {
            retained.release()
            return nil
        }
        return CGPDFDocument(provider)
    }
}
