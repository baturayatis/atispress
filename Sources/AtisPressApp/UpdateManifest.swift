import Foundation
import CryptoKit

/// Shared with the offline release tool. The second signature binds all metadata,
/// including the ZIP signature, so changing JSON cannot redirect an update.
struct UpdateManifest: Codable, Equatable {
    var version:String
    var build:Int
    var minimumOS:String
    var url:String
    var sha256:String
    var signature:String
    var notes:String
    var publishedAt:String
    var metadataSignature:String

    func signedMetadata() throws -> Data {
        let fields:[String:Any] = ["version":version,"build":build,"minimumOS":minimumOS,"url":url,
            "sha256":sha256,"signature":signature,"notes":notes,"publishedAt":publishedAt]
        return try JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys,.withoutEscapingSlashes])
    }
    func verifyMetadata(publicKey:Data) throws {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation:publicKey),
              let sig = Data(base64Encoded:metadataSignature),key.isValidSignature(sig,for:try signedMetadata()) else {
            throw UpdateFailure("Güncelleme bilgisinin imzası doğrulanamadı.")
        }
        guard build>0,Self.validVersion(version),Self.validOS(minimumOS),
              sha256.count==64,sha256.allSatisfy({$0.isHexDigit}),
              !notes.isEmpty,notes.utf8.count<=200_000,ISO8601DateFormatter().date(from:publishedAt) != nil else {
            throw UpdateFailure("Güncelleme bilgisi geçersiz.")
        }
    }
    func verifyArchive(_ archive:URL,publicKey:Data) throws {
        try verifyMetadata(publicKey:publicKey)
        let bytes = try Data(contentsOf:archive,options:.mappedIfSafe)
        guard Self.digest(bytes)==sha256.lowercased() else { throw UpdateFailure("İndirilen dosyanın SHA-256 özeti uyuşmuyor.") }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation:publicKey),
              let sig = Data(base64Encoded:signature),key.isValidSignature(sig,for:bytes) else {
            throw UpdateFailure("İndirilen dosyanın imzası doğrulanamadı.")
        }
    }
    static func digest(_ bytes:Data) -> String { SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined() }
    static func validVersion(_ s:String) -> Bool {
        let parts = s.split(separator:".",omittingEmptySubsequences:false)
        return parts.count==3 && parts.allSatisfy{!$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil}
    }
    static func validOS(_ s:String) -> Bool {
        let parts = s.split(separator:".",omittingEmptySubsequences:false)
        return (1...3).contains(parts.count) && parts.allSatisfy{!$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil}
    }
    func isNewer(than version:String,build currentBuild:Int) -> Bool {
        guard Self.validVersion(self.version),Self.validVersion(version) else { return false }
        let a = self.version.split(separator:".").compactMap{Int($0)}, b = version.split(separator:".").compactMap{Int($0)}
        return a.lexicographicallyPrecedes(b) ? false : a==b ? build>currentBuild : true
    }
    func supportsCurrentOS(_ os:OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        let p = minimumOS.split(separator:".").compactMap{Int($0)}
        let needed = (0..<3).map{$0<p.count ? p[$0] : 0}
        return ![os.majorVersion,os.minorVersion,os.patchVersion].lexicographicallyPrecedes(needed)
    }
}
struct UpdateFailure:LocalizedError {
    let message:String
    init(_ message:String) { self.message=message }
    var errorDescription:String? { message }
}
