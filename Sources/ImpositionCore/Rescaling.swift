import Foundation

public enum RescaleMode: String, Codable, CaseIterable, Sendable {
    case fit, fill, stretch
    public var title: String { switch self { case .fit: return "Sığdır"; case .fill: return "Doldur"; case .stretch: return "Esnet" } }
}
public struct RescaleSettings: Equatable, Codable, Sendable {
    public var target: Size
    public var mode: RescaleMode
    public init(target: Size = Size(90,50),mode: RescaleMode = .fit) { self.target = target; self.mode = mode }
    public var isValid: Bool { [target.width,target.height].allSatisfy { $0.isFinite && $0>0 && $0<=10_000 } }
    public static let targets: [(String,Size)] = [("Kartvizit 90×50",Size(90,50)),("Kartvizit 85×55",Size(85,55)),("A6",Size(105,148)),("A5",Size(148,210)),("A4",Size(210,297)),("DL",Size(99,210))]
}
public struct RescaleJob: Equatable, Codable, Sendable {
    public var pages: [Int]
    public var jobIndex: Int? = nil
    public var settings: RescaleSettings
    public init(pages: [Int],settings: RescaleSettings,jobIndex:Int? = nil) { self.pages = pages; self.settings = settings; self.jobIndex = jobIndex }
}
/// Global defaults with explicit job exceptions; a nil override settings means no scaling.
public struct ScalingOverride: Equatable, Codable, Sendable {
    public var pages: [Int]
    public var jobIndex: Int?
    public var gangID: UUID?
    public var settings: RescaleSettings?
    public init(pages:[Int],jobIndex:Int? = nil,gangID:UUID? = nil,settings:RescaleSettings?) {
        self.pages = pages; self.jobIndex = jobIndex; self.gangID = gangID; self.settings = settings
    }
}
public struct ScalingSettings: Equatable, Codable, Sendable {
    public var enabled = false
    public var defaults = RescaleSettings()
    public var overrides: [ScalingOverride] = []
    public init() {}
}
public struct ArtworkRescale: Equatable, Sendable {
    public var source: Size
    public var settings: RescaleSettings
    public init(source:Size,settings:RescaleSettings) { self.source = source; self.settings = settings }
    public var factors: Size {
        let x = settings.target.width/source.width,y = settings.target.height/source.height
        switch settings.mode { case .fit: return Size(min(x,y),min(x,y)); case .fill: return Size(max(x,y),max(x,y)); case .stretch: return Size(x,y) }
    }
    public var artwork: Rect {
        let w = source.width*factors.width,h = source.height*factors.height
        return Rect(x:(settings.target.width-w)/2,y:(settings.target.height-h)/2,width:w,height:h)
    }
    public var aspectWarning: Bool { settings.mode == .stretch && abs(factors.width/factors.height-1)>0.02 }
    public var summary: String {
        settings.mode == .stretch ? String(format:"%%%.0f × %%%.0f ölçek",100*factors.width,100*factors.height) : String(format:"%%%.0f ölçek",100*factors.width)
    }
}
extension Project {
    public func rescale(for number: Int,jobID:UUID? = nil,jobIndex:Int? = nil) -> ArtworkRescale? {
        let page = jobID.flatMap { id in gang?.jobs.first { $0.id == id }.flatMap { $0.front.number == number ? $0.front : $0.back } } ?? pages.first { $0.number == number }
        guard let page, let settings = scalingSettings(number:number,jobID:jobID,jobIndex:jobIndex),settings.isValid else { return nil }
        return ArtworkRescale(source:page.trimSize,settings:settings)
    }
    public func scalingSettings(number:Int,jobID:UUID? = nil,jobIndex:Int? = nil) -> RescaleSettings? {
        if let scaling {
            if let override = scaling.overrides.last(where: { $0.gangID == jobID && ($0.jobIndex == nil || $0.jobIndex == jobIndex) && $0.pages.contains(number) }) { return override.settings }
            return scaling.enabled ? scaling.defaults : nil
        }
        if let jobID { return gang?.jobs.first { $0.id == jobID }?.rescale }
        return rescaleJobs?.last { $0.pages.contains(number) && ($0.jobIndex == nil || $0.jobIndex == jobIndex) }?.settings
    }
    public mutating func migrateScaling() {
        guard scaling == nil else { return }
        var value = ScalingSettings()
        for old in rescaleJobs ?? [] {
            if binding == .stepAndRepeat {
                for (index,job) in repeatJobs.enumerated() where old.jobIndex == nil || old.jobIndex == index {
                    let selected = ([job.front.number]+[job.back?.number].compactMap { $0 }).filter { old.pages.contains($0) }
                    if !selected.isEmpty { value.overrides.append(ScalingOverride(pages:selected,jobIndex:index,settings:old.settings)) }
                }
            } else { value.overrides.append(ScalingOverride(pages:old.pages,jobIndex:old.jobIndex,settings:old.settings)) }
        }
        for job in gang?.jobs ?? [] {
            if let settings = job.rescale { value.overrides.append(ScalingOverride(pages:[job.front.number]+[job.back?.number].compactMap { $0 },gangID:job.id,settings:settings)) }
        }
        scaling = value; rescaleJobs = nil
        if var jobs = gang {
            for i in jobs.jobs.indices { jobs.jobs[i].rescale = nil }
            gang = jobs
        }
    }
    public var hasInvalidScaling: Bool {
        if let scaling { return (scaling.enabled && !scaling.defaults.isValid) || scaling.overrides.contains { $0.settings?.isValid == false } }
        return (rescaleJobs ?? []).contains { !$0.settings.isValid } || gang?.jobs.contains { $0.rescale?.isValid == false } == true
    }
    public var hasRescaling: Bool { scaling.map { $0.enabled || $0.overrides.contains { $0.settings != nil } } ?? (!(rescaleJobs ?? []).isEmpty || gang?.jobs.contains { $0.rescale != nil } == true) }
    /// A temporary geometry input; source metadata in the saved project remains unchanged.
    public var rescaledPlanningInput: Project {
        var next = self
        func scaled(_ page: SourcePage,jobID:UUID? = nil,jobIndex:Int? = nil) -> SourcePage {
            guard let scale = rescale(for:page.number,jobID:jobID,jobIndex:jobIndex) else { return page }
            var p = page; p.trimSize = scale.settings.target
            p.availableBleed = (page.availableBleed ?? 0)*min(scale.factors.width,scale.factors.height)
            return p
        }
        var pageJobs: [Int] = []
        if binding == .stepAndRepeat {
            for (i,job) in repeatJobs.enumerated() { pageJobs += Array(repeating:i,count:job.back == nil ? 1 : 2) }
        }
        next.pages = binding == .gang ? pages : pages.enumerated().map { index,page in scaled(page,jobIndex:pageJobs.indices.contains(index) ? pageJobs[index] : nil) }
        // Scaling one job must not change automatic simplex/duplex pairing.
        if binding == .stepAndRepeat,next.stepAndRepeat.pageLayout?.mode == .automatic {
            next.stepAndRepeat.pageLayout?.mode = resolvedPageLayout
        }
        if hasRescaling { next.settings.generatedBleed.enabled = true; next.settings.generatedBleed.method = .automatic }
        if var gang = next.gang {
            for i in gang.jobs.indices where rescale(for:gang.jobs[i].front.number,jobID:gang.jobs[i].id) != nil {
                let id = gang.jobs[i].id
                gang.jobs[i].front = scaled(gang.jobs[i].front,jobID:id); gang.jobs[i].back = gang.jobs[i].back.map { scaled($0,jobID:id) }
                gang.jobs[i].rescale = nil; gang.jobs[i].generatedBleed.enabled = true; gang.jobs[i].generatedBleed.method = .automatic
            }
            next.gang = gang
        }
        next.rescaleJobs = nil
        next.scaling = nil
        return next
    }
}
