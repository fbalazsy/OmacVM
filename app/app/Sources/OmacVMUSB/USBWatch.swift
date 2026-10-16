import Foundation
import IOKit

/// The Mac's USB devices coming and going, from IOKit's notifications on
/// the main run loop: the devices there at `start`, then each one plugged
/// in, once macOS has set it up (its drivers matched: IOServiceWaitQuiet, at
/// most 2 s, so a USB stick is seen as a disk, not as free), and each one
/// unplugged, by its place (locationID). Reads the IORegistry only, opens no
/// device. With `hid` (the VM's "Vendor HID devices" switch on) it also reads
/// each device's HID part and reads a device again when macOS publishes or
/// removes one. Main thread.
public final class USBWatch {
    public var onPlug: (USBDevice) -> Void = { _ in }
    public var onUnplug: (UInt32) -> Void = { _ in }
    public var onUnplugGeneration: ((UInt32, UInt64) -> Void)?

    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    /// IORegistry entry id -> locationID (a removed entry can no longer be read).
    private var places: [UInt64: UInt32] = [:]
    /// Being read (settling), and those of them that left meanwhile.
    private var settling = Set<UInt64>()
    private var leftEarly = Set<UInt64>()
    private let hid: Bool
    private let coexistencePID: Int32?
    private var hidAdded: io_iterator_t = 0
    private var hidRemoved: io_iterator_t = 0
    /// A HID part's IORegistry entry id -> its USB device's (as reported).
    private var hidParts: [UInt64: UInt64] = [:]
    /// Read again while its first read still ran: reported right after it.
    private var again: [UInt64: USBDevice] = [:]
    private let settle = DispatchQueue(label: "org.omacvm.usb-watch", qos: .utility, attributes: .concurrent)
    private var running = false

    public init(hid: Bool = false, coexistencePID: Int32? = nil) {
        self.hid = hid
        self.coexistencePID = coexistencePID
    }

    public func start() {
        guard !running, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        running = true
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), { ref, it in
            guard let ref else { return }
            Unmanaged<USBWatch>.fromOpaque(ref).takeUnretainedValue().arrived(it)
        }, me, &added)
        IOServiceAddMatchingNotification(p, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), { ref, it in
            guard let ref else { return }
            Unmanaged<USBWatch>.fromOpaque(ref).takeUnretainedValue().left(it)
        }, me, &removed)
        if hid {
            IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"), { ref, it in
                guard let ref else { return }
                Unmanaged<USBWatch>.fromOpaque(ref).takeUnretainedValue().hidArrived(it)
            }, me, &hidAdded)
            IOServiceAddMatchingNotification(p, kIOTerminatedNotification, IOServiceMatching("IOHIDDevice"), { ref, it in
                guard let ref else { return }
                Unmanaged<USBWatch>.fromOpaque(ref).takeUnretainedValue().hidLeft(it)
            }, me, &hidRemoved)
        }
        // Arms the notifications and reports the devices there now (set up already: no wait).
        arrived(added, initial: true)
        left(removed)
        // The HID parts there now came with their devices.
        for it in [hidAdded, hidRemoved] where it != 0 {
            while case let e = IOIteratorNext(it), e != 0 { IOObjectRelease(e) }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        if added != 0 { IOObjectRelease(added); added = 0 }
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        if hidAdded != 0 { IOObjectRelease(hidAdded); hidAdded = 0 }
        if hidRemoved != 0 { IOObjectRelease(hidRemoved); hidRemoved = 0 }
        if let p = port {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
            IONotificationPortDestroy(p)
        }
        port = nil
        places.removeAll()
        settling.removeAll()
        leftEarly.removeAll()
        hidParts.removeAll()
        again.removeAll()
    }

    private func arrived(_ it: io_iterator_t, initial: Bool = false) {
        while case let dev = IOIteratorNext(it), dev != 0 {
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(dev, &entry)
            settling.insert(entry)
            let hid = self.hid
            let coexistencePID = self.coexistencePID
            // Read off the main thread: waiting for macOS's drivers takes up to 2 s.
            settle.async { [weak self] in
                if !initial {
                    var wait = mach_timespec_t(tv_sec: 2, tv_nsec: 0)
                    _ = IOServiceWaitQuiet(dev, &wait)
                    // Apps that use a device (usbmuxd, usbaudiod) open it a moment after the drivers.
                    Thread.sleep(forTimeInterval: 0.5)
                }
                let d = USBScan.device(dev, hid: hid, coexistencePID:coexistencePID)
                IOObjectRelease(dev)
                DispatchQueue.main.async {
                    guard let self, self.running else { return }
                    self.settling.remove(entry)
                    let later = self.again.removeValue(forKey: entry)
                    // Gone before it was set up: never reported.
                    if self.leftEarly.remove(entry) != nil { return }
                    guard let d else { return }
                    self.places[entry] = d.location
                    self.report(d, entry: entry)
                    if let later { self.report(later, entry: entry) }
                }
            }
        }
    }

    private func left(_ it: io_iterator_t) {
        while case let dev = IOIteratorNext(it), dev != 0 {
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(dev, &entry)
            IOObjectRelease(dev)
            if settling.contains(entry) {
                leftEarly.insert(entry)
            } else if let loc = places.removeValue(forKey: entry) {
                hidParts = hidParts.filter { $0.value != entry }
                if let onUnplugGeneration { onUnplugGeneration(loc,entry) }
                else { onUnplug(loc) }
            }
        }
    }

    private func report(_ d: USBDevice, entry: UInt64) {
        hidParts = hidParts.filter { $0.value != entry }
        if let h = d.hid { hidParts[h.registryID] = entry }
        else if let c = d.coexistence { hidParts[c.target.hid] = entry }
        onPlug(d)
    }

    // MARK: HID parts (the switch on only)

    // macOS publishes a device's HID part a moment after the device (at times
    // after the read above), and can replace or remove it while the device
    // stays. Then the device is read and reported again; USBSession compares
    // its HID part (QEMU's usb-host-hid is tied to the one it opened).

    private func hidArrived(_ it: io_iterator_t) {
        while case let part = IOIteratorNext(it), part != 0 {
            var dev = part
            IOObjectRetain(dev)
            IOObjectRelease(part)
            // Up to its USB device (none: built in, Bluetooth).
            for _ in 0..<8 where IOObjectConformsTo(dev, "IOUSBHostDevice") == 0 {
                var parent: io_registry_entry_t = 0
                let found = IORegistryEntryGetParentEntry(dev, kIOServicePlane, &parent) == KERN_SUCCESS
                IOObjectRelease(dev)
                dev = found ? parent : 0
                if dev == 0 { break }
            }
            guard dev != 0, IOObjectConformsTo(dev, "IOUSBHostDevice") != 0 else {
                if dev != 0 { IOObjectRelease(dev) }
                continue
            }
            readAgain(dev)
        }
    }

    private func hidLeft(_ it: io_iterator_t) {
        while case let part = IOIteratorNext(it), part != 0 {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(part, &id)
            IOObjectRelease(part)
            // Only a part a device was reported with; its device, if still there.
            guard let entry = hidParts.removeValue(forKey: id) else { continue }
            let dev = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(entry))
            if dev != 0 { readAgain(dev) }
        }
    }

    /// Reads a reported device again (takes `dev`'s reference).
    private func readAgain(_ dev: io_registry_entry_t) {
        var entry: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(dev, &entry)
        guard places[entry] != nil || settling.contains(entry) else {
            IOObjectRelease(dev)
            return
        }
        let coexistencePID = self.coexistencePID
        settle.async { [weak self] in
            var wait = mach_timespec_t(tv_sec: 2, tv_nsec: 0)
            _ = IOServiceWaitQuiet(dev, &wait)
            Thread.sleep(forTimeInterval: 0.5)
            let d = USBScan.device(dev, hid: true, coexistencePID:coexistencePID)
            IOObjectRelease(dev)
            DispatchQueue.main.async {
                guard let self, self.running, let d else { return }
                if self.settling.contains(entry) {
                    self.again[entry] = d
                } else if self.places[entry] != nil {
                    self.report(d, entry: entry)
                }
            }
        }
    }
}
