import XCTest
import AppKit
import UniformTypeIdentifiers
import ImpositionCore
@testable import AtisPressApp

@MainActor
final class HomeScreenTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "AtisPress.HomeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func pdf(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("test.pdf")
        var media = CGRect(x: 0,y: 0,width: 210*72/25.4,height: 297*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return url
    }
    private func model(_ store: RecentFilesStore,picker: Workspace.FilePicker? = nil) -> Workspace {
        Workspace(bookmarkCreator: { try $0.bookmarkData(options: .minimalBookmark,includingResourceValuesForKeys: nil,relativeTo: nil) },
                  recentStore: store,filePicker: picker)
    }
    private func settle(_ model: Workspace) async throws {
        for _ in 0..<500 {
            if !model.loading && !model.planning && !model.autoArranging && !model.samplingBleed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Opening did not settle")
    }
    func testPDFButtonAndCommandOImportExactlyLikeDropAndRecentClick() async throws {
        let url = try pdf(in: directory()), preferences = try defaults()
        var requests: [OpenFileKind] = []
        let picker: Workspace.FilePicker = { kind,finish in requests.append(kind); finish(url) }
        let button = model(RecentFilesStore(defaults: preferences),picker: picker)
        let command = model(RecentFilesStore(defaults: try defaults()),picker: picker)
        let drop = model(RecentFilesStore(defaults: try defaults()))
        button.choosePDF() // The home button action.
        command.openPanel() // The same action wired to Dosya > Aç / ⌘O.
        XCTAssertTrue(drop.acceptDrop([NSItemProvider(item: url as NSURL,typeIdentifier: UTType.fileURL.identifier)]))
        try await settle(button); try await settle(command)
        // Item-provider completion may arrive after the first idle check.
        for _ in 0..<500 {
            if drop.source != nil || drop.error != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await settle(drop)
        XCTAssertEqual(requests,[.pdf,.any])
        let recent = model(RecentFilesStore(defaults: preferences))
        recent.openRecent(try XCTUnwrap(recent.recentFiles.first))
        try await settle(recent)
        for workspace in [button,command,drop,recent] {
            XCTAssertNil(workspace.error)
            XCTAssertEqual(workspace.source?.url.standardizedFileURL,url.standardizedFileURL)
            XCTAssertEqual(workspace.project,button.project)
            XCTAssertEqual(workspace.plan.sheets,button.plan.sheets)
            XCTAssertTrue(workspace.canExportNow)
            XCTAssertEqual(workspace.recentFiles.map(\.url),[url])
            XCTAssertTrue(workspace.recentFiles[0].isAvailable)
        }
    }
    func testTypedPickersFilterFilesAndCancellationDoesNotImport() throws {
        let store = RecentFilesStore(defaults: try defaults())
        var requests: [OpenFileKind] = []
        let workspace = model(store) { kind,finish in requests.append(kind); finish(nil) }
        let original = workspace.project
        workspace.choosePDF(); workspace.chooseProject(); workspace.openPanel()
        XCTAssertEqual(requests,[.pdf,.project,.any])
        XCTAssertEqual(OpenFileKind.pdf.contentTypes,[.pdf])
        XCTAssertEqual(OpenFileKind.project.contentTypes,[.projectFile])
        XCTAssertEqual(OpenFileKind.any.contentTypes,[.pdf,.projectFile])
        XCTAssertNil(workspace.source); XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.project,original); XCTAssertFalse(workspace.isModified)
        XCTAssertTrue(workspace.recentFiles.isEmpty)
        let wrong = model(store) { _,finish in finish(URL(fileURLWithPath: "/tmp/not-a-pdf.atispress")) }
        wrong.choosePDF()
        XCTAssertFalse(wrong.loading); XCTAssertNil(wrong.source); XCTAssertTrue(wrong.recentFiles.isEmpty)
    }
    func testProjectButtonRestoresSavedProjectAndRecordsIt() async throws {
        let store = RecentFilesStore(defaults: try defaults()), folder = try directory()
        let original = model(store)
        original.project.exportMarks.sheetInfo = true
        let url = folder.appendingPathComponent("saved.atispress")
        try original.saveProject(as: url)
        var request: OpenFileKind?
        let restored = model(store) { kind,finish in request = kind; finish(url) }
        restored.chooseProject()
        try await settle(restored)
        XCTAssertEqual(request,.project)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.projectURL,url)
        XCTAssertEqual(restored.project,original.project)
        XCTAssertFalse(restored.isModified)
        XCTAssertEqual(restored.recentFiles.map(\.url),[url])
    }
    func testHistoryKeepsLastFiveDeduplicatesPersistsAndRetainsMissingFiles() throws {
        let preferences = try defaults(), folder = try directory()
        let store = RecentFilesStore(defaults: preferences)
        let files = (0..<7).map { folder.appendingPathComponent("file-\($0)."+($0%2 == 0 ? "pdf" : "atispress")) }
        for url in files { try Data("test".utf8).write(to: url); store.record(url,bookmark: nil) }
        XCTAssertEqual(store.files().map(\.url),Array(files[2...6].reversed()))
        store.record(files[4],bookmark: nil)
        let order = [files[4],files[6],files[5],files[3],files[2]]
        XCTAssertEqual(store.files().map(\.url),order)
        let reloaded = RecentFilesStore(defaults: preferences)
        XCTAssertEqual(reloaded.files().map(\.url),order)
        try FileManager.default.removeItem(at: files[4])
        let workspace = model(reloaded)
        let missing = try XCTUnwrap(workspace.recentFiles.first)
        XCTAssertFalse(missing.isAvailable)
        XCTAssertEqual(workspace.recentFiles.count,5)
        workspace.openRecent(missing)
        XCTAssertFalse(workspace.loading); XCTAssertNil(workspace.error); XCTAssertNil(workspace.source)
        try Data("returned".utf8).write(to: files[4])
        workspace.refreshRecentFiles()
        XCTAssertTrue(workspace.recentFiles[0].isAvailable)
        XCTAssertEqual(workspace.recentFiles.map(\.url),order)
    }
    func testFailedImportDoesNotDisplaceHistory() async throws {
        let store = RecentFilesStore(defaults: try defaults()), folder = try directory()
        let valid = try pdf(in: folder)
        store.record(valid,bookmark: nil)
        let invalid = folder.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        let workspace = model(store) { _,finish in finish(invalid) }
        workspace.choosePDF()
        try await settle(workspace)
        XCTAssertNotNil(workspace.error); XCTAssertNil(workspace.source)
        XCTAssertEqual(workspace.recentFiles.map(\.url),[valid])
    }
}
