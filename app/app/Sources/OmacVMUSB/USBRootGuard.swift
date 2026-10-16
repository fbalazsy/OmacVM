import Foundation

/// Queue-confined adapter. Tests inject an inert implementation; production uses
/// USBRootGuardIOKit. No method here permits requests/reset/config/interface open.
protocol USBRootGuardDriver: AnyObject {
    func snapshot(rootID: UInt64) throws -> USBScan.Entry
    func create(rootID: UInt64) throws
    func monitor(queue: DispatchQueue, event: @escaping (USBRootGuardError) -> Void) throws
    func open() throws
    func close() throws
    func closeAfterDrain(rootID: UInt64, clientIDs: [UInt64], allowGone: Bool) throws -> USBRootGuardDisposition
    func release()
}

public struct USBRootGuardTicket: Equatable, Sendable {
    public let binding: USBRootGuardBinding
    public let guardClientID: UInt64
    // A drain ACK must be mapped to the original ticket by the trusted transport,
    // not manufactured from a timeout, EOF, empty bus or DEVICE_DELETED.
    public init(binding: USBRootGuardBinding, guardClientID: UInt64) {
        self.binding = binding; self.guardClientID = guardClientID
    }
}

/// One attempt, one generation. Retain from prepare through confirmed close.
/// Self-retention after acquisition protects against accidental early owner loss.
/// An uncertain drain intentionally retains the guard: no timer may close it.
/// The app coordinator must keep exactly one owner per root, consume each prepare
/// receipt once and enforce monotonic epochs across owners. Those are transport/
/// launch duties, not inferred here from a PID or an ordinary QMP connection EOF.
/// The deadline bounds lease authorization, not a synchronous kernel call: IOKit
/// calls cannot safely be force-cancelled. No main-thread waits or seize fallback.
public final class USBRootGuard {
    private enum State { case idle, opening, held, committing, revoking, proofPending, closed, failed }
    private let queue = DispatchQueue(label:"org.omacvm.usb-root-guard")
    private let driver: USBRootGuardDriver
    private let receipt: USBRootGuardReceipt
    private let lifetime, pollInterval: TimeInterval
    private var state: State = .idle
    private var baseline: USBRootGuardSnapshot?
    private var ticket: USBRootGuardTicket?
    private var nativeID: UInt64?
    // Exact native identity frozen by the first drain ACK, including explicit nil.
    private var drainAcknowledged = false
    private var drainNativeID: UInt64?
    private var disposition: USBRootGuardDisposition?
    private var clientValues: [UInt64: USBRootGuardValue] = [:]
    private var opened = false
    private var timer: DispatchSourceTimer?
    private var deadline: UInt64 = 0
    private var keepAlive: USBRootGuard?
    private let onRevoke: (USBRootGuardTicket, USBRootGuardError) -> Void

    init(driver: USBRootGuardDriver, receipt: USBRootGuardReceipt, lifetime: TimeInterval,
         pollInterval: TimeInterval = 0.1,
         onRevoke: @escaping (USBRootGuardTicket, USBRootGuardError) -> Void = { _,_ in }) {
        self.driver = driver; self.receipt = receipt; self.lifetime = lifetime
        self.pollInterval = pollInterval; self.onRevoke = onRevoke
    }

    public convenience init(receipt: USBRootGuardReceipt, lifetime: TimeInterval = 30,
                            onRevoke: @escaping (USBRootGuardTicket, USBRootGuardError) -> Void) {
        self.init(driver: USBRootGuardIOKit(launcherPID:receipt.launcherPID), receipt:receipt,
                  lifetime:lifetime,onRevoke:onRevoke)
    }

    /// Callbacks run on the guard queue. Dispatch UI/transport work elsewhere;
    /// never wait synchronously for QMP here. Open has one attempt, no fallback.
    public func acquire(_ completion: @escaping (Result<USBRootGuardTicket, USBRootGuardError>) -> Void) {
        queue.async { [self] in
            guard self.state == .idle else { completion(.failure(.busy)); return }
            self.state = .opening
            guard self.lifetime.isFinite, self.lifetime > 0, self.lifetime <= 300,
                  self.pollInterval.isFinite, self.pollInterval > 0, self.pollInterval <= 10 else {
                self.state = .failed; completion(.failure(.refused)); return
            }
            self.deadline = DispatchTime.now().uptimeNanoseconds + UInt64(self.lifetime * 1_000_000_000)
            do {
                let before = try self.driver.snapshot(rootID:self.receipt.rootID)
                guard let baseline = USBRootGuardPolicy.validate(before,receipt:self.receipt,guardClientID:nil) else { throw USBRootGuardError.refused }
                self.baseline = baseline
                try self.driver.create(rootID:self.receipt.rootID)
                let after = try self.driver.snapshot(rootID:self.receipt.rootID)
                let old = Set(before.descendants.map(\.registryID))
                let added = after.descendants.filter { !old.contains($0.registryID) }
                guard added.count == 1, let own = added.first,
                      USBRootGuardPolicy.creator(own,pid:self.receipt.launcherPID),
                      USBRootGuardPolicy.validate(after,receipt:self.receipt,guardClientID:own.registryID) == baseline else { throw USBRootGuardError.refused }
                guard let ownValues = USBRootGuardValue(own.properties) else { throw USBRootGuardError.refused }
                self.clientValues[own.registryID] = ownValues
                self.ticket = .init(binding:self.receipt.binding,guardClientID:own.registryID)
                try self.driver.monitor(queue:self.queue) { [weak self] reason in
                    // Driver delivers on this same serial queue.
                    self?.beginRevocation(reason)
                }
                try self.driver.open()
                self.opened = true
                guard self.check(), DispatchTime.now().uptimeNanoseconds < self.deadline else { throw USBRootGuardError.refused }
                self.state = .held
                self.keepAlive = self
                let timer = DispatchSource.makeTimerSource(queue:self.queue)
                timer.schedule(deadline:.now()+min(self.pollInterval,self.lifetime),repeating:self.pollInterval)
                timer.setEventHandler { [weak self] in self?.poll() }
                self.timer = timer; timer.resume()
                completion(.success(self.ticket!))
            } catch {
                // No ticket has escaped to QEMU: native commit is impossible.
                // A failed close still retains the owned handle for explicit retry.
                if self.opened {
                    do { try self.driver.close(); self.opened = false }
                    catch { self.state = .revoking; self.keepAlive = self
                        if let ticket = self.ticket { self.onRevoke(ticket,.uncertain) }
                        completion(.failure(.uncertain)); return }
                }
                self.driver.release(); self.state = .failed
                completion(.failure((error as? USBRootGuardError) ?? .refused))
            }
        }
    }

    /// Resolve failed acquisition on the owning queue, not from error prose or
    /// callback scheduling. nil is definitive no held/open guard after cleanup;
    /// a retained exact ticket is still a cleanup obligation, never admission.
    func acquisitionCleanup(_ completion: @escaping (Result<USBRootGuardTicket?,USBRootGuardError>) -> Void) {
        queue.async { [self] in
            if state == .failed && !opened { completion(.success(nil)) }
            else if opened, let ticket { completion(.success(ticket)) }
            else { completion(.failure(.uncertain)) }
        }
    }

    private func check(learningNative: Bool = false) -> Bool {
        guard let ticket, let baseline,
              let root = try? driver.snapshot(rootID:receipt.rootID),
              USBRootGuardPolicy.validate(root,receipt:receipt,guardClientID:ticket.guardClientID,nativeClientID:nativeID) == baseline else { return false }
        for id in [ticket.guardClientID, nativeID].compactMap({ $0 }) {
            guard let node = root.descendants.first(where:{ $0.registryID == id }),
                  let value = USBRootGuardValue(node.properties) else { return false }
            if learningNative && id == nativeID && clientValues[id] == nil { clientValues[id] = value }
            guard clientValues[id] == value else { return false }
        }
        return true
    }
    private func poll() {
        guard state == .held || state == .committing else { return }
        if DispatchTime.now().uptimeNanoseconds >= deadline { beginRevocation(.expired) }
        else if state == .held && !check() { beginRevocation(.lost) }
    }
    private func beginRevocation(_ reason: USBRootGuardError) {
        guard state == .held || state == .committing, let ticket else { return }
        state = .revoking; timer?.cancel(); timer = nil
        onRevoke(ticket,reason)
    }

    /// The exact native client comes only from a validated commit receipt.
    /// An extra client racing that receipt fails closed, never class/PID-wide allow.
    public func observeNativeClient(_ id: UInt64, ticket: USBRootGuardTicket,
                                    completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard self.state == .held || self.state == .committing, self.ticket == ticket, self.nativeID == nil else { completion(false); return }
            self.nativeID = id
            guard self.check(learningNative:true), DispatchTime.now().uptimeNanoseconds < self.deadline else { self.beginRevocation(.lost); completion(false); return }
            self.state = .held
            completion(true)
        }
    }

    /// Bounded commit phase: registry polling cannot misclassify QEMU's newly
    /// created native client before its exact receipt arrives. Interest loss and
    /// deadline still revoke; no I/O is authorized by this local phase alone.
    public func beginCommit(_ ticket: USBRootGuardTicket, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard state == .held, self.ticket == ticket, nativeID == nil, check(), state == .held,
                  DispatchTime.now().uptimeNanoseconds < deadline else { completion(false); return }
            state = .committing
            completion(true)
        }
    }

    /// Refresh only after a matching successful QEMU renewal. Never resurrect
    /// an expired/revoking generation; every extension rechecks exact policy.
    public func renew(_ ticket: USBRootGuardTicket, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard state == .held, self.ticket == ticket,
                  check(), DispatchTime.now().uptimeNanoseconds < deadline else {
                beginRevocation(.expired); completion(false); return
            }
            deadline = DispatchTime.now().uptimeNanoseconds + UInt64(lifetime * 1_000_000_000)
            completion(true)
        }
    }

    public func revoke(reason: USBRootGuardError = .lost, completion: @escaping () -> Void = {}) {
        queue.async { [self] in self.beginRevocation(reason); completion() }
    }

    /// Only invoke after QEMU has stopped submits, drained and closed native HID.
    /// Wrong/replayed generation ACKs cannot release this handle. Close failure
    /// remains retryable with the SAME ticket; it never authorizes ordinary USB.
    public func acknowledgeDrain(_ ticket: USBRootGuardTicket, nativeClientID: UInt64? = nil,
                                 completion: @escaping (Result<USBRootGuardDisposition,USBRootGuardError>) -> Void) {
        queue.async { [self] in
            guard self.state == .revoking || self.state == .proofPending, self.ticket == ticket,
                  (!self.drainAcknowledged || self.drainNativeID == nativeClientID),
                  nativeClientID == nil || (nativeClientID != 0 &&
                    ![self.receipt.rootID,self.receipt.interfaceID,self.receipt.hidID,self.receipt.cacheClientID,ticket.guardClientID].contains(nativeClientID!) &&
                    (self.nativeID == nil || self.nativeID == nativeClientID)) else {
                completion(.failure(.stale)); return
            }
            // A commit may already be drained before local observeNativeClient.
            // Retain its exact ID from the validated ACK for absence proof only.
            if let nativeClientID { self.nativeID = nativeClientID }
            self.drainAcknowledged = true; self.drainNativeID = nativeClientID
            do {
                if self.opened || self.state == .proofPending {
                    self.disposition = try self.driver.closeAfterDrain(rootID:self.receipt.rootID,
                        clientIDs:[ticket.guardClientID,self.nativeID].compactMap { $0 },
                        allowGone:nativeClientID != nil)
                    self.opened = false
                }
                let disposition = self.disposition ?? .closed
                if disposition == .closed { self.driver.release() }
                self.state = .closed; self.keepAlive = nil
                completion(.success(disposition))
            } catch USBRootGuardError.disposalProofPending {
                // No physical handle remains. Retain only logical quarantine and
                // immutable ACK identity; retry invokes proof, not destruction.
                self.opened = false; self.state = .proofPending
                completion(.failure(.uncertain))
            } catch { completion(.failure(.uncertain)) }
        }
    }
}
