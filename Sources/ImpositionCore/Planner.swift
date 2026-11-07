public enum ImpositionPlanner {
    private struct Unit {
        var columns: Int
        var rows: Int
        var front: [Slot]
        var back: [Slot]
    }
    private struct Layout {
        var size: Size
        var origin: Point
        var columns: Int
        var rows: Int
        var rotated: Bool
        var unitSize: Size
        var capacity: Int { columns * rows }
    }
    /// Produces the sole geometry source for both preview and future PDF export.
    public static func plan(_ project: Project) -> ImpositionPlan {
        if let auto = project.autoLayout, !auto.trimTolerance.isFinite || !(0...1).contains(auto.trimTolerance) {
            return ImpositionPlan(issues: [ValidationIssue(.error,.invalidInput,"Tam sayfa toleransı 0–1 mm aralığında olmalıdır.")])
        }
        var result = layoutPlan(project)
        addFitDiagnostics(project,to: &result)
        for index in result.sheets.indices {
            result.sheets[index].gripperEdge = project.sheet.gripperEdge
            result.sheets[index].backFlipsX = project.binding == .stepAndRepeat ? repeatMirrorsX(project) : project.settings.turnMethod != .workAndTumble
        }
        for index in result.diagnosticSheets.indices { result.diagnosticSheets[index].gripperEdge = project.sheet.gripperEdge }
        applySerials(project,to: &result)
        result.refreshWarningSummary(project: project)
        return result
    }
    private static func layoutPlan(_ project: Project) -> ImpositionPlan {
        if project.binding == .stepAndRepeat { return repeatPlan(project) }
        var result = ImpositionPlan(generatedBleed: project.settings.generatedBleed)
        func error(_ code: ValidationIssue.Code, _ message: String) {
            result.issues.append(ValidationIssue(.error, code, message))
        }
        guard project.binding == .saddleStitch || project.binding == .perfectBound else {
            error(.unsupportedBinding, "Bu ciltleme yöntemi henüz desteklenmiyor."); return result
        }
        guard project.coverMode == .included else {
            error(.unsupportedCover, "Ayrı veya hariç kapak henüz desteklenmiyor."); return result
        }
        let s = project.settings
        let spec = project.sheet
        let numbers = [spec.size.width, spec.size.height, spec.gutter, spec.gripperWidth,
                       spec.margins.left, spec.margins.right, spec.margins.top, spec.margins.bottom,
                       s.bleed, s.cropMarkLength, s.cropMarkOffset, s.safeAreaInset]
        guard s.generatedBleed.isValid, !project.pages.isEmpty, numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
              spec.size.width > 0, spec.size.height > 0,
              project.pages.allSatisfy({ $0.number > 0 && $0.trimSize.width.isFinite && $0.trimSize.height.isFinite &&
                  $0.trimSize.width > 0 && $0.trimSize.height > 0 &&
                  ($0.availableBleed == nil || ($0.availableBleed!.isFinite && $0.availableBleed! >= 0)) }) else {
            error(.invalidInput, "Sayfa, ölçü veya ayarlar geçersiz."); return result
        }
        let trim = project.pages[0].trimSize
        guard project.pages.allSatisfy({ $0.trimSize == trim }) else {
            error(.mixedPageSizes, "Karışık sayfa boyutları desteklenmiyor."); return result
        }
        guard s.safeAreaInset * 2 < min(trim.width, trim.height) else {
            error(.invalidInput, "Güvenli alan payı sayfa boyutunu aşıyor."); return result
        }
        if s.bleed > 0 && !s.generatedBleed.enabled && project.pages.contains(where: { ($0.availableBleed ?? -1) < s.bleed }) {
            result.issues.append(ValidationIssue(.warning, .missingBleed, "Bazı sayfalarda taşma payı eksik veya bilinmiyor."))
        }
        let signature: Int
        if project.binding == .saddleStitch { signature = ((project.pages.count + 3) / 4) * 4 }
        else if let fixed = s.signatureSize.pageCount { signature = fixed }
        else {
            // Minimize press sheets, then padding, then prefer the larger signature.
            let choices = [8, 16, 32].compactMap { count -> (Int, Int, Int)? in
                let grid = signatureGrid(count)
                guard let fit = bestLayout(spec, trim, grid.0, grid.1, s,clipBleed: project.autoLayout?.clipBleedToSheet == true) else { return nil }
                let units = (project.pages.count + count - 1) / count
                return ((units + fit.capacity - 1) / fit.capacity, units * count - project.pages.count, count)
            }.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : (a.1 != b.1 ? a.1 < b.1 : a.2 > b.2) }
            guard let best = choices.first else {
                error(.exceedsSheet, "En küçük forma bile baskı tabakasına sığmıyor."); return result
            }
            signature = best.2
        }
        result.signaturePageCount = signature
        let total = ((project.pages.count + signature - 1) / signature) * signature
        result.addedBlankPages = total - project.pages.count
        if result.addedBlankPages > 0 {
            result.issues.append(ValidationIssue(project.blankPagePolicy == .append ? .warning : .error,
                .pageCountPadding, "\(result.addedBlankPages) boş sayfa eklenmesi gerekiyor."))
        }
        let pages: [Int?] = project.pages.map { Optional($0.number) } + Array(repeating: nil, count: result.addedBlankPages)
        let units: [Unit]
        if project.binding == .saddleStitch {
            units = (0..<(total / 4)).map { i in
                Unit(columns: 2, rows: 1,
                     front: [makeSlot(pages[total - 1 - 2*i], 0, 0, trim, spec.gutter, 0),
                             makeSlot(pages[2*i], 1, 0, trim, spec.gutter, 0)],
                     back: [makeSlot(pages[2*i + 1], 0, 0, trim, spec.gutter, 0),
                            makeSlot(pages[total - 2 - 2*i], 1, 0, trim, spec.gutter, 0)])
            }
        } else {
            units = stride(from: 0, to: total, by: signature).map {
                foldedUnit(Array(pages[$0..<($0 + signature)]), trim, spec.gutter, $0 / signature)
            }
        }
        guard let first = units.first,
              let layout = bestLayout(spec, trim, first.columns, first.rows, s,clipBleed: project.autoLayout?.clipBleedToSheet == true) else {
            error(.exceedsSheet, "Forma ve baskı işaretleri tabakaya sığmıyor."); return result
        }
        let reserve = project.autoLayout?.clipBleedToSheet == true ? max(0,s.cropMarkLength > 0 ? s.cropMarkOffset+s.cropMarkLength : 0) : max(s.bleed,s.cropMarkOffset+s.cropMarkLength)
        for offset in stride(from: 0, to: units.count, by: layout.capacity) {
            var front = Side(); var back = Side()
            for index in 0..<min(layout.capacity, units.count - offset) {
                let unit = units[offset + index]
                let origin = Point(layout.origin.x + Double(index % layout.columns) * (layout.unitSize.width + spec.gutter),
                                   layout.origin.y + Double(index / layout.columns) * (layout.unitSize.height + spec.gutter))
                let rawSize = Size(Double(unit.columns) * trim.width + Double(unit.columns - 1) * spec.gutter,
                                   Double(unit.rows) * trim.height + Double(unit.rows - 1) * spec.gutter)
                func placed(_ slots: [Slot], shift: Point = Point(0, 0)) -> [Slot] {
                    slots.map { slot in
                        var p = slot
                        let left = slot.x > 0 ? min(s.bleed,spec.gutter/2) : s.bleed
                        let bottom = slot.y > 0 ? min(s.bleed,spec.gutter/2) : s.bleed
                        let right = slot.x+trim.width < rawSize.width-0.000001 ? min(s.bleed,spec.gutter/2) : s.bleed
                        let top = slot.y+trim.height < rawSize.height-0.000001 ? min(s.bleed,spec.gutter/2) : s.bleed
                        var clip = Rect(x: slot.x+reserve-left,y: slot.y+reserve-bottom,
                                        width: trim.width+left+right,height: trim.height+bottom+top)
                        p.origin.x += reserve; p.origin.y += reserve
                        if layout.rotated {
                            let old = p.origin
                            p.origin = Point(old.y, rawSize.width + 2*reserve - old.x - p.size.width)
                            p.size = Size(slot.size.height, slot.size.width)
                            p.rotation = (p.rotation + 90) % 360
                            clip = Rect(x: clip.origin.y,y: rawSize.width+2*reserve-clip.origin.x-clip.size.width,
                                        width: clip.size.height,height: clip.size.width)
                        }
                        p.origin.x += origin.x + shift.x; p.origin.y += origin.y + shift.y
                        clip.origin.x += origin.x+shift.x; clip.origin.y += origin.y+shift.y
                        p.artworkClip = clip
                        return p
                    }
                }
                let f = placed(unit.front)
                let b = placed(unit.back)
                if s.turnMethod == .sheetwise {
                    front.slots += f; back.slots += b
                } else {
                    // Same-plate work styles: one complete front/back pair occupies opposite halves.
                    // The reflected back uses an inverted coordinate frame; content reflection is explicit.
                    front.slots += f + b.map { reflected($0, layout.size, s.turnMethod) }
                }
                // Fold lines follow panel boundaries, including rotated units.
                var folds: [Mark] = []
                for c in 1..<unit.columns {
                    let x = Double(c) * (trim.width + spec.gutter) - spec.gutter/2
                    folds.append(Mark(kind: .fold, start: Point(x, 0), end: Point(x, rawSize.height)))
                }
                if unit.rows > 1 {
                    for r in 1..<unit.rows {
                        let y = Double(r) * (trim.height + spec.gutter) - spec.gutter/2
                        folds.append(Mark(kind: .fold, start: Point(0, y), end: Point(rawSize.width, y)))
                    }
                }
                func point(_ p: Point) -> Point {
                    let q = Point(p.x + reserve, p.y + reserve)
                    return layout.rotated ? Point(origin.x + q.y, origin.y + rawSize.width + 2*reserve - q.x) : Point(origin.x + q.x, origin.y + q.y)
                }
                let fm = folds.map { Mark(kind: .fold, start: point($0.start), end: point($0.end)) }
                front.marks += fm
                if s.turnMethod == .sheetwise { back.marks += fm }
                else { front.marks += fm.map { reflectMark($0, layout.size, s.turnMethod) } }
            }
            if s.turnMethod != .sheetwise {
                back.slots = front.slots.map { reflected($0, layout.size, s.turnMethod) }
                back.marks = front.marks.map { reflectMark($0, layout.size, s.turnMethod) }
            }
            if project.autoLayout?.clipBleedToSheet == true {
                func clipped(_ side: Side) -> Side {
                    var side = side
                    for i in side.slots.indices {
                        guard let r = side.slots[i].artworkClip else { continue }
                        let x = max(0,r.origin.x),y = max(0,r.origin.y)
                        side.slots[i].artworkClip = Rect(x: x,y: y,width: min(layout.size.width,r.origin.x+r.size.width)-x,
                                                       height: min(layout.size.height,r.origin.y+r.size.height)-y)
                    }
                    return side
                }
                front = clipped(front); back = clipped(back)
            }
            front.marks += front.slots.flatMap { marks($0, s) }
            back.marks += back.slots.flatMap { marks($0, s) }
            removeIntrudingCropMarks(&front)
            removeIntrudingCropMarks(&back)
            let guides = pressGuides(spec, layout.size)
            front.marks += guides; back.marks += guides
            result.sheets.append(Sheet(size: layout.size, front: front, back: back))
        }
        if result.issues.contains(where: { $0.code == .missingBleed }) {
            result.issues.removeAll { $0.code == .missingBleed }
            let insufficient = Set(project.pages.filter { ($0.availableBleed ?? -1) < s.bleed }.map(\.number))
            for (sheetIndex, sheet) in result.sheets.enumerated() {
                for (kind, side) in [(SideKind.front, sheet.front), (.back, sheet.back)] {
                    for (slotIndex, slot) in side.slots.enumerated() {
                        if let page = slot.sourcePageNumber, insufficient.contains(page) {
                            result.issues.append(ValidationIssue(.warning, .missingBleed,
                                "Sayfa \(page): taşma payı eksik veya bilinmiyor.",
                                slot: SlotReference(sheet: sheetIndex, side: kind, slot: slotIndex)))
                        }
                    }
                }
            }
        }
        return result
    }
    static func pressGuides(_ spec: SheetSpec, _ size: Size) -> [Mark] {
        let m = spec.margins
        let a = Point(m.left,m.bottom), b = Point(size.width-m.right,m.bottom)
        let c = Point(size.width-m.right,size.height-m.top), d = Point(m.left,size.height-m.top)
        var marks = [(a,b),(b,c),(c,d),(d,a)].map { Mark(kind: .margin,start: $0.0,end: $0.1) }
        let w = spec.gripperWidth
        let start: Point, end: Point
        switch spec.gripperEdge {
        case .left: start = Point(m.left+w,m.bottom); end = Point(m.left+w,size.height-m.top)
        case .right: start = Point(size.width-m.right-w,m.bottom); end = Point(size.width-m.right-w,size.height-m.top)
        case .bottom: start = Point(m.left,m.bottom+w); end = Point(size.width-m.right,m.bottom+w)
        case .top: start = Point(m.left,size.height-m.top-w); end = Point(size.width-m.right,size.height-m.top-w)
        }
        marks.append(Mark(kind: .gripper,start: start,end: end,label: "Maşa \(w) mm"))
        return marks
    }
    private static func signatureGrid(_ n: Int) -> (Int, Int) { n == 8 ? (2, 2) : (4, n / 8) }
    private static func makeSlot(_ page: Int?, _ x: Int, _ y: Int, _ size: Size, _ gutter: Double, _ signature: Int) -> Slot {
        Slot(sourcePageNumber: page, origin: Point(Double(x)*(size.width+gutter), Double(y)*(size.height+gutter)), size: size, signature: signature)
    }
    private struct Layer { var cell: Int; var up = true; var rotation = 0 }
    private static func foldedUnit(_ pages: [Int?], _ size: Size, _ gutter: Double, _ signature: Int) -> Unit {
        let (columns, rows) = signatureGrid(pages.count)
        var grid = (0..<rows).map { y in (0..<columns).map { x in [Layer(cell: y*columns+x)] } }
        var width = columns; var height = rows
        // Left half folds over right; bottom half folds over top. Each moving stack reverses.
        while width > 1 {
            let half = width / 2
            let previous = grid
            for y in 0..<height {
                for x in 0..<half {
                    let moving = previous[y][half-1-x].reversed().map { Layer(cell: $0.cell, up: !$0.up, rotation: $0.rotation) }
                    grid[y][x] = Array(moving) + previous[y][half+x]
                }
            }
            width = half
        }
        while height > 1 {
            let half = height / 2
            let previous = grid
            for y in 0..<half {
                let moving = previous[half-1-y][0].reversed().map { Layer(cell: $0.cell, up: !$0.up, rotation: ($0.rotation+180)%360) }
                grid[y][0] = Array(moving) + previous[half+y][0]
            }
            height = half
        }
        var front = (0..<(columns*rows)).map { makeSlot(nil, $0 % columns, $0 / columns, size, gutter, signature) }
        var back = front
        for (i, layer) in grid[0][0].enumerated() {
            let cell = layer.cell
            front[cell].sourcePageNumber = pages[2*i + (layer.up ? 0 : 1)]
            back[cell].sourcePageNumber = pages[2*i + (layer.up ? 1 : 0)]
            front[cell].rotation = layer.rotation; back[cell].rotation = layer.rotation
        }
        // Back is viewed from the reverse face, with a long-edge (left/right) sheet turn.
        back = back.map { p in
            var q = p; q.origin.x = Double(columns-1)*(size.width+gutter)-p.origin.x; return q
        }.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        return Unit(columns: columns, rows: rows, front: front, back: back)
    }
    private static func bestLayout(_ spec: SheetSpec, _ trim: Size, _ columns: Int, _ rows: Int, _ s: ImpositionSettings,clipBleed: Bool = false) -> Layout? {
        let reserve = clipBleed ? max(0,s.cropMarkLength > 0 ? s.cropMarkOffset+s.cropMarkLength : 0) : max(s.bleed,s.cropMarkOffset+s.cropMarkLength)
        let raw = Size(Double(columns)*trim.width + Double(columns-1)*spec.gutter + 2*reserve,
                       Double(rows)*trim.height + Double(rows-1)*spec.gutter + 2*reserve)
        guard raw.width.isFinite, raw.height.isFinite else { return nil }
        let portrait = Size(min(spec.size.width, spec.size.height), max(spec.size.width, spec.size.height))
        let sizes = spec.orientation == .portrait ? [portrait] : spec.orientation == .landscape ? [Size(portrait.height, portrait.width)] : [portrait, Size(portrait.height, portrait.width)]
        var best: Layout?
        for size in sizes {
            var m = spec.margins
            switch spec.gripperEdge {
            case .left: m.left += spec.gripperWidth
            case .right: m.right += spec.gripperWidth
            case .top: m.top += spec.gripperWidth
            case .bottom: m.bottom += spec.gripperWidth
            }
            // Shared-plate styles require symmetric printable halves to preserve registration.
            if s.turnMethod == .workAndTurn { m.left = max(m.left,m.right); m.right = m.left }
            if s.turnMethod == .workAndTumble { m.top = max(m.top,m.bottom); m.bottom = m.top }
            var w = size.width-m.left-m.right
            var h = size.height-m.top-m.bottom
            if s.turnMethod == .workAndTurn { w = (w-spec.gutter)/2 }
            if s.turnMethod == .workAndTumble { h = (h-spec.gutter)/2 }
            for rotate in [false, true] {
                let u = rotate ? Size(raw.height,raw.width) : raw
                guard w >= u.width, h >= u.height else { continue }
                let nx = (w+spec.gutter)/(u.width+spec.gutter)
                let ny = (h+spec.gutter)/(u.height+spec.gutter)
                // Bound conversion and allocation even for hostile custom dimensions.
                guard nx.isFinite, ny.isFinite else { continue }
                let candidate = Layout(size: size, origin: Point(m.left,m.bottom), columns: Int(min(nx,100_000)), rows: Int(min(ny,100_000)), rotated: rotate, unitSize: u)
                if best == nil || candidate.capacity > best!.capacity ||
                    (candidate.capacity == best!.capacity && best!.rotated && !candidate.rotated) { best = candidate }
            }
        }
        return best
    }
    private static func reflectPoint(_ p: Point, _ size: Size, _ method: TurnMethod) -> Point {
        method == .workAndTurn ? Point(size.width-p.x,p.y) : Point(p.x,size.height-p.y)
    }
    private static func reflected(_ p: Slot, _ size: Size, _ method: TurnMethod) -> Slot {
        var q = p
        if method == .workAndTurn { q.origin.x = size.width-p.x-p.size.width; q.rotation = (360-p.rotation)%360 }
        else { q.origin.y = size.height-p.y-p.size.height; q.rotation = (540-p.rotation)%360 }
        if var clip = p.artworkClip {
            if method == .workAndTurn { clip.origin.x = size.width-clip.origin.x-clip.size.width }
            else { clip.origin.y = size.height-clip.origin.y-clip.size.height }
            q.artworkClip = clip
        }
        q.mirrored.toggle(); return q
    }
    private static func reflectMark(_ m: Mark, _ size: Size, _ method: TurnMethod) -> Mark {
        Mark(kind: m.kind, start: reflectPoint(m.start,size,method), end: reflectPoint(m.end,size,method), label: m.label)
    }
    /// Shared trim boundaries need no crop line through adjacent page artwork.
    private static func removeIntrudingCropMarks(_ side: inout Side) {
        let slots = side.slots
        side.marks.removeAll { mark in
            guard mark.kind == .crop else { return false }
            return slots.contains { slot in
                let minX = min(mark.start.x, mark.end.x), maxX = max(mark.start.x, mark.end.x)
                let minY = min(mark.start.y, mark.end.y), maxY = max(mark.start.y, mark.end.y)
                let epsilon = 0.000001
                return maxX > slot.x + epsilon && minX < slot.x + slot.size.width - epsilon &&
                    maxY > slot.y + epsilon && minY < slot.y + slot.size.height - epsilon
            }
        }
    }
    static func marks(_ p: Slot, _ s: ImpositionSettings) -> [Mark] {
        var result: [Mark] = []
        let x = p.x, y = p.y, w = p.size.width, h = p.size.height
        func rectangle(_ inset: Double, _ kind: MarkKind) {
            let a = Point(x+inset,y+inset), b = Point(x+w-inset,y+inset)
            let c = Point(x+w-inset,y+h-inset), d = Point(x+inset,y+h-inset)
            result += [(a,b),(b,c),(c,d),(d,a)].map { Mark(kind: kind,start: $0.0,end: $0.1) }
        }
        if let clip = p.artworkClip {
            let l = clip.origin.x, b = clip.origin.y, r = l+clip.size.width, t = b+clip.size.height
            let a = Point(l,b), c = Point(r,b), d = Point(r,t), e = Point(l,t)
            result += [(a,c),(c,d),(d,e),(e,a)].map { Mark(kind: .bleed,start: $0.0,end: $0.1) }
        } else { rectangle(-s.bleed,.bleed) }
        rectangle(s.safeAreaInset,.safeArea)
        if s.cropMarkLength > 0 {
            for cx in [x,x+w] {
                for cy in [y,y+h] {
                    let dx: Double = cx == x ? -1 : 1, dy: Double = cy == y ? -1 : 1
                    result.append(Mark(kind: .crop, start: Point(cx+dx*s.cropMarkOffset,cy), end: Point(cx+dx*(s.cropMarkOffset+s.cropMarkLength),cy)))
                    result.append(Mark(kind: .crop, start: Point(cx,cy+dy*s.cropMarkOffset), end: Point(cx,cy+dy*(s.cropMarkOffset+s.cropMarkLength))))
                }
            }
        }
        result.append(Mark(kind: .pageLabel, start: Point(x+w/2,y+h/2), end: Point(x+w/2,y+h/2), label: p.sourcePageNumber.map(String.init) ?? "Boş"))
        return result
    }
}
