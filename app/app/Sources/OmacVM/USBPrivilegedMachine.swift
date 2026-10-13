import Foundation
import OmacVMUSB

/// Default composition: ordinary usb-host remains unchanged; explicit HID grants
/// alone reach the bundled native launcher. No device-specific CLI or profile.
final class USBPrivilegedMachine: USBMachine, USBCaptureMachine {
    private let ordinary: USBMachine
    private let socketPath: String
    private let helper: URL
    private let preparation = DispatchQueue(label: "org.omacvm.usb-native.prepare")
    // Written/read only on preparation, frozen once at VM-session construction.
    private var identity: Result<USBProcessIdentity, Error>?
    private var pending: [UUID: Pending] = [:] // main thread
    // Cleanup owners outlive USBRun/window/VM stop. Retired only on proven terminal state.
    private static var retained: [UUID: USBPrivilegedMachine] = [:]
    private final class Pending {
        let lock = NSLock()
        var cancelled = false
        var operation: USBNativeOperation?
        func cancel() { lock.lock(); cancelled = true; let op = operation; lock.unlock(); op?.cancel() }
        func set(_ op: USBNativeOperation) { lock.lock(); operation = op; let cancel = cancelled; lock.unlock(); if cancel { op.cancel() } }
    }
    init(ordinary: USBMachine, socketPath: String, qemuPID: pid_t, helper: URL = USBHelperProcess.bundled()) {
        self.ordinary = ordinary; self.socketPath = socketPath; self.helper = helper
        preparation.async { [self] in
            identity = Result { try USBHelperProcess.inspect(executable: helper, pid: qemuPID) }
        }
    }
    func attach(_ d: USBDevice, done: @escaping (USBAttachResult) -> Void) { ordinary.attach(d, done: done) }
    func detach(_ d: USBDevice, done: @escaping (Bool) -> Void) { ordinary.detach(d, done: done) }
    func isAttached(_ d: USBDevice, done: @escaping (Bool) -> Void) { ordinary.isAttached(d, done: done) }
    func capture(_ grant: USBCaptureGrant, event: @escaping (USBCaptureEvent) -> Void) {
        guard pending[grant.attempt] == nil, grant.device.captureCandidate else { event(.refused("Invalid or repeated capture grant")); return }
        let pending = Pending()
        self.pending[grant.attempt] = pending
        Self.retained[grant.attempt] = self
        let deliver: (USBCaptureEvent) -> Void = { [self] value in
            DispatchQueue.main.async { [self] in
                event(value)
                switch value {
                case .released, .refused:
                    self.pending[grant.attempt] = nil
                    Self.retained[grant.attempt] = nil
                default: break // uncertain keeps exact owner and diagnostics
                }
            }
        }
        preparation.async { [self] in
            do {
                guard let identity else { throw USBNativeError("VM identity unavailable") }
                let qemu = try identity.get()
                guard qemu.uid == getuid() else { throw USBNativeError("VM belongs to another account") }
                let app = try USBHelperProcess.inspect(executable: helper, pid: getpid())
                let launcher = USBHelperLauncher(executable: helper, app: app)
                let qmp = USBPrivilegedQMP(path: socketPath, identity: qemu, helper: helper)
                let op = USBNativeOperation(grant: grant, qemu: qemu, launcher: launcher, qmp: qmp, event: deliver)
                pending.set(op)
                DispatchQueue.global(qos: .userInitiated).async { op.run() }
            } catch { deliver(.refused(USBChoice.clean(error.localizedDescription))) }
        }
    }
    func cancelCapture(_ attempt: UUID) { pending[attempt]?.cancel() }
}
