import Foundation
import Darwin
#if !COEXISTENCE_DI
import OmacVMUSB
#endif

// Local stdin control only. Not a QMP schema or an application IPC endpoint.
enum LiveControl: Equatable {
    case attach(String,String), bulk(UInt16,UInt16,UInt32,Int), detach, retry, status
    enum Invalid: Error { case command }
    // Open nonblocking before fstat so a FIFO/device cannot pin the control
    // queue. Bound both the advertised size and bytes actually read after it.
    static func readFile(_ path:String, limit:Int = 65536) throws -> Data {
        guard limit >= 0, limit <= 268435456 else { throw Invalid.command }
        let fd = Darwin.open(path,O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Invalid.command }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw Invalid.command }
        var data = Data(), bytes = [UInt8](repeating:0,count:4096)
        while true {
            let n = Darwin.read(fd,&bytes,min(bytes.count,limit + 1 - data.count))
            if n < 0 { if errno == EINTR { continue }; throw Invalid.command }
            if n == 0 { return data }
            data.append(contentsOf:bytes.prefix(n))
            guard data.count <= limit else { throw Invalid.command }
        }
    }
    static func parse(_ data:Data) throws -> LiveControl {
        guard data.count <= 4096 else { throw Invalid.command }
        if data == Data("retry".utf8) { return .retry }
        let obj = try USBCoexistenceCodec.decode(data)
        guard let command = obj["command"] as? String else { throw Invalid.command }
        let keys = Set(obj.keys)
        if keys == Set(["command"]) {
            switch command {
            case "detach": return .detach
            case "retry": return .retry
            case "status": return .status
            default: throw Invalid.command
            }
        }
        if command == "attach", keys == Set(["command","target-file","descriptor-file"]),
           let target = obj["target-file"] as? String, let descriptor = obj["descriptor-file"] as? String,
           target.hasPrefix("/"), descriptor.hasPrefix("/"), !target.utf8.contains(0), !descriptor.utf8.contains(0) {
            return .attach(target,descriptor)
        }
        func uint(_ key:String) -> UInt32? {
            guard let text = obj[key] as? String, text.range(of:"^[1-9][0-9]*$",options:.regularExpression) != nil else { return nil }
            return UInt32(text)
        }
        if command == "bulk", keys == Set(["command","vendor","product","location","address"]),
           let v = uint("vendor"), let p = uint("product"), let l = uint("location"), let a = uint("address"),
           v <= 65535, p <= 65535, a <= 127 {
            return .bulk(UInt16(v),UInt16(p),l,Int(a))
        }
        throw Invalid.command
    }
}
