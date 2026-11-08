import Foundation

public struct LeafBindingSettings: Equatable, Codable, Sendable {
    public enum BindingEdge: String, Codable, Sendable { case left, top, right }
    public var edge: BindingEdge = .left
    // Optional storage keeps schema 13 and older leaf projects readable.
    public var placementBehavior: BindingAllowanceBehavior? = nil
    public var behavior: BindingAllowanceBehavior {
        get { placementBehavior ?? .preserve }
        set { placementBehavior = newValue }
    }
    public var allowance: Double? = nil
    public var holes = false
    public var pitch: Double? = nil
    public var diameter: Double? = nil
    public var offset: Double? = nil
    public init() {}
}
public struct PunchMark: Equatable, Sendable {
    public var center: Point
    public var diameter: Double
    public init(center: Point,diameter: Double) { self.center = center; self.diameter = diameter }
    public var bounds: Rect { Rect(x:center.x-diameter/2,y:center.y-diameter/2,width:diameter,height:diameter) }
}
public struct LeafSheetInfo: Equatable, Sendable {
    public var placementSummary = ""
    public var leafCount: Int
    public var sheetCount: Int
    public var copiesPerSheet: Int
    public var setsPerSheet: Int
    public var blanks: Int
    public var cover: Bool
    public var summary: String { "\(cover ? "Kapak" : "İç blok"): \(leafCount) yaprak · \(sheetCount) tabaka · \(copiesPerSheet*setsPerSheet) yaprak/tabaka (\(setsPerSheet) takım) · Eklenen boş: \(blanks)"+(placementSummary.isEmpty ? "" : " · "+placementSummary) }
}
extension Project {
    public var isLeafBinding: Bool { binding == .spiral || binding == .wireO }
    public var leafSettings: LeafBindingSettings {
        get { leafBinding ?? LeafBindingSettings() }
        set { leafBinding = newValue }
    }
}

/// Cut each grid position into a pile, then stack piles in grid/copy order.
/// Same-plate work styles produce two identical sets, as in the existing grid.
public enum LeafPlanner {
    public static func plan(_ source: Project) -> ImpositionPlan {
        var result = ImpositionPlan(generatedBleed:source.settings.generatedBleed)
        let setting = source.leafSettings,allowance = setting.allowance ?? 0
        func warning(_ text: String) { result.issues.append(ValidationIssue(.warning,.bookSettings,text)) }
        guard allowance.isFinite,allowance >= 0,allowance <= 1000 else {
            result.issues.append(ValidationIssue(.error,.invalidInput,"Cilt payı 0–1000 mm aralığında olmalıdır.")); return result
        }
        if allowance == 0 { warning("Cilt payı girilmedi (0 mm); delme makinenizin gerektirdiği payı girin.") }
        var body = source.pages
        var covers: [SourcePage] = []
        let book = source.book ?? BookSettings()
        let domain = source.book == nil ? source.pages : source.bookCoverPages
        if source.coverMode != .included {
            let front = book.selection.front ?? domain.first?.number
            let back = book.selection.back ?? domain.last?.number
            let selected = [front,back].compactMap { $0 }
            guard selected.count == 2,Set(selected).count == 2,selected.allSatisfy({ n in domain.contains { $0.number==n } }) else {
                result.issues.append(ValidationIssue(.error,.bookSettings,"Ön ve arka kapak için iki ayrı PDF sayfası seçin.")); return result
            }
            covers = selected.compactMap { n in domain.first { $0.number==n } }
            let excluded = Set(book.auxiliaryPages+book.coverPDFPages+(source.coverMode == .excluded ? selected : []))
            body.removeAll { excluded.contains($0.number) }
            if source.coverMode == .separate && book.coverSourceID == nil {
                result.issues.append(ValidationIssue(.error,.bookSettings,"Ayrı kapak PDF’sini yükleyin.")); return result
            }
        }
        guard !body.isEmpty else {
            result.issues.append(ValidationIssue(.error,.invalidInput,"İç blok için en az bir sayfa gerekli.")); return result
        }
        func impose(_ pages: [SourcePage],cover: Bool) {
            let odd = pages.count%2
            if !cover && odd == 1 && source.blankPagePolicy == .reject {
                result.issues.append(ValidationIssue(.error,.pageCountPadding,"Yaprak düzeni için sona 1 boş sayfa eklenmesi gerekiyor.")); return
            }
            guard let size = pages.first?.trimSize,pages.allSatisfy({ $0.trimSize == size }) else {
                result.issues.append(ValidationIssue(.error,.mixedPageSizes,"Yaprak bloğundaki sayfalar aynı kesim ölçüsünde olmalıdır.")); return
            }
            let across = setting.edge == .top ? size.height : size.width
            guard allowance+2*source.settings.safeAreaInset<across else {
                result.issues.append(ValidationIssue(.error,.invalidInput,"Cilt payı ve güvenli alan sayfa ölçüsünü aşıyor.")); return
            }
            var probe = source
            probe.binding = .stepAndRepeat; probe.book = nil; probe.coverMode = .included
            probe.serialFields = []; probe.pages = Array(pages.prefix(2))
            probe.stepAndRepeat.quantity = 1; probe.stepAndRepeat.waste = nil
            var layout = PageLayoutSettings(); layout.mode = .duplex; probe.stepAndRepeat.pageLayout = layout
            let geometry = ImpositionPlanner.plan(probe)
            result.issues += geometry.issues.filter { $0.code != .missingBleed }
            guard let template = geometry.sheets.first,geometry.canExport else { result.diagnosticSheets += geometry.diagnosticSheets; return }
            let positions = template.front.slots.filter { $0.itemSide == .front }.compactMap(\.copyIndex).sorted()
            guard !positions.isEmpty else { return }
            let count = (pages.count+1)/2,capacity = positions.count,sheets = (count+capacity-1)/capacity
            let ranks = Dictionary(uniqueKeysWithValues:positions.enumerated().map { ($0.element,$0.offset) })
            let mirrorX = template.backFlipsX
            func originKey(_ slot: Slot) -> String { "\((slot.x*1e6).rounded())/\((slot.y*1e6).rounded())" }
            let backAtOrigin = Dictionary(uniqueKeysWithValues:template.back.slots.map { (originKey($0),$0.copyIndex!) })
            let frontAtOrigin = Dictionary(uniqueKeysWithValues:template.front.slots.map { (originKey($0),$0.copyIndex!) })
            let frontByCopy = Dictionary(uniqueKeysWithValues:template.front.slots.map { ($0.copyIndex!,$0) })
            for index in 0..<sheets {
                var sheet = template; sheet.repeatCount = 1; sheet.repeatLayout = nil; sheet.serialPlan = nil; sheet.requiresDuplexBack = true
                sheet.leafInfo = LeafSheetInfo(leafCount:count,sheetCount:sheets,copiesPerSheet:capacity,setsPerSheet:source.settings.turnMethod == .sheetwise ? 1 : 2,blanks:cover ? 0 : odd,cover:cover)
                func face(_ original: Side,back: Bool) -> Side {
                    var side = original
                    side.marks.removeAll { $0.kind == .safeArea || $0.kind == .pageLabel }
                    for i in side.slots.indices {
                        var slot = side.slots[i]
                        let key = ranks[slot.copyIndex ?? -1] == nil ? (back ? frontAtOrigin[originKey(slot)] : backAtOrigin[originKey(slot)]) : slot.copyIndex
                        let rank = key.flatMap { ranks[$0] } ?? 0
                        let leaf = rank*sheets+index
                        let pageIndex = leaf*2+(slot.itemSide == .back ? 1 : 0)
                        slot.sourcePageNumber = pageIndex<pages.count ? pages[pageIndex].number : nil
                        slot.logicalPageIndex = pageIndex<count*2 ? pageIndex : nil
                        slot.bookLeafIndex = leaf<count ? leaf : nil
                        slot.bookRegion = cover ? "Kapak" : "Yaprak \(leaf+1)"
                        // Find the same physical piece on the front and reflect its edge.
                        let frontSlot = frontByCopy[slot.copyIndex ?? -1] ?? slot
                        let frontEdge = rotatedEdge(setting.edge,rotation:frontSlot.rotation,itemBack:frontSlot.itemSide == .back)
                        slot.bindingEdge = back ? reflectedEdge(frontEdge,mirrorX:mirrorX) : frontEdge
                        slot.bindingAllowance = allowance
                        BindingAllowanceLayout.apply(to:&slot,inset:source.settings.safeAreaInset,behavior:setting.behavior)
                        side.slots[i] = slot
                        if leaf<count { side.marks += guides(slot,inset:source.settings.safeAreaInset) }
                    }
                    result.issues += BindingAllowanceLayout.warnings(side:side,sheet:sheet.size)
                    if setting.holes {
                        let marks = punches(side:side,sheet:sheet,settings:setting)
                        side.punchMarks = marks.marks
                        if !marks.warnings.isEmpty { warning(marks.warnings.joined(separator:" ")) }
                    }
                    return side
                }
                sheet.front = face(template.front,back:false); sheet.back = face(template.back,back:true)
                let placementSummary = sheet.front.slots.first(where:{ $0.sourcePageNumber != nil })?.bindingPlacementSummary ?? ""
                sheet.leafInfo?.placementSummary = placementSummary
                result.sheets.append(sheet)
            }
            if !cover { result.addedBlankPages += odd }
            if !cover {
                result.readingOrder = pages.map { Optional($0.number) }+(odd==1 ? [nil] : [])
                result.blankPositions = odd==1 ? [pages.count+1] : []
            }
        }
        impose(body,cover:false)
        // Front and back covers are independent front-only leaves with blank insides.
        for cover in covers { impose([cover],cover:true) }
        if source.settings.bleed>0 && !source.settings.generatedBleed.enabled {
            let missing = source.pages.filter { ($0.availableBleed ?? 0)<source.settings.bleed }
            if !missing.isEmpty { var issue = ValidationIssue(.warning,.missingBleed,"\(missing.count) sayfada taşma payı eksik."); issue.affectedPages = missing.map(\.number); result.issues.append(issue) }
        }
        return result
    }
    public static func reflectedEdge(_ edge: Edge,mirrorX: Bool) -> Edge {
        if mirrorX { return edge == .left ? .right : edge == .right ? .left : edge }
        return edge == .top ? .bottom : edge == .bottom ? .top : edge
    }
    private static func rotatedEdge(_ edge: LeafBindingSettings.BindingEdge,rotation: Int,itemBack: Bool) -> Edge {
        var result: Edge = edge == .left ? .left : edge == .right ? .right : .top
        if itemBack { result = reflectedEdge(result,mirrorX:true) }
        for _ in 0..<((rotation%360+360)%360/90) {
            switch result { case .left: result = .top; case .top: result = .right; case .right: result = .bottom; case .bottom: result = .left }
        }
        return result
    }
    public static func safeRect(_ slot: Slot,inset: Double) -> Rect {
        let a = slot.bindingAllowance
        let l = inset+(slot.bindingEdge == .left ? a : 0),r = inset+(slot.bindingEdge == .right ? a : 0)
        let b = inset+(slot.bindingEdge == .bottom ? a : 0),t = inset+(slot.bindingEdge == .top ? a : 0)
        return Rect(x:slot.x+l,y:slot.y+b,width:max(0,slot.size.width-l-r),height:max(0,slot.size.height-b-t))
    }
    private static func guides(_ slot: Slot,inset: Double) -> [Mark] {
        let r = safeRect(slot,inset:inset)
        let p = [Point(r.origin.x,r.origin.y),Point(r.origin.x+r.size.width,r.origin.y),Point(r.origin.x+r.size.width,r.origin.y+r.size.height),Point(r.origin.x,r.origin.y+r.size.height)]
        var marks = (0..<4).map { Mark(kind:.safeArea,start:p[$0],end:p[($0+1)%4]) }
        let a = slot.bindingAllowance
        if a>0 {
            let x = slot.bindingEdge == .left ? slot.x+a : slot.x+slot.size.width-a
            let y = slot.bindingEdge == .bottom ? slot.y+a : slot.y+slot.size.height-a
            let vertical = slot.bindingEdge == .left || slot.bindingEdge == .right
            marks.append(Mark(kind:.margin,start:vertical ? Point(x,slot.y) : Point(slot.x,y),end:vertical ? Point(x,slot.y+slot.size.height) : Point(slot.x+slot.size.width,y),label:"Cilt payı"))
        }
        return marks
    }
    public static func punches(side: Side,sheet: Sheet,settings: LeafBindingSettings) -> (marks:[PunchMark],warnings:[String]) {
        guard let pitch = settings.pitch,let diameter = settings.diameter,let offset = settings.offset,
              [pitch,diameter,offset].allSatisfy({ $0.isFinite && $0>0 && $0<=1000 }),pitch>=diameter else {
            return ([],["Delik aralığı, çapı ve kenardan uzaklığı girin; aralık çaptan küçük olamaz. Delik işaretleri eklenmedi."])
        }
        var output: [PunchMark] = [],skipped = false
        let radius = diameter/2+0.25 // stroke + clearance, deliberately conservative
        for slot in side.slots where slot.bookLeafIndex != nil {
            let vertical = slot.bindingEdge == .left || slot.bindingEdge == .right
            let length = vertical ? slot.size.height : slot.size.width
            let raw = floor((length-diameter)/pitch)+1
            guard raw.isFinite,raw>0,raw<=1000 else { skipped = true; continue }
            let count = Int(raw)
            let start = (length-Double(count-1)*pitch)/2
            for index in 0..<count {
                let along = start+Double(index)*pitch
                let center: Point
                switch slot.bindingEdge ?? .left {
                case .left: center = Point(slot.x-offset,slot.y+along)
                case .right: center = Point(slot.x+slot.size.width+offset,slot.y+along)
                case .top: center = Point(slot.x+along,slot.y+slot.size.height+offset)
                case .bottom: center = Point(slot.x+along,slot.y-offset)
                }
                let bounds = Rect(x:center.x-radius,y:center.y-radius,width:2*radius,height:2*radius)
                let intersects = side.slots.contains { other in
                    let b = other.productionProtectedBounds
                    return bounds.origin.x<b.origin.x+b.size.width && bounds.origin.x+bounds.size.width>b.origin.x && bounds.origin.y<b.origin.y+b.size.height && bounds.origin.y+bounds.size.height>b.origin.y
                }
                if intersects || bounds.origin.x<0 || bounds.origin.y<0 || bounds.origin.x+bounds.size.width>sheet.size.width || bounds.origin.y+bounds.size.height>sheet.size.height || output.count>=50_000 { skipped = true; continue }
                let mark = PunchMark(center:center,diameter:diameter)
                if !output.contains(mark) { output.append(mark) }
            }
        }
        return (output,skipped ? ["Delik işaretleri için kesim/taşma dışında yeterli boş kenar yok veya işaret sınırı aşıldı; sığmayanlar eklenmedi."] : [])
    }
}
