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
    func replaceManifest(_ replacement: Data) { data = replacement }
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
        let blocked=UpdateChecker(client:client,defaults:defaults,target:URL(fileURLWithPath:"/Volumes/Test/AtışPress.app"),currentVersion:"0.2.1",currentBuild:3)
        blocked.setAutomaticConsent(false)
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
    @MainActor func testLaunchConsentPersistsAndDeclineStillAllowsManualCheck() async throws {
        let suite = "AtisPressConsent-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let key = Curve25519.Signing.PrivateKey()
        let transport = MockUpdateTransport(try JSONEncoder().encode(signed(key)))
        let client = UpdateClient(transport:transport,publicKey:key.publicKey.rawRepresentation)
        let checker = UpdateChecker(client:client,defaults:defaults,currentVersion:"0.2.1",currentBuild:3)
        XCTAssertNil(checker.automaticConsent)
        let unasked = await checker.checkOnLaunch()
        await checker.checkNow()
        XCTAssertNil(unasked)
        let none = await transport.count()
        XCTAssertEqual(none,0)

        checker.setAutomaticConsent(false)
        let reopened = UpdateChecker(client:client,defaults:defaults,currentVersion:"0.2.1",currentBuild:3)
        XCTAssertEqual(reopened.automaticConsent,false)
        let declined = await reopened.checkOnLaunch()
        XCTAssertNil(declined)
        let stillNone = await transport.count()
        XCTAssertEqual(stillNone,0)
        await reopened.checkNow()
        let manual = await transport.count()
        XCTAssertEqual(manual,1)
        XCTAssertTrue(reopened.available)

        reopened.setAutomaticConsent(true)
        let allowed = UpdateChecker(client:client,defaults:defaults,currentVersion:"0.2.1",currentBuild:3)
        XCTAssertEqual(allowed.automaticConsent,true)
        let notification = await allowed.checkOnLaunch()
        XCTAssertEqual(notification,.release)
    }

    @MainActor func testLaunchReminderSkipAndVerifiedCacheAcrossRelaunches() async throws {
        let suite = "AtisPressReminder-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let key = Curve25519.Signing.PrivateKey()
        let transport = MockUpdateTransport(try JSONEncoder().encode(signed(key)))
        let client = UpdateClient(transport:transport,publicKey:key.publicKey.rawRepresentation)
        func reopen() -> UpdateChecker {
            UpdateChecker(client:client,defaults:defaults,
                target:URL(fileURLWithPath:"/private/var/folders/x/AppTranslocation/UUID/d/AtışPress.app"),
                currentVersion:"0.2.1",currentBuild:3)
        }
        let start = Date(timeIntervalSince1970:1_800_000_000)
        let first = reopen()
        first.setAutomaticConsent(true)
        let initial = await first.checkOnLaunch(now:start)
        XCTAssertEqual(initial,.release)
        XCTAssertNotNil(first.installBlocked)
        XCTAssertEqual(first.badgeTitle,"Güncelleme var: 0.3.0")
        first.remindLater(now:start.addingTimeInterval(60))

        let early = reopen()
        let snoozed = await early.checkOnLaunch(now:start.addingTimeInterval(86_402))
        XCTAssertNil(snoozed)
        XCTAssertEqual(early.badgeTitle,"Güncelleme var: 0.3.0")
        let remaining = reopen()
        let reminded = await remaining.checkOnLaunch(now:start.addingTimeInterval(86_460))
        XCTAssertEqual(reminded,.release)
        let dailyRequests = await transport.count()
        XCTAssertEqual(dailyRequests,2)

        remaining.skipRelease()
        let skipped = reopen()
        let muted = await skipped.checkOnLaunch(now:start.addingTimeInterval(86_461))
        XCTAssertNil(muted)
        XCTAssertNil(skipped.badgeTitle)
        await skipped.checkNow()
        XCTAssertEqual(skipped.release?.version,"0.3.0")
        skipped.resetSkippedRelease()
        XCTAssertNil(reopen().skippedVersion)
        XCTAssertEqual(skipped.badgeTitle,"Güncelleme var: 0.3.0")
        skipped.skipRelease()

        await transport.replaceManifest(try JSONEncoder().encode(signed(key,version:"0.4.0",build:5)))
        let newer = reopen()
        let updated = await newer.checkOnLaunch(now:start.addingTimeInterval(172_805))
        XCTAssertEqual(updated,.release)
        XCTAssertEqual(newer.badgeTitle,"Güncelleme var: 0.4.0")
    }

    @MainActor func testLaunchStaysQuietForCurrentAndRejectedMetadataAndThrottlesFailure() async throws {
        let suite = "AtisPressQuietLaunch-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let key = Curve25519.Signing.PrivateKey()
        let manifest = try signed(key)
        let transport = MockUpdateTransport(try JSONEncoder().encode(manifest))
        let client = UpdateClient(transport:transport,publicKey:key.publicKey.rawRepresentation)
        let checker = UpdateChecker(client:client,defaults:defaults,currentVersion:"0.3.0",currentBuild:4)
        checker.setAutomaticConsent(true)
        let now = Date(timeIntervalSince1970:1_800_000_000)
        let current = await checker.checkOnLaunch(now:now)
        XCTAssertNil(current)
        XCTAssertEqual(checker.text,"Güncelsiniz")
        XCTAssertNil(checker.badgeTitle)
        var forged = try signed(key,version:"0.4.0",build:5)
        forged.notes += " Değiştirilmiş not."
        await transport.replaceManifest(try JSONEncoder().encode(forged))
        let failed = await checker.checkOnLaunch(now:now.addingTimeInterval(86_400))
        XCTAssertNil(failed)
        XCTAssertNil(checker.badgeTitle)
        XCTAssertTrue(checker.text.contains("imzası"))
        let retriedTooSoon = await checker.checkOnLaunch(now:now.addingTimeInterval(86_401))
        XCTAssertNil(retriedTooSoon)
        let requestCount = await transport.count()
        XCTAssertEqual(requestCount,2)
    }

    @MainActor func testLaunchPresentationBlockersAndNotificationEntryPoints() throws {
        let workspace = Workspace()
        XCTAssertFalse(workspace.hasPendingUpdatePresentationBlocker)
        workspace.preparingExport = true
        XCTAssertTrue(workspace.hasPendingUpdatePresentationBlocker)
        workspace.preparingExport = false
        workspace.showingPageSplit = true
        XCTAssertTrue(workspace.hasPendingUpdatePresentationBlocker)
        workspace.showingPageSplit = false
        workspace.error = "Deneme"
        XCTAssertTrue(workspace.hasPendingUpdatePresentationBlocker)
        let delegate = AppDelegate()
        delegate.workspace = workspace
        XCTAssertFalse(delegate.canPresentUpdateWindow)

        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/AtisPressApp.swift"))
        XCTAssertTrue(app.contains("updates.helpBadge"))
        XCTAssertTrue(app.contains("TeamPDFImportSettings(settings:workspace.ui,updates:updates)"))
        let workspaceView = try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/WorkspaceView.swift"))
        XCTAssertTrue(workspaceView.contains("UpdateToolbarBadge(checker:"))
    }

    @MainActor func testDefaultOffDailyGateMockedCheckerAndUpdateWindowReachability() async throws {
        let suite="AtisPressUpdaterTests-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let key=Curve25519.Signing.PrivateKey(),m=try signed(key),transport=MockUpdateTransport(try JSONEncoder().encode(m))
        let folder=try directory(),target=folder.appendingPathComponent("AtışPress.app")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        let checker=UpdateChecker(client:UpdateClient(transport:transport,publicKey:key.publicKey.rawRepresentation),defaults:defaults,target:target,currentVersion:"0.2.1",currentBuild:3)
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

extension UpdaterTests {
    func testDocumentAndReleaseDittoArchivesAcceptNFCAndNFDWithMetadata() throws {
        let previous=getenv("LC_ALL").map{String(cString:$0)}
        setenv("LC_ALL","C",1)
        defer {if let previous {setenv("LC_ALL",previous,1)} else {unsetenv("LC_ALL")}}
        let key=Curve25519.Signing.PrivateKey()
        for form in ["NFC","NFD"] {
            for producer in ["document","release"] {
                let folder=try directory()
                let name=form=="NFC" ? "AtışPress".precomposedStringWithCanonicalMapping : "AtışPress".decomposedStringWithCanonicalMapping
                let source=try app(in:folder,name:name,version:"0.3.0",build:4)
                try UpdateInstaller.run("/usr/bin/xattr",["-w","com.atispress.fixture","metadata",source.appendingPathComponent("Contents/Info.plist").path])
                let zip=folder.appendingPathComponent(producer+".zip")
                // Exact original doc/release format, deliberately retaining AppleDouble.
                try UpdateInstaller.run("/usr/bin/ditto",["-c","-k","--sequesterRsrc","--keepParent",form=="NFC" ? source.path.precomposedStringWithCanonicalMapping : source.path.decomposedStringWithCanonicalMapping,zip.path])
                let m=try signed(key,bytes:Data(contentsOf:zip))
                try m.verifyArchive(zip,publicKey:key.publicKey.rawRepresentation)
                let result=try UpdateInstaller.unpack(zip,in:folder.appendingPathComponent("unpacked"),manifest:m,currentVersion:"0.2.1",currentBuild:3)
                XCTAssertEqual(result.lastPathComponent.precomposedStringWithCanonicalMapping,"AtışPress.app")
                XCTAssertFalse(FileManager.default.fileExists(atPath:result.deletingLastPathComponent().appendingPathComponent("__MACOSX").path))
            }
        }
    }
}

extension UpdaterTests {
    func testCurrentReleaseAndDocumentFormatsAndReleaseVerificationGate() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder=try directory(),tool=folder.appendingPathComponent("release-tool")
        let sources=["UpdateManifest.swift","UpdateArchive.swift","UpdateArchiveAudit.swift","UpdateInstaller.swift"].map{root.appendingPathComponent("Sources/AtisPressApp/"+$0).path}
        try UpdateInstaller.run("/usr/bin/xcrun",["swiftc"]+sources+[root.appendingPathComponent("scripts/ReleaseTool/main.swift").path,"-o",tool.path])
        let flags=["-c","-k","--norsrc","--noextattr","--noacl","--noqtn","--keepParent"]
        let key=Curve25519.Signing.PrivateKey(),info=folder.appendingPathComponent("public.plist")
        try PropertyListSerialization.data(fromPropertyList:["AtisPressUpdatePublicKey":key.publicKey.rawRepresentation.base64EncodedString()],format:.xml,options:0).write(to:info)
        for form in ["NFC","NFD"] {
            for producer in ["document","release"] {
                let work=folder.appendingPathComponent(form+producer);try FileManager.default.createDirectory(at:work,withIntermediateDirectories:false)
                let source=try app(in:work,name:form=="NFC" ? "AtışPress".precomposedStringWithCanonicalMapping : "AtışPress".decomposedStringWithCanonicalMapping,version:"0.3.0",build:4)
                try UpdateInstaller.run("/usr/bin/xattr",["-w","com.atispress.fixture","metadata",source.appendingPathComponent("Contents/Info.plist").path])
                let zip=work.appendingPathComponent("update.zip"),json=work.appendingPathComponent("update.json")
                try UpdateInstaller.run("/usr/bin/ditto",flags+[form=="NFC" ? source.path.precomposedStringWithCanonicalMapping : source.path.decomposedStringWithCanonicalMapping,zip.path])
                let archive=try UpdateArchive(url:zip)
                XCTAssertTrue(archive.entries.allSatisfy{!$0.skipped})
                let m=try signed(key,bytes:Data(contentsOf:zip));try JSONEncoder().encode(m).write(to:json)
                try UpdateInstaller.run(tool.path,["verify",zip.path,json.path,info.path])
                var changed=m;changed.notes="tampered";try JSONEncoder().encode(changed).write(to:json)
                XCTAssertThrowsError(try UpdateInstaller.run(tool.path,["verify",zip.path,json.path,info.path]))
            }
        }
        let wrong=try app(in:folder,name:"Other",version:"0.3.0",build:4),badZip=folder.appendingPathComponent("bad.zip"),badJSON=folder.appendingPathComponent("bad.json")
        try UpdateInstaller.run("/usr/bin/ditto",flags+[wrong.path,badZip.path])
        try JSONEncoder().encode(signed(key,bytes:Data(contentsOf:badZip))).write(to:badJSON)
        XCTAssertThrowsError(try UpdateInstaller.run(tool.path,["verify",badZip.path,badJSON.path,info.path]))
        XCTAssertTrue(try String(contentsOf:folder.appendingPathComponent("install.log")).contains("Other.app/"))
        let release=try String(contentsOf:root.appendingPathComponent("scripts/make_release.sh")),doc=try String(contentsOf:root.appendingPathComponent("docs/UPDATER.md"))
        let format="ditto "+flags.joined(separator:" ")
        let packager=try String(contentsOf:root.appendingPathComponent("scripts/package_update_zip.sh"))
        XCTAssertTrue(packager.contains(format));XCTAssertTrue(release.contains("./scripts/package_update_zip.sh"));XCTAssertTrue(doc.contains("./scripts/package_update_zip.sh"))
        let verification=try XCTUnwrap(release.range(of:"\"$bin_dir/release-tool\" verify")),upload=try XCTUnwrap(release.range(of:"gh release create"))
        XCTAssertLessThan(verification.lowerBound,upload.lowerBound);XCTAssertTrue(release.contains("set -euo pipefail"))
    }
}

extension UpdaterTests {
    @MainActor func testInstallFailureShowsOffendingPathAndKeepsLogAfterCleanup() async throws {
        let folder=try directory(),key=Curve25519.Signing.PrivateKey()
        let wrong=try app(in:folder,name:"Other",version:"0.3.0",build:4),zip=folder.appendingPathComponent("bad.zip"),json=folder.appendingPathComponent("update.json")
        try UpdateInstaller.run("/usr/bin/ditto",["-c","-k","--norsrc","--noextattr","--noacl","--noqtn","--keepParent",wrong.path,zip.path])
        var m=try signed(key,bytes:Data(contentsOf:zip));m.url=zip.absoluteString;try resign(&m,key)
        try JSONEncoder().encode(m).write(to:json)
        let target=folder.appendingPathComponent("AtışPress.app");try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        let suite="AtisPressArchiveFailure-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let checker=UpdateChecker(client:UpdateClient(transport:LocalUpdateTransport(),publicKey:key.publicKey.rawRepresentation),manifestURL:json,defaults:defaults,target:target,currentVersion:"0.2.1",currentBuild:3)
        checker.setAutomaticConsent(false)
        await checker.checkNow();XCTAssertTrue(checker.available);XCTAssertNil(checker.installBlocked)
        checker.install(model:Workspace(uiDefaults:defaults))
        for _ in 0..<1000 {if !checker.busy {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(checker.busy);XCTAssertTrue(checker.text.contains("Other.app/"))
        let line=try XCTUnwrap(checker.text.components(separatedBy:"\n").first(where:{$0.hasPrefix("Ayrıntılar: ")}))
        let log=URL(fileURLWithPath:String(line.dropFirst("Ayrıntılar: ".count)))
        addTeardownBlock{try? FileManager.default.removeItem(at:log.deletingLastPathComponent())}
        XCTAssertTrue(try String(contentsOf:log).contains("Other.app/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:log.deletingLastPathComponent().appendingPathComponent("update.zip").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:log.deletingLastPathComponent().appendingPathComponent("unpacked").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:target.path))
    }
}

extension UpdaterTests {
    func testPackagedAtisPressExecutableMatchesDeclaredUnzipAndDecodedBytes() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Use the actual app product built by swift test, not /usr/bin/true or
        // data compressed by the same library as our decoder.
        let binary=Bundle(for:UpdaterTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AtisPressApp")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:binary.path),binary.path)
        let key=Curve25519.Signing.PrivateKey()
        for form in ["NFC","NFD"] {
            let folder=try directory(),name=form=="NFC" ? "AtışPress".precomposedStringWithCanonicalMapping : "AtışPress".decomposedStringWithCanonicalMapping
            let source=try app(in:folder,name:name,version:"0.3.0",build:4),contents=source.appendingPathComponent("Contents")
            try FileManager.default.removeItem(at:contents.appendingPathComponent("MacOS/TestApp"))
            try FileManager.default.copyItem(at:binary,to:contents.appendingPathComponent("MacOS/AtisPressApp"))
            var info=try PropertyListSerialization.propertyList(from:Data(contentsOf:contents.appendingPathComponent("Info.plist")),format:nil) as! [String:Any]
            info["CFBundleExecutable"]="AtisPressApp"
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
            try UpdateInstaller.run("/usr/bin/codesign",["--force","--deep","--sign","-",source.path])
            let zip=folder.appendingPathComponent("update.zip")
            try UpdateInstaller.run("/bin/bash",[root.appendingPathComponent("scripts/package_update_zip.sh").path,source.path,zip.path])
            let m=try signed(key,bytes:Data(contentsOf:zip));try m.verifyArchive(zip,publicKey:key.publicKey.rawRepresentation)
            let audit=try UpdateArchiveAudit.inspect(zip)
            XCTAssertEqual(audit.declared,audit.unzip);XCTAssertEqual(audit.unzip,audit.decoded)
            XCTAssertGreaterThan(audit.calls,1,"Fixture must exercise the final-output drain: \(audit.report)")
            XCTAssertLessThan(audit.firstCall,audit.decoded)
            let archive=try UpdateArchive(url:zip),entry=try XCTUnwrap(archive.entries.first{$0.path=="AtışPress.app/Contents/MacOS/AtisPressApp"})
            // Re-signing may change signature bytes, so compare with the packaged source.
            XCTAssertEqual(try archive.contents(entry),try Data(contentsOf:contents.appendingPathComponent("MacOS/AtisPressApp")))
            _ = try UpdateInstaller.unpack(zip,in:folder.appendingPathComponent("unpacked"),manifest:m,currentVersion:"0.2.1",currentBuild:3)
        }
    }
}


extension UpdaterTests {
    func testManifestHTTPFailuresShowStatusAndPublicationGuidance() throws {
        let url=UpdateClient.manifestURL
        for code in [200,401,403,404,429,500,503,302,204] {
            let response=try XCTUnwrap(HTTPURLResponse(url:url,statusCode:code,httpVersion:"HTTP/1.1",headerFields:nil))
            if code==200 {
                XCTAssertNoThrow(try UpdateHTTPTransport.validateManifestResponse(response))
            } else {
                XCTAssertThrowsError(try UpdateHTTPTransport.validateManifestResponse(response)) {error in
                    XCTAssertTrue(error.localizedDescription.contains("HTTP \(code)"))
                    if code==404 {XCTAssertTrue(error.localizedDescription.contains("update.json"))}
                }
            }
        }
        XCTAssertThrowsError(try UpdateHTTPTransport.validateManifestResponse(URLResponse(url:url,mimeType:nil,expectedContentLength:0,textEncodingName:nil)))
    }
}
