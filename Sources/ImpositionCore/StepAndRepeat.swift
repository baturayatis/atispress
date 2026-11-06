extension ImpositionPlanner {
    private struct RepeatGrid {
        var sheet: Size
        var origin: Point
        var item: Size
        var columns: Int
        var rows: Int
        var rotation: Int
        var spacing: Double
        var mirrorX: Bool
        var capacity: Int { columns * rows }
    }

    static func repeatPlan(_ project: Project) -> ImpositionPlan {
        var plan = ImpositionPlan(generatedBleed: project.settings.generatedBleed)
        func issue(_ code: ValidationIssue.Code, _ message: String) {
            plan.issues.append(ValidationIssue(.error,code,message))
        }
        let spec = project.sheet, settings = project.settings, options = project.stepAndRepeat
        let values = [spec.size.width,spec.size.height,spec.margins.left,spec.margins.right,
                      spec.margins.top,spec.margins.bottom,spec.gripperWidth,spec.gutter,
                      settings.bleed,settings.cropMarkLength,settings.cropMarkOffset,settings.safeAreaInset]
        guard settings.generatedBleed.isValid, !project.pages.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }),
              spec.size.width > 0, spec.size.height > 0,
              project.pages.allSatisfy({ $0.number > 0 && $0.trimSize.width.isFinite && $0.trimSize.height.isFinite &&
                  $0.trimSize.width > 0 && $0.trimSize.height > 0 &&
                  ($0.availableBleed == nil || ($0.availableBleed!.isFinite && $0.availableBleed! >= 0)) }),
              options.columns.map({ (1...200).contains($0) }) ?? true,
              options.rows.map({ (1...200).contains($0) }) ?? true,
              options.quantity.map({ (1...1_000_000_000).contains($0) }) ?? true else {
            issue(.invalidInput,"Ölçüler, ızgara (1–200) veya adet (1–1.000.000.000) geçersiz."); return plan
        }
        guard project.coverMode == .included else {
            issue(.unsupportedCover,"Düz işlerde kapak ayrımı desteklenmiyor."); return plan
        }
        let mirrorX = repeatMirrorsX(project)
        let override = mirrorX ? options.columns : options.rows
        if settings.turnMethod != .sheetwise && override.map({ $0 % 2 != 0 }) == true {
            issue(.invalidInput,"Aynı kalıp için \(mirrorX ? "sütun" : "satır") sayısı çift olmalıdır."); return plan
        }
        // Selection order determines consecutive pairs. An odd last page has an unprinted reverse;
        // it is never appended to the source list and never counted as padding.
        for index in stride(from: 0,to: project.pages.count,by: 2) {
            let front = project.pages[index]
            let back = index+1 < project.pages.count ? project.pages[index+1] : nil
            let job = index/2
            guard back == nil || back?.trimSize == front.trimSize else {
                issue(.mixedPageSizes,"İş \(job+1): ön ve arka sayfa boyutları aynı olmalıdır."); continue
            }
            guard settings.safeAreaInset*2 < min(front.trimSize.width,front.trimSize.height) else {
                issue(.invalidInput,"İş \(job+1): güvenli alan payı ürün boyutunu aşıyor."); continue
            }
            guard let grid = repeatGrid(project,trim: front.trimSize) else {
                issue(.exceedsSheet,"İş \(job+1): ürün veya seçilen ızgara baskı tabakasına sığmıyor."); continue
            }
            guard grid.capacity <= 20_000 else {
                issue(.invalidInput,"İş \(job+1): tek tabakada en fazla 20.000 ürün destekleniyor."); continue
            }
            var frontSlots: [Slot] = [], backSlots: [Slot] = []
            for row in 0..<grid.rows {
                for column in 0..<grid.columns {
                    let position = GridPosition(column: column,row: row)
                    let inverse = backPosition(position,columns: grid.columns,rows: grid.rows,mirrorX: grid.mirrorX)
                    let reverseHalf = settings.turnMethod != .sheetwise &&
                        (grid.mirrorX ? column >= grid.columns/2 : row >= grid.rows/2)
                    let page = reverseHalf ? back?.number : front.number
                    let reversePage = reverseHalf ? front.number : back?.number
                    let rotation = reverseHalf ? reverseRotation(grid.rotation,mirrorX: grid.mirrorX) : grid.rotation
                    func origin(_ p: GridPosition) -> Point {
                        Point(grid.origin.x+Double(p.column)*(grid.item.width+grid.spacing),
                              grid.origin.y+Double(p.row)*(grid.item.height+grid.spacing))
                    }
                    let copy = row*grid.columns+column
                    frontSlots.append(Slot(sourcePageNumber: page,origin: origin(position),size: grid.item,
                        rotation: rotation,signature: job,gridPosition: position,copyIndex: copy))
                    backSlots.append(Slot(sourcePageNumber: reversePage,origin: origin(inverse),size: grid.item,
                        rotation: reverseRotation(rotation,mirrorX: grid.mirrorX),signature: job,gridPosition: inverse,copyIndex: copy))
                }
            }
            // The array stays in copy order. GridPosition expresses each face's row/column order.
            let frontSide = repeatSide(frontSlots,grid: grid,spec: spec,settings: settings)
            let backSide = repeatSide(backSlots,grid: grid,spec: spec,settings: settings)
            if settings.generatedBleed.enabled {
                for slot in frontSide.slots+backSide.slots {
                    if let clip = slot.artworkClip,
                       clip.origin.x < -0.000001 || clip.origin.y < -0.000001 ||
                       clip.origin.x+clip.size.width > grid.sheet.width+0.000001 ||
                       clip.origin.y+clip.size.height > grid.sheet.height+0.000001 {
                        issue(.exceedsSheet,"Blok dışındaki taşma payı tabaka kenarına sığmıyor.")
                    }
                }
            }
            let quantity = options.quantity
            let repeats = quantity.map { $0/grid.capacity + ($0%grid.capacity == 0 ? 0 : 1) } ?? 1
            let sheetIndex = plan.sheets.count
            plan.sheets.append(Sheet(size: grid.sheet,front: frontSide,back: backSide,repeatCount: repeats,
                repeatLayout: RepeatLayout(jobIndex: job,frontPageNumber: front.number,backPageNumber: back?.number,
                    columns: grid.columns,rows: grid.rows,requestedQuantity: quantity)))
            let missing = Set([front,back].compactMap { $0 }.filter { ($0.availableBleed ?? -1) < settings.bleed }.map(\.number))
            if settings.bleed > 0 {
                for (kind,side) in [(SideKind.front,frontSide),(.back,backSide)] {
                    for (slotIndex,slot) in side.slots.enumerated() {
                        if let number = slot.sourcePageNumber, missing.contains(number) {
                            plan.issues.append(ValidationIssue(.warning,.missingBleed,
                                "İş \(job+1), sayfa \(number): taşma payı eksik veya bilinmiyor.",
                                slot: SlotReference(sheet: sheetIndex,side: kind,slot: slotIndex)))
                        }
                    }
                }
            }
            if settings.generatedBleed.enabled && spec.gutter > 0 && spec.gutter < 2*settings.bleed {
                plan.issues.append(ValidationIssue(.warning,.insufficientGutter,
                    "İş \(job+1): ara boşluk iki taşma payından küçük; kesim ayrımını kontrol edin."))
            }
            if spec.gutter == 0 && settings.bleed > 0 && grid.capacity > 1 {
                plan.issues.append(ValidationIssue(.warning,.sharedCutBleed,
                    "İş \(job+1): ortak kesimde iç taşmalar kesim sınırında kırpılır; komşu tasarımları kontrol edin."))
            }
        }
        return plan
    }

    /// Both faces use an origin viewed from their own side of the sheet.
    /// Reflection maps positions, never glyphs; type must remain readable after printing.
    private static func repeatMirrorsX(_ project: Project) -> Bool {
        let sideGripper = project.sheet.gripperEdge == .left || project.sheet.gripperEdge == .right
        return sideGripper == (project.settings.turnMethod == .workAndTumble)
    }
    private static func backPosition(_ p: GridPosition, columns: Int, rows: Int, mirrorX: Bool) -> GridPosition {
        mirrorX ? GridPosition(column: columns-1-p.column,row: p.row) : GridPosition(column: p.column,row: rows-1-p.row)
    }
    private static func reverseRotation(_ rotation: Int, mirrorX: Bool) -> Int {
        ((mirrorX ? 360 : 180)-rotation)%360
    }
    private static func repeatGrid(_ project: Project, trim: Size) -> RepeatGrid? {
        let spec = project.sheet, settings = project.settings, options = project.stepAndRepeat
        let mirrorX = repeatMirrorsX(project)
        let portrait = Size(min(spec.size.width,spec.size.height),max(spec.size.width,spec.size.height))
        let landscape = Size(portrait.height,portrait.width)
        let sheets = spec.orientation == .portrait ? [portrait] : spec.orientation == .landscape ? [landscape] : [portrait,landscape]
        let reserve = max(settings.bleed,settings.cropMarkLength > 0 ? settings.cropMarkOffset+settings.cropMarkLength : 0)
        // Zero gutter is an explicit shared-trim-cut mode. Otherwise bleed boxes do not overlap.
        let spacing = spec.gutter == 0 ? 0 : 2*settings.bleed+spec.gutter
        var best: RepeatGrid?
        for sheet in sheets {
            var m = spec.margins
            switch spec.gripperEdge {
            case .left: m.left += spec.gripperWidth
            case .right: m.right += spec.gripperWidth
            case .top: m.top += spec.gripperWidth
            case .bottom: m.bottom += spec.gripperWidth
            }
            // Reserve the opposite lay/gripper too, so both passes fit at the same coordinates.
            if !mirrorX { m.bottom = max(m.bottom,m.top); m.top = m.bottom }
            else { m.left = max(m.left,m.right); m.right = m.left }
            let width = sheet.width-m.left-m.right-2*reserve
            let height = sheet.height-m.top-m.bottom-2*reserve
            for rotation in (options.allowRotation ? [0,90] : [0]) {
                let item = rotation == 0 ? trim : Size(trim.height,trim.width)
                guard width >= item.width, height >= item.height else { continue }
                let fitColumns = ((width+spacing)/(item.width+spacing)).rounded(.down)
                let fitRows = ((height+spacing)/(item.height+spacing)).rounded(.down)
                guard fitColumns.isFinite,fitRows.isFinite else { continue }
                // Bound conversion; oversized automatic layouts report a validation error above.
                var columns = options.columns ?? Int(min(fitColumns,20_001))
                var rows = options.rows ?? Int(min(fitRows,20_001))
                if settings.turnMethod != .sheetwise && mirrorX && options.columns == nil { columns -= columns%2 }
                if settings.turnMethod != .sheetwise && !mirrorX && options.rows == nil { rows -= rows%2 }
                guard columns > 0,rows > 0,Double(columns) <= fitColumns,Double(rows) <= fitRows else { continue }
                let usedWidth = Double(columns)*item.width+Double(columns-1)*spacing
                let usedHeight = Double(rows)*item.height+Double(rows-1)*spacing
                let origin = !mirrorX ?
                    Point(m.left+reserve,(sheet.height-usedHeight)/2) : Point((sheet.width-usedWidth)/2,m.bottom+reserve)
                let candidate = RepeatGrid(sheet: sheet,origin: origin,item: item,columns: columns,rows: rows,rotation: rotation,spacing: spacing,mirrorX: mirrorX)
                if best == nil || candidate.capacity > best!.capacity ||
                    (candidate.capacity == best!.capacity && candidate.rotation < best!.rotation) { best = candidate }
            }
        }
        return best
    }

    private static func repeatSide(_ slots: [Slot], grid: RepeatGrid, spec: SheetSpec, settings: ImpositionSettings) -> Side {
        var slots = slots
        var lines = pressGuides(spec,grid.sheet)
        if settings.turnMethod == .workAndTumble {
            lines += lines.filter { $0.kind == .gripper }.map { mark in
                func flip(_ p: Point) -> Point {
                    grid.mirrorX ? Point(grid.sheet.width-p.x,p.y) : Point(p.x,grid.sheet.height-p.y)
                }
                return Mark(kind: .gripper,start: flip(mark.start),end: flip(mark.end),label: mark.label)
            }
        }
        let x0 = grid.origin.x, y0 = grid.origin.y
        let x1 = x0+Double(grid.columns)*grid.item.width+Double(grid.columns-1)*grid.spacing
        let y1 = y0+Double(grid.rows)*grid.item.height+Double(grid.rows-1)*grid.spacing
        for index in slots.indices {
            let slot = slots[index]
            lines += marks(slot,settings).filter { $0.kind != .crop && $0.kind != .bleed }
            // Bleed guides stop at shared cuts; they never imply overlapping neighboring artwork.
            let p = slot.gridPosition!
            let l = spec.gutter == 0 && p.column > 0 ? slot.x : slot.x-settings.bleed
            let r = spec.gutter == 0 && p.column < grid.columns-1 ? slot.x+slot.size.width : slot.x+slot.size.width+settings.bleed
            let b = spec.gutter == 0 && p.row > 0 ? slot.y : slot.y-settings.bleed
            let t = spec.gutter == 0 && p.row < grid.rows-1 ? slot.y+slot.size.height : slot.y+slot.size.height+settings.bleed
            slots[index].artworkClip = Rect(x: l,y: b,width: r-l,height: t-b)
            if spec.gutter != 0 || !settings.generatedBleed.enabled { lines += rectangleLines(l,b,r,t,kind: .bleed) }
        }
        if spec.gutter == 0 && settings.generatedBleed.enabled {
            lines += rectangleLines(x0-settings.bleed,y0-settings.bleed,x1+settings.bleed,y1+settings.bleed,kind: .bleed)
            for column in 1..<grid.columns {
                let x = x0+Double(column)*grid.item.width
                lines.append(Mark(kind: .sharedCut,start: Point(x,y0),end: Point(x,y1)))
            }
            for row in 1..<grid.rows {
                let y = y0+Double(row)*grid.item.height
                lines.append(Mark(kind: .sharedCut,start: Point(x0,y),end: Point(x1,y)))
            }
        }
        if settings.cropMarkLength > 0 {
            // External ticks describe every row/column trim. A common cut gets one pair of ticks,
            // instead of duplicate strokes or marks drawn through adjacent artwork.
            let xs = Set(slots.flatMap { [$0.x,$0.x+$0.size.width].map { ($0*1e7).rounded()/1e7 } }).sorted()
            let ys = Set(slots.flatMap { [$0.y,$0.y+$0.size.height].map { ($0*1e7).rounded()/1e7 } }).sorted()
            let offset = settings.cropMarkOffset, length = settings.cropMarkLength
            if grid.spacing > 0 {
                for slot in slots {
                    let position = slot.gridPosition!
                    for dx in [-1.0,1.0] {
                        for dy in [-1.0,1.0] {
                            let x = dx < 0 ? slot.x : slot.x+slot.size.width
                            let y = dy < 0 ? slot.y : slot.y+slot.size.height
                            let horizontalNeighbor = dx < 0 ? position.column > 0 : position.column < grid.columns-1
                            let verticalNeighbor = dy < 0 ? position.row > 0 : position.row < grid.rows-1
                            let end = min(offset+length,grid.spacing)
                            if end > offset && horizontalNeighbor {
                                lines.append(Mark(kind: .crop,start: Point(x+dx*offset,y),end: Point(x+dx*end,y)))
                            }
                            if end > offset && verticalNeighbor {
                                lines.append(Mark(kind: .crop,start: Point(x,y+dy*offset),end: Point(x,y+dy*end)))
                            }
                        }
                    }
                }
            }
            for x in xs {
                lines.append(Mark(kind: .crop,start: Point(x,y0-offset),end: Point(x,y0-offset-length)))
                lines.append(Mark(kind: .crop,start: Point(x,y1+offset),end: Point(x,y1+offset+length)))
            }
            for y in ys {
                lines.append(Mark(kind: .crop,start: Point(x0-offset,y),end: Point(x0-offset-length,y)))
                lines.append(Mark(kind: .crop,start: Point(x1+offset,y),end: Point(x1+offset+length,y)))
            }
        }
        var cropKeys = Set<CropKey>()
        lines = lines.filter { $0.kind != .crop || cropKeys.insert(CropKey($0)).inserted }
        return Side(slots: slots,marks: lines)
    }
    private struct CropKey: Hashable {
        var ax: Double, ay: Double, bx: Double, by: Double
        init(_ mark: Mark) {
            let forward = mark.start.x < mark.end.x || (mark.start.x == mark.end.x && mark.start.y < mark.end.y)
            let a = forward ? mark.start : mark.end, b = forward ? mark.end : mark.start
            ax = (a.x*1e7).rounded(); ay = (a.y*1e7).rounded()
            bx = (b.x*1e7).rounded(); by = (b.y*1e7).rounded()
        }
    }
    private static func rectangleLines(_ l: Double, _ b: Double, _ r: Double, _ t: Double, kind: MarkKind) -> [Mark] {
        let a = Point(l,b), c = Point(r,b), d = Point(r,t), e = Point(l,t)
        return [(a,c),(c,d),(d,e),(e,a)].map { Mark(kind: kind,start: $0.0,end: $0.1) }
    }
}
