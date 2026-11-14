import Foundation
import ImpositionCore

enum WorkflowAddon:String,CaseIterable,Identifiable {
    case serial = "Seri numara / QR kod", scaling = "Hedef ebada ölçeklendir", color = "Renk skalası ve diz işaretleri", info = "Bilgi şeridi", pricing = "Maliyet ve teklif"
    var id:String { rawValue }
}
enum WorkflowFocus:String { case margins, gripper, gutter, bleed, marks }
enum WorkflowPresentation {
    static let sheetChips = ["Otomatik","A4","A3","SRA3","33×48","35×50","50×70","70×100","Özel ölçü…"]
    static let sheetPresets:[String:SheetPreset] = ["A4":.a4,"A3":.a3,"SRA3":.sra3,"33×48":.cm33x48,"35×50":.cm35x50,"50×70":.cm50x70,"70×100":.cm70x100]
    static func showsBindingCard(_ product:ProductKind) -> Bool { [.book,.catalog,.spiral,.wireO].contains(product) }
    static func focus(_ field:AutoLayoutField) -> WorkflowFocus? {
        switch field {
        case .marginLeft,.marginRight,.marginTop,.marginBottom,.alignment,.orientation: return .margins
        case .gripperEdge,.gripperWidth: return .gripper
        case .gutter,.rows,.columns: return .gutter
        case .bleed,.generatedEnabled,.generatedMethod,.generatedColor,.generatedTolerance: return .bleed
        case .cropLength,.cropOffset,.safeArea: return .marks
        default: return field.rawValue.hasPrefix("export") ? .marks : nil
        }
    }
    static func pageRole(_ number:Int,project:Project) -> String {
        if project.binding == .stepAndRepeat {
            for job in project.repeatJobs {
                if job.front.number == number { return job.back == nil ? "Ön · tek yüz" : "Ön" }
                if job.back?.number == number { return "Arka" }
            }
        }
        return number.isMultiple(of:2) ? "Arka" : "Ön"
    }
}

struct WorkflowSheetRecommendation:Equatable,Sendable { var name:String; var copies:Int }
