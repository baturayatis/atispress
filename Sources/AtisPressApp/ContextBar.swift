import SwiftUI
import AppKit
import ImpositionCore

/// These bindings use the same Workspace entry points as the inspector. No
/// production value or draft is stored in the context bar.
@MainActor struct ContextBindings {
    let model:Workspace
    func edit(_ change:()->Void) {
        model.beginUndoGroup()
        change()
        model.endUndoGroup()
    }
    var sheet:Binding<String> {
        Binding(get:{model.selectedWorkflowChip},set:{value in edit {model.selectWorkflowSheet(value)}})
    }
    var orientation:Binding<Orientation> {
        Binding(get:{model.workflowOrientation},set:{value in edit {model.selectWorkflowOrientation(value)}})
    }
    var production:Binding<ProductionType> {
        Binding(get:{model.project.autoLayout?.production ?? .digital},set:{value in edit {model.setProduction(value)}})
    }
    var quantity:Binding<Int?> {
        Binding(get:{model.basicQuantity},set:{value in edit {model.basicQuantity=value}})
    }
    var waste:Binding<Double> {
        Binding(get:{model.workflowWastePercent},set:{value in edit {model.workflowWastePercent=value}})
    }
    var bleedEnabled:Binding<Bool> {
        Binding(get:{model.editableGeneratedBleed.enabled},set:{value in edit {
            model.markManual(.generatedEnabled)
            model.editableGeneratedBleed.enabled=value
        }})
    }
    var bleed:Binding<Double> {
        Binding(get:{model.workflowBleed},set:{value in edit {model.markManual(.bleed);model.workflowBleed=value}})
    }
    var crop:Binding<Bool> {
        Binding(get:{model.project.exportMarks.crop},set:{value in edit {model.markManual(.exportCrop);model.project.exportMarks.crop=value}})
    }
    var arrangement:Binding<RepeatArrangement> {
        Binding(get:{model.repeatArrangement},set:{value in edit {model.setRepeatArrangement(value)}})
    }
    var binding:Binding<BindingMethod> {
        Binding(get:{model.project.binding},set:{value in edit {model.setMode(value)}})
    }
    var signature:Binding<SignatureSize> {
        Binding(get:{model.project.settings.signatureSize},set:{value in edit {model.project.settings.signatureSize=value}})
    }
    var cover:Binding<CoverMode> {
        Binding(get:{model.project.coverMode},set:{value in edit {model.setCoverMode(value)}})
    }
    func serial<Value>(_ id:UUID,_ path:WritableKeyPath<SerialField,Value>,fallback:Value) -> Binding<Value> {
        Binding(get:{model.editableSerialFields.first{$0.id==id}?[keyPath:path] ?? fallback},set:{value in
            edit {
                guard let index=model.editableSerialFields.firstIndex(where:{$0.id==id}) else {return}
                model.editableSerialFields[index][keyPath:path]=value
            }
        })
    }
}

enum ContextKind:Equatable {case flat,book,serial,job,split,guides}
enum ContextControl:String,Identifiable {
    case sheet,orientation,production,quantity,bleed,crop,arrangement,binding,signature,cover
    case field,kind,font,size,color,x,y,rotation,center,waste,dimensions,split,guides
    var id:String {rawValue}
    var title:String {
        switch self {
        case .sheet:return "Tabaka"
        case .orientation:return "Yön"
        case .production:return "Üretim"
        case .quantity:return "Adet"
        case .bleed:return "Taşma payı"
        case .crop:return "Kesim işaretleri"
        case .arrangement:return "Dizilim"
        case .binding:return "Cilt yöntemi"
        case .signature:return "Forma"
        case .cover:return "Kapak modu"
        case .field:return "Alan seçici"
        case .kind:return "Tür"
        case .font:return "Yazı tipi"
        case .size:return "Boyut"
        case .color:return "Renk"
        case .x:return "X (mm)"
        case .y:return "Y (mm)"
        case .rotation:return "Dönüş (°)"
        case .center:return "Ortala"
        case .waste:return "Fire (%)"
        case .dimensions:return "Ebat"
        case .split:return "Böl"
        case .guides:return "Gizle/Göster"
        }
    }
    var width:CGFloat {
        switch self {
        case .sheet:return 116
        case .orientation:return 130
        case .production:return 114
        case .bleed:return 132
        case .crop:return 108
        case .arrangement:return 132
        case .binding:return 132
        case .signature:return 96
        case .cover:return 108
        case .font:return 140
        case .field:return 126
        case .kind:return 96
        case .dimensions:return 150
        case .color,.center,.split,.guides:return 82
        default:return 82
        }
    }
}
enum ContextPresentation {
    @MainActor static func kind(_ model:Workspace) -> ContextKind {
        if model.showingPageSplit {return .split}
        if model.showingSourceGuides {return .guides}
        if model.editableSerialFields.contains(where:{$0.id==model.selectedSerialID}) {return .serial}
        if model.project.binding == .gang && model.selectedGangJobID != nil || !model.selectedPages.isEmpty {return .job}
        return model.project.isBooklet || model.project.isLeafBinding ? .book : .flat
    }
    static func controls(_ kind:ContextKind) -> [ContextControl] {
        switch kind {
        case .flat:return [.sheet,.orientation,.production,.quantity,.bleed,.crop,.arrangement]
        case .book:return [.binding,.signature,.cover,.sheet,.orientation,.production,.bleed]
        case .serial:return [.field,.kind,.font,.size,.color,.x,.y,.rotation,.center]
        case .job:return [.quantity,.waste,.dimensions]
        case .split:return [.split]
        case .guides:return [.guides]
        }
    }
    struct Layout:Equatable {
        var visible:[ContextControl]
        var overflow:[ContextControl]
    }
    static func layout(_ controls:[ContextControl],width:CGFloat) -> Layout {
        let limit=min(8,controls.count)
        let total=controls.prefix(limit).reduce(CGFloat(0)) {$0+$1.width+8}
        let hasOverflow=controls.count>limit || total>width-16
        let budget=max(0,width-16-(hasOverflow ? 44:0))
        var used:CGFloat=0,count=0
        for control in controls.prefix(8) {
            guard used+control.width+8<=budget else {break}
            used+=control.width+8;count+=1
        }
        return Layout(visible:Array(controls.prefix(count)),overflow:Array(controls.dropFirst(count)))
    }
}

struct ContextBar:View {
    @ObservedObject var model:Workspace
    @State private var overflow=false
    @State private var customSheet=false
    private var values:ContextBindings {ContextBindings(model:model)}
    private var controls:[ContextControl] {
        var result=ContextPresentation.controls(ContextPresentation.kind(model))
        if ContextPresentation.kind(model) == .book && model.project.isLeafBinding {result.removeAll{$0 == .signature}}
        if let selected=model.editableSerialFields.first(where:{$0.id==model.selectedSerialID}),selected.kind != .text,!selected.codeSettings.humanReadable {result.removeAll{$0 == .font}}
        return result
    }
    var body:some View {
        GeometryReader { geometry in
            let layout=ContextPresentation.layout(controls,width:geometry.size.width)
            HStack(spacing:8) {
                ForEach(layout.visible) {control in field(control).frame(width:control.width)}
                Spacer(minLength:0)
                if !layout.overflow.isEmpty {
                    Button("…") {overflow.toggle()}.frame(width:32).help("Diğer bağlam ayarları")
                        .accessibilityLabel("Diğer bağlam ayarları")
                        .popover(isPresented:$overflow) {
                            VStack(alignment:.leading,spacing:12) {
                                ForEach(layout.overflow) {control in field(control).frame(width:max(control.width,230))}
                            }.padding(16)
                        }
                }
            }.padding(.horizontal,8).frame(height:36)
        }.frame(height:36).background(DesignSystem.card)
            .disabled(model.loading || model.preparingSource || model.exporting || model.autoArranging)
            .controlSize(.small)
            .onChange(of:ContextPresentation.kind(model)) {_,_ in overflow=false}
    }
    private func field(_ control:ContextControl) -> some View {
        VStack(alignment:.leading,spacing:1) {
            Text(control.title).font(.system(size:9)).foregroundStyle(DesignSystem.muted)
            editor(control).frame(maxWidth:.infinity,alignment:.leading)
        }.help(control.title).accessibilityElement(children:.contain)
            .accessibilityIdentifier("context."+control.rawValue)
    }
    @ViewBuilder private func editor(_ control:ContextControl) -> some View {
        switch control {
        case .sheet:
            Picker("Tabaka",selection:Binding(get:{values.sheet.wrappedValue},set:{value in
                values.sheet.wrappedValue=value
                if value=="Özel ölçü…" {customSheet=true}
            })) {ForEach(WorkflowPresentation.sheetChips,id:\.self) {Text($0).tag($0)}}.labelsHidden()
                .popover(isPresented:$customSheet) {
                    VStack {
                        DimensionInput("Genişlik",value:sheetDimension(\.width),range:20...3000)
                        DimensionInput("Yükseklik",value:sheetDimension(\.height),range:20...3000)
                    }.padding().frame(width:280)
                }
        case .orientation:
            Picker("Yön",selection:values.orientation) {
                Image(systemName:"arrow.triangle.2.circlepath").tag(Orientation.auto).help("Otomatik")
                Image(systemName:"rectangle.portrait").tag(Orientation.portrait).help("Dikey")
                Image(systemName:"rectangle").tag(Orientation.landscape).help("Yatay")
            }.labelsHidden().pickerStyle(.segmented).accessibilityLabel("Yön, otomatik, dikey veya yatay")
        case .production:
            Picker("Üretim",selection:values.production) {Text("Dijital").tag(ProductionType.digital);Text("Ofset").tag(ProductionType.offset)}.labelsHidden().pickerStyle(.segmented)
        case .quantity:
            HStack(spacing:2) {TextField("Girilmedi",value:values.quantity,format:.number.locale(TRFormat.locale));Text("adet").font(.system(size:9))}.textFieldStyle(.roundedBorder).accessibilityLabel("Adet")
        case .bleed:
            HStack(spacing:3) {
                Toggle("Eksik taşmayı üret",isOn:values.bleedEnabled).labelsHidden().toggleStyle(.switch)
                TextField("Taşma payı",value:values.bleed,format:.number.locale(TRFormat.locale)).frame(minWidth:34).textFieldStyle(.roundedBorder).disabled(!values.bleedEnabled.wrappedValue)
                Text("mm").font(.system(size:9))
            }
        case .crop:Toggle("Çıktıya basılır",isOn:values.crop).toggleStyle(.checkbox).font(.system(size:10)).help("Kesim işaretleri (çıktıya basılır)")
        case .arrangement:
            Picker("Dizilim",selection:values.arrangement) {
                Text("Bitişik").tag(RepeatArrangement.adjacent);Text("Aralıklı").tag(RepeatArrangement.spaced)
                if model.repeatArrangement == .custom {Text("Özel").tag(RepeatArrangement.custom)}
            }.labelsHidden().pickerStyle(.segmented)
        case .binding:
            Picker("Cilt yöntemi",selection:values.binding) {
                Text("Tel dikiş").tag(BindingMethod.saddleStitch);Text("Tutkallı cilt").tag(BindingMethod.perfectBound)
                Text("Dikişli cilt").tag(BindingMethod.sewn);Text("Spiral").tag(BindingMethod.spiral);Text("Wire-O").tag(BindingMethod.wireO)
            }.labelsHidden()
        case .signature:
            Picker("Forma",selection:values.signature) {
                Text("Otomatik").tag(SignatureSize.automatic);Text("4 sayfa").tag(SignatureSize.four);Text("8 sayfa").tag(SignatureSize.eight)
                Text("16 sayfa").tag(SignatureSize.sixteen);Text("32 sayfa").tag(SignatureSize.thirtyTwo)
            }.labelsHidden()
        case .cover:
            Picker("Kapak modu",selection:values.cover) {Text("Dahil").tag(CoverMode.included);Text("Ayrı bas").tag(CoverMode.excluded);Text("Ayrı PDF").tag(CoverMode.separate)}.labelsHidden()
        case .waste:TextField("Fire (%)",value:values.waste,format:.number.locale(TRFormat.locale)).textFieldStyle(.roundedBorder)
        case .dimensions:
            Button("Ebadı değiştir…") {model.openScaleWindow()}.disabled(model.scalingRows.isEmpty)
        case .field:
            Picker("Alan seçici",selection:$model.selectedSerialID) {
                ForEach(Array(model.editableSerialFields.enumerated()),id:\.element.id) {index,field in Text("Alan \(index+1) · \(field.kind == .text ? "Metin" : field.kind == .qr ? "QR" : "Barkod")").tag(Optional(field.id))}
            }.labelsHidden()
        case .kind,.font,.size,.color,.x,.y,.rotation,.center:
            if let field=model.editableSerialFields.first(where:{$0.id==model.selectedSerialID}) {serialEditor(control,field:field)}
        case .split:Button("Sayfayı böl…") {model.showingPageSplit=true}.disabled(!model.canSplitSource)
        case .guides:Button("Kılavuz çizgileri…") {model.showingSourceGuides=true}.disabled(model.preparationInput==nil)
        }
    }
    private func sheetDimension(_ path:WritableKeyPath<Size,Double>) -> Binding<Double> {
        Binding(get:{model.project.sheet.size[keyPath:path]},set:{value in values.edit {
            model.markManual(.sheetSize)
            model.project.sheet.size[keyPath:path]=min(3000,max(20,value))
        }})
    }
    @ViewBuilder private func serialEditor(_ control:ContextControl,field:SerialField) -> some View {
        switch control {
        case .kind:
            Picker("Tür",selection:Binding(get:{model.serialKindBinding(field.id).wrappedValue},set:{value in values.edit {model.serialKindBinding(field.id).wrappedValue=value}})) {
                Text("Metin").tag(SerialCodeSettings.Kind.text);Text("QR kod").tag(SerialCodeSettings.Kind.qr);Text("Barkod").tag(SerialCodeSettings.Kind.code128)
            }.labelsHidden()
        case .font:
            Picker("Yazı tipi",selection:values.serial(field.id,\.font,fallback:field.font)) {
                ForEach(Array(Set(["Helvetica","Helvetica-Bold","Menlo-Regular","Times-Roman","Courier",field.font])).sorted(),id:\.self) {Text($0).tag($0)}
            }.labelsHidden()
        case .size:
            if field.kind == .text {number("Boyut (pt)",values.serial(field.id,\.size,fallback:field.size),unit:"pt")}
            else {number("Boyut (mm)",values.serial(field.id,\.codeSettings.width,fallback:field.codeSettings.width),unit:"mm")}
        case .x:number("X (mm)",values.serial(field.id,\.position.x,fallback:field.position.x),unit:"mm")
        case .y:number("Y (mm)",values.serial(field.id,\.position.y,fallback:field.position.y),unit:"mm")
        case .rotation:number("Dönüş (°)",values.serial(field.id,\.rotation,fallback:field.rotation),unit:"°")
        case .center:Button("Ortala") {model.placeSerial(field.id,corner:nil)}.disabled(model.currentSheet==nil)
        case .color:
            ColorPicker("Renk",selection:serialColor(field),supportsOpacity:false).labelsHidden().accessibilityLabel("Alan rengi")
        default:EmptyView()
        }
    }
    private func number(_ title:String,_ value:Binding<Double>,unit:String) -> some View {
        HStack(spacing:2) {TextField(title,value:value,format:.number.locale(TRFormat.locale)).textFieldStyle(.roundedBorder);Text(unit).font(.system(size:9))}
    }
    private func serialColor(_ field:SerialField) -> Binding<Color> {
        let binding=values.serial(field.id,\.color,fallback:field.color)
        return Binding(get:{
            let c=binding.wrappedValue.components
            let color=c.count==4 ? NSColor(deviceCyan:c[0],magenta:c[1],yellow:c[2],black:c[3],alpha:1) : NSColor(srgbRed:c[0],green:c[1],blue:c[2],alpha:1)
            return Color(nsColor:color)
        },set:{color in
            let ns=NSColor(color)
            if binding.wrappedValue.components.count==4 || field.kind != .text,let c=ns.usingColorSpace(.deviceCMYK) {
                binding.wrappedValue = .cmyk(c.cyanComponent,c.magentaComponent,c.yellowComponent,c.blackComponent)
            } else if let c=ns.usingColorSpace(.sRGB) {binding.wrappedValue = .rgb(c.redComponent,c.greenComponent,c.blueComponent)}
        })
    }
}
