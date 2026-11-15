import SwiftUI
import ImpositionCore
import PDFEngine

extension Workspace {
    var cropMarkStatus:String {
        guard (project.exportMarks.crop || project.exportMarks.fullCut),!plan.sheets.isEmpty else {return "Kesim işareti: 0 adet"}
        let sides=plan.sheets.flatMap {sheet in [sheet.front,sheet.back].filter{!$0.slots.isEmpty}.map {(sheet,$0)} }
        let count=sides.reduce(0) { n,pair in n+PDFExportMarkRenderer.geometry(side:pair.1,sheet:pair.0,settings:project.exportMarks).segments.filter{$0.kind == .crop || $0.kind == .sharedCut}.count }
        return count>0 ? "Kesim işareti: \(count) adet":"Kesim işareti sığmıyor: kenar payı yetersiz"
    }
    func bleedResult(pages:[SourcePage],enabled:Bool,amount:Double,settings:GeneratedBleedSettings,adjacent:Bool) -> String {
        if amount<=0 {return "Taşma üretilemedi: taşma miktarı 0 mm"}
        if !enabled {
            if !pages.isEmpty,pages.allSatisfy({($0.availableBleed ?? 0)+0.001>=amount}) {return "Taşma: kaynakta \(TRFormat.dimension(amount)) mm, her kartın 4 kenarında"}
            return "Taşma üretilemedi: taşma üretimi kapalı"
        }
        func white(_ color:BleedColor) -> Bool {
            switch color {case .rgb(let r,let g,let b):return min(r,g,b)>0.97;case .cmyk(let c,let m,let y,let k):return max(c,m,y,k)<0.03}
        }
        if settings.method == .solidColor && white(settings.color) {return "Taşma: kenar rengi beyaz, taşma beyaz çıkar"}
        if settings.method != .solidColor {
            guard let source else {return "Taşma üretilemedi: kaynak PDF yok"}
            let samples=pages.compactMap {source.edgeSamples.cached(page:$0.number)}
            if samples.count<pages.count {return "Taşma üretilemedi: kenar örnekleri henüz hazır değil"}
            if samples.allSatisfy({sample in SampleEdge.allCases.allSatisfy {edge in sample.strips[edge]?.uniformColor(tolerance:settings.tolerance).map(white) ?? false}}) {return "Taşma: kenar rengi beyaz, taşma beyaz çıkar"}
        }
        return adjacent ? "Taşma: bloğun dış çevresinde (bitişik dizilim)":"Taşma: her kartın 4 kenarında üretildi"
    }
    var bleedResultLines:[String] {
        guard !project.pages.isEmpty else {return []}
        if project.binding == .gang {
            return (project.gang?.jobs ?? []).map {job in job.name+" · "+bleedResult(pages:[job.front]+[job.back].compactMap{$0},enabled:job.generatedBleed.enabled,amount:job.bleed,settings:job.generatedBleed,adjacent:project.sheet.gutter==0)}
        }
        return [bleedResult(pages:project.pages,enabled:plan.generatedBleed.enabled,amount:project.settings.bleed,settings:plan.generatedBleed,adjacent:!project.isBooklet && project.sheet.gutter==0)]
    }
}
