import SwiftUI
import AppKit
import ImpositionCore
import PDFEngine

struct ArtworkSeparationView: View {
    @ObservedObject var model: Workspace
    let input: PDFSource
    @State private var draft: ArtworkSeparation
    @State private var selection: UUID?
    @State private var drawing = false
    @State private var rubberBand: Rect?
    @State private var confirmed = false
    @State private var error: String?
    @State private var image: NSImage?

    init(model: Workspace, input: PDFSource) {
        self.model = model
        self.input = input
        var draft = model.project.sourcePreparation?.separation ?? ArtworkSeparation()
        if model.project.sourcePreparation?.separation == nil {
            draft.regions = input.guides.artworkCandidates(size: input.pages[0].trimSize)
        }
        _draft = State(initialValue: draft)
        _selection = State(initialValue: draft.regions.first?.id)
    }

    private var size: Size { input.pages[0].trimSize }
    private var selectedIndex: Int? { draft.regions.firstIndex { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Akıllı İş Ayırma").font(.title2.bold())
            Text("Kutular öneridir. Baskı sınırlarını ve ön/arka yüzleri gözden geçirip onaylayın.")
            HStack(alignment: .top, spacing: 16) {
                VStack {
                    artboard.frame(width: 560, height: 425)
                    HStack {
                        Toggle("Bölge çiz", isOn: $drawing).toggleStyle(.button)
                        Button("Bölge ekle") { add(Rect(x: size.width / 4, y: size.height / 4, width: size.width / 2, height: size.height / 2)) }
                        Button("Bölgeyi sil") { removeSelected() }.disabled(selectedIndex == nil)
                    }.disabled(model.preparingSource)
                }
                VStack(alignment: .leading, spacing: 9) {
                    List(selection: $selection) {
                        ForEach(Array(draft.regions.enumerated()), id: \.element.id) { index, region in
                            Text("Bölge \(index + 1) · \(assignmentLabel(region.assignment))").tag(region.id)
                        }
                    }.frame(height: 140)
                    if let index = selectedIndex {
                        ScrollView { editor($draft.regions[index]).id(draft.regions[index].id) }
                    } else {
                        Text("Elle eklemek için çalışma alanında bir kutu çizin.").foregroundStyle(.secondary)
                        Spacer()
                    }
                }.frame(width: 300, height: 460)
            }.disabled(model.preparingSource)
            HStack {
                Picker("Üretim", selection: $draft.asTeam) {
                    Text("Ayrı işler").tag(false)
                    Text("Tam takım").tag(true)
                }.pickerStyle(.segmented).frame(width: 350)
                Spacer()
                Text("\(draft.regions.count) bölge").foregroundStyle(.secondary)
            }.disabled(model.preparingSource)
            if model.project.hasRescaling {
                Text("Ayırma kaynak ölçülerini kullanır ve mevcut hedef ebat ölçeklemesini kaldırır.").foregroundStyle(DesignSystem.warning)
            }
            Toggle("Bölge sınırlarını, taşmayı ve yüz eşlemelerini kontrol ettim", isOn: $confirmed)
                .disabled(model.preparingSource)
            if let message = error ?? draft.validation(size: size) {
                Text(message).foregroundStyle(DesignSystem.error).font(.callout)
            }
            HStack {
                Spacer()
                Button("Vazgeç") { model.showingArtworkSeparation = false }.keyboardShortcut(.cancelAction)
                    .disabled(model.preparingSource)
                if model.preparingSource { ProgressView().controlSize(.small) }
                Button("Uygula", action: apply).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!confirmed || draft.validation(size: size) != nil || model.preparingSource)
            }
        }.padding(20).frame(width: 920).interactiveDismissDisabled(model.preparingSource)
        .task { image = SourceImage.render(input, page: 1, url: model.source?.guidePreviewURL) }
        .onChange(of: draft) { _, _ in confirmed = false; error = nil }
    }

    private var artboard: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            let width = size.width * scale, height = size.height * scale
            ZStack(alignment: .topLeading) {
                Color.white
                if let image { Image(nsImage: image).resizable().frame(width: width, height: height) }
                ForEach(draft.regions) { region in
                    outline(region.crop, scale: scale, color: region.id == selection ? DesignSystem.teal : DesignSystem.warning)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = region.id }
                        .allowsHitTesting(!drawing)
                    if region.trim != region.crop {
                        outline(region.trim, scale: scale, color: DesignSystem.teal, dashed: true)
                            .allowsHitTesting(false)
                    }
                }
                if let rubberBand { outline(rubberBand, scale: scale, color: DesignSystem.teal).allowsHitTesting(false) }
                if drawing {
                    Color.clear.contentShape(Rectangle()).gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { rubberBand = dragged($0, scale: scale) }
                            .onEnded { event in
                                let rect = dragged(event, scale: scale)
                                if rect.size.width >= 1 && rect.size.height >= 1 { add(rect) }
                                rubberBand = nil
                            }
                    )
                }
            }.frame(width: width, height: height).clipped().border(DesignSystem.border)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityLabel("Kaynak PDF ve bölge sınırları")
    }

    private func outline(_ rect: Rect, scale: Double, color: Color, dashed: Bool = false) -> some View {
        Rectangle().stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
            .frame(width: max(0, rect.size.width) * scale, height: max(0, rect.size.height) * scale)
            .offset(x: rect.origin.x * scale, y: (size.height - rect.origin.y - rect.size.height) * scale)
    }

    private func dragged(_ event: DragGesture.Value, scale: Double) -> Rect {
        func point(_ p: CGPoint) -> Point {
            Point(min(size.width, max(0, p.x / scale)), min(size.height, max(0, size.height - p.y / scale)))
        }
        let a = point(event.startLocation), b = point(event.location)
        return Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func editor(_ region: Binding<ArtworkRegion>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Menu(assignmentLabel(region.wrappedValue.assignment)) {
                Button("Yeni tek yüzlü ürün") {
                    if let product = nextProduct { region.wrappedValue.assignment = SplitCell(product: product) }
                }.disabled(nextProduct == nil)
                ForEach(productNumbers, id: \.self) { number in
                    Button("Ürün \(number) · Ön") { region.wrappedValue.assignment = SplitCell(product: number) }
                    Button("Ürün \(number) · Arka") { region.wrappedValue.assignment = SplitCell(product: number, side: .back) }
                }
                Button("Kullanma") { region.wrappedValue.assignment = SplitCell(product: nil) }
            }
            Group {
                field("Sol konum", region.crop.origin.x)
                field("Alt konum", region.crop.origin.y)
                field("Bölge eni", region.crop.size.width)
                field("Bölge boyu", region.crop.size.height)
                field("Sol taşma", region.bleed.left)
                field("Sağ taşma", region.bleed.right)
                field("Üst taşma", region.bleed.top)
                field("Alt taşma", region.bleed.bottom)
            }
            let trim = region.wrappedValue.trim.size
            Text("Kesim \(TRFormat.size(trim.width, trim.height))").font(.caption)
        }
    }

    private func field(_ title: String, _ value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); DimensionInput(title, value: value, range: 0...10000) }
    }

    private var productNumbers: [Int] { Set(draft.regions.compactMap { $0.assignment?.product }).sorted() }
    private var nextProduct: Int? { (1...ArtworkSeparation.maximumRegions).first { !productNumbers.contains($0) } }

    private func assignmentLabel(_ value: SplitCell?) -> String {
        guard let value else { return "Ürün ve yüz ata" }
        guard let product = value.product else { return "Kullanma" }
        return "Ürün \(product) · \(value.side == .front ? "Ön" : "Arka")"
    }

    private func add(_ crop: Rect) {
        guard draft.regions.count < ArtworkSeparation.maximumRegions else { return }
        let region = ArtworkRegion(crop: crop)
        draft.regions.append(region)
        selection = region.id
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }
        draft.regions.remove(at: index)
        selection = draft.regions.first?.id
    }

    private func apply() {
        var preparation = model.project.sourcePreparation ?? SourcePreparationSettings(sourceID: model.preparationSourceID)
        preparation.separation = draft
        preparation.split = nil
        preparation.ignoreSplitSuggestion = true
        Task {
            do {
                try await model.applySourcePreparation(preparation)
                model.showingArtworkSeparation = false
            } catch { self.error = error.localizedDescription }
        }
    }
}
