import SwiftUI
import ImpositionCore

struct ColorControlSizeView: View {
    @ObservedObject var model: Workspace
    enum Scope { case all, scale, registration }
    var scope: Scope = .all
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            if scope != .scale && (model.project.exportMarks.registrationTargets || model.overlays.registrationTargets) {
                HStack { Text("Diz boyutu").frame(maxWidth:.infinity,alignment:.leading); DimensionInput("Diz boyutu",value:model.autoBinding($model.project.exportMarks.targetSize,.exportTargetSize),range:0...100,inspectorID:"targetSize") }
            }
            if scope != .registration && (model.project.exportMarks.colorBar || model.overlays.colorBar) {
                HStack { Text("Renk yaması").frame(maxWidth:.infinity,alignment:.leading); DimensionInput("Renk yaması",value:model.autoBinding($model.project.exportMarks.patchSize,.exportPatchSize),range:0...100,inspectorID:"patchSize") }
            Picker("Skala konumu",selection: model.autoBinding($model.project.exportMarks.barSide,.exportBarSide)) {
                Text("Maşa tarafı").tag(ColorControlSettings.BarSide.gripper)
                Text("Maşanın karşısı").tag(ColorControlSettings.BarSide.opposite)
            }.pickerStyle(.segmented).inspectorTarget("barSide").automaticReset(model,.exportBarSide)
            }
            Text(scope == .scale ? "Skala, baskı rengini kontrol eder." : scope == .registration ? "Diz işaretleri, kalıpları hizalar." : "Diz: kalıpları hizalar · Skala: baskı rengini kontrol eder.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
        }
    }
}
