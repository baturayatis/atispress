import Foundation
import CoreGraphics
import CoreText
import ImpositionCore

/// One canonical placement shared by the two faces. Geometry is independent of
/// visibility so preview switches cannot move the bar or alter export output.
public enum PDFColorControlRenderer {
    public struct PatchDefinition: Equatable, Sendable {
        public let name: String
        public let cmyk: [Double]
    }
    public static let patchDefinitions: [PatchDefinition] = [
        PatchDefinition(name: "C100",cmyk: [1,0,0,0]), PatchDefinition(name: "M100",cmyk: [0,1,0,0]),
        PatchDefinition(name: "Y100",cmyk: [0,0,1,0]), PatchDefinition(name: "K100",cmyk: [0,0,0,1]),
        PatchDefinition(name: "C50",cmyk: [0.5,0,0,0]), PatchDefinition(name: "M50",cmyk: [0,0.5,0,0]),
        PatchDefinition(name: "Y50",cmyk: [0,0,0.5,0]), PatchDefinition(name: "K50",cmyk: [0,0,0,0.5]),
        PatchDefinition(name: "B (C+M)",cmyk: [1,1,0,0]), PatchDefinition(name: "R (M+Y)",cmyk: [0,1,1,0]),
        PatchDefinition(name: "G (C+Y)",cmyk: [1,0,1,0]), PatchDefinition(name: "CMY gri",cmyk: [0.5,0.4,0.4,0])
    ]
    public struct Patch {
        public let bounds: CGRect
        public let definition: PatchDefinition
    }
    public struct Target {
        public let edge: Edge
        public let center: CGPoint
        public let size: Double
        public let strokeWidth: Double
        public var circleBounds: CGRect { CGRect(x: center.x-size/2,y: center.y-size/2,width: size,height: size) }
        public var bounds: CGRect { circleBounds.insetBy(dx: -strokeWidth/2,dy: -strokeWidth/2) }
    }
    public struct Geometry {
        public var patches: [Patch] = []
        public var targets: [Target] = []
        public var warnings: [String] = []
        public var barBounds: CGRect? {
            guard !patches.isEmpty else { return nil }
            return patches.reduce(CGRect.null) { $0.union($1.bounds) }
        }
        public var bounds: [CGRect] { patches.map(\.bounds)+targets.map(\.bounds) }
    }
    private static let unit = PDFPreviewDrawing.pointsPerMM
    private static func opposite(_ edge: Edge) -> Edge {
        switch edge { case .bottom: return .top; case .top: return .bottom; case .left: return .right; case .right: return .left }
    }
    private static func title(_ edge: Edge) -> String {
        switch edge { case .bottom: return "Alt"; case .top: return "Üst"; case .left: return "Sol"; case .right: return "Sağ" }
    }
    public static func geometry(sheet: Sheet,settings: ExportMarks,kind: SideKind = .front) -> Geometry {
        var result = Geometry()
        guard settings.colorBar || settings.registrationTargets else { return result }
        let paper = CGRect(x: 0.5,y: 0.5,width: sheet.size.width-1,height: sheet.size.height-1)
        guard sheet.diagnosticBounds == nil,paper.width.isFinite,paper.height.isFinite,paper.width > 0,paper.height > 0 else {
            result.warnings = ["Renk kontrol işaretleri için geçerli tabaka alanı yok; işaretler eklenmedi."]; return result
        }
        let stroke = max(0.01,settings.lineWidth.isFinite ? settings.lineWidth : 0.25)/unit
        func reflected(_ rect: CGRect) -> CGRect {
            CGRect(x: sheet.backFlipsX ? sheet.size.width-rect.maxX : rect.minX,
                y: sheet.backFlipsX ? rect.minY : sheet.size.height-rect.maxY,width: rect.width,height: rect.height)
        }
        func reflectedEdge(_ edge: Edge) -> Edge {
            if sheet.backFlipsX { return edge == .left ? .right : edge == .right ? .left : edge }
            return edge == .bottom ? .top : edge == .top ? .bottom : edge
        }
        let faces: [(Side,Bool)] = [(sheet.front,false),(sheet.back,true)]
        let artwork = faces.flatMap { side,back in
            side.slots.map { slot -> CGRect in
                let r: Rect? = slot.productionProtectedBounds
                let rect = CGRect(x: r?.origin.x ?? slot.x,y: r?.origin.y ?? slot.y,
                    width: r?.size.width ?? slot.size.width,height: r?.size.height ?? slot.size.height).insetBy(dx: -0.25,dy: -0.25)
                return back ? reflected(rect) : rect
            }
        }
        var protected = artwork
        var reserved = settings
        // Reserve planned crop ticks even when hidden; toggles never relocate controls.
        reserved.crop = true
        for (side,back) in faces {
            protected += side.punchMarks.map { mark in
                let b = mark.bounds
                let rect = CGRect(x:b.origin.x,y:b.origin.y,width:b.size.width,height:b.size.height).insetBy(dx:-0.25,dy:-0.25)
                return back ? reflected(rect) : rect
            }
            protected += PDFExportMarkRenderer.geometry(side: side,sheet: sheet,settings: reserved).segments.map {
                let rect = CGRect(x: min($0.start.x,$0.end.x)-stroke/2-0.25,y: min($0.start.y,$0.end.y)-stroke/2-0.25,
                    width: abs($0.end.x-$0.start.x)+stroke+0.5,height: abs($0.end.y-$0.start.y)+stroke+0.5)
                return back ? reflected(rect) : rect
            }
            if settings.pageNumbers {
                for (index,slot) in side.slots.enumerated() {
                    let text = "\(slot.sourcePageNumber.map(String.init) ?? "Boş") / \(index+1)"
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Menlo-Bold" as CFString,2,nil)]))
                    var a: CGFloat = 0,d: CGFloat = 0
                    let w = CTLineGetTypographicBounds(line,&a,&d,nil)
                    let rect = CGRect(x: slot.x+slot.size.width/2-w/2-0.25,
                        y: slot.productionProtectedBounds.origin.y-2-(a+d)/2-0.25,width: w+0.5,height: a+d+0.5)
                    protected.append(back ? reflected(rect) : rect)
                }
            }
        }
        let block = artwork.reduce(CGRect.null) { $0.union($1) }
        func band(_ edge: Edge) -> CGRect {
            guard !block.isNull else { return paper }
            switch edge {
            case .bottom: return CGRect(x: paper.minX,y: paper.minY,width: paper.width,height: max(0,block.minY-paper.minY))
            case .top: return CGRect(x: paper.minX,y: block.maxY,width: paper.width,height: max(0,paper.maxY-block.maxY))
            case .left: return CGRect(x: paper.minX,y: paper.minY,width: max(0,block.minX-paper.minX),height: paper.height)
            case .right: return CGRect(x: block.maxX,y: paper.minY,width: max(0,paper.maxX-block.maxX),height: paper.height)
            }
        }
        func fit(_ size: CGSize,edge: Edge,centered: Bool) -> CGRect? {
            let area = band(edge)
            guard size.width.isFinite,size.height.isFinite,size.width > 0,size.height > 0,
                  area.width >= size.width,area.height >= size.height else { return nil }
            let horizontal = edge == .bottom || edge == .top
            let length = horizontal ? size.width : size.height,thickness = horizontal ? size.height : size.width
            let lo = horizontal ? area.minX : area.minY,hi = horizontal ? area.maxX : area.maxY
            let normalLo = horizontal ? area.minY : area.minX,normalHi = horizontal ? area.maxY : area.maxX
            let midpoint = sheet.alignment == .center && !block.isNull ? (horizontal ? block.midX : block.midY) : (horizontal ? sheet.size.width/2 : sheet.size.height/2)
            var along = [midpoint-length/2]
            if !centered {
                along += [lo,hi-length]
                along += protected.flatMap { rect in
                    [ (horizontal ? rect.minX : rect.minY)-length-0.01,(horizontal ? rect.maxX : rect.maxY)+0.01 ]
                }
                along = Array(Set(along)).sorted { abs($0-(midpoint-length/2)) < abs($1-(midpoint-length/2)) ||
                    (abs($0-(midpoint-length/2)) == abs($1-(midpoint-length/2)) && $0 < $1) }
            }
            var normals = [normalLo,normalHi-thickness]
            normals += protected.flatMap { rect in [
                (horizontal ? rect.minY : rect.minX)-thickness-0.01,(horizontal ? rect.maxY : rect.maxX)+0.01 ] }
            let nearBlock = edge == .bottom || edge == .left ? normalHi-thickness : normalLo
            normals = Array(Set(normals)).filter { $0 >= normalLo && $0+thickness <= normalHi }
                .sorted {
                    if sheet.alignment == .center,!block.isNull {
                        if abs($0-nearBlock) != abs($1-nearBlock) { return abs($0-nearBlock)<abs($1-nearBlock) }
                    }
                    return edge == .bottom || edge == .left ? $0 < $1 : $0 > $1
                }
            for normal in normals {
                for start in along where start >= lo && start+length <= hi {
                    let rect = CGRect(x: horizontal ? start : normal,y: horizontal ? normal : start,width: size.width,height: size.height)
                    if paper.contains(rect),area.contains(rect),!protected.contains(where: { $0.intersects(rect) }) { return rect }
                }
            }
            return nil
        }
        var targets: [Target] = [],missing: [String] = []
        let targetSize = settings.targetSize
        if targetSize.isFinite,targetSize > 0,targetSize <= 1_000_000 {
            for edge in [Edge.bottom,.top,.left,.right] {
                if let rect = fit(CGSize(width: targetSize+stroke,height: targetSize+stroke),edge: edge,centered: true) {
                    targets.append(Target(edge: edge,center: CGPoint(x: rect.midX,y: rect.midY),size: targetSize,strokeWidth: stroke))
                } else { missing.append(title(kind == .back ? reflectedEdge(edge) : edge)) }
            }
            if settings.registrationTargets,!missing.isEmpty {
                result.warnings.append("Diz işaretleri için boş kenar alanı yok (\(missing.joined(separator: ", "))); sığmayan işaretler eklenmedi.")
            }
        } else if settings.registrationTargets { result.warnings.append("Diz işareti boyutu geçersiz; işaretler eklenmedi.") }
        // Reserve target centers even while hidden to keep the color bar stable.
        protected += targets.map { $0.bounds.insetBy(dx: -0.25,dy: -0.25) }
        if settings.registrationTargets { result.targets = targets }
        if settings.colorBar {
            let size = settings.patchSize
            let edge = settings.barSide == .gripper ? sheet.gripperEdge : opposite(sheet.gripperEdge)
            let horizontal = edge == .bottom || edge == .top
            if size.isFinite,size > 0,size <= 1_000_000,
               let rect = fit(CGSize(width: horizontal ? size*12 : size,height: horizontal ? size : size*12),edge: edge,centered: false) {
                result.patches = patchDefinitions.enumerated().map { index,patch in
                    Patch(bounds: CGRect(x: rect.minX+(horizontal ? Double(index)*size : 0),
                        y: rect.minY+(horizontal ? 0 : Double(index)*size),width: size,height: size),definition: patch)
                }
            } else { result.warnings.append("Renk skalası için seçilen kenarda boş alan yok veya yama boyutu geçersiz; skala eklenmedi.") }
        }
        if kind == .back {
            result.patches = result.patches.map { Patch(bounds: reflected($0.bounds),definition: $0.definition) }
            result.targets = result.targets.map { target in
                let bounds = reflected(target.circleBounds)
                return Target(edge: reflectedEdge(target.edge),center: CGPoint(x: bounds.midX,y: bounds.midY),size: target.size,strokeWidth: target.strokeWidth)
            }
        }
        return result
    }
    public static func draw(_ geometry: Geometry,in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        let space = CGColorSpaceCreateDeviceCMYK()
        for patch in geometry.patches {
            var components: [CGFloat] = patch.definition.cmyk.map { CGFloat($0) }
            components.append(1)
            context.setFillColor(CGColor(colorSpace: space,components: components)!)
            context.fill(patch.bounds)
        }
        context.setStrokeColor(CGColor(colorSpace: space,components: [1,1,1,1,1])!)
        context.setLineDash(phase: 0,lengths: []); context.setLineCap(.butt)
        for target in geometry.targets {
            context.setLineWidth(target.strokeWidth)
            context.strokeEllipse(in: target.circleBounds)
            context.move(to: CGPoint(x: target.center.x-target.size/2,y: target.center.y))
            context.addLine(to: CGPoint(x: target.center.x+target.size/2,y: target.center.y))
            context.move(to: CGPoint(x: target.center.x,y: target.center.y-target.size/2))
            context.addLine(to: CGPoint(x: target.center.x,y: target.center.y+target.size/2)); context.strokePath()
        }
    }
}
