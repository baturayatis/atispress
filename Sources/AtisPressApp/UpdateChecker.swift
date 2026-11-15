import SwiftUI

@MainActor final class UpdateChecker:ObservableObject {
    static let shared=UpdateChecker()
    static let automaticKey="atispress.updates.checkOnLaunch"
    static let pendingInstallKey="atispress.updates.pendingInstall"
    @Published private(set) var launchNotice=false
    static let lastCheckKey="atispress.updates.lastLaunchCheck"
    @Published private(set) var text="Denetlemek için Yardım menüsünü kullanın."
    @Published private(set) var release:UpdateManifest?
    @Published private(set) var busy=false
    @Published private(set) var progress:Double?
    @Published private(set) var installBlocked:String?
    var available:Bool {release != nil}
    private let client:UpdateClient
    private let manifestURL:URL
    private let defaults:UserDefaults
    private let target:URL
    private let currentVersion:String
    private let currentBuild:Int
    init(client:UpdateClient? = nil,manifestURL:URL = UpdateClient.manifestURL,defaults:UserDefaults = .standard,target:URL = Bundle.main.bundleURL,currentVersion:String = AppHelp.version,currentBuild:Int = Int(AppHelp.buildNumber) ?? 0) {
        var key=Data(base64Encoded:Bundle.main.object(forInfoDictionaryKey:"AtisPressUpdatePublicKey") as? String ?? "") ?? Data()
        var configuredClient=client,configuredURL=manifestURL
        if client==nil,let local=ProcessInfo.processInfo.environment["ATISPRESS_LOCAL_UPDATE"],let u=URL(string:local),u.isFileURL {
            configuredURL=u
            #if DEBUG
            if let override=ProcessInfo.processInfo.environment["ATISPRESS_LOCAL_UPDATE_PUBLIC_KEY"] {key=Data(base64Encoded:override) ?? Data()}
            #endif
            configuredClient=UpdateClient(transport:LocalUpdateTransport(),publicKey:key)
        }
        self.client=configuredClient ?? UpdateClient(publicKey:key); self.manifestURL=configuredURL
        self.defaults=defaults; self.target=target; self.currentVersion=currentVersion; self.currentBuild=currentBuild
    }
    static func claimLaunchCheck(defaults:UserDefaults,now:Date = Date()) -> Bool {
        guard defaults.bool(forKey:automaticKey) else {return false}
        if let previous=defaults.object(forKey:lastCheckKey) as? Date,now.timeIntervalSince(previous)<86400 {return false}
        defaults.set(now,forKey:lastCheckKey); return true
    }
    func checkOnLaunch() async {
        if let path=defaults.string(forKey:Self.pendingInstallKey) {
            let folder=URL(fileURLWithPath:path),result=folder.appendingPathComponent("result.txt")
            if let message=try? String(contentsOf:result,encoding:.utf8) {
                defaults.removeObject(forKey:Self.pendingInstallKey)
                text=message.trimmingCharacters(in:.whitespacesAndNewlines)=="installed" ? "Güncelleme kuruldu. Şu an \(currentVersion) (build \(currentBuild))." : message
                launchNotice=true; return
            }
        }
        if Self.claimLaunchCheck(defaults:defaults) {await checkNow()}
    }
    func check() {Task {await checkNow()}}
    func checkNow() async {
        guard !busy else {return}; busy=true; release=nil; launchNotice=false; installBlocked=nil; text="Denetleniyor…"
        defer {busy=false}
        guard client.publicKey.count==32 else {text="Güncelleme doğrulama anahtarı henüz ayarlanmamış. GitHub’dan elle kurabilirsiniz."; return}
        do {
            release=try await client.check(at:manifestURL,currentVersion:currentVersion,currentBuild:currentBuild)
            if let release {
                text="Yeni sürüm var: \(release.version) (şu an \(currentVersion))"
                do {try UpdateInstaller.guardTarget(target)} catch {installBlocked=error.localizedDescription}
            } else {text="Güncelsiniz"}
        } catch {text=Self.message(error)}
    }
    static func message(_ error:Error) -> String {
        if let failure=error as? UpdateFailure {return failure.message}
        if error is URLError {return "Güncelleme sunucusuna ulaşılamadı. İnternet bağlantısını kontrol edip yeniden deneyin."}
        return "Güncelleme tamamlanamadı. Dosya erişimini ve boş disk alanını kontrol edin."
    }
    func install(model:Workspace) {
        guard !busy,installBlocked==nil,let release else {return}
        busy=true; progress=0; text="Güncelleme indiriliyor…"
        Task {
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent("AtisPressUpdate-"+UUID().uuidString,isDirectory:true)
            var helperStarted=false,preserveLog=false
            defer {busy=false; progress=nil; if !helperStarted && !preserveLog {try? FileManager.default.removeItem(at:folder)}}
            do {
                try UpdateInstaller.guardTarget(target)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                let zip=folder.appendingPathComponent("update.zip")
                guard let url=URL(string:release.url) else {throw UpdateFailure("İndirme adresi geçersiz.")}
                try await client.transport.archive(from:url,to:zip) { [weak checker = self] amount in Task {@MainActor in checker?.progress=amount} }
                text="İmza ve uygulama doğrulanıyor…"; progress=nil
                let key=client.publicKey,version=currentVersion,build=currentBuild
                let app=try await Task.detached {
                    try release.verifyArchive(zip,publicKey:key)
                    return try UpdateInstaller.unpack(zip,in:folder.appendingPathComponent("unpacked"),manifest:release,currentVersion:version,currentBuild:build)
                }.value
                guard !model.preparingSource,!model.loading,!model.exporting,!model.autoArranging else {throw UpdateFailure("İşlem sürüyor. Güncellemeyi iş bittikten sonra yeniden deneyin.")}
                guard model.confirmDiscard() else {text="Güncelleme kurulumu iptal edildi."; return}
                defaults.set(folder.path,forKey:Self.pendingInstallKey)
                do {try UpdateInstaller.launchHelper(newApp:app,target:target,folder:folder)}
                catch {defaults.removeObject(forKey:Self.pendingInstallKey); throw error}
                helperStarted=true; model.closeApproved=true; text="Uygulama kapatılıp güncelleme kurulacak…"
                NSApp.terminate(nil)
            } catch {
                text=Self.message(error)
                if let log=try? UpdateInstaller.recordFailure(error,in:folder) {
                    preserveLog=true; text+="\nAyrıntılar: \(log.path)"
                    try? FileManager.default.removeItem(at:folder.appendingPathComponent("update.zip"))
                    try? FileManager.default.removeItem(at:folder.appendingPathComponent("unpacked"))
                }
            }
        }
    }
}

struct UpdatePanel:View {
    @ObservedObject var model:Workspace
    @ObservedObject var checker:UpdateChecker
    @AppStorage(UpdateChecker.automaticKey) private var automatic=false
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Güncellemeler").font(.title2.bold())
            Text(checker.text).textSelection(.enabled)
            if let release=checker.release {
                Text("Build \(release.build) · macOS \(release.minimumOS)+").font(.caption).foregroundStyle(.secondary)
                ScrollView {Text(release.notes).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}.frame(maxHeight:240)
                if let reason=checker.installBlocked {Text(reason).foregroundStyle(.orange)}
                if let progress=checker.progress {
                    if progress>=0 {ProgressView(value:progress); Text("İndiriliyor: %\(Int(progress*100))").font(.caption)}
                    else {ProgressView()}
                } else if checker.busy {ProgressView()}
                HStack {
                    if checker.installBlocked==nil {Button("Şimdi güncelle") {checker.install(model:model)}.disabled(checker.busy)}
                    Button("Daha sonra") {dismiss()}.disabled(checker.busy)
                    Link("GitHub’da aç",destination:AppHelp.releases)
                }
            } else {
                HStack {
                    Button("Yeniden denetle") {checker.check()}.disabled(checker.busy)
                    Link("GitHub’da aç",destination:AppHelp.releases)
                }
            }
            Divider()
            Toggle("Açılışta güncellemeyi denetle (günde en fazla bir kez)",isOn:$automatic)
                .accessibilityIdentifier("updates.checkOnLaunch")
            Text("Varsayılan kapalıdır. Denetleme yalnız update.json dosyasını ister; uygulama veya proje verisi göndermez. ZIP yalnız Şimdi güncelle ile indirilir.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width:540).background(Color(nsColor:.windowBackgroundColor))
    }
}
