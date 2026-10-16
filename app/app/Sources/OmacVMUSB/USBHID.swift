import Foundation
import IOKit

// Vendor HID devices (docs/usb.md; by @fbalazsy, #424): boards that talk to
// their tools in HID reports of their own (ECU interfaces, bootloaders,
// programmers). macOS's HID driver holds them, so usb-host (libusb) cannot
// take them; QEMU's usb-host-hid (patch qemu-usb-host-hid.patch) passes their
// reports through IOHIDDevice instead, without root. Only while the VM's
// switch is on: then the app also reads a device's HID part (here, from the
// IORegistry, nothing opened) and USBQMP adds usb-host-hid for it.

/// The VM's "Vendor HID devices" switch (experimental, off by default): the
/// file `usb-vendor-hid` in the VM's folder says "on" or "off". Read at each
/// start, with the USB switch (it does nothing while that one is off). Off:
/// no HID part is read, no HID publication is watched, usb-host-hid is never
/// added; USB devices work as before.
public enum USBVendorHID {
    public static let fileName = "usb-vendor-hid"

    public static func isOn(fileText: String?) -> Bool {
        fileText?.trimmingCharacters(in: .whitespacesAndNewlines) == "on"
    }

    public static func isOn(folder: URL) -> Bool {
        isOn(fileText: try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8))
    }

    public static func set(_ on: Bool, folder: URL) throws {
        try Data((on ? "on" : "off").appending("\n").utf8).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }
}

/// A device's HID part, as QEMU's usb-host-hid takes it: the IOHIDDevice's
/// registry id (a new one each time macOS publishes it) and the serial
/// number. Only a hint: QEMU checks the device again before it opens it.
public struct USBHID: Equatable, Sendable {
    public let registryID: UInt64
    public let serial: String

    public init(registryID: UInt64, serial: String) {
        self.registryID = registryID
        self.serial = serial
    }

    /// Worth reading the HID part of: one interface, a HID one.
    public static func candidate(_ d: USBDevice) -> Bool {
        d.interfaces.count == 1 && d.interfaces[0].interfaceClass == 3
    }

    // Byte for byte, as QEMU compares it (Swift's == folds Unicode forms).
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.registryID == rhs.registryID && Array(lhs.serial.utf8) == Array(rhs.serial.utf8)
    }

    /// The device's HID part when QEMU's usb-host-hid would take it (the same
    /// checks, from the IORegistry): one HID interface without boot protocol,
    /// one IOHIDDevice on it with nothing but its IOHIDInterface, a vendor
    /// usage page in the metadata and in the report descriptor (keyboards,
    /// mice, game controllers, security keys never), a serial number.
    public static func resolve(_ root: USBScan.Entry) -> USBHID? {
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
    /// The device as `device(_:)` reads it and, with `hid` (the switch on),
    /// its HID part when it is a vendor HID device. Without `hid` exactly
    /// `device(_:)`.
    public static func device(_ dev: io_registry_entry_t, hid: Bool, coexistencePID: Int32? = nil) -> USBDevice? {
        guard var d = device(dev) else { return nil }
        if hid {
            var rootID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(dev, &rootID) == KERN_SUCCESS, rootID != 0 { d.coexistenceRootID = rootID }
        }
        if hid, USBHID.candidate(d) {
            var budget = 128
            let root = readEntry(dev, depth: 0, budget: &budget)
            d.coexistence = USBCoexistenceCandidate.resolve(root,qemuPID:coexistencePID)
            d.hid = d.coexistence.map { USBHID(registryID:$0.target.hid,serial:String(decoding:$0.target.serial,as:UTF8.self)) }
        }
        return d
    }

    /// One device's part of the IORegistry, as a tree (properties only).
    public struct Entry {
        public var registryID: UInt64
        public var className: String
        public var conforms: Set<String>
        public var properties: [String: Any]
        public var children: [Entry]
        public var complete: Bool

        public init(registryID: UInt64, className: String, conforms: Set<String> = [],
                    properties: [String: Any] = [:], children: [Entry] = [], complete: Bool = true) {
            self.registryID = registryID
            self.className = className
            self.conforms = conforms
            self.properties = properties
            self.children = children
            self.complete = complete
        }

        func isA(_ cls: String) -> Bool { className == cls || conforms.contains(cls) }
        func string(_ key: String) -> String? { properties[key] as? String }
        var descendants: [Entry] { [self] + children.flatMap(\.descendants) }
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
                    "Built-In", "PrimaryUsagePage", "PrimaryUsage", "DeviceUsagePairs",
                    "built-in", "sessionID", "USB Serial Number", "IOUserClientCreator"] {
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
