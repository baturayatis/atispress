import SwiftUI
import ImpositionCore

/// Window-local values remember a control's inactive value. They never enter a
/// production project or alter the planner; explicit saved settings remain authoritative.
struct InspectorEditMemory {
    struct SerialStyle { var code:SerialCodeSettings?; var color:BleedColor }
    struct SerialDigits { var digits:Int; var automatic:Int?; var fixed:Bool? }
    var serialDigitModes:[String:SerialDigits] = [:]
    var serialStyles:[String:SerialStyle] = [:]
    var wasteOrigins:[String:WasteSettings] = [:]
    var counts:[String:Int] = [:]
    var coverSelections:[String:CoverSelection] = [:]
    var customGutters:[String:Double] = [:]
    var bleedOrigins:[String:(amount:Double,enabled:Bool)] = [:]
    var layoutSerials:[String:[SerialField]] = [:]
    var lastMappedSerials:[SerialField]?
}
extension Workspace {
    func optionalCountBinding(_ value:Binding<Int?>,name:String,defaultValue:Int,field:AutoLayoutField? = nil) -> Binding<Bool> {
        Binding(get:{value.wrappedValue != nil},set:{ enabled in
            if let field { self.markManual(field) }
            let key = self.inspectorMemoryKey+name
            if enabled { value.wrappedValue = self.inspectorMemory.counts[key] ?? defaultValue }
            else { if let current = value.wrappedValue { self.inspectorMemory.counts[key] = current }; value.wrappedValue = nil }
        })
    }
    func setCoverMode(_ mode:CoverMode) {
        let old = project.coverMode
        guard old != mode else { return }
        inspectorMemory.coverSelections[inspectorMemoryKey+old.rawValue] = bookSettings.selection
        if let remembered = inspectorMemory.coverSelections[inspectorMemoryKey+mode.rawValue] { bookSettings.selection = remembered }
        else if (old == .separate) != (mode == .separate) { bookSettings.selection = CoverSelection() }
        project.coverMode = mode
    }
}


extension Workspace {
    func serialKindBinding(_ id:UUID) -> Binding<SerialCodeSettings.Kind> {
        Binding(get:{ self.editableSerialFields.first { $0.id == id }?.kind ?? .text },set:{ kind in
            guard let i = self.editableSerialFields.firstIndex(where:{ $0.id == id }) else { return }
            var fields = self.editableSerialFields
            let field = fields[i], key = self.inspectorMemoryKey+id.uuidString
            self.inspectorMemory.serialStyles[key+field.kind.rawValue] = .init(code:field.code,color:field.color)
            if let remembered = self.inspectorMemory.serialStyles[key+kind.rawValue] { fields[i].code = remembered.code; fields[i].color = remembered.color }
            else { fields[i].kind = kind }
            self.editableSerialFields = fields
        })
    }
    func serialManualDigitsBinding(_ id:UUID) -> Binding<Bool> {
        Binding(get:{ self.editableSerialFields.first { $0.id == id }?.digitsAreManual ?? false },set:{ enabled in
            guard let i = self.editableSerialFields.firstIndex(where:{ $0.id == id }) else { return }
            var fields = self.editableSerialFields
            let key = self.inspectorMemoryKey+id.uuidString+"digits"
            let current = fields[i]
            self.inspectorMemory.serialDigitModes[key+String(current.digitsAreManual)] = .init(digits:current.digits,automatic:current.autoIncreasedDigits,fixed:current.fixedDigits)
            if let previous = self.inspectorMemory.serialDigitModes[key+String(enabled)] {
                fields[i].digits = previous.digits; fields[i].autoIncreasedDigits = previous.automatic; fields[i].fixedDigits = previous.fixed
            } else { fields[i].digitsAreManual = enabled }
            self.editableSerialFields = fields
        })
    }
    var workflowWastePercent:Double {
        get { workflowWaste.percent }
        set {
            let key = inspectorMemoryKey+(project.team == nil ? selectedGangJob?.id.uuidString ?? "global" : "team")
            let remembered = inspectorMemory.wasteOrigins[key], original = remembered ?? workflowWaste
            if remembered == nil,newValue != original.percent { inspectorMemory.wasteOrigins[key] = original }
            var value = workflowWaste
            value.percent = newValue
            value.mode = remembered != nil && newValue == original.percent ? original.mode : .percent
            workflowWaste = value
            if remembered != nil && newValue == original.percent { inspectorMemory.wasteOrigins.removeValue(forKey:key) }
        }
    }
}
