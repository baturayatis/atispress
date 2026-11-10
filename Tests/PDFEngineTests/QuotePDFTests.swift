import XCTest
import PDFKit
import ImpositionCore
import PDFEngine

final class QuotePDFTests: XCTestCase {
    func testOnePageVectorQuoteHidesCostsUnlessEnabled() throws {
        var p = Project(pages:[SourcePage(number:1,trimSize:Size(85,55))],sheet:SheetSpec(preset:.cm33x48),settings:ImpositionSettings(bleed:0,cropMarkLength:0),stepAndRepeat:StepAndRepeatSettings(quantity:100))
        var paper = PriceEntry(kind:.paper,name:"Kuşe"); paper.price = 2
        var printing = PriceEntry(kind:.digital,name:"Dijital"); printing.price = 1
        var lib = PriceLibrary(); lib.entries = [paper,printing]; lib.margin = 25; lib.vat = 20
        var s = JobCostSettings(); s.paper = PriceSelection(paper.id); s.printing = PriceSelection(printing.id)
        s.quote.company = "Atış Ajans"; s.quote.jobName = "Kartvizit"; s.quote.validity = "7 gün"; s.quote.note = "Örnek Türkçe: ı İ ş Ş ğ Ğ ü Ü ö Ö ç Ç"; p.costing = s
        let result = CostCalculator.calculate(project:p,plan:ImpositionPlanner.plan(p),library:lib)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atis-quote-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at:url) }
        for show in [false,true] {
            p.costing?.quote.showCosts = show
            try QuotePDFExporter.export(project:p,result:result,library:lib,to:url)
            let doc = try XCTUnwrap(PDFDocument(url:url)); XCTAssertEqual(doc.pageCount,1)
            let text = try XCTUnwrap(doc.string)
            XCTAssertTrue(text.contains("Kartvizit")); XCTAssertTrue(text.contains("KDV")); XCTAssertTrue(text.contains("7 gün"))
            XCTAssertEqual(text.contains("Toplam maliyet"),show); XCTAssertEqual(text.contains("Maliyet dökümü"),show)
            let page = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at:1))
            XCTAssertNil(page.dictionary?.dictionary(for:"Resources")?.dictionary(for:"XObject"))
            if show {
                let image = try XCTUnwrap(doc.page(at:0)?.thumbnail(of:NSSize(width:595,height:842),for:.mediaBox))
                let tiff = try XCTUnwrap(image.tiffRepresentation); let rep = try XCTUnwrap(NSBitmapImageRep(data:tiff))
                try rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/atis-quote-preview.png"))
            }
        }
        p.costing?.quote.validity = ""; XCTAssertThrowsError(try QuotePDFExporter.export(project:p,result:result,library:lib,to:url))
    }
}
private extension CGPDFDictionaryRef {
    func dictionary(for key: String) -> CGPDFDictionaryRef? { var value: CGPDFDictionaryRef?; CGPDFDictionaryGetDictionary(self,key,&value); return value }
}
