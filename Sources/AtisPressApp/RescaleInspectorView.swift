import SwiftUI
import ImpositionCore

struct ScalingRow: Identifiable {
    var indices: [Int]
    var pages: [Int]
    var gangID: UUID?
    var jobIndex: Int?
    var size: Size
    var settings: RescaleSettings?
    var defaultTarget: Size
    var id: Int { indices[0] }
    var title: String {
        let numbers = indices.map { String($0+1) }.joined(separator:", ")
        let label = indices.count > 1 && indices.last! - indices[0] == indices.count-1 ? "\(indices[0]+1)-\(indices.last!+1)" : numbers
        let target = settings?.target ?? defaultTarget
        func dimension(_ s:Size) -> String { "\(TRFormat.dimension(s.width))×\(TRFormat.dimension(s.height))" }
        return "İş \(label): \(dimension(size))" + (abs(size.width-target.width)<0.1 && abs(size.height-target.height)<0.1 ? " · ebat uygun" : " → \(dimension(target))")
    }
}
extension Workspace {
    var scalingRows: [ScalingRow] {
        var rows: [ScalingRow] = []
        func add(_ pages:[Int],_ size:Size,_ gangID:UUID?,_ jobIndex:Int?) {
            rows.append(ScalingRow(indices:[rows.count],pages:pages,gangID:gangID,jobIndex:jobIndex,size:size,settings:scaleSettings(pages:pages,gangID:gangID,jobIndex:jobIndex),defaultTarget:project.scaling?.defaults.target ?? Size(90,50)))
        }
        if project.binding == .gang {
            for job in project.gang?.jobs ?? [] { add([job.front.number]+[job.back?.number].compactMap { $0 },job.front.trimSize,job.id,nil) }
        } else if project.isBooklet {
            let covers = project.book?.coverPDFPages ?? []
            for pages in [project.pages.filter { !covers.contains($0.number) },project.pages.filter { covers.contains($0.number) }] {
                if let page = pages.first { add(pages.map(\.number),page.trimSize,nil,nil) }
            }
        } else {
            for (i,job) in project.repeatJobs.enumerated() { add([job.front.number]+[job.back?.number].compactMap { $0 },job.front.trimSize,nil,i) }
        }
        return rows
    }
    var groupedScalingRows: [ScalingRow] {
        var groups: [ScalingRow] = []
        for row in scalingRows {
            if let i = groups.firstIndex(where:{ $0.size == row.size && $0.settings == row.settings }) { groups[i].indices += row.indices }
            else { groups.append(row) }
        }
        return groups
    }
    var scalingSummary: String {
        if project.hasInvalidScaling { return "Geçerli bir hedef ebat girin." }
        let rows = scalingRows
        let target = project.scaling?.defaults.target ?? Size(90,50)
        if project.scaling?.enabled != true && rows.allSatisfy({ $0.settings == nil }) {
            let different = rows.filter { abs($0.size.width-target.width)>0.1 || abs($0.size.height-target.height)>0.1 }.count
            return different == 0 ? "Tüm işler hedef ebatta" : "\(different) iş farklı ebatta — ölçekle"
        }
        let values = rows.flatMap { row -> [Int] in
            guard let settings = row.settings, settings.isValid, row.size.width > 0, row.size.height > 0 else { return [100] }
            let factors = ArtworkRescale(source:row.size,settings:settings).factors
            return [Int((factors.width*100).rounded()),Int((factors.height*100).rounded())]
        }
        guard let low = values.min(),let high = values.max() else { return "0 iş" }
        return "\(rows.count) iş · %\(low)" + (low == high ? " ölçek" : "–%\(high) ölçek")
    }
    func updateScaling(_ edit:(inout ScalingSettings)->Void) {
        project.migrateScaling()
        var value = project.scaling!; edit(&value); project.scaling = value
    }
}
struct RescaleInspectorView: View {
    @ObservedObject var model:Workspace
    var body:some View { ScalingSizeRow(model:model) }
}

struct RescalePrompt: Identifiable {
    let id = UUID()
    var pages: [Int]
    var gangID: UUID?
    var jobIndex: Int? = nil
    var size: Size
    var settings: RescaleSettings
    var arrangeAfter = false
}

extension Workspace {
    func scaleSettings(pages:[Int],gangID:UUID?,jobIndex:Int? = nil) -> RescaleSettings? {
        guard let number = pages.first else { return nil }
        return project.scalingSettings(number:number,jobID:gangID,jobIndex:jobIndex)
    }
    func setScale(_ settings:RescaleSettings?,pages:[Int],gangID:UUID?,jobIndex:Int? = nil) {
        updateScaling { value in
            value.overrides = value.overrides.compactMap { override in
                var next = override
                if next.gangID == gangID && next.jobIndex == jobIndex { next.pages.removeAll { pages.contains($0) } }
                return next.pages.isEmpty ? nil : next
            }
            value.overrides.append(ScalingOverride(pages:pages,jobIndex:jobIndex,gangID:gangID,settings:settings))
        }
    }
    @discardableResult func offerRescaling(arrangeAfter:Bool = false) -> Bool {
        var candidates: [RescalePrompt] = []
        func add(_ pages:[Int],_ size:Size,_ id:UUID?,_ jobIndex:Int? = nil) {
            let chosen = scaleSettings(pages:pages,gangID:id,jobIndex:jobIndex)
            let differs = chosen.map { abs($0.target.width-size.width)>0.1 || abs($0.target.height-size.height)>0.1 } ?? false
            let largeCard = size.width>=99.9 && size.height>=59.9 && size.width<=150 && size.height<=100
            let oversized = max(size.width,size.height)>300
            if differs || (chosen == nil && (largeCard || oversized)) {
                candidates.append(RescalePrompt(pages:pages,gangID:id,jobIndex:jobIndex,size:size,settings:chosen ?? RescaleSettings(target:oversized ? Size(210,297) : Size(90,50)),arrangeAfter:arrangeAfter))
            }
        }
        if project.binding == .gang {
            for job in project.gang?.jobs ?? [] { add([job.front.number]+[job.back?.number].compactMap { $0 },job.front.trimSize,job.id) }
        } else if project.isBooklet {
            let covers = project.book?.coverPDFPages ?? []
            let body = project.pages.filter { !covers.contains($0.number) }
            if let page = body.first { add(body.map(\.number),page.trimSize,nil) }
            if let cover = project.pages.first(where:{ covers.contains($0.number) }) { add(covers,cover.trimSize,nil) }
        } else {
            for (index,job) in project.repeatJobs.enumerated() { add([job.front.number]+[job.back?.number].compactMap { $0 },job.front.trimSize,nil,index) }
        }
        pendingScalePrompts = candidates
        rescalePrompt = pendingScalePrompts.isEmpty ? nil : pendingScalePrompts.removeFirst()
        return rescalePrompt != nil
    }
    func finishScalePrompt(_ prompt:RescalePrompt,settings:RescaleSettings?) {
        setScale(settings,pages:prompt.pages,gangID:prompt.gangID,jobIndex:prompt.jobIndex)
        rescalePrompt = nil
        if !pendingScalePrompts.isEmpty {
            DispatchQueue.main.async { self.rescalePrompt = self.pendingScalePrompts.removeFirst() }
        } else if prompt.arrangeAfter { autoArrange(resetOverrides:true,askRescale:false) }
        else { autoArrange(resetOverrides:false,askRescale:false) }
    }
}
