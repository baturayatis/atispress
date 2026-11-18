import Foundation
import CoreGraphics
import ImpositionCore

public struct PDFGuideStroke:Sendable {
    public var page:Int
    public var groupID:String
    public var bounds:Rect
    public var segments:[(Point,Point)]
    public var rectangle:Rect?
    var paintRange:Range<Int>
}
public struct PDFGuideGroup:Identifiable,Sendable {
    public var id:String
    public var color:[Double]
    public var width:Double
    public var layer:String
    public var role:String
    public var count:Int
    public var canHide:Bool
}
public struct PDFGuideAnalysis:Sendable {
    public var strokes:[PDFGuideStroke] = []
    public var groups:[PDFGuideGroup] = []
    public var artworkBounds:[Rect] = []
    var regionBounds: [Rect] = []
    public var hasImages = false
    public var unsupported = false
    public var rasterFramesSuspected = false
    public var count:Int { strokes.count }
    public func hit(page:Int,point:Point,tolerance:Double = 1.5) -> String? {
        strokes.filter { $0.page == page }.reversed().first { stroke in stroke.segments.contains { a,b in
            let dx=b.x-a.x,dy=b.y-a.y,d=dx*dx+dy*dy
            let t=d>0 ? max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/d)) : 0
            return hypot(point.x-a.x-t*dx,point.y-a.y-t*dy)<=tolerance
        } }?.groupID
    }
    public struct Learned:Sendable { public var page:Int; public var trim:Size; public var bleed:Double; public var outer:Rect; public var inner:Rect }
    public var learned:[Learned] {
        let outer = strokes.filter { $0.rectangle != nil }
        var result:[Learned] = []
        for stroke in outer {
            guard groups.first(where: { $0.id == stroke.groupID })?.role == "taşma sınırı",let a = stroke.rectangle else { continue }
            for inside in strokes where inside.page == stroke.page {
                guard groups.first(where: { $0.id == inside.groupID })?.role == "kesim",let b = inside.rectangle else { continue }
                let gaps = [b.origin.x-a.origin.x,b.origin.y-a.origin.y,a.origin.x+a.size.width-b.origin.x-b.size.width,a.origin.y+a.size.height-b.origin.y-b.size.height]
                guard let lo=gaps.min(),let hi=gaps.max(),lo>0.1,hi-lo<0.25 else { continue }
                if !result.contains(where:{$0.page==stroke.page && abs($0.outer.origin.x-a.origin.x)<0.05 && abs($0.outer.origin.y-a.origin.y)<0.05 && abs($0.inner.origin.x-b.origin.x)<0.05 && abs($0.inner.origin.y-b.origin.y)<0.05 && abs($0.trim.width-b.size.width)<0.05 && abs($0.trim.height-b.size.height)<0.05}) {
                    result.append(Learned(page:stroke.page,trim:b.size,bleed:gaps.reduce(0,+)/4,outer:a,inner:b))
                }
            }
        }
        return result
    }
    public func suggestion(size:Size) -> PageSplitSettings? {
        if learned.count>1 {
            let centers = learned.map { Point($0.outer.origin.x+$0.outer.size.width/2,$0.outer.origin.y+$0.outer.size.height/2) }
            func distinct(_ values:[Double]) -> [Double] { var output:[Double]=[]; for v in values.sorted() where output.last.map({abs($0-v)>2}) ?? true { output.append(v) }; return output }
            let xs=distinct(centers.map(\.x)),ys=distinct(centers.map(\.y))
            if xs.count*ys.count == learned.count,xs.count<=12,ys.count<=12 {
                var split=PageSplitSettings(columns:xs.count,rows:ys.count,size:size)
                split.verticalCuts=zip(xs,xs.dropFirst()).map { ($0+$1)/2 }
                split.horizontalCuts=zip(ys,ys.dropFirst()).map { ($0+$1)/2 }
                split.cellBleed=learned[0].bleed; split.explicitTrim=learned[0].trim; split.learnedTrimCenters=centers
                split.assign(.row); return split
            }
        }
        let standards=[Size(90,50),Size(85,55),Size(85.6,54),Size(100,50),Size(50,30)]
        for trim in standards { for bleed in [3.0,0.0] {
            let w=trim.width+2*bleed,h=trim.height+2*bleed
            let cols=Int((size.width/w).rounded()),rows=Int((size.height/h).rounded())
            if (1...8).contains(cols),(1...8).contains(rows),cols*rows>1,abs(size.width-Double(cols)*w)<1.5,abs(size.height-Double(rows)*h)<1.5 {
                var split=PageSplitSettings(columns:cols,rows:rows,size:size); split.cellBleed=bleed; split.assign(.row); return split
            }
        } }
        return nil
    }
}

// Byte positions are retained so hiding can replace only a selected S/s paint
// operator with n. Strings, comments and dictionaries never become operators.
struct PDFContentToken {
    var text:String
    var range:Range<Int>
}
func pdfTokens(_ data:Data) -> [PDFContentToken] {
    let bytes=[UInt8](data); var i=0,result:[PDFContentToken]=[]
    func white(_ c:UInt8) -> Bool { [0,9,10,12,13,32].contains(c) }
    func delimiter(_ c:UInt8) -> Bool { white(c) || [40,41,60,62,91,93,123,125,47,37].contains(c) }
    while i<bytes.count {
        if white(bytes[i]) { i+=1; continue }
        if bytes[i]==37 { while i<bytes.count && bytes[i] != 10 && bytes[i] != 13 { i+=1 }; continue }
        let start=i,c=bytes[i]; i+=1
        if c==40 {
            var depth=1
            while i<bytes.count && depth>0 { if bytes[i]==92 { i=min(bytes.count,i+2); continue }; if bytes[i]==40 {depth+=1}; if bytes[i]==41 {depth-=1}; i+=1 }
        } else if c==60,i<bytes.count,bytes[i] != 60 { while i<bytes.count && bytes[i] != 62 {i+=1}; i=min(bytes.count,i+1) }
        else if (c==60 || c==62),i<bytes.count,bytes[i]==c {i+=1}
        else if c==47 { while i<bytes.count && !delimiter(bytes[i]) {i+=1} }
        else if !delimiter(c) { while i<bytes.count && !delimiter(bytes[i]) {i+=1} }
        let text=String(bytes:bytes[start..<i],encoding:.isoLatin1) ?? ""
        result.append(PDFContentToken(text:text,range:start..<i))
        if text=="BI" { break } // Binary inline images need a dedicated decoder.
    }
    return result
}
func pdfPageContent(_ page:CGPDFPage) -> Data? {
    guard let dictionary=page.dictionary else {return nil}
    var object:CGPDFObjectRef?
    guard CGPDFDictionaryGetObject(dictionary,"Contents",&object),let object else {return Data()}
    var streams:[CGPDFStreamRef]=[]
    if CGPDFObjectGetType(object) == .stream { var stream:CGPDFStreamRef?; if CGPDFObjectGetValue(object,.stream,&stream),let stream {streams=[stream]} }
    else if CGPDFObjectGetType(object) == .array {
        var array:CGPDFArrayRef?
        if CGPDFObjectGetValue(object,.array,&array),let array { for i in 0..<CGPDFArrayGetCount(array) {var stream:CGPDFStreamRef?; guard CGPDFArrayGetStream(array,i,&stream),let stream else {return nil}; streams.append(stream)} }
    } else {return nil}
    var data=Data()
    for stream in streams {var format=CGPDFDataFormat.raw; guard let bytes=CGPDFStreamCopyData(stream,&format),format == .raw else {return nil}; data.append(bytes as Data); data.append(10)}
    return data
}
public enum PDFGuideDetector {
    public static func inspect(_ document:CGPDFDocument) -> PDFGuideAnalysis {
        var output=PDFGuideAnalysis()
        for number in 1...document.numberOfPages {
            if number>2000 {output.unsupported=true;break}
            guard let page=document.page(at:number),let data=pdfPageContent(page) else {output.unsupported=true;continue}
            let trim=page.getBoxRect(.trimBox),rotated=abs(page.rotationAngle%180)==90
            let size=CGSize(width:(rotated ? trim.height:trim.width)*25.4/72,height:(rotated ? trim.width:trim.height)*25.4/72)
            let view=page.getDrawingTransform(.trimBox,rect:CGRect(origin:.zero,size:size),rotate:0,preserveAspectRatio:true)
            var resource:CGPDFDictionaryRef?,ancestor=page.dictionary,group:CGPDFDictionaryRef?
            for _ in 0..<32 {guard let d=ancestor else {break};if CGPDFDictionaryGetDictionary(d,"Resources",&resource) {break};var parent:CGPDFDictionaryRef?;_ = CGPDFDictionaryGetDictionary(d,"Parent",&parent);ancestor=parent}
            let unsafe=page.dictionary.map {CGPDFDictionaryGetDictionary($0,"Group",&group)} ?? false
            merge(scan(data:data,number:number,view:view,resource:resource,matrix:.identity,layer:"",depth:0,scope:"",unsafe:unsafe,clip:page.getBoxRect(.mediaBox),collectRegions:document.numberOfPages==1),into:&output)
        }
        if output.hasImages,output.strokes.isEmpty,document.numberOfPages==1,let page=document.page(at:1) {output.rasterFramesSuspected=rasterFrames(page)}
        return output
    }
    private static func merge(_ other:PDFGuideAnalysis,into output:inout PDFGuideAnalysis) {
        output.strokes+=other.strokes;output.artworkBounds+=other.artworkBounds;output.regionBounds+=other.regionBounds.prefix(max(0,601-output.regionBounds.count))
        output.hasImages = output.hasImages || other.hasImages;output.unsupported = output.unsupported || other.unsupported
        for group in other.groups {
            if let i=output.groups.firstIndex(where:{$0.id==group.id}) {output.groups[i].count+=group.count;output.groups[i].canHide = output.groups[i].canHide && group.canHide}
            else {output.groups.append(group)}
        }
    }
    private static func scan(data:Data,number:Int,view:CGAffineTransform,resource:CGPDFDictionaryRef?,matrix:CGAffineTransform,layer:String,depth:Int,scope:String,unsafe:Bool,clip:CGRect?,collectRegions:Bool) -> PDFGuideAnalysis {
        var output=PDFGuideAnalysis()
        guard data.count<=4*1024*1024 else {output.unsupported=true;return output}
            struct State { var matrix=CGAffineTransform.identity; var width=1.0; var rgb=[0.0,0,0]; var layer=""; var components=1; var clip:CGRect? }
            var state=State(),stack:[State]=[],layerStack:[String]=[],args:[PDFContentToken]=[],path=CGMutablePath(),segments:[(CGPoint,CGPoint)]=[],current=CGPoint.zero,begin=CGPoint.zero,rectangle:CGRect?,pageUnsafe=unsafe,curved=false
            state.matrix=matrix;state.layer=layer;state.clip=clip
            func point(_ x:Double,_ y:Double) -> CGPoint { CGPoint(x:x,y:y).applying(state.matrix) }
            func rect(_ r:CGRect) -> Rect { Rect(x:r.minX,y:r.minY,width:r.width,height:r.height) }
            var curveBounds = CGRect.null
            func clear() {path=CGMutablePath();segments=[];rectangle=nil;curved=false;curveBounds = .null}
            func recordRegion(_ bounds: CGRect) {
                guard collectRegions, output.regionBounds.count <= 600 else { return }
                let clipped = state.clip.map { bounds.intersection($0) } ?? bounds
                guard !clipped.isNull, !clipped.isEmpty else { return }
                output.regionBounds.append(rect(clipped.applying(view)))
            }
            func value(_ n:Int) -> Double {Double(args[n].text) ?? 0}
            func components(_ name:String) -> Int {
                if name=="/DeviceRGB" {return 3};if name=="/DeviceCMYK" {return 4};if name=="/DeviceGray" {return 1}
                guard let resource else {return 0};var spaces:CGPDFDictionaryRef?,object:CGPDFObjectRef?
                guard CGPDFDictionaryGetDictionary(resource,"ColorSpace",&spaces),let spaces,CGPDFDictionaryGetObject(spaces,String(name.dropFirst()),&object),let object else {return 0}
                if CGPDFObjectGetType(object) == .name {var n:UnsafePointer<CChar>?;if CGPDFObjectGetValue(object,.name,&n),let n {let s=String(cString:n);return s=="DeviceRGB" ? 3:s=="DeviceCMYK" ? 4:s=="DeviceGray" ? 1:0}}
                var array:CGPDFArrayRef?
                if CGPDFObjectGetValue(object,.array,&array),let array {var kind:UnsafePointer<CChar>?;if CGPDFArrayGetName(array,0,&kind),let kind,String(cString:kind)=="ICCBased" {var stream:CGPDFStreamRef?;if CGPDFArrayGetStream(array,1,&stream),let stream,let streamDictionary=CGPDFStreamGetDictionary(stream) {var n:CGPDFInteger=0;if CGPDFDictionaryGetInteger(streamDictionary,"N",&n) {return n}}}}
                return 0
            }
            let tokens=pdfTokens(data)
            for token in tokens {
                if Double(token.text) != nil || token.text.hasPrefix("/") || token.text.hasPrefix("(") || token.text.hasPrefix("<") || ["[","]",">>"].contains(token.text) {args.append(token);continue}
                switch token.text {
                case "q": stack.append(state)
                case "Q": if let saved=stack.popLast() {state=saved}
                case "cm" where args.count==6: state.matrix=CGAffineTransform(a:value(0),b:value(1),c:value(2),d:value(3),tx:value(4),ty:value(5)).concatenating(state.matrix)
                case "w" where args.count==1:state.width=value(0)
                case "CS" where args.count==1:state.components=components(args[0].text)
                case "SC","SCN":
                    if state.components==3,args.count==3 {state.rgb=(0..<3).map(value)}
                    else if state.components==4,args.count==4 {state.rgb=(0..<3).map {1-min(1,value($0)+value(3))}}
                    else if state.components==1,args.count==1 {state.rgb=Array(repeating:value(0),count:3)}
                    else {state.rgb=[0,0,0]}
                case "RG" where args.count==3:state.rgb=(0..<3).map(value);state.components=3
                case "G" where args.count==1:state.rgb=Array(repeating:value(0),count:3);state.components=1
                case "K" where args.count==4:state.rgb=(0..<3).map {1-min(1,value($0)+value(3))};state.components=4
                case "m" where args.count==2:current=point(value(0),value(1));begin=current;path.move(to:current)
                case "l" where args.count==2:let next=point(value(0),value(1));segments.append((current,next));path.addLine(to:next);current=next
                case "h":segments.append((current,begin));path.closeSubpath();current=begin
                case "re" where args.count==4:
                    let r=CGRect(x:value(0),y:value(1),width:value(2),height:value(3)).applying(state.matrix)
                    rectangle=path.isEmpty ? r:nil
                    let pts=[point(value(0),value(1)),point(value(0)+value(2),value(1)),point(value(0)+value(2),value(1)+value(3)),point(value(0),value(1)+value(3))]
                    path.move(to:pts[0]);for i in 1..<4 {path.addLine(to:pts[i])};path.closeSubpath();for i in 0..<4 {segments.append((pts[i],pts[(i+1)%4]))};current=pts[0];begin=current
                case "c","v","y":
                    curved = true // Curved paths are deliberately not offered for hiding.
                    if collectRegions {
                        let points = stride(from: 0, to: args.count - args.count % 2, by: 2).map { point(value($0), value($0 + 1)) }
                        for p in [current] + points { curveBounds = curveBounds.union(CGRect(origin: p, size: .zero)) }
                    }
                case "S","s":
                    if token.text=="s" {segments.append((current,begin));path.closeSubpath()}
                    if rectangle == nil,segments.count==4,segments.allSatisfy({abs($0.0.x-$0.1.x)<0.001 || abs($0.0.y-$0.1.y)<0.001}) { rectangle=path.boundingBoxOfPath }
                    let r=state.rgb,layer=state.layer.lowercased(),named=["guide","kılavuz","kilavuz","bleed","safe","trim"].contains {layer.contains($0)}
                    let magenta=r[0]>0.65 && r[2]>0.5 && r[1]<0.35
                    let pink=r[0]>0.75 && r[1]>0.35 && r[1]<0.93 && r[2]>0.55 && r[0]-r[1]>0.08
                    let cyan=r[1]>0.65 && r[2]>0.7 && r[0]<0.85 && r[2]-r[0]>0.08
                    let width=state.width*max(hypot(state.matrix.a,state.matrix.b),hypot(state.matrix.c,state.matrix.d))
                    let visible=segments.compactMap {a,b -> (CGPoint,CGPoint)? in
                        guard let clip=state.clip else {return (a,b)}
                        return clipped(a,b,to:clip.insetBy(dx:-width/2-0.001,dy:-width/2-0.001))
                    }
                    if width.isFinite && width>=0 && width<=0.500001 && !path.isEmpty && !curved && !visible.isEmpty && (magenta || pink || cyan || named) {
                        let role=magenta ? "taşma sınırı":pink ? "kesim":cyan ? "güvenli alan":layer.contains("bleed") ? "taşma sınırı":layer.contains("trim") ? "kesim":layer.contains("safe") ? "güvenli alan":"bilinmiyor"
                        let key=String(format:"%.4f-%.4f-%.4f-%.4f-",locale:Locale(identifier:"en_US_POSIX"),r[0],r[1],r[2],width)+state.layer
                        let bounds=path.boundingBoxOfPath.applying(view).insetBy(dx:-max(0.15,width*25.4/72*5),dy:-max(0.15,width*25.4/72*5))
                        output.strokes.append(PDFGuideStroke(page:number,groupID:key,bounds:rect(bounds),segments:visible.map {a,b in let x=a.applying(view),y=b.applying(view);return (Point(x.x,x.y),Point(y.x,y.y))},rectangle:rectangle.flatMap {r in (state.clip?.insetBy(dx:-0.01,dy:-0.01).contains(r) ?? true) ? rect(r.applying(view)):nil},paintRange:token.range))
                        if let i=output.groups.firstIndex(where:{$0.id==key}) {output.groups[i].count+=1}
                        else {output.groups.append(PDFGuideGroup(id:key,color:r,width:width,layer:state.layer,role:role,count:1,canHide:true))}
                    } else if !path.isEmpty {
                        output.artworkBounds.append(rect(path.boundingBoxOfPath.applying(view)))
                        recordRegion(path.boundingBoxOfPath.union(curveBounds).insetBy(dx: -width / 2, dy: -width / 2))
                    }
                    clear()
                case "f","F","f*","B","B*","b","b*":
                    if !path.isEmpty {
                        output.artworkBounds.append(rect(path.boundingBoxOfPath.applying(view)))
                        recordRegion(path.boundingBoxOfPath.union(curveBounds))
                    }
                    clear()
                case "W","W*":
                    let box=path.boundingBoxOfPath
                    if !box.isNull {state.clip=state.clip.map{$0.intersection(box)} ?? box}
                    if rectangle==nil {pageUnsafe=true}
                case "n":clear()
                case "gs","sh","BI":pageUnsafe=true
                case "Do":
                    var objects:CGPDFDictionaryRef?,stream:CGPDFStreamRef?,subtype:UnsafePointer<CChar>?
                    if let resource,let name=args.first?.text,CGPDFDictionaryGetDictionary(resource,"XObject",&objects),let objects,CGPDFDictionaryGetStream(objects,String(name.dropFirst()),&stream),let stream,let dict=CGPDFStreamGetDictionary(stream),CGPDFDictionaryGetName(dict,"Subtype",&subtype),let subtype {
                        if String(cString:subtype)=="Image" {
                            output.hasImages=true
                            recordRegion(CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.matrix))
                        }
                        else if String(cString:subtype)=="Form",depth<8 {
                            var format=CGPDFDataFormat.raw,formResources:CGPDFDictionaryRef?,array:CGPDFArrayRef?
                            if let formData=CGPDFStreamCopyData(stream,&format),format == .raw {
                                var fm=CGAffineTransform.identity
                                if CGPDFDictionaryGetArray(dict,"Matrix",&array),let array,CGPDFArrayGetCount(array)==6 {
                                    var v=[CGPDFReal](repeating:0,count:6);for i in 0..<6 {_ = CGPDFArrayGetNumber(array,i,&v[i])};fm=CGAffineTransform(a:v[0],b:v[1],c:v[2],d:v[3],tx:v[4],ty:v[5])
                                }
                                _ = CGPDFDictionaryGetDictionary(dict,"Resources",&formResources)
                                let nested=scan(data:formData as Data,number:number,view:view,resource:formResources ?? resource,matrix:fm.concatenating(state.matrix),layer:state.layer,depth:depth+1,scope:scope+name+"/",unsafe:true,clip:formClip(dict,matrix:fm.concatenating(state.matrix),parent:state.clip),collectRegions:collectRegions)
                                merge(nested,into:&output)
                            } else {output.unsupported=true}
                        } else {output.unsupported=true}
                    } else {output.unsupported=true}
                case "BDC":
                    layerStack.append(state.layer)
                    if args.count>=2,args[0].text=="/OC",let resource {
                        var properties:CGPDFDictionaryRef?,oc:CGPDFDictionaryRef?,name:CGPDFStringRef?
                        if CGPDFDictionaryGetDictionary(resource,"Properties",&properties),let properties,CGPDFDictionaryGetDictionary(properties,String(args[1].text.dropFirst()),&oc),let oc,CGPDFDictionaryGetString(oc,"Name",&name),let name,let text=CGPDFStringCopyTextString(name) {state.layer=text as String}
                    }
                case "BMC":layerStack.append(state.layer)
                case "EMC":state.layer=layerStack.popLast() ?? ""
                default:break
                }
                args=[]
            }
        if pageUnsafe {for i in output.groups.indices {output.groups[i].canHide=false};output.unsupported=true}
        return output
    }
    private static func formClip(_ dictionary:CGPDFDictionaryRef,matrix:CGAffineTransform,parent:CGRect?) -> CGRect? {
        var array:CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary,"BBox",&array),let array,CGPDFArrayGetCount(array)==4 else {return parent}
        var v=[CGPDFReal](repeating:0,count:4);for i in 0..<4 {_ = CGPDFArrayGetNumber(array,i,&v[i])}
        let box=CGRect(x:v[0],y:v[1],width:v[2]-v[0],height:v[3]-v[1]).applying(matrix)
        return parent.map{$0.intersection(box)} ?? box
    }
    private static func clipped(_ a:CGPoint,_ b:CGPoint,to box:CGRect) -> (CGPoint,CGPoint)? {
        guard !box.isNull else {return nil}
        let dx=b.x-a.x,dy=b.y-a.y
        let p=[-dx,dx,-dy,dy],q=[a.x-box.minX,box.maxX-a.x,a.y-box.minY,box.maxY-a.y]
        var lo=0.0,hi=1.0
        for i in 0..<4 {
            if abs(p[i])<0.0000001 {if q[i]<0 {return nil};continue}
            let r=q[i]/p[i]
            if p[i]<0 {lo=max(lo,r)} else {hi=min(hi,r)}
            if lo>hi {return nil}
        }
        return (CGPoint(x:a.x+lo*dx,y:a.y+lo*dy),CGPoint(x:a.x+hi*dx,y:a.y+hi*dy))
    }
    private static func rasterFrames(_ page:CGPDFPage) -> Bool {
        let box=page.getBoxRect(.trimBox),scale=min(1200/box.width,900/box.height),w=max(1,Int(box.width*scale)),h=max(1,Int(box.height*scale))
        guard let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let data=c.data else {return false}
        c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:w,height:h));c.concatenate(page.getDrawingTransform(.trimBox,rect:CGRect(x:0,y:0,width:w,height:h),rotate:0,preserveAspectRatio:true));c.drawPDFPage(page)
        let p=data.assumingMemoryBound(to:UInt8.self)
        func colored(_ x:Int,_ y:Int) -> Bool {
            let i=y*c.bytesPerRow+x*4,r=Double(p[i])/255,g=Double(p[i+1])/255,b=Double(p[i+2])/255
            return (r>0.8 && b>0.6 && r-g>0.04) || (b>0.8 && g>0.6 && b-r>0.04 && (b-g>0.04 || r<0.2))
        }
        var horizontal=0,vertical=0
        for y in 0..<h {var run=0,best=0;for x in 0..<w {run=colored(x,y) ? run+1:0;best=max(best,run)};if best>max(20,w/8) {horizontal+=1}}
        for x in 0..<w {var run=0,best=0;for y in 0..<h {run=colored(x,y) ? run+1:0;best=max(best,run)};if best>max(20,h/8) {vertical+=1}}
        return horizontal>=2 && horizontal<h/4 && vertical>=2 && vertical<w/4
    }
}
