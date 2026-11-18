import SwiftUI
import ImpositionCore

struct DimensionInput:View {
    let title:String
    @Binding var value:Double
    var enabled = true
    var unit = "mm"
    var range:ClosedRange<Double> = -1000000...1000000
    init(_ title:String,value:Binding<Double>,unit:String = "mm",range:ClosedRange<Double> = -1000000...1000000,enabled:Bool = true) { self.enabled = enabled; self.title = title; _value = value; self.unit = unit; self.range = range }
    var body:some View {
        HStack(spacing:6) {
            TextField(title,value:$value,format:TRFormat.detail).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width:72).accessibilityLabel(title).disabled(!enabled).opacity(enabled ? 1 : 0.45)
            Text(unit).font(.system(size:12)).foregroundStyle(DesignSystem.muted).fixedSize().frame(width:32,alignment:.leading)
            Stepper(title,value:$value,in:range,step:0.5).labelsHidden().fixedSize()
        }.fixedSize()
    }
}
extension Workspace {
    var manualSettingCount:Int { AutoLayoutField.allCases.filter { isManual($0) || project.autoLayout?.presetFields?.contains($0) == true }.count }
    var showsTurnControl:Bool { project.team?.duplex ?? (plan.hasBackContent || project.repeatJobs.contains { $0.back != nil } || project.isBooklet || project.isLeafBinding && project.pages.count > 1) }
    var turnLabel:String {
        switch project.settings.turnMethod { case .sheetwise:return "Ayrı kalıp (sheetwise)"; case .workAndTurn:return "Yandan çevir (work-and-turn)"; case .workAndTumble:return "Baştan çevir (work-and-tumble)" }
    }
    var turnHelper:String {
        switch project.settings.turnMethod {
        case .sheetwise:return "Ön ve arka için ayrı baskı kalıbı kullanılır."
        case .workAndTurn:return "Kâğıt yan kenarından çevrilir; aynı kalıp kullanılır."
        case .workAndTumble:return "Kâğıt baştan çevrilir; aynı kalıp kullanılır."
        }
    }
    func cardSummary(_ title:String) -> String {
        switch title {
        case "Ne basıyoruz?":return workflowProductSummary
        case "Hangi kâğıda basılacak?":return "\(selectedWorkflowChip) · \(project.sheet.orientation == .landscape ? "Yatay" : project.sheet.orientation == .portrait ? "Dikey" : "Otomatik") · \(project.autoLayout?.production == .offset ? "Ofset" : "Dijital")"
        case "Kesim ve taşma":return "Taşma payı \(TRFormat.dimension(workflowBleed)) mm · \(project.exportMarks.crop ? "Kesim işareti açık" : "Kesim işareti kapalı")"
        case "Cilt ve kapak":return productKind.rawValue
        case "Eklemek istersen":return WorkflowAddon.allCases.filter { $0 != .scaling }.compactMap(workflowAddonSummary).joined(separator:" · ")
        default:return "Kenarlar, maşa ve üretim ayrıntıları"
        }
    }
}

extension Workspace {
    func confirmResetAllSettings() {
        let alert = NSAlert(); alert.messageText = "Tüm ayarlar otomatiğe döndürülsün mü?"
        alert.informativeText = "Yerleşim ve çıktı işaretleri yeniden hesaplanır. Adet, kâğıt kalınlığı ve seri içeriği korunur."
        alert.addButton(withTitle:"Otomatiğe döndür"); alert.addButton(withTitle:"İptal")
        if alert.runModal() == .alertFirstButtonReturn { requestAutomaticLayout(confirm:{ _ in true }) }
    }
}

struct IntegerInput:View {
    let title:String
    @Binding var value:Int
    var unit = "adet"
    var body:some View {
        HStack(spacing:6) {
            TextField(title,value:$value,format:.number.locale(TRFormat.locale)).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width:72)
            Text(unit).font(.system(size:12)).foregroundStyle(DesignSystem.muted)
            Stepper(title,onIncrement:{ value += 1 },onDecrement:{ value -= 1 }).labelsHidden().fixedSize()
        }
    }
}

struct OptionalDimensionInput:View {
    let title:String
    @Binding var value:Double?
    let unit:String
    var body:some View {
        HStack(spacing:6) {
            TextField("Girilmedi",value:$value,format:TRFormat.detail).textFieldStyle(.roundedBorder).frame(width:72).accessibilityLabel(title)
            Text(unit).font(.system(size:12)).fixedSize().frame(width:32,alignment:.leading)
            Stepper(title,onIncrement:{ value = (value ?? 0)+0.5 },onDecrement:{ value = max(0,(value ?? 0)-0.5) }).labelsHidden().fixedSize()
        }
    }
}
struct OptionalIntegerInput:View {
    let title:String
    @Binding var value:Int?
    let unit:String
    var body:some View {
        HStack(spacing:6) {
            TextField("Girilmedi",value:$value,format:.number.locale(TRFormat.locale)).textFieldStyle(.roundedBorder).frame(width:72).accessibilityLabel(title)
            Text(unit).font(.system(size:12))
            Stepper(title,onIncrement:{ value = (value ?? 0)+1 },onDecrement:{ value = max(0,(value ?? 0)-1) }).labelsHidden().fixedSize()
        }
    }
}


extension Workspace {
    func guideDimensionBinding(_ key:WritableKeyPath<ImpositionSettings,Double>,field:AutoLayoutField) -> Binding<Double> {
        Binding(get:{ self.project.settings[keyPath:key] },set:{ self.markManual(field); self.project.settings[keyPath:key] = $0 })
    }
    func leafSettingBinding<T>(_ key:WritableKeyPath<LeafBindingSettings,T>) -> Binding<T> {
        Binding(get:{ self.project.leafSettings[keyPath:key] },set:{ self.project.leafSettings[keyPath:key] = $0 })
    }
}
