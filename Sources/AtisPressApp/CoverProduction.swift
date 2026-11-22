import ImpositionCore

extension Workspace {
    var canShowCoverTab: Bool {
        (source?.pages.count ?? 0) >= 2 || project.coverPreparation != nil
    }

    private var coverAuxiliary: Set<Int> {
        Set((project.book?.auxiliaryPages ?? []) + (project.book?.coverPDFPages ?? []))
    }

    var coverSourcePages: [SourcePage] {
        let pages = project.binding == .gang
            ? (project.gang?.jobs ?? []).flatMap { [$0.front] + ($0.back.map { [$0] } ?? []) }
            : project.pages
        let auxiliary = coverAuxiliary
        return pages.filter { !auxiliary.contains($0.number) && project.artworkPageNumber($0.number) != nil }
    }

    var coverSelectablePages: [SourcePage] {
        project.pageItems?.filter { $0.sourcePage != nil }.map(\.planningPage) ?? source?.pages.map(\.sourcePage) ?? []
    }

    private var coverFaces: (front: SourcePage?, back: SourcePage?) {
        let pages: [SourcePage]
        switch coverPreparation.source {
        case .none: return (nil,nil)
        case .firstAndLast: pages = coverSourcePages
        case .coverFile:
            pages = coverSourcePages.count == 2 ? coverSourcePages : []
        case .separatePDF:
            let linked = project.book?.coverPDFPages ?? []
            pages = linked.compactMap { id in coverSelectablePages.first { $0.number == id } }
            if pages.count == 1 { return (coverSourcePages.first,coverSourcePages.first) }
        case .selectedPages:
            let candidates = coverSelectablePages
            func resolve(_ id: Int?,fallback: SourcePage?) -> SourcePage? {
                guard let id else { return fallback }
                return candidates.first { $0.number == id }
            }
            return (resolve(coverPreparation.front,fallback:coverSourcePages.first),
                    resolve(coverPreparation.back,fallback:coverSourcePages.last))
        }
        return (pages.first,pages.last)
    }

    var coverPlanningInput: (project: Project, pages: [SourcePage], prepared: SourcePage?) {
        guard let source else { return (project,[],nil) }
        guard coverPreparation.source != nil else { return (project,source.pages.map(\.sourcePage),nil) }
        func artwork(_ page: SourcePage) -> SourcePage? {
            guard let number = project.artworkPageNumber(page.number) else { return nil }
            var result = page
            result.number = number
            return result
        }
        var input = project
        var settings = coverPreparation
        let (front,back) = coverFaces
        let prepared: SourcePage? = if settings.source == .separatePDF, let linked = project.book?.coverPDFPages,
            linked.count == 1, let page = coverSelectablePages.first(where: { $0.number == linked[0] }) {
            artwork(page)
        } else { nil }
        let pages: [SourcePage]
        if let front, let back, front.number != back.number || prepared != nil,
           let frontArtwork = artwork(front), let backArtwork = artwork(back) {
            pages = [frontArtwork,backArtwork]
        } else {
            pages = []
        }
        settings.front = pages.first?.number
        settings.back = pages.last?.number
        settings.crop = nil
        settings.bleed = nil
        input.coverPreparation = settings
        if let team = project.team {
            input.stepAndRepeat.quantity = team.quantity
            input.stepAndRepeat.waste = team.waste
        } else if project.isBooklet || project.isLeafBinding {
            input.stepAndRepeat.quantity = project.costing?.copies
        }
        return (input,pages,prepared)
    }

    var coverInteriorProject: Project {
        var interior = project
        let (front,back) = coverFaces
        let removed = coverAuxiliary.union([front?.number,back?.number].compactMap { $0 })
        let excluded = coverPreparation.source == .separatePDF ? coverAuxiliary : removed
        interior.pages.removeAll { excluded.contains($0.number) }
        interior.gang?.jobs.removeAll { excluded.contains($0.front.number) && ($0.back.map { excluded.contains($0.number) } ?? true) }
        if var jobs = interior.gang?.jobs {
            for i in jobs.indices {
                if excluded.contains(jobs[i].front.number), let back = jobs[i].back {
                    jobs[i].front = back
                    jobs[i].back = nil
                } else if let back = jobs[i].back, excluded.contains(back.number) {
                    jobs[i].back = nil
                }
            }
            interior.gang?.jobs = jobs
        }
        if let jobs = interior.gang?.jobs {
            let ids = Set(jobs.map(\.id))
            interior.gang?.blocks.removeAll { !ids.contains($0.jobID) }
            if let layouts = interior.team?.manualLayouts {
                interior.team?.manualLayouts = layouts.map { $0.filter { ids.contains($0.jobID) } }.filter { !$0.isEmpty }
            }
        }
        interior.coverMode = .included
        if project.binding == .saddleStitch, var book = project.book, book.creepEnabled {
            book.coverSourceID = nil
            book.coverPDFPages = []
            book.auxiliaryPages = []
            book.separateSaddleCover = false
            book.selection = CoverSelection()
            interior.book = book
        } else {
            interior.book = nil
        }
        return interior
    }

    func activateCoverSource(_ source: CoverPreparationSettings.Source,spineWidth: Double? = nil) {
        var cover = coverPreparation
        if cover.source == nil && project.coverPreparation == nil {
            cover.spineWidth = self.spineWidth
            if let content = project.book?.spineContent {
                cover.color = content.color
                cover.colorMode = content.extendEdges || content.mode != .color ? .automatic : .manual
                cover.foldMarks = content.foldMarks
                cover.spineText = content.mode == .text ? content.blocks : nil
            }
        }
        cover.source = source
        if let spineWidth { cover.spineWidth = spineWidth }
        coverPreparation = cover
        coverPreviewOutput = .spread
    }
}

extension ImpositionPlan {
    mutating func appendCover(_ cover: ImpositionPlan) {
        let sheetOffset = sheets.count
        let diagnosticOffset = diagnosticSheets.count
        func shifted(_ issue: ValidationIssue,by offset: (Int) -> Int) -> ValidationIssue {
            func move(_ slot: SlotReference) -> SlotReference {
                var result = slot
                result.sheet += offset(slot.sheet)
                return result
            }
            var issue = issue
            issue.slot = issue.slot.map(move)
            issue.affectedSlots = issue.affectedSlots.map(move)
            return issue
        }
        issues = issues.map { issue in
            shifted(issue) { $0 >= sheetOffset ? cover.sheets.count : 0 }
        }
        if !cover.sheets.isEmpty { generatedBleed = cover.generatedBleed }
        sheets += cover.sheets
        diagnosticSheets += cover.diagnosticSheets
        issues += cover.issues.map { issue in
            shifted(issue) { sheetOffset + ($0 >= cover.sheets.count ? diagnosticOffset : 0) }
        }
        refreshWarningSummary()
    }
}
