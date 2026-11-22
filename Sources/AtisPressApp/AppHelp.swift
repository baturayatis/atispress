import SwiftUI
import ImpositionCore

struct ReleaseVersion:Comparable {
    let numbers:[Int]
    let prerelease:String?
    init?(_ value:String) {
        var text = value.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        let base = text.split(separator:"+",maxSplits:1,omittingEmptySubsequences:false)[0].split(separator:"-",maxSplits:1,omittingEmptySubsequences:false)
        let parts = base[0].split(separator:".",omittingEmptySubsequences:false)
        guard !parts.isEmpty,parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),parts.count <= 4 else { return nil }
        numbers = parts.compactMap { Int($0) }; guard numbers.count == parts.count else { return nil }
        prerelease = base.count>1 ? String(base[1]) : nil
        if let prerelease,prerelease.isEmpty { return nil }
    }
    static func ==(a:Self,b:Self) -> Bool { !(a<b) && !(b<a) }
    static func <(a:Self,b:Self) -> Bool {
        for i in 0..<max(a.numbers.count,b.numbers.count) {
            let x = i<a.numbers.count ? a.numbers[i] : 0,y = i<b.numbers.count ? b.numbers[i] : 0
            if x != y { return x<y }
        }
        if a.prerelease == b.prerelease { return false }
        guard let x = a.prerelease else { return false }; guard let y = b.prerelease else { return true }
        let left = x.split(separator:"."),right = y.split(separator:".")
        for (l,r) in zip(left,right) where l != r {
            if let ln = Int(l),let rn = Int(r) { return ln<rn }
            if Int(l) != nil { return true }; if Int(r) != nil { return false }; return l<r
        }
        return left.count<right.count
    }
}
enum AppHelp {
    static let releases = URL(string:"https://github.com/baturayatis/atispress/releases")!
    // Test runners and swift run have their own main bundle; never report its tool version.
    private static var appBundle:Bundle? { Bundle.main.bundleIdentifier == "com.atisajans.atispress" ? .main : nil }
    static var version:String { appBundle?.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.7.1" }
    static var buildNumber:String { appBundle?.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "11" }
    static let licenseName = "Atış Ajans Kullanım Lisansı (taslak)"
    struct Release:Decodable { let tag_name:String }
    static func updateAvailable(data:Data,current:String = version) throws -> Bool {
        let release = try JSONDecoder().decode(Release.self,from:data)
        guard let latest = ReleaseVersion(release.tag_name),let installed = ReleaseVersion(current) else { throw CocoaError(.coderReadCorrupt) }
        return latest>installed
    }
    /// Only explicitly selected production objects. No source references, job names,
    /// serial templates, quote text, filenames, PDF bytes or user report text.
    static func diagnostics(project:Project,issues:[ValidationIssue]) throws -> String {
        let encoded = try JSONEncoder().encode(project)
        let original = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        var settings:[String:Any] = [:]
        for key in ["sheet","settings","exportMarks"] { settings[key] = original[key] }
        settings["production"] = project.autoLayout?.production.rawValue ?? "digital"
        settings["manualFields"] = project.autoLayout?.manualFields.map(\.rawValue).sorted() ?? []
        settings["serialFieldCount"] = project.serialFields.count + (project.gang?.jobs.reduce(0) { $0+$1.serialFields.count } ?? 0)
        let warningCodes = issues.suffix(20).map { ["code":String(describing:$0.code),"severity":String(describing:$0.severity)] }
        let payload:[String:Any] = ["appVersion":version,"macOS":ProcessInfo.processInfo.operatingSystemVersionString,"settings":settings,"recentWarnings":warningCodes]
        return String(data:try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!
    }
}
struct HelpPanel:View {
    @ObservedObject var model:Workspace
    let mode:String
    @State private var report = ""
    @ObservedObject private var checker = UpdateChecker.shared
    @State private var copied = false
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(mode).font(.title2.bold())
            if mode == "Hata bildir…" {
                TextField("Ne oldu? Beklediğiniz sonucu yazın.",text:$report,axis:.vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
                Button(copied ? "Tanı bilgisi kopyalandı" : "Tanı bilgisini kopyala") {
                    if let text = try? AppHelp.diagnostics(project:model.project,issues:model.workflowIssues) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); copied = true }
                }
                Text("Tanı kopyasında dosya yolu, PDF içeriği veya seri/QR metni bulunmaz.").font(.caption)
                Text("Açıklamanızı ve tanı bilgisini GitHub hata kaydına kendiniz ekleyebilirsiniz.").font(.caption)
                Link("Hata kayıtlarını aç",destination:URL(string:"https://github.com/baturayatis/atispress/issues")!)
            } else if mode == "AtışPress Hakkında" {
                if let icon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                }
                Text("AtışPress · \(AppHelp.version) (\(AppHelp.buildNumber))")
                Text(AppHelp.licenseName)
                Text("© 2026 Atış Ajans · Tüm hakları saklıdır.")
                Text("Lisans taslağı, uygulama satılmadan önce bir avukat tarafından incelenmelidir.").font(.caption)
                Link("GitHub sürümleri",destination:AppHelp.releases)
            } else {
                Text(checker.text)
                if checker.available { Link("Yeni sürüm var · İndir",destination:AppHelp.releases) }
            }
        }.padding(24).frame(width:500)
    }
}
