import SwiftUI
import ImpositionCore

struct ColorControlSizeView: View {
    @ObservedObject var model: Workspace
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            if model.project.exportMarks.registrationTargets || model.overlays.registrationTargets {
                HStack { Text("Diz boyutu").frame(maxWidth:.infinity,alignment:.leading); DimensionInput("Diz boyutu",value:model.autoBinding($model.project.exportMarks.targetSize,.exportTargetSize),range:0...100) }
            }
            if model.project.exportMarks.colorBar || model.overlays.colorBar {
                HStack { Text("Renk yaması").frame(maxWidth:.infinity,alignment:.leading); DimensionInput("Renk yaması",value:model.autoBinding($model.project.exportMarks.patchSize,.exportPatchSize),range:0...100) }
            Picker("Skala konumu",selection: model.autoBinding($model.project.exportMarks.barSide,.exportBarSide)) {
                Text("Maşa tarafı").tag(ColorControlSettings.BarSide.gripper)
                Text("Maşanın karşısı").tag(ColorControlSettings.BarSide.opposite)
            }.pickerStyle(.segmented).automaticReset(model,.exportBarSide)
            }
            Text("Diz: kalıpları hizalar · Skala: baskı rengini kontrol eder.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
        }
    }
}
