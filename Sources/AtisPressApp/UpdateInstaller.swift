import Foundation

/// No privileged helper or elevation. All paths are positional arguments, never shell code.
enum UpdateInstaller {
    static let bundleIdentifier = "com.atisajans.atispress"
    static func guardTarget(_ target:URL) throws {
        let raw=target.standardizedFileURL.path,real=target.resolvingSymlinksInPath().path
        guard target.pathExtension=="app",!raw.hasPrefix("/Volumes/"),!real.hasPrefix("/Volumes/"),
              !raw.contains("/AppTranslocation/"),!real.contains("/AppTranslocation/") else {
            throw UpdateFailure("Önce uygulamayı Uygulamalar klasörüne taşıyın")
        }
        let parent=target.deletingLastPathComponent()
        guard let values=try? parent.resourceValues(forKeys:[.volumeIsReadOnlyKey,.volumeURLKey]),
              let attrs=try? FileManager.default.attributesOfItem(atPath:parent.path) else {
            throw UpdateFailure("Önce uygulamayı Uygulamalar klasörüne taşıyın")
        }
        let mode=(attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let volume=values.volume?.standardizedFileURL.path
        guard (volume=="/" || volume=="/System/Volumes/Data"),values.volumeIsReadOnly != true,mode & 0o222 != 0,FileManager.default.isWritableFile(atPath:parent.path),
              raw==real,FileManager.default.fileExists(atPath:target.path) else {
            throw UpdateFailure("Önce uygulamayı Uygulamalar klasörüne taşıyın")
        }
    }
    @discardableResult static func run(_ executable:String,_ args:[String]) throws -> String {
        let p=Process(); p.executableURL=URL(fileURLWithPath:executable); p.arguments=args
        let pipe=Pipe(); p.standardOutput=pipe; p.standardError=pipe
        try p.run()
        let bytes=pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus==0 else { throw UpdateFailure("Güncelleme dosyası doğrulanamadı veya açılamadı (\(URL(fileURLWithPath:executable).lastPathComponent), \(p.terminationStatus)).") }
        return String(data:bytes,encoding:.utf8) ?? ""
    }
    static func validateBundle(_ app:URL,manifest:UpdateManifest,currentVersion:String,currentBuild:Int) throws {
        guard manifest.isNewer(than:currentVersion,build:currentBuild) else { throw UpdateFailure("Aynı veya daha eski sürüm kurulamaz.") }
        let file=app.appendingPathComponent("Contents/Info.plist")
        guard let data=try? Data(contentsOf:file),let p=try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
              p["CFBundleIdentifier"] as? String==bundleIdentifier,
              p["CFBundleShortVersionString"] as? String==manifest.version,
              Int(p["CFBundleVersion"] as? String ?? "")==manifest.build,
              p["LSMinimumSystemVersion"] as? String==manifest.minimumOS else { throw UpdateFailure("Uygulamanın kimliği veya sürümü güncelleme bilgisiyle uyuşmuyor.") }
        try run("/usr/bin/codesign",["--verify","--deep","--strict",app.path])
    }
    static func unpack(_ zip:URL,in folder:URL,manifest:UpdateManifest,currentVersion:String,currentBuild:Int) throws -> URL {
        var extracted=false
        do {
            let archive=try UpdateArchive(url:zip)
            let app=try archive.extract(to:folder)
            extracted=true
            try validateBundle(app,manifest:manifest,currentVersion:currentVersion,currentBuild:currentBuild)
            return app
        } catch {
            if extracted {try? FileManager.default.removeItem(at:folder)}
            _ = try? recordFailure(error,in:folder.deletingLastPathComponent())
            throw error
        }
    }
    @discardableResult static func recordFailure(_ error:Error,in folder:URL) throws -> URL {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let log=folder.appendingPathComponent("install.log")
        let line=ISO8601DateFormatter().string(from:Date())+" · "+error.localizedDescription+"\n"
        if FileManager.default.fileExists(atPath:log.path) {
            let handle=try FileHandle(forWritingTo:log); defer {try? handle.close()}
            try handle.seekToEnd(); try handle.write(contentsOf:Data(line.utf8))
        } else {try Data(line.utf8).write(to:log,options:.withoutOverwriting)}
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:log.path)
        return log
    }
    static func launchHelper(newApp:URL,target:URL,folder:URL) throws {
        try guardTarget(target)
        let script=folder.appendingPathComponent("install.sh")
        try Data(helperScript.utf8).write(to:script,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:script.path)
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/bin/bash")
        process.arguments=[script.path,String(ProcessInfo.processInfo.processIdentifier),target.path,newApp.path,folder.path,"production"]
        let log=folder.appendingPathComponent("install.log"); FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600])
        let handle=try FileHandle(forWritingTo:log); process.standardOutput=handle; process.standardError=handle; process.standardInput=FileHandle.nullDevice
        try process.run(); try? handle.close()
        // The helper lives independently and waits for normal AppKit termination.
    }
    static let helperScript = #"""
#!/bin/bash
set -euo pipefail
pid="$1"; target="$2"; source_app="$3"; work="$4"; mode="${5:-production}"
parent="$(dirname -- "$target")"
trap 'result=$?; if [[ "$result" != 0 && ! -f "$work/result.txt" ]]; then echo "Güncelleme kurulamadı; mevcut uygulama korundu. Uygulamanın konumunu ve klasör izinlerini kontrol edin." > "$work/result.txt"; fi' EXIT
case "$target" in /Volumes/*|*/AppTranslocation/*) echo 'Önce uygulamayı Uygulamalar klasörüne taşıyın'; exit 1;; esac
[[ -d "$target" && ! -L "$target" && -d "$source_app" && ! -L "$source_app" && -w "$parent" ]] || exit 1
# Recheck permission bits even when run as root in an automated test.
device=$(/usr/bin/stat -f '%d' "$parent")
root_device=$(/usr/bin/stat -f '%d' /)
data_device=$(/usr/bin/stat -f '%d' /System/Volumes/Data)
[[ "$device" == "$root_device" || "$device" == "$data_device" ]] || exit 1
permissions=$(/usr/bin/stat -f '%Lp' "$parent")
(( (8#$permissions & 0222) != 0 )) || exit 1
for ((i=0; i<300; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    /bin/sleep 1
done
if kill -0 "$pid" 2>/dev/null; then echo 'Uygulama kapanmadı; kurulum iptal edildi.' > "$work/result.txt"; exit 1; fi
stage="$(/usr/bin/mktemp -d "$parent/.atispress-update.XXXXXX")"
old_moved=0; new_moved=0; committed=0
rollback() {
    result=$?
    trap - EXIT HUP INT TERM
    if [[ "$committed" == 0 && "$old_moved" == 1 ]]; then
        if [[ "$new_moved" == 1 ]]; then /bin/rm -rf -- "$target"; fi
        if /bin/mv -- "$stage/old.app" "$target"; then
            echo 'Güncelleme başarısız; önceki uygulama geri yüklendi.' > "$work/result.txt"
            if [[ "$mode" == production ]]; then /usr/bin/open -n "$target" || true; fi
        else
            echo "Güncelleme ve geri yükleme başarısız. Yedek: $work/backup.app; eski uygulama: $stage/old.app" > "$work/result.txt"
            exit 1
        fi
    fi
    if [[ "$result" != 0 && ! -f "$work/result.txt" ]]; then echo "Güncelleme kurulamadı; mevcut uygulama korundu. Ayrıntılar: $work/install.log" > "$work/result.txt"; fi
    /bin/rm -rf -- "$stage"
    exit "$result"
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/ditto "$source_app" "$stage/new.app"
/usr/bin/codesign --verify --deep --strict "$stage/new.app"
/usr/bin/ditto "$target" "$work/backup.app"
/bin/mv -- "$target" "$stage/old.app"
old_moved=1
if [[ "$mode" == fail-after-backup ]]; then exit 1; fi
/bin/mv -- "$stage/new.app" "$target"
new_moved=1
/usr/bin/xattr -dr com.apple.quarantine "$target"
/usr/bin/codesign --verify --deep --strict "$target"
if [[ "$mode" == fail-after-install ]]; then exit 1; fi
echo "installed" > "$work/result.txt"
if [[ "$mode" == production ]]; then /usr/bin/open -n "$target"; fi
committed=1
echo "Güncelleme tamamlandı. Önceki uygulama: $work/backup.app"
"""#
}
