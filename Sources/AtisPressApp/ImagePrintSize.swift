import SwiftUI
import PDFEngine

@MainActor
final class ImagePrintSize: ObservableObject {
    enum Field: CaseIterable {
        case width, height, dpi
        var label: String {
            switch self {
            case .width: return "Genişlik (mm)"
            case .height: return "Yükseklik (mm)"
            case .dpi: return "Etkin DPI"
            }
        }
    }

    let info: ImageImportInfo
    @Published private(set) var settings: ImagePrintSettings
    @Published private var activeField: Field?
    @Published private var input = ""
    @Published private var rejectedEdit = false

    init(_ info: ImageImportInfo) {
        self.info = info
        settings = info.defaultSettings
    }

    var isValid: Bool { !rejectedEdit && settings.isValid }
    var dpi: Double { info.effectiveDPI(settings) }

    func text(_ field: Field) -> Binding<String> {
        Binding(get: {
            if self.activeField == field { return self.input }
            let value: Double
            switch field {
            case .width: value = self.settings.widthMM
            case .height: value = self.settings.heightMM
            case .dpi: value = self.dpi
            }
            return TRFormat.dimension(value, detail: true)
        }, set: { self.edit(field, text: $0) })
    }

    var locked: Binding<Bool> {
        Binding(get: { self.settings.lockAspectRatio }, set: { self.settings.lockAspectRatio = $0 })
    }

    private func number(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    private func edit(_ field: Field, text: String) {
        activeField = field
        input = text
        guard let value = number(text) else { rejectedEdit = true; return }
        var next = settings
        let original = info.defaultSettings
        switch field {
        case .width:
            next.widthMM = value
            if next.lockAspectRatio { next.heightMM = value * (original.heightMM / original.widthMM) }
        case .height:
            next.heightMM = value
            if next.lockAspectRatio { next.widthMM = value * (original.widthMM / original.heightMM) }
        case .dpi:
            let factor = dpi / value
            next.widthMM *= factor
            next.heightMM *= factor
        }
        rejectedEdit = !next.isValid
        if !rejectedEdit { settings = next }
    }
}

private struct ImagePrintSizeFields: View {
    @ObservedObject var size: ImagePrintSize
    var validityChanged: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(size.info.pixelWidth) × \(size.info.pixelHeight) piksel")
            Grid(alignment: .leading) {
                ForEach(ImagePrintSize.Field.allCases, id: \.self) { field in
                    GridRow {
                        Text(field.label)
                        TextField(field.label, text: size.text(field)).labelsHidden().frame(width: 100)
                    }
                }
            }
            Toggle("En boy oranını koru", isOn: size.locked)
            Text(!size.isValid ? "Geçerli bir baskı ölçüsü girin." :
                size.dpi < 150 ? "Etkin çözünürlük 150 DPI’ın altında." : " ")
                .foregroundStyle(.orange)
        }.padding(8).frame(width: 275, alignment: .leading)
            .onChange(of: size.isValid, initial: true) { _, valid in validityChanged(valid) }
    }
}

extension Workspace {
    func openImageSource(_ url: URL, settings: ImagePrintSettings?, configure: Bool) async throws -> PDFSource {
        let selected: ImagePrintSettings
        if let settings {
            selected = settings
        } else {
            let info = try await ImageImport.inspect(url)
            if configure {
                try Task.checkCancellation()
                let size = ImagePrintSize(info)
                let alert = NSAlert()
                alert.messageText = "Görsel baskı ölçüsü"
                alert.informativeText = url.lastPathComponent
                let add = alert.addButton(withTitle: "Ekle")
                alert.addButton(withTitle: "Vazgeç")
                let fields = ImagePrintSizeFields(size: size) { [weak add] valid in add?.isEnabled = valid }
                let view = NSHostingView(rootView: fields)
                view.frame = CGRect(origin: .zero, size: view.fittingSize)
                alert.accessoryView = view
                guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
                guard size.isValid else { throw ImageImportError.invalidSize }
                selected = size.settings
            } else {
                selected = info.defaultSettings
            }
        }
        let (source, warnings) = try await PDFSource.openImage(url, settings: selected)
        if configure, !warnings.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = url.lastPathComponent
            alert.informativeText = warnings.joined(separator: "\n")
            alert.addButton(withTitle: "Ekle")
            alert.addButton(withTitle: "Vazgeç")
            guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
        }
        return source
    }
}
