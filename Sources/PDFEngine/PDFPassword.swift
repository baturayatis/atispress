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
            try await Task.detached {
                guard let document=PDFDocument(url:url) else {throw PDFReadError.unreadable}
                guard !document.isLocked || document.unlock(withPassword:password) else {throw PDFReadError.locked}
                let decrypted=PDFDocument()
                for index in 0..<document.pageCount {
                    guard let page=document.page(at:index)?.copy() as? PDFPage else {throw PDFReadError.unreadable}
                    decrypted.insert(page,at:decrypted.pageCount)
                }
                guard decrypted.write(to:output) else {throw PDFReadError.unreadable}
            }.value
            let source=try await open(output)
            source.retainUnlockedOrigin(url,folder:folder,scoped:access)
            return source
        } catch {
            if access {url.stopAccessingSecurityScopedResource()}
            try? FileManager.default.removeItem(at:folder)
            throw error
        }
    }
}
