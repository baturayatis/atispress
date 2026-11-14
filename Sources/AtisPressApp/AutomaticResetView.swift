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
    @FocusState private var active:Bool
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.focused($active)
        .onHover { hovered = $0 }
        .simultaneousGesture(TapGesture().onEnded { model.ui.focusedArea = WorkflowPresentation.focus(field) })
        .onChange(of:active) { _,focused in if focused { model.ui.focusedArea = WorkflowPresentation.focus(field) } }
    }
}
extension View {
    func automaticReset(_ model: Workspace,_ field: AutoLayoutField) -> some View {
        modifier(AutomaticResetModifier(model:model,field:field))
    }
}
