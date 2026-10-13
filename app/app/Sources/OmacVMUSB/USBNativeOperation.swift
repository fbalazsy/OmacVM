import Foundation

public protocol USBNativeChannel: AnyObject {
    func send(_ data: Data) throws
    func receive(timeoutMS: Int32) throws -> Data?
    func reap(timeout: Double) -> Bool
    func close()
    func finishRequests()
    /// ONLY ESRCH for the exact old PID. Reused/changed process is NOT dead proof.
    func qemuIsDead(_ identity: USBProcessIdentity) -> Bool
}
public protocol USBNativeLaunching {
    /// Authorize/install fixed native payload and connect control; does not send capture.
    func start(_ grant: USBCaptureGrant, cancelled: () -> Bool) throws -> USBNativeChannel
}

/// Actual production orchestration, also exercised with ordinary socket/fixture I/O.
/// One serial thread per attempt; cancel only flips a synchronized flag. Neither
/// foreground changes nor elapsed transport lifetime revoke an established session.
public final class USBNativeOperation {
    private let grant: USBCaptureGrant, qemu: USBProcessIdentity
    private let launcher: USBNativeLaunching
    public let redirection: USBRedirection
    private let event: (USBCaptureEvent) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var ran = false
    public init(grant: USBCaptureGrant, qemu: USBProcessIdentity, launcher: USBNativeLaunching,
                qmp: USBPrivilegedQMPTransport, event: @escaping (USBCaptureEvent) -> Void) {
        self.grant = grant; self.qemu = qemu; self.launcher = launcher
        self.redirection = USBRedirection(attempt: grant.attempt, qmp: qmp); self.event = event
    }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func run() {
        guard !ran else { return }; ran = true
        if isCancelled { event(.refused("Cancelled before authorization")); return }
        event(.authorizing)
        let channel: USBNativeChannel
        do { channel = try launcher.start(grant, cancelled: { self.isCancelled }) }
        catch USBLaunchFailure.beforeCapture(let reason) { event(.refused(reason)); return }
        catch { event(.uncertain(USBChoice.clean(error.localizedDescription))); return }
        defer { channel.close() }
        var frames = USBNativeFrames(attempt: grant.attempt)
        var postcheck = false, connected = false, cancelSent = false, nativeReleased = false, restored = false
        var nativeReleasing = false, captureSent = false
        var refusal: String?
        let startupDeadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        var cancelTime: UInt64?, cleanupWarning = false
        var nextCheck: UInt64 = 0
        do {
            if !isCancelled {
                // A partial/failed send stays uncertain in the catch path below;
                // only a capture that was never attempted permits safe retry.
                captureSent = true
                try channel.send(USBNativeWire.capture(attempt: grant.attempt, device: grant.device, qemu: qemu))
            }
            while !nativeReleased {
                let now = DispatchTime.now().uptimeNanoseconds
                if !connected && now >= startupDeadline && !isCancelled { cancel(); event(.releasing) }
                if isCancelled && !cancelSent && !nativeReleasing {
                    // A release proof may already be buffered even if this write gets EPIPE.
                    // Still drain the read side; EOF alone remains uncertain.
                    do { try channel.send(USBNativeWire.cancel(grant.attempt)) }
                    catch { channel.finishRequests() }
                    cancelSent = true; cancelTime = now; event(.releasing)
                }
                if let cancelTime, now - cancelTime > 15_000_000_000, !cleanupWarning {
                    cleanupWarning = true; event(.uncertain("Waiting for native release proof"))
                    // Keep draining: late release after cancellation remains valid evidence.
                }
                if let data = try channel.receive(timeoutMS: 100) {
                    for status in try frames.feed(data) {
                        switch status {
                        case .listening:
                            if !isCancelled {
                                event(.capturing)
                                if !redirection.create(socket: USBNativeWire.directory(grant.attempt) + "/usb.sock", cancelled: { self.isCancelled }) { cancel() }
                            }
                        case .postcheck: postcheck = true
                        case .releasing: nativeReleasing = true; cancel(); event(.releasing)
                        case .released(let hid): nativeReleased = true; restored = hid
                        case .failed(let reason):
                            // Parser permits failed only before listening, before QMP ownership.
                            refusal = reason; nativeReleased = true
                        case .uncertain(let reason): cancel(); event(.uncertain(reason))
                        }
                    }
                }
                if postcheck && !isCancelled && !nativeReleased && now >= nextCheck {
                    nextCheck = now + 1_000_000_000
                    let ready = redirection.ready(nativePostcheck: true)
                    if ready && !connected && !isCancelled { connected = true; event(.connected) }
                    else if !ready && connected { cancel(); event(.releasing) }
                }
            }
            guard channel.reap(timeout: 10),
                  redirection.cleanup(nativeReleased: true, reaped: true, qemuDead: channel.qemuIsDead(qemu)) else {
                event(.uncertain("Native ended; QMP cleanup or process reap not confirmed")); return
            }
            if let refusal { event(.refused(refusal)) }
            else if !captureSent && cancelSent {
                // Native first-request cancel does not initialize USB and reports
                // hid_restored=false. Release + reap prove a retryable no-capture
                // cancellation, not HID restoration for a captured device.
                event(.refused("Cancelled before capture"))
            } else { event(.released(hidRestored: restored)) }
        } catch {
            // EOF initiates root cancellation, but exit/closed stream alone proves no release.
            channel.close()
            _ = channel.reap(timeout: 10)
            event(.uncertain(USBChoice.clean(error.localizedDescription)))
        }
    }
}
