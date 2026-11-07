import SwiftUI
import ImpositionCore

struct ColorControlSizeView: View {
    @ObservedObject var model: Workspace
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            HStack {
                Text(model.autoLabel("Diz boyutu (mm)",.exportTargetSize))
                TextField("Diz boyutu (mm)",value: model.autoBinding($model.project.exportMarks.targetSize,.exportTargetSize),format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
            }
            HStack {
                Text(model.autoLabel("Yama boyutu (mm, kare)",.exportPatchSize))
                TextField("Yama boyutu",value: model.autoBinding($model.project.exportMarks.patchSize,.exportPatchSize),format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
            }
            Picker(model.autoLabel("Skala konumu",.exportBarSide),selection: model.autoBinding($model.project.exportMarks.barSide,.exportBarSide)) {
                Text("Maşa tarafı").tag(ColorControlSettings.BarSide.gripper)
                Text("Maşanın karşısı").tag(ColorControlSettings.BarSide.opposite)
            }
            Text("12 CMYK yama · CMY gri: %50 / %40 / %40").font(.caption).foregroundStyle(.secondary)
            Text("Ölçüler önizleme ve çıktı için ortaktır; görünürlük anahtarları bağımsızdır. Dizler registration, yamalar CMYK basılır.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
