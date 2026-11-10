import Foundation
import ImpositionCore

@MainActor final class PricingStore: ObservableObject {
    @Published var library = PriceLibrary()
    @Published var error: String?
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AtisPress/Prices/library.json")
        if FileManager.default.fileExists(atPath:self.url.path) {
            do { library = try PriceLibrary.decode(Data(contentsOf:self.url)) } catch { self.error = error.localizedDescription }
        }
    }
    func save() {
        do { try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try library.encoded().write(to:url,options:.atomic); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func importFile(_ source: URL) throws {
        let next = try PriceLibrary.decode(Data(contentsOf:source))
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try next.encoded().write(to:url,options:.atomic)
        library = next; error = nil
    }
    func exportFile(_ destination: URL) throws { try library.encoded().write(to:destination,options:.atomic) }
}
