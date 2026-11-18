import SwiftUI
import AppKit
import ImpositionCore
import PDFEngine

struct SourcePageTools:View {
    @ObservedObject var model:Workspace
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            if model.canSeparateArtwork {
                Button(model.project.sourcePreparation?.separation == nil ? "Akıllı İş Ayırma…" : "Bölgeleri ve yüzleri düzenle…") {
                    model.showingArtworkSeparation = true
                }.help("PDF bölgelerini seçin, düzeltin ve işlere atayın.")
            }
            if let split=model.suggestedPageSplit {
                Text("Bu sayfa birden fazla kart içeriyor gibi görünüyor (\(split.columns) × \(split.rows)).").font(.system(size:12))
                HStack {Button("Sayfayı böl") {model.showingPageSplit=true};Button("Olduğu gibi kullan",action:model.dismissPageSplitSuggestion)}
            }
            if model.canSplitSource {Button("Sayfa birden fazla ürün içeriyor") {model.showingPageSplit=true}}
            if model.canInspectSourceGuides,let input=model.preparationInput {
                if input.guides.count>0 {
                    Text(input.guides.count>model.hiddenSourceGuideCount ? "Dosyada baskıya girebilecek kılavuz çizgileri var (\(input.guides.count-model.hiddenSourceGuideCount) çizgi)":"Dosyadaki kılavuz çizgileri gizlendi").font(.system(size:12)).foregroundStyle(DesignSystem.warning)
                    Button("Kılavuz çizgileri…") {model.showingSourceGuides=true}
                } else if input.guides.rasterFramesSuspected {
                    Text("Raster görüntü içinde kılavuz benzeri çerçeveler saptandı; ayrı çizgi olarak gizlenemez.").font(.system(size:12)).foregroundStyle(DesignSystem.warning)
                }
            }
            if model.hiddenSourceGuideCount>0 {Text("\(model.hiddenSourceGuideCount) kılavuz çizgisi gizlendi").font(.system(size:12))}
        }
    }
}
enum SourceImage {
    static func render(_ source:PDFSource,page:Int,url:URL? = nil) -> NSImage? {
        guard let doc=CGPDFDocument((url ?? source.url) as CFURL),let pdf=doc.page(at:page),source.pages.indices.contains(page-1) else {return nil}
        let size=source.pages[page-1].trimSize,scale=min(900/size.width,650/size.height)
        let w=max(1,Int(size.width*scale)),h=max(1,Int(size.height*scale))
        guard let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return nil}
        c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:w,height:h))
        let pt=PDFPreviewDrawing.pointsPerMM
        c.scaleBy(x:scale/pt,y:scale/pt)
        c.concatenate(pdf.getDrawingTransform(.trimBox,rect:CGRect(x:0,y:0,width:size.width*pt,height:size.height*pt),rotate:0,preserveAspectRatio:true));c.drawPDFPage(pdf)
        return c.makeImage().map {NSImage(cgImage:$0,size:NSSize(width:w,height:h))}
    }
}
struct PageSplitView:View {
    @ObservedObject var model:Workspace
    let input:PDFSource
    @State var settings:PageSplitSettings
    @State private var selectedCell:Int?
    @State private var cellMemory:[Int:SplitCell]=[:]
    @State private var useTrim=false
    @State private var trim=Size(90,50)
    @State private var image:NSImage?
    @State private var error:String?
    init(model:Workspace,input:PDFSource) {
        self.model=model;self.input=input
        var draft=model.project.sourcePreparation?.split ?? input.guides.suggestion(size:input.pages[0].trimSize) ?? PageSplitSettings(size:input.pages[0].trimSize)
        if let learned=model.pendingSourceTrim,learned.id==input.id {
            draft.explicitTrim=learned.trim;draft.cellBleed=learned.bleed
            if input.guides.learned.count==draft.cells.count {draft.learnedTrimCenters=input.guides.learned.map{Point($0.inner.origin.x+$0.inner.size.width/2,$0.inner.origin.y+$0.inner.size.height/2)}}
        }
        _image=State(initialValue:SourceImage.render(input,page:1,url:model.source?.guidePreviewURL))
        _settings=State(initialValue:draft);_trim=State(initialValue:draft.explicitTrim ?? Size(90,50));_useTrim=State(initialValue:draft.explicitTrim != nil)
    }
    private var size:Size {input.pages[0].trimSize}
    private var warning:String? {
        let lines=settings.verticalCuts.map {x in CGRect(x:x-0.1,y:0,width:0.2,height:size.height)}+settings.horizontalCuts.map {y in CGRect(x:0,y:y-0.1,width:size.width,height:0.2)}
        if input.guides.artworkBounds.contains(where:{ r in lines.contains{$0.intersects(CGRect(x:r.origin.x,y:r.origin.y,width:r.size.width,height:r.size.height))} }) {return "Kesim çizgisi baskı içeriğinin içinden geçiyor; hücreleri kontrol edin."}
        if input.guides.hasImages || input.guides.unsupported {return "Görüntü/metin içeriği kesim çizgisini aşabilir; kesim yerlerini önizlemede kontrol edin."}
        return nil
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Sayfayı böl").font(.title2.bold())
            Text("Hücreler yeni vektör sayfalara kırpılır. Ürünlerin Ön ve Arka yüzleri birlikte eşlenir; onay vermeden kaynak değişmez.").font(.system(size:12))
            if let index=selectedCell,settings.cells.indices.contains(index) {
                HStack(spacing:12) {
                    Text("Hücre \(index+1)").font(.system(size:12))
                    Menu("Ata") {
                        Button("Boş (kullanma)") {settings.cells[index].product=nil}
                        ForEach(1...max(2,settings.cells.count),id:\.self) {n in
                            Button("Ürün \(n) · Ön") {settings.cells[index]=SplitCell(product:n)}
                            Button("Ürün \(n) · Arka") {settings.cells[index]=SplitCell(product:n,side:.back)}
                        }
                    }.help("Seçili hücreye ürün ve yüz ata")
                    Menu("Böl") {
                        Button("Bir sütun ekle") {selectedCell=nil;resize(columns:settings.columns+1,rows:settings.rows)}.disabled(settings.columns>=12)
                        Button("Bir satır ekle") {selectedCell=nil;resize(columns:settings.columns,rows:settings.rows+1)}.disabled(settings.rows>=12)
                    }
                    Button(settings.cells[index].product==nil ? "Göster" : "Gizle") {
                        if settings.cells[index].product==nil {settings.cells[index]=cellMemory[index] ?? SplitCell(product:1)}
                        else {cellMemory[index]=settings.cells[index];settings.cells[index].product=nil}
                    }.help("Boş hücre baskıda kullanılmaz")
                    Spacer()
                }.controlSize(.small).padding(6).background(DesignSystem.card).accessibilityIdentifier("context.splitSelection")
            }

            HStack(alignment:.top,spacing:16) {
                GeometryReader { g in
                    let scale=min(g.size.width/size.width,g.size.height/size.height),w=size.width*scale,h=size.height*scale
                    ZStack(alignment:.topLeading) {
                        if let image {Image(nsImage:image).resizable().frame(width:w,height:h)}
                        else {Rectangle().fill(.white).frame(width:w,height:h)}
                        ForEach(Array(settings.rectangles(size:size).enumerated()),id:\.offset) { i,cell in
                            let t=settings.trim(in:cell)
                            Rectangle().stroke(selectedCell==i ? DesignSystem.teal : DesignSystem.warning,style:StrokeStyle(lineWidth:1,dash:[4,3])).frame(width:max(0,t.size.width*scale),height:max(0,t.size.height*scale)).offset(x:t.origin.x*scale,y:(size.height-t.origin.y-t.size.height)*scale)
                                .contentShape(Rectangle()).onTapGesture {selectedCell=i}
                                .focusable().onKeyPress(.return) {selectedCell=i;return .handled}
                                .accessibilityLabel("Hücre \(i+1), \(cellTitle(i))")
                            Menu {
                                Button("Boş (kullanma)") {settings.cells[i].product=nil}
                                ForEach(1...max(2,settings.cells.count),id:\.self) {n in
                                    Button("Ürün \(n) · Ön") {settings.cells[i]=SplitCell(product:n)}
                                    Button("Ürün \(n) · Arka") {settings.cells[i]=SplitCell(product:n,side:.back)}
                                }
                            } label: {Text(cellTitle(i)).font(.system(size:12)).padding(4).background(.regularMaterial,in:RoundedRectangle(cornerRadius:4))}
                                .simultaneousGesture(TapGesture().onEnded {selectedCell=i})
                                .fixedSize().position(x:(cell.origin.x+cell.size.width/2)*scale,y:(size.height-cell.origin.y-cell.size.height/2)*scale)
                        }
                        ForEach(settings.verticalCuts.indices,id:\.self) {i in
                            SplitCutLine(value:$settings.verticalCuts[i],scale:scale,length:h,vertical:true,limit:(i==0 ? 1:settings.verticalCuts[i-1]+1)...(i==settings.verticalCuts.count-1 ? size.width-1:settings.verticalCuts[i+1]-1))
                        }
                        ForEach(settings.horizontalCuts.indices,id:\.self) {i in
                            SplitCutLine(value:$settings.horizontalCuts[i],scale:scale,length:w,vertical:false,limit:(i==0 ? 1:settings.horizontalCuts[i-1]+1)...(i==settings.horizontalCuts.count-1 ? size.height-1:settings.horizontalCuts[i+1]-1),height:h)
                        }
                    }.frame(width:w,height:h).clipped().border(DesignSystem.border)
                }.frame(width:600,height:470)
                VStack(alignment:.leading,spacing:12) {
                    HStack {Text("Sütun");IntegerInput(title:"Sütun",value:Binding(get:{settings.columns},set:{resize(columns:min(12,max(1,$0)),rows:settings.rows)}),unit:"")}
                    HStack {Text("Satır");IntegerInput(title:"Satır",value:Binding(get:{settings.rows},set:{resize(columns:settings.columns,rows:min(12,max(1,$0)))}),unit:"")}
                    Picker("Hazır eşleme",selection:Binding<PageSplitSettings.Preset?>(get:{settings.matchingPreset},set:{if let value=$0 {settings.assign(value)}})) {Text("Özel eşleme").tag(PageSplitSettings.Preset?.none);ForEach(PageSplitSettings.Preset.allCases,id:\.self) {Text($0.rawValue).tag(Optional($0))}}
                    Text(settings.matchingPreset?.rawValue ?? "Özel eşleme").font(.system(size:12)).foregroundStyle(DesignSystem.muted).fixedSize(horizontal:false,vertical:true)
                    Text("Kesim çizgilerini sürükleyin. Hücre menüsünden ürün ve yüz seçin.").font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
                    if !useTrim {HStack {Text("Hücrede taşma");DimensionInput("Hücrede taşma",value:$settings.cellBleed,range:0...30)}}
                    else {
                        let minimum=settings.rectangles(size:size).map {cell in let t=settings.trim(in:cell);return min(t.origin.x-cell.origin.x,t.origin.y-cell.origin.y,cell.origin.x+cell.size.width-t.origin.x-t.size.width,cell.origin.y+cell.size.height-t.origin.y-t.size.height)}.min() ?? 0
                        Text("Hücrede taşma: en az \(TRFormat.dimension(max(0,minimum),detail:true)) mm (kesim ebadından hesaplandı)").font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
                    }
                    Toggle("Kesim ebadını elle gir",isOn:$useTrim).onChange(of:useTrim) {_,v in settings.explicitTrim=v ? trim:nil}
                    if useTrim {
                        HStack {Text("Kesim eni");DimensionInput("Kesim genişliği",value:$trim.width,range:1...3000)}
                        HStack {Text("Kesim boyu");DimensionInput("Kesim yüksekliği",value:$trim.height,range:1...3000)}
                        Text(settings.learnedTrimCenters == nil ? "Kesim hücrenin ortalanmış alanıdır; çevresindeki alan gerçek kaynak taşmasıdır.":"Kesim merkezleri algılanan çerçevelerden alındı; dış sayfa boşlukları kesimi kaydırmaz.").font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
                    }
                    if settings.learnedTrimCenters != nil {Button("Kesimi hücrelerde ortala") {settings.learnedTrimCenters=nil}}
                    if let first=settings.rectangles(size:size).first {
                        let t=settings.trim(in:first)
                        Text("Kesim: \(TRFormat.size(t.size.width,t.size.height))").font(.system(size:12).weight(.medium))
                    }
                    Text("Adet her ürün içindir. Ürünler aynı tabakayı paylaşabilir; Ön/Arka eşlemesi seçilen çevirme yöntemini kullanır.").font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
                }.frame(width:285)
            }
            if model.project.hasRescaling && settings != model.project.sourcePreparation?.split {Text("Bölme, sayfanın mevcut hedef ebat ölçeklemesini kaldırır; ürün ebatları hücrelerden alınır.").font(.system(size:12)).foregroundStyle(DesignSystem.warning)}
            if let warning {Text(warning).font(.system(size:12)).foregroundStyle(DesignSystem.warning)}
            if let message=settings.validation(size:size) {Text(message).font(.system(size:12)).foregroundStyle(DesignSystem.error)}
            if let error {Text(error).font(.system(size:12)).foregroundStyle(DesignSystem.error)}
            HStack {
                Text("\(Set(settings.cells.compactMap(\.product)).count) ürün").font(.system(size:12))
                Spacer();Button("Vazgeç") {model.showingPageSplit=false}.keyboardShortcut(.cancelAction)
                if model.preparingSource {ProgressView().controlSize(.small)}
                Button("Uygula") {apply()}.buttonStyle(.borderedProminent).disabled(settings.validation(size:size) != nil || model.preparingSource).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width:945).background(DesignSystem.workspace).tint(DesignSystem.teal)
        .task {image=SourceImage.render(input,page:1,url:model.source?.guidePreviewURL)}
        .onChange(of:trim) {_,value in if useTrim {settings.explicitTrim=value}}
    }
    private func cellTitle(_ i:Int) -> String {settings.cells[i].product.map {"Ürün \($0) · \(settings.cells[i].side == .front ? "Ön":"Arka")"} ?? "Boş (kullanma)"}
    private func resize(columns:Int,rows:Int) {
        selectedCell=nil;cellMemory=[:]
        var next=PageSplitSettings(columns:columns,rows:rows,size:size);next.cellBleed=settings.cellBleed;next.explicitTrim=settings.explicitTrim;next.assign(settings.matchingPreset ?? .row);settings=next
    }
    private func apply() {
        var preparation=model.project.sourcePreparation ?? SourcePreparationSettings(sourceID:model.preparationSourceID)
        preparation.split=settings;preparation.ignoreSplitSuggestion=true
        Task {do {try await model.applySourcePreparation(preparation);model.showingPageSplit=false} catch {self.error=error.localizedDescription}}
    }
}
private struct SplitCutLine:View {
    @Binding var value:Double
    let scale:Double
    let length:Double
    let vertical:Bool
    let limit:ClosedRange<Double>
    var height:Double = 0
    @State private var origin:Double?
    var body:some View {
        Rectangle().fill(DesignSystem.teal).frame(width:vertical ? 2:length,height:vertical ? length:2)
            .frame(width:vertical ? 14:length,height:vertical ? length:14)
            .contentShape(Rectangle()).offset(x:vertical ? value*scale-7:0,y:vertical ? 0:height-value*scale-7)
            .gesture(DragGesture(minimumDistance:0).onChanged {event in
                if origin==nil {origin=value}
                let delta=(vertical ? event.translation.width:-event.translation.height)/scale
                value=min(limit.upperBound,max(limit.lowerBound,origin!+delta))
            }.onEnded {_ in origin=nil})
    }
}
struct SourceGuidesView:View {
    @ObservedObject var model:Workspace
    let input:PDFSource
    @State private var selected=Set<String>()
    @State private var page=1
    @State private var image:NSImage?
    @State private var error:String?
    @State private var learning=false
    init(model:Workspace,input:PDFSource) {
        self.model=model;self.input=input
        _image=State(initialValue:SourceImage.render(input,page:1,url:model.source?.guidePreviewURL))
    }
    private var hidden:Set<String> {Set(model.project.sourcePreparation?.hiddenGuideGroups ?? [])}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Kılavuz çizgileri").font(.title2.bold())
            if !selected.isEmpty {
                HStack(spacing:12) {
                    Text("\(selected.count) grup seçili").font(.system(size:12))
                    Menu("Grup") {
                        ForEach(input.guides.groups) {group in
                            Button("\(group.role) · \(group.count) çizgi") {selected=[group.id]}
                        }
                    }.help("Çizgi grubunu seç")
                    if model.canSplitSource {
                        Button("Böl") {
                            if let learned=input.guides.learned.first {model.useLearnedSourceTrim(learned)}
                            else {model.showSplitAfterGuides=true;model.showingSourceGuides=false}
                        }
                    }
                    if selected.allSatisfy({id in input.guides.groups.contains{$0.id==id && $0.canHide}}) {
                        Button("Gizle") {apply(hidden.union(selected))}.disabled(model.preparingSource)
                        Button("Göster") {apply(hidden.subtracting(selected))}.disabled(hidden.intersection(selected).isEmpty || model.preparingSource)
                    }
                    Spacer()
                }.controlSize(.small).padding(6).background(DesignSystem.card).accessibilityIdentifier("context.guideSelection")
            }

            Text("Çizgi seç: bir çizgiye tıklayın; ⇧ ile gruba ekleyin. İşaretli kutu = gizli. Gizleme yalnız seçilen ince vektör çizgilerinde doğrulanır.").font(.system(size:12))
            HStack(alignment:.top) {
                VStack {
                    if input.pages.count>1 {Stepper("Sayfa \(page)",value:$page,in:1...input.pages.count)}
                    GeometryReader {g in
                        let size=input.pages[page-1].trimSize,scale=min(g.size.width/size.width,g.size.height/size.height),w=size.width*scale,h=size.height*scale
                        ZStack(alignment:.topLeading) {
                            if let image {Image(nsImage:image).resizable().frame(width:w,height:h)}
                            ForEach(Array(input.guides.strokes.enumerated()),id:\.offset) {_,stroke in
                                if stroke.page==page,selected.contains(stroke.groupID) {
                                    Path {path in for (a,b) in stroke.segments {path.move(to:CGPoint(x:a.x*scale,y:h-a.y*scale));path.addLine(to:CGPoint(x:b.x*scale,y:h-b.y*scale))}}.stroke(Color.orange,lineWidth:3)
                                }
                            }
                        }.frame(width:w,height:h).background(.white).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded {event in
                                if let id=input.guides.hit(page:page,point:Point(event.location.x/scale,(h-event.location.y)/scale),tolerance:max(1,5/scale)) {
                                    if NSEvent.modifierFlags.contains(.shift) {selected.insert(id)} else {selected=[id]}
                                }
                            })
                    }.frame(width:540,height:420)
                }
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        ForEach(input.guides.groups) {group in
                            HStack(alignment:.top) {
                                if group.canHide {
                                    Toggle("Gizle",isOn:Binding(get:{hidden.contains(group.id)},set:{value in var next=hidden;if value {next.insert(group.id)} else {next.remove(group.id)};apply(next)})).labelsHidden().disabled(model.preparingSource)
                                }
                                Rectangle().fill(Color(red:group.color[0],green:group.color[1],blue:group.color[2])).frame(width:18,height:18).border(.gray)
                                Button {selected=[group.id];page=input.guides.strokes.first(where:{$0.groupID==group.id})?.page ?? 1} label: {
                                    VStack(alignment:.leading) {
                                        Text("\(group.count) çizgi · \(TRFormat.dimension(group.width,detail:true)) pt · \(group.role)")
                                        Text(group.layer.isEmpty ? "Katman adı yok":group.layer).font(.system(size:12))
                                        if !group.canHide {Text("Bu grupta güvenli gizleme desteklenmiyor.").font(.system(size:12)).foregroundStyle(DesignSystem.warning)}
                                    }.frame(maxWidth:.infinity,alignment:.leading)
                                }.buttonStyle(.plain)
                            }.padding(6).background(selected.contains(group.id) ? DesignSystem.successSurface:DesignSystem.card,in:RoundedRectangle(cornerRadius:6))
                        }
                    }
                }.frame(width:350,height:420)
            }
            if input.guides.groups.contains(where:{$0.canHide}) {
                HStack {
                    Button("Gizle") {apply(hidden.union(selected))}.disabled(selected.isEmpty || selected.contains(where:{id in !input.guides.groups.contains{$0.id==id && $0.canHide}}) || model.preparingSource)
                    Button("Göster") {apply(hidden.subtracting(selected))}.disabled(selected.isEmpty || hidden.intersection(selected).isEmpty || model.preparingSource)
                }
            }
            if input.guides.groups.contains(where:{!$0.canHide}) {Text(SourcePreparationError.unsafeGuides.localizedDescription).font(.system(size:12)).foregroundStyle(DesignSystem.warning)}
            if !input.guides.learned.isEmpty,model.canSplitSource {
                Button("Kesim ölçüsünü çizgilerden öğren") {learning=true}
                if learning,let learned=input.guides.learned.first {
                    HStack {Text("Öneri: \(TRFormat.size(learned.trim.width,learned.trim.height)) · \(TRFormat.dimension(learned.bleed)) mm taşma").font(.system(size:12))
                        Button("Bölme penceresinde kullan") {model.useLearnedSourceTrim(learned)}
                    }
                }
            }
            if input.guides.unsupported {Text("Bazı iç içe/karmaşık içerikler yalnız okunur veya inceleme sınırı dışında. Listede olmayan çizgiler gizlenmez.").font(.system(size:12)).foregroundStyle(DesignSystem.muted)}
            if let error {Text(error).font(.system(size:12)).foregroundStyle(DesignSystem.error)}
            HStack {if model.preparingSource {ProgressView().controlSize(.small);Text("Çizgi dışındaki pikseller doğrulanıyor…").font(.system(size:12))};Spacer();Button("Kapat") {model.showingSourceGuides=false}.keyboardShortcut(.cancelAction)}
        }.padding(20).background(DesignSystem.workspace).tint(DesignSystem.teal)
        .task(id:"\(page)-\(model.source?.id.uuidString ?? "")") {image=SourceImage.render(input,page:page,url:model.source?.guidePreviewURL)}
    }
    private func apply(_ groups:Set<String>) {
        var settings=model.project.sourcePreparation ?? SourcePreparationSettings(sourceID:model.preparationSourceID)
        settings.hiddenGuideGroups=groups.sorted()
        Task {do {try await model.applySourcePreparation(settings);error=nil} catch {self.error=error.localizedDescription}}
    }
}
