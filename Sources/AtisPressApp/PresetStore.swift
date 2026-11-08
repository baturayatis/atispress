import Foundation
import ImpositionCore
import PDFEngine

/// An explicit allow-list: no PDF URLs/bookmarks/pages, quantities/fire or serials.
struct PresetSettings: Codable, Equatable {
    var binding: BindingMethod
    var sheet: SheetSpec
    var alignment: BlockAlignment
    var settings: ImpositionSettings
    var exportMarks: ExportMarks
    var sheetInfo: SheetInfoSettings?
    var clipBleedToSheet: Bool
    var trimTolerance: Double
    var production: ProductionType
    var leaf: LeafBindingSettings?
    var columns: Int?
    var rows: Int?
    var allowRotation: Bool
    var arrangement: RepeatArrangement?
    var overlays: PDFRenderOptions
    init(project: Project,overlays: PDFRenderOptions) {
        binding = project.binding; sheet = project.sheet; alignment = project.blockAlignment
        settings = project.settings; exportMarks = project.exportMarks; sheetInfo = project.sheetInfo
        clipBleedToSheet = project.autoLayout?.clipBleedToSheet ?? false; trimTolerance = project.autoLayout?.trimTolerance ?? 0
        production = project.autoLayout?.production ?? .digital; leaf = project.leafBinding
        columns = project.stepAndRepeat.columns; rows = project.stepAndRepeat.rows
        allowRotation = project.stepAndRepeat.allowRotation; arrangement = project.stepAndRepeat.arrangement
        self.overlays = overlays
    }
    func apply(to project: Project,name: String) -> Project {
        var p = project
        p.binding = binding; p.sheet = sheet; p.blockAlignment = alignment
        p.settings = settings; p.exportMarks = exportMarks; p.sheetInfo = sheetInfo; p.leafBinding = leaf
        p.stepAndRepeat.columns = columns; p.stepAndRepeat.rows = rows
        p.stepAndRepeat.allowRotation = allowRotation; p.stepAndRepeat.arrangement = arrangement
        if binding == .gang {
            if p.gang == nil { p.gang = GangSettings() }
            p.gang?.mode = .automatic
            for i in p.gang?.jobs.indices ?? 0..<0 {
                p.gang?.jobs[i].bleed = settings.bleed
                p.gang?.jobs[i].generatedBleed = settings.generatedBleed
                p.gang?.jobs[i].allowRotation = allowRotation
            }
        }
        var auto = AutoLayoutSettings(); auto.production = production; auto.sheetSelection = .fixed
        auto.clipBleedToSheet = clipBleedToSheet; auto.trimTolerance = trimTolerance
        auto.presetFields = Set(AutoLayoutField.allCases); auto.presetName = name
        p.autoLayout = auto
        return p
    }
}
struct JobPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var settings: PresetSettings
}
struct PresetPack: Codable {
    var version = 1
    var presets: [JobPreset]
    static func decode(_ data: Data) throws -> PresetPack {
        let pack: PresetPack
        do { pack = try JSONDecoder().decode(PresetPack.self,from:data) } catch { throw PresetError.invalidPack }
        guard pack.version==1,pack.presets.count<=1000,Set(pack.presets.map(\.id)).count==pack.presets.count,
              pack.presets.allSatisfy({ !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) else { throw PresetError.invalidPack }
        return pack
    }
    func encoded() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]; return try e.encode(self) }
}
enum PresetError: LocalizedError {
    case invalidPack
    var errorDescription: String? { "Hazır ayar paketi geçersiz veya sürümü desteklenmiyor." }
}
@MainActor
struct PresetStore {
    var url = RecoveryStore.supportDirectory.appendingPathComponent("Presets/library.json")
    func load() throws -> [JobPreset] {
        if FileManager.default.fileExists(atPath:url.path) { return try PresetPack.decode(Data(contentsOf:url)).presets }
        let examples = Self.examples(); try save(examples); return examples
    }
    func save(_ presets: [JobPreset]) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try PresetPack(presets:presets).encoded().write(to:url,options:.atomic)
    }
    static func examples() -> [JobPreset] {
        let names = ["Kartvizit 33x48 ofset","A4 form dijital","A4 spiral form","Amerikan cilt A5 forma 4"]
        return names.enumerated().map { i,name in
            var p = Workspace.newProject()
            p.sheet = SheetSpec(preset:i == 0 ? .cm33x48 : .a4,margins:i == 0 ? Insets(left:10,right:10,top:10,bottom:10) : Insets(),gripperWidth:i == 0 ? 10 : 0,gutter:0,orientation:i == 0 || i == 3 ? .landscape : .portrait)
            p.binding = i == 2 ? .spiral : i == 3 ? .perfectBound : .stepAndRepeat
            p.settings.signatureSize = .four
            p.autoLayout?.production = i == 0 ? .offset : .digital
            if i != 0 { p.autoLayout?.trimTolerance = 0.0001; p.autoLayout?.clipBleedToSheet = true }
            p.settings.bleed = i == 0 ? 3 : 0; p.settings.generatedBleed.enabled = i == 0
            p.settings.cropMarkLength = i == 0 ? 5 : 0; p.exportMarks.crop = i == 0
            p.exportMarks.colorBar = i == 0; p.exportMarks.registrationTargets = i == 0
            if i == 2 { p.leafSettings.allowance = nil }
            return JobPreset(name:name,settings:PresetSettings(project:p,overlays:PDFRenderOptions()))
        }
    }
}
