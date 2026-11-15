import Foundation
import ImpositionCore

enum WorkflowAddon:String,CaseIterable,Identifiable {
    case serial = "Seri numara / QR kod", scaling = "Hedef ebada ölçeklendir", color = "Renk skalası ve diz işaretleri", info = "Bilgi şeridi", pricing = "Maliyet ve teklif"
    var id:String { rawValue }
}
enum WorkflowFocus:String { case margins, gripper, gutter, bleed, marks }
enum WorkflowPresentation {
    static let sheetChips = ["Otomatik","A5","A4","A3","SRA3","33×48","35×50","50×70","70×100","Özel ölçü…"]
    static let sheetPresets:[String:SheetPreset] = ["A5":.a5,"A4":.a4,"A3":.a3,"SRA3":.sra3,"33×48":.cm33x48,"35×50":.cm35x50,"50×70":.cm50x70,"70×100":.cm70x100]
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

extension WorkflowPresentation {
    static let overlayNames = ["Kesim çizgisi", "Katlama", "Taşma", "Güvenli alan", "Sayfa numaraları", "Tabaka sınırı"]
    static func cardFields(_ title:String) -> [AutoLayoutField] {
        let paper:[AutoLayoutField] = [.sheetSize,.orientation]
        let cut:[AutoLayoutField] = [.bleed,.generatedEnabled,.exportCrop]
        let color:[AutoLayoutField] = [.exportColorBar,.exportTargets,.exportTargetSize,.exportPatchSize,.exportBarSide]
        switch title {
        case "Hangi kâğıda basılacak?": return paper
        case "Kesim ve taşma": return cut
        case "Eklemek istersen": return color
        case "Ayrıntılar": return AutoLayoutField.allCases.filter { !paper.contains($0) && !cut.contains($0) && !color.contains($0) }
        default: return []
        }
    }
    static func shouldRecommend(selectedValid:Bool,selectedCopies:Int,recommendedCopies:Int) -> Bool {
        !selectedValid || selectedCopies < recommendedCopies
    }
    static func actionableIssues(_ issues:[ValidationIssue]) -> [ValidationIssue] {
        issues.filter { $0.code != .sharedCutBleed || $0.severity == .error }
    }
}

extension Workspace {
    var workflowIssues:[ValidationIssue] { !project.hasPanelItems ? [] : WorkflowPresentation.actionableIssues(plan.displayIssues) }
    var visibleWorkflowRecommendation:WorkflowSheetRecommendation? {
        guard let recommendation = workflowRecommendation, recommendation.name != SmartAutoLayout.presetName(for:project.sheet.size) else { return nil }
        let size = project.sheet.size
        // Digital stock includes the common 33×48 press sheet in either orientation.
        let validStock = project.autoLayout?.production != .digital || (min(size.width,size.height) <= 330 && max(size.width,size.height) <= 483)
        let copies = plan.sheets.first.map { $0.repeatLayout?.copiesPerSheet ?? $0.front.slots.count } ?? 0
        return WorkflowPresentation.shouldRecommend(selectedValid:plan.canExport && validStock,selectedCopies:copies,recommendedCopies:recommendation.copies) ? recommendation : nil
    }
    func workflowRecommendationText(_ recommendation:WorkflowSheetRecommendation) -> String {
        let production = project.autoLayout?.production == .offset ? "ofset" : "dijital"
        let copies = plan.sheets.first.map { $0.repeatLayout?.copiesPerSheet ?? $0.front.slots.count } ?? 0
        return "\(recommendation.name) \(production) makinede çalışır · \(recommendation.copies) adet. Seçili \(SmartAutoLayout.presetName(for:project.sheet.size)) · \(copies) adet."
    }
}

// Gang projects may carry their pages only in the product jobs.
extension Project {
    var hasPanelItems:Bool {
        if binding == .gang {return !(gang?.jobs.isEmpty ?? true)}
        return !pages.isEmpty
    }
}
