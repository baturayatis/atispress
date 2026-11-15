import Foundation
import CryptoKit
import Security

let service = "com.atisajans.atispress.update-signing"
let account = "ed25519-v1"
func fail(_ message:String) -> Never { fputs(message+"\n",stderr); exit(1) }
func query() -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account] }
func privateKey() throws -> Curve25519.Signing.PrivateKey {
    var q=query(); q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
    var value:CFTypeRef?
    let status=SecItemCopyMatching(q as CFDictionary,&value)
    guard status==errSecSuccess,let encoded=value as? Data,let text=String(data:encoded,encoding:.utf8),let bytes=Data(base64Encoded:text) else {
        throw UpdateFailure("İmzalama anahtarı Keychain’de okunamadı (\(status)). Önce make_update_key.sh çalıştırın.")
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation:bytes)
}
func plist(_ path:String) throws -> [String:Any] {
    guard let p=try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as? [String:Any] else { throw UpdateFailure("Plist okunamadı.") }; return p
}
do {
    let args=CommandLine.arguments
    guard args.count>=3 else { fail("Kullanım: release-tool keygen|check|sign <repo> [version zip output]") }
    let mode=args[1],root=URL(fileURLWithPath:args[2]), info=root.appendingPathComponent("packaging/Info.plist")
    if mode=="keygen" {
        var q=query(); q[kSecReturnAttributes as String]=true
        guard SecItemCopyMatching(q as CFDictionary,nil)==errSecItemNotFound else { fail("Keychain girdisi zaten var veya erişilemiyor. Mevcut anahtarın üzerine yazılmadı.") }
        var p=try plist(info.path)
        guard (p["AtisPressUpdatePublicKey"] as? String ?? "").isEmpty else { fail("Depoda açık anahtar zaten ayarlı. Anahtar değişimi eski kurulumları etkiler; otomatik değiştirilmedi.") }
        let key=Curve25519.Signing.PrivateKey()
        var add=query(); add[kSecValueData as String]=Data(key.rawRepresentation.base64EncodedString().utf8)
        add[kSecAttrLabel as String]="AtışPress güncelleme imzalama anahtarı — YEDEKLEYİN"
        add[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status=SecItemAdd(add as CFDictionary,nil)
        guard status==errSecSuccess else { fail("Keychain kaydı başarısız (\(status)).") }
        let pub=key.publicKey.rawRepresentation.base64EncodedString()
        p["AtisPressUpdatePublicKey"]=pub
        try PropertyListSerialization.data(fromPropertyList:p,format:.xml,options:0).write(to:info,options:.atomic)
        print("Açık anahtar (uygulama plist’ine yazıldı): \(pub)")
        print("ÖZEL ANAHTARI YEDEKLEYİN: Keychain Access → \(service) / \(account) → Parolayı göster. Base64 değeri çevrimdışı şifreli kasaya alın; terminale, dosyaya veya depoya yazmayın. Bu aygıtla sınırlı kayıt otomatik taşınmaz. Ayrıntılar: docs/UPDATER.md")
    } else if mode=="check" || mode=="sign" || mode=="sign-local" {
        let key=try privateKey(), p=try plist(info.path)
        guard p["AtisPressUpdatePublicKey"] as? String==key.publicKey.rawRepresentation.base64EncodedString() else { fail("Keychain anahtarı uygulamadaki açık anahtarla eşleşmiyor.") }
        if mode=="check" { print("Keychain ve açık anahtar eşleşiyor."); exit(0) }
        guard args.count==6,UpdateManifest.validVersion(args[3]),p["CFBundleShortVersionString"] as? String==args[3],let build=Int(p["CFBundleVersion"] as? String ?? ""),let os=p["LSMinimumSystemVersion"] as? String else { fail("Sürüm/build plist ile eşleşmiyor.") }
        let version=args[3],zip=URL(fileURLWithPath:args[4]),out=URL(fileURLWithPath:args[5])
        let releaseNotes=root.appendingPathComponent("RELEASE_NOTES.md"),changelog=root.appendingPathComponent("CHANGELOG.md")
        let notes=try String(contentsOf:FileManager.default.fileExists(atPath:releaseNotes.path) ? releaseNotes : changelog,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        let bytes=try Data(contentsOf:zip,options:.mappedIfSafe)
        var m=UpdateManifest(version:version,build:build,minimumOS:os,url:mode=="sign-local" ? zip.absoluteString : "https://github.com/baturayatis/atispress/releases/download/v\(version)/AtisPress-\(version).zip",sha256:UpdateManifest.digest(bytes),signature:try key.signature(for:bytes).base64EncodedString(),notes:notes,publishedAt:ISO8601DateFormatter().string(from:Date()),metadataSignature:"")
        m.metadataSignature=try key.signature(for:m.signedMetadata()).base64EncodedString()
        try m.verifyArchive(zip,publicKey:key.publicKey.rawRepresentation)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(m).write(to:out,options:.atomic)
        print("ZIP ve manifest imzalandı: \(out.path)")
    } else { fail("Bilinmeyen komut.") }
} catch { fail(error.localizedDescription) }
