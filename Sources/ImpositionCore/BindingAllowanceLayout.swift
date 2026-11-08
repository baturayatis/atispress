import Foundation

public enum BindingAllowanceBehavior: String, Codable, Sendable, CaseIterable {
    case preserve, shrink, shift
    public var title: String {
        switch self { case .preserve: return "Koru"; case .shrink: return "Küçült"; case .shift: return "Kaydır" }
    }
}

/// Page-only placement in sheet axes. Trim, cuts, binding guides and punch marks
/// stay fixed. This applies to any slot that declares a binding edge/allowance.
public enum BindingAllowanceLayout {
    public static func apply(to slot: inout Slot,inset: Double,behavior: BindingAllowanceBehavior) {
        slot.bindingBehavior = behavior
        slot.bindingScale = 1; slot.bindingTranslation = Point(0,0)
        guard let edge = slot.bindingEdge,slot.bindingAllowance>=0 else { return }
        let original = slot.artworkClip ?? Rect(x:slot.x,y:slot.y,width:slot.size.width,height:slot.size.height)
        switch behavior {
        case .preserve: return
        case .shrink:
            let safe = LeafPlanner.safeRect(slot,inset:inset)
            guard safe.size.width>0,safe.size.height>0 else { return }
            let scale = min(1,safe.size.width/slot.size.width,safe.size.height/slot.size.height)
            let w = slot.size.width*scale,h = slot.size.height*scale
            var x = safe.origin.x+(safe.size.width-w)/2,y = safe.origin.y+(safe.size.height-h)/2
            switch edge {
            case .left: x = safe.origin.x+safe.size.width-w
            case .right: x = safe.origin.x
            case .top: y = safe.origin.y
            case .bottom: y = safe.origin.y+safe.size.height-h
            }
            slot.bindingScale = scale
            slot.bindingTranslation = Point(x-slot.x,y-slot.y)
        case .shift:
            let a = slot.bindingAllowance
            switch edge {
            case .left: slot.bindingTranslation.x = a
            case .right: slot.bindingTranslation.x = -a
            case .top: slot.bindingTranslation.y = -a
            case .bottom: slot.bindingTranslation.y = a
            }
        }
        slot.artworkClip = transformed(original,slot:slot)
    }
    public static func transformed(_ rect: Rect,slot: Slot) -> Rect {
        Rect(x:slot.x+(rect.origin.x-slot.x)*slot.bindingScale+slot.bindingTranslation.x,
             y:slot.y+(rect.origin.y-slot.y)*slot.bindingScale+slot.bindingTranslation.y,
             width:rect.size.width*slot.bindingScale,height:rect.size.height*slot.bindingScale)
    }
    public static func warnings(side: Side,sheet: Size) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (index,slot) in side.slots.enumerated() where slot.sourcePageNumber != nil && slot.bindingBehavior == .shift {
            let r = slot.artworkClip ?? transformed(Rect(x:slot.x,y:slot.y,width:slot.size.width,height:slot.size.height),slot:slot)
            var text: String?
            if r.origin.x < -0.000001 || r.origin.y < -0.000001 || r.origin.x+r.size.width > sheet.width+0.000001 || r.origin.y+r.size.height > sheet.height+0.000001 {
                text = "Kaydır: artwork tabaka sınırını aşıyor; tabaka dışındaki bölüm PDF sayfasında yer alamaz. Tabakayı veya kenar paylarını büyütün."
            } else if side.slots.enumerated().contains(where:{ i,other in
                guard i != index,other.sourcePageNumber != nil else { return false }
                return r.origin.x<other.x+other.size.width-0.000001 && r.origin.x+r.size.width>other.x+0.000001 && r.origin.y<other.y+other.size.height-0.000001 && r.origin.y+r.size.height>other.y+0.000001
            }) {
                text = "Kaydır: artwork komşu ürünün kesim alanına taşıyor; kırpma uygulanmadı. Ara boşluğu artırın."
            }
            if let text {
                var issue = ValidationIssue(.warning,.bindingAllowance,text)
                issue.affectedPages = [slot.sourcePageNumber!]; issues.append(issue)
            }
        }
        return issues
    }
}
extension Slot {
    public var bindingPlacementSummary: String {
        switch bindingBehavior {
        case .preserve: return "Koru · %100 ölçek"
        case .shrink: return String(format:"Küçült · %%%.2f ölçek",locale:Locale(identifier:"tr_TR"),bindingScale*100)
        case .shift: return String(format:"Kaydır · %.2f mm kaydırma · %%100 ölçek",locale:Locale(identifier:"tr_TR"),bindingAllowance)
        }
    }
}

extension Slot {
    /// Production marks stay outside the physical trim as well as the moved page.
    /// Shrinking artwork does not turn the product's white area into sheet margin.
    public var productionProtectedBounds: Rect {
        guard let art = artworkClip else { return Rect(x:x,y:y,width:size.width,height:size.height) }
        let l = min(x,art.origin.x),b = min(y,art.origin.y)
        let r = max(x+size.width,art.origin.x+art.size.width),t = max(y+size.height,art.origin.y+art.size.height)
        return Rect(x:l,y:b,width:r-l,height:t-b)
    }
}
