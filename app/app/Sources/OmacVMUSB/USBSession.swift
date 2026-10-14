import Foundation

// While the VM runs with the USB switch on: what happens to each device
// plugged into the Mac (docs/usb.md). Nothing goes to the VM by itself: a
// device the VM may have is asked about once per plug-in ("Connect “ST-Link
// V2” to Omarchy or keep it on the Mac?"), unless the user said "Always do
// this for this device" before (USBMemory). The answer for this plug-in only
// lasts until the device is unplugged or the VM stops. Devices macOS uses are
// never asked about.
//
// USBSession is the decisions only; what it acts on is behind three
// protocols, so `swift run usb-tests` runs all of it without a device, a VM
// or a window: the VM (USBMachine: QMP in the app), the question
// (USBAsker: an alert in the app) and the time (USBClock).

/// The VM: gives a device to it and takes it back. Calls back on the
/// session's thread (the app's main thread), in the order asked.
public protocol USBMachine: AnyObject {
    func attach(_ device: USBDevice, done: @escaping (USBAttachResult) -> Void)
    func detach(_ device: USBDevice, done: @escaping (Bool) -> Void)
    /// Does the VM still have it (after the Mac saw it go)?
    func isAttached(_ device: USBDevice, done: @escaping (Bool) -> Void)
}

/// The question, and a short notice when something did not work.
public protocol USBAsker: AnyObject {
    /// Shows the question; `answer` is called once, unless `cancel` closed it first.
    func ask(_ question: USBQuestion, answer: @escaping (USBAnswer) -> Void)
    /// Closes the open question without an answer (the device was unplugged, the VM stopped).
    func cancel()
    func notice(title: String, text: String)
}

public protocol USBClock: AnyObject {
    func after(_ seconds: Double, _ run: @escaping () -> Void)
}

public struct USBAnswer: Equatable, Sendable {
    public var connect: Bool
    /// "Always do this for this device" (unchecked by default).
    public var always: Bool
    public init(connect: Bool, always: Bool) {
        self.connect = connect
        self.always = always
    }
}

/// The words of the question (built here, tested; the app only shows them).
public struct USBQuestion: Equatable, Sendable {
    public var title: String
    public var text: String
    public var detail: String
    public var connect: String
    public var keep: String
    public var always: String
    /// The device it is about (USBDevice.location).
    public var location: UInt32

    public init(device d: USBDevice, vmName: String, waiting: Int) {
        let vm = vmName.isEmpty ? "the VM" : vmName
        let named = !USBChoice.clean(d.name).isEmpty
        title = named ? "Connect “\(USBChoice.clean(d.name))” to \(vm) or keep it on the Mac?"
                      : "Connect this USB device to \(vm) or keep it on the Mac?"
        text = "\(vm) can use it while it runs. The Mac gets it back when you unplug it or \(vm) shuts down."
        var parts: [String] = []
        if !d.maker.isEmpty { parts.append(USBChoice.clean(d.maker)) }
        parts.append(d.id.description)
        detail = parts.joined(separator: " · ")
            + (waiting == 1 ? "\n1 more device waiting" : waiting > 1 ? "\n\(waiting) more devices waiting" : "")
        connect = "Connect to \(vm)"
        keep = "Keep on Mac"
        always = "Always do this for this device"
        location = d.location
    }
}

public final class USBSession {
    /// QEMU's xHCI controller has four ports of each speed.
    public static let maxConnected = 4
    /// A device that leaves and comes back at the same place within this
    /// time while the VM has it is the same plug: on macOS a reset (Linux
    /// asks for one: DFU, firmware tools) makes it leave and come back
    /// (USBWatch reports it again after up to 2.5 s of setting up).
    public static let grace = 4.0

    public enum State: Equatable, Sendable {
        /// A hub or a USB-C info device: never shown.
        case ignored
        /// macOS uses it (why): never asked about.
        case kept(String)
        /// To be asked once the VM is in front.
        case waiting
        case asking
        case connecting
        case connected
        case disconnecting
        case releaseFailed
        /// Unplugged while the VM had it: waiting `grace` for it to come back.
        case leaving
        /// Stays with the Mac: remembered (or "this time").
        case onMac(remembered: Bool)
    }

    public struct Plug: Equatable, Sendable {
        public var device: USBDevice
        public var state: State
        /// How it got its state, for the log: "asked, this time", "remembered", ...
        public var how: String
        /// Came back at the same place while leaving.
        public var returned: USBDevice?
        var hidPath: Bool { device.hid != nil || hidIdentity != nil }
        var attachPending = false
        var leavingReady = false
        /// A question answer or Connect/Disconnect, not an automatic saved route.
        var explicitDecision = false
        /// Last reliable logical HID identity, retained through incomplete snapshots.
        var hidIdentity: String?
        /// Current Ask/Connect while metadata is unavailable, never the next-plug plan.
        var suspendedPlan: USBPlan?
    }

    public let vmName: String
    public private(set) var memory: USBMemory
    public private(set) var plugs: [UInt32: Plug] = [:]
    /// Plug order of the devices waiting for a question.
    public private(set) var queue: [UInt32] = []
    public private(set) var asking: UInt32?
    public private(set) var stopped = false

    private var present: [UInt32: USBDevice] = [:]

    /// Physical inventory, plus only unresolved HID instances after removal.
    public var rows: USBListRows {
        var inventory = present
        for p in plugs.values where p.hidPath {
            if p.state == .disconnecting || p.state == .releaseFailed || p.state == .leaving {
                inventory[p.device.location] = p.device
            } else if var d = inventory[p.device.location], d.hid == nil, d.availability == .free {
                d.hidUnavailable = "HID is still being set up"
                inventory[d.location] = d
            }
        }
        return USBListRows.make(memory: memory, devices: inventory.values.sorted { $0.location < $1.location },
                               states: plugs.mapValues(\.state), vmName: vmName)
    }

    /// The VM's window (or this app's question) is in front: only then is a
    /// question shown; until then devices wait.
    public var inFront = true {
        didSet { if inFront { askNext() } }
    }

    /// Something changed (the list follows it).
    public var onChange: (() -> Void)?

    private let machine: USBMachine
    private let asker: USBAsker
    private let clock: USBClock
    private let save: (USBMemory) -> Void
    private let log: (String) -> Void

    public init(vmName: String, memory: USBMemory, machine: USBMachine, asker: USBAsker, clock: USBClock,
                save: @escaping (USBMemory) -> Void, log: @escaping (String) -> Void) {
        self.vmName = vmName
        self.memory = memory
        self.machine = machine
        self.asker = asker
        self.clock = clock
        self.save = save
        self.log = log
    }

    // MARK: From the Mac's device list

    /// A device appeared (or was there when the VM started).
    public func plugged(_ d: USBDevice) {
        guard !stopped else { return }
        present[d.location] = d
        if var p = plugs[d.location] {
            let firstHID = !p.hidPath && d.hid != nil
            let hidRefresh = p.hidPath || d.hid != nil
            let identity = Self.hidIdentity(d)
            p.hidIdentity = p.hidIdentity ?? Self.hidIdentity(p.device)
            let replacement = p.hidPath && Self.hidReplacement(p, d)
            p.hidIdentity = p.hidIdentity ?? identity
            plugs[d.location] = p
            if case .onMac = p.state, hidRefresh, p.device != d {
                if replacement || (firstHID && !p.explicitDecision) {
                    // A different logical device gets its own plan; registry alone is not identity.
                    plugs[d.location] = nil
                    plugged(d)
                    return
                }
                // Eligibility can change without a new physical plug. Keep this
                // plug's decision; the list and Connect check fresh availability.
                p.device = d
                plugs[d.location] = p
                changed()
                return
            }
            if hidRefresh && p.device != d && (p.state == .asking || p.state == .waiting || p.suspendedPlan != nil) {
                // Complete this target refresh even when a replacement auto-connects.
                defer { askNext() }
                if p.state == .asking { asker.cancel(); asking = nil }
                queue.removeAll { $0 == d.location }
                if firstHID || replacement {
                    plugs[d.location] = nil
                    plugged(d)
                    return
                }
                let plan = p.suspendedPlan ?? .ask
                p.device = d
                if prepareHIDResume(&p, plan: plan) && plan == .ask { queue.append(d.location) }
                plugs[d.location] = p
                if p.state == .waiting && plan == .omarchy { connect(d.location, how: p.how) }
                changed()
                return
            }
            if hidRefresh && (p.device.hid != d.hid || p.device.availability != d.availability)
                && (p.state == .connected || p.state == .connecting) {
                unplugged(location: d.location)
                plugged(d)
                return
            }
            if p.state == .disconnecting || p.state == .releaseFailed || (p.hidPath && p.state == .leaving) {
                p.returned = d
                plugs[d.location] = p
                return
            }
            if case .kept = p.state, hidRefresh, d.hid != nil, p.device != d {
                // IOHIDDevice may publish after its IOUSBHostDevice parent.
                plugs[d.location] = nil
                plugged(d)
                return
            }
            // The same device back (same id and serial, still free): a reset.
            if p.state == .leaving && p.device.id == d.id && p.device.serial == d.serial && d.availability == .free {
                p.returned = d
                plugs[d.location] = p
                return
            }
            if p.state == .leaving {
                // Another device at that place: the one that left is gone.
                finishLeaving(d.location, attached: false)
            } else {
                return   // seen already
            }
        }
        let p: Plug
        switch d.availability {
        case .notOffered:
            p = Plug(device: d, state: .ignored, how: "")
        case .usedByMac(let why):
            p = Plug(device: d, state: .kept(why), how: "")
        case .free:
            switch memory.plan(for: d) {
            case .omarchy:
                plugs[d.location] = Plug(device: d, state: .waiting, how: "remembered")
                connect(d.location, how: "remembered")
                changed()
                return
            case .mac:
                p = Plug(device: d, state: .onMac(remembered: true), how: "remembered")
                log("OmacVM: USB: \(Self.label(d)) kept on the Mac (remembered)")
            case .ask:
                p = Plug(device: d, state: .waiting, how: "")
                queue.append(d.location)
            }
        }
        plugs[d.location] = p
        changed()
        askNext()
    }

    /// A device went away.
    public func unplugged(location: UInt32) {
        guard !stopped, let p = plugs[location] else { return }
        present[location] = nil
        switch p.state {
        case .asking:
            asker.cancel()
            asking = nil
            plugs[location] = nil
            log("OmacVM: USB: \(Self.label(p.device)) unplugged before an answer")
            askNext()
        case .waiting:
            queue.removeAll { $0 == location }
            plugs[location] = nil
        case .connected, .connecting:
            var q = p
            q.state = .leaving
            q.returned = nil
            plugs[location] = q
            let wasConnecting = p.state == .connecting
            clock.after(Self.grace) { [weak self] in
                guard let self, !self.stopped, self.plugs[location]?.state == .leaving else { return }
                if wasConnecting || self.plugs[location]?.hidPath == true {
                    self.finishLeaving(location, attached: false)
                    return
                }
                self.machine.isAttached(p.device) { [weak self] attached in
                    self?.finishLeaving(location, attached: attached)
                }
            }
        case .disconnecting, .releaseFailed:
            var q = p
            q.returned = nil
            plugs[location] = q
        case .leaving:
            // Back and gone again within the grace time: gone (unless it comes back once more).
            var q = p
            q.returned = nil
            plugs[location] = q
        default:
            plugs[location] = nil
        }
        changed()
    }

    /// After the grace time: the VM still has it (the device only
    /// reconnected) or it is gone; one that came back meanwhile but that the
    /// VM lost is given to it again (the user gave it for this plug-in).
    private func finishLeaving(_ location: UInt32, attached: Bool) {
        guard var p = plugs[location], p.state == .leaving else { return }
        if p.hidPath {
            // Wait for the result before deciding whether the target owns cleanup.
            if p.attachPending {
                p.leavingReady = true
                plugs[location] = p
                return
            }
            releaseHID(location, returned: p.returned, reconnect: true)
            return
        }
        if let back = p.returned {
            p.device = back
            p.returned = nil
            if attached {
                p.state = .connected
                plugs[location] = p
                log("OmacVM: USB: \(Self.label(back)) reconnected on the Mac: still with the VM")
                changed()
                return
            }
            plugs[location] = p
            machine.detach(p.device) { _ in }
            log("OmacVM: USB: \(Self.label(back)) reconnected on the Mac: giving it to the VM again")
            p.state = .waiting
            plugs[location] = p
            connect(location, how: p.how)
            return
        }
        plugs[location] = nil
        machine.detach(p.device) { _ in }
        log("OmacVM: USB: \(Self.label(p.device)) disconnected (unplugged)")
        changed()
    }

    /// The VM stopped: the Mac has every device again (QEMU closed them). An
    /// answer for this plug-in only does not carry over to the next start.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        if asking != nil { asker.cancel() }
        asking = nil
        queue.removeAll()
        plugs.removeAll()
        present.removeAll()
        changed()
    }

    // MARK: The question

    private func askNext() {
        guard !stopped, asking == nil, inFront else { return }
        queue.removeAll { plugs[$0]?.state != .waiting }
        guard let loc = queue.first, var p = plugs[loc] else { return }
        queue.removeFirst()
        p.state = .asking
        plugs[loc] = p
        asking = loc
        changed()
        asker.ask(USBQuestion(device: p.device, vmName: vmName, waiting: queue.count)) { [weak self] a in
            self?.answered(loc, a)
        }
    }

    private func answered(_ loc: UInt32, _ a: USBAnswer) {
        guard asking == loc else { return }
        asking = nil
        guard var p = plugs[loc], p.state == .asking else {
            askNext()
            return
        }
        let how = a.always ? "asked, always" : "asked, this time"
        p.explicitDecision = true
        if a.always {
            memory.remember(p.device, a.connect ? .omarchy : .mac)
            save(memory)
        }
        if a.connect {
            p.state = .waiting
            plugs[loc] = p
            connect(loc, how: how)
        } else {
            p.state = .onMac(remembered: a.always)
            p.how = how
            plugs[loc] = p
            log("OmacVM: USB: \(Self.label(p.device)) kept on the Mac (\(how))")
            changed()
        }
        askNext()
    }

    // MARK: Connect and disconnect

    private var connectedCount: Int {
        plugs.values.filter { $0.state == .connected || $0.state == .connecting || $0.state == .leaving }.count
    }

    private func connect(_ loc: UInt32, how: String) {
        guard var p = plugs[loc] else { return }
        guard !p.hidPath || (p.device.hid != nil && p.device.availability == .free) else { return }
        if connectedCount >= Self.maxConnected {
            p.state = .onMac(remembered: false)
            p.how = how
            plugs[loc] = p
            log("OmacVM: USB: \(Self.label(p.device)) not connected: the VM has \(Self.maxConnected) devices already")
            asker.notice(title: "Couldn’t connect “\(p.device.displayName)”",
                         text: "\(vmName) already has \(Self.maxConnected) USB devices. Unplug one first.")
            changed()
            return
        }
        p.state = .connecting
        p.attachPending = p.hidPath
        p.how = how
        plugs[loc] = p
        changed()
        machine.attach(p.device) { [weak self] result in
            self?.attachDone(loc, p.device, result)
        }
    }

    private func attachDone(_ loc: UInt32, _ d: USBDevice, _ result: USBAttachResult) {
        guard !stopped else { return }
        guard var p = plugs[loc], p.device == d,
              p.state == .connecting || p.state == .leaving else {
            // Unplugged meanwhile (its device_del is queued already). Another
            // device at that place now has the same QEMU id: only when nothing
            // is there may it be taken back once more.
            if result == .attached && plugs[loc] == nil { machine.detach(d) { _ in } }
            return
        }
        p.attachPending = false
        plugs[loc] = p
        if p.state == .leaving {
            if !p.hidPath {
                if result != .attached { machine.detach(d) { _ in } }
                return
            }
            if !result.requiresRelease {
                plugs[loc] = nil
                if let back = p.returned { plugged(back) }
                changed()
                return
            }
            // Unplugged while QEMU took it: the grace time decides.
            if p.leavingReady { finishLeaving(loc, attached: false) }
            return
        }
        switch result {
        case .attached:
            p.state = .connected
            plugs[loc] = p
            log("OmacVM: USB: \(Self.label(d)) connected (\(p.how))")
            if d.hid != nil { watchHID(d) }
        case .releaseRequired:
            p.state = .releaseFailed
            p.returned = d
            plugs[loc] = p
            log("OmacVM: USB: \(Self.label(d)) needs release: \(Self.why(result))")
            asker.notice(title: "Couldn’t confirm “\(d.displayName)”", text: Self.noticeText(result, vmName: vmName, hid: p.hidPath))
        case .busy, .gone, .full, .failed:
            p.state = .onMac(remembered: false)
            plugs[loc] = p
            log("OmacVM: USB: \(Self.label(d)) not connected: \(Self.why(result))")
            if result != .gone {
                asker.notice(title: "Couldn’t connect “\(d.displayName)”", text: Self.noticeText(result, vmName: vmName, hid: p.hidPath))
            }
        }
        changed()
    }

    /// Gives a plugged-in device to the VM now (the list's Connect).
    public func connectNow(location: UInt32) {
        guard !stopped, var p = plugs[location] else { return }
        switch p.state {
        case .onMac, .waiting:
            p.explicitDecision = true
            plugs[location] = p
            queue.removeAll { $0 == location }
            connect(location, how: "from the list")
        default:
            return
        }
    }

    /// Gives it back to the Mac now (the list's Disconnect).
    public func disconnectNow(location: UInt32) {
        guard !stopped, var p = plugs[location], p.state == .connected || p.state == .releaseFailed else { return }
        p.explicitDecision = true
        plugs[location] = p
        if p.device.hid != nil || p.state == .releaseFailed {
            releaseHID(location, returned: p.state == .connected ? p.device : p.returned, reconnect: false)
            return
        }
        p.state = .onMac(remembered: false)
        p.how = "from the list"
        plugs[location] = p
        machine.detach(p.device) { _ in }
        log("OmacVM: USB: \(Self.label(p.device)) disconnected (from the list)")
        changed()
    }

    /// IOHID loss/overflow detaches irreversibly; do not leave a stale Connected
    /// row or silently reopen it. The existing list offers an explicit retry.
    private func watchHID(_ d: USBDevice) {
        clock.after(1) { [weak self] in
            guard let self, !self.stopped, self.plugs[d.location]?.device == d,
                  self.plugs[d.location]?.state == .connected else { return }
            self.machine.isAttached(d) { [weak self] attached in
                guard let self, !self.stopped, self.plugs[d.location]?.device == d,
                      self.plugs[d.location]?.state == .connected else { return }
                if attached { self.watchHID(d) } else {
                    self.releaseHID(d.location, returned: d, reconnect: false)
                    self.asker.notice(title: "“\(d.displayName)” disconnected", text: "QEMU lost the HID connection. Connect again to retry.")
                }
            }
        }
    }

    /// Suspend only the current decision until its HID snapshot is ready.
    private func prepareHIDResume(_ p: inout Plug, plan: USBPlan) -> Bool {
        let ready = p.device.hid != nil && p.device.availability == .free
        p.suspendedPlan = ready ? nil : plan
        if ready { p.state = .waiting }
        else if case .usedByMac(let why) = p.device.availability { p.state = .kept(why) }
        else { p.state = .kept("HID is still being set up") }
        return ready
    }

    /// Retain the old generation until device_del completes. A replacement can
    /// come and go meanwhile; only the latest still-present one may reconnect.
    private func releaseHID(_ loc: UInt32, returned: USBDevice?, reconnect: Bool) {
        guard var p = plugs[loc] else { return }
        let old = p.device
        p.state = .disconnecting
        p.returned = returned
        plugs[loc] = p
        changed()
        machine.detach(old) { [weak self] released in
            guard let self, !self.stopped, var current = self.plugs[loc],
                  current.device == old, current.state == .disconnecting else { return }
            guard released else {
                current.state = .releaseFailed
                self.plugs[loc] = current
                self.changed()
                return
            }
            self.plugs[loc] = nil
            if let back = current.returned {
                let identity = current.hidIdentity ?? Self.hidIdentity(old)
                let same = identity != nil ? !Self.hidReplacement(current, back)
                    : (back.id == old.id && back.serial == old.serial)
                if same {
                    // Deletion releases the generation, not this logical device's decision.
                    current.device = back
                    current.returned = nil
                    current.hidIdentity = identity ?? Self.hidIdentity(back)
                    current.leavingReady = false
                    current.state = .onMac(remembered: false)
                    let ready = reconnect && self.prepareHIDResume(&current, plan: .omarchy)
                    self.plugs[loc] = current
                    if ready { self.connect(loc, how: current.how) }
                } else {
                    self.plugged(back)
                }
            }
            self.changed()
        }
    }

    /// Missing HID metadata is not replacement evidence; a different ID or a
    /// published, non-HID interface is. Only an existing HID decision uses this.
    private static func hidReplacement(_ p: Plug, _ d: USBDevice) -> Bool {
        if d.id != p.device.id { return true }
        if let identity = hidIdentity(d) { return identity != (p.hidIdentity ?? hidIdentity(p.device)) }
        return d.hidUnavailable == nil && !d.interfaces.isEmpty && d.interfaces.allSatisfy {
            (1...255).contains($0.interfaceClass) && $0.interfaceClass != 3
        }
    }

    private static func hidIdentity(_ d: USBDevice) -> String? {
        d.hid.map { "\(d.id)/\($0.serialKey)" }
    }

    // MARK: The remembered list (changes only later plug-ins)

    public func setPlan(_ plan: USBPlan, for d: USBDevice) {
        memory.remember(d, plan)
        save(memory)
        changed()
    }

    public func setPlan(_ plan: USBPlan, key: String) {
        memory.set(key: key, plan)
        save(memory)
        changed()
    }

    public func forget(key: String) {
        memory.forget(key: key)
        save(memory)
        changed()
    }

    // MARK: Words

    /// "0483:3748 ST-Link V2" for the log.
    public static func label(_ d: USBDevice) -> String {
        let n = USBChoice.clean(d.name)
        return n.isEmpty ? d.id.description : "\(d.id) \(n)"
    }

    static func why(_ r: USBAttachResult) -> String {
        switch r {
        case .attached: return "connected"
        case .busy: return "in use on the Mac"
        case .gone: return "unplugged"
        case .full: return "the VM's USB controller is full"
        case .failed(let e), .releaseRequired(let e): return "QEMU: \(USBChoice.clean(e))"
        }
    }

    public static func noticeText(_ r: USBAttachResult, vmName: String, hid: Bool = false) -> String {
        switch r {
        case .busy: return "A Mac app is using it. Quit that app, then unplug the device and plug it in again."
        case .full: return "\(vmName) already has \(maxConnected) USB devices. Unplug one first."
        case .failed(let detail) where hid: return "\(vmName) didn’t take it: \(USBChoice.clean(detail))"
        case .releaseRequired(let detail): return "QEMU may still have it. Retry Disconnect before connecting again, or stop the VM. \(USBChoice.clean(detail))"
        default: return "\(vmName) didn’t take it. Unplug it and plug it in again to try once more."
        }
    }

    private func changed() { onChange?() }
}
