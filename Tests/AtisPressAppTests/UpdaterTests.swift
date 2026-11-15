import XCTest
import CryptoKit
import SwiftUI
import AppKit
@testable import AtisPressApp

private actor MockUpdateTransport:UpdateTransport {
    var data:Data
    var requests:[URL]=[]
    init(_ data:Data) {self.data=data}
    func manifest(from url:URL) async throws -> Data {requests.append(url); return data}
    func archive(from url:URL,to destination:URL,progress:@escaping @Sendable (Double)->Void) async throws {requests.append(url); try data.write(to:destination); progress(1)}
    func count() -> Int {requests.count}
}
final class UpdaterTests:XCTestCase {
    private func directory() throws -> URL {
        let u=FileManager.default.temporaryDirectory.appendingPathComponent("Atış güncelleme ' $-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:u,withIntermediateDirectories:false)
        addTeardownBlock {try? FileManager.default.removeItem(at:u)}; return u
    }
    private func signed(_ key:Curve25519.Signing.PrivateKey,bytes:Data=Data("zip bytes".utf8),version:String="0.3.0",build:Int=4) throws -> UpdateManifest {
        var m=UpdateManifest(version:version,build:build,minimumOS:"14.0",url:"https://github.com/baturayatis/atispress/releases/download/v\(version)/AtisPress-\(version).zip",sha256:UpdateManifest.digest(bytes),signature:try key.signature(for:bytes).base64EncodedString(),notes:"Yeni özellikler\nTürkçe notlar.",publishedAt:"2026-11-15T10:00:00Z",metadataSignature:"")
        m.metadataSignature=try key.signature(for:m.signedMetadata()).base64EncodedString(); return m
    }
    private func resign(_ m:inout UpdateManifest,_ key:Curve25519.Signing.PrivateKey) throws {m.metadataSignature=try key.signature(for:m.signedMetadata()).base64EncodedString()}
    func testValidSignaturesAndEveryMetadataTamperAreRejected() throws {
        let key=Curve25519.Signing.PrivateKey(),pub=key.publicKey.rawRepresentation
        let zip=try directory().appendingPathComponent("update.zip"); try Data("zip bytes".utf8).write(to:zip)
        let m=try signed(key); try m.verifyArchive(zip,publicKey:pub)
        XCTAssertThrowsError(try m.verifyArchive(zip,publicKey:Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        let changes:[(inout UpdateManifest)->Void] = [{$0.version="99.0.0"},{$0.build=99},{$0.minimumOS="99.0"},{$0.url="https://evil.invalid/update.zip"},{$0.sha256=String(repeating:"0",count:64)},{$0.signature="AAAA"},{$0.notes="Değişti"},{$0.publishedAt="2026-11-16T10:00:00Z"}]
        for change in changes {var changed=m; change(&changed); XCTAssertThrowsError(try changed.verifyMetadata(publicKey:pub))}
        try Data("tampered zip".utf8).write(to:zip)
        XCTAssertThrowsError(try m.verifyArchive(zip,publicKey:pub)) {XCTAssertTrue($0.localizedDescription.contains("SHA-256"))}
        var hashUpdated=m; hashUpdated.sha256=UpdateManifest.digest(Data("tampered zip".utf8)); try resign(&hashUpdated,key)
        XCTAssertThrowsError(try hashUpdated.verifyArchive(zip,publicKey:pub)) {XCTAssertTrue($0.localizedDescription.contains("imzası"))}
    }
    func testVersionBuildAndMinimumOS() throws {
        let key=Curve25519.Signing.PrivateKey()
        var m=try signed(key,version:"0.2.1",build:3)
        XCTAssertFalse(m.isNewer(than:"0.2.1",build:3)); XCTAssertFalse(m.isNewer(than:"0.2.1",build:4))
        m.build=4; XCTAssertTrue(m.isNewer(than:"0.2.1",build:3))
        m.version="0.2.0"; m.build=999; XCTAssertFalse(m.isNewer(than:"0.2.1",build:3))
        m.version="0.10.0"; XCTAssertTrue(m.isNewer(than:"0.9.99",build:999))
        m.minimumOS="14.2"; XCTAssertFalse(m.supportsCurrentOS(.init(majorVersion:14,minorVersion:1,patchVersion:9)))
        XCTAssertTrue(m.supportsCurrentOS(.init(majorVersion:14,minorVersion:2,patchVersion:0)))
        XCTAssertFalse(UpdateManifest.validVersion("v0.3.0")); XCTAssertFalse(UpdateManifest.validVersion("0.3"))
    }
    func testMockedFetchAndEqualLowerRejectedWithoutDownload() async throws {
        let key=Curve25519.Signing.PrivateKey(),m=try signed(key)
        let transport=MockUpdateTransport(try JSONEncoder().encode(m)),client=UpdateClient(transport:transport,publicKey:key.publicKey.rawRepresentation)
        let release=try await client.check(currentVersion:"0.2.1",currentBuild:3)
        XCTAssertEqual(release,m)
        let equal=try await client.check(currentVersion:"0.3.0",currentBuild:4)
        let older=try await client.check(currentVersion:"0.4.0",currentBuild:1)
        XCTAssertNil(equal); XCTAssertNil(older)
        let count=await transport.count(); XCTAssertEqual(count,3)
        var changed=m; changed.notes="tampered"
        let bad=UpdateClient(transport:MockUpdateTransport(try JSONEncoder().encode(changed)),publicKey:key.publicKey.rawRepresentation)
        do {_=try await bad.check(currentVersion:"0.2.1",currentBuild:3); XCTFail("Tampered JSON accepted")} catch {XCTAssertTrue(error.localizedDescription.contains("imzası"))}
    }
    func testAllowedHostsAndPathGuards() throws {
        for s in ["http://github.com/file","https://evil.invalid/file","https://github.com:444/file","https://a:b@github.com/file","file:///tmp/update.json"] {XCTAssertFalse(UpdateHTTPTransport.allowed(URL(string:s)!))}
        XCTAssertTrue(UpdateHTTPTransport.allowed(UpdateClient.manifestURL))
        for s in ["/Volumes/AtışPress/AtışPress.app","/private/var/folders/x/AppTranslocation/UUID/d/AtışPress.app"] {
            XCTAssertThrowsError(try UpdateInstaller.guardTarget(URL(fileURLWithPath:s))) {XCTAssertTrue($0.localizedDescription.contains("Uygulamalar"))}
        }
        let folder=try directory(),target=folder.appendingPathComponent("AtışPress.app")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        try UpdateInstaller.guardTarget(target)
        let link=folder.appendingPathComponent("Link.app"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        XCTAssertThrowsError(try UpdateInstaller.guardTarget(link))
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:folder.path)
        defer {try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:folder.path)}
        XCTAssertThrowsError(try UpdateInstaller.guardTarget(target))
    }
    private func app(in parent:URL,name:String,version:String,build:Int) throws -> URL {
        let app=parent.appendingPathComponent(name+".app"),contents=app.appendingPathComponent("Contents"),bin=contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
        let plist:[String:Any] = ["CFBundleIdentifier":UpdateInstaller.bundleIdentifier,"CFBundleExecutable":"TestApp","CFBundlePackageType":"APPL","CFBundleShortVersionString":version,"CFBundleVersion":String(build),"LSMinimumSystemVersion":"14.0"]
        try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at:URL(fileURLWithPath:"/usr/bin/true"),to:bin.appendingPathComponent("TestApp"))
        try UpdateInstaller.run("/usr/bin/codesign",["--force","--deep","--sign","-",app.path]); return app
    }
    func testSignedArchiveUnpacksAndBundleIdentityVersionAreChecked() throws {
        let folder=try directory(),key=Curve25519.Signing.PrivateKey()
        let source=try app(in:folder,name:"AtışPress",version:"0.3.0",build:4),zip=folder.appendingPathComponent("update.zip")
        try UpdateInstaller.run("/usr/bin/ditto",["-c","-k","--sequesterRsrc","--keepParent",source.path,zip.path])
        let m=try signed(key,bytes:Data(contentsOf:zip)); try m.verifyArchive(zip,publicKey:key.publicKey.rawRepresentation)
        let unpacked=try UpdateInstaller.unpack(zip,in:folder.appendingPathComponent("unpacked"),manifest:m,currentVersion:"0.2.1",currentBuild:3)
        try UpdateInstaller.validateBundle(unpacked,manifest:m,currentVersion:"0.2.1",currentBuild:3)
        XCTAssertThrowsError(try UpdateInstaller.validateBundle(unpacked,manifest:m,currentVersion:"0.3.0",currentBuild:4))
        var wrong=m; wrong.version="0.4.0"
        XCTAssertThrowsError(try UpdateInstaller.validateBundle(unpacked,manifest:wrong,currentVersion:"0.2.1",currentBuild:3))
        let info=unpacked.appendingPathComponent("Contents/Info.plist")
        var p=try PropertyListSerialization.propertyList(from:Data(contentsOf:info),format:nil) as! [String:Any]
        p["CFBundleIdentifier"]="wrong.bundle"
        try PropertyListSerialization.data(fromPropertyList:p,format:.xml,options:0).write(to:info)
        XCTAssertThrowsError(try UpdateInstaller.validateBundle(unpacked,manifest:m,currentVersion:"0.2.1",currentBuild:3))
    }
    func testLocalManifestAndArchiveUseNoNetworkAndKeepSignatures() async throws {
        let folder=try directory(),key=Curve25519.Signing.PrivateKey(),zip=folder.appendingPathComponent("update.zip")
        try Data("zip bytes".utf8).write(to:zip)
        var m=try signed(key); m.url=zip.absoluteString; try resign(&m,key)
        let json=folder.appendingPathComponent("update.json"); try JSONEncoder().encode(m).write(to:json)
        let transport=LocalUpdateTransport(),client=UpdateClient(transport:transport,publicKey:key.publicKey.rawRepresentation)
        let found=try await client.check(at:json,currentVersion:"0.2.1",currentBuild:3)
        XCTAssertEqual(found,m)
        let downloaded=folder.appendingPathComponent("download.zip")
        try await transport.archive(from:zip,to:downloaded,progress:{_ in})
        try m.verifyArchive(downloaded,publicKey:key.publicKey.rawRepresentation)
        do {_=try await client.check(currentVersion:"0.2.1",currentBuild:3); XCTFail("Local transport used HTTPS")} catch {}
    }
    func testInvalidCodeSignatureAndArchivePathsAreRejected() throws {
        let folder=try directory(),key=Curve25519.Signing.PrivateKey(),m=try signed(key)
        let source=try app(in:folder,name:"AtışPress",version:"0.3.0",build:4)
        try Data("modified".utf8).write(to:source.appendingPathComponent("Contents/MacOS/TestApp"))
        XCTAssertThrowsError(try UpdateInstaller.validateBundle(source,manifest:m,currentVersion:"0.2.1",currentBuild:3))
        let foreign=folder.appendingPathComponent("Unexpected.txt"),zip=folder.appendingPathComponent("foreign.zip")
        try Data("wrong root".utf8).write(to:foreign)
        try UpdateInstaller.run("/usr/bin/ditto",["-c","-k","--keepParent",foreign.path,zip.path])
        XCTAssertThrowsError(try UpdateInstaller.unpack(zip,in:folder.appendingPathComponent("foreign"),manifest:m,currentVersion:"0.2.1",currentBuild:3))
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent("foreign").path))
    }
    @MainActor func testCheckerReportsCurrentBlockedAndFailureAndConsumesInstallerResult() async throws {
        let suite="AtisPressUpdaterTests-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let key=Curve25519.Signing.PrivateKey(),m=try signed(key)
        let client=UpdateClient(transport:MockUpdateTransport(try JSONEncoder().encode(m)),publicKey:key.publicKey.rawRepresentation)
        let blocked=UpdateChecker(client:client,defaults:defaults,target:URL(fileURLWithPath:"/Volumes/Test/AtışPress.app"))
        await blocked.checkNow(); XCTAssertTrue(blocked.available); XCTAssertEqual(blocked.installBlocked,"Önce uygulamayı Uygulamalar klasörüne taşıyın")
        let current=UpdateChecker(client:client,defaults:defaults,currentVersion:"0.3.0",currentBuild:4)
        await current.checkNow(); XCTAssertEqual(current.text,"Güncelsiniz"); XCTAssertFalse(current.available)
        let bad=UpdateChecker(client:UpdateClient(transport:MockUpdateTransport(Data("invalid".utf8)),publicKey:key.publicKey.rawRepresentation),defaults:defaults)
        await bad.checkNow(); XCTAssertTrue(bad.text.contains("okunamadı")); XCTAssertFalse(bad.available)
        let folder=try directory(); defaults.set(folder.path,forKey:UpdateChecker.pendingInstallKey)
        try Data("Güncelleme başarısız; önceki uygulama geri yüklendi.".utf8).write(to:folder.appendingPathComponent("result.txt"))
        await current.checkOnLaunch(); XCTAssertTrue(current.launchNotice); XCTAssertTrue(current.text.contains("geri yüklendi"))
        XCTAssertNil(defaults.object(forKey:UpdateChecker.pendingInstallKey))
    }
    func testHelperInstallsAndRestoresOnFailuresAndRefusesReadOnlyTarget() throws {
        for mode in ["test","fail-after-backup","fail-after-install","readonly"] {
            let folder=try directory(),parent=folder.appendingPathComponent("Applications"),work=folder.appendingPathComponent("work")
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false)
            try FileManager.default.createDirectory(at:work,withIntermediateDirectories:false)
            let old=try app(in:parent,name:"AtışPress",version:"0.2.1",build:3)
            let new=try app(in:folder,name:"Yeni",version:"0.3.0",build:4)
            let script=folder.appendingPathComponent("install.sh"); try Data(UpdateInstaller.helperScript.utf8).write(to:script)
            if mode=="readonly" {try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:parent.path)}
            defer {try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:parent.path)}
            let arguments=[script.path,"2147483647",old.path,new.path,work.path,mode]
            if mode=="test" {try UpdateInstaller.run("/bin/bash",arguments)}
            else {XCTAssertThrowsError(try UpdateInstaller.run("/bin/bash",arguments))}
            let plist=try PropertyListSerialization.propertyList(from:Data(contentsOf:old.appendingPathComponent("Contents/Info.plist")),format:nil) as! [String:Any]
            XCTAssertEqual(plist["CFBundleShortVersionString"] as? String,mode=="test" ? "0.3.0" : "0.2.1",mode)
            try UpdateInstaller.run("/usr/bin/codesign",["--verify","--deep","--strict",old.path])
            if mode != "readonly" {XCTAssertTrue(FileManager.default.fileExists(atPath:work.appendingPathComponent("backup.app").path))}
        }
    }
    @MainActor func testDefaultOffDailyGateMockedCheckerAndUpdateWindowReachability() async throws {
        let suite="AtisPressUpdaterTests-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let key=Curve25519.Signing.PrivateKey(),m=try signed(key),transport=MockUpdateTransport(try JSONEncoder().encode(m))
        let folder=try directory(),target=folder.appendingPathComponent("AtışPress.app")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        let checker=UpdateChecker(client:UpdateClient(transport:transport,publicKey:key.publicKey.rawRepresentation),defaults:defaults,target:target)
        await checker.checkOnLaunch(); let zero=await transport.count(); XCTAssertEqual(zero,0)
        defaults.set(true,forKey:UpdateChecker.automaticKey)
        await checker.checkOnLaunch(); await checker.checkOnLaunch()
        let one=await transport.count(); XCTAssertEqual(one,1); XCTAssertEqual(checker.release,m); XCTAssertNil(checker.installBlocked)
        XCTAssertTrue(checker.text.contains("Yeni sürüm var: 0.3.0 (şu an 0.2.1)"))
        let tomorrow=Date().addingTimeInterval(86401)
        XCTAssertTrue(UpdateChecker.claimLaunchCheck(defaults:defaults,now:tomorrow))
        XCTAssertFalse(UpdateChecker.claimLaunchCheck(defaults:defaults,now:tomorrow))
        let model=Workspace(uiDefaults:defaults)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for scheme in [ColorScheme.light,.dark] {
            let host=NSHostingView(rootView:UpdatePanel(model:model,checker:checker).environment(\.colorScheme,scheme))
            host.appearance=NSAppearance(named:scheme == .light ? .aqua : .darkAqua)
            host.frame=CGRect(x:0,y:0,width:588,height:500); host.layoutSubtreeIfNeeded()
            let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds)); host.cacheDisplay(in:host.bounds,to:bitmap)
            let artifacts=root.appendingPathComponent(".build/WorkflowQA")
            try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
            try bitmap.representation(using:.png,properties:[:])?.write(to:artifacts.appendingPathComponent("updater-\(scheme == .light ? "light" : "dark").png"))
        }
        let entry=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/AtisPressApp.swift"))
        XCTAssertTrue(entry.contains("UpdatePanel(model:workspace")); XCTAssertTrue(entry.contains("Güncellemeleri denetle…"))
        let panel=try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/UpdateChecker.swift"))
        for title in ["Şimdi güncelle","Daha sonra","GitHub’da aç","Açılışta güncellemeyi denetle"] {XCTAssertTrue(panel.contains(title))}
    }
}
