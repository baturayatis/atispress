import Foundation

public struct GangJob: Identifiable, Equatable, Codable, Sendable {
    public var id = UUID()
    public var sourceID: UUID
    public var name: String
    public var front: SourcePage
    public var back: SourcePage?
    public var quantity: Int = 1000
    public var waste = WasteSettings()
    public var bleed: Double = 3
    public var generatedBleed = GeneratedBleedSettings()
    public var serialFields: [SerialField] = []
    public var allowRotation = true
    public var tint: Double = 0.55
    public init(sourceID: UUID,name: String,front: SourcePage,back: SourcePage? = nil) {
        self.sourceID = sourceID; self.name = name; self.front = front; self.back = back
    }
}
public struct GangBlock: Identifiable, Equatable, Codable, Sendable {
    public var id = UUID()
    public var jobID: UUID
    public var origin: Point
    public var columns: Int
    public var rows: Int
    public var rotated: Bool
    public init(jobID: UUID,origin: Point,columns: Int = 1,rows: Int = 1,rotated: Bool = false) {
        self.jobID = jobID; self.origin = origin; self.columns = columns; self.rows = rows; self.rotated = rotated
    }
}
public struct GangSettings: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case automatic, manual }
    public var mode: Mode = .automatic
    public var jobs: [GangJob] = []
    public var blocks: [GangBlock] = []
    public init() {}
}
public struct GangJobResult: Equatable, Sendable {
    public var job: GangJob
    public var copiesPerSheet: Int
    public var required: Int
    public var surplus: UInt64
    public var serialPlan: SerialNumberPlan
}
public struct GangSheetLayout: Equatable, Sendable {
    public var samePlate: Bool
    public var blocks: [GangBlock]
    public var jobs: [GangJobResult]
    public var cuts: [Mark]
    public var printable: Rect
    public var summary: String
}
extension Sheet {
    public func serialRecipe(for slot: Slot) -> SerialNumberPlan? {
        if let id = slot.gangJobID { return gangLayout?.jobs.first { $0.job.id == id }?.serialPlan }
        return serialPlan
    }
    public func serialPlacements(side: Side,kind: SideKind,repetition: Int) -> [SerialPlacement] {
        side.slots.enumerated().flatMap { serialRecipe(for: $0.element)?.placements(slot: $0.element,slotIndex: $0.offset,kind: kind,repetition: repetition) ?? [] }
    }
    public var generatedBleedByJob: [UUID:GeneratedBleedSettings] {
        Dictionary(uniqueKeysWithValues: (gangLayout?.jobs ?? []).map { ($0.job.id,$0.job.generatedBleed) })
    }
    public var gangJobNames: String? { gangLayout?.jobs.map(\.job.name).joined(separator: ", ") }
}

/// Rectangular slicing layouts: every internal node is a full straight cut.
/// A leaf is one job's regular grid, so shared cuts never require an L-shaped knife path.
public enum GangPlanner {
    private struct Candidate {
        var size: Size
        var blocks: [GangBlock]
    }
    public static func sheetCount(required: [Int],copies: [Int]) -> Int? {
        guard required.count == copies.count,!required.isEmpty,
              zip(required,copies).allSatisfy({ $0 > 0 && $1 > 0 }) else { return nil }
        return zip(required,copies).map { 1+($0-1)/$1 }.max()
    }
    public static func isStraightCut(_ path: [Point]) -> Bool {
        guard path.count >= 2 else { return false }
        return path.allSatisfy { abs($0.x-path[0].x)<0.000001 } || path.allSatisfy { abs($0.y-path[0].y)<0.000001 }
    }
    public static func guillotineCuts(_ rectangles: [Rect],within region: Rect) -> [Mark]? {
        guard !rectangles.isEmpty else { return [] }
        func split(_ rs: [Rect],_ area: Rect) -> [Mark]? {
            if rs.count <= 1 { return [] }
            for vertical in [true,false] {
                let edges = Set(rs.flatMap { r in vertical ? [r.origin.x,r.origin.x+r.size.width] : [r.origin.y,r.origin.y+r.size.height] }).sorted()
                for edge in edges {
                    let low = rs.filter { r in (vertical ? r.origin.x+r.size.width : r.origin.y+r.size.height) <= edge+0.000001 }
                    let high = rs.filter { r in (vertical ? r.origin.x : r.origin.y) >= edge-0.000001 }
                    guard !low.isEmpty,!high.isEmpty,low.count+high.count == rs.count else { continue }
                    let a = vertical ? Rect(x: area.origin.x,y: area.origin.y,width: edge-area.origin.x,height: area.size.height) : Rect(x: area.origin.x,y: area.origin.y,width: area.size.width,height: edge-area.origin.y)
                    let b = vertical ? Rect(x: edge,y: area.origin.y,width: area.origin.x+area.size.width-edge,height: area.size.height) : Rect(x: area.origin.x,y: edge,width: area.size.width,height: area.origin.y+area.size.height-edge)
                    if let x = split(low,a),let y = split(high,b) {
                        let cut = Mark(kind: .sharedCut,start: vertical ? Point(edge,area.origin.y) : Point(area.origin.x,edge),end: vertical ? Point(edge,area.origin.y+area.size.height) : Point(area.origin.x+area.size.width,edge))
                        return [cut]+x+y
                    }
                }
            }
            return nil
        }
        for (i,a) in rectangles.enumerated() {
            for b in rectangles.dropFirst(i+1) where overlaps(a,b) { return nil }
        }
        return split(rectangles,region)
    }
    private static func overlaps(_ a: Rect,_ b: Rect) -> Bool {
        min(a.origin.x+a.size.width,b.origin.x+b.size.width)>max(a.origin.x,b.origin.x)+0.000001 && min(a.origin.y+a.size.height,b.origin.y+b.size.height)>max(a.origin.y,b.origin.y)+0.000001
    }
    public static func blockBounds(_ b: GangBlock,job: GangJob,gutter: Double) -> Rect {
        let w = b.rotated ? job.front.trimSize.height : job.front.trimSize.width
        let h = b.rotated ? job.front.trimSize.width : job.front.trimSize.height
        return Rect(x: b.origin.x,y: b.origin.y,width: Double(b.columns)*w+Double(b.columns-1)*gutter,height: Double(b.rows)*h+Double(b.rows-1)*gutter)
    }
    /// Pareto dynamic programming over slicing trees. Search bounds are explicit in the plan.
    private static func pack(jobs: [GangJob],required: [Int],sheets: Int,factor: Int,area: Size,gutter: Double) -> Candidate? {
        var memo: [Int:[Candidate]] = [:]
        func frontier(_ input: [Candidate]) -> [Candidate] {
            var out: [Candidate] = []
            for c in input.sorted(by: { $0.size.width == $1.size.width ? $0.size.height < $1.size.height : $0.size.width < $1.size.width }) {
                if out.contains(where: { $0.size.width <= c.size.width+0.000001 && $0.size.height <= c.size.height+0.000001 }) { continue }
                out.removeAll { c.size.width <= $0.size.width && c.size.height <= $0.size.height }
                out.append(c)
            }
            // Sampling preserves both narrow/tall and wide/short extremes for larger jobs.
            // The caller reports that this bounded search is not an optimality proof.
            if jobs.count > 4 && out.count > 8 {
                return (0..<8).map { out[$0*(out.count-1)/7] }
            }
            return out
        }
        func solve(_ mask: Int) -> [Candidate] {
            if Task.isCancelled { return [] }
            if let hit = memo[mask] { return hit }
            var choices: [Candidate] = []
            if mask.nonzeroBitCount == 1 {
                let i = mask.trailingZeroBitCount,j = jobs[i]
                let need = 1+((1+(required[i]-1)/sheets)-1)/factor
                for rotated in (j.allowRotation ? [false,true] : [false]) {
                    let w = rotated ? j.front.trimSize.height : j.front.trimSize.width,h = rotated ? j.front.trimSize.width : j.front.trimSize.height
                    let maxCols = min(200,Int(min(200,max(0,(area.width+gutter)/(w+gutter)))))
                    guard maxCols > 0 else { continue }
                    for cols in 1...maxCols {
                        let rows = 1+(need-1)/cols
                        guard rows <= 200,cols*rows <= 20_000 else { continue }
                        let size = Size(Double(cols)*w+Double(cols-1)*gutter,Double(rows)*h+Double(rows-1)*gutter)
                        if size.width <= area.width+0.000001 && size.height <= area.height+0.000001 {
                            var block = GangBlock(jobID: j.id,origin: Point(0,0),columns: cols,rows: rows,rotated: rotated); block.id = j.id
                            choices.append(Candidate(size: size,blocks: [block]))
                        }
                    }
                }
            } else {
                var left = (mask-1)&mask
                while left > 0 {
                    if Task.isCancelled { return [] }
                    let right = mask^left
                    if left < right {
                        for a in solve(left) { for b in solve(right) { for horizontal in [true,false] {
                            let size = horizontal ? Size(a.size.width+gutter+b.size.width,max(a.size.height,b.size.height)) : Size(max(a.size.width,b.size.width),a.size.height+gutter+b.size.height)
                            guard size.width <= area.width+0.000001,size.height <= area.height+0.000001 else { continue }
                            let moved = b.blocks.map { block -> GangBlock in var q = block; q.origin.x += horizontal ? a.size.width+gutter : 0; q.origin.y += horizontal ? 0 : a.size.height+gutter; return q }
                            choices.append(Candidate(size: size,blocks: a.blocks+moved))
                            if jobs.count > 4 && choices.count >= 256 { choices = frontier(choices) }
                        } } }
                    }
                    left = (left-1)&mask
                }
            }
            let result = frontier(choices); memo[mask] = result; return result
        }
        return solve((1<<jobs.count)-1).min { $0.size.width*$0.size.height < $1.size.width*$1.size.height }
    }
    public static func plan(_ project: Project) -> ImpositionPlan {
        var result = ImpositionPlan()
        guard let gang = project.gang,!gang.jobs.isEmpty else { return result }
        func issue(_ text: String,_ severity: ValidationIssue.Severity = .error) { result.issues.append(ValidationIssue(severity,.gangLayout,text)) }
        let jobs = gang.jobs,spec = project.sheet
        guard jobs.count <= 8,Set(jobs.map(\.id)).count == jobs.count else { issue("Karışık düzende en fazla 8 benzersiz iş desteklenir."); return result }
        guard [spec.size.width,spec.size.height,spec.gutter,spec.gripperWidth,spec.margins.left,spec.margins.right,spec.margins.top,spec.margins.bottom].allSatisfy({ $0.isFinite && $0 >= 0 }),spec.size.width > 0,spec.size.height > 0,
              jobs.allSatisfy({ j in j.front.number>0 && [j.front.trimSize.width,j.front.trimSize.height].allSatisfy({ $0.isFinite && $0>0 }) && j.tint.isFinite && (0...1).contains(j.tint) && j.bleed.isFinite && j.bleed>=0 && j.generatedBleed.isValid && j.waste.quantities(for: j.quantity) != nil && j.serialFields.count<=100 && Set(j.serialFields.map(\.id)).count==j.serialFields.count && j.serialFields.allSatisfy(\.isValid) }) else { issue("İş ölçüsü, adet, fire, taşma veya seri alanı geçersiz."); return result }
        if jobs.count > 4 { issue("5–8 işte otomatik arama örneklenir: bulunan düzen giyotinle kesilebilir; en az tabaka sayısı garanti edilemedi.",.warning) }
        let required = jobs.map { $0.waste.quantities(for: $0.quantity)!.total }
        let mirrorsX = ImpositionPlanner.repeatMirrorsX(project)
        let samePlate = project.settings.turnMethod != .sheetwise,factor = samePlate ? 2 : 1
        var m = spec.margins
        switch spec.gripperEdge { case .left: m.left += spec.gripperWidth; case .right: m.right += spec.gripperWidth; case .top: m.top += spec.gripperWidth; case .bottom: m.bottom += spec.gripperWidth }
        if project.blockAlignment == .gripper || samePlate {
            if mirrorsX { m.left = max(m.left,m.right); m.right = m.left } else { m.top = max(m.top,m.bottom); m.bottom = m.top }
        }
        // Positive gutters must protect both jobs' bleeds. Zero gutter means common trim, perimeter bleed only.
        let bleed = jobs.map(\.bleed).max() ?? 0
        let gap = spec.gutter
        if gap > 0 && gap < 2*bleed { issue("Ara boşluk \(gap) mm; iki taşma için en az \(2*bleed) mm gerekir.") }
        let reserve = max(bleed,project.settings.cropMarkOffset+project.settings.cropMarkLength)
        var size = spec.size
        if spec.orientation == .portrait { size = Size(min(size.width,size.height),max(size.width,size.height)) }
        if spec.orientation == .landscape { size = Size(max(size.width,size.height),min(size.width,size.height)) }
        func region(_ size: Size) -> Rect {
            var w = size.width-m.left-m.right-2*reserve,h = size.height-m.top-m.bottom-2*reserve
            if samePlate { if mirrorsX { w = (w-gap-2*bleed)/2 } else { h = (h-gap-2*bleed)/2 } }
            return Rect(x: m.left+reserve,y: m.bottom+reserve,width: w,height: h)
        }
        var area = region(size),blocks = gang.blocks
        if gang.mode == .automatic {
            var best: (Int,Size,Candidate)?
            for stock in spec.orientation == .auto ? [size,Size(size.height,size.width)] : [size] {
                let r = region(stock)
                guard r.size.width>0,r.size.height>0 else { continue }
                var low = 1,high = required.max()!
                guard pack(jobs: jobs,required: required,sheets: high,factor: factor,area: r.size,gutter: gap) != nil else { continue }
                while low<high {
                    if Task.isCancelled { return result }
                    let mid = low+(high-low)/2
                    if pack(jobs: jobs,required: required,sheets: mid,factor: factor,area: r.size,gutter: gap) != nil { high = mid } else { low = mid+1 }
                }
                if let c = pack(jobs: jobs,required: required,sheets: low,factor: factor,area: r.size,gutter: gap),best == nil || low<best!.0 { best = (low,stock,c) }
            }
            if let best { size = best.1; area = region(size); blocks = best.2.blocks.map {
                var b = $0
                b.origin.x += area.origin.x+(project.blockAlignment == .center ? (area.size.width-best.2.size.width)/2 : 0)
                b.origin.y += area.origin.y+(project.blockAlignment == .center ? (area.size.height-best.2.size.height)/2 : 0)
                return b
            } }
            else {
                issue("İşler aynı tabakaya sığmıyor: kullanılabilir alan \(String(format: "%.1f × %.1f",area.size.width,area.size.height)) mm; "+jobs.map { "\($0.name) \(String(format: "%.1f × %.1f",$0.front.trimSize.width,$0.front.trimSize.height)) mm" }.joined(separator:"; ")+". Tabakayı büyütün veya işleri ayırın.")
                blocks = jobs.enumerated().map { GangBlock(jobID: $0.element.id,origin: Point(area.origin.x+Double($0.offset)*10,area.origin.y)) }
            }
        }
        guard blocks.count<=1000,blocks.allSatisfy({ b in jobs.contains { $0.id==b.jobID } && (1...200).contains(b.columns) && (1...200).contains(b.rows) && b.columns*b.rows<=20_000 && b.origin.x.isFinite && b.origin.y.isFinite }) else { issue("Elle düzen blokları geçersiz."); return result }
        let slotCount = blocks.reduce(0) { $0+$1.columns*$1.rows }
        guard slotCount <= 20_000/factor else { issue("Tabaka başına 20.000 yuva sınırı aşıldı."); return result }
        let rects = blocks.map { b in blockBounds(b,job: jobs.first { $0.id == b.jobID }!,gutter: gap) }
        for (i,r) in rects.enumerated() {
            if r.origin.x<area.origin.x-0.000001 || r.origin.y<area.origin.y-0.000001 || r.origin.x+r.size.width>area.origin.x+area.size.width+0.000001 || r.origin.y+r.size.height>area.origin.y+area.size.height+0.000001 { issue("Blok \(i+1): kenar/maşa/taşma sınırını aşıyor (\(String(format: "%.1f",r.origin.x)), \(String(format: "%.1f",r.origin.y)) mm.") }
            for (k,q) in rects.enumerated() where k>i {
                if overlaps(r,q) { issue("Blok \(i+1) ve \(k+1) çakışıyor.") }
                else if spec.gutter>0 {
                    let a = Rect(x:r.origin.x-bleed,y:r.origin.y-bleed,width:r.size.width+2*bleed,height:r.size.height+2*bleed)
                    let b = Rect(x:q.origin.x-bleed,y:q.origin.y-bleed,width:q.size.width+2*bleed,height:q.size.height+2*bleed)
                    if overlaps(a,b) { issue("Blok \(i+1) ve \(k+1): taşmalar arasında yeterli boşluk yok.") }
                }
            }
        }
        let cuts = guillotineCuts(rects,within: area)
        if cuts == nil { issue("Düzen giyotinle düz kesilemiyor: çakışan veya birbirine geçen bloklar var. L biçimli kesim kabul edilmez.") }
        var front = Side(),back = Side(),capacities: [UUID:Int] = [:]
        func reflected(_ p: Slot) -> Slot {
            var q = p
            if mirrorsX { q.origin.x = size.width-p.x-p.size.width; q.rotation = (360-p.rotation)%360 } else { q.origin.y = size.height-p.y-p.size.height; q.rotation = (540-p.rotation)%360 }
            if var c = p.artworkClip { if mirrorsX { c.origin.x = size.width-c.origin.x-c.size.width } else { c.origin.y = size.height-c.origin.y-c.size.height }; q.artworkClip = c }
            return q
        }
        for b in blocks {
            let j = jobs.first { $0.id==b.jobID }!,w = b.rotated ? j.front.trimSize.height : j.front.trimSize.width,h = b.rotated ? j.front.trimSize.width : j.front.trimSize.height
            if b.rotated && !j.allowRotation { issue("\(j.name): 90° döndürme kapalı; blok döndürülmüş.") }
            if let reverse = j.back,reverse.trimSize != j.front.trimSize { issue("\(j.name): ön ve arka kesim ölçüleri eşit değil.") }
            let start = capacities[j.id] ?? 0,c = b.columns*b.rows
            capacities[j.id] = start+c*factor
            for row in 0..<b.rows { for col in 0..<b.columns {
                let x = b.origin.x+Double(col)*(w+gap),y = b.origin.y+Double(row)*(h+gap)
                var p = Slot(sourcePageNumber: j.front.number,origin: Point(x,y),size: Size(w,h),rotation: b.rotated ? 90 : 0,copyIndex: start+row*b.columns+col,itemSide: .front)
                p.gangJobID = j.id; p.gangBlockID = b.id
                var l = col==0 ? j.bleed : (gap==0 ? 0 : j.bleed),r = col==b.columns-1 ? j.bleed : (gap==0 ? 0 : j.bleed)
                var d = row==0 ? j.bleed : (gap==0 ? 0 : j.bleed),t = row==b.rows-1 ? j.bleed : (gap==0 ? 0 : j.bleed)
                // Conservative rectangular clipping at touching neighboring blocks protects their artwork.
                if gap==0 { for q in rects where !((abs(q.origin.x-b.origin.x)<0.000001)&&(abs(q.origin.y-b.origin.y)<0.000001)) {
                    if y-j.bleed<q.origin.y+q.size.height && y+h+j.bleed>q.origin.y { if q.origin.x+q.size.width<=x+0.000001 { l = min(l,max(0,x-q.origin.x-q.size.width)) }; if q.origin.x>=x+w-0.000001 { r = min(r,max(0,q.origin.x-x-w)) } }
                    if x-j.bleed<q.origin.x+q.size.width && x+w+j.bleed>q.origin.x { if q.origin.y+q.size.height<=y+0.000001 { d = min(d,max(0,y-q.origin.y-q.size.height)) }; if q.origin.y>=y+h-0.000001 { t = min(t,max(0,q.origin.y-y-h)) } }
                } }
                p.artworkClip = Rect(x:x-l,y:y-d,width:w+l+r,height:h+d+t)
                var reverse = p; reverse.sourcePageNumber = j.back?.number; reverse.itemSide = .back
                front.slots.append(p); back.slots.append(reflected(reverse))
                if samePlate {
                    var otherFront = reflected(reverse); otherFront.copyIndex = p.copyIndex!+c
                    var otherBack = p; otherBack.copyIndex = p.copyIndex!+c
                    front.slots.append(otherFront); back.slots.append(otherBack)
                }
            } }
        }
        if front.slots.count>20_000 { issue("Tabaka başına 20.000 yuva sınırı aşıldı."); return result }
        let copies = jobs.map { capacities[$0.id] ?? 0 }
        let count = sheetCount(required: required,copies: copies) ?? 1
        if copies.contains(0) { issue("Her iş için en az bir blok gerekir.") }
        var jobResults: [GangJobResult] = []
        for (i,j) in jobs.enumerated() {
            var recipe = SerialNumberPlan(fields:j.serialFields,quantity:j.waste.numberCopies ? required[i] : j.quantity,capacity:copies[i],sheetCount:count); recipe.frontOnly = j.back == nil
            if recipe.fields.contains(where: { $0.usesSerialNumber && $0.value(at: recipe.quantity-1)==nil }) { issue("\(j.name): seri numara taşması.") }
            let product = UInt64(count).multipliedReportingOverflow(by:UInt64(copies[i]))
            let made = product.overflow ? UInt64.max : product.partialValue
            jobResults.append(GangJobResult(job:j,copiesPerSheet:copies[i],required:required[i],surplus:made>UInt64(required[i]) ? made-UInt64(required[i]) : 0,serialPlan:recipe))
            for field in recipe.fields {
                if let note = field.digitNote(quantity:recipe.quantity) { result.issues.append(ValidationIssue(.warning,.serialNumbering,j.name+": "+note)) }
            }
            let missing = [j.front,j.back].compactMap { $0 }.filter { ($0.availableBleed ?? 0)<j.bleed }
            if !missing.isEmpty && !j.generatedBleed.enabled {
                var warning = ValidationIssue(.warning,.missingBleed,"\(j.name): \(missing.count) sayfada taşma payı eksik.")
                warning.affectedPages = missing.map(\.number); result.issues.append(warning)
            }
        }
        // Cell grid boundaries are straight cuts within leaf strips; no fold paths are emitted.
        func guides(_ side: inout Side) {
            for slot in side.slots {
                var s = project.settings; s.bleed = jobs.first { $0.id==slot.gangJobID }?.bleed ?? 0
                side.marks += ImpositionPlanner.marks(slot,s)
            }
            side.marks += ImpositionPlanner.pressGuides(spec,size)
        }
        guides(&front); guides(&back)
        var allCuts = cuts ?? []
        for (index,block) in blocks.enumerated() {
            let r = rects[index],job = jobs.first { $0.id==block.jobID }!
            let w = block.rotated ? job.front.trimSize.height : job.front.trimSize.width
            let h = block.rotated ? job.front.trimSize.width : job.front.trimSize.height
            var xs: Set<Double> = [r.origin.x,r.origin.x+r.size.width]
            var ys: Set<Double> = [r.origin.y,r.origin.y+r.size.height]
            for c in 1..<block.columns {
                xs.insert(r.origin.x+Double(c)*(w+gap)); xs.insert(r.origin.x+Double(c)*(w+gap)-gap)
            }
            for row in 1..<block.rows {
                ys.insert(r.origin.y+Double(row)*(h+gap)); ys.insert(r.origin.y+Double(row)*(h+gap)-gap)
            }
            allCuts += xs.sorted().map { Mark(kind:.sharedCut,start:Point($0,r.origin.y),end:Point($0,r.origin.y+r.size.height)) }
            allCuts += ys.sorted().map { Mark(kind:.sharedCut,start:Point(r.origin.x,$0),end:Point(r.origin.x+r.size.width,$0)) }
        }
        func reflectedCut(_ cut: Mark) -> Mark {
            func flip(_ p: Point) -> Point { mirrorsX ? Point(size.width-p.x,p.y) : Point(p.x,size.height-p.y) }
            return Mark(kind:.sharedCut,start:flip(cut.start),end:flip(cut.end))
        }
        if samePlate { allCuts += allCuts.map(reflectedCut) }
        front.marks += allCuts; back.marks += allCuts.map(reflectedCut)
        var sheet = Sheet(size:size,front:front,back:back,repeatCount:count)
        sheet.gangLayout = GangSheetLayout(samePlate:samePlate,blocks:blocks,jobs:jobResults,cuts:allCuts,printable:area,summary:"\(jobs.count) iş · \(copies.reduce(0,+)) adet/tabaka · \(count) tabaka")
        result.sheets = [sheet]
        return result
    }
}
