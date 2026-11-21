import SwiftUI
import ImpositionCore
import PDFEngine

extension Workspace {
    var coverPreparation: CoverPreparationSettings {
        get { project.coverPreparation ?? CoverPreparationSettings() }
        set { project.coverPreparation = newValue }
    }

    var coverSheetSpec: SheetSpec {
        get { coverPreparation.effectiveSheet(for:project) }
        set { updateCoverImposition { $0.sheet = newValue } }
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
    @State private var sheetDetails = false
    private let presets: [SheetPreset] = [.a5,.a4,.a3,.sra3,.cm33x48,.cm35x50,.cm50x70,.cm70x100]

    var body: some View {
        if let source = model.source {
            let spread = model.coverPreparationPlan(.spread)
            let sheet = model.coverPreparationPlan(.sheet)
            VStack(alignment:.leading,spacing:10) {
                pagePicker("Ön kapak",pages:source.pages,value:$model.coverPreparation.front,automatic:source.pages.first?.number)
                    .inspectorTarget("prepareCover")
                pagePicker("Arka kapak",pages:source.pages,value:$model.coverPreparation.back,automatic:source.pages.last?.number)
                measure("Sırt payı (mm)",$model.coverPreparation.spineWidth,range:0...1000)
                if let size = spread.sheets.first?.size {
                    Text("Açılım: "+TRFormat.size(size.width,size.height)).monospacedDigit()
                }
                if model.coverPreparation.spineWidth > 0 {
                    let back = source.pages.first { $0.number == model.coverPreparation.back } ?? source.pages.last
                    let trim = CGRect(x:0,y:0,width:model.coverPreparation.spineWidth,height:back?.trimSize.height ?? 0)
                    PreparedSpineEditor(model:model,trim:trim)
                    if let issue = spread.issues.first(where:{ $0.severity == .error }) {
                        Text(issue.message).foregroundStyle(DesignSystem.warning)
                    }
                }
                Button("Kapak PDF'i oluştur") { model.requestCoverPreparationExport(.spread) }
                    .disabled(!spread.canExport || model.exporting)
                    .accessibilityIdentifier("exportCoverSpread")
                Divider()
                sheetControls(sheet)
                Button("Tabakaya bağla / PDF oluştur") { model.requestCoverPreparationExport(.sheet) }
                    .disabled(!sheet.canExport || model.exporting)
                    .accessibilityIdentifier("exportImposedCover")
            }
        } else {
            Button("PDF seçin",action:model.choosePDF)
        }
    }

    private func pagePicker(_ title: String,pages: [PDFPageInfo],value: Binding<Int?>,automatic: Int?) -> some View {
        Picker(title,selection:value) {
            Text(automatic.map { "Otomatik (sayfa \($0))" } ?? "Otomatik").tag(nil as Int?)
            ForEach(pages,id:\.number) { page in Text("Sayfa \(page.number)").tag(Optional(page.number)) }
        }.accessibilityIdentifier(title == "Ön kapak" ? "preparedCoverFront" : "preparedCoverBack")
    }

    private var selectedMachine: MachineProfile? {
        model.coverPreparation.useProjectMachine ? model.project.machineProfile : model.coverPreparation.machine
    }

    private var machineSelection: Binding<String> {
        Binding(get:{
            if model.coverPreparation.useProjectMachine { return "project" }
            return model.coverPreparation.machine?.id.uuidString ?? "none"
        },set:{ choice in
            model.updateCoverImposition {
                $0.useProjectMachine = choice == "project"
                $0.machine = model.machineProfiles.first { $0.id.uuidString == choice }
            }
        })
    }

    private func sheetControls(_ plan: ImpositionPlan) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Tabaka montajı").font(.headline)
            Picker("Makine",selection:machineSelection) {
                Text("İşteki makine ayarı").tag("project")
                Text("Makine yok / Serbest").tag("none")
                ForEach(model.machineProfiles) { profile in Text(profile.name).tag(profile.id.uuidString) }
                if let profile = model.coverPreparation.machine,
                   !model.machineProfiles.contains(where:{ $0.id == profile.id }) {
                    Text(profile.name).tag(profile.id.uuidString)
                }
            }
            if let machine = selectedMachine {
                Text(machine.name+" · "+TRFormat.size(machine.size.width,machine.size.height))
                    .foregroundStyle(DesignSystem.muted)
            }
            Menu("Tabaka · "+TRFormat.size(model.coverSheetSpec.size.width,model.coverSheetSpec.size.height)) {
                Button("Varsayılan ölçü") { model.updateCoverImposition { $0.sheet = nil } }
                ForEach(presets,id:\.title) { preset in
                    Button(preset.title) { model.coverSheetSpec.size = preset.size }
                }
            }.accessibilityLabel("Kapak tabakası")
            CoverSheetMeasure(title:"Genişlik",value:$model.coverSheetSpec.size.width,minimum:1)
            CoverSheetMeasure(title:"Yükseklik",value:$model.coverSheetSpec.size.height,minimum:1)
            CoverSheetMeasure(title:"Ara boşluk",value:$model.coverSheetSpec.gutter)
            CoverSheetMeasure(title:"Taşma",value:Binding(
                get:{ model.coverPreparation.bleed ?? CoverPreparationSettings.defaultBleed },
                set:{ value in model.updateCoverImposition { $0.bleed = value } }),maximum:1000)
            Picker("Tabaka yönü",selection:$model.coverSheetSpec.orientation) {
                Text("Otomatik").tag(Orientation.auto)
                Text("Dikey").tag(Orientation.portrait)
                Text("Yatay").tag(Orientation.landscape)
            }
            DisclosureGroup("Kenarlar ve maşa",isExpanded:$sheetDetails) {
                measure("Sol kenar",$model.coverSheetSpec.margins.left)
                measure("Sağ kenar",$model.coverSheetSpec.margins.right)
                measure("Alt kenar",$model.coverSheetSpec.margins.bottom)
                measure("Üst kenar",$model.coverSheetSpec.margins.top)
                if selectedMachine == nil {
                    Picker("Maşa kenarı",selection:$model.coverSheetSpec.gripperEdge) {
                        Text("Alt").tag(ImpositionCore.Edge.bottom)
                        Text("Üst").tag(ImpositionCore.Edge.top)
                        Text("Sol").tag(ImpositionCore.Edge.left)
                        Text("Sağ").tag(ImpositionCore.Edge.right)
                    }
                    measure("Maşa payı",$model.coverSheetSpec.gripperWidth)
                }
            }
            Toggle("Kesim işaretleri",isOn:Binding(get:{ model.coverPreparation.crop ?? model.project.exportMarks.crop },
                                                    set:{ model.coverPreparation.crop = $0 }))
            Picker("Kapak dönüşü",selection:Binding(get:{ model.coverPreparation.grid.rotation },
                set:{ value in model.updateCoverImposition { $0.grid.rotation = value } })) {
                Text("Otomatik (en çok kopya)").tag(MachineProfile.Rotation.automatic)
                Text("0°").tag(MachineProfile.Rotation.zero)
                Text("90°").tag(MachineProfile.Rotation.ninety)
            }
            HStack {
                count("Sütun",$model.coverPreparation.grid.columns)
                count("Satır",$model.coverPreparation.grid.rows)
            }
            measure("Merkezden yatay",$model.coverPreparation.grid.x,range:-10_000...10_000)
            measure("Merkezden dikey",$model.coverPreparation.grid.y,range:-10_000...10_000)
            if let layout = plan.sheets.first?.repeatLayout {
                Text("\(layout.columns) × \(layout.rows) · \(layout.copiesPerSheet) kapak/tabaka").monospacedDigit()
            }
            Button("Tabaka önizle") { model.coverPreviewOutput = .sheet }
            if let error = plan.issues.first(where:{ $0.severity == .error }) {
                Text(error.message).foregroundStyle(DesignSystem.warning)
            } else if let warning = plan.issues.first(where:{ $0.severity == .warning }) {
                Text(warning.message).foregroundStyle(DesignSystem.warning)
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

/// Keeps partial decimal input intact while publishing every valid edit.
private struct CoverSheetMeasure: View {
    let title: String
    @Binding var value: Double
    var minimum = 0.0
    var maximum = 10_000.0
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title,text:Binding(
                get:{ focused ? draft : TRFormat.dimension(value,detail:true) },
                set:{ text in
                    draft = text
                    if let parsed = Double(text.replacingOccurrences(of:",",with:".")),
                       (minimum...maximum).contains(parsed), parsed != value { value = parsed }
                }))
                .focused($focused).multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder).frame(width:80).accessibilityLabel(title)
                .onChange(of:focused) { _, active in
                    if active { draft = TRFormat.dimension(value,detail:true) }
                }
            Text("mm").foregroundStyle(DesignSystem.muted)
        }
    }
}

struct CoverPreparationPreview: View {
    @ObservedObject var model: Workspace

    var body: some View {
        let output = model.coverPreviewOutput
        let plan = model.coverPreparationPlan(output)
        let marks = model.coverPreparationMarks(output)
        VStack(spacing:0) {
            HStack {
                Picker("Kapak önizlemesi",selection:$model.coverPreviewOutput) {
                    Text("Açılım").tag(CoverPreparationPlanner.Output.spread)
                    Text("Tabaka").tag(CoverPreparationPlanner.Output.sheet)
                }.pickerStyle(.segmented).frame(maxWidth:280)
                Spacer()
                if let size = plan.sheets.first?.size {
                    let angle = plan.sheets.first?.front.slots.first?.rotation ?? 0
                    Text(TRFormat.size(size.width,size.height)+(output == .sheet ? " · \(angle)°" : "")).monospacedDigit()
                }
                Button("Sığdır") { model.zoomFactor = 0; model.zoomAction += 1 }
            }.padding(10)
            if let sheet = plan.sheets.first {
                PreviewCanvas(sheet:sheet,side:sheet.front,sheetIndex:0,sideKind:.front,source:model.source,
                              overlays:.artworkOnly,generatedBleed:plan.generatedBleed,highlighted:[],
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
}
