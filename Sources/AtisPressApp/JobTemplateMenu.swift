import SwiftUI

struct JobTemplateMenu: View {
    @ObservedObject var model: Workspace
    @State private var name = ""
    @State private var editingName = false
    @State private var renameID: UUID?
    @State private var confirmingDelete = false

    private var selected: JobTemplate? {
        model.jobTemplates.first { $0.id == model.selectedJobTemplateID }
    }

    var body: some View {
        Menu {
            ForEach(model.jobTemplates) { template in
                Button {
                    model.loadJobTemplate(template)
                } label: {
                    if template.id == model.selectedJobTemplateID {
                        Label(template.name, systemImage: "checkmark")
                    } else {
                        Text(template.name)
                    }
                }
            }
            if !model.jobTemplates.isEmpty { Divider() }
            Button("Ayarları şablon olarak kaydet…") {
                renameID = nil
                name = ""
                editingName = true
            }
            if let selected {
                Button("Yeniden adlandır…") {
                    renameID = selected.id
                    name = selected.name
                    editingName = true
                }
                Button("Şablonu sil…", role: .destructive) { confirmingDelete = true }
            }
        } label: {
            Text(selected.map { "Şablon: \($0.name)" } ?? "Şablon").lineLimit(1)
        }
        .accessibilityLabel("Şablon")
        .accessibilityIdentifier("jobTemplate")
        .disabled(model.loading || model.preparingSource || model.autoArranging || model.exporting)
        .task { perform { try model.refreshJobTemplates() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            perform { try model.refreshJobTemplates() }
        }
        .alert(renameID == nil ? "İş şablonunu kaydet" : "İş şablonunu yeniden adlandır", isPresented: $editingName) {
            TextField("Şablon adı", text: $name)
            Button("İptal", role: .cancel) {}
            Button("Kaydet") {
                perform {
                    if let renameID { try model.renameJobTemplate(renameID, to: name) }
                    else { try model.saveJobTemplate(name: name) }
                }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("İş şablonu silinsin mi?", isPresented: $confirmingDelete) {
            Button("Sil", role: .destructive) {
                if let id = selected?.id { perform { try model.deleteJobTemplate(id) } }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { model.error = error.localizedDescription }
    }
}
