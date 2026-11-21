import SwiftUI
import UniformTypeIdentifiers
import ImpositionCore
import PDFEngine

extension Workspace {
    var preparedSpineObjects: [FreeSpineObject] {
        get { coverPreparation.resolvedSpineObjects }
        set {
            var settings = coverPreparation
            settings.spineObjects = newValue
            settings.spineText = nil; settings.spineLogo = nil
            coverPreparation = settings
        }
    }

    func editPreparedSpine(_ object: FreeSpineObject) {
        guard let index = preparedSpineObjects.firstIndex(where:{ $0.id == object.id }) else { return }
        preparedSpineObjects[index] = object
    }

    func deletePreparedSpine(_ id: UUID) {
        guard preparedSpineObjects.contains(where:{ $0.id == id }) else { return }
        beginUndoGroup()
        preparedSpineObjects.removeAll { $0.id == id }
        if selectedPreparedSpineID == id { selectedPreparedSpineID = nil }
        endUndoGroup()
    }

    func addPreparedSpine(_ object: FreeSpineObject) {
        guard preparedSpineObjects.count < CoverPreparationSettings.spineObjectLimit else {
            error = "Sırta en fazla 128 nesne eklenebilir."
            return
        }
        let byteCount = (preparedSpineObjects+[object]).reduce(0) { count,item in
            if case .logo(let logo) = item.content { return count+logo.data.count }
            return count
        }
        guard byteCount <= CoverPreparationSettings.spineAssetByteLimit else {
            error = "Sırttaki logoların toplam boyutu en fazla 64 MB olabilir."
            return
        }
        beginUndoGroup()
        preparedSpineObjects.append(object)
        selectedPreparedSpineID = object.id
        endUndoGroup()
        coverPreviewOutput = .spread
    }
}

struct PreparedSpineEditor: View {
    @ObservedObject var model: Workspace
    let trim: CGRect
    @State private var importing = false

    var body: some View {
        Picker("Sırt zemini",selection:$model.coverPreparation.colorMode) {
            Text("Otomatik").tag(CoverPreparationSettings.SpineColorMode.automatic)
            Text("Renk seç").tag(CoverPreparationSettings.SpineColorMode.picked)
            Text("CMYK").tag(CoverPreparationSettings.SpineColorMode.manual)
        }.inspectorTarget("preparedSpineBackground")
        switch model.coverPreparation.colorMode {
        case .automatic: EmptyView()
        case .picked: ColorPicker("Renk seç",selection:pickedColor,supportsOpacity:false)
        case .manual: SpineCMYKPicker(color:$model.coverPreparation.color)
        }
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Button("+ Yazı ekle") {
                    var text = SpineContent.TextBlock()
                    text.text = "Sırt yazısı"
                    text.autoFit = true
                    var object = PDFSpine.freePlacement(FreeSpineObject(content:.text(text)),in:trim)
                    object.size = min(object.size,24)
                    model.addPreparedSpine(object)
                }
                Button("+ Logo ekle") { importing = true }
            }
            if !model.preparedSpineObjects.isEmpty &&
                (model.preparedSpineObjects.count > 1 ||
                 !model.preparedSpineObjects.contains(where:{ $0.id == model.selectedPreparedSpineID })) {
                Picker("Nesne",selection:$model.selectedPreparedSpineID) {
                    Text("Seçili nesne yok").tag(nil as UUID?)
                    ForEach(model.preparedSpineObjects) { object in
                        Text(title(object)).lineLimit(1).tag(Optional(object.id))
                    }
                }
            }
            if let object = model.preparedSpineObjects.first(where:{ $0.id == model.selectedPreparedSpineID }) {
                selectedEditor(object)
            }
        }.accessibilityIdentifier("preparedSpineContent")
            .fileImporter(isPresented:$importing,allowedContentTypes:[.png,.svg,.pdf]) { result in
                do { try importLogo(result.get()) }
                catch { model.error = error.localizedDescription }
            }
    }

    private func title(_ object: FreeSpineObject) -> String {
        switch object.content {
        case .text(let text): return text.text.isEmpty ? "Boş yazı" : String(text.text.prefix(40))
        case .logo(let logo): return logo.name
        }
    }

    @ViewBuilder private func selectedEditor(_ object: FreeSpineObject) -> some View {
        let placed = PDFSpine.freePlacement(object,in:trim)
        switch object.content {
        case .text(let text):
            SpineTypefaceEditor(block:Binding(get:{
                if let current = model.preparedSpineObjects.first(where:{ $0.id == object.id }),
                   case .text(let value) = current.content { return value }
                return text
            },set:{ value in
                if var current = model.preparedSpineObjects.first(where:{ $0.id == object.id }) {
                    current.content = .text(value)
                    model.editPreparedSpine(current)
                }
            }))
            measurement("Yazı boyutu",objectValue(placed,\.size),unit:"pt",range:object.sizeRange)
        case .logo(let logo):
            Text(logo.name).lineLimit(1)
            if logo.format == .convertedSVG {
                Text("SVG piksele çevrildi. Vektör çıktı için PDF logo kullanın.").foregroundStyle(DesignSystem.warning)
            }
            measurement("Logo genişliği",objectValue(placed,\.size),range:object.sizeRange)
        }
        DisclosureGroup("Konum ve dönüş") {
            measurement("X",objectValue(placed,\.x))
            measurement("Y",objectValue(placed,\.y))
            measurement("Dönüş",objectValue(placed,\.rotation),unit:"°",range:-360...360)
        }
        if let warning = PDFSpine.objectWarning(object,in:trim) {
            Text(warning).foregroundStyle(DesignSystem.warning)
        }
        Button("Seçileni sil") { model.deletePreparedSpine(object.id) }
            .help("Önizlemede ⌫ ile de silebilirsiniz. Sürüklemede konum 1 mm’ye yuvarlanır.")
    }

    private var pickedColor: Binding<Color> {
        Binding(get:{
            let components = model.coverPreparation.pickedColor?.components ?? [0,0,0]
            guard components.count == 3 else { return .black }
            return Color(.sRGB,red:components[0],green:components[1],blue:components[2])
        },set:{ color in
            if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                func channel(_ value: CGFloat) -> Double { min(1,max(0,Double(value))) }
                model.coverPreparation.pickedColor = .rgb(channel(rgb.redComponent),channel(rgb.greenComponent),channel(rgb.blueComponent))
            }
        })
    }

    private func objectValue(_ object: FreeSpineObject,_ key: WritableKeyPath<FreeSpineObject,Double>) -> Binding<Double> {
        Binding(get:{
            guard let current = model.preparedSpineObjects.first(where:{ $0.id == object.id }) else { return object[keyPath:key] }
            return PDFSpine.freePlacement(current,in:trim)[keyPath:key]
        },set:{ value in
            if let current = model.preparedSpineObjects.first(where:{ $0.id == object.id }) {
                var next = PDFSpine.freePlacement(current,in:trim)
                next[keyPath:key] = value
                model.editPreparedSpine(next)
            }
        })
    }

    private func measurement(_ name: String,_ value: Binding<Double>,unit: String = "mm",
                             range: ClosedRange<Double> = -10_000...10_000) -> some View {
        HStack { Text(name); Spacer(); DimensionInput(name,value:value,unit:unit,range:range) }
    }

    private func importLogo(_ url: URL) throws {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf:url,options:.mappedIfSafe)
        guard data.count <= 16*1024*1024 else { throw LogoImportError.tooLarge }
        let format: SpineLogo.Format
        switch url.pathExtension.lowercased() {
        case "pdf": format = .pdf
        case "png": format = .png
        case "svg":
            guard let logo = PDFSpine.importSVGLogo(name:url.lastPathComponent,data:data,in:trim) else { throw LogoImportError.svg }
            model.addPreparedSpine(FreeSpineObject(content:.logo(logo)))
            return
        default: throw LogoImportError.unsupported
        }
        guard let logo = PDFSpine.makeLogo(name:url.lastPathComponent,format:format,data:data,in:trim) else {
            throw LogoImportError.unsupported
        }
        model.addPreparedSpine(FreeSpineObject(content:.logo(logo)))
    }
}

private enum LogoImportError: LocalizedError {
    case tooLarge, unsupported, svg

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Logo dosyası en fazla 16 MB olabilir."
        case .unsupported: return "Logo okunamadı. PNG veya kopyalamaya açık, tek sayfalı PDF kullanın."
        case .svg: return "SVG bu sistemde açılamadı. Logoyu PNG veya vektör PDF olarak kaydedip yeniden ekleyin."
        }
    }
}
