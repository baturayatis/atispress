import SwiftUI

struct PreviewLayersView:View {
    @ObservedObject var model:Workspace
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            let options = $model.overlays
            Text("Katmanlar (çıktıya basılmaz)").font(.headline)
            Toggle("Kesim çizgisi",isOn:options.crop)
            Toggle("Katlama",isOn:options.fold)
            Toggle("Taşma",isOn:options.bleed)
            Toggle("Üretilen taşma",isOn:Binding(get:{model.overlays.generatedBleedTint ?? false},set:{model.overlays.generatedBleedTint = $0}))
            Toggle("Güvenli alan",isOn:options.safeArea)
            Toggle("Sayfa numaraları",isOn:options.pageNumbers)
            Toggle("Tabaka sınırı",isOn:options.sheetBoundary)
            Text("Kılavuzlar çıktıya basılmaz. Kartlar çıktı işaretlerini yönetir.").font(.caption).foregroundStyle(DesignSystem.muted)
        }.padding(16).frame(width:230)
    }
}
