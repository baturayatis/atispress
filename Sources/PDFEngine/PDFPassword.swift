import Foundation
import PDFKit

extension PDFSource {
    /// Passwords live only for this call. Rendering uses a private decrypted
    /// temporary copy; the project retains the original encrypted file reference.
    public static func openWithPassword(_ url:URL,password:String) async throws -> PDFSource {
        let access=url.startAccessingSecurityScopedResource()
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("atispress-unlocked-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let output=folder.appendingPathComponent("unlocked.pdf")
            let (details,pages)=try await Task.detached {
                let document=try coordinatedRead(url) {try readableDocument($0,password:password)}
                guard let original=CGPDFDocument(url as CFURL),original.isUnlocked || original.unlockWithPassword(password) else {throw PDFReadError.locked}
                let decrypted=PDFDocument()
                for index in 0..<document.pageCount {
                    let page=try copiedPage(document,original:original,index:index)
                    decrypted.insert(page,at:decrypted.pageCount)
                }
                guard decrypted.write(to:output) else {throw PDFReadError.unreadable}
                return ("Özgün PDF: isEncrypted=\(document.isEncrypted), isLocked=\(document.isLocked), allowsCopying=\(document.allowsCopying), allowsPrinting=\(document.allowsPrinting)",try pageMetadata(original))
            }.value
            let source=try await open(output)
            source.originalPDFDetails=details
            guard let written=CGPDFDocument(output as CFURL) else {throw PDFReadError.unreadable}
            try validateCopiedMetadata(source.pages,expected:pages,written:written)
            source.retainUnlockedOrigin(url,folder:folder,scoped:access,pages:pages)
            return source
        } catch {
            if access {url.stopAccessingSecurityScopedResource()}
            try? FileManager.default.removeItem(at:folder)
            throw error
        }
    }
}
