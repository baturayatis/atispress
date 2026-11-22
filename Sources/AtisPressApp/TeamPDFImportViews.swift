import SwiftUI

struct TeamPDFImportDialog: View {
    @ObservedObject var model: Workspace
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Çok sayfalı PDF").font(.headline)
            Toggle("Seçimimi hatırla", isOn: $remember)
                .toggleStyle(.checkbox)
                .help("Bu seçimi sonraki çok sayfalı PDF açılışlarında uygular. Ayarlar’dan değiştirebilirsiniz.")
            HStack {
                Spacer()
                Button(TeamPDFImport.asIs.title) { model.finishTeamImport(.asIs, remember: remember) }
                Button(TeamPDFImport.team.title) { model.finishTeamImport(.team, remember: remember) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onExitCommand { model.finishTeamImport(.asIs, remember: false) }
    }
}

struct TeamPDFImportSettings: View {
    @ObservedObject var settings: UsabilitySettings
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        Form {
            Picker("Çok sayfalı PDF açılışı", selection: $settings.teamPDFImport) {
                ForEach(TeamPDFImport.allCases) { choice in Text(choice.title).tag(choice) }
            }
            Text("Yalnızca yeni PDF açılışları için geçerlidir. Montaj bölümünden açık işi elle değiştirebilirsiniz.")
                .foregroundStyle(.secondary)
                .font(.caption)
            UpdateSettingsSection(checker:updates)
        }
        .padding(20)
        .frame(width: 430)
    }
}
