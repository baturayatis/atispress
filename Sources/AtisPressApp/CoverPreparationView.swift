import SwiftUI
import ImpositionCore
import PDFEngine

extension Workspace {
    var coverPreparation: CoverPreparationSettings {
        get { project.coverPreparation ?? CoverPreparationSettings() }
        set { project.coverPreparation = newValue }
    }

    func updateCoverImposition(_ change: (inout CoverPreparationSettings) -> Void) {
        var cover = coverPreparation
        change(&cover)
        coverPreviewOutput = .sheet
        coverPreparation = cover
    }
}

struct CoverPreparationView: View {
    @ObservedObject var model: Workspace
    @State private var calculator = false

    var body: some View {
        let enabled = model.coverSettingsHint == nil
        Group {
            let spread = enabled ? model.coverPreparationPlan(.spread) : ImpositionPlan()
            let sheet = enabled ? model.coverPreparationPlan(.sheet) : ImpositionPlan()
            VStack(alignment:.leading,spacing:10) {
                sourceControls
                if model.project.coverPreparation == nil && (model.project.isBooklet || model.project.isLeafBinding) {
                    BookInspectorView(model:model)
                } else {
                    if model.coverPreparation.source == .selectedPages || model.coverPreparation.source == nil && model.project.coverPreparation != nil {
                        let legacy = model.coverPreparation.source == nil
                        let pages = legacy ? model.source?.pages.map(\.sourcePage) ?? [] : model.coverSelectablePages
                        let automatic = legacy ? pages : model.coverSourcePages
                        pagePicker("Ön kapak",pages:pages,value:$model.coverPreparation.front,automatic:automatic.first?.number)
                        pagePicker("Arka kapak",pages:pages,value:$model.coverPreparation.back,automatic:automatic.last?.number)
                    }
                    measure("Sırt payı (mm)",ContextBindings(model:model).spine,range:0...1000)
                        .inspectorTarget("coverMode")
                    Button("Kalınlıktan hesapla…") { calculator = true }
                        .popover(isPresented:$calculator) {
                            SpineCalculatorView(book:model.bookSettings,pageCount:model.coverInteriorProject.pages.count) {
                                model.spineWidth = $0
                                calculator = false
                            }
                        }
                    if let size = spread.sheets.first?.size {
                        Text("Açılım: \(TRFormat.dimension(size.width,detail:true)) × \(TRFormat.dimension(size.height,detail:true)) mm").monospacedDigit()
                    }
                    if let slot = spread.sheets.first?.front.slots.first(where: { $0.spineArtwork != nil }) {
                        Text("Sırt içeriği").font(.headline)
                        PreparedSpineEditor(model:model,trim:CGRect(x:0,y:0,width:slot.size.width,height:slot.size.height))
                    }
                    if sheet.issues.isEmpty, let issue = spread.issues.first(where:{ $0.severity == .error }) {
                        Text(issue.message).foregroundStyle(DesignSystem.warning)
                    }
                    if model.coverPreparation.source == nil && model.project.coverPreparation != nil {
                        Button("Kapak PDF'i oluştur") { model.requestCoverPreparationExport(.spread) }
                            .disabled(!spread.canExport || model.exporting)
                            .accessibilityIdentifier("exportCoverSpread")
                        Divider()
                        coverSheetControls(sheet,legacy:true)
                        Button("Tabakaya bağla / PDF oluştur") { model.requestCoverPreparationExport(.sheet) }
                            .disabled(!sheet.canExport || model.exporting)
                            .accessibilityIdentifier("exportImposedCover")
                    } else if model.coverPreparation.source != nil {
                        if model.spineWidth > 0 {
                            Toggle("Sırt kenarlarına katlama işareti",isOn:optionalFlag(\.foldMarks))
                        }
                        Divider()
                        coverSheetControls(sheet,legacy:false)
                        if model.project.binding == .saddleStitch {
                            DisclosureGroup("Tel dikiş ayrıntıları") { SaddleCreepControls(model:model) }
                        }
                    }
                }
            }.font(.system(size:13))
        }
            .disabled(!enabled)
            .accessibilityIdentifier("cover.settings")
    }

    private var sourceControls: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Kapak kaynağı").font(.headline)
            let choices: [(CoverPreparationSettings.Source,String)] = [
                (.firstAndLast,"İlk ve son sayfa"), (.selectedPages,"Sayfaları seç"),
                (.coverFile,"Sadece kapağı olan iş"), (.separatePDF,"Ayrı kapak PDF'i")
            ]
            VStack(spacing:4) {
                sourcePicker(Array(choices.prefix(2)))
                sourcePicker(Array(choices.suffix(2)))
            }.inspectorTarget("prepareCover")
            if let source = model.coverPreparation.source {
                if source == .separatePDF {
                    let linked = model.pageSourceRecords.first { $0.id == model.bookSettings.coverSourceID }
                    if let linked { Text(linked.reference.fileName).lineLimit(1) }
                    Button(linked == nil ? "Kapak PDF’i seç…" : "Kapak PDF’ini değiştir…",action:model.chooseCoverPDF)
                        .disabled(model.loading || model.exporting)
                }
                Toggle("Sadece kapağı bas",isOn:optionalFlag(\.onlyCover))
                if model.coverPreparation.onlyCover == true { Text("İç sayfalar: basılmayacak") }
            }
        }
    }

    private func sourcePicker(_ choices: [(CoverPreparationSettings.Source,String)]) -> some View {
        Picker("Kapak kaynağı",selection:Binding(
            get:{ model.coverPreparation.source },
            set:{ if let source = $0 { model.activateCoverSource(source) } })) {
            ForEach(choices,id:\.0) { source, label in Text(label).tag(Optional(source)) }
        }.pickerStyle(.segmented).labelsHidden()
    }

    private func optionalFlag(_ field: WritableKeyPath<CoverPreparationSettings,Bool?>) -> Binding<Bool> {
        Binding(get:{ model.coverPreparation[keyPath:field] ?? false },
                set:{ model.coverPreparation[keyPath:field] = $0 })
    }

    private func pagePicker(_ title: String,pages: [SourcePage],value: Binding<Int?>,automatic: Int?) -> some View {
        Picker(title,selection:value) {
            Text(automatic.map { "Otomatik (\(pageLabel($0)))" } ?? "Otomatik").tag(nil as Int?)
            ForEach(pages,id:\.number) { page in Text(pageLabel(page.number)).tag(Optional(page.number)) }
        }.accessibilityIdentifier(title == "Ön kapak" ? "preparedCoverFront" : "preparedCoverBack")
    }

    private func pageLabel(_ number: Int) -> String {
        if model.coverPreparation.source == nil { return "Sayfa \(number)" }
        let title = model.coverPageLabel(number)
        guard model.project.pageItems != nil, model.pageSourceRecords.count > 1 else { return title }
        return title+" · "+model.pageSourceName(number)
    }

    private func coverSheetControls(_ plan: ImpositionPlan,legacy: Bool) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Tabaka montajı").font(.headline)
            HStack {
                Button("Tabaka ayarları") { model.ui.jump(.sheet,opening:.paper) }
                Button("Kenarlar ve hizalama") { model.ui.jump(.dimensions,opening:.edges) }
            }
            HStack {
                Button("Taşma ayarları") {
                    if let index = model.displaySheets.firstIndex(where: \.isPreparedCover) {
                        model.selectPreviewSheet(index)
                    }
                    model.ui.jump(.dimensions,opening:.bleed)
                }
                Button("Çıktı işaretleri") { model.ui.jump(.cut,opening:.printedMarks) }
            }
            if legacy {
                measure("Kapak ara boşluğu",Binding(get:{ model.coverPreparation.gap ?? 0 },
                    set:{ value in model.updateCoverImposition { $0.gap = value } }))
                LabeledContent("Kapak taşması") {
                    BleedInput(title:"Kapak taşması",value:Binding(
                        get:{ model.coverPreparation.bleed ?? CoverPreparationSettings.defaultBleed },
                        set:{ value in model.updateCoverImposition { $0.bleed = value } }),maximum:1000)
                }
            }
            DisclosureGroup("Açılım dizilimi") {
                Picker("Kapak dönüşü",selection:$model.coverPreparation.grid.rotation) {
                    Text("Otomatik").tag(MachineProfile.Rotation.automatic)
                    Text("0°").tag(MachineProfile.Rotation.zero)
                    Text("90°").tag(MachineProfile.Rotation.ninety)
                }
                HStack {
                    count("Sütun",$model.coverPreparation.grid.columns)
                    count("Satır",$model.coverPreparation.grid.rows)
                }
                measure("Merkezden yatay",$model.coverPreparation.grid.x,range:-10_000...10_000)
                measure("Merkezden dikey",$model.coverPreparation.grid.y,range:-10_000...10_000)
            }
            if let copies = plan.sheets.first?.repeatLayout?.copiesPerSheet {
                Text("Tabakada \(copies) açılım").monospacedDigit()
            }
            if let sheet = plan.sheets.first {
                let warnings = PDFColorControlRenderer.geometry(sheet:sheet,settings:model.coverPreparationMarks(.sheet)).warnings
                ForEach(Array(Set(warnings)).sorted(),id:\.self) {
                    Text($0).foregroundStyle(DesignSystem.warning)
                }
            }
            ForEach(Array(plan.issues.enumerated()),id:\.offset) { _, issue in
                Text(issue.message).foregroundStyle(DesignSystem.warning)
            }
        }
    }

    private func count(_ title: String,_ value: Binding<Int?>) -> some View {
        VStack(alignment:.leading,spacing:3) {
            Text(title)
            TextField("Otomatik",value:value,format:.number)
                .accessibilityLabel(title+" sayısı")
                .textFieldStyle(.roundedBorder)
        }
    }

    private func measure(_ title: String,_ value: Binding<Double>,range: ClosedRange<Double> = 0...10_000) -> some View {
        HStack { Text(title); Spacer(); DimensionInput(title,value:value,range:range) }
    }
}

struct CoverPreparationPreview: View {
    @ObservedObject var model: Workspace

    var body: some View {
        let output = model.coverPreviewOutput
        let plan = model.coverPreparationPlan(output)
        let marks = model.coverPreparationMarks(output)
        let active = model.coverPreparation.source != nil
        let guides = active ? model.overlays : coverGuides(output,marks:marks)
        VStack(spacing:0) {
            HStack {
                Text("Kapak").font(.headline)
                Picker("Kapak önizlemesi",selection:$model.coverPreviewOutput) {
                    Text("Açılım").tag(CoverPreparationPlanner.Output.spread)
                    Text("Tabaka").tag(CoverPreparationPlanner.Output.sheet)
                }.pickerStyle(.segmented).frame(maxWidth:280)
                Spacer()
                if let size = plan.sheets.first?.size {
                    let angle = plan.sheets.first?.front.slots.first?.rotation ?? 0
                    let copies = plan.sheets.first?.repeatLayout?.copiesPerSheet ?? 0
                    Text(TRFormat.size(size.width,size.height)+(output == .sheet ? " · \(angle)° · \(copies) kapak" : ""))
                        .monospacedDigit()
                }
                Button("Sığdır") { model.zoomFactor = 0; model.zoomAction += 1 }
            }.padding(10)
            if let sheet = plan.sheets.first {
                PreviewCanvas(sheet:sheet,side:sheet.front,sheetIndex:0,sideKind:.front,source:model.source,
                              overlays:guides,generatedBleed:plan.generatedBleed,bleedAmount:model.project.settings.bleed,tone:plan.tone,highlighted:[],
                              zoomAction:model.zoomAction,zoomFactor:model.zoomFactor,controlMarks:marks,forceVectorArtwork:true,preparedSpineModel:model,
                              beginEdit:model.beginUndoGroup,endEdit:model.endUndoGroup)
                    .id(output)
            } else {
                ContentUnavailableView(model.source == nil ? "PDF seçin" : "Kapak önizlemesi oluşturulamadı",
                    systemImage:"book.closed",description:plan.issues.first.map { Text($0.message) })
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            if let summary = model.exportSummary, !model.exportedFiles.isEmpty || model.exporting {
                HStack { Text(summary); Spacer(); Button("Klasörde göster",action:model.revealExport) }.padding(8)
            }
        }
        .accessibilityIdentifier("coverPreparationPreview")
    }

    private func coverGuides(_ output: CoverPreparationPlanner.Output,marks: ExportMarks) -> PreviewOverlays {
        var guides = PreviewOverlays.artworkOnly
        guides.registrationTargets = output == .sheet && model.overlays.registrationTargets && !marks.registrationTargets
        return guides
    }

}
