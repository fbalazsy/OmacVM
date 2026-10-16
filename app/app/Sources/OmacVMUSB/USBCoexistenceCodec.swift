import Foundation
import CoreFoundation
import CryptoKit
import Darwin

public enum USBCoexistenceError: Error { case schema, identity, busy, uncertain, rejected(String) }

/// Reserved protocol v1. All identities are strings on the wire; never truncate
/// NSNumber, normalize serials, or reconstruct a receipt from a device label.
public enum USBCoexistenceCodec {
    public static func u64(_ value: Any?, nonzero: Bool = false) throws -> UInt64 {
        guard let s = value as? String, !s.isEmpty, s.utf8.allSatisfy({ 48...57 ~= $0 }),
              s == "0" || s.first != "0", let n = UInt64(s), !nonzero || n != 0 else { throw USBCoexistenceError.schema }
        return n
    }
    static func object(_ value: Any?, _ keys: String) throws -> [String: Any] {
        guard let d = value as? [String: Any], Set(d.keys) == Set(keys.split(separator: " ").map(String.init)) else { throw USBCoexistenceError.schema }
        return d
    }
    static func integer(_ value: Any?, max: Int) throws -> Int {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(unsafeBitCast(n, to: CFNumber.self)),
              let i = Int(n.stringValue), i > 0, i <= max else { throw USBCoexistenceError.schema }
        return i
    }
    static func bool(_ value: Any?) throws -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw USBCoexistenceError.schema }
        return n.boolValue
    }
    static func hex(_ value: Any?, count: Int) throws -> String {
        guard let s = value as? String, s.utf8.count == count,
              s.utf8.allSatisfy({ 48...57 ~= $0 || 97...102 ~= $0 }) else { throw USBCoexistenceError.schema }
        return s
    }
    public static func launchID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func uuid(_ hex: String) -> UUID {
        let s = Array(hex); let pieces = [0..<8,8..<12,12..<16,16..<20,20..<32].map { String(s[$0]) }
        return UUID(uuidString: pieces.joined(separator: "-"))!
    }

    /// Validate raw frames BEFORE Foundation can collapse duplicate keys. This
    /// protocol has no floating-point fields (including PID). Bounded recursion
    /// and frame size apply to trusted local QMP too.
    public static func decode(_ data: Data) throws -> [String: Any] {
        guard data.count <= 262144 else { throw USBCoexistenceError.schema }
        var parser = Parser(bytes: Array(data)); let v = try parser.value(0)
        parser.space()
        guard parser.i == parser.bytes.count, let d = v as? [String: Any] else { throw USBCoexistenceError.schema }
        return d
    }
    private struct Parser {
        let bytes: [UInt8]; var i = 0
        mutating func space() { while i < bytes.count && [9,10,13,32].contains(bytes[i]) { i += 1 } }
        mutating func take(_ c: UInt8) -> Bool { space(); if i < bytes.count && bytes[i] == c { i += 1; return true }; return false }
        mutating func string() throws -> String {
            space(); let start = i
            guard take(34) else { throw USBCoexistenceError.schema }
            while i < bytes.count {
                let c = bytes[i]; i += 1
                if c == 92 { guard i < bytes.count else { throw USBCoexistenceError.schema }; i += 1 }
                else if c == 34 {
                    guard let s = try JSONSerialization.jsonObject(with: Data(bytes[start..<i]), options: .fragmentsAllowed) as? String else { throw USBCoexistenceError.schema }
                    return s
                }
            }
            throw USBCoexistenceError.schema
        }
        mutating func value(_ depth: Int) throws -> Any {
            space(); guard depth < 24, i < bytes.count else { throw USBCoexistenceError.schema }
            if bytes[i] == 34 { return try string() }
            if take(123) {
                var d: [String: Any] = [:]
                if take(125) { return d }
                repeat {
                    let key = try string()
                    guard d[key] == nil, take(58) else { throw USBCoexistenceError.schema }
                    d[key] = try value(depth+1)
                    if take(125) { return d }
                    guard take(44) else { throw USBCoexistenceError.schema }
                } while true
            }
            if take(91) {
                var a: [Any] = []; if take(93) { return a }
                repeat { a.append(try value(depth+1)); if take(93) { return a }; guard take(44) else { throw USBCoexistenceError.schema } } while true
            }
            let start = i
            while i < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[i]) { i += 1 }
            let token = String(decoding: bytes[start..<i], as: UTF8.self)
            if token == "true" { return true }; if token == "false" { return false }; if token == "null" { return NSNull() }
            guard token.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
                  let n = Int64(token) else { throw USBCoexistenceError.schema }
            return NSNumber(value: n)
        }
    }
}

public struct USBCoexistenceTask: Equatable, Sendable {
    public let pid: Int32
    public let seconds, microseconds: UInt64
    public init(wire: Any) throws {
        let d = try USBCoexistenceCodec.object(wire, "pid start-sec start-usec")
        pid = Int32(try USBCoexistenceCodec.integer(d["pid"], max: Int(Int32.max)))
        seconds = try USBCoexistenceCodec.u64(d["start-sec"])
        microseconds = try USBCoexistenceCodec.u64(d["start-usec"])
        guard microseconds <= 999999 else { throw USBCoexistenceError.schema }
    }
    public static func measure(_ pid: Int32) throws -> Self {
        var info = proc_bsdinfo(); let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { throw USBCoexistenceError.identity }
        return try Self(wire: ["pid":pid,"start-sec":String(info.pbi_start_tvsec),"start-usec":String(info.pbi_start_tvusec)])
    }
    public var wire: [String: Any] { ["pid":pid,"start-sec":String(seconds),"start-usec":String(microseconds)] }
}

public struct USBCoexistenceTarget: Equatable, Sendable {
    public let root, interface, hid: UInt64
    public let vendor, product: UInt16
    public let serial: Data
    public let descriptorHash: String
    public init(wire: Any) throws {
        let d = try USBCoexistenceCodec.object(wire,"root-id interface-id hid-id vendor-id product-id serial-utf8 descriptor-sha256")
        root = try USBCoexistenceCodec.u64(d["root-id"],nonzero:true)
        interface = try USBCoexistenceCodec.u64(d["interface-id"],nonzero:true)
        hid = try USBCoexistenceCodec.u64(d["hid-id"],nonzero:true)
        vendor = UInt16(try USBCoexistenceCodec.integer(d["vendor-id"],max:65535))
        product = UInt16(try USBCoexistenceCodec.integer(d["product-id"],max:65535))
        guard let s = d["serial-utf8"] as? String, !s.isEmpty, s.utf8.count <= 256, !s.utf8.contains(0), Set([root,interface,hid]).count == 3 else { throw USBCoexistenceError.schema }
        serial = Data(s.utf8); descriptorHash = try USBCoexistenceCodec.hex(d["descriptor-sha256"],count:64)
    }
    public var wire: [String: Any] { ["root-id":String(root),"interface-id":String(interface),"hid-id":String(hid),"vendor-id":Int(vendor),"product-id":Int(product),"serial-utf8":String(decoding:serial,as:UTF8.self),"descriptor-sha256":descriptorHash] }
    public static func hash(_ descriptor: Data) -> String { SHA256.hash(data:descriptor).map { String(format:"%02x",$0) }.joined() }
}

public struct USBCoexistenceStatus {
    public let lease, published: [String: Any]
    public let launch, qemuLaunch: String
    public let launcher, qemu: USBCoexistenceTask
    public let epoch, sequence, session, cache, guardID, nativeID, handles, transfers, callbacks: UInt64
    public let target: USBCoexistenceTarget
    public let state: String
    public let uncertain: Bool
    public init(wire: Any) throws {
        let c = USBCoexistenceCodec.self
        let d = try c.object(wire,"lease sequence state published guard-client-id native-client-id handles transfers callbacks uncertain")
        lease = try c.object(d["lease"],"qemu-launch launcher lease-epoch")
        let owner = try c.object(lease["launcher"],"launch task")
        launch = try c.hex(owner["launch"],count:32); launcher = try .init(wire:owner["task"] as Any)
        qemuLaunch = try c.hex(lease["qemu-launch"],count:32); epoch = try c.u64(lease["lease-epoch"],nonzero:true)
        sequence = try c.u64(d["sequence"],nonzero:true)
        published = try c.object(d["published"],"target session cache-client-id qemu-task")
        target = try .init(wire:published["target"] as Any)
        session = try c.u64(published["session"],nonzero:true); cache = try c.u64(published["cache-client-id"],nonzero:true)
        qemu = try .init(wire:published["qemu-task"] as Any)
        guardID = try c.u64(d["guard-client-id"]); nativeID = try c.u64(d["native-client-id"])
        handles = try c.u64(d["handles"]); transfers = try c.u64(d["transfers"]); callbacks = try c.u64(d["callbacks"])
        uncertain = try c.bool(d["uncertain"])
        guard let s = d["state"] as? String, ["freezing","guard-pending","native","revoking","guard-release","retired","uncertain"].contains(s), qemu.pid != launcher.pid else { throw USBCoexistenceError.schema }
        state = s
    }
    public var drained: Bool { !uncertain && handles == 0 && transfers == 0 && callbacks == 0 }
    func sameGeneration(_ other: Self) -> Bool {
        launch == other.launch && qemuLaunch == other.qemuLaunch && launcher == other.launcher && qemu == other.qemu && epoch == other.epoch && target == other.target && session == other.session && cache == other.cache
    }
}
