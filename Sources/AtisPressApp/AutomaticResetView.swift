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
    func body(content: Content) -> some View {
        HStack(alignment:.center,spacing:5) {
            content
            AutomaticResetButton(model:model,field:field)
        }
    }
}
extension View {
    func automaticReset(_ model: Workspace,_ field: AutoLayoutField) -> some View {
        modifier(AutomaticResetModifier(model:model,field:field))
    }
}
