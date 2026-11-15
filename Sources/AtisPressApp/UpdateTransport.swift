import Foundation

protocol UpdateTransport {
    func manifest(from url:URL) async throws -> Data
    func archive(from url:URL,to destination:URL,progress:@escaping @Sendable (Double)->Void) async throws
}
/// Ephemeral, GET-only transport. No cookies, credentials, analytics or project data.
class UpdateHTTPTransport:NSObject,UpdateTransport,URLSessionTaskDelegate {
    static let hosts:Set<String> = ["github.com","objects.githubusercontent.com","release-assets.githubusercontent.com"]
    static func allowed(_ url:URL) -> Bool { url.scheme=="https" && hosts.contains(url.host ?? "") && url.user==nil && url.password==nil && (url.port==nil || url.port==443) }
    static func configuration() -> URLSessionConfiguration {
        let c=URLSessionConfiguration.ephemeral; c.httpCookieStorage=nil; c.httpShouldSetCookies=false
        c.urlCredentialStorage=nil; c.urlCache=nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest=30; c.timeoutIntervalForResource=1800
        return c
    }
    func manifest(from url:URL) async throws -> Data {
        guard Self.allowed(url) else { throw UpdateFailure("Güncelleme adresi güvenilir değil.") }
        let session=URLSession(configuration:Self.configuration(),delegate:self,delegateQueue:nil)
        defer {session.invalidateAndCancel()}
        var request=URLRequest(url:url); request.httpMethod="GET"; request.setValue("application/json",forHTTPHeaderField:"Accept")
        // Stream and cap the manifest before allocating the complete body.
        let (bytes,response)=try await session.bytes(for:request)
        try Self.validateManifestResponse(response)
        var data=Data()
        for try await byte in bytes { guard data.count<512_000 else { throw UpdateFailure("Güncelleme bilgisi çok büyük.") }; data.append(byte) }
        return data
    }
    static func validateManifestResponse(_ response:URLResponse) throws {
        guard let http=response as? HTTPURLResponse else {
            throw UpdateFailure("Güncelleme sunucusundan geçerli bir HTTP yanıtı alınamadı.")
        }
        switch http.statusCode {
        case 200:
            return
        case 404:
            throw UpdateFailure("Güncelleme dosyası bulunamadı (HTTP 404). GitHub’daki son sürüme update.json dosyası eklenmeli.")
        case 401,403:
            throw UpdateFailure("Güncelleme dosyasına erişim engellendi (HTTP \(http.statusCode)). GitHub sürümünün herkese açık olduğunu kontrol edin.")
        case 429:
            throw UpdateFailure("Güncelleme sunucusunun istek sınırına ulaşıldı (HTTP 429). Daha sonra yeniden deneyin.")
        case 500...599:
            throw UpdateFailure("Güncelleme sunucusu geçici bir hata verdi (HTTP \(http.statusCode)). Daha sonra yeniden deneyin.")
        default:
            throw UpdateFailure("Güncelleme bilgisi alınamadı (HTTP \(http.statusCode)).")
        }
    }
    func archive(from url:URL,to destination:URL,progress:@escaping @Sendable (Double)->Void) async throws {
        guard Self.allowed(url) else { throw UpdateFailure("İndirme adresi güvenilir değil.") }
        try await UpdateDownload.download(url,to:destination,progress:progress)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {
        completionHandler(request.url.map(Self.allowed)==true ? request : nil)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping (URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge,nil)
    }
}
private final class UpdateDownload:UpdateHTTPTransport,URLSessionDownloadDelegate {
    private var continuation:CheckedContinuation<Void,Error>?
    private let destination:URL
    private let progress:@Sendable (Double)->Void
    private var downloadError:Error?
    private var saved=false
    private init(destination:URL,progress:@escaping @Sendable (Double)->Void) {self.destination=destination; self.progress=progress}
    static func download(_ url:URL,to destination:URL,progress:@escaping @Sendable (Double)->Void) async throws {
        let delegate=UpdateDownload(destination:destination,progress:progress)
        let session=URLSession(configuration:configuration(),delegate:delegate,delegateQueue:nil)
        defer {session.finishTasksAndInvalidate()}
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            delegate.continuation=continuation
            let task=session.downloadTask(with:url); task.resume()
        }
    }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
        if totalBytesWritten>1_500_000_000 || totalBytesExpectedToWrite>1_500_000_000 { downloadError=UpdateFailure("Güncelleme dosyası çok büyük."); downloadTask.cancel(); return }
        progress(totalBytesExpectedToWrite>0 ? min(1,Double(totalBytesWritten)/Double(totalBytesExpectedToWrite)) : -1)
    }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {
        do {
            guard let response=downloadTask.response as? HTTPURLResponse,response.statusCode==200 else { throw UpdateFailure("Güncelleme dosyası indirilemedi (sunucu yanıtı geçersiz).") }
            let size=try location.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size>0,size<=1_500_000_000 else { throw UpdateFailure("Güncelleme dosyasının boyutu geçersiz.") }
            try FileManager.default.moveItem(at:location,to:destination); saved=true
        } catch {downloadError=error}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        if let error=downloadError ?? error {continuation?.resume(throwing:error)}
        else if saved {continuation?.resume()}
        else {continuation?.resume(throwing:UpdateFailure("Güncelleme dosyası kaydedilemedi."))}
        continuation=nil
    }
}

struct UpdateClient {
    static let manifestURL=URL(string:"https://github.com/baturayatis/atispress/releases/latest/download/update.json")!
    var transport:any UpdateTransport = UpdateHTTPTransport()
    var publicKey:Data
    func check(at url:URL = manifestURL,currentVersion:String,currentBuild:Int) async throws -> UpdateManifest? {
        let data=try await transport.manifest(from:url)
        let manifest:UpdateManifest
        do { manifest=try JSONDecoder().decode(UpdateManifest.self,from:data) }
        catch { throw UpdateFailure("Güncelleme bilgisi okunamadı veya imza alanları eksik.") }
        try manifest.verifyMetadata(publicKey:publicKey)
        guard let address=URL(string:manifest.url),address.absoluteString=="https://github.com/baturayatis/atispress/releases/download/v\(manifest.version)/AtisPress-\(manifest.version).zip" else {
            if url.isFileURL,URL(string:manifest.url)?.isFileURL==true {
                guard manifest.isNewer(than:currentVersion,build:currentBuild) else {return nil}
                guard manifest.supportsCurrentOS() else {throw UpdateFailure("Bu sürüm macOS \(manifest.minimumOS) veya üzerini gerektirir.")}
                return manifest
            }
            throw UpdateFailure("İndirme adresi AtışPress sürüm adresiyle uyuşmuyor.")
        }
        guard manifest.isNewer(than:currentVersion,build:currentBuild) else {return nil}
        guard manifest.supportsCurrentOS() else {throw UpdateFailure("Bu sürüm macOS \(manifest.minimumOS) veya üzerini gerektirir.")}
        return manifest
    }
}
/// Explicit file-only developer tests; production still uses the embedded key.
struct LocalUpdateTransport:UpdateTransport {
    func manifest(from url:URL) async throws -> Data {
        guard url.isFileURL else {throw UpdateFailure("Yerel test yalnız file:// kullanır.")}
        return try Data(contentsOf:url)
    }
    func archive(from url:URL,to destination:URL,progress:@escaping @Sendable (Double)->Void) async throws {
        guard url.isFileURL else {throw UpdateFailure("Yerel test yalnız file:// kullanır.")}
        try FileManager.default.copyItem(at:url,to:destination); progress(1)
    }
}
