import SwiftUI
import ImpositionCore
import UniformTypeIdentifiers

struct JobTemplateMenu: View {
    @ObservedObject var model: Workspace
    @State private var name = ""
    @State private var width = ""
    @State private var height = ""
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
                setSize(model.suggestedTemplateSize)
                editingName = true
            }
            if let selected {
                Button("Adı ve ebadı düzenle…") {
                    renameID = selected.id
                    name = selected.name
                    setSize(selected.expectedSize)
                    editingName = true
                }
                Button("Şablonu sil…", role: .destructive) { confirmingDelete = true }
                Button("JSON olarak dışa aktar…") { exportTemplate(selected) }
            }
            Button("JSON şablonu içe aktar…") { importTemplate() }
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
        .alert(renameID == nil ? "İş şablonunu kaydet" : "İş şablonunu düzenle", isPresented: $editingName) {
            TextField("Şablon adı", text: $name)
            TextField("Beklenen genişlik (mm)", text: $width)
            TextField("Beklenen yükseklik (mm)", text: $height)
            Button("İptal", role: .cancel) {}
            Button("Kaydet") {
                perform {
                    let size = try enteredSize()
                    if let renameID { try model.updateJobTemplate(renameID, name: name, expectedSize: size) }
                    else { try model.saveJobTemplate(name: name, expectedSize: size) }
                }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("Ebat isteğe bağlıdır. Kullanmayacaksanız iki ölçüyü de boş bırakın.") }
        .confirmationDialog("İş şablonu silinsin mi?", isPresented: $confirmingDelete) {
            Button("Sil", role: .destructive) {
                if let id = selected?.id { perform { try model.deleteJobTemplate(id) } }
            }
        }
    }

    private func setSize(_ size: Size?) {
        width = size.map { TRFormat.dimension($0.width, detail: true) } ?? ""
        height = size.map { TRFormat.dimension($0.height, detail: true) } ?? ""
    }

    private func enteredSize() throws -> Size? {
        let values = [width, height].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if values.allSatisfy(\.isEmpty) { return nil }
        let parser = FloatingPointFormatStyle<Double>.number.locale(TRFormat.locale).parseStrategy
        let parsed = values.map { try? parser.parse($0) }
        guard let width = parsed[0], let height = parsed[1] else { throw JobTemplateError.invalidMetadata }
        return Size(width, height)
    }

    private func exportTemplate(_ template: JobTemplate) {
        let panel = NSSavePanel()
        panel.title = "İş şablonunu dışa aktar"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = template.name.replacingOccurrences(of: "/", with: "-") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try model.exportJobTemplate(template.id, to: url) }
    }

    private func importTemplate() {
        let panel = NSOpenPanel()
        panel.title = "İş şablonu seçin"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try model.importJobTemplate(from: url) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { model.error = error.localizedDescription }
    }
}
