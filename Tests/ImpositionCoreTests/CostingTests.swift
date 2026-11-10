import XCTest
@testable import ImpositionCore

final class CostingTests: XCTestCase {
    func fixture() -> (Project,ImpositionPlan,PriceLibrary) {
        var p = Project(pages:[SourcePage(number:1,trimSize:Size(85,55))],sheet:SheetSpec(preset:.cm33x48),settings:ImpositionSettings(bleed:0,cropMarkLength:0),stepAndRepeat:StepAndRepeatSettings(quantity:100))
        let side = Side(slots:[Slot(sourcePageNumber:1,origin:Point(0,0),size:Size(85,55))])
        let layout = RepeatLayout(jobIndex:0,frontPageNumber:1,backPageNumber:2,columns:5,rows:2,requestedQuantity:100)
        let plan = ImpositionPlan(sheets:[Sheet(size:p.sheet.size,front:side,back:side,repeatCount:10,repeatLayout:layout)])
        var paper = PriceEntry(kind:.paper,name:"Kuşe"); paper.price = 2; paper.grammage = 170
        var print = PriceEntry(kind:.offset,name:"Ofset"); print.price = 100; print.platePrice = 20; print.setupPrice = 30; print.colors = 4
        var finish = PriceEntry(kind:.finishing,name:"Kesim"); finish.price = Decimal(string:"0.25"); finish.unit = .piece
        var lib = PriceLibrary(); lib.entries = [paper,print,finish]; lib.margin = 25; lib.vat = 20
        var settings = JobCostSettings(); settings.paper = PriceSelection(paper.id); settings.printing = PriceSelection(print.id); settings.finishing = [PriceSelection(finish.id)]; settings.extraWasteSheets = 2
        p.costing = settings
        return (p,plan,lib)
    }
    func testOffsetArithmeticFinishingMarginAndTax() {
        let (p,plan,lib) = fixture(); let r = CostCalculator.calculate(project:p,plan:plan,library:lib)
        // 12*2 + 8*20 + 2*30 + 24/1000*100 + 100*.25 = 271.40
        XCTAssertTrue(r.missing.isEmpty); XCTAssertEqual(r.sheets,12); XCTAssertEqual(r.cost,Decimal(string:"271.40"))
        XCTAssertEqual(r.profit,Decimal(string:"67.85")); XCTAssertEqual(r.tax,Decimal(string:"67.85")); XCTAssertEqual(r.sale,Decimal(string:"407.10")); XCTAssertEqual(r.perCopy,Decimal(string:"4.07"))
    }
    func testDigitalFrontBackVATIncludedPerThousandAndExplicitZero() {
        var (p,plan,lib) = fixture()
        lib.entries[0].price = 2400; lib.entries[0].perThousand = true; lib.entries[0].includesVAT = true
        lib.entries[1].kind = .digital; lib.entries[1].price = 1; lib.entries[1].backPrice = Decimal(string:"0.5")
        lib.margin = 0
        let r = CostCalculator.calculate(project:p,plan:plan,library:lib)
        XCTAssertEqual(r.lines[0].amount,24); XCTAssertEqual(r.cost,67); XCTAssertEqual(r.sale,Decimal(string:"80.40"))
        p.costing?.printing?.override = lib.entries[1]; p.costing?.printing?.override?.backPrice = 0
        XCTAssertNotNil(CostCalculator.calculate(project:p,plan:plan,library:lib).sale)
    }
    func testEveryMissingInputBlocksAndOverrideDoesNotMutateTable() {
        var (p,plan,lib) = fixture(); let original = lib
        p.costing?.paper?.override = lib.entries[0]; p.costing?.paper?.override?.price = 10
        XCTAssertEqual(CostCalculator.calculate(project:p,plan:plan,library:lib).lines[0].amount,120)
        XCTAssertEqual(lib,original)
        for index in lib.entries.indices {
            var missing = original; missing.entries[index].price = nil
            var clean = p; clean.costing?.paper?.override = nil
            XCTAssertNil(CostCalculator.calculate(project:clean,plan:plan,library:missing).sale)
        }
        lib.vat = nil; XCTAssertNil(CostCalculator.calculate(project:p,plan:plan,library:lib).sale)
        lib = original; lib.margin = nil; XCTAssertNil(CostCalculator.calculate(project:p,plan:plan,library:lib).sale)
        lib = original; lib.entries[1].platePrice = nil; XCTAssertNil(CostCalculator.calculate(project:p,plan:plan,library:lib).sale)
    }
    func testSamePlateUsesOneSetAndSimplexDoesNotRequireBackPrice() {
        var (p,plan,lib) = fixture(); p.settings.turnMethod = .workAndTurn
        let r = CostCalculator.calculate(project:p,plan:plan,library:lib)
        XCTAssertEqual(r.lines.first { $0.name == "Ofset kalıp" }?.quantity,4)
        var simplex = plan; simplex.sheets[0].back = Side()
        lib.entries[1].kind = .digital; lib.entries[1].price = 1
        XCTAssertNotNil(CostCalculator.calculate(project:p,plan:simplex,library:lib).sale)
    }
    func testCheapestSheetUsesMatchingStockAndExcludesMissingPrices() throws {
        var (p,_,lib) = fixture(); p.costing?.finishing = []; p.costing?.extraWasteSheets = 0
        lib.entries[1].kind = .digital; lib.entries[1].price = 0; lib.entries[1].backPrice = 0
        lib.entries[0].size = SheetPreset.a3.size; lib.entries[0].price = 50
        var cheap = lib.entries[0]; cheap.id = UUID(); cheap.size = SheetPreset.cm50x70.size; cheap.price = 1; lib.entries.append(cheap)
        let rows = EconomicSheets.compare(project:p,library:lib)
        XCTAssertEqual(rows.count,6)
        XCTAssertEqual(rows.filter(\.cheapest).count,1)
        XCTAssertEqual(rows.first(where:\.cheapest)?.title,"50×70")
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.title == "SRA3" }).paperPriced)
        XCTAssertNil(rows.first { $0.title == "SRA3" }?.result.sale)
        let best = try XCTUnwrap(rows.first(where:\.cheapest))
        XCTAssertEqual(CostCalculator.calculate(project:best.project,plan:ImpositionPlanner.plan(best.project),library:lib).sale,best.result.sale)
    }
    func testFinishingUsesProductionQuantityAndSelectedUnit() {
        let (p,plan,lib) = fixture()
        var project = p, production = plan, library = lib
        production.sheets[0].repeatLayout?.productionQuantity = 110
        for (unit,count) in [(PriceUnit.piece,110),(PriceUnit.sheet,12),(PriceUnit.job,1)] {
            library.entries[2].unit = unit
            let result = CostCalculator.calculate(project:project,plan:production,library:library)
            XCTAssertEqual(result.lines.last?.quantity,Decimal(count))
        }
        project.costing?.paper?.override = library.entries[0]
        project.costing?.paper?.override?.size = Size(100,100)
        XCTAssertNil(CostCalculator.calculate(project:project,plan:production,library:library).sale)
        project = p; project.binding = .spiral
        XCTAssertNil(CostCalculator.calculate(project:project,plan:production,library:library).sale)
        project.costing?.copies = 3
        let publication = CostCalculator.calculate(project:project,plan:production,library:library)
        XCTAssertEqual(publication.sheets,32); XCTAssertEqual(publication.quantity,3)
        XCTAssertNotNil(publication.sale)
        XCTAssertEqual(CostCalculator.round(Decimal(string:"1.005")!),Decimal(string:"1.01"))
    }
    func testLibraryAndProjectRoundtripLegacy() throws {
        let (p,_,lib) = fixture()
        XCTAssertEqual(try PriceLibrary.decode(lib.encoded()),lib)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:data),p)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]); json.removeValue(forKey:"costing")
        XCTAssertNil(try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:json)).costing)
        var future = lib; future.version = 2; XCTAssertThrowsError(try PriceLibrary.decode(future.encoded()))
    }
}
