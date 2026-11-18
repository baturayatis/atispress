/// Adjustments are applied to image samples in their existing component space.
public struct ImageColorAdjustment: Equatable, Hashable, Codable, Sendable {
    public var brightness: Double = 0
    public var contrast: Double = 1
    public var saturation: Double = 1
    public var cmykProfileID: String?
    public init() {}

    public var hasSampleAdjustments: Bool { brightness != 0 || contrast != 1 || saturation != 1 }
    public var isNeutral: Bool { !hasSampleAdjustments && cmykProfileID == nil }
    public var isValid: Bool {
        (-0.5...0.5).contains(brightness) && (0...2).contains(contrast) && (0...2).contains(saturation)
    }
}

extension ImpositionPlanner {
    static func applyImageColor(_ project: Project, to plan: inout ImpositionPlan) {
        let jobs = Dictionary((project.gang?.jobs ?? []).compactMap { job in
            job.imageColor.map { (job.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        guard !jobs.isEmpty || !(project.imageColorJobs?.isEmpty ?? true) else { return }
        func apply(_ side: inout Side, job: Int) {
            for i in side.slots.indices where side.slots[i].sourcePageNumber != nil {
                let adjustment = side.slots[i].gangJobID.map { jobs[$0] } ?? project.imageColorJobs?[job]
                if let adjustment, !adjustment.isNeutral { side.slots[i].imageColor = adjustment }
            }
        }
        for i in plan.sheets.indices {
            let job = project.binding == .stepAndRepeat ? plan.sheets[i].repeatLayout?.frontPageNumber ?? 0 : 0
            apply(&plan.sheets[i].front, job: job)
            apply(&plan.sheets[i].back, job: job)
        }
    }
}
