import SwiftUI
import PDFEngine
import ImpositionCore

struct PreflightRow: Identifiable {
    var id: String
    var severity: PDFPreflightFinding.Severity
    var pages: [Int]
    var explanation: String
    var text: String {
        var parts: [String] = [],start: Int?,end: Int?
        for page in pages {
            if let last = end,page-last == 1 { end = page }
            else {
                if let a = start,let b = end { parts.append(a == b ? "\(a)" : "\(a)-\(b)") }
                start = page; end = page
            }
        }
        if let a = start,let b = end { parts.append(a == b ? "\(a)" : "\(a)-\(b)") }
        return "\(severity.rawValue) · \(pages.count) sayfa (\(parts.joined(separator: ", "))): \(explanation)"
    }
}
extension Workspace {
    var preflightRows: [PreflightRow] {
        guard let source else { return [] }
        var findings = source.preflight.filter { included.contains($0.page) }
        if project.binding == .gang {
            findings = []
            for job in project.gang?.jobs ?? [] {
                let pages = [job.front,job.back].compactMap { $0 },numbers = Set(pages.map(\.number))
                let assetIndex = gangAssets.firstIndex { $0.saved.id==job.sourceID }
                let offset = assetIndex.map { index in gangAssets.prefix(index).reduce(0) { $0+$1.saved.pageCount } } ?? 0
                // Inspect originals: PDFKit's temporary merge may normalize fonts/resources.
                let originalFindings = assetIndex.map { gangAssets[$0].source.preflight } ?? source.preflight
                findings += originalFindings.filter { numbers.contains($0.page+offset) }.map { original in
                    var f = original; f.explanation = job.name+": "+f.explanation; return f
                }
                if job.bleed>0 && !job.generatedBleed.enabled {
                    findings += pages.filter { ($0.availableBleed ?? 0)<job.bleed }.map { PDFPreflightFinding("bleed",page:$0.number-offset,job.name+": Taşma payı eksik veya kontrol edilemedi.") }
                }
                if let back = job.back,back.trimSize != job.front.trimSize {
                    findings += pages.map { PDFPreflightFinding("size",page:$0.number-offset,job.name+": Ön ve arka kesim ölçüleri farklı.") }
                }
            }
        }
        let pages = project.binding == .gang ? [] : project.pages
        if Set(pages.map { "\($0.trimSize.width)/\($0.trimSize.height)" }).count > 1 {
            findings += pages.map { PDFPreflightFinding("size",page: $0.number,"Sayfa boyutları farklı; sayfa düzenini ve eşleştirmeyi kontrol edin.") }
        }
        if project.settings.bleed > 0 && !project.settings.generatedBleed.enabled {
            findings += pages.filter { ($0.availableBleed ?? 0) < project.settings.bleed }.map {
                PDFPreflightFinding("bleed",page: $0.number,"Taşma payı eksik veya kontrol edilemedi.")
            }
        }
        var groups: [String:PreflightRow] = [:]
        for var finding in findings {
            if finding.code == "rgb",project.autoLayout?.production != .offset { finding.severity = .notice }
            let key = finding.severity.rawValue+finding.code+finding.explanation
            if groups[key] == nil { groups[key] = PreflightRow(id: key,severity: finding.severity,pages: [],explanation: finding.explanation) }
            if groups[key]?.pages.contains(finding.page) != true { groups[key]?.pages.append(finding.page) }
        }
        return groups.values.map { value in var row = value; row.pages.sort(); return row }.sorted {
            if $0.severity != $1.severity { return $0.severity.rawValue > $1.severity.rawValue }
            return $0.id < $1.id
        }
    }
}
struct PreflightView: View {
    @ObservedObject var model: Workspace
    var body: some View {
        GroupBox("Ön Kontrol") {
            VStack(alignment: .leading,spacing: 7) {
                Text(model.project.autoLayout?.production == .offset ? "Ofset: RGB bulgularını ve renk ayrımlarını kontrol edin." : "Dijital: RGB bulguları bilgilendirme amaçlıdır.")
                    .font(.caption)
                if model.source == nil { Text("PDF yüklenince otomatik incelenir.").font(.caption).foregroundStyle(.secondary) }
                else {
                    ForEach(model.preflightRows) { row in
                        Text(row.text).font(.caption).foregroundStyle(row.severity == .warning ? Color.orange : Color.secondary)
                            .textSelection(.enabled)
                    }
                    Text("En iyi çaba; bulgu olmaması uygunluk onayı değildir. Renk yönetimi, bindirme, gerçek piksel mürekkep kaplaması ve tüm PDF özellikleri kontrol edilemedi. Dışa aktarımı engellemez.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity,alignment: .leading).padding(5)
        }
    }
}
