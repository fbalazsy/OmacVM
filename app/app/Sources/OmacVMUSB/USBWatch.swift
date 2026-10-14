import Foundation
import IOKit

/// The Mac's USB devices coming and going, from IOKit's notifications on
/// the main run loop: the devices there at `start`, then each one plugged
/// in, once macOS has set it up (its drivers matched: IOServiceWaitQuiet, at
/// most 2 s, so a USB stick is seen as a disk, not as free), and each one
/// unplugged, by its place (locationID). Reads the IORegistry only, opens no
/// device. Main thread.
public final class USBWatch {
    public var onPlug: (USBDevice) -> Void = { _ in }
    public var onUnplug: (UInt32) -> Void = { _ in }

    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private var hidAdded: io_iterator_t = 0
    private var reads = Reads()
    private let settle = DispatchQueue(label: "org.omacvm.usb-watch", qos: .utility, attributes: .concurrent)
    private var running = false

    /// Correlates asynchronous reads with the notification that requested them.
    public struct Reads {
        private var places: [UInt64: UInt32] = [:]
        private var pending: [UInt64: UInt64] = [:]
        private var settling = Set<UInt64>()
        private var leftEarly = Set<UInt64>()
        private var hidEntries = Set<UInt64>()
        // Keep the watermark through removal: an older first read may still finish.
        private var latest: [UInt32: UInt64] = [:]
        private var sequence: UInt64 = 0
        public init() {}
        public mutating func begin(_ entry: UInt64, publication: Bool = false) -> UInt64 {
            if !publication { settling.insert(entry) }
            sequence += 1
            pending[entry] = sequence
            return sequence
        }
        public mutating func finish(_ entry: UInt64, ticket: UInt64, location: UInt32,
                                    hid: Bool = true, publication: Bool = false) -> Bool {
            if !hid && !hidEntries.contains(entry) {
                // HID publication must not duplicate or reorder ordinary notifications.
                guard !publication else { return false }
                settling.remove(entry)
                if pending[entry] == ticket { pending[entry] = nil }
                if leftEarly.remove(entry) != nil { return false }
                // Only an already-observed target generation owns this watermark.
                if ticket < (latest[location] ?? 0) { return false }
                // An ordinary replacement also retires the old HID generation.
                // Do not change ordinary-to-ordinary notification semantics.
                for (old, place) in places where old != entry && place == location && hidEntries.contains(old) {
                    places[old] = nil; pending[old] = nil
                    latest[location] = ticket
                }
                places[entry] = location
                return true
            }
            settling.remove(entry)
            hidEntries.insert(entry)
            guard pending[entry] == ticket else { return false }
            pending[entry] = nil
            guard ticket > (latest[location] ?? 0) else { return false }
            latest[location] = ticket
            for (old, place) in places where old != entry && place == location {
                places[old] = nil
                pending[old] = nil
            }
            places[entry] = location
            return true
        }
        public mutating func remove(_ entry: UInt64) -> UInt32? {
            pending[entry] = nil
            if !hidEntries.contains(entry), settling.contains(entry) {
                leftEarly.insert(entry)
                return nil
            }
            return places.removeValue(forKey: entry)
        }
        public mutating func clear() {
            places.removeAll(); pending.removeAll(); latest.removeAll()
            settling.removeAll(); leftEarly.removeAll(); hidEntries.removeAll()
        }
    }

    public init() {}

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
        // IOHIDDevice can publish after the USB parent's quiet period. Watch
        // that publication too; a fixed retry window would silently miss it.
        IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"), { ref, it in
            guard let ref else { return }
            Unmanaged<USBWatch>.fromOpaque(ref).takeUnretainedValue().hidArrived(it)
        }, me, &hidAdded)
        arrived(added, initial: true)
        left(removed)
        hidArrived(hidAdded)
    }

    public func stop() {
        guard running else { return }
        running = false
        if added != 0 { IOObjectRelease(added); added = 0 }
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        if hidAdded != 0 { IOObjectRelease(hidAdded); hidAdded = 0 }
        if let p = port {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
            IONotificationPortDestroy(p)
        }
        port = nil
        reads.clear()
    }

    private func arrived(_ it: io_iterator_t, initial: Bool = false) {
        while case let dev = IOIteratorNext(it), dev != 0 { read(dev, initial: initial) }
    }

    private func hidArrived(_ it: io_iterator_t) {
        while case var entry = IOIteratorNext(it), entry != 0 {
            for _ in 0..<16 {
                if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 { read(entry, initial: false, publication: true); entry = 0; break }
                var parent: io_registry_entry_t = 0
                let found = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
                IOObjectRelease(entry)
                entry = found ? parent : 0
                if !found { break }
            }
            if entry != 0 { IOObjectRelease(entry) }
        }
    }

    /// Consumes the retained entry; every result is tied to this notification.
    private func read(_ dev: io_registry_entry_t, initial: Bool, publication: Bool = false) {
        var entry: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(dev, &entry)
        let ticket = reads.begin(entry, publication: publication)
        settle.async { [weak self] in
            if !initial {
                var wait = mach_timespec_t(tv_sec: 2, tv_nsec: 0)
                _ = IOServiceWaitQuiet(dev, &wait)
                Thread.sleep(forTimeInterval: 0.5)
            }
            let d = USBScan.device(dev)
            IOObjectRelease(dev)
            DispatchQueue.main.async {
                guard let self, self.running, let d,
                      self.reads.finish(entry, ticket: ticket, location: d.location, hid: d.hid != nil, publication: publication) else { return }
                self.onPlug(d)
            }
        }
    }

    private func left(_ it: io_iterator_t) {
        while case let dev = IOIteratorNext(it), dev != 0 {
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(dev, &entry)
            IOObjectRelease(dev)
            if let loc = reads.remove(entry) {
                onUnplug(loc)
            }
        }
    }
}
