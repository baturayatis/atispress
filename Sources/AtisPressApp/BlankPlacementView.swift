import SwiftUI
import ImpositionCore

struct BlankPlacementInspector: View {
    @ObservedObject var model: Workspace
    var body: some View {
        GroupBox("Boş sayfalar") {
            VStack(alignment:.leading,spacing:7) {
                Picker("Boş sayfalar nereye",selection:$model.blankSettings.mode) {
                    Text("Sona").tag(BlankPlacement.Mode.end)
                    Text("Başa").tag(BlankPlacement.Mode.start)
                    Text("Elle seç").tag(BlankPlacement.Mode.manual)
                }.inspectorSetting(model,"Boş sayfalar nereye",SettingGuidance.detail("Boş sayfalar nereye"))
                Text(model.plan.paginationSummary).font(.caption).textSelection(.enabled)
                if model.blankSettings.mode == .manual {
                    Text("Soldaki iç okuma sırasında boş konumları işaretleyin. Konum, kapaklar ayrıldıktan sonraki kitap sırasıdır; PDF sayfa numarası değildir.").font(.caption).foregroundStyle(.secondary)
                    Button("Seçimi temizle") { model.blankSettings.positions = [] }
                }
                if model.project.blankPagePolicy == .reject && model.plan.addedBlankPages>0 {
                    Text("Boş sayfa politikası çıktıyı engelliyor.").font(.caption).foregroundStyle(.orange)
                    Button("Boş sayfa eklemeye izin ver") { model.project.blankPagePolicy = .append }
                }
            }.padding(5)
        }
    }
}
struct BlankPageOrderView: View {
    @ObservedObject var model: Workspace
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            Text("İç okuma sırası · \(model.blankSettings.positions.count)/\(model.plan.addedBlankPages) boş seçildi").font(.caption.bold())
            ScrollView {
                LazyVStack(alignment:.leading,spacing:5) {
                    ForEach(Array(model.plan.readingOrder.enumerated()),id:\.offset) { i,page in
                        let position = i+1,selected = model.blankSettings.positions.contains(position)
                        Toggle(isOn:Binding(get:{ model.blankSettings.positions.contains(position) },set:{ model.setBlankPosition(position,selected:$0) })) {
                            Text("\(position). "+(page.map { "PDF "+model.coverPageLabel($0) } ?? (selected ? "Boş" : "Boş (geçici)"))).font(.caption)
                        }.toggleStyle(.checkbox)
                            .disabled(!selected && model.blankSettings.positions.count>=model.plan.addedBlankPages)
                    }
                }.padding(4)
            }.frame(height:170)
        }
    }
}
