import Foundation

struct RecoveryRecord: Codable, Identifiable {
    var version = 1
    var id: UUID
    var savedAt = Date()
    var originalProjectPath: String?
    var document: ProjectDocument
}
struct RecoveryStore {
    static var supportDirectory: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AtisPress",isDirectory:true)
    }
    var directory = supportDirectory.appendingPathComponent("Recovery",isDirectory:true)
    func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString+".recovery.json") }
    func write(_ record: RecoveryRecord) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to:url(record.id),options:.atomic)
    }
    func remove(_ id: UUID) throws { if FileManager.default.fileExists(atPath:url(id).path) { try FileManager.default.removeItem(at:url(id)) } }
    func records() throws -> [RecoveryRecord] {
        guard FileManager.default.fileExists(atPath:directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasSuffix(".recovery.json") }.map { url in
            let record = try JSONDecoder().decode(RecoveryRecord.self,from:Data(contentsOf:url))
            guard record.version==1 else { throw ProjectFileError.invalidSelection }
            _ = try ProjectDocument.decode(record.document.encoded())
            return record
        }.sorted { $0.savedAt>$1.savedAt }
    }
}
