import Foundation
import Compression

/// ZIP records, not locale-sensitive `zipinfo` display text. No extraction tool
/// sees untrusted names; only bounded, checked files are written into a new folder.
struct UpdateArchive {
    struct Limits {
        var entries=20_000
        var totalBytes=512*1024*1024
        var fileBytes=256*1024*1024
    }
    struct Entry {
        let path:String
        let bytes:Range<Int>
        let size:Int
        let crc:UInt32
        let method:UInt16
        let kind:UInt32
        let permissions:Int
        let skipped:Bool
    }
    let data:Data
    let entries:[Entry]
    static let root="AtışPress.app"
    private static func identity(_ path:String) -> String {
        path.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
    static func failure(_ path:String,_ reason:String) -> UpdateFailure {
        let escaped=path.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) ? String(format:"\\u{%04X}",scalar.value) : String(scalar)
        }.joined()
        let short=escaped.count>160 ? String(escaped.prefix(120))+"…"+String(escaped.suffix(30)) : escaped
        return UpdateFailure("Güncelleme arşivinde güvensiz girdi: \(short.isEmpty ? "(boş yol)" : short) — \(reason)")
    }
    init(url:URL,limits:Limits = Limits()) throws {
        let length=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard length>=22,length<=1_500_000_000 else {throw Self.failure("(ZIP)","arşiv boyutu geçersiz")}
        let d=try Data(contentsOf:url,options:.mappedIfSafe)
        func u16(_ i:Int) -> UInt16 {UInt16(d[i]) | UInt16(d[i+1])<<8}
        func u32(_ i:Int) -> UInt32 {UInt32(u16(i)) | UInt32(u16(i+2))<<16}
        func require(_ ok:Bool,_ path:String,_ reason:String) throws {if !ok {throw Self.failure(path,reason)}}
        var end:Int?
        for i in stride(from:d.count-22,through:max(0,d.count-65_557),by:-1) {
            if u32(i)==0x06054b50, i+22+Int(u16(i+20))==d.count {end=i; break}
        }
        guard let end else {throw Self.failure("(ZIP)","merkez dizin bulunamadı")}
        let count=Int(u16(end+10)),central=Int(u32(end+16)),centralSize=Int(u32(end+12))
        try require(u16(end+4)==0 && u16(end+6)==0 && u16(end+8)==u16(end+10) && count<65_535,"(ZIP)","çok diskli/ZIP64 arşiv desteklenmiyor")
        try require(count>0 && count<=limits.entries,"(ZIP)","girdi sayısı sınırı aşıldı (\(limits.entries))")
        try require(central<=end && centralSize==end-central,"(ZIP)","merkez dizin sınırları geçersiz")
        var position=central,total=0,result:[Entry]=[],ranges:[Range<Int>]=[],seen=Set<String>(),spellings:[String:String]=[:]
        func extra(_ range:Range<Int>,name:Data,path:String) throws {
            var i=range.lowerBound
            while i<range.upperBound {
                try require(i+4<=range.upperBound,path,"ek alan kesik")
                let tag=u16(i),n=Int(u16(i+2)); i+=4
                try require(n<=range.upperBound-i,path,"ek alan kesik")
                try require(tag != 0x0001,path,"ZIP64 desteklenmiyor")
                if tag==0x7075 {
                    try require(n>=5 && d[i]==1 && u32(i+1)==Self.crc32(name),path,"Unicode yol ek alanı geçersiz")
                    let value=String(data:d.subdata(in:i+5..<i+n),encoding:.utf8)?.precomposedStringWithCanonicalMapping
                    try require(value==path,path,"çelişen Unicode yol adları")
                }
                i+=n
            }
        }
        for _ in 0..<count {
            try require(position+46<=end,"(ZIP)","merkez girdisi kesik")
            try require(u32(position)==0x02014b50,"(ZIP)","merkez girdisi geçersiz")
            let flags=u16(position+8),method=u16(position+10),crc=u32(position+16)
            let compressed=Int(u32(position+20)),size=Int(u32(position+24)),n=Int(u16(position+28)),x=Int(u16(position+30)),c=Int(u16(position+32))
            let attributes=u32(position+38),offset=Int(u32(position+42)),recordEnd=position+46+n+x+c
            try require(recordEnd<=end,"(ZIP)","merkez girdisi kesik")
            let raw=d.subdata(in:position+46..<position+46+n)
            guard let decoded=String(data:raw,encoding:.utf8) else {throw Self.failure(raw.prefix(64).map{String(format:"%02X",$0)}.joined(),"UTF-8 yol adı değil")}
            let path=decoded.precomposedStringWithCanonicalMapping
            try require(!path.isEmpty && raw.count<=4096 && !path.hasPrefix("/") && !path.contains("\\") && !path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),path,"yol boş, mutlak veya yasak karakter içeriyor")
            let trailing=path.hasSuffix("/"),body=trailing ? String(path.dropLast()) : path
            let parts=body.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
            try require(parts.allSatisfy{!$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count<=255},path,"boş, nokta veya üst dizin bileşeni")
            let metadata=parts[0]=="__MACOSX" || parts[0]=="._"+Self.root || (parts[0]==Self.root && parts.dropFirst().contains(where:{$0.hasPrefix("._")}))
            try require(parts[0]==Self.root || metadata,path,"tek AtışPress.app kökü dışında")
            for length in 1...parts.count {
                let prefix=parts.prefix(length).joined(separator:"/"),key=Self.identity(prefix)
                try require(spellings[key]==nil || spellings[key]==prefix,path,"harf biçimi çakışan yol bileşenleri")
                spellings[key]=prefix
            }
            try require(seen.insert(Self.identity(body)).inserted,path,"yinelenen/çakışan yol")
            let mode=attributes>>16,type=mode & 0o170000
            let kind:UInt32=type==0 ? (trailing || attributes & 0x10 != 0 ? 0o040000 : 0o100000) : type
            try require([UInt32(0o040000),0o100000,0o120000].contains(kind) && mode & 0o7000==0 && attributes & 0x48==0,path,"aygıt/özel dosya veya özel izinler")
            try require(!metadata || kind != 0o120000,path,"AppleDouble girdisi bağlantı olamaz")
            try require((kind==0o040000 || !trailing) && (parts.count>1 || metadata || kind==0o040000),path,"dosya/dizin türü çelişkisi")
            try require(flags & ~UInt16(0x080e)==0 && (method==0 || method==8) && u16(position+34)==0,path,"şifreli veya desteklenmeyen ZIP yöntemi")
            try require(size<=limits.fileBytes && size<=limits.totalBytes-total,path,"açılmış boyut sınırı aşıldı")
            total+=size
            try require(kind != 0o040000 || size==0,path,"dizin veri içeriyor")
            try require(offset<=central && offset+30<=central && u32(offset)==0x04034b50,path,"yerel başlık geçersiz")
            let ln=Int(u16(offset+26)),lx=Int(u16(offset+28)),start=offset+30+ln+lx
            try require(start<=central && compressed<=central-start,path,"sıkıştırılmış veri sınırları geçersiz")
            try require(u16(offset+6)==flags && u16(offset+8)==method && ln==n && d.subdata(in:offset+30..<offset+30+ln)==raw,path,"yerel/merkez yol veya yöntem uyuşmuyor")
            try extra(position+46+n..<position+46+n+x,name:raw,path:path)
            try extra(offset+30+ln..<start,name:raw,path:path)
            var finish=start+compressed
            if flags & 8 != 0 {
                try require(finish+12<=central,path,"veri tanımlayıcısı kesik")
                if u32(finish)==0x08074b50 {finish+=4}
                try require(finish+12<=central && u32(finish)==crc && u32(finish+4)==compressed && u32(finish+8)==size,path,"veri tanımlayıcısı uyuşmuyor")
                finish+=12
                try require((u32(offset+14)==0 || u32(offset+14)==crc) && (u32(offset+18)==0 || u32(offset+18)==compressed) && (u32(offset+22)==0 || u32(offset+22)==size),path,"yerel boyut/CRC uyuşmuyor")
            } else {
                try require(u32(offset+14)==crc && u32(offset+18)==compressed && u32(offset+22)==size,path,"yerel boyut/CRC uyuşmuyor")
            }
            ranges.append(offset..<finish)
            result.append(Entry(path:body,bytes:start..<start+compressed,size:size,crc:crc,method:method,kind:kind,permissions:Int(mode & 0o777),skipped:metadata))
            position=recordEnd
        }
        try require(position==end,"(ZIP)","merkez dizin uzunluğu uyuşmuyor")
        var boundary=0
        for range in ranges.sorted(by:{$0.lowerBound<$1.lowerBound}) {
            try require(range.lowerBound==boundary,"(ZIP)","örtüşen veya sahipsiz yerel veri")
            boundary=range.upperBound
        }
        try require(boundary==central,"(ZIP)","yerel veri uzunluğu uyuşmuyor")
        try require(result.contains{$0.path==Self.root && $0.kind==0o040000},Self.root,"kök uygulama dizini eksik")
        self.data=d; self.entries=result
        // Resolve every symlink before creating files; file sizes/CRC are checked
        // with bounded decoding before each file is written.
        var links:[String:String]=[:]
        for e in result where !e.skipped {
            if e.kind==0o120000 {
                try require(e.size<=4096,e.path,"bağlantı hedefi çok uzun")
                let bytes=try contents(e)
                guard let target=String(data:bytes,encoding:.utf8),!target.isEmpty,!target.hasPrefix("/"),!target.contains("\\"),!target.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {throw Self.failure(e.path,"güvensiz bağlantı hedefi")}
                links[Self.identity(e.path)]=target.precomposedStringWithCanonicalMapping
            }
        }
        let kinds=Dictionary(uniqueKeysWithValues:result.map{(Self.identity($0.path),$0.kind)})
        for e in result where !e.skipped {
            var parent=e.path.split(separator:"/").dropLast().map(String.init)
            while !parent.isEmpty {
                try require(links[Self.identity(parent.joined(separator:"/"))]==nil,e.path,"bir bağlantının altına dosya yazılamaz")
                if let kind=kinds[Self.identity(parent.joined(separator:"/"))] {try require(kind==0o040000,e.path,"üst yol dizin değil")}
                parent.removeLast()
            }
        }
        for e in result where !e.skipped && e.kind==0o120000 {
            let path=e.path
            var pending=path.split(separator:"/").map(String.init),resolved:[String]=[],hops=0
            while !pending.isEmpty {
                let part=pending.removeFirst()
                if part=="." || part.isEmpty {continue}
                if part==".." {try require(resolved.count>1,path,"bağlantı uygulama dışına çıkıyor"); resolved.removeLast(); continue}
                resolved.append(part)
                if let target=links[Self.identity(resolved.joined(separator:"/"))] {
                    hops+=1; try require(hops<=40,path,"bağlantı döngüsü")
                    resolved.removeLast(); pending=target.split(separator:"/",omittingEmptySubsequences:false).map(String.init)+pending
                }
            }
            try require(resolved.first==Self.root,path,"bağlantı uygulama dışına çıkıyor")
        }
    }
    struct DecodeProgress {
        let call:Int
        let produced:Int
        let remainingInput:Int
        let status:Int32
    }
    func contents(_ entry:Entry,progress:((DecodeProgress)->Void)? = nil) throws -> Data {
        let output:Data
        if entry.method==0 {
            guard entry.bytes.count==entry.size else {throw Self.failure(entry.path,"saklanan veri boyutu uyuşmuyor")}
            output=data.subdata(in:entry.bytes)
        }
        else {
            var buffer=[UInt8](repeating:0,count:entry.size+1)
            guard !entry.bytes.isEmpty else {throw Self.failure(entry.path,"sıkıştırılmış veri boş")}
            let stream=UnsafeMutablePointer<compression_stream>.allocate(capacity:1)
            defer {stream.deallocate()}
            guard compression_stream_init(stream,COMPRESSION_STREAM_DECODE,COMPRESSION_ZLIB)==COMPRESSION_STATUS_OK else {throw Self.failure(entry.path,"açıcı başlatılamadı")}
            defer {compression_stream_destroy(stream)}
            var last:DecodeProgress?
            let count:Int?=buffer.withUnsafeMutableBufferPointer { destination in
                data.withUnsafeBytes { source in
                    stream.pointee.dst_ptr=destination.baseAddress!; stream.pointee.dst_size=destination.count
                    stream.pointee.src_ptr=source.bindMemory(to:UInt8.self).baseAddress!.advanced(by:entry.bytes.lowerBound); stream.pointee.src_size=entry.bytes.count
                    var calls=0
                    while true {
                        let beforeSource=stream.pointee.src_size,beforeDestination=stream.pointee.dst_size
                        let status=compression_stream_process(stream,Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                        calls+=1
                        let step=DecodeProgress(call:calls,produced:destination.count-stream.pointee.dst_size,remainingInput:stream.pointee.src_size,status:status.rawValue)
                        last=step; progress?(step)
                        if status==COMPRESSION_STATUS_END {
                            return stream.pointee.src_size==0 ? destination.count-stream.pointee.dst_size : nil
                        }
                        // The decoder may consume input before flushing its final output.
                        // Require progress and never grow the declared-size buffer.
                        guard status==COMPRESSION_STATUS_OK,stream.pointee.dst_size>0,
                              stream.pointee.src_size<beforeSource || stream.pointee.dst_size<beforeDestination else {return nil}
                    }
                }
            }
            guard let count,count==entry.size else {
                throw Self.failure(entry.path,"açılan veri beyan edilen boyuta uymuyor (bildirilen: \(entry.size), hesaplanan: \(last?.produced ?? 0), kalan sıkıştırılmış veri: \(last?.remainingInput ?? entry.bytes.count), açıcı durumu: \(last?.status ?? -1))")
            }
            output=Data(buffer.prefix(count))
        }
        guard output.count==entry.size,Self.crc32(output)==entry.crc else {throw Self.failure(entry.path,"boyut/CRC doğrulaması başarısız")}
        return output
    }
    func extract(to folder:URL) throws -> URL {
        let fm=FileManager.default
        try fm.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            for e in entries where !e.skipped && e.kind != 0o120000 {
                let destination=folder.appendingPathComponent(e.path)
                if e.kind==0o040000 {try fm.createDirectory(at:destination,withIntermediateDirectories:true,attributes:[.posixPermissions:0o755])}
                else {
                    try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o755])
                    try contents(e).write(to:destination,options:.withoutOverwriting)
                    try fm.setAttributes([.posixPermissions:e.permissions==0 ? 0o644 : e.permissions],ofItemAtPath:destination.path)
                }
            }
            for e in entries where !e.skipped && e.kind==0o120000 {
                let destination=folder.appendingPathComponent(e.path)
                try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                try fm.createSymbolicLink(atPath:destination.path,withDestinationPath:String(decoding:try contents(e),as:UTF8.self))
            }
            let app=folder.appendingPathComponent(Self.root),root=folder.appendingPathComponent(Self.root).resolvingSymlinksInPath().path
            // Keep a filesystem-level check as well as the preflight link graph.
            // This also covers filesystem-specific Unicode/case equivalences.
            if let files=fm.enumerator(at:app,includingPropertiesForKeys:[.isSymbolicLinkKey]) {
                for case let file as URL in files {
                    let resolved=file.resolvingSymlinksInPath().path
                    guard resolved==root || resolved.hasPrefix(root+"/") else {throw Self.failure(file.path.replacingOccurrences(of:folder.path+"/",with:""),"bağlantı uygulama dışına çıkıyor")}
                }
            }
            return app
        } catch {try? fm.removeItem(at:folder); throw error}
    }
    private static let crcTable:[UInt32]=(0..<256).map { i in
        var c=UInt32(i); for _ in 0..<8 {c=c & 1==1 ? 0xedb88320 ^ (c>>1) : c>>1}; return c
    }
    static func crc32(_ data:Data) -> UInt32 {
        var crc:UInt32=0xffffffff
        for byte in data {crc=crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc>>8)}
        return crc ^ 0xffffffff
    }
}
