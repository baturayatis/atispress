import SwiftUI
import ImpositionCore
import PDFEngine

struct ScaleWindowRequest:Identifiable {
    let id = UUID()
    var row:Int
    var suggested:RescaleSettings?
}
enum ScalingPresentation {
    static func size(_ size:Size) -> String { TRFormat.size(size.width,size.height) }
    static func percent(_ scale:ArtworkRescale) -> String {
        let f = scale.factors
        return "%\(TRFormat.dimension(f.width*100))" + (abs(f.width-f.height)>0.0001 ? " × %\(TRFormat.dimension(f.height*100))" : "")
    }
    static func change(source:Size,settings:RescaleSettings) -> String {
        guard settings.isValid,source.width>0,source.height>0 else { return "Geçerli bir ebat girin." }
        let scale = ArtworkRescale(source:source,settings:settings)
        let word = max(scale.factors.width,scale.factors.height)>1 ? "büyür" : min(scale.factors.width,scale.factors.height)<1 ? "küçülür" : "aynı kalır"
        return "\(size(source)) → \(size(settings.target)) (\(percent(scale)) \(word))"
    }
    static func targets(booklet:Bool) -> [(String,Size)] {
        booklet ? [("A5",Size(148,210)),("A6",Size(105,148))] : [
            ("90 × 50",Size(90,50)),("85 × 55",Size(85,55)),("85,6 × 54",Size(85.6,54)),
            ("A7",Size(74,105)),("A6",Size(105,148)),("A5",Size(148,210)),("A4",Size(210,297)),("A3",Size(297,420)),("DL",Size(99,210))]
    }
    static func nearest(source:Size,booklet:Bool) -> Size {
        if booklet { return source.width>source.height ? Size(210,148) : Size(148,210) }
        return targets(booklet:false).min { a,b in
            hypot(a.1.width-source.width,a.1.height-source.height) < hypot(b.1.width-source.width,b.1.height-source.height)
        }?.1 ?? Size(90,50)
    }
    static func warnings(source:Size,settings:RescaleSettings,sourceDPI:Double?) -> [String] {
        guard settings.isValid,source.width>0,source.height>0 else { return [] }
        let scale = ArtworkRescale(source:source,settings:settings), f = scale.factors
        var lines:[String] = []
        if scale.aspectWarning { lines.append("En/boy oranı %2’den fazla değişir; görseller ve yazılar esneyebilir.") }
        if max(f.width,f.height)>1 {
            let dpi = sourceDPI.map { " (yaklaşık \(Int(($0/max(f.width,f.height)).rounded())) dpi)" } ?? " (etkin dpi bilgisi yok)"
            lines.append("Görseller büyütülünce kalite düşebilir"+dpi)
        }
        if min(f.width,f.height)<0.999 { lines.append("Yazılar %\(TRFormat.dimension((1-min(f.width,f.height))*100)) küçülür.") }
        return lines
    }
}
extension Workspace {
    var selectedScalingRowIndex:Int {
        scalingRows.firstIndex { row in
            if let id = selectedGangJob?.id { return row.gangID == id }
            return !selectedPages.isDisjoint(with:row.pages)
        } ?? 0
    }
    func openScaleWindow(prompt:RescalePrompt? = nil) {
        let index = prompt.flatMap { p in scalingRows.firstIndex { $0.pages == p.pages && $0.gangID == p.gangID && $0.jobIndex == p.jobIndex } } ?? selectedScalingRowIndex
        scaleWindow = ScaleWindowRequest(row:index,suggested:prompt.map { RescaleSettings(target:ScalingPresentation.nearest(source:$0.size,booklet:project.isBooklet)) })
    }
    func useGeneralScale(row:Int) {
        guard scalingRows.indices.contains(row) else { return }
        let job = scalingRows[row]
        let rows = scalingRows
        updateScaling { value in
            value.overrides = value.overrides.flatMap { override -> [ScalingOverride] in
                guard override.gangID == job.gangID else { return [override] }
                if override.jobIndex == nil,job.jobIndex != nil {
                    // A broad legacy exception must keep applying to the other
                    // repeated jobs when just one returns to the general setting.
                    return rows.filter { $0.gangID == job.gangID && $0.jobIndex != job.jobIndex }.compactMap { row in
                        let pages = row.pages.filter(override.pages.contains)
                        return pages.isEmpty ? nil : ScalingOverride(pages:pages,jobIndex:row.jobIndex,gangID:row.gangID,settings:override.settings)
                    }
                }
                var next = override
                if next.jobIndex == job.jobIndex { next.pages.removeAll { job.pages.contains($0) } }
                return next.pages.isEmpty ? [] : [next]
            }
        }
        scaleWindow = nil
    }
    func scaledMiniature(pages:[Int],sourceSize:Size,settings:RescaleSettings) -> NSImage? {
        guard settings.isValid,let source,let number = pages.first,let document = CGPDFDocument(source.url as CFURL),let page = document.page(at:number) else { return nil }
        let factor = min(400/settings.target.width,160/settings.target.height)
        let w = max(1,Int(settings.target.width*factor)),h = max(1,Int(settings.target.height*factor))
        guard let context = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:w,height:h))
        context.scaleBy(x:factor,y:factor)
        var slot = Slot(sourcePageNumber:number,origin:Point(0,0),size:settings.target,rotation:0)
        slot.rescale = ArtworkRescale(source:sourceSize,settings:settings)
        try? PDFPlanRenderer.drawSlot(slot,page:page,in:context,reference:SlotReference(sheet:0,side:.front,slot:0),overlays:[GeneratedBleedOverlay(settings:GeneratedBleedSettings(enabled:true),cache:source.edgeSamples,sampleIfMissing:true)])
        return context.makeImage().map { NSImage(cgImage:$0,size:NSSize(width:w,height:h)) }
    }
    func applyScaleWindow(_ settings:RescaleSettings?,all:Bool,row:Int) {
        guard settings?.isValid != false else { return }
        if all {
            updateScaling { value in value.enabled = settings != nil; if let settings { value.defaults = settings }; value.overrides = [] }
        } else if scalingRows.indices.contains(row) {
            let selected = scalingRows[row]
            setScale(settings,pages:selected.pages,gangID:selected.gangID,jobIndex:selected.jobIndex)
        }
        scaleWindow = nil
        if let prompt = rescalePrompt { finishScaleSuggestion(prompt) }
    }
    func finishScaleSuggestion(_ prompt:RescalePrompt) {
        rescalePrompt = nil
        if !pendingScalePrompts.isEmpty { rescalePrompt = pendingScalePrompts.removeFirst() }
    }
    var scalingStatus:String {
        let rows = scalingRows.filter { $0.settings != nil }
        guard let row = rows.first,let settings = row.settings,settings.isValid else { return "" }
        let scale = ArtworkRescale(source:row.size,settings:settings)
        return "\(TRFormat.dimension(row.size.width))×\(TRFormat.dimension(row.size.height)) → \(TRFormat.dimension(settings.target.width))×\(TRFormat.dimension(settings.target.height)) · \(ScalingPresentation.percent(scale))" + (rows.contains { $0.settings != settings } ? " · farklı işler" : "")
    }
    var scalingSizeText:String {
        guard scalingRows.indices.contains(selectedScalingRowIndex) else { return "Ebat: —" }
        let row = scalingRows[selectedScalingRowIndex]
        guard let settings = row.settings,settings.isValid else { return "Ebat: "+ScalingPresentation.size(row.size) }
        return "Ebat: \(ScalingPresentation.size(settings.target)) (\(TRFormat.dimension(row.size.width)) × \(TRFormat.dimension(row.size.height))’den ölçeklendi, \(ScalingPresentation.percent(ArtworkRescale(source:row.size,settings:settings))))"
    }
    func scalingSourceDPI(pages:[Int]) -> Double? {
        // Preflight reports measured low effective DPI. Never invent a 300 dpi source.
        let text = (source?.preflight ?? []).filter { $0.code == "dpi" && pages.contains($0.page) }.map(\.explanation).joined(separator:" ")
        guard let regex = try? NSRegularExpression(pattern:"yaklaşık ([0-9]+) dpi") else { return nil }
        let ns = text as NSString
        return regex.matches(in:text,range:NSRange(location:0,length:ns.length)).compactMap { Double(ns.substring(with:$0.range(at:1))) }.min()
    }
}
struct ScalingSizeRow:View {
    @ObservedObject var model:Workspace
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            Text(model.scalingSizeText).font(.callout).fixedSize(horizontal:false,vertical:true)
            Button(model.project.hasRescaling ? "Değiştir" : "Ebadı değiştir…") { model.openScaleWindow() }.disabled(model.scalingRows.isEmpty)
        }
    }
}
struct ScalingSuggestionBanner:View {
    @ObservedObject var model:Workspace
    let prompt:RescalePrompt
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text("Bu iş \(ScalingPresentation.size(prompt.size)). \(model.project.isBooklet ? "İsterseniz tüm sayfaları daha küçük ebada ölçekleyin." : "Standart kartvizit 90 × 50 değil.")").font(.system(size:12))
            HStack { Button("Ölçekle") { model.openScaleWindow(prompt:prompt) }; Button("Olduğu gibi bas") { model.finishScaleSuggestion(prompt) } }
        }.padding(8).background(DesignSystem.warningSurface,in:RoundedRectangle(cornerRadius:8))
    }
}

struct ScaleWindowView:View {
    @ObservedObject var model:Workspace
    let request:ScaleWindowRequest
    @State var settings:RescaleSettings
    @State var all = true
    @State var row:Int
    @State private var custom = false
    @State private var image:NSImage?
    @State private var afterImage:NSImage?
    init(model:Workspace,request:ScaleWindowRequest) {
        self.model = model; self.request = request
        let rows = model.scalingRows
        let index = rows.indices.contains(request.row) ? request.row : 0
        _row = State(initialValue:index)
        _settings = State(initialValue:request.suggested ?? (rows.indices.contains(index) ? rows[index].settings ?? RescaleSettings(target:rows[index].size) : RescaleSettings()))
    }
    var showsJobScope:Bool { model.scalingRows.count>1 }
    private var source:Size { model.scalingRows.indices.contains(row) ? model.scalingRows[row].size : Size(90,50) }
    var currentSize:Size { model.scalingRows.indices.contains(row) ? model.scalingRows[row].settings?.target ?? source : source }
    private var pages:[Int] { model.scalingRows.indices.contains(row) ? model.scalingRows[row].pages : [] }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Ebadı değiştir").font(.title2.bold())
            Text("1 · Yeni ebat").font(.headline)
            Text("Şu an: \(ScalingPresentation.size(currentSize))").font(.system(size:12))
            LazyVGrid(columns:[GridItem(.adaptive(minimum:90))],spacing:6) {
                ForEach(Array(ScalingPresentation.targets(booklet:model.project.isBooklet).enumerated()),id:\.offset) { _,target in
                    Button { settings.target = target.1; custom = false } label: {
                        Text(target.0+(target.1 == currentSize ? " · Şu an" : "")).frame(maxWidth:.infinity)
                    }.tint(settings.target == target.1 ? DesignSystem.teal : nil)
                }
                Button("Özel ölçü") { custom = true }
            }
            if custom || !ScalingPresentation.targets(booklet:model.project.isBooklet).contains(where: { $0.1 == settings.target }) {
                HStack { DimensionInput("Genişlik",value:$settings.target.width,range:1...3000); Text("×"); DimensionInput("Yükseklik",value:$settings.target.height,range:1...3000) }
            }
            Text(ScalingPresentation.change(source:source,settings:settings)).font(.callout.weight(.medium))
            Text("2 · Nasıl sığsın?").font(.headline)
            HStack(alignment:.top,spacing:8) {
                mode(.fit,"Tamamı görünsün","Oran korunur, boş kalan yer kenar rengiyle dolar.")
                mode(.fill,"Alan dolsun","Oran korunur, taşan kısım kesilir.")
                mode(.stretch,"Ebada esnet","Oran bozulabilir.")
            }
            Text("3 · Hangi işlere?").font(.headline)
            if showsJobScope {
                Picker("Kapsam",selection:$all) { Text("Tüm işler").tag(true); Text("Sadece seçili iş").tag(false) }.pickerStyle(.segmented)
                if !all {
                    Picker("İş",selection:$row) { ForEach(model.scalingRows) { r in Text(r.title).tag(r.id) } }
                    Button("Genel ayarı kullan") { model.useGeneralScale(row:row) }
                }
            } else { Text("Tüm işler").font(.callout) }
            if model.project.isBooklet { Text("Tüm sayfalar ölçeklenir, sayfa sayısı değişmez").font(.system(size:12)) }
            ScaleMiniature(source:source,settings:settings,image:image,afterImage:afterImage).frame(height:95)
            ForEach(ScalingPresentation.warnings(source:source,settings:settings,sourceDPI:model.scalingSourceDPI(pages:pages)),id:\.self) { Text($0).font(.system(size:12)).foregroundStyle(DesignSystem.warning) }
            HStack {
                if model.project.hasRescaling { Button("Ölçeklemeyi kaldır") { model.applyScaleWindow(nil,all:all,row:row) } }
                Spacer()
                Button("Vazgeç") { model.scaleWindow = nil }.keyboardShortcut(.cancelAction)
                Button("Uygula") { model.applyScaleWindow(settings,all:all,row:row) }.buttonStyle(.borderedProminent).disabled(!settings.isValid).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width:620).background(DesignSystem.workspace).tint(DesignSystem.teal)
        .task(id:pages) { image = nil; if let number = pages.first { image = await model.source?.image(page:number,pixels:512) } }
        .task(id: "\(pages)-\(settings)") { afterImage = model.scaledMiniature(pages:pages,sourceSize:source,settings:settings) }
        .onChange(of:row) { _,index in if model.scalingRows.indices.contains(index) { settings = model.scalingRows[index].settings ?? RescaleSettings(target:model.scalingRows[index].size) } }
    }
    private func mode(_ mode:RescaleMode,_ title:String,_ detail:String) -> some View {
        Button { settings.mode = mode } label: {
            VStack(alignment:.leading,spacing:5) {
                ScaleMiniature(source:source,settings:RescaleSettings(target:settings.target,mode:mode),image:nil).frame(height:42)
                Text(title).font(.callout.bold()); Text(detail).font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
                if mode == .stretch,settings.isValid,ArtworkRescale(source:source,settings:RescaleSettings(target:settings.target,mode:mode)).aspectWarning { Text("Oran %2’den fazla değişir").font(.system(size:12)).foregroundStyle(DesignSystem.warning) }
            }.padding(8).frame(maxWidth:.infinity,minHeight:120,alignment:.topLeading).background(settings.mode == mode ? DesignSystem.successSurface : DesignSystem.workspace,in:RoundedRectangle(cornerRadius:8))
        }.buttonStyle(.plain)
    }
}
struct ScaleMiniature:View {
    let source:Size
    let settings:RescaleSettings
    var image:NSImage?
    var afterImage:NSImage?
    var body:some View {
        HStack(spacing:10) {
            thumbnail(source:source,settings:RescaleSettings(target:source)).overlay(alignment:.bottom) { Text("Önce").font(.system(size:12)).background(.regularMaterial) }
            Image(systemName:"arrow.right")
            Group { if let afterImage { Image(nsImage:afterImage).resizable().scaledToFit() } else { thumbnail(source:source,settings:settings) } }.overlay(alignment:.bottom) { Text("Sonra").font(.system(size:12)).background(.regularMaterial) }
        }
    }
    private func thumbnail(source:Size,settings:RescaleSettings) -> some View {
        GeometryReader { g in
            if settings.isValid,source.width>0,source.height>0 {
                let factor = min(g.size.width/settings.target.width,g.size.height/settings.target.height)
                let art = ArtworkRescale(source:source,settings:settings).artwork
                ZStack(alignment:.topLeading) {
                    Rectangle().fill(DesignSystem.paper)
                    Group {
                        if let image { Image(nsImage:image).resizable() }
                        else { ZStack { Rectangle().fill(DesignSystem.teal.opacity(0.3)); Text("Aa").foregroundStyle(Color(nsColor:DesignSystem.focusNS)) } }
                    }.frame(width:art.size.width*factor,height:art.size.height*factor).offset(x:art.origin.x*factor,y:art.origin.y*factor)
                }.frame(width:settings.target.width*factor,height:settings.target.height*factor).clipped().overlay(Rectangle().stroke(DesignSystem.muted,lineWidth:1)).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
    }
}
