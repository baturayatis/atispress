import SwiftUI
import ImpositionCore

struct RescaleEditor: View {
    @Binding var settings: RescaleSettings
    let sourceSize: Size
    @State private var target = -1
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Picker("Hedef ebat",selection:$target) {
                ForEach(RescaleSettings.targets.indices,id:\.self) { index in Text(RescaleSettings.targets[index].0).tag(index) }
                Text("Özel (mm)").tag(-1)
            }.onAppear { target = RescaleSettings.targets.firstIndex { $0.1 == settings.target } ?? -1 }.onChange(of:target) { _,index in if index>=0 { settings.target = RescaleSettings.targets[index].1 } }
            HStack {
                TextField("En (mm)",value:$settings.target.width,format:.number)
                Text("×")
                TextField("Boy (mm)",value:$settings.target.height,format:.number)
            }.textFieldStyle(.roundedBorder)
            Picker("Mod",selection:$settings.mode) { ForEach(RescaleMode.allCases,id:\.self) { Text($0.title).tag($0) } }
            if settings.isValid {
                let scale = ArtworkRescale(source:sourceSize,settings:settings)
                Text(scale.summary).font(.caption)
                if scale.aspectWarning { Text("En/boy oranı %2’den fazla değişiyor.").font(.caption).foregroundStyle(.orange) }
            } else { Text("Geçerli bir hedef ebat girin.").foregroundStyle(.red) }
        }
    }
}

struct RescaleInspectorView: View {
    @ObservedObject var model: Workspace
    var body: some View {
        GroupBox("Ölçeklendir") {
            VStack(alignment:.leading,spacing:8) {
                if let job = model.selectedGangJob {
                    editor(pages:[job.front.number]+[job.back?.number].compactMap { $0 },size:job.front.trimSize,gangID:job.id)
                } else if model.project.isBooklet,let page = model.project.pages.first {
                    let covers = model.project.book?.coverPDFPages ?? []
                    Text("İç sayfalar").font(.caption.bold())
                    editor(pages:model.project.pages.map(\.number).filter { !covers.contains($0) },size:page.trimSize,gangID:nil)
                    if let cover = model.project.pages.first(where:{ covers.contains($0.number) }) {
                        Text("Kapak PDF / açılım").font(.caption.bold())
                        editor(pages:covers,size:cover.trimSize,gangID:nil)
                    }
                } else {
                    ForEach(Array(model.project.repeatJobs.enumerated()),id:\.offset) { index,job in
                        Text("İş \(index+1)").font(.caption.bold())
                        editor(pages:[job.front.number]+[job.back?.number].compactMap { $0 },size:job.front.trimSize,gangID:nil,jobIndex:index)
                    }
                }
            }.padding(5)
        }
    }
    private func editor(pages:[Int],size:Size,gangID:UUID?,jobIndex:Int? = nil) -> some View {
        let current = model.scaleSettings(pages:pages,gangID:gangID,jobIndex:jobIndex)
        return VStack(alignment:.leading,spacing:6) {
            Toggle("Hedef ebada ölçeklendir",isOn:Binding(get:{ current != nil },set:{ model.setScale($0 ? RescaleSettings() : nil,pages:pages,gangID:gangID,jobIndex:jobIndex) }))
            if let current {
                RescaleEditor(settings:Binding(get:{ model.scaleSettings(pages:pages,gangID:gangID,jobIndex:jobIndex) ?? current },set:{ model.setScale($0,pages:pages,gangID:gangID,jobIndex:jobIndex) }),sourceSize:size)
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
        if let gangID { return project.gang?.jobs.first { $0.id == gangID }?.rescale }
        return project.rescaleJobs?.last { ($0.jobIndex == nil || $0.jobIndex == jobIndex) && !$0.pages.isEmpty && Set($0.pages).intersection(pages).count>0 }?.settings
    }
    func setScale(_ settings:RescaleSettings?,pages:[Int],gangID:UUID?,jobIndex:Int? = nil) {
        if let gangID { editGangJob(gangID) { $0.rescale = settings }; return }
        var jobs = project.rescaleJobs ?? []
        jobs = jobs.compactMap { job in var next = job; if next.jobIndex == jobIndex { next.pages.removeAll { pages.contains($0) } }; return next.pages.isEmpty ? nil : next }
        if let settings { jobs.append(RescaleJob(pages:pages,settings:settings,jobIndex:jobIndex)) }
        project.rescaleJobs = jobs.isEmpty ? nil : jobs
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
