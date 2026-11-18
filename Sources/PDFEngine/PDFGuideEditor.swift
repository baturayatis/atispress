import Foundation
import CoreGraphics
import ImpositionCore

public enum SourcePreparationError:LocalizedError {
    case unsafeGuides,invalidGrid(String),unsupportedSource
    public var errorDescription:String? {
        switch self {
        case .unsafeGuides:return "Bu çizgiler güvenli şekilde gizlenemedi. Çizgileri tasarım programında kılavuza çevirip PDF'i yeniden kaydedin."
        case .invalidGrid(let message):return message
        case .unsupportedSource:return "Sayfa bölme şu anda tek sayfalı, tek kaynaklı düz PDF işleri içindir."
        }
    }
}
/// Incremental replacement keeps original resources and every unselected operator
/// byte-for-byte. Xref streams/object streams/encryption are deliberately refused.
struct PDFClassicFile {
    let data:Data
    var offsets:[Int:(Int,Int)] = [:]
    var root:String = ""
    var info:String?
    var previous:Int = 0
    var pages:[Int] = []
    enum StructureError: String, Error {
        case start = "PDF başlangıç çapraz başvurusu (startxref) eksik veya bozuk."
        case table = "PDF çapraz başvuru tablosu veya /Prev zinciri bozuk."
        case stream = "PDF çapraz başvuru akışı (/XRef) kullanıyor."
        case hybrid = "PDF karma çapraz başvuru yapısı (/XRefStm) kullanıyor."
        case signed = "PDF imza bayt aralığı (/ByteRange) içeriyor."
        case encrypted = "PDF şifreleme sözlüğü (/Encrypt) içeriyor."
        case pages = "PDF sayfa ağacı güvenli biçimde çözümlenemedi."
        case size = "PDF 64 MB renk düzenleme sınırını aşıyor."
    }

    init(_ data:Data) throws {
        guard data.count<64*1024*1024 else {throw StructureError.size}
        guard let text=String(data:data,encoding:.isoLatin1),let start=text.range(of:"startxref",options:.backwards),let position=Int(text[start.upperBound...].split(whereSeparator:{$0.isWhitespace}).first ?? "") else {throw StructureError.start}
        guard !text.contains("/ByteRange") else {throw StructureError.signed}
        self.data=data;previous=position
        var next:Int?=position,visited=Set<Int>()
        while let at=next {
            guard at>=0,at<data.count,visited.insert(at).inserted else {throw StructureError.table}
            let header = pdfTokens(data.subdata(in: at..<min(at + 4096, data.count)))
            if header.count >= 4, header[2].text == "obj",
               value("/Type", Array(header.dropFirst(3)))?.first?.text == "/XRef" { throw StructureError.stream }
            let tail=data.subdata(in:at..<data.count),tokens=pdfTokens(tail)
            guard tokens.first?.text=="xref",let trailer=tokens.firstIndex(where:{$0.text=="trailer"}) else {throw StructureError.table}
            var i=1
            while i<trailer {
                guard i+1<trailer,let first=Int(tokens[i].text),let count=Int(tokens[i+1].text),first>=0,first<=Int(Int32.max),count>=0,count<1_000_000 else {throw StructureError.table};i+=2
                for n in 0..<count {
                    guard i+2<trailer,let offset=Int(tokens[i].text),let generation=Int(tokens[i+1].text) else {throw StructureError.table}
                    if offsets[first+n]==nil { offsets[first+n] = tokens[i+2].text=="n" ? (offset,generation):(-1,generation) };i+=3
                }
            }
            let dict=Array(tokens[(trailer+1)...])
            if value("/Encrypt",dict) != nil {throw StructureError.encrypted}
            if value("/XRefStm",dict) != nil {throw StructureError.hybrid}
            if root.isEmpty,let r=value("/Root",dict) {root=r.map(\.text).joined(separator:" ")}
            if info==nil,let r=value("/Info",dict) {info=r.map(\.text).joined(separator:" ")}
            next=value("/Prev",dict).flatMap{$0.first}.flatMap{Int($0.text)}
        }
        guard let rootID=Int(root.split(separator:" ").first ?? ""),let catalog=try? dictionary(rootID),let pageID=reference("/Pages",catalog) else {throw StructureError.pages}
        var seen=Set<Int>()
        func descend(_ id:Int, depth:Int) throws {
            guard depth<64,seen.insert(id).inserted,seen.count<100_000 else {throw StructureError.pages}
            guard let d=try? dictionary(id,maximumBytes:256*1024) else {throw StructureError.pages}
            let t=pdfTokens(d)
            if value("/Type",t)?.first?.text=="/Page" {pages.append(id);return}
            guard let kids=value("/Kids",t) else {throw StructureError.pages}
            for i in kids.indices where kids[i].text=="R" {
                guard i>=2,let child=Int(kids[i-2].text) else {throw StructureError.pages};try descend(child,depth:depth+1)
            }
        }
        try descend(pageID,depth:0)
    }
    func dictionary(_ id:Int, maximumBytes: Int = .max) throws -> Data {
        guard let (offset,_) = offsets[id],offset>=0,offset<data.count else {throw SourcePreparationError.unsafeGuides}
        let limit=offsets.values.map(\.0).filter{$0>offset}.min() ?? data.count
        let end = offset + min(maximumBytes, min(limit, data.count) - offset)
        let section=data.subdata(in:offset..<end),tokens=pdfTokens(section)
        guard tokens.count>=4,Int(tokens[0].text)==id,tokens[2].text=="obj",let start=tokens.firstIndex(where:{$0.text=="<<"}) else {throw SourcePreparationError.unsafeGuides}
        var depth=0
        for i in start..<tokens.count {if tokens[i].text=="<<" {depth+=1};if tokens[i].text==">>" {depth-=1;if depth==0 {return section.subdata(in:tokens[start].range.lowerBound..<tokens[i].range.upperBound)}}}
        throw SourcePreparationError.unsafeGuides
    }
    func reference(_ name:String,_ data:Data) -> Int? {value(name,pdfTokens(data))?.first.flatMap{Int($0.text)}}
    func value(_ name:String,_ tokens:[PDFContentToken]) -> [PDFContentToken]? {
        var depth=0
        for i in tokens.indices {
            let text=tokens[i].text
            if text=="<<" || text=="[" {depth+=1};if text==">>" || text=="]" {depth-=1}
            guard depth==1,text==name,i+1<tokens.count else {continue}
            let begin=i+1,first=tokens[begin].text
            if first=="<<" || first=="[" {
                var n=0
                for end in begin..<tokens.count {
                    if tokens[end].text=="<<" || tokens[end].text=="[" {n+=1};if tokens[end].text==">>" || tokens[end].text=="]" {n-=1}
                    if n==0 {return Array(tokens[begin...end])}
                }
                return nil
            }
            if begin+2<tokens.count,Int(first) != nil,Int(tokens[begin+1].text) != nil,tokens[begin+2].text=="R" {return Array(tokens[begin...begin+2])}
            return [tokens[begin]]
        }
        return nil
    }
    func replacing(_ contents:[Int:Data]) throws -> Data {
        var output=data;output.append(Data("\n".utf8));var entries:[Int:(Int,Int)]=[:]
        var next=(offsets.keys.max() ?? 0)+1
        for number in contents.keys.sorted() {
            guard pages.indices.contains(number-1),let stream=contents[number] else {throw SourcePreparationError.unsafeGuides}
            let pageID=pages[number-1],generation=offsets[pageID]!.1
            var dictionary=try self.dictionary(pageID)
            if let old=value("/Contents",pdfTokens(dictionary)),let first=old.first,let last=old.last {dictionary.replaceSubrange(first.range.lowerBound..<last.range.upperBound,with:Data("\(next) 0 R".utf8))}
            else {dictionary.insert(contentsOf:Data(" /Contents \(next) 0 R ".utf8),at:dictionary.count-2)}
            entries[next]=(output.count,0)
            output.append(Data("\(next) 0 obj\n<< /Length \(stream.count) >>\nstream\n".utf8));output.append(stream);output.append(Data("\nendstream\nendobj\n".utf8))
            entries[pageID]=(output.count,generation)
            output.append(Data("\(pageID) \(generation) obj\n".utf8));output.append(dictionary);output.append(Data("\nendobj\n".utf8));next+=1
        }
        return appendingXref(to: output, entries: entries, size: next)
    }

    func appendingXref(to body: Data, entries: [Int: (Int, Int)], size: Int) -> Data {
        var output = body
        let xref=output.count;output.append(Data("xref\n".utf8))
        for id in entries.keys.sorted() {let (offset,generation)=entries[id]!;output.append(Data(String(format:"%d 1\n%010d %05d n \n",id,offset,generation).utf8))}
        output.append(Data("trailer\n<< /Size \(size) /Root \(root) /Prev \(previous) \(info.map{"/Info "+$0} ?? "") >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return output
    }
}
public enum PDFGuideEditor {
    public static func canVerify(_ document:CGPDFDocument) -> Bool {
        (1...document.numberOfPages).allSatisfy { n in
            guard let page=document.page(at:n) else {return false}
            let box=page.getBoxRect(.mediaBox),w=ceil(box.width*25.4/72*8),h=ceil(box.height*25.4/72*8)
            return w>0 && h>0 && w<=4000 && h<=4000 && w*h<=8_000_000
        }
    }
    public static func supports(_ url:URL) -> Bool { (try? PDFClassicFile(Data(contentsOf:url))) != nil }
    public static func hiddenCopy(source:URL,destination:URL,analysis:PDFGuideAnalysis,groups:Set<String>) throws {
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else {throw PDFExportError.sourceOverwrite}
        guard !groups.isEmpty,groups.allSatisfy({id in analysis.groups.contains{$0.id==id && $0.canHide}}) else {throw SourcePreparationError.unsafeGuides}
        let bytes=try Data(contentsOf:source)
        guard let provider=CGDataProvider(data:bytes as CFData),let doc=CGPDFDocument(provider),!doc.isEncrypted else {throw SourcePreparationError.unsafeGuides}
        let current=PDFGuideDetector.inspect(doc)
        let before=analysis.strokes.filter{groups.contains($0.groupID)},now=current.strokes.filter{groups.contains($0.groupID)}
        guard !before.isEmpty,before.count==now.count,groups.allSatisfy({id in current.groups.contains{$0.id==id && $0.canHide}}),zip(before,now).allSatisfy({a,b in
            a.page==b.page && a.groupID==b.groupID && a.paintRange==b.paintRange && a.bounds==b.bounds && a.segments.count==b.segments.count && zip(a.segments,b.segments).allSatisfy{$0.0==$1.0 && $0.1==$1.1}
        }) else {throw SourcePreparationError.unsafeGuides}
        guard let original=try? PDFClassicFile(bytes),original.pages.count==doc.numberOfPages else {throw SourcePreparationError.unsafeGuides}
        var changed:[Int:Data]=[:]
        for number in Set(analysis.strokes.filter{groups.contains($0.groupID)}.map(\.page)) {
            guard let page=doc.page(at:number),var data=pdfPageContent(page) else {throw SourcePreparationError.unsafeGuides}
            for stroke in analysis.strokes.filter({$0.page==number && groups.contains($0.groupID)}).sorted(by:{$0.paintRange.lowerBound>$1.paintRange.lowerBound}) {data.replaceSubrange(stroke.paintRange,with:Data("n".utf8))}
            changed[number]=data
        }
        try original.replacing(changed).write(to:destination,options:.atomic)
        guard let hidden=CGPDFDocument(destination as CFURL),hidden.numberOfPages==doc.numberOfPages else {try? FileManager.default.removeItem(at:destination);throw SourcePreparationError.unsafeGuides}
        do {
            // Comparison is exact outside conservative stroke bounds at two scales.
            // Oversize pages are refused, never checked using downsampled pixels.
            for page in changed.keys.sorted() {for scale in [4.0,8.0] {
                guard try outsidePixelsIdentical(original:doc.page(at:page)!,modified:hidden.page(at:page)!,page:page,analysis:analysis,groups:groups,pixelsPerMM:scale) else {throw SourcePreparationError.unsafeGuides}
            }}
        } catch {try? FileManager.default.removeItem(at:destination);throw error}
    }
    public static func outsidePixelsIdentical(original:CGPDFPage,modified:CGPDFPage,page:Int,analysis:PDFGuideAnalysis,groups:Set<String>,pixelsPerMM:Double) throws -> Bool {
        let media=original.getBoxRect(.mediaBox),rotated=abs(original.rotationAngle%180)==90
        let size=CGSize(width:(rotated ? media.height:media.width)*25.4/72,height:(rotated ? media.width:media.height)*25.4/72)
        let width=Int(ceil(size.width*pixelsPerMM)),height=Int(ceil(size.height*pixelsPerMM))
        guard width>0,height>0,width<=4000,height<=4000,width*height<=8_000_000 else {throw SourcePreparationError.unsafeGuides}
        func render(_ p:CGPDFPage) throws -> CGContext {
            guard let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw SourcePreparationError.unsafeGuides}
            c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
            let native=CGSize(width:size.width*PDFPreviewDrawing.pointsPerMM,height:size.height*PDFPreviewDrawing.pointsPerMM)
            c.scaleBy(x:pixelsPerMM/PDFPreviewDrawing.pointsPerMM,y:pixelsPerMM/PDFPreviewDrawing.pointsPerMM)
            c.concatenate(p.getDrawingTransform(.mediaBox,rect:CGRect(origin:.zero,size:native),rotate:0,preserveAspectRatio:true));c.drawPDFPage(p);return c
        }
        let a=try render(original),b=try render(modified),pa=a.data!.assumingMemoryBound(to:UInt8.self),pb=b.data!.assumingMemoryBound(to:UInt8.self)
        // Stroke geometry is stored in displayed TrimBox coordinates. Include
        // MediaBox margins by composing the two Quartz transforms.
        let trim=original.getBoxRect(.trimBox),trimSize=CGSize(width:(rotated ? trim.height:trim.width)*25.4/72,height:(rotated ? trim.width:trim.height)*25.4/72)
        let trimToPDF=original.getDrawingTransform(.trimBox,rect:CGRect(origin:.zero,size:trimSize),rotate:0,preserveAspectRatio:true).inverted()
        let native=CGSize(width:size.width*PDFPreviewDrawing.pointsPerMM,height:size.height*PDFPreviewDrawing.pointsPerMM)
        let toPixel=trimToPDF.concatenating(original.getDrawingTransform(.mediaBox,rect:CGRect(origin:.zero,size:native),rotate:0,preserveAspectRatio:true)).concatenating(CGAffineTransform(scaleX:pixelsPerMM/PDFPreviewDrawing.pointsPerMM,y:pixelsPerMM/PDFPreviewDrawing.pointsPerMM))
        let segments=analysis.strokes.filter{$0.page==page && groups.contains($0.groupID)}.flatMap {stroke -> [(CGPoint,CGPoint,Double)] in
            let width=analysis.groups.first(where:{$0.id==stroke.groupID})?.width ?? 0.5
            let padding=max(0.15,width*25.4/72*5)*max(hypot(toPixel.a,toPixel.b),hypot(toPixel.c,toPixel.d))+1
            return stroke.segments.map {(CGPoint(x:$0.0.x,y:$0.0.y).applying(toPixel),CGPoint(x:$0.1.x,y:$0.1.y).applying(toPixel),padding)}
        }
        func withinStroke(_ p:CGPoint) -> Bool {
            segments.contains {a,b,radius in
                let dx=b.x-a.x,dy=b.y-a.y,d=dx*dx+dy*dy
                let t=d>0 ? max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/d)):0
                return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)<=radius
            }
        }
        for y in 0..<height {for x in 0..<width {
            let i=y*a.bytesPerRow+x*4
            if pa[i] == pb[i] && pa[i+1] == pb[i+1] && pa[i+2] == pb[i+2] && pa[i+3] == pb[i+3] {continue}
            // Bitmap storage starts at the top; PDF display coordinates start at the bottom.
            guard withinStroke(CGPoint(x:Double(x)+0.5,y:Double(height-y)-0.5)) else {return false}
        }}
        return true
    }
}
