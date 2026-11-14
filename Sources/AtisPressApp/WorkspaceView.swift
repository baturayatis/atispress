import SwiftUI
import PDFEngine
import ImpositionCore
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @ObservedObject var model: Workspace
    @ObservedObject var prices:PricingStore
    @State private var dropTarget = false
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HSplitView {
            sidebar.frame(minWidth:210,idealWidth:230,maxWidth:270)
            center.frame(minWidth:500,maxWidth: .infinity,maxHeight: .infinity)
            InspectorView(model:model,prices:prices).frame(minWidth:370,idealWidth:DesignSystem.inspectorWidth,maxWidth:440)
        }
        .background(DesignSystem.workspace)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshRecentFiles() }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 10).stroke(DesignSystem.teal,lineWidth: 4).padding(5).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL],isTargeted: $dropTarget,perform: model.acceptDrop)
        .alert("İşlem tamamlanamadı",isPresented: Binding(get: { model.error != nil },set: { if !$0 { model.error = nil } })) {
            Button("Tamam") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented:$model.preparingExport) { ExportPreparationView(model:model) }
        .sheet(item:$model.rescalePrompt) { RescalePromptView(model:model,prompt:$0) }
        .toolbar {
            Button(action:model.choosePDF) { HStack { Image(systemName:"doc.badge.plus"); Text("PDF Seç") } }.help("PDF seç · ⌘O")
            Spacer()
            Button("Otomatik düzenle") { model.requestAutomaticLayout() }.disabled(model.source == nil || model.loading || model.autoArranging || model.exporting)
            Button { model.preparingExport = true } label: {
                HStack(spacing:DesignSystem.Space.sm) { Image(systemName:"square.and.arrow.up"); Text("PDF’i Hazırla").fontWeight(.semibold) }.padding(.horizontal,DesignSystem.Space.md).padding(.vertical,DesignSystem.Space.xs)
            }.buttonStyle(.borderedProminent).tint(DesignSystem.action).controlSize(.large).disabled(!model.canExportNow).accessibilityLabel("PDF’i Hazırla")
            if model.exporting { ProgressView().controlSize(.small); Button("İptal",action:model.cancelExport) }
        }.tint(DesignSystem.teal)
    }
    @ViewBuilder private var sidebar: some View {
        if model.project.binding == .gang { GangSidebarView(model: model) } else { classicSidebar }
    }
    private var classicSidebar: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Sayfalar").font(.headline)
                    Spacer()
                    Text("\(model.included.count)/\(model.order.count)").foregroundStyle(DesignSystem.muted).monospacedDigit()
                }.padding(12)
                HStack {
                    Button("Tümü") { model.includeAll(true) }
                    Button("Hiçbiri") { model.includeAll(false) }
                    Spacer()
                    Button { model.moveSelected(up: true) } label: { Image(systemName: "arrow.up") }.help("Seçili sayfaları yukarı taşı").accessibilityLabel("Seçili sayfaları yukarı taşı")
                    Button { model.moveSelected(up: false) } label: { Image(systemName: "arrow.down") }.help("Seçili sayfaları aşağı taşı").accessibilityLabel("Seçili sayfaları aşağı taşı")
                }.buttonStyle(.borderless).disabled(model.source == nil).padding(.horizontal,12).padding(.bottom,8)
                if model.project.isBooklet && model.blankSettings.mode == .manual { BlankPageOrderView(model:model).padding(.horizontal,8) }
                List(selection: $model.selectedPages) {
                    if let source = model.source {
                        ForEach(model.order,id: \.self) { number in
                            PageRow(source:source,number:number,role:WorkflowPresentation.pageRole(number,project:model.project),included: Binding(
                                get: { model.included.contains(number) },
                                set: { model.setIncluded(number,$0) }))
                            .tag(number)
                        }.onMove(perform: model.move)
                    }
                }.listStyle(.sidebar)
                Text("✓ Baskıya dahil et · ⌘ ile çoklu seç · sürükleyerek veya ↑↓ ile sırala")
                    .font(.caption).foregroundStyle(DesignSystem.muted).padding(8)
            }.frame(minHeight: 250)
            VStack(spacing: 0) {
                HStack { Text("Tabakalar").font(.headline); Spacer(); Text("\(model.displaySheets.count)") }.padding(12)
                List(selection: Binding(get:{ model.sheetIndex },set:model.selectPreviewSheet)) {
                    ForEach(model.displaySheets.indices,id: \.self) { index in
                        let sheet = model.displaySheets[index]
                        let signatures = Set(sheet.front.slots.map(\.signature)).sorted().map { String($0+1) }.joined(separator: ", ")
                        VStack(alignment: .leading,spacing: 4) {
                            if let layout = sheet.repeatLayout {
                                Text("Tabaka \(index+1)").fontWeight(.semibold)
                                Text("\(layout.copiesPerSheet) adet · \(sheet.hasContent(on:.back) ? "ön ve arka" : "tek yüz")").font(.caption)
                                Text("Ön \(layout.frontPageNumber) / Arka \(layout.backPageNumber.map(String.init) ?? "Yok") · \(layout.columns)×\(layout.rows)")
                                    .font(.caption).foregroundStyle(DesignSystem.muted)
                                if let summary = sheet.productionSummary { Text(summary).font(.caption).foregroundStyle(DesignSystem.muted) }
                            } else {
                                Text("\(sheet.leafInfo == nil ? (sheet.bookInfo?.label ?? "Tabaka") : (sheet.leafInfo!.cover ? "Kapak" : "Yaprak tabakası")) \(index+1)").fontWeight(.medium)
                                if let leaf = sheet.leafInfo { Text(leaf.summary).font(.caption).foregroundStyle(DesignSystem.muted) }
                                else {
                                    Text("\(sheet.size.width,specifier: "%.0f") × \(sheet.size.height,specifier: "%.0f") mm · \(sheet.bookInfo?.section == .cover ? "Kapak" : "Forma "+signatures)")
                                        .font(.caption).foregroundStyle(DesignSystem.muted)
                                }
                            }
                            if !sheet.blankPositions.isEmpty { Text("Boş konumlar: "+sheet.blankPositions.map(String.init).joined(separator:", ")).font(.caption).foregroundStyle(DesignSystem.warning) }
                            if let serials = sheet.serialPlan {
                                ForEach(serials.fields) { field in
                                    Text("Seri: \(serials.range(field: field,repetition: index == model.sheetIndex ? model.repetition : 0) ?? "—")")
                                        .font(.caption).foregroundStyle(DesignSystem.muted)
                                }
                            }
                        }.tag(index).padding(.vertical,DesignSystem.Space.xs)
                            .listRowBackground(model.sheetIndex == index ? DesignSystem.selected.opacity(0.12) : DesignSystem.clear)
                        if sheet.serialPlan != nil,index == model.sheetIndex { serialSheetRows(sheet,index: index) }
                    }
                }.listStyle(.sidebar)
            }.frame(minHeight: 130,idealHeight: 230)
        }
    }
    @ViewBuilder
    private func serialSheetRows(_ sheet: Sheet,index: Int) -> some View {
        let first = (model.repetition/100)*100
        if first > 0 { Button("Önceki 100 tabaka") { model.repetition = first-1 } }
        ForEach(first..<(first+min(100,sheet.repeatCount-first)),id: \.self) { repetition in
            Button {
                model.sheetIndex = index; model.repetition = repetition
            } label: {
                VStack(alignment: .leading,spacing: 2) {
                    Text("Tabaka \(repetition+1)"+(model.repetition == repetition ? " · Önizleme" : ""))
                    if let serials = sheet.serialPlan {
                        ForEach(serials.fields) { field in
                            Text(serials.range(field: field,repetition: repetition) ?? "Numara yok").font(.caption)
                        }
                    }
                }
            }.buttonStyle(.plain).padding(.leading,8)
        }
        if sheet.repeatCount-first > 100 { Button("Sonraki 100 tabaka") { model.repetition = first+100 } }
    }
    private var generatedBleedLabel: String? {
        let settings = model.plan.generatedBleed
        guard settings.enabled else { return nil }
        switch settings.method {
        case .automatic: return String(format: "Taşma: Otomatik · tolerans %.1f%%",settings.tolerance*100)
        case .mirror: return "Taşma: Yansıt"
        case .solidColor:
            let space = settings.color.components.count == 4 ? "CMYK" : "RGB"
            return "Taşma: Renk · "+space+" "+settings.color.components.map { String(format: "%.0f",$0*100) }.joined(separator: "/")
        }
    }
    private var center: some View {
        VStack(spacing: 0) {
            VStack(spacing:8) {
                HStack {
                    Text("Görünüm:").font(.caption)
                    PreviewScopePicker(model:model).labelsHidden()
                    Spacer(minLength:4)
                    Picker("Yüz",selection: $model.side) {
                        Text("Ön").tag(SideKind.front)
                        Text("Arka").tag(SideKind.back)
                    }.pickerStyle(.segmented).frame(width:150)
                }
                HStack {
                    if !model.showsAllSides,!model.displaySheets.isEmpty {
                        Button { model.movePreviewSheet(-1) } label: { Image(systemName:"chevron.left") }.accessibilityLabel("Önceki tabaka")
                        Text(model.previewSheetPosition).font(.caption).monospacedDigit()
                        Button { model.movePreviewSheet(1) } label: { Image(systemName:"chevron.right") }.accessibilityLabel("Sonraki tabaka")
                    }
                    Spacer()
                    Button { model.zoomFactor = 1/1.25; model.zoomAction += 1 } label: { Image(systemName:"minus.magnifyingglass") }.help("Uzaklaştır").accessibilityLabel("Uzaklaştır")
                    Button("Sığdır") { model.zoomFactor = 0; model.zoomAction += 1 }
                    Button { model.zoomFactor = 1.25; model.zoomAction += 1 } label: { Image(systemName:"plus.magnifyingglass") }.help("Yakınlaştır").accessibilityLabel("Yakınlaştır")
                }
            }.padding(10)
            if model.showsAllSides, !model.displaySheets.isEmpty {
                AllSheetsPreview(model:model)
            } else if let sheet = model.currentSheet,model.side == .back,!sheet.hasContent(on: .back),sheet.diagnosticBounds == nil {
                ContentUnavailableView("Arka yüz yok",systemImage: "doc",description: Text("Bu işin arka yüzünde içerik yok."))
                    .frame(maxWidth: .infinity,maxHeight: .infinity)
            } else if let sheet = model.currentSheet, let side = model.currentSide {
                PreviewCanvas(sheet: sheet,side: side,sheetIndex: model.sheetIndex,sideKind: model.side,source: model.source,overlays: model.overlays,generatedBleed: model.plan.generatedBleed,
                              highlighted: model.highlightedSlots,zoomAction: model.zoomAction,zoomFactor:model.zoomFactor,focusArea:model.ui.focusedArea,moveSheet:model.movePreviewSheet,
                              repetition: model.repetition,selectedSerial: model.selectedSerialID,
                              selectSerial: model.selectSerial,moveSerial: { model.moveSerialField($0,to: $1) },controlMarks: model.project.exportMarks,moveGangBlock: { model.moveGangBlock($0,to:$1) },beginEdit:model.beginUndoGroup,endEdit:model.endUndoGroup)
            } else if model.source == nil {
                HomeEmptyStateView(model: model)
            } else {
                ContentUnavailableView("Önizleme oluşturulamadı",systemImage: "exclamationmark.triangle",
                    description: Text("Sayfa seçimini ve aşağıdaki doğrulama mesajlarını kontrol edin."))
                    .frame(maxWidth: .infinity,maxHeight: .infinity)
            }
            if let summary = model.exportSummary {
                HStack {
                    Text(summary).font(.caption)
                    Spacer()
                    if !model.exportedFiles.isEmpty { Button("Finder’da Göster",action: model.revealExport).font(.caption) }
                }.padding(8)
            }
            Divider()
            HStack(spacing:DesignSystem.Space.md) {
                if model.plan.displayIssues.isEmpty {
                    Label(model.workflowReadyText,systemImage:"checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.success).padding(DesignSystem.Space.sm)
                        .background(DesignSystem.successSurface,in:RoundedRectangle(cornerRadius:DesignSystem.Radius.control))
                } else {
                    Menu {
                        ForEach(Array(model.plan.displayIssues.enumerated()),id:\.offset) { _,issue in Button(issue.message) { model.revealWorkflowIssue(issue) } }
                    } label: {
                        let errors = model.plan.issues.filter { $0.severity == .error }.count
                        let warnings = model.plan.issues.filter { $0.severity == .warning }.count
                        Label("\(errors > 0 ? "\(errors) hata · " : "")\(warnings) uyarı · \(model.plan.totalPressSheets) tabaka",systemImage:errors > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    }.menuStyle(.borderlessButton).fixedSize().padding(DesignSystem.Space.sm)
                        .foregroundStyle(DesignSystem.warning).background(DesignSystem.warningSurface,in:RoundedRectangle(cornerRadius:DesignSystem.Radius.control))
                    if let first = model.plan.displayIssues.first {
                        Button(first.message) { model.revealWorkflowIssue(first) }.buttonStyle(.plain).font(.caption).lineLimit(2).accessibilityLabel("Ayarı göster: "+first.message)
                    }
                }
                Spacer(minLength:0)
            }.font(.callout).padding(DesignSystem.Space.md)

        }
    }
}

private struct PageRow: View {
    let source: PDFSource
    let number: Int
    let role:String
    @Binding var included: Bool
    @State private var thumbnail: NSImage?
    var body: some View {
        HStack(spacing: 9) {
            Toggle("Sayfa \(number) · \(role) · baskıya dahil",isOn:$included).labelsHidden().toggleStyle(.checkbox)
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(DesignSystem.paper)
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else { Image(systemName: "doc").foregroundStyle(DesignSystem.muted) }
            }.frame(width: 44,height: 62).clipped()
            VStack(alignment: .leading,spacing: 4) {
                HStack { Text("Sayfa \(number)").fontWeight(.medium); Text(role).font(.caption).foregroundStyle(DesignSystem.muted) }
                let info = source.pages[number-1]
                Text("\(info.trimSize.width,specifier: "%.1f") × \(info.trimSize.height,specifier: "%.1f") mm").font(.caption2)
                Text(info.availableBleed.map { String(format: "Taşma %.1f mm",$0) } ?? "Taşma bilinmiyor")
                    .font(.caption2).foregroundStyle(DesignSystem.muted)
            }
        }.opacity(included ? 1 : 0.45)
        .task(id: "\(source.id)-\(number)") {
            let image = await source.image(page: number,pixels: 128)
            if !Task.isCancelled { thumbnail = image }
        }
        .onDisappear { thumbnail = nil }
    }
}
