import Foundation
import PDFKit

public enum PDFLoadReason:String,Sendable {
    case permission="Erişim izni yok"
    case password="Şifreli PDF (parola gerekli)"
    case copying="Kopyalama kısıtlı"
    case damaged="Dosya bozuk veya sayfa yok"
    case missing="Dosya bulunamadı"
    case size="Ebat uyuşmuyor"
}
public struct PDFLoadFailure:LocalizedError,Sendable {
    public let reason:PDFLoadReason
    public let fileName:String
    public let stage:String
    public let detail:String
    public var errorDescription:String? {"\(fileName) — \(reason.rawValue)"}
    public var diagnosticText:String {"\(errorDescription ?? reason.rawValue)\nAşama: \(stage)\n\(detail)"}
    public init(_ reason:PDFLoadReason,url:URL,stage:String,detail:String="") {
        self.reason=reason;fileName=url.lastPathComponent;self.stage=stage;self.detail=detail
    }
    public static func classify(_ error:Error,url:URL,stage:String)->PDFLoadFailure {
        if let failure=error as? PDFLoadFailure {return failure}
        let reason:PDFLoadReason
        switch error {
        case PDFReadError.locked:reason = .password
        case PDFReadError.copyRestricted:reason = .copying
        case PDFReadError.metadataMismatch:reason = .size
        default:
            let ns=error as NSError
            if (ns.domain==NSCocoaErrorDomain && [NSFileReadNoPermissionError,NSFileWriteNoPermissionError].contains(ns.code)) || (ns.domain==NSPOSIXErrorDomain && [1,13].contains(ns.code)) {reason = .permission}
            else if (ns.domain==NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(ns.code)) || (ns.domain==NSPOSIXErrorDomain && ns.code==2) {reason = .missing}
            else {reason = .damaged}
        }
        // Avoid underlying error strings because they can contain full paths.
        return PDFLoadFailure(reason,url:url,stage:stage,detail:"Hata alanı: \((error as NSError).domain), kod: \((error as NSError).code)")
    }
    public func writeLog(directory:URL? = nil) {
        let folder=directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AtisPress",isDirectory:true)
        let line="\(ISO8601DateFormatter().string(from:Date()))\n\(diagnosticText)\n\n"
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let url=folder.appendingPathComponent("pdf-load.log")
            if !FileManager.default.fileExists(atPath:url.path) {try Data().write(to:url)}
            let handle=try FileHandle(forWritingTo:url);defer {try? handle.close()}
            try handle.seekToEnd();try handle.write(contentsOf:Data(line.utf8))
        } catch {NSLog("AtışPress PDF tanı günlüğü yazılamadı (kod %ld).",(error as NSError).code)}
    }
}

extension PDFSource {
    /// The picked URL is retained verbatim. NFC is used only for identity comparisons.
    public static func sameFile(_ lhs:URL,_ rhs:URL)->Bool {
        lhs.standardizedFileURL.path.precomposedStringWithCanonicalMapping == rhs.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
    static func coordinatedRead<T>(_ url:URL,_ read:(URL)throws->T) throws -> T {
        // Local files need their security scope, while ubiquitous files also
        // need file coordination so the provider can materialize their contents.
        if (try? url.resourceValues(forKeys:[.isUbiquitousItemKey]).isUbiquitousItem) != true {return try read(url)}
        var coordinationError:NSError?,result:Result<T,Error>?
        NSFileCoordinator().coordinate(readingItemAt:url,options:.withoutChanges,error:&coordinationError) {coordinated in
            result=Result {try read(coordinated)}
        }
        if let result {return try result.get()}
        throw coordinationError ?? CocoaError(.fileReadUnknown) as NSError
    }
    static func readableDocument(_ url:URL,password:String="") throws -> PDFDocument {
        guard FileManager.default.fileExists(atPath:url.path) else {throw PDFLoadFailure(.missing,url:url,stage:"Dosyaya erişim")}
        guard FileManager.default.isReadableFile(atPath:url.path) else {throw PDFLoadFailure(.permission,url:url,stage:"Dosyaya erişim")}
        guard let document=PDFDocument(url:url) else {throw PDFReadError.unreadable}
        guard !document.isLocked || document.unlock(withPassword:password) else {throw PDFReadError.locked}
        guard document.pageCount>0 else {throw PDFReadError.empty}
        guard document.allowsCopying else {throw PDFReadError.copyRestricted}
        return document
    }
    public var loadingDetails:String {
        guard let document=try? Self.readableDocument(url) else {return "Çalışma PDF’si açılamadı."}
        return (originalPDFDetails.map{$0+"\n"} ?? "")+"Sayfa: \(pages.count), isEncrypted=\(document.isEncrypted), isLocked=\(document.isLocked), allowsCopying=\(document.allowsCopying), allowsPrinting=\(document.allowsPrinting)"
    }
}
