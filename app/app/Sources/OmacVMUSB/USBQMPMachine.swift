import Foundation

/// Production USBSession driver, with an injectable short-transaction transport
/// and guard coordinator factory. Ordinary USB retains its original code path.
public final class USBQMPMachine: USBMachine {
    public typealias Factory = (USBDevice)->USBCoexistenceCoordinator?
    private let transport: USBQMPTransport
    private let factory: Factory
    private let deliver: (@escaping ()->Void)->Void
    private let queue = DispatchQueue(label:"org.omacvm.usb-qmp",qos:.userInitiated)
    private var owners: [UInt32:USBCoexistenceCoordinator] = [:]
    private var stopped = false
    public var onCoexistencePhase: ((USBCoexistenceCoordinator.Phase,USBDevice)->Void)?
    public init(transport:USBQMPTransport, coexistenceFactory:@escaping Factory = { _ in nil },
                deliver:@escaping (@escaping ()->Void)->Void = { DispatchQueue.main.async(execute:$0) }) {
        self.transport = transport; factory = coexistenceFactory; self.deliver = deliver
    }
    public func attach(_ device:USBDevice,done:@escaping(USBAttachResult)->Void) {
        queue.async { [self] in
            guard !stopped, owners[device.location] == nil else { deliver { done(.failed("USB ownership pending")) }; return }
            if let candidate = device.coexistence {
                guard let c = factory(device) else { deliver { done(.failed("Coexistence unavailable")) }; return }
                owners[device.location] = c
                c.onPhase = { [weak self, weak c] phase in
                    guard let self, let c else { return }
                    self.queue.async {
                        guard self.owners[device.location] === c else { return }
                        if phase == .retired || phase == .refused { self.owners[device.location] = nil }
                        self.deliver { self.onCoexistencePhase?(phase,device) }
                    }
                }
                c.attach(target:candidate.target,descriptor:candidate.descriptor,deviceID:USBQMP.qemuID(location:device.location)) { ok in
                    // Serialize after phase cleanup so a completion-triggered
                    // retry/replacement cannot observe the retired local owner.
                    self.queue.async {
                        self.deliver { done(ok ? .attached : .failed("USB coexistence admission or release pending")) }
                    }
                }
                return
            }
            let result = USBQMP.attach(device,over:transport)
            deliver { done(result) }
        }
    }
    public func detach(_ device:USBDevice,done:@escaping(Bool)->Void) {
        detach(device,retryClose:false,done:done)
    }
    public func retryRelease(_ device:USBDevice,done:@escaping(Bool)->Void) {
        detach(device,retryClose:true,done:done)
    }
    private func detach(_ device:USBDevice,retryClose:Bool,done:@escaping(Bool)->Void) {
        queue.async { [self] in
            if let c = owners[device.location] {
                c.detach(retryClose:retryClose) { ok in
                    self.queue.async { self.deliver { done(ok) } }
                }
                return
            }
            guard device.coexistence == nil else { deliver { done(false) }; return }
            let result = USBQMP.detach(location:device.location,over:transport)
            deliver { done(result) }
        }
    }
    public func isAttached(_ device:USBDevice,done:@escaping(Bool)->Void) {
        queue.async { [self] in
            // Unknown target ownership remains owned. HMP absence is not drain.
            if owners[device.location] != nil || device.coexistence != nil { deliver { done(true) }; return }
            let result = (try? USBQMP.attached(over:transport))?.contains(USBQMP.qemuID(location:device.location)) ?? false
            deliver { done(result) }
        }
    }
    public func stop() { queue.async { self.stopped = true; self.owners.values.forEach { $0.stop() } } }
}
