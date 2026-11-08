import Foundation

extension ImpositionPlanner {
    /// Separate diagnostic geometry must never be accepted by the export path.
    static func addFitDiagnostics(_ project: Project,to plan: inout ImpositionPlan) {
        guard plan.issues.contains(where: { $0.code == .exceedsSheet }),!project.pages.isEmpty else { return }
        let spec = project.sheet, s = project.settings
        guard [spec.size.width,spec.size.height,s.bleed,s.cropMarkLength,s.cropMarkOffset].allSatisfy({ $0.isFinite && $0 >= 0 }),
              spec.size.width > 0,spec.size.height > 0 else { return }
        let stock = spec.orientation == .landscape ? Size(max(spec.size.width,spec.size.height),min(spec.size.width,spec.size.height)) :
            spec.orientation == .portrait ? Size(min(spec.size.width,spec.size.height),max(spec.size.width,spec.size.height)) : spec.size
        let reserve = project.layoutExteriorReserve
        var margins = spec.margins
        if project.binding == .stepAndRepeat { margins = repeatMargins(spec,mirrorX: repeatMirrorsX(project)) }
        else {
            switch spec.gripperEdge {
            case .left: margins.left += spec.gripperWidth
            case .right: margins.right += spec.gripperWidth
            case .top: margins.top += spec.gripperWidth
            case .bottom: margins.bottom += spec.gripperWidth
            }
            if s.turnMethod == .workAndTurn { margins.left = max(margins.left,margins.right); margins.right = margins.left }
            if s.turnMethod == .workAndTumble { margins.top = max(margins.top,margins.bottom); margins.bottom = margins.top }
        }
        let jobs = project.repeatJobs
        let count = project.binding == .stepAndRepeat ? jobs.count : 1
        for job in 0..<count {
            let page = project.binding == .stepAndRepeat ? jobs[job].front : project.pages[0]
            guard page.trimSize.width.isFinite,page.trimSize.height.isFinite,page.trimSize.width > 0,page.trimSize.height > 0 else { continue }
            if project.binding == .stepAndRepeat,plan.sheets.contains(where: { $0.repeatLayout?.jobIndex == job }) { continue }
            let columns: Int, rows: Int
            if project.binding == .stepAndRepeat { columns = max(1,project.stepAndRepeat.columns ?? (s.turnMethod != .sheetwise && repeatMirrorsX(project) ? 2 : 1))
                rows = max(1,project.stepAndRepeat.rows ?? (s.turnMethod != .sheetwise && !repeatMirrorsX(project) ? 2 : 1)) }
            else if project.binding == .saddleStitch { columns = 2; rows = 1 }
            else { let n = project.settings.signatureSize.pageCount ?? 4; (columns,rows) = signatureGrid(n) }
            let spacing = project.binding == .stepAndRepeat && spec.gutter > 0 ? 2*s.bleed+spec.gutter : spec.gutter
            var grid = Size(Double(columns)*page.trimSize.width+Double(columns-1)*spacing,
                            Double(rows)*page.trimSize.height+Double(rows-1)*spacing)
            if project.binding != .stepAndRepeat {
                if s.turnMethod == .workAndTurn { grid.width = 2*(grid.width+2*reserve)+spec.gutter-2*reserve }
                if s.turnMethod == .workAndTumble { grid.height = 2*(grid.height+2*reserve)+spec.gutter-2*reserve }
            }
            let origin = Point(max(0,margins.left+reserve),max(0,margins.bottom+reserve))
            let needed = Size(grid.width+margins.left+margins.right+2*reserve,grid.height+margins.top+margins.bottom+2*reserve)
            let slot = Slot(sourcePageNumber: page.number,origin: origin,size: page.trimSize,
                            artworkClip: Rect(x: origin.x,y: origin.y,width: page.trimSize.width,height: page.trimSize.height))
            var sheet = Sheet(size: stock,front: Side(slots: [slot]),back: Side(slots: [slot]))
            sheet.diagnosticBounds = Rect(x: origin.x,y: origin.y,width: grid.width,height: grid.height)
            let index = plan.diagnosticSheets.count
            plan.diagnosticSheets.append(sheet)
            let text = String(format: "İş %d: ürün %.2f×%.2f mm; ızgara %d×%d (0°), gereken %.2f×%.2f mm; tabaka %.2f×%.2f mm; kullanılabilir %.2f×%.2f mm.",
                job+1,page.trimSize.width,page.trimSize.height,columns,rows,needed.width,needed.height,stock.width,stock.height,
                max(0,stock.width-margins.left-margins.right),max(0,stock.height-margins.top-margins.bottom))
            plan.issues.append(ValidationIssue(.error,.exceedsSheet,text,
                slot: SlotReference(sheet: plan.sheets.isEmpty ? index : plan.sheets.count+index,side: .front,slot: 0)))
        }
    }
}
