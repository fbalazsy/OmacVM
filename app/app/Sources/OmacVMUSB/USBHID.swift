import Foundation
import IOKit

/// Read-only discovery identity, not permission: QEMU revalidates before opening.
public struct USBHID: Equatable, Sendable {
    public let registryID: UInt64
    public let serial: String

    // String equality normalizes Unicode; native strcmp and QMP identity do not.
    // Reversible ASCII keeps keys/sets exact without changing the saved raw string.
    static func serialKey(_ serial: String) -> String { Data(serial.utf8).base64EncodedString() }
    var serialKey: String { Self.serialKey(serial) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.registryID == rhs.registryID && lhs.serialKey == rhs.serialKey
    }

    static func resolve(_ root: USBScan.Entry) -> USBHID? {
        let nodes = root.descendants
        let interfaces = root.children.filter { $0.className == "IOUSBHostInterface" }
        guard nodes.count <= 64, nodes.allSatisfy(\.complete), root.className == "IOUSBHostDevice",
              root.children.allSatisfy({ $0.className == "IOUSBHostInterface" ||
                  ($0.className == "AppleUSBHostCompositeDevice" && $0.children.isEmpty) }),
              interfaces.count == 1, let interface = interfaces.first,
              integer(interface.properties["bInterfaceClass"]) == 3, integer(interface.properties["bInterfaceSubClass"]) == 0,
              integer(interface.properties["bInterfaceProtocol"]) == 0,
              interface.children.count == 1, let hid = interface.children.first,
              ["IOHIDDevice", "AppleUserHIDDevice"].contains(hid.className),
              hid.isA("IOHIDDevice"), hid.registryID != 0,
              hid.children.count <= 1,
              hid.children.allSatisfy({ $0.className == "IOHIDInterface" && $0.children.isEmpty }),
              (1...65535).contains(integer(hid.properties["VendorID"]) ?? 0), (1...65535).contains(integer(hid.properties["ProductID"]) ?? 0),
              integer(hid.properties["VendorID"]) == integer(root.properties["idVendor"]),
              integer(hid.properties["ProductID"]) == integer(root.properties["idProduct"]),
              hid.string("Transport") == "USB", let serial = hid.string("SerialNumber"), !serial.isEmpty,
              validString(serial), let product = hid.string("Product"), validString(product),
              let descriptor = hid.properties["ReportDescriptor"] as? Data,
              accepts(descriptor, page: integer(hid.properties["PrimaryUsagePage"]), usage: integer(hid.properties["PrimaryUsage"])),
              nodes.allSatisfy({ metadata($0, required: $0.registryID == hid.registryID || $0.className == "IOHIDInterface",
                                                   page: integer(hid.properties["PrimaryUsagePage"]), usage: integer(hid.properties["PrimaryUsage"])) }) else { return nil }
        if let value = root.properties["bDeviceClass"] {
            guard let cls = integer(value), cls <= 255, cls != 9, cls != 17 else { return nil }
        }
        return USBHID(registryID: hid.registryID, serial: serial)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(unsafeBitCast(n, to: CFNumber.self)),
              (0...65535).contains(n.int64Value) else { return nil }
        return n.intValue
    }

    /// Registry metadata is additional evidence, never an override of topology.
    private static func metadata(_ node: USBScan.Entry, required: Bool, page expectedPage: Int?, usage expectedUsage: Int?) -> Bool {
        if let value = node.properties["Built-In"] {
            guard let n = value as? NSNumber,
                  CFGetTypeID(n) == CFBooleanGetTypeID() ? !n.boolValue : integer(value) == 0 else { return false }
        }
        let p = node.properties
        let page = integer(p["PrimaryUsagePage"]), usage = integer(p["PrimaryUsage"])
        if required || p["PrimaryUsagePage"] != nil || p["PrimaryUsage"] != nil {
            guard let page, page >= 0xff00, let usage else { return false }
            if required && (page != expectedPage || usage != expectedUsage) { return false }
        }
        if required || p["DeviceUsagePairs"] != nil {
            guard let pairs = p["DeviceUsagePairs"] as? [[String: Any]],
                  (1...16).contains(pairs.count), pairs.allSatisfy({ pair in
                      guard let pp = integer(pair["DeviceUsagePage"]), pp >= 0xff00,
                            let uu = integer(pair["DeviceUsage"]) else { return false }
                      return page == nil || (pp == page && uu == usage)
                  }) else { return false }
        }
        return true
    }

    private static func validString(_ s: String) -> Bool {
        s.utf16.count <= 126 && !s.utf8.contains(0)
    }

    /// Mirrors usb-host-hid's bounded subset, not a general HID parser. The
    /// native backend remains authoritative and checks again at device_add.
    static func accepts(_ data: Data, page expectedPage: Int?, usage expectedUsage: Int?) -> Bool {
        guard !data.isEmpty, data.count <= 1024 else { return false }
        let bytes = Array(data)
        var offset = 0, page = 0, size = 0, count = 0, id = 0, depth = 0, apps = 0
        var numbered = false, zero = false, input = false
        var localPage: Int?, localUsage: Int?
        var bits: [Int: Int] = [:]
        while offset < bytes.count {
            let tag = Int(bytes[offset])
            offset += 1
            let n = tag & 3 == 3 ? 4 : tag & 3
            guard tag != 0xfe, n <= bytes.count - offset else { return false }
            var value = 0
            for i in 0..<n { value |= Int(bytes[offset + i]) << (8 * i) }
            offset += n
            switch tag & 0xfc {
            case 0x04:
                page = value
                guard (0xff00...0xffff).contains(page) else { return false }
            case 0x74: size = value
            case 0x94: count = value
            case 0x84:
                guard (1...255).contains(value), !zero else { return false }
                id = value
                numbered = true
            case 0xa0:
                guard page >= 0xff00, depth < 8 else { return false }
                if depth == 0 {
                    apps += 1
                    guard value == 1, apps == 1, localPage == expectedPage, localUsage == expectedUsage,
                          localPage != nil, localUsage != nil else { return false }
                }
                depth += 1
            case 0xc0:
                guard depth > 0, n == 0 else { return false }
                depth -= 1
            case 0x80, 0x90, 0xb0:
                guard depth > 0, (1...32).contains(size), (1...512).contains(count) else { return false }
                let key = (tag & 0xfc) * 256 + id
                let total = (bits[key] ?? 0) + size * count
                guard total <= (id == 0 ? 512 : 504) else { return false }
                if id == 0 { zero = true; if numbered { return false } }
                bits[key] = total
                input = input || tag & 0xfc == 0x80
            case 0x08, 0x18, 0x28:
                if n == 4 && value >> 16 < 0xff00 { return false }
                if tag & 0xfc == 0x08 {
                    localPage = n == 4 ? value >> 16 : page
                    localUsage = value & 0xffff
                }
            case 0x14, 0x24, 0x34, 0x44, 0x54, 0x64: break
            default: return false
            }
        }
        return input && apps == 1 && depth == 0
    }
}

extension USBScan {
    /// Only the selected physical USB subtree is read. No IOHID open or manager.
    public struct Entry {
        public var registryID: UInt64
        public var className: String
        public var name: String
        public var conforms: Set<String>
        public var properties: [String: Any]
        public var children: [Entry]
        public var complete: Bool

        public init(registryID: UInt64, className: String, name: String = "", conforms: Set<String> = [],
                    properties: [String: Any] = [:], children: [Entry] = [], complete: Bool = true) {
            self.registryID = registryID
            self.className = className
            self.name = name
            self.conforms = conforms
            self.properties = properties
            self.children = children
            self.complete = complete
        }

        func isA(_ cls: String) -> Bool { className == cls || conforms.contains(cls) }
        func number(_ key: String) -> Int? { (properties[key] as? NSNumber)?.intValue }
        func string(_ key: String) -> String? { properties[key] as? String }
        var descendants: [Entry] { [self] + children.flatMap(\.descendants) }
        var user: String {
            if className.contains("UserClient") || className.contains("FrameworkInterfaceClient") {
                return name.split(separator: "@").first.map(String.init) ?? name
            }
            return className
        }
    }

    static func readEntry(_ e: io_registry_entry_t, depth: Int, budget: inout Int) -> Entry {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(e, &id)
        var node = Entry(registryID: id, className: className(e))
        guard depth < 16, budget > 0 else { node.complete = false; return node }
        budget -= 1
        if IOObjectConformsTo(e, "IOHIDDevice") != 0 { node.conforms.insert("IOHIDDevice") }
        for key in ["idVendor", "idProduct", "bDeviceClass", "bInterfaceClass", "bInterfaceSubClass",
                    "bInterfaceProtocol", "VendorID", "ProductID", "SerialNumber", "Product", "Transport", "ReportDescriptor",
                    "Built-In", "PrimaryUsagePage", "PrimaryUsage", "DeviceUsagePairs"] {
            node.properties[key] = property(e, key)
        }
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(e, kIOServicePlane, &it) == KERN_SUCCESS, it != 0 else {
            node.complete = false
            return node
        }
        defer { IOObjectRelease(it) }
        while case let child = IOIteratorNext(it), child != 0 {
            node.children.append(readEntry(child, depth: depth + 1, budget: &budget))
            IOObjectRelease(child)
            if budget == 0 { node.complete = false; break }
        }
        if IOIteratorIsValid(it) == 0 { node.complete = false }
        return node
    }
}
