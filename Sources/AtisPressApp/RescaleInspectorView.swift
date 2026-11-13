import SwiftUI
import ImpositionCore

struct RescaleEditor: View {
    @Binding var settings: RescaleSettings
    let sourceSize: Size
    var showSummary = true
    @State private var customTarget = false
    private var target: Binding<Int> { Binding(get:{ customTarget ? -1 : RescaleSettings.targets.firstIndex { $0.1 == settings.target } ?? -1 },set:{ customTarget = $0 == -1; if $0 >= 0 { settings.target = RescaleSettings.targets[$0].1 } }) }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Picker("Hedef ebat",selection:target) {
                ForEach(RescaleSettings.targets.indices,id:\.self) { index in Text(RescaleSettings.targets[index].0).tag(index) }
                Text("Özel (mm)").tag(-1)
            }
            if target.wrappedValue == -1 {
                HStack {
                    TextField("En (mm)",value:$settings.target.width,format:.number)
                    Text("×")
                    TextField("Boy (mm)",value:$settings.target.height,format:.number)
                }.textFieldStyle(.roundedBorder)
            }
            Picker("Mod",selection:$settings.mode) { ForEach(RescaleMode.allCases,id:\.self) { Text($0.title).tag($0) } }
            if settings.isValid {
                let scale = ArtworkRescale(source:sourceSize,settings:settings)
                if showSummary { Text(scale.summary).font(.caption) }
                if scale.aspectWarning { Text("En/boy oranı %2’den fazla değişiyor.").font(.caption).foregroundStyle(.orange) }
            } else { Text("Geçerli bir hedef ebat girin.").foregroundStyle(.red) }
        }
    }
}

struct ScalingRow: Identifiable {
    var indices: [Int]
    var pages: [Int]
    var gangID: UUID?
    var jobIndex: Int?
    var size: Size
    var settings: RescaleSettings?
    var defaultTarget: Size
    var id: Int { indices[0] }
    var title: String {
        let numbers = indices.map { String($0+1) }.joined(separator:", ")
        let label = indices.count > 1 && indices.last! - indices[0] == indices.count-1 ? "\(indices[0]+1)-\(indices.last!+1)" : numbers
        let target = settings?.target ?? defaultTarget
        func dimension(_ s:Size) -> String { String(format:"%g×%g",s.width,s.height) }
        return "İş \(label): \(dimension(size))" + (abs(size.width-target.width)<0.1 && abs(size.height-target.height)<0.1 ? " · ebat uygun" : " → \(dimension(target))")
    }
}
extension Workspace {
    var scalingRows: [ScalingRow] {
        var rows: [ScalingRow] = []
        func add(_ pages:[Int],_ size:Size,_ gangID:UUID?,_ jobIndex:Int?) {
            rows.append(ScalingRow(indices:[rows.count],pages:pages,gangID:gangID,jobIndex:jobIndex,size:size,settings:scaleSettings(pages:pages,gangID:gangID,jobIndex:jobIndex),defaultTarget:project.scaling?.defaults.target ?? Size(90,50)))
        }
        if project.binding == .gang {
            for job in project.gang?.jobs ?? [] { add([job.front.number]+[job.back?.number].compactMap { $0 },job.front.trimSize,job.id,nil) }
        } else if project.isBooklet {
            let covers = project.book?.coverPDFPages ?? []
            for pages in [project.pages.filter { !covers.contains($0.number) },project.pages.filter { covers.contains($0.number) }] {
                if let page = pages.first { add(pages.map(\.number),page.trimSize,nil,nil) }
            }
        } else {
            for (i,job) in project.repeatJobs.enumerated() { add([job.front.number]+[job.back?.number].compactMap { $0 },job.front.trimSize,nil,i) }
        }
        return rows
    }
    var groupedScalingRows: [ScalingRow] {
        var groups: [ScalingRow] = []
        for row in scalingRows {
            if let i = groups.firstIndex(where:{ $0.size == row.size && $0.settings == row.settings }) { groups[i].indices += row.indices }
            else { groups.append(row) }
        }
        return groups
    }
    var scalingSummary: String {
        if project.hasInvalidScaling { return "Geçerli bir hedef ebat girin." }
        let rows = scalingRows
        let target = project.scaling?.defaults.target ?? Size(90,50)
        if project.scaling?.enabled != true && rows.allSatisfy({ $0.settings == nil }) {
            let different = rows.filter { abs($0.size.width-target.width)>0.1 || abs($0.size.height-target.height)>0.1 }.count
            return different == 0 ? "Tüm işler hedef ebatta" : "\(different) iş farklı ebatta — ölçekle"
        }
        let values = rows.flatMap { row -> [Int] in
            guard let settings = row.settings, settings.isValid, row.size.width > 0, row.size.height > 0 else { return [100] }
            let factors = ArtworkRescale(source:row.size,settings:settings).factors
            return [Int((factors.width*100).rounded()),Int((factors.height*100).rounded())]
        }
        guard let low = values.min(),let high = values.max() else { return "0 iş" }
        return "\(rows.count) iş · %\(low)" + (low == high ? " ölçek" : "–%\(high) ölçek")
    }
    func updateScaling(_ edit:(inout ScalingSettings)->Void) {
        project.migrateScaling()
        var value = project.scaling!; edit(&value); project.scaling = value
    }
}
struct RescaleInspectorView: View {
    @ObservedObject var model: Workspace
    @State private var expanded = false
    @State private var showAll = false
    var body: some View {
        GroupBox("Ölçeklendir") {
            VStack(alignment:.leading,spacing:8) {
                Toggle("Hedef ebada ölçeklendir",isOn:Binding(get:{ model.project.scaling?.enabled ?? false },set:{ enabled in model.updateScaling { $0.enabled = enabled } }))
                RescaleEditor(settings:Binding(get:{ model.project.scaling?.defaults ?? RescaleSettings() },set:{ settings in model.updateScaling { $0.defaults = settings } }),sourceSize:model.scalingRows.first?.size ?? Size(90,50),showSummary:false)
                Text(model.scalingSummary).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("İşlere göre ayarla (\(model.scalingRows.count))",isExpanded:$expanded) {
                    let groups = model.groupedScalingRows
                    ForEach(Array((showAll ? groups : Array(groups.prefix(3))))) { group in
                        VStack(alignment:.leading,spacing:4) {
                            Text(group.title).font(.caption)
                            Picker("Ölçekleme",selection:Binding(get:{ overrideKind(group) },set:{ kind in apply(group,kind:kind) })) {
                                Text("Genel ayar").tag(0)
                                Text("Ölçekleme yok").tag(1)
                                Text("Özel hedef / mod").tag(2)
                            }
                            if overrideKind(group) == 2 {
                                RescaleEditor(settings:Binding(get:{ group.settings ?? RescaleSettings() },set:{ settings in apply(group,settings:settings) }),sourceSize:group.size)
                            }
                        }.padding(.vertical,4)
                    }
                    if groups.count > 3 { Button(showAll ? "Daha az göster" : "Tümünü göster") { showAll.toggle() } }
                }
            }.padding(5)
        }
    }
    private func overrideKind(_ row:ScalingRow) -> Int {
        let first = model.scalingRows[row.indices[0]]
        if let value = model.project.scaling?.overrides.last(where:{ $0.gangID == first.gangID && ($0.jobIndex == nil || $0.jobIndex == first.jobIndex) && first.pages.first.map($0.pages.contains) == true }) { return value.settings == nil ? 1 : 2 }
        return model.project.scaling == nil && row.settings != nil ? 2 : 0
    }
    private func apply(_ row:ScalingRow,kind:Int = 2,settings:RescaleSettings? = nil) {
        let jobs = row.indices.map { model.scalingRows[$0] }
        model.updateScaling { value in
            for job in jobs {
                value.overrides = value.overrides.compactMap { override in
                    var next = override
                    if next.gangID == job.gangID && next.jobIndex == job.jobIndex { next.pages.removeAll { job.pages.contains($0) } }
                    return next.pages.isEmpty ? nil : next
                }
                if kind != 0 { value.overrides.append(ScalingOverride(pages:job.pages,jobIndex:job.jobIndex,gangID:job.gangID,settings:kind == 1 ? nil : settings ?? row.settings ?? value.defaults)) }
            }
        }
    }
}

struct RescalePrompt: Identifiable {
    let id = UUID()
    var pages: [Int]
    var gangID: UUID?
    var jobIndex: Int? = nil
    var size: Size
    var settings: RescaleSettings
    var arrangeAfter = false
}
struct RescalePromptView: View {
    @ObservedObject var model: Workspace
    let prompt: RescalePrompt
    @State private var settings: RescaleSettings
    init(model:Workspace,prompt:RescalePrompt) { self.model = model; self.prompt = prompt; _settings = State(initialValue:prompt.settings) }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Ürün ebadı \(prompt.size.width,specifier:"%.1f") × \(prompt.size.height,specifier:"%.1f"). Hedef ebada ölçeklensin mi?").font(.headline)
            RescaleEditor(settings:$settings,sourceSize:prompt.size)
            HStack {
                Button("Özgün ebadı koru") { model.finishScalePrompt(prompt,settings:nil) }
                Spacer()
                Button("Ölçeklendir") { model.finishScalePrompt(prompt,settings:settings) }.disabled(!settings.isValid).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:500)
    }
}

extension Workspace {
    func scaleSettings(pages:[Int],gangID:UUID?,jobIndex:Int? = nil) -> RescaleSettings? {
        guard let number = pages.first else { return nil }
        return project.scalingSettings(number:number,jobID:gangID,jobIndex:jobIndex)
    }
    func setScale(_ settings:RescaleSettings?,pages:[Int],gangID:UUID?,jobIndex:Int? = nil) {
        updateScaling { value in
            value.overrides = value.overrides.compactMap { override in
                var next = override
                if next.gangID == gangID && next.jobIndex == jobIndex { next.pages.removeAll { pages.contains($0) } }
                return next.pages.isEmpty ? nil : next
            }
            value.overrides.append(ScalingOverride(pages:pages,jobIndex:jobIndex,gangID:gangID,settings:settings))
        }
    }
    @discardableResult func offerRescaling(arrangeAfter:Bool = false) -> Bool {
        var candidates: [RescalePrompt] = []
        func add(_ pages:[Int],_ size:Size,_ id:UUID?,_ jobIndex:Int? = nil) {
            let chosen = scaleSettings(pages:pages,gangID:id,jobIndex:jobIndex)
            let differs = chosen.map { abs($0.target.width-size.width)>0.1 || abs($0.target.height-size.height)>0.1 } ?? false
            let largeCard = size.width>=99.9 && size.height>=59.9 && size.width<=150 && size.height<=100
            let oversized = max(size.width,size.height)>300
            if differs || (chosen == nil && (largeCard || oversized)) {
                candidates.append(RescalePrompt(pages:pages,gangID:id,jobIndex:jobIndex,size:size,settings:chosen ?? RescaleSettings(target:oversized ? Size(210,297) : Size(90,50)),arrangeAfter:arrangeAfter))
            }
        }
        if project.binding == .gang {
            for job in project.gang?.jobs ?? [] { add([job.front.number]+[job.back?.number].compactMap { $0 },job.front.trimSize,job.id) }
        } else if project.isBooklet {
            let covers = project.book?.coverPDFPages ?? []
            let body = project.pages.filter { !covers.contains($0.number) }
            if let page = body.first { add(body.map(\.number),page.trimSize,nil) }
            if let cover = project.pages.first(where:{ covers.contains($0.number) }) { add(covers,cover.trimSize,nil) }
        } else {
            for (index,job) in project.repeatJobs.enumerated() { add([job.front.number]+[job.back?.number].compactMap { $0 },job.front.trimSize,nil,index) }
        }
        pendingScalePrompts = candidates
        rescalePrompt = pendingScalePrompts.isEmpty ? nil : pendingScalePrompts.removeFirst()
        return rescalePrompt != nil
    }
    func finishScalePrompt(_ prompt:RescalePrompt,settings:RescaleSettings?) {
        setScale(settings,pages:prompt.pages,gangID:prompt.gangID,jobIndex:prompt.jobIndex)
        rescalePrompt = nil
        if !pendingScalePrompts.isEmpty {
            DispatchQueue.main.async { self.rescalePrompt = self.pendingScalePrompts.removeFirst() }
        } else if prompt.arrangeAfter { autoArrange(resetOverrides:true,askRescale:false) }
        else { autoArrange(resetOverrides:false,askRescale:false) }
    }
}
