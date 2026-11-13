import Foundation

public enum BookPlanner {
    public static func spreadSize(trim: Size,spine: Double,leftFlap: Double = 0,rightFlap: Double = 0) -> Size {
        Size(2*trim.width+spine+leftFlap+rightFlap,trim.height)
    }
    public static func plan(_ original: Project) -> ImpositionPlan {
        guard let book = original.book else { return ImpositionPlanner.plan(original) }
        var issues: [ValidationIssue] = []
        func issue(_ text: String,_ severity: ValidationIssue.Severity = .error) { issues.append(ValidationIssue(severity,.bookSettings,text)) }
        guard book.isValid else {
            var legacy = original; legacy.book = nil; legacy.coverMode = .included; legacy.pages = original.bookInteriorPages
            var fallback = ImpositionPlanner.plan(legacy)
            fallback.issues.append(ValidationIssue(.error,.bookSettings,"Kâğıt kalınlığı pozitif, paylar ve kulaklar 0–500 mm olmalıdır; geçersiz değerler uygulanmadı.")); return fallback
        }
        let selection = original.resolvedCoverSelection,domain = original.bookCoverPages
        let isSpread = original.coverMode == .separate && book.coverArtwork == .spread
        let roles = isSpread ? [selection.front,selection.insideFront] : [selection.front,selection.insideFront,selection.insideBack,selection.back]
        if roles.compactMap({ $0 }).contains(where:{ $0<0 }) { issue("Kapak sayfa numaraları pozitif olmalıdır; boş iç yüz için 0 kullanılır.") }
        let chosen = roles.compactMap { $0 }.filter { $0>0 }
        if selection.front == nil || selection.front == 0 || (!isSpread && (selection.back == nil || selection.back == 0)) { issue("Ön ve arka kapak sayfalarını seçin.") }
        if original.coverMode == .excluded && (selection.insideFront == nil || selection.insideBack == nil) { issue("İç kapak sayfalarını seçin veya Boş seçeneğini kullanın.") }
        if Set(chosen).count != chosen.count { issue("Bir PDF sayfası birden çok kapak yüzüne atanamaz.") }
        if chosen.contains(where: { number in !domain.contains { $0.number==number } }) { issue("Seçilen kapak sayfası etkin kaynakta yok veya baskı seçimine dahil değil.") }
        if original.coverMode == .included && domain.count<4 { issue("Dahil kapak için PDF’de en az dört kapak yüzü gerekir.") }
        if original.coverMode == .separate && (book.coverPDFPages.isEmpty || book.coverSourceID == nil) { issue("Ayrı kapak PDF’sini yükleyin.") }
        var body = original; body.book = nil; body.coverMode = .included; body.pages = original.bookInteriorPages; body.serialFields = []
        var result = ImpositionPlanner.plan(body)
        if body.pages.isEmpty { issue("Kapaklar ayrıldıktan sonra iç sayfa kalmadı.") }
        let trim = body.pages.first?.trimSize ?? domain.first?.trimSize ?? Size(0,0)
        guard trim.width>0,trim.height>0 else {
            result.issues += issues; return result
        }
        let pageCount = body.pages.count+result.addedBlankPages
        let spine: Double?
        if original.binding == .perfectBound {
            if let caliper = book.interiorPaper.millimetres {
                spine = MeasuredSpineCalculator(coverAllowance:book.coverAllowance,adhesiveAllowance:book.adhesiveAllowance).thickness(pageCount:pageCount,stockCaliper:caliper)
            } else { spine = nil; issue("Sırt hesabı için iç kâğıt kalınlığını girin (µm veya gramaj × cilt katsayısı).") }
        } else { spine = 0 }
        let spread = spreadSize(trim:trim,spine:spine ?? 0,leftFlap:original.binding == .perfectBound ? book.leftFlap : 0,rightFlap:original.binding == .perfectBound ? book.rightFlap : 0)
        var maximumCreep = 0.0
        if book.creepEnabled {
            if original.binding != .saddleStitch { issue("Creep yalnız tel dikişte uygulanır; bu ciltleme için kapatın.") }
            else if let inside = book.interiorPaper.millimetres,let cover = book.coverPaper.millimetres {
                let leaves = max(1,(pageCount+3)/4)
                let calculator: any CreepCalculating = LinearCreepCalculator(interiorThickness:inside,coverThickness:cover)
                maximumCreep = calculator.displacement(sheetIndex:leaves-1,sheetCount:leaves,stockCaliper:inside)
                if maximumCreep >= trim.width/2 { issue(String(format:"Creep %.3f mm; sayfa eninin yarısı %.3f mm değerine ulaşamaz.",maximumCreep,trim.width/2)) }
                else {
                    for index in result.sheets.indices {
                        func shifted(_ side: Side) -> Side {
                            var next = side
                            for s in next.slots.indices {
                                guard let leaf = next.slots[s].bookLeafIndex,let left = next.slots[s].bookPanelIsLeft else { continue }
                                let value = calculator.displacement(sheetIndex:leaf,sheetCount:leaves,stockCaliper:inside)
                                next.slots[s].artworkOffset.x = left ? value : -value
                            }
                            return next
                        }
                        result.sheets[index].front = shifted(result.sheets[index].front)
                        result.sheets[index].back = shifted(result.sheets[index].back)
                    }
                }
            } else { issue("Creep için iç ve kapak kâğıdı kalınlıklarını girin; kalınlık tahmin edilmez.") }
        }
        var info = BookSheetInfo(section:.interior,interiorPageCount:pageCount,spine:spine,spreadSize:spread,interiorPaper:book.interiorPaper,coverPaper:book.coverPaper,maximumCreep:maximumCreep)
        info.bleed = original.settings.bleed; info.bleedClippedToSheet = original.clipsArtworkToSheet
        info.creepEnabled = book.creepEnabled; info.coverAllowance = book.coverAllowance; info.adhesiveAllowance = book.adhesiveAllowance
        info.leftFlap = original.binding == .perfectBound ? book.leftFlap : 0; info.rightFlap = original.binding == .perfectBound ? book.rightFlap : 0
        for i in result.sheets.indices { result.sheets[i].bookInfo = info }
        for i in result.diagnosticSheets.indices { result.diagnosticSheets[i].bookInfo = info }
        func page(_ number: Int?) -> SourcePage? { number.flatMap { n in domain.first { $0.number==n } } }
        let front = page(selection.front),insideFront = page(selection.insideFront),insideBack = page(selection.insideBack),back = page(selection.back)
        let activeCoverPages = [front,insideFront,insideBack,back].compactMap { $0 }
        if original.settings.bleed>0 && !original.settings.generatedBleed.enabled {
            let missing = activeCoverPages.filter { ($0.availableBleed ?? 0)<original.settings.bleed }
            if !missing.isEmpty {
                var warning = ValidationIssue(.warning,.missingBleed,"Kapak: taşma payı eksik veya bilinmiyor.")
                warning.affectedPages = missing.map(\.number); issues.append(warning)
            }
        }
        if !isSpread {
            for p in [front,insideFront,insideBack,back].compactMap({ $0 }) where abs(p.trimSize.width-trim.width)>0.1 || abs(p.trimSize.height-trim.height)>0.1 {
                issue(String(format:"Kapak sayfa %d: %.2f×%.2f mm; gerekli tek yüz %.2f×%.2f mm. Ölçek değiştirilmez.",p.number,p.trimSize.width,p.trimSize.height,trim.width,trim.height))
            }
        } else if spine != nil {
            for p in [front,insideFront].compactMap({ $0 }) where abs(p.trimSize.width-spread.width)>0.1 || abs(p.trimSize.height-spread.height)>0.1 {
                issue(String(format:"Kapak PDF sayfa %d: %.2f×%.2f mm; hesaplanan açılım %.2f×%.2f mm (sırt %.3f mm). Ölçek değiştirilmez; hesaplanan açılımda kırpılır.",p.number,p.trimSize.width,p.trimSize.height,spread.width,spread.height,spine ?? 0),.warning)
            }
        }
        if let first = front {
            var template = original; template.book = nil; template.bookCoverTemplate = true
            template.binding = .stepAndRepeat; template.coverMode = .included; template.serialFields = []
            template.pages = [SourcePage(number:first.number,trimSize:spread,availableBleed:original.settings.bleed),SourcePage(number:first.number,trimSize:spread,availableBleed:original.settings.bleed)]
            let flipX = original.settings.turnMethod != .workAndTumble
            let samePlate = original.settings.turnMethod != .sheetwise
            template.stepAndRepeat = StepAndRepeatSettings(columns:samePlate && flipX ? 2 : 1,rows:samePlate && !flipX ? 2 : 1,quantity:samePlate ? 2 : 1)
            template.stepAndRepeat.pageLayout = PageLayoutSettings(); template.stepAndRepeat.pageLayout?.mode = .duplex
            // Cover folds are contiguous: body signature gutter never opens a gap in the spine.
            template.sheet.gutter = 0
            let imposed = ImpositionPlanner.plan(template)
            var coverInfo = info; coverInfo.section = .cover
            let leftFlap = original.binding == .perfectBound ? book.leftFlap : 0,rightFlap = original.binding == .perfectBound ? book.rightFlap : 0
            func pieces(inside: Bool) -> [Slot] {
                var output: [Slot] = []
                func add(_ p: SourcePage?,_ x: Double,_ width: Double,_ label: String) {
                    guard width>0 else { return }
                    let actual = p?.trimSize ?? Size(width,trim.height)
                    var s = Slot(sourcePageNumber:p?.number,origin:Point(x,0),size:actual)
                    s.bookRegion = label
                    let b = original.settings.bleed
                    s.artworkClip = Rect(x:x == 0 ? -b : x,y:-b,width:width+(x == 0 ? b : 0)+(abs(x+width-spread.width)<0.000001 ? b : 0),height:trim.height+2*b)
                    output.append(s)
                }
                if isSpread {
                    let p = inside ? insideFront : front
                    add(p,0,spread.width,inside ? "İç kapak açılımı" : "Dış kapak açılımı")
                } else {
                    let l = inside ? rightFlap : leftFlap,r = inside ? leftFlap : rightFlap
                    add(nil,0,l,"Kulak")
                    add(inside ? insideFront : back,l,trim.width,inside ? "İç ön" : "Arka kapak")
                    add(nil,l+trim.width,spine ?? 0,"Sırt")
                    add(inside ? insideBack : front,l+trim.width+(spine ?? 0),trim.width,inside ? "İç arka" : "Ön kapak")
                    add(nil,l+2*trim.width+(spine ?? 0),r,"Kulak")
                }
                return output
            }
            func transformed(_ p: Point,by whole: Slot) -> Point {
                // Same clockwise/reflection contract as PDFPreviewDrawing.slotTransform, in pure core.
                func rotated(_ p: Point) -> Point {
                    let q = whole.mirrored ? Point(-p.x,p.y) : p
                    switch (whole.rotation%360+360)%360 {
                    case 90: return Point(q.y,-q.x)
                    case 180: return Point(-q.x,-q.y)
                    case 270: return Point(-q.y,q.x)
                    default: return q
                    }
                }
                let corners = [Point(0,0),Point(spread.width,0),Point(0,spread.height),Point(spread.width,spread.height)].map(rotated)
                let q = rotated(p)
                return Point(whole.x+q.x-corners.map(\.x).min()!,whole.y+q.y-corners.map(\.y).min()!)
            }
            func rect(_ r: Rect,by whole: Slot) -> Rect {
                let points = [r.origin,Point(r.origin.x+r.size.width,r.origin.y),Point(r.origin.x,r.origin.y+r.size.height),Point(r.origin.x+r.size.width,r.origin.y+r.size.height)].map { transformed($0,by:whole) }
                let x = points.map(\.x),y = points.map(\.y)
                return Rect(x:x.min()!,y:y.min()!,width:x.max()!-x.min()!,height:y.max()!-y.min()!)
            }
            func assembled(_ side: Side) -> Side {
                var output = side; output.slots = []
                for whole in side.slots {
                    let inside = whole.itemSide == .back
                    let panels = pieces(inside:inside)
                    for var panel in panels {
                        let bounds = rect(Rect(x:panel.x,y:panel.y,width:panel.size.width,height:panel.size.height),by:whole)
                        panel.origin = bounds.origin; panel.size = bounds.size; panel.rotation = whole.rotation; panel.mirrored = whole.mirrored
                        panel.artworkClip = panel.artworkClip.map { rect($0,by:whole) }
                        if let a = panel.artworkClip,let b = whole.artworkClip {
                            let x = max(a.origin.x,b.origin.x),y = max(a.origin.y,b.origin.y)
                            let w = min(a.origin.x+a.size.width,b.origin.x+b.size.width)-x
                            let h = min(a.origin.y+a.size.height,b.origin.y+b.size.height)-y
                            guard w>0,h>0 else { continue }
                            panel.artworkClip = Rect(x:x,y:y,width:w,height:h)
                        }
                        panel.itemSide = whole.itemSide
                        output.slots.append(panel)
                    }
                    let l = inside ? rightFlap : leftFlap
                    for x in Set([l,l+trim.width,l+trim.width+(spine ?? 0),spread.width-(inside ? leftFlap : rightFlap)]).sorted() where x>0 && x<spread.width {
                        output.marks.append(Mark(kind:.fold,start:transformed(Point(x,0),by:whole),end:transformed(Point(x,spread.height),by:whole)))
                    }
                }
                return output
            }
            let offset = result.sheets.count,bodyDiagnostics = result.diagnosticSheets.count
            if !imposed.sheets.isEmpty {
                for i in result.issues.indices {
                    if var ref = result.issues[i].slot,ref.sheet>=offset { ref.sheet += imposed.sheets.count; result.issues[i].slot = ref }
                }
            }
            for var sheet in imposed.sheets {
                sheet.front = assembled(sheet.front); sheet.back = assembled(sheet.back)
                sheet.bookInfo = coverInfo; sheet.repeatLayout = nil; sheet.serialPlan = nil
                result.sheets.append(sheet)
            }
            for var sheet in imposed.diagnosticSheets {
                sheet.bookInfo = coverInfo; result.diagnosticSheets.append(sheet)
            }
            for var i in imposed.issues {
                if var ref = i.slot {
                    ref.sheet = ref.sheet<imposed.sheets.count ? ref.sheet+offset : result.sheets.count+bodyDiagnostics+ref.sheet-imposed.sheets.count
                    i.slot = ref
                }
                i.message = "Kapak: "+i.message; result.issues.append(i)
            }
        }
        // Physical nesting order is outermost first. The independent cover was
        // built after the interior; move it without changing diagnostic indices.
        let order = result.sheets.indices.filter { result.sheets[$0].bookInfo?.section == .cover }
            + result.sheets.indices.filter { result.sheets[$0].bookInfo?.section != .cover }
        let newIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element,$0.offset) })
        result.sheets = order.map { result.sheets[$0] }
        for i in result.issues.indices {
            if var ref = result.issues[i].slot, let index = newIndex[ref.sheet] {
                ref.sheet = index; result.issues[i].slot = ref
            }
        }
        result.issues += issues
        let pagination = result.paginationSummary,sides = result.pdfSideCount(includeBlankBacks:original.includeBlankBacks ?? true)
        for i in result.sheets.indices {
            result.sheets[i].bookInfo?.pagination = pagination
            result.sheets[i].bookInfo?.pdfSides = sides
        }
        for i in result.diagnosticSheets.indices { result.diagnosticSheets[i].bookInfo?.pagination = pagination }
        return result
    }
}
