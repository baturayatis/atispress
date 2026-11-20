import ImpositionCore
import SwiftUI

struct MachineProfileView: View {
    @ObservedObject var model: Workspace
    @State private var draft: MachineProfile?
    @State private var confirmingDelete = false

    private var profiles: [MachineProfile] {
        var profiles = model.machineProfiles
        if let selected = model.project.machineProfile, !profiles.contains(where: { $0.id == selected.id }) {
            profiles.append(selected)
        }
        return profiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Makine", selection: Binding(
                get: { model.project.machineProfile?.id },
                set: { id in model.selectMachineProfile(profiles.first { $0.id == id }) }
            )) {
                Text("Makine yok / Serbest").tag(nil as UUID?)
                ForEach(profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .accessibilityIdentifier("machineProfile")
            if let profile = model.project.machineProfile {
                Text(TRFormat.size(profile.size.width, profile.size.height))
                    .foregroundStyle(DesignSystem.muted)
                Picker("Yön", selection: layoutBinding(\.rotation, unselected: .automatic)) {
                    Text("Seçin").tag(nil as MachineProfile.Rotation?)
                    Text("0°").tag(Optional(MachineProfile.Rotation.zero))
                    Text("90°").tag(Optional(MachineProfile.Rotation.ninety))
                }
                LabeledContent("Dizilim") {
                    HStack {
                        layoutCount("Sütun", \.columns)
                        Text("×")
                        layoutCount("Satır", \.rows)
                    }
                }
            }
            HStack {
                Button("Ekle") {
                    var profile = model.project.machineProfile ?? .heidelberg
                    profile.id = UUID()
                    profile.name = ""
                    draft = profile
                }
                Button("Düzenle") { draft = model.project.machineProfile }
                    .disabled(model.project.machineProfile == nil)
                Button("Sil", role: .destructive) { confirmingDelete = true }
                    .disabled(model.project.machineProfile == nil)
            }
        }
        .sheet(item: $draft) { profile in
            MachineProfileEditor(profile: profile) { model.saveMachineProfile($0) }
        }
        .confirmationDialog("Makine profili silinsin mi?", isPresented: $confirmingDelete) {
            Button("Sil", role: .destructive) {
                if let id = model.project.machineProfile?.id { model.deleteMachineProfile(id) }
            }
        }
    }
    private func layoutBinding<Value: Equatable>(_ key: WritableKeyPath<MachineProfile, Value?>,
                                                 unselected: Value? = nil) -> Binding<Value?> {
        Binding(get: {
            let value = model.project.machineProfile?[keyPath: key]
            return value == unselected ? nil : value
        }, set: { value in
            guard var profile = model.project.machineProfile else { return }
            profile[keyPath: key] = value
            model.saveMachineProfile(profile)
        })
    }

    private func layoutCount(_ title: String, _ key: WritableKeyPath<MachineProfile, Int?>) -> some View {
        let value = layoutBinding(key)
        return TextField(title, text: Binding(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { value.wrappedValue = Int($0) }
        ))
        .accessibilityLabel(title)
        .multilineTextAlignment(.trailing)
        .textFieldStyle(.roundedBorder)
        .frame(width: 60)
    }

}

private struct MachineProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: MachineProfile
    var save: (MachineProfile) -> Void

    var body: some View {
        Form {
            TextField("Ad", text: $profile.name)
            LabeledContent("Tabaka genişliği") {
                DimensionInput("Tabaka genişliği", value: $profile.size.width, range: 0.5...10_000)
            }
            LabeledContent("Tabaka yüksekliği") {
                DimensionInput("Tabaka yüksekliği", value: $profile.size.height, range: 0.5...10_000)
            }
            Picker("Tutacak kenarı", selection: $profile.gripperEdge) {
                Text("Alt").tag(ImpositionCore.Edge.bottom)
                Text("Üst").tag(ImpositionCore.Edge.top)
                Text("Sol").tag(ImpositionCore.Edge.left)
                Text("Sağ").tag(ImpositionCore.Edge.right)
            }
            LabeledContent("Tutacak payı") {
                DimensionInput("Tutacak payı", value: $profile.gripperWidth, range: 0...10_000)
            }
            LabeledContent("İşler arası boşluk") {
                DimensionInput("İşler arası boşluk", value: $profile.gap, range: 0...10_000)
            }
            Picker("Yüz", selection: $profile.faces) {
                Text("Tek").tag(MachineProfile.Faces.single)
                Text("Çevir-çevir").tag(MachineProfile.Faces.workAndTurn)
            }
            HStack {
                Spacer()
                Button("İptal") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Kaydet") {
                    profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(profile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!profile.isValid)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
