import Foundation
import CoreGraphics
import ImpositionCore

public struct PDFPreflightFinding: Equatable, Sendable {
    public enum Severity: String, Sendable { case warning = "Uyarı", notice = "Bilgi", unknown = "Kontrol edilemedi" }
    public var code: String
    public var page: Int
    public var severity: Severity
    public var explanation: String
    public init(_ code: String,page: Int,severity: Severity = .warning,_ explanation: String) {
        self.code = code; self.page = page; self.severity = severity; self.explanation = explanation
    }
}

/// Bounded content-stream/resource inspection. It never modifies the PDF and is
/// not a PDF/X certification or a color-managed raster ink-coverage measurement.
public enum PDFPreflight {
    public static func inspect(_ document: CGPDFDocument) -> [PDFPreflightFinding] {
        var findings: [PDFPreflightFinding] = []
        for number in 1...document.numberOfPages {
            if Task.isCancelled { break }
            guard let page = document.page(at: number) else {
                findings.append(PDFPreflightFinding("unreadable",page: number,severity: .unknown,"Sayfa içeriği kontrol edilemedi.")); continue
            }
            let inspection = PreflightScanner(page: number)
            if let pageDictionary = page.dictionary {
                inspection.transparency(pageDictionary)
                var current: CGPDFDictionaryRef? = pageDictionary
                for _ in 0..<32 {
                    guard let value = current else { break }
                    if let resources = dictionary(value,"Resources") { inspection.resources = resources; break }
                    current = dictionary(value,"Parent")
                }
            }
            let content = CGPDFContentStreamCreateWithPage(page)
            inspection.scan(content)
            CGPDFContentStreamRelease(content)
            findings += inspection.findings
        }
        return findings
    }
}
private func name(_ dictionary: CGPDFDictionaryRef,_ key: String) -> String? {
    var value: UnsafePointer<CChar>?
    return CGPDFDictionaryGetName(dictionary,key,&value) ? value.map { String(cString: $0) } : nil
}
private func dictionary(_ source: CGPDFDictionaryRef,_ key: String) -> CGPDFDictionaryRef? {
    var value: CGPDFDictionaryRef?
    return CGPDFDictionaryGetDictionary(source,key,&value) ? value : nil
}
private func number(_ dictionary: CGPDFDictionaryRef,_ key: String) -> Double? {
    var value: CGPDFReal = 0
    return CGPDFDictionaryGetNumber(dictionary,key,&value) ? Double(value) : nil
}
private final class PreflightScanner {
    let page: Int
    var findings: [PDFPreflightFinding] = []
    var resources: CGPDFDictionaryRef?
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var depth = 0, operations = 0
    init(page: Int) { self.page = page }
    func add(_ code: String,_ message: String,_ severity: PDFPreflightFinding.Severity = .warning) {
        guard !findings.contains(where: { $0.code == code && $0.explanation == message }) else { return }
        findings.append(PDFPreflightFinding(code,page: page,severity: severity,message))
    }
    func unknown(_ message: String) { add("unknown",message,.unknown) }
    func transparency(_ dict: CGPDFDictionaryRef) {
        if (number(dict,"ca") ?? 1) < 1 || (number(dict,"CA") ?? 1) < 1 ||
            dictionary(dict,"SMask") != nil || name(dict,"BM").map({ $0 != "Normal" && $0 != "Compatible" }) == true ||
            dictionary(dict,"Group").flatMap({ name($0,"S") }) == "Transparency" {
            add("transparency","Saydamlık / karışım etkisi var; baskı iş akışını kontrol edin.")
        }
    }
    func scan(_ content: CGPDFContentStreamRef) {
        guard depth < 16,operations < 100_000 else { unknown("İç içe / karmaşık içerik sınırı: kalan öğeler kontrol edilemedi."); return }
        guard let table = CGPDFOperatorTableCreate() else { unknown("PDF tarayıcısı oluşturulamadı."); return }
        defer { CGPDFOperatorTableRelease(table) }
        let callbacks: [(String,CGPDFOperatorCallback)] = [
            ("q",{ _,info in PreflightScanner.context(info)?.save() }),
            ("Q",{ _,info in PreflightScanner.context(info)?.restore() }),
            ("cm",{ scanner,info in PreflightScanner.context(info)?.matrix(scanner) }),
            ("rg",{ _,info in PreflightScanner.context(info)?.rgb() }), ("RG",{ _,info in PreflightScanner.context(info)?.rgb() }),
            ("k",{ scanner,info in PreflightScanner.context(info)?.ink(scanner) }), ("K",{ scanner,info in PreflightScanner.context(info)?.ink(scanner) }),
            ("cs",{ scanner,info in PreflightScanner.context(info)?.space(scanner) }), ("CS",{ scanner,info in PreflightScanner.context(info)?.space(scanner) }),
            ("Do",{ scanner,info in PreflightScanner.context(info)?.object(scanner) }),
            ("gs",{ scanner,info in PreflightScanner.context(info)?.state(scanner) }),
            ("Tf",{ scanner,info in PreflightScanner.context(info)?.font(scanner) }),
            ("sh",{ _,info in PreflightScanner.context(info)?.unknown("Gölge/desen renkleri ve mürekkep kaplaması kontrol edilemedi.") }),
            ("BI",{ _,info in PreflightScanner.context(info)?.unknown("Satır içi görüntünün rengi ve çözünürlüğü kontrol edilemedi.") })
        ]
        for (key,callback) in callbacks { CGPDFOperatorTableSetCallback(table,key,callback) }
        let scanner = CGPDFScannerCreate(content,table,Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        depth += 1
        if !CGPDFScannerScan(scanner) { unknown("PDF içerik akışının bir bölümü kontrol edilemedi.") }
        if operations > 100_000 { unknown("Karmaşık içerik sınırı: kalan öğeler kontrol edilemedi.") }
        depth -= 1
    }
    static func context(_ pointer: UnsafeMutableRawPointer?) -> PreflightScanner? {
        guard let pointer else { return nil }
        let context = Unmanaged<PreflightScanner>.fromOpaque(pointer).takeUnretainedValue()
        context.operations += 1
        return context.operations <= 100_000 && !Task.isCancelled ? context : nil
    }
    func save() { if stack.count < 1000 { stack.append(ctm) } else { unknown("Grafik durum yığını kontrol edilemedi.") } }
    func restore() { if let value = stack.popLast() { ctm = value } }
    func matrix(_ scanner: CGPDFScannerRef) {
        var values = [CGPDFReal](repeating: 0,count: 6)
        for index in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner,&values[index]) else { unknown("Görüntü yerleşim dönüşümü kontrol edilemedi."); return } }
        ctm = CGAffineTransform(a: values[0],b: values[1],c: values[2],d: values[3],tx: values[4],ty: values[5]).concatenating(ctm)
    }
    func rgb() { add("rgb","RGB görüntü veya renk var; ofset için CMYK dönüşümünü kontrol edin.") }
    func ink(_ scanner: CGPDFScannerRef) {
        var values = [CGPDFReal](repeating: 0,count: 4)
        for index in (0..<4).reversed() { guard CGPDFScannerPopNumber(scanner,&values[index]) else { unknown("CMYK mürekkep değeri kontrol edilemedi."); return } }
        if values.reduce(0,+) > 3.000001 && values[3] > 0 {
            add("ink","Zengin siyah / CMYK toplam mürekkep %300 üzerinde (vektör renk, en iyi çaba).")
        }
    }
    func resource(_ scanner: CGPDFScannerRef,_ category: String,_ key: UnsafePointer<CChar>) -> CGPDFObjectRef? {
        CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner),category,key)
    }
    func colorSpace(_ object: CGPDFObjectRef?,content: CGPDFContentStreamRef,level: Int = 0) {
        guard let object,level < 8 else { unknown("Renk uzayı kontrol edilemedi."); return }
        var text: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object,.name,&text),let text {
            let value = String(cString: text)
            if ["DeviceRGB","RGB","CalRGB"].contains(value) { rgb() }
            else if !["DeviceGray","G","DeviceCMYK","CMYK"].contains(value) {
                if let resolved = CGPDFContentStreamGetResource(content,"ColorSpace",text) { colorSpace(resolved,content: content,level: level+1) }
                else { unknown("\(value) renk uzayı kontrol edilemedi.") }
            }
            return
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object,.array,&array),let array else { unknown("Renk uzayı kontrol edilemedi."); return }
        var first: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array,0,&first),let first else { unknown("Renk uzayı kontrol edilemedi."); return }
        switch String(cString: first) {
        case "Separation","DeviceN": add("spot","Spot / özel renk var; renk ayrımlarını kontrol edin.")
        case "CalRGB": rgb()
        case "ICCBased":
            var stream: CGPDFStreamRef?
            if CGPDFArrayGetStream(array,1,&stream),let stream,let profile = CGPDFStreamGetDictionary(stream),number(profile,"N") == 3 { rgb() }
            unknown("ICC profil dönüşümü ve gerçek mürekkep kaplaması kontrol edilemedi.")
        case "Indexed":
            var base: CGPDFObjectRef?
            if CGPDFArrayGetObject(array,1,&base) { colorSpace(base,content: content,level: level+1) }
        default: unknown("\(String(cString: first)) renk uzayı kontrol edilemedi.")
        }
    }
    func space(_ scanner: CGPDFScannerRef) {
        var key: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner,&key),let key else { unknown("Renk uzayı seçimi kontrol edilemedi."); return }
        let text = String(cString: key)
        if ["DeviceRGB","RGB"].contains(text) { rgb(); return }
        if ["DeviceCMYK","DeviceGray"].contains(text) { return }
        colorSpace(resource(scanner,"ColorSpace",key),content: CGPDFScannerGetContentStream(scanner))
    }
    func state(_ scanner: CGPDFScannerRef) {
        var key: UnsafePointer<CChar>?,value: CGPDFDictionaryRef?
        guard CGPDFScannerPopName(scanner,&key),let key,let object = resource(scanner,"ExtGState",key),CGPDFObjectGetValue(object,.dictionary,&value),let value else {
            unknown("Saydamlık durumu kontrol edilemedi."); return
        }
        transparency(value)
    }
    func font(_ scanner: CGPDFScannerRef) {
        var size: CGPDFReal = 0,key: UnsafePointer<CChar>?,value: CGPDFDictionaryRef?
        guard CGPDFScannerPopNumber(scanner,&size),CGPDFScannerPopName(scanner,&key),let key,
              let object = resource(scanner,"Font",key),CGPDFObjectGetValue(object,.dictionary,&value),let value else {
            unknown("Yazı tipi gömme durumu kontrol edilemedi."); return
        }
        if name(value,"Subtype") == "Type3" { return } // glyph programs are embedded PDF content
        var font = value,array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(value,"DescendantFonts",&array),let array {
            var child: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(array,0,&child),let child { font = child }
            else { unknown("CID yazı tipi gömme durumu kontrol edilemedi."); return }
        }
        let descriptor = dictionary(font,"FontDescriptor")
        let embedded = ["FontFile","FontFile2","FontFile3"].contains { key in
            guard let descriptor else { return false }
            var stream: CGPDFStreamRef?
            return CGPDFDictionaryGetStream(descriptor,key,&stream)
        }
        if !embedded { add("font","Gömülü olmayan yazı tipi var: \(name(font,"BaseFont") ?? String(cString: key)).") }
    }
    func object(_ scanner: CGPDFScannerRef) {
        var key: UnsafePointer<CChar>?,stream: CGPDFStreamRef?
        guard CGPDFScannerPopName(scanner,&key),let key,let object = resource(scanner,"XObject",key),
              CGPDFObjectGetValue(object,.stream,&stream),let stream else { unknown("PDF nesnesi kontrol edilemedi."); return }
        guard let dict = CGPDFStreamGetDictionary(stream) else { unknown("PDF nesne sözlüğü kontrol edilemedi."); return }
        switch name(dict,"Subtype") {
        case "Image":
            var color: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dict,"ColorSpace",&color) { colorSpace(color,content: CGPDFScannerGetContentStream(scanner)) }
            let width = number(dict,"Width") ?? 0,height = number(dict,"Height") ?? 0
            let placedW = hypot(ctm.a,ctm.b),placedH = hypot(ctm.c,ctm.d)
            if width > 0,height > 0,placedW > 0,placedH > 0 {
                let dpi = min(width/placedW,height/placedH)*72
                if dpi < 250 { add("dpi","Düşük çözünürlüklü görüntü (< 250 dpi etkin); en düşük yaklaşık \(Int(max(0,dpi))) dpi.") }
            } else { unknown("Görüntünün etkin çözünürlüğü kontrol edilemedi.") }
            var mask: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(dict,"SMask",&mask) { add("transparency","Saydamlık / karışım etkisi var; baskı iş akışını kontrol edin.") }
            unknown("Görüntülerde toplam mürekkep kaplaması kontrol edilemedi.")
        case "Form":
            guard let activeResources = dictionary(dict,"Resources") ?? resources else {
                unknown("Form kaynakları kontrol edilemedi."); return
            }
            let savedResources = resources
            resources = activeResources
            let saved = ctm,savedStack = stack
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict,"Matrix",&array),let array,CGPDFArrayGetCount(array) == 6 {
                var values = [CGPDFReal](repeating: 0,count: 6)
                for index in 0..<6 { _ = CGPDFArrayGetNumber(array,index,&values[index]) }
                ctm = CGAffineTransform(a: values[0],b: values[1],c: values[2],d: values[3],tx: values[4],ty: values[5]).concatenating(ctm)
            }
            transparency(dict)
            let child = CGPDFContentStreamCreateWithStream(stream,activeResources,CGPDFScannerGetContentStream(scanner))
            scan(child)
            CGPDFContentStreamRelease(child)
            ctm = saved; stack = savedStack; resources = savedResources
        default: unknown("Desteklenmeyen PDF nesnesi kontrol edilemedi.")
        }
    }
}
