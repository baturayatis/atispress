import Foundation

public struct TeamSettings: Equatable, Codable, Sendable {
    public var allowRotation = true
    public var duplex = false
    public var quantity = 1000
    /// Fire is calculated in physical sheets, separately for each layout.
    public var waste = WasteSettings()
    public var manualLayouts: [[GangBlock]]?
    public init() {}
}

public struct TeamSummary: Equatable, Sendable {
    public var pageCount: Int
    public var teamsPerLayout: [Int]
    public var occupancy: Double
    public var plateCount: Int
    public var fastSolution: Bool
}

public enum TeamPlanner {
    private struct Layout {
        var jobs: [GangJob]
        var blocks: [GangBlock]
    }

    public static func plan(_ project: Project) -> ImpositionPlan {
        var result = ImpositionPlan(generatedBleed: project.settings.generatedBleed)
        guard let team = project.team, var gang = project.gang, !gang.jobs.isEmpty else { return result }
        func fail(_ message: String) -> ImpositionPlan {
            result.issues.append(ValidationIssue(.error, .gangLayout, message))
            return result
        }
        let pageNumbers = gang.jobs.flatMap { [$0.front.number, $0.back?.number].compactMap { $0 } }
        guard Set(gang.jobs.map(\.id)).count == gang.jobs.count,
              pageNumbers.count == project.pages.count, pageNumbers.sorted() == project.pages.map(\.number).sorted(),
              team.duplex || gang.jobs.allSatisfy({ $0.back == nil }) else {
            return fail("Takımda eksik, yinelenen veya yanlış yüze atanmış sayfa var.")
        }
        guard team.quantity > 0 else { return fail("Takım adedi en az 1 olmalı.") }

        var base = project
        base.team = nil
        if !team.duplex { base.settings.turnMethod = .sheetwise }
        let factor = base.settings.turnMethod == .sheetwise ? 1 : 2
        gang.mode = .manual
        gang.blocks = []
        for index in gang.jobs.indices {
            gang.jobs[index].quantity = team.quantity
            gang.jobs[index].waste = WasteSettings()
            gang.jobs[index].allowRotation = team.allowRotation
        }
        let jobs = gang.jobs
        base.gang = gang
        if let invalid = jobs.first(where: { job in
            [job.front, job.back].compactMap { $0 }.contains { page in
                let size = page.trimSize
                return !(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0)
            }
        }) { return fail("\(invalid.name): kesim ölçüsü geçersiz.") }
        if let mismatch = jobs.first(where: { job in
            guard let back = job.back else { return false }
            return abs(back.trimSize.width - job.front.trimSize.width) > 0.0001 ||
                   abs(back.trimSize.height - job.front.trimSize.height) > 0.0001
        }) { return fail("\(mismatch.name): ön ve arka kesim ölçüleri eşleşmiyor. Eşlemeyi değiştirin.") }
        // Keep the largest bleed reserve across all layouts, including the probe.
        guard let reference = jobs.max(by: { $0.bleed < $1.bleed }) else { return result }
        let orientations: [Orientation] = base.sheet.orientation == .auto ? [.portrait, .landscape] : [base.sheet.orientation]
        var candidate: (orientation: Orientation, layouts: [Layout], sets: Int)?
        var firstUnplaced: GangJob?
        for orientation in orientations {
            if Task.isCancelled { return result }
            var probe = base
            probe.sheet.orientation = orientation
            probe.gang?.jobs = [reference]
            guard let area = GangPlanner.plan(probe).sheets.first?.gangLayout?.printable,
                  area.size.width > 0, area.size.height > 0 else { continue }
            func pack(_ group: [GangJob], sets: Int = 1) -> [GangBlock]? {
                GangPlanner.shelfBlocks(jobs: Array(repeating: group, count: sets).flatMap { $0 },
                                        area: area, gutter: base.sheet.gutter)
            }

            if let manual = team.manualLayouts {
                let byID = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($0.element.id, $0.offset) })
                var assigned = Set<UUID>()
                var layouts: [Layout] = []
                for blocks in manual {
                    let ids = Set(blocks.map(\.jobID))
                    guard !ids.isEmpty, ids.isDisjoint(with: assigned),
                          ids.allSatisfy({ byID[$0] != nil }),
                          Set(blocks.map(\.id)).count == blocks.count else {
                        return fail("Elle düzende her sayfa veya çift tek bir düzene atanmalı.")
                    }
                    let group = ids.compactMap { byID[$0] }.sorted().map { jobs[$0] }
                    layouts.append(Layout(jobs: group, blocks: blocks))
                    assigned.formUnion(ids)
                }
                guard assigned.count == jobs.count else {
                    return fail("Elle düzende bir veya daha fazla sayfa eksik.")
                }
                candidate = (orientation, layouts, 0)
                break
            }

            // Binary searches cap the work even when a PDF has hundreds of pages.
            var layouts: [Layout] = []
            var start = 0
            while start < jobs.count {
                if Task.isCancelled { return result }
                let first = [jobs[start]]
                guard var blocks = pack(first) else {
                    firstUnplaced = jobs[start]
                    break
                }
                var low = 1
                var high = min(GangPlanner.maximumJobs, jobs.count - start)
                while low < high {
                    let mid = low + (high - low + 1) / 2
                    if let packed = pack(Array(jobs[start..<(start + mid)])) {
                        low = mid
                        blocks = packed
                    } else { high = mid - 1 }
                }
                layouts.append(Layout(jobs: Array(jobs[start..<(start + low)]), blocks: blocks))
                start += low
            }
            guard start == jobs.count else { continue }
            var low = 1
            var high = min(1000 / (layouts.map { $0.jobs.count }.max() ?? 1), 1 + (team.quantity - 1) / factor)
            while low < high {
                let mid = low + (high - low + 1) / 2
                let packed = layouts.map { pack($0.jobs, sets: mid) }
                if packed.allSatisfy({ $0 != nil }) {
                    low = mid
                    for index in layouts.indices { layouts[index].blocks = packed[index]! }
                } else { high = mid - 1 }
            }
            if candidate == nil || layouts.count < candidate!.layouts.count ||
                (layouts.count == candidate!.layouts.count && low > candidate!.sets) {
                candidate = (orientation, layouts, low)
            }
        }
        guard let candidate else {
            if let job = firstUnplaced {
                return fail("\(job.name) tabakaya sığmıyor. Tabaka ebadını, kenarları ve maşa payını kontrol edin.")
            }
            return fail("Takım tabakaya sığmıyor. Sayfa kesim ölçülerini, tabaka yönünü, kenar ve maşa paylarını kontrol edin.")
        }
        base.sheet.orientation = candidate.orientation
        var capacities: [Int] = []
        var ink = 0.0
        var stock = 0.0
        var plates = 0
        var totalSheets = 0
        for (index, layout) in candidate.layouts.enumerated() {
            if Task.isCancelled { return ImpositionPlan() }
            base.gang?.jobs = layout.jobs
            base.gang?.blocks = layout.blocks
            let imposed = GangPlanner.plan(base, teamLayout: true)
            guard var sheet = imposed.sheets.first, var details = sheet.gangLayout else {
                result.issues += imposed.issues
                return fail("Düzen \(index + 1) oluşturulamadı.")
            }
            result.issues += imposed.issues
            let capacity = details.jobs.first?.copiesPerSheet ?? 0
            guard capacity > 0, details.jobs.allSatisfy({ $0.copiesPerSheet == capacity }),
                  capacities.first.map({ $0 == capacity }) ?? true else {
                return fail("Düzen \(index + 1): her sayfa aynı sayıda yerleştirilmeli. Yalnız tam takımlar basılabilir.")
            }
            guard let production = team.waste.quantities(for: sheet.repeatCount) else {
                return fail("Düzen \(index + 1): tabaka veya fire adedi geçersiz.")
            }
            let sum = totalSheets.addingReportingOverflow(production.total)
            guard !sum.overflow else { return fail("Toplam tabaka adedi sayı sınırını aşıyor.") }
            totalSheets = sum.partialValue
            sheet.repeatCount = production.total
            for i in details.jobs.indices {
                details.jobs[i].serialPlan.sheetCount = sheet.repeatCount
                let made = UInt64(sheet.repeatCount).multipliedReportingOverflow(by: UInt64(capacity))
                details.jobs[i].surplus = (made.overflow ? UInt64.max : made.partialValue) - UInt64(team.quantity)
            }
            let occupied = sheet.front.slots.reduce(0.0) { $0 + $1.size.width * $1.size.height }
            let available = details.printable.size.width * details.printable.size.height * Double(factor)
            let utilization = available > 0 ? min(1, occupied / available) : 0
            details.isTeam = true
            details.summary = "Düzen \(index + 1) · \(capacity) takım payı/tabaka · \(sheet.repeatCount) tabaka · %\(Int((100 * utilization).rounded())) doluluk"
            sheet.gangLayout = details
            capacities.append(capacity)
            ink += occupied
            stock += available
            plates += 1 + (factor == 1 && sheet.hasContent(on: .back) ? 1 : 0)
            result.sheets.append(sheet)
        }
        if team.manualLayouts == nil {
            result.issues.append(ValidationIssue(.warning, .gangLayout, "Hızlı çözüm: arama sınırlıdır. En az tabaka veya kalıp sayısı kanıtlanmadı."))
        }
        result.teamSummary = TeamSummary(pageCount: pageNumbers.count, teamsPerLayout: capacities,
                                         occupancy: stock > 0 ? min(1, ink / stock) : 0,
                                         plateCount: plates, fastSolution: team.manualLayouts == nil)
        return result
    }
}
