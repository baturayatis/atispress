import SwiftUI

struct HomeEmptyStateView: View {
    @ObservedObject var model: Workspace
    private var busy: Bool { model.loading || model.exporting || model.autoArranging }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "doc.richtext").font(.system(size: 48)).foregroundStyle(.secondary)
                Text("PDF ile başlayın").font(.title2.bold())
                Text("1. PDF seç → 2. Ayarları kontrol et → 3. Dışa aktar")
                    .font(.headline).multilineTextAlignment(.center)
                Text("PDF dosyasını buraya sürükle veya ⌘O ile yükle")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button(action: model.choosePDF) { Label("PDF Seç…",systemImage: "doc.badge.plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Proje Aç…",action: model.chooseProject)
                        .buttonStyle(.bordered).controlSize(.large)
                }.disabled(busy)
                VStack(alignment: .leading,spacing: 8) {
                    Text("Son kullanılanlar").font(.headline)
                    if model.recentFiles.isEmpty {
                        Text("Henüz dosya açılmadı.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.recentFiles) { file in
                        Button { model.openRecent(file) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: file.url.pathExtension.lowercased() == "atispress" ? "doc.text" : "doc.richtext")
                                VStack(alignment: .leading,spacing: 2) {
                                    Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text(file.url.deletingLastPathComponent().path)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if !file.isAvailable { Text("Bulunamadı").font(.caption) }
                            }.padding(8).frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(busy || !file.isAvailable)
                        .foregroundStyle(file.isAvailable ? Color.primary : Color.secondary)
                        .opacity(file.isAvailable ? 1 : 0.5)
                        .help(file.url.path)
                    }
                }.frame(maxWidth: 420,alignment: .leading).padding(.top,16)
            }.padding(28).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity,maxHeight: .infinity)
        .onAppear { model.refreshRecentFiles() }
    }
}
