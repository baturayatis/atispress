import SwiftUI
import UniformTypeIdentifiers
import ImpositionCore
import PDFEngine

extension Workspace {
    func movePreparedSpine(_ position: SpineContent.Position?, to point: Point) {
        var settings = coverPreparation
        if let position, var block = settings.spineText?[position] {
            block.x = point.x.rounded(); block.y = point.y.rounded()
            settings.spineText?[position] = block
        } else if position == nil, var logo = settings.spineLogo {
            logo.x = point.x.rounded(); logo.y = point.y.rounded()
            settings.spineLogo = logo
        } else { return }
        coverPreparation = settings
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
        DisclosureGroup("Sırt içeriği") {
            VStack(alignment:.leading,spacing:8) {
                SpineTextBlocksEditor(trim:trim,blocks:Binding(
                    get:{ model.coverPreparation.spineText ?? [:] },
                    set:{ model.coverPreparation.spineText = $0 }))
                Divider()
                if let logo = model.coverPreparation.spineLogo {
                    Text(logo.name).lineLimit(1)
                    if logo.format == .convertedSVG {
                        Text("SVG bu sistemde piksele çevrildi. Vektör çıktı için PDF logo kullanın.")
                            .foregroundStyle(DesignSystem.warning)
                    }
                    HStack {
                        Button("Logoyu değiştir…") { importing = true }
                        Button("Kaldır") { model.coverPreparation.spineLogo = nil }
                    }
                    measurement("Logo genişliği",logoValue(\.width,logo.width),range:0.001...10_000)
                    measurement("Dönüş",logoValue(\.rotation,logo.rotation),unit:"°",range:-360...360)
                    measurement("X",logoValue(\.x,logo.x))
                    measurement("Y",logoValue(\.y,logo.y))
                    if let warning = PDFSpine.logoWarning(logo,in:trim) {
                        Text(warning).foregroundStyle(DesignSystem.warning)
                    }
                } else {
                    Button("Logo ekle…") { importing = true }
                }
            }.padding(.top,6)
        }.accessibilityIdentifier("preparedSpineContent")
            .fileImporter(isPresented:$importing,allowedContentTypes:[.png,.svg,.pdf]) { result in
                do { try importLogo(result.get()) }
                catch { model.error = error.localizedDescription }
            }
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

    private func logoValue(_ key: WritableKeyPath<SpineLogo,Double>,_ fallback: Double) -> Binding<Double> {
        Binding(get:{ model.coverPreparation.spineLogo?[keyPath:key] ?? fallback },
                set:{ model.coverPreparation.spineLogo?[keyPath:key] = $0 })
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
            model.coverPreparation.spineLogo = logo
            return
        default: throw LogoImportError.unsupported
        }
        guard let logo = PDFSpine.makeLogo(name:url.lastPathComponent,format:format,data:data,in:trim) else {
            throw LogoImportError.unsupported
        }
        model.coverPreparation.spineLogo = logo
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
