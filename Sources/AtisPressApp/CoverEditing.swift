import SwiftUI
import ImpositionCore

extension Workspace {
    var spineWidth: Double {
        get {
            if let cover = project.coverPreparation { return cover.spineWidth }
            if project.binding == .saddleStitch { return 0 }
            return bookSettings.spineWidth ?? plan.sheets.compactMap(\.bookInfo).first?.spine ?? 0
        }
        set {
            guard (0...1000).contains(newValue) else { return }
            if project.coverPreparation != nil || !(project.isBooklet || project.isLeafBinding) || project.binding == .saddleStitch {
                guard hasCoverArtworkContext else { return }
                if project.coverPreparation == nil { activateCoverSource(.firstAndLast,spineWidth:newValue) }
                else { coverPreparation.spineWidth = newValue }
                return
            }
            var book = bookSettings
            if project.book == nil { book.automaticCover = true }
            book.spineWidth = newValue
            project.book = book
        }
    }

    var coverModeForEditing: CoverMode { project.automaticCoverMode }

    func setProductionBinding(_ mode: BindingMethod) {
        guard project.binding != mode else { return }
        beginUndoGroup()
        defer { endUndoGroup() }
        setMode(mode)
        if project.isBooklet || project.isLeafBinding {
            var book = bookSettings
            book.automaticCover = true
            if book.spineWidth == nil { book.spineWidth = 0 }
            if mode != .saddleStitch { book.creepEnabled = false }
            project.book = book
            project.coverMode = project.automaticCoverMode
            sheetIndex = 0
        } else if project.book?.automaticCover == true {
            project.coverMode = .included
        }
    }

    var separateSaddleCover: Bool {
        get {
            if bookSettings.automaticCover == true { return bookSettings.separateSaddleCover == true }
            return project.book != nil && project.coverMode != .separate
        }
        set {
            var book = bookSettings
            book.automaticCover = true
            book.separateSaddleCover = newValue
            project.book = book
            project.coverMode = project.automaticCoverMode
            sheetIndex = 0
        }
    }

    var spineContent: SpineContent {
        get { bookSettings.spineContent ?? SpineContent() }
        set { bookSettings.spineContent = newValue }
    }

    func moveSpineBlock(_ position: SpineContent.Position, to offset: Point) {
        guard var block = spineContent.blocks[position] else { return }
        block.x = offset.x.rounded()
        block.y = offset.y.rounded()
        spineContent.blocks[position] = block
    }

    func coverSheetTitle(at index: Int) -> String? {
        let sheets = displaySheets
        guard sheets.indices.contains(index) else { return nil }
        if sheets[index].isPreparedCover { return "Kapak" }
        func cover(_ sheet: Sheet) -> Bool { sheet.bookInfo?.section == .cover || sheet.leafInfo?.cover == true }
        return cover(sheets[index]) ? "Kapak \(sheets[...index].filter(cover).count)" : nil
    }

    func removeCoverPDF() {
        guard let id = bookSettings.coverSourceID else { return }
        Task {
            do { try await removePageSource(id) }
            catch { self.error = error.localizedDescription }
        }
    }
}
