import Foundation
import CryptoKit

/// Offline diagnostics only: does not install, access Keychain, or replace the
/// updater's mandatory signature, manifest, codesign and version checks.
enum UpdateArchiveAudit {
    struct Result {
        let path:String
        let declared:Int
        let unzip:Int
        let decoded:Int
        let firstCall:Int
        let calls:Int
        var report:String {
            "Girdi: \(path)\nZIP’te bildirilen: \(declared) bayt\nmacOS unzip: \(unzip) bayt\nUygulama: \(decoded) bayt\nİlk açıcı çağrısı: \(firstCall) bayt; çağrı sayısı: \(calls)\nBayt sayıları ve SHA-256 içerikleri eşit.\nBu tanı kurulum yapmaz; güncelleme imzası doğrulamasının yerine geçmez."
        }
    }
    static func inspect(_ zip:URL) throws -> Result {
        let archive=try UpdateArchive(url:zip)
        guard let entry=archive.entries.first(where:{$0.path=="AtışPress.app/Contents/MacOS/AtisPressApp" && !$0.skipped && $0.kind==0o100000}) else {
            throw UpdateArchive.failure("AtışPress.app/Contents/MacOS/AtisPressApp","yürütülebilir bulunamadı")
        }
        var first:Int?,calls=0
        let bytes=try archive.contents(entry) { step in
            if first==nil {first=step.produced}; calls=step.call
        }
        // Only run the system decoder after our bounded reader has checked the
        // stream size and CRC. Keep its output bounded independently as well.
        let process=Process(),pipe=Pipe()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/unzip")
        // Process may decompose Unicode argv on macOS. Use an ASCII pattern;
        // preflight has already proved that only the single expected root exists.
        process.arguments=["-p",zip.path,"At*Press.app/Contents/MacOS/AtisPressApp"]
        process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
        process.standardInput=FileHandle.nullDevice
        try process.run()
        var count=0,hash=SHA256()
        while true {
            let chunk=pipe.fileHandleForReading.readData(ofLength:1024*1024)
            if chunk.isEmpty {break}
            count+=chunk.count
            guard count<=entry.size else {
                process.terminate(); try? pipe.fileHandleForReading.close(); process.waitUntilExit()
                throw UpdateArchive.failure(entry.path,"macOS unzip çıktı sınırını aştı")
            }
            hash.update(data:chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus==0,count==entry.size,count==bytes.count,
              Data(hash.finalize())==Data(SHA256.hash(data:bytes)) else {
            throw UpdateArchive.failure(entry.path,"macOS unzip ve uygulama çıktıları uyuşmuyor (ZIP: \(entry.size), unzip: \(count), uygulama: \(bytes.count))")
        }
        return Result(path:entry.path,declared:entry.size,unzip:count,decoded:bytes.count,firstCall:first ?? bytes.count,calls:calls)
    }
}
