import SwiftUI

struct PreviewLayersView:View {
    @ObservedObject var model:Workspace
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Katmanlar").font(.headline)
            Toggle("Kesim",isOn:$model.overlays.crop)
            Toggle("Katlama",isOn:$model.overlays.fold)
            Toggle("Taşma",isOn:$model.overlays.bleed)
            Toggle("Güvenli alan",isOn:$model.overlays.safeArea)
            Toggle("Sayfa numaraları",isOn:$model.overlays.pageNumbers)
            Toggle("Tabaka sınırı",isOn:$model.overlays.sheetBoundary)
            Text("Yalnız önizlemeyi değiştirir.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
        }.padding(16).frame(width:230)
    }
}
