import Foundation
import CoreFoundation

/// In-process bindings, NOT a QMP schema. The transport must validate a drained,
/// published single-context receipt before constructing these values.
public struct USBRootGuardBinding: Equatable, Sendable {
    public let launcher: UUID
    public let qemu: UUID
    public let epoch: UInt64
    public let request: UUID
    public init(launcher: UUID, qemu: UUID, epoch: UInt64, request: UUID) {
        self.launcher = launcher; self.qemu = qemu; self.epoch = epoch; self.request = request
    }
}

public struct USBRootGuardReceipt: Sendable {
    public let binding: USBRootGuardBinding
    public let rootID, sessionID, interfaceID, hidID, cacheClientID: UInt64
    public let qemuPID, launcherPID: Int32
    public let serial, descriptor: Data
    public init(binding: USBRootGuardBinding, rootID: UInt64, sessionID: UInt64,
                interfaceID: UInt64, hidID: UInt64, cacheClientID: UInt64,
                qemuPID: Int32, launcherPID: Int32, serial: Data, descriptor: Data) {
        self.binding = binding; self.rootID = rootID; self.sessionID = sessionID
        self.interfaceID = interfaceID; self.hidID = hidID; self.cacheClientID = cacheClientID
        self.qemuPID = qemuPID; self.launcherPID = launcherPID
        self.serial = serial; self.descriptor = descriptor
    }
}

public enum USBRootGuardError: Error, Equatable {
    case refused, stale, busy, native(String), expired, lost, rootAbsent, requestingClose, uncertain
    case disposalProofPending
}

// Preserve types and byte identity, including NFC/NFD. Never compare a complete
// live CF dictionary: the collector reads only the existing admission inputs
// plus root/session/creator identity. Only HID DebugState is telemetry.
indirect enum USBRootGuardValue: Equatable {
    case bytes(Data), text(Data), number(String), boolean(Bool)
    case array([USBRootGuardValue]), dictionary([String: USBRootGuardValue])
    init?(_ value: Any) {
        if let v = value as? Data { self = .bytes(v) }
        else if let v = value as? String { self = .text(Data(v.utf8)) }
        else if let v = value as? NSNumber {
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .boolean(v.boolValue) }
            else if CFGetTypeID(v) == CFNumberGetTypeID() { self = .number(v.stringValue) }
            else { return nil }
        } else if let v = value as? [Any] {
            var result: [Self] = []
            for x in v { guard let x = Self(x) else { return nil }; result.append(x) }
            self = .array(result)
        } else if let v = value as? [String: Any] {
            var result: [String: Self] = [:]
            for (k,x) in v { guard let x = Self(x) else { return nil }; result[k] = x }
            self = .dictionary(result)
        } else { return nil }
    }
}

struct USBRootGuardSnapshot: Equatable {
    struct Node: Equatable {
        let id: UInt64
        let parent: UInt64
        let cls: String
        let conforms: Set<String>
        let properties: USBRootGuardValue
    }
    let nodes: [Node]
}

enum USBRootGuardPolicy {
    static func uint(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(unsafeBitCast(n, to: CFNumber.self)),
              let v = UInt64(n.stringValue) else { return nil }
        return v
    }

    // IOUserClientCreator is read directly from the kernel registry. Never
    // search a process name or trust a user-facing label as creator provenance.
    static func creator(_ node: USBScan.Entry, pid: Int32) -> Bool {
        guard pid > 0, let raw = node.properties["IOUserClientCreator"] as? String else { return false }
        let prefix = "pid \(pid), "
        return raw.hasPrefix(prefix) && raw.utf8.count > prefix.utf8.count && !raw.utf8.contains(0)
    }

    static func validate(_ root: USBScan.Entry, receipt r: USBRootGuardReceipt,
                         guardClientID: UInt64?, nativeClientID: UInt64? = nil) -> USBRootGuardSnapshot? {
        let ids = [r.rootID,r.interfaceID,r.hidID,r.cacheClientID]
        guard r.binding.epoch > 0, r.sessionID > 0, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count,
              r.qemuPID > 0, r.launcherPID > 0, r.qemuPID != r.launcherPID,
              !r.serial.isEmpty, !r.serial.contains(0), !r.descriptor.isEmpty,
              root.registryID == r.rootID, uint(root.properties["sessionID"]) == r.sessionID,
              let serial = root.properties["USB Serial Number"] as? String, Data(serial.utf8) == r.serial else { return nil }
        var expected: [UInt64: Int32] = [r.cacheClientID:r.qemuPID]
        if let id = guardClientID { guard id > 0, !ids.contains(id) else { return nil }; expected[id] = r.launcherPID }
        if let id = nativeClientID { guard id > 0, !ids.contains(id), expected[id] == nil else { return nil }; expected[id] = r.qemuPID }
        var found = Set<UInt64>(), seen = Set<UInt64>(), frozen: [USBRootGuardSnapshot.Node] = []
        func visit(_ node: USBScan.Entry, parent: UInt64, depth: Int) -> USBScan.Entry? {
            guard depth < 16, seen.count < 64, node.complete, node.registryID != 0,
                  seen.insert(node.registryID).inserted, node.properties["built-in"] == nil else { return nil }
            var copy = node
            if let pid = expected[node.registryID] {
                let isNative = node.registryID == nativeClientID
                guard node.className == (isNative ? "IOHIDLibUserClient" : "AppleUSBHostDeviceUserClient"),
                      parent == (isNative ? r.hidID : r.rootID), node.children.isEmpty,
                      creator(node, pid:pid) else { return nil }
                found.insert(node.registryID)
                // Feed every client's ORIGINAL protected metadata through the
                // unchanged policy too. This surrogate is local, never inventory.
                copy.className = "AppleUSBHostCompositeDevice"
            }
            if expected[node.registryID] == nil || node.registryID == r.cacheClientID {
                var props = node.properties
                if node.isA("IOHIDDevice") { props.removeValue(forKey:"DebugState") }
                guard let value = USBRootGuardValue(props) else { return nil }
                frozen.append(.init(id:node.registryID,parent:parent,cls:node.className,conforms:node.conforms,properties:value))
            }
            var children: [USBScan.Entry] = []
            for child in node.children {
                guard let c = visit(child,parent:node.registryID,depth:depth+1) else { return nil }
                children.append(c)
            }
            copy.children = children
            return copy
        }
        guard var sanitized = visit(root,parent:0,depth:0), found == Set(expected.keys) else { return nil }
        // Validate client metadata under the same original metadata predicate by
        // moving only the exact native client surrogate beside the root clients.
        if let nativeID = nativeClientID {
            for i in sanitized.children.indices where sanitized.children[i].registryID == r.interfaceID {
                for h in sanitized.children[i].children.indices where sanitized.children[i].children[h].registryID == r.hidID {
                    let clients = sanitized.children[i].children[h].children.filter { $0.registryID == nativeID }
                    sanitized.children[i].children[h].children.removeAll { $0.registryID == nativeID }
                    sanitized.children.append(contentsOf:clients)
                }
            }
        }
        guard let hid = USBHID.resolve(sanitized), hid.registryID == r.hidID, Data(hid.serial.utf8) == r.serial,
              let interface = root.children.first(where: { $0.registryID == r.interfaceID }),
              let h = interface.children.first(where: { $0.registryID == r.hidID }),
              h.properties["ReportDescriptor"] as? Data == r.descriptor else { return nil }
        return USBRootGuardSnapshot(nodes:frozen.sorted { $0.id < $1.id })
    }
}
