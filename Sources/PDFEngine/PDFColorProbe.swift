import CoreGraphics
import Foundation

/// Conservative provenance check, not a PDF color preflight. DeviceCMYK content is sampled
/// into DeviceCMYK; mixed, ICC, pattern, shading or transparency content falls back to sRGB.
enum PDFColorProbe {
    private final class State {
        var cmyk = false
        var fallback = false
        var depth = 0
        let table: CGPDFOperatorTableRef
        init(_ table: CGPDFOperatorTableRef) { self.table = table }
        func name(_ name: String) {
            if name == "DeviceCMYK" { cmyk = true }
            else if name != "DeviceGray" { fallback = true }
        }
        func colorObject(_ object: CGPDFObjectRef?) {
            guard let object else { fallback = true; return }
            var value: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(object,.name,&value),let value { name(String(cString: value)) }
            else { fallback = true }
        }
        func scan(_ stream: CGPDFContentStreamRef) {
            guard depth < 16 else { fallback = true; return }
            // A resource override may map DeviceCMYK through another profile.
            if CGPDFContentStreamGetResource(stream,"ColorSpace","DefaultCMYK") != nil { fallback = true }
            depth += 1; defer { depth -= 1 }
            let scanner = CGPDFScannerCreate(stream,table,Unmanaged.passUnretained(self).toOpaque())
            defer { CGPDFScannerRelease(scanner) }
            if !CGPDFScannerScan(scanner) { fallback = true }
        }
    }
    private static func state(_ pointer: UnsafeMutableRawPointer?) -> State? {
        pointer.map { Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }
    }
    static func canReadNativeCMYK(_ page: CGPDFPage) -> Bool {
        guard let table = CGPDFOperatorTableCreate() else { return false }
        defer { CGPDFOperatorTableRelease(table) }
        for op in ["k","K"] { CGPDFOperatorTableSetCallback(table,op,{ _,info in PDFColorProbe.state(info)?.cmyk = true }) }
        for op in ["rg","RG","sh","gs","BI"] { CGPDFOperatorTableSetCallback(table,op,{ _,info in PDFColorProbe.state(info)?.fallback = true }) }
        for op in ["cs","CS"] {
            CGPDFOperatorTableSetCallback(table,op,{ scanner,info in
                guard let s = PDFColorProbe.state(info) else { return }
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner,&name),let name else { s.fallback = true; return }
                let value = String(cString: name)
                if value.hasPrefix("Device") { s.name(value) }
                else { s.colorObject(CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner),"ColorSpace",name)) }
            })
        }
        CGPDFOperatorTableSetCallback(table,"Do",{ scanner,info in
            guard let s = PDFColorProbe.state(info) else { return }
            var name: UnsafePointer<CChar>?, stream: CGPDFStreamRef?
            let parent = CGPDFScannerGetContentStream(scanner)
            guard CGPDFScannerPopName(scanner,&name),let name,
                  let object = CGPDFContentStreamGetResource(parent,"XObject",name),
                  CGPDFObjectGetValue(object,.stream,&stream),let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { s.fallback = true; return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary,"Subtype",&subtype),let subtype else { s.fallback = true; return }
            if String(cString: subtype) == "Form" {
                var resources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources)
                let child = CGPDFContentStreamCreateWithStream(stream,resources ?? dictionary,parent)
                defer { CGPDFContentStreamRelease(child) }; s.scan(child)
            } else if String(cString: subtype) == "Image" {
                var mask = false
                if CGPDFDictionaryGetBoolean(dictionary,"ImageMask",&mask),mask { return }
                var space: CGPDFObjectRef?
                CGPDFDictionaryGetObject(dictionary,"ColorSpace",&space); s.colorObject(space)
            } else { s.fallback = true }
        })
        let s = State(table)
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        s.scan(stream)
        return s.cmyk && !s.fallback
    }
}
