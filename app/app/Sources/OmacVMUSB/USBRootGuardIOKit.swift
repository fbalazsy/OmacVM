import Foundation
import IOKit
import IOKit.usb
import Darwin

/// Existing launcher task only. Constructing this adapter does not touch IOKit.
/// All acquired objects, notification delivery and release belong to guard queue.
final class USBRootGuardIOKit: USBRootGuardDriver {
    private let launcherPID: Int32
    private var service: io_service_t = 0
    private var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    private var usb: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>?
    private var port: IONotificationPortRef?
    private var notice: io_object_t = 0
    private var event: ((USBRootGuardError) -> Void)?
    init(launcherPID: Int32) { self.launcherPID = launcherPID }

    private func require(_ result: kern_return_t, _ operation: String) throws {
        guard result == KERN_SUCCESS else { throw USBRootGuardError.native("\(operation): \(result)") }
    }
    private let registry = USBRootGuardRegistryLookup(iterate:{
        // Matching sees published services only, not every registry object.
        // Full recursive plane iteration includes unregistered IOUserClients.
        var iterator: io_iterator_t = 0
        let result = IORegistryCreateIterator(kIOMainPortDefault,kIOServicePlane,
                                             IOOptionBits(kIORegistryIterateRecursively),&iterator)
        return (result,iterator)
    }, next:{ IOIteratorNext($0) }, valid:{ IOIteratorIsValid($0) != 0 }, identity:{ entry in
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry,&id) == KERN_SUCCESS ? id : nil
    }, release:{ _ = IOObjectRelease($0) })
    private lazy var drainClose = USBRootGuardCloseBoundary(close:{ [weak self] in
        guard let self, let usb = self.usb, let close = usb.pointee?.pointee.USBDeviceClose else { return kIOReturnError }
        return close(usb)
    }, presence:{ [weak self] in self?.registry.presence($0) ?? .unknown },
       dispose:{ [unowned self] in self.release() })

    private func exactService(_ rootID: UInt64) throws -> io_service_t {
        guard let s = try registry.service(rootID) else { throw USBRootGuardError.rootAbsent }
        guard IOObjectConformsTo(s,"IOUSBHostDevice") != 0,
              service == 0 || IOObjectIsEqualTo(service,s) != 0 else {
            IOObjectRelease(s); throw USBRootGuardError.lost
        }
        return s
    }
    func snapshot(rootID: UInt64) throws -> USBScan.Entry {
        let s = try exactService(rootID)
        defer { IOObjectRelease(s) }
        // Source-limited admission snapshot, NOT CreateCFProperties equality.
        // Retain every original policy input; add generation/creator identity.
        var budget = 64
        func read(_ entry: io_registry_entry_t, depth: Int) -> USBScan.Entry {
            var id: UInt64 = 0
            var node = USBScan.Entry(registryID:0,className:USBScan.className(entry))
            guard depth < 16, budget > 0, IORegistryEntryGetRegistryEntryID(entry,&id) == KERN_SUCCESS, id != 0 else {
                node.complete = false; return node
            }
            node.registryID = id; budget -= 1
            if IOObjectConformsTo(entry,"IOHIDDevice") != 0 { node.conforms.insert("IOHIDDevice") }
            for key in ["idVendor","idProduct","bDeviceClass","bInterfaceClass","bInterfaceSubClass",
                        "bInterfaceProtocol","VendorID","ProductID","SerialNumber","Product","Transport","ReportDescriptor",
                        "Built-In","PrimaryUsagePage","PrimaryUsage","DeviceUsagePairs",
                        "built-in","sessionID","USB Serial Number","IOUserClientCreator"] {
                node.properties[key] = USBScan.property(entry,key)
            }
            var iterator: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(entry,kIOServicePlane,&iterator) == KERN_SUCCESS, iterator != 0 else {
                node.complete = false; return node
            }
            defer { IOObjectRelease(iterator) }
            while case let child = IOIteratorNext(iterator), child != 0 {
                if budget == 0 { IOObjectRelease(child); node.complete = false; break }
                node.children.append(read(child,depth:depth+1)); IOObjectRelease(child)
            }
            if IOIteratorIsValid(iterator) == 0 { node.complete = false }
            return node
        }
        return read(s,depth:0)
    }
    func create(rootID: UInt64) throws {
        guard launcherPID == getpid(), service == 0, plugin == nil, usb == nil else { throw USBRootGuardError.refused }
        service = try exactService(rootID)
        var score: Int32 = 0
        try require(IOCreatePlugInInterfaceForService(service,
            CFUUIDGetConstantUUIDWithBytes(nil,0x9d,0xc7,0xb7,0x80,0x9e,0xc0,0x11,0xd4,0xa5,0x4f,0x00,0x0a,0x27,0x05,0x28,0x61),
            CFUUIDGetConstantUUIDWithBytes(nil,0xc2,0x44,0xe8,0x58,0x10,0x9c,0x11,0xd4,0x91,0xd4,0x00,0x50,0xe4,0xc6,0x42,0x6f),&plugin,&score),"create plugin")
        guard let plugin, let query = plugin.pointee?.pointee.QueryInterface else { throw USBRootGuardError.refused }
        let uuid = CFUUIDGetConstantUUIDWithBytes(nil,0x5c,0x81,0x87,0xd0,0x9e,0xf3,0x11,0xd4,0x8b,0x45,0x00,0x0a,0x27,0x05,0x28,0x61)!
        var raw: UnsafeMutableRawPointer?
        let result = query(UnsafeMutableRawPointer(plugin),CFUUIDGetUUIDBytes(uuid),&raw)
        usb = raw?.assumingMemoryBound(to:UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
        guard result == 0, usb?.pointee != nil else { throw USBRootGuardError.native("QueryInterface: \(result)") }
    }
    func monitor(queue: DispatchQueue, event: @escaping (USBRootGuardError) -> Void) throws {
        guard service != 0, port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { throw USBRootGuardError.refused }
        self.event = event; port = p
        IONotificationPortSetDispatchQueue(p,queue)
        try require(IOServiceAddInterestNotification(p,service,kIOGeneralInterest,{ context,_,message,_ in
            guard let context else { return }
            let owner = Unmanaged<USBRootGuardIOKit>.fromOpaque(context).takeUnretainedValue()
            // IOMessage.h compound macros are not imported by Swift. Keep
            // these SDK values covered by the compiled C-enum callback replay.
            if message == 0xe0000100 { owner.event?(.requestingClose) } // kIOMessageServiceIsRequestingClose
            else if message == 0xe0000010 || message == 0xe0000110 { owner.event?(.lost) }
        },Unmanaged.passUnretained(self).toOpaque(),&notice),"interest")
        guard notice != 0 else { throw USBRootGuardError.refused }
    }
    func open() throws {
        guard let usb, let open = usb.pointee?.pointee.USBDeviceOpen else { throw USBRootGuardError.refused }
        try require(open(usb),"USBDeviceOpen")
    }
    func close() throws {
        guard let usb, let close = usb.pointee?.pointee.USBDeviceClose else { throw USBRootGuardError.refused }
        try require(close(usb),"USBDeviceClose")
    }
    func closeAfterDrain(rootID: UInt64, clientIDs: [UInt64], allowGone: Bool) throws -> USBRootGuardDisposition {
        try drainClose.closeAfterDrain(rootID:rootID,clientIDs:clientIDs,allowGone:allowGone)
    }
    func release() {
        if notice != 0 { IOObjectRelease(notice); notice = 0 }
        if let port { IONotificationPortSetDispatchQueue(port,nil); IONotificationPortDestroy(port); self.port = nil }
        event = nil
        if let usb { _ = usb.pointee?.pointee.Release(usb); self.usb = nil }
        if let plugin { _ = plugin.pointee?.pointee.Release(plugin); self.plugin = nil }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }
}
