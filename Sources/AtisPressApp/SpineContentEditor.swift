import SwiftUI
import ImpositionCore
import PDFEngine

struct SpineContentEditor: View {
    @ObservedObject var model: Workspace
    private var trim: CGRect? {
        for sheet in model.plan.sheets {
            if let slot = (sheet.front.slots+sheet.back.slots).first(where: { $0.bookRegion == "Sırt" }) {
                return PDFPreviewDrawing.localTrim(slot)
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            Picker("Sırt içeriği",selection:$model.spineContent.mode) {
                Text("Boş").tag(SpineContent.Mode.empty)
                Text("Renk").tag(SpineContent.Mode.color)
                Text("Yazı").tag(SpineContent.Mode.text)
            }.pickerStyle(.segmented).accessibilityIdentifier("spineContent")
            switch model.spineContent.mode {
            case .empty: EmptyView()
            case .color:
                Toggle("Kapak kenarından uzat",isOn:$model.spineContent.extendEdges)
                if !model.spineContent.extendEdges { SpineCMYKPicker(color:$model.spineContent.color) }
            case .text:
                SpineTextBlocksEditor(trim:trim,blocks:$model.spineContent.blocks)
            }
            Toggle("Sırt kenarlarına katlama işareti",isOn:$model.spineContent.foldMarks)
        }
    }

}

struct SpineTextBlocksEditor: View {
    let trim: CGRect?
    @Binding var blocks: [SpineContent.Position:SpineContent.TextBlock]

    var body: some View {
        ForEach(SpineContent.Position.allCases,id:\.self) { position in
            SpineBlockEditor(title:title(position),position:position,trim:trim,block:Binding(
                get:{ blocks[position] ?? SpineContent.TextBlock() },
                set:{ blocks[position] = $0 }))
        }
    }

    private func title(_ position: SpineContent.Position) -> String {
        switch position {
        case .top: return "Üst"
        case .middle: return "Orta"
        case .bottom: return "Alt"
        }
    }
}

private struct SpineBlockEditor: View {
    let title: String
    let position: SpineContent.Position
    let trim: CGRect?
    @Binding var block: SpineContent.TextBlock
    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment:.leading,spacing:7) {
                SpineTypefaceEditor(block:$block)
                Toggle("Sırta sığdır",isOn:$block.autoFit)
                if !block.autoFit { measure("Boyut",$block.size,unit:"pt",range:0.01...1000) }
                Picker("Hizalama",selection:$block.alignment) {
                    Text("Başlangıç").tag(SpineContent.Alignment.start)
                    Text("Orta").tag(SpineContent.Alignment.center)
                    Text("Bitiş").tag(SpineContent.Alignment.end)
                }
                measure("X",$block.x,range:-10_000...10_000)
                measure("Y",$block.y,range:-10_000...10_000)
                if let trim, let warning = PDFSpine.warning(block,at:position,in:trim) {
                    Text(warning).foregroundStyle(DesignSystem.warning)
                    if PDFSpine.layout(block,at:position,in:trim) != nil {
                        Button("Sığdır") {
                            var fitted = block
                            fitted.x = 0; fitted.y = 0; fitted.autoFit = true
                            block = fitted
                        }
                    }
                }
            }.padding(.top,5)
        }
    }

    private func measure(_ title: String,_ value: Binding<Double>,unit: String = "mm",range: ClosedRange<Double>) -> some View {
        HStack { Text(title); Spacer(); DimensionInput(title,value:value,unit:unit,range:range) }
    }
}

struct SpineTypefaceEditor: View {
    @Binding var block: SpineContent.TextBlock
    @State private var showFonts = false
    @State private var query = ""
    private static let fonts = NSFontManager.shared.availableFonts.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }

    var body: some View {
        VStack(alignment:.leading,spacing:7) {
                TextField("Sırt yazısı",text:$block.text)
                Button("Yazı tipi: "+block.font) { query = ""; showFonts = true }
                    .popover(isPresented:$showFonts) {
                        VStack {
                            TextField("Yazı tipi ara",text:$query).textFieldStyle(.roundedBorder)
                            List(Self.fonts.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) },id:\.self) { font in
                                Button(font) { block.font = font; showFonts = false }.buttonStyle(.plain)
                            }
                        }.padding(12).frame(width:300,height:300)
                    }
                HStack { Toggle("Kalın",isOn:$block.bold); Toggle("İtalik",isOn:$block.italic) }
                Picker("Okuma yönü",selection:$block.bottomUp) {
                    Text("Yukarıdan aşağı").tag(false)
                    Text("Aşağıdan yukarı").tag(true)
                }
                SpineCMYKPicker(color:$block.color)
                Toggle("Yazıyı eğriye çevir",isOn:$block.outlines)
        }
    }
}

struct SpineCMYKPicker: View {
    @Binding var color: BleedColor
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Label("CMYK",systemImage:"circle.fill")
                .foregroundStyle(Color(cgColor:PDFSpine.color(color)))
        }.accessibilityLabel("CMYK renk seç")
            .popover(isPresented:$show) {
                VStack {
                    ForEach(Array(["C","M","Y","K"].enumerated()),id:\.offset) { index, name in
                        HStack {
                            Text(name); Spacer()
                            DimensionInput(name,value:Binding(get:{ (color.components.count == 4 ? color.components[index] : 0)*100 },set:{ value in
                                var channels = color.components.count == 4 ? color.components : [0,0,0,0]
                                channels[index] = min(100,max(0,value))/100
                                color = .cmyk(channels[0],channels[1],channels[2],channels[3])
                            }),unit:"%",range:0...100)
                        }
                    }
                }.padding(12)
            }
    }
}
