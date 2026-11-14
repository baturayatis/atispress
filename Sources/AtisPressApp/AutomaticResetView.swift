import SwiftUI
import ImpositionCore

struct AutomaticResetButton: View {
    @ObservedObject var model: Workspace
    let field: AutoLayoutField
    var body: some View {
        if model.isManual(field) {
            Button("Otomatik'e dön") { model.returnToAutomatic(field) }
                .font(.caption2).buttonStyle(.borderless).fixedSize()
        }
    }
}
private struct AutomaticResetModifier: ViewModifier {
    @ObservedObject var model: Workspace
    let field: AutoLayoutField
    @Environment(\.inspectorSection) private var section
    @Environment(\.inspectorSearchEnabled) private var searchEnabled
    func body(content: Content) -> some View {
        if !searchEnabled || model.ui.matches(SettingGuidance.title(field),section:section) {
            HStack(alignment:.center,spacing:5) {
                content
                SettingHelp(title:SettingGuidance.title(field),detail:SettingGuidance.detail(field))
                AutomaticResetButton(model:model,field:field)
            }
        }
    }
}
extension View {
    func automaticReset(_ model: Workspace,_ field: AutoLayoutField) -> some View {
        modifier(AutomaticResetModifier(model:model,field:field))
    }
}
