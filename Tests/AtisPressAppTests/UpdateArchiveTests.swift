import XCTest
import Compression
@testable import AtisPressApp

final class UpdateArchiveTests:XCTestCase {
    struct Item {
        var path:String
        var data=Data("content".utf8)
        var mode:UInt32=0o100644
        var size:Int?=nil
        var method:UInt16=0
        var packed:Data?=nil
    }
    private func directory() throws -> URL {
        let u=FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:u,withIntermediateDirectories:false)
        addTeardownBlock{try? FileManager.default.removeItem(at:u)}; return u
    }
    private func zip(_ items:[Item],at folder:URL) throws -> URL {
        var d=Data(),central=Data()
        func u16(_ n:Int,_ target:inout Data) {target.append(UInt8(truncatingIfNeeded:n));target.append(UInt8(truncatingIfNeeded:n>>8))}
        func u32(_ n:Int,_ target:inout Data) {u16(n,&target);u16(n>>16,&target)}
        let all=[Item(path:"AtışPress.app/",data:Data(),mode:0o040755)]+items
        for i in all {
            let name=Data(i.path.utf8),packed=i.packed ?? i.data,crc=Int(UpdateArchive.crc32(i.data)),size=i.size ?? i.data.count,offset=d.count
            u32(0x04034b50,&d);u16(20,&d);u16(0x800,&d);u16(Int(i.method),&d);u16(0,&d);u16(0,&d)
            u32(crc,&d);u32(packed.count,&d);u32(size,&d);u16(name.count,&d);u16(0,&d);d.append(name);d.append(packed)
            u32(0x02014b50,&central);u16(0x0314,&central);u16(20,&central);u16(0x800,&central);u16(Int(i.method),&central);u16(0,&central);u16(0,&central)
            u32(crc,&central);u32(packed.count,&central);u32(size,&central);u16(name.count,&central);u16(0,&central);u16(0,&central);u16(0,&central);u16(0,&central)
            u32(Int(i.mode)<<16,&central);u32(offset,&central);central.append(name)
        }
        let offset=d.count;d.append(central)
        u32(0x06054b50,&d);u16(0,&d);u16(0,&d);u16(all.count,&d);u16(all.count,&d);u32(central.count,&d);u32(offset,&d);u16(0,&d)
        let url=folder.appendingPathComponent(UUID().uuidString+".zip");try d.write(to:url);return url
    }
    func testRejectsEveryUnsafePathAndSpecialFileBeforeWriting() throws {
        let folder=try directory()
        for name in ["/AtışPress.app/file","AtışPress.app/../outside","AtışPress.app/a\\b","","AtışPress.app//file","AtışPress.app/./file","Other.app/file","AtışPress.app/a\nfile","AtışPress.app/a\0file"] {
            let url=try zip([Item(path:name)],at:folder)
            XCTAssertThrowsError(try UpdateArchive(url:url),name)
        }
        for mode:UInt32 in [0o020600,0o060600,0o010600,0o140600,0o104755] {
            let url=try zip([Item(path:"AtışPress.app/device",mode:mode)],at:folder)
            XCTAssertThrowsError(try UpdateArchive(url:url),String(mode,radix:8))
        }
    }
    func testRejectsEscapingAndChainedSymlinksAndSymlinkParents() throws {
        let folder=try directory()
        for target in ["../../outside","/tmp/outside","..\\outside"] {
            let url=try zip([Item(path:"AtışPress.app/link",data:Data(target.utf8),mode:0o120777)],at:folder)
            XCTAssertThrowsError(try UpdateArchive(url:url),target)
        }
        let metadataLink=try zip([Item(path:"__MACOSX/link",data:Data("/tmp/outside".utf8),mode:0o120777)],at:folder)
        XCTAssertThrowsError(try UpdateArchive(url:metadataLink))
        let chained=try zip([Item(path:"AtışPress.app/link",data:Data("Contents/other/../../outside".utf8),mode:0o120777),Item(path:"AtışPress.app/Contents/other",data:Data("..".utf8),mode:0o120777)],at:folder)
        XCTAssertThrowsError(try UpdateArchive(url:chained))
        let caseEscape=try zip([Item(path:"AtışPress.app/Contents/L",data:Data("..".utf8),mode:0o120777),Item(path:"AtışPress.app/x",data:Data("Contents/l/../../outside".utf8),mode:0o120777)],at:folder)
        XCTAssertThrowsError(try UpdateArchive(url:caseEscape))
        let cycle=try zip([Item(path:"AtışPress.app/a",data:Data("b".utf8),mode:0o120777),Item(path:"AtışPress.app/b",data:Data("a".utf8),mode:0o120777)],at:folder)
        XCTAssertThrowsError(try UpdateArchive(url:cycle))
        let parent=try zip([Item(path:"AtışPress.app/link",data:Data("Contents".utf8),mode:0o120777),Item(path:"AtışPress.app/link/file")],at:folder)
        XCTAssertThrowsError(try UpdateArchive(url:parent))
        let safe=try zip([Item(path:"AtışPress.app/Contents/file"),Item(path:"AtışPress.app/alias",data:Data("Contents/file".utf8),mode:0o120777)],at:folder)
        let app=try UpdateArchive(url:safe).extract(to:folder.appendingPathComponent("safe"))
        XCTAssertEqual(try Data(contentsOf:app.appendingPathComponent("alias")),Data("content".utf8))
    }
    func testEntryTotalAndPerFileBombLimitsAndFalseDeclaredSize() throws {
        let folder=try directory(),url=try zip([Item(path:"AtışPress.app/a"),Item(path:"AtışPress.app/b")],at:folder)
        XCTAssertThrowsError(try UpdateArchive(url:url,limits:.init(entries:2,totalBytes:100,fileBytes:100)))
        XCTAssertThrowsError(try UpdateArchive(url:url,limits:.init(entries:100,totalBytes:10,fileBytes:100)))
        XCTAssertThrowsError(try UpdateArchive(url:url,limits:.init(entries:100,totalBytes:100,fileBytes:2)))
        let huge=try zip([Item(path:"AtışPress.app/bomb",size:513*1024*1024)],at:folder)
        XCTAssertThrowsError(try UpdateArchive(url:huge))
        let expanded=Data(repeating:65,count:4096)
        var buffer=[UInt8](repeating:0,count:8192)
        let n=expanded.withUnsafeBytes{raw in compression_encode_buffer(&buffer,buffer.count,raw.bindMemory(to:UInt8.self).baseAddress!,expanded.count,nil,COMPRESSION_ZLIB)}
        XCTAssertGreaterThan(n,0)
        let liar=try zip([Item(path:"AtışPress.app/bomb",data:expanded,size:1,method:8,packed:Data(buffer.prefix(n)))],at:folder)
        let output=folder.appendingPathComponent("liar")
        XCTAssertThrowsError(try UpdateArchive(url:liar).extract(to:output))
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
    }
    func testLargeDeflateFlushesAllOutputWithinDeclaredBound() throws {
        let folder=try directory(),seed=try Data(contentsOf:URL(fileURLWithPath:"/usr/bin/true"))
        var payload=Data()
        while payload.count<8*1024*1024 {payload.append(seed)}
        var buffer=[UInt8](repeating:0,count:payload.count+1024)
        let n=payload.withUnsafeBytes {source in compression_encode_buffer(&buffer,buffer.count,source.bindMemory(to:UInt8.self).baseAddress!,payload.count,nil,COMPRESSION_ZLIB)}
        XCTAssertGreaterThan(n,0)
        let url=try zip([Item(path:"AtışPress.app/Contents/large",data:payload,method:8,packed:Data(buffer.prefix(n)))],at:folder)
        let app=try UpdateArchive(url:url).extract(to:folder.appendingPathComponent("large"))
        XCTAssertEqual(try Data(contentsOf:app.appendingPathComponent("Contents/large")),payload)
    }
    func testNormalizationCollisionsAndHeaderMismatchAreRejected() throws {
        let folder=try directory()
        let nfc="AtışPress.app/ş.txt",nfd=nfc.decomposedStringWithCanonicalMapping
        XCTAssertThrowsError(try UpdateArchive(url:zip([Item(path:nfc),Item(path:nfd)],at:folder)))
        XCTAssertThrowsError(try UpdateArchive(url:zip([Item(path:"AtışPress.app/File"),Item(path:"AtışPress.app/file")],at:folder)))
        let url=try zip([Item(path:"AtışPress.app/file")],at:folder)
        var data=try Data(contentsOf:url);data[30]=UInt8(ascii:"X");try data.write(to:url)
        XCTAssertThrowsError(try UpdateArchive(url:url))
    }
    func testAppleDoubleIsSkippedAndDiagnosticsIncludeFirstPathAndPrivateLog() throws {
        let folder=try directory()
        let archive=try UpdateArchive(url:zip([Item(path:"AtışPress.app/Contents/file"),Item(path:"__MACOSX/._AtışPress.app"),Item(path:"AtışPress.app/Contents/._file"),Item(path:"._AtışPress.app")],at:folder))
        let app=try archive.extract(to:folder.appendingPathComponent("clean"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:app.appendingPathComponent("Contents/._file").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:app.deletingLastPathComponent().appendingPathComponent("__MACOSX").path))
        let path="AtışPress.app/"+String(repeating:"x",count:300)+"/offending.txt"
        let url=try zip([Item(path:path),Item(path:"second-bad-root")],at:folder)
        let manifest=UpdateManifest(version:"0.3.0",build:4,minimumOS:"14.0",url:"",sha256:"",signature:"",notes:"",publishedAt:"",metadataSignature:"")
        var message=""
        XCTAssertThrowsError(try UpdateInstaller.unpack(url,in:folder.appendingPathComponent("bad"),manifest:manifest,currentVersion:"0.2.1",currentBuild:3)) {message=$0.localizedDescription}
        XCTAssertTrue(message.contains("AtışPress.app/"));XCTAssertTrue(message.contains("offending.txt"));XCTAssertTrue(message.contains("…"));XCTAssertLessThan(message.count,260)
        XCTAssertFalse(message.contains("second-bad-root"))
        let existing=folder.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at:existing,withIntermediateDirectories:false)
        let marker=existing.appendingPathComponent("keep.txt");try Data("keep".utf8).write(to:marker)
        XCTAssertThrowsError(try UpdateInstaller.unpack(url,in:existing,manifest:manifest,currentVersion:"0.2.1",currentBuild:3))
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        let log=folder.appendingPathComponent("install.log")
        XCTAssertTrue(try String(contentsOf:log).contains(message))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:log.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
}
