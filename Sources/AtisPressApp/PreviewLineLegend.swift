import SwiftUI
import ImpositionCore

struct PreviewLineEntry:Identifiable {
    var id:String
    var title:String
    var color:Color
    var dashed:Bool = false
    var printed:Bool
}
enum PreviewLineLegend {
    static func entries(safeArea:Double) -> [PreviewLineEntry] {
        [
            .init(id:"cropPrint",title:"Kesim işaretleri / tam kesim",color:.black,printed:true),
            .init(id:"foldPrint",title:"Katlama işaretleri",color:.black,printed:true),
            .init(id:"bleedPrint",title:"Taşma / güvenli alan çıktı işaretleri (baskı alanı dışında)",color:.black,printed:true),
            .init(id:"colorPrint",title:"Renk skalası",color:.cyan,printed:true),
            .init(id:"targetsPrint",title:"Diz işaretleri",color:.black,printed:true),
            .init(id:"infoPrint",title:"Bilgi şeridi / çıktı sayfa etiketleri",color:.black,printed:true),
            .init(id:"punchPrint",title:"Delik işaretleri",color:.black,printed:true),
            .init(id:"crop",title:"Kesim çizgisi",color:.black,printed:false),
            .init(id:"sharedCut",title:"Ortak kesim",color:.black,printed:false),
            .init(id:"trim",title:"Kesim yuvası sınırı",color:DesignSystem.muted,printed:false),
            .init(id:"fold",title:"Katlama kılavuzu",color:.blue,dashed:true,printed:false),
            .init(id:"bleed",title:"Taşma kılavuzu",color:.red,dashed:true,printed:false),
            .init(id:"generatedBleed",title:"Üretilen taşma alanı",color:DesignSystem.teal,printed:false),
            .init(id:"safeArea",title:"Güvenli alan: \(TRFormat.dimension(safeArea)) mm",color:.green,dashed:true,printed:false),
            .init(id:"pageLabel",title:"Sayfa numaraları",color:.blue,printed:false),
            .init(id:"sheetBoundary",title:"Tabaka sınırı",color:.black,printed:false),
            .init(id:"margin",title:"Kenar payı",color:.orange,dashed:true,printed:false),
            .init(id:"gripper",title:"Maşa",color:.orange,printed:false),
            .init(id:"punch",title:"Delik kılavuzları",color:.black,printed:false),
            .init(id:"selection",title:"Seçili seri / konum çerçevesi",color:DesignSystem.teal,printed:false),
            .init(id:"blank",title:"Boş sayfa çaprazı",color:.gray,printed:false),
            .init(id:"error",title:"Taşma / hata çerçevesi",color:.red,printed:false)
        ]
    }
}
struct PreviewLineLegendView:View {
    @ObservedObject var model:Workspace
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:10) {
                Text("Çizgiler").font(.headline)
                ForEach(PreviewLineLegend.entries(safeArea:model.project.settings.safeAreaInset)) { entry in
                    HStack(alignment:.top) {
                        Path { p in p.move(to:CGPoint(x:0,y:8)); p.addLine(to:CGPoint(x:32,y:8)) }.stroke(entry.color,style:StrokeStyle(lineWidth:2,dash:entry.dashed ? [4,2] : [])).frame(width:32,height:16)
                        VStack(alignment:.leading) {
                            Text(entry.title)
                            Text(entry.printed ? "Çıktıya basılır" : "Yalnız kılavuz · çıktıya basılmaz").font(.caption).foregroundStyle(DesignSystem.muted)
                        }
                    }
                }
            }.padding(16)
        }.frame(width:380,height:480)
    }
}
extension Workspace {
    var hasPreviewGuides:Bool {
        overlays.crop || overlays.fold || overlays.bleed || overlays.safeArea || overlays.pageNumbers || overlays.sheetBoundary || overlays.pressGuides || overlays.punch || overlays.colorBar || overlays.registrationTargets || overlays.generatedBleedTint == true
    }
}
