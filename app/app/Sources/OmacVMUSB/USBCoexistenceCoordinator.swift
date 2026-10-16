import Foundation

/// Process-wide ownership; uncertain roots are deliberately never recycled.
/// Epoch tombstones survive successful release and coordinator destruction.
public final class USBCoexistenceLedger {
    public static let shared = USBCoexistenceLedger()
    private let lock = NSLock()
    private var roots: [UInt64:UUID] = [:]
    private var epochs: [String:UInt64] = [:]
    public init() {}
    func claim(root:UInt64, owner:UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard roots[root] == nil else { return false }; roots[root] = owner; return true
    }
    func reserve(root:UInt64, owner:UUID, qemuLaunch:String, epoch:UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard roots[root] == nil || roots[root] == owner, epoch > (epochs[qemuLaunch] ?? 0) else { return false }
        roots[root] = owner; epochs[qemuLaunch] = epoch; return true
    }
    func retire(root:UInt64, owner:UUID) {
        lock.lock(); defer { lock.unlock() }
        if roots[root] == owner { roots[root] = nil }
    }
}

/// A single root attempt; QMP operations are serialized off the main thread and
/// each transport operation owns only one short connection. No ordinary fallback.
/// A lost mutator reply is resolved by status, NEVER by replaying the command.
public final class USBCoexistenceCoordinator {
    public typealias GuardFactory = (USBRootGuardReceipt, @escaping (USBRootGuardTicket,USBRootGuardError)->Void) -> USBRootGuard
    public enum Phase: String { case idle, preparing, acquiring, committing, native, revoking, uncertain, retired, refused }
    private let queue = DispatchQueue(label:"org.omacvm.usb-coexistence")
    private let transport: USBQMPTransport
    private let launcher, qemu: USBCoexistenceTask
    private let launch: String
    private let ledger: USBCoexistenceLedger
    private let owner = UUID()
    private let factory: GuardFactory
    private let automaticTimers: Bool
    private let taskMatches: (USBCoexistenceTask)->Bool
    private var phase: Phase = .idle
    private var receipt: USBCoexistenceStatus?
    private var lookupTarget: USBCoexistenceTarget?
    private var guardOwner: USBRootGuard?
    private var ticket: USBRootGuardTicket?
    private var timer: DispatchSourceTimer?
    private var keepAlive: USBCoexistenceCoordinator?
    private var stopped = false
    private var mutating = false
    private var unresolvedSequence: UInt64?
    private var disposition: USBRootGuardDisposition?
    private var closed: Bool { disposition != nil }
    private var closeFailed = false
    // false while acquisition disposition is unresolved. Error/EOF is not no-guard.
    private var noGuard = true
    private var noGuardHandoffSequence: UInt64?
    public var onPhase: ((Phase)->Void)?

    public init(transport: USBQMPTransport, launcher: USBCoexistenceTask, qemu: USBCoexistenceTask,
                launch: String, ledger: USBCoexistenceLedger = .shared, automaticTimers: Bool = true,
                taskMatches: @escaping (USBCoexistenceTask)->Bool = { (try? USBCoexistenceTask.measure($0.pid)) == $0 },
                guardFactory: @escaping GuardFactory = { USBRootGuard(receipt:$0,lifetime:5,onRevoke:$1) }) {
        self.transport = transport; self.launcher = launcher; self.qemu = qemu; self.launch = launch
        self.ledger = ledger; self.automaticTimers = automaticTimers; self.taskMatches = taskMatches; factory = guardFactory
    }
    private func set(_ p: Phase) { phase = p; onPhase?(p) }
    private func execute(_ op: String, _ args: [String:Any]) throws -> USBCoexistenceStatus {
        try .init(wire:transport.execute("x-omacvm-usb-coexistence-"+op,args))
    }
    private func accept(_ s: USBCoexistenceStatus, sequence: UInt64) throws {
        guard let old = receipt, old.sameGeneration(s), s.sequence == sequence,
              ticket == nil || s.guardID == ticket!.guardClientID || (s.guardID == 0 && old.guardID == 0 && s.state != "native"),
              old.nativeID == 0 || s.nativeID == old.nativeID else { throw USBCoexistenceError.identity }
        receipt = s
    }
    private func status() throws -> USBCoexistenceStatus {
        guard let old = receipt else {
            guard let target = lookupTarget else { throw USBCoexistenceError.uncertain }
            let s = try execute("status",["launcher":["launch":launch,"task":launcher.wire],"target":target.wire])
            try acceptPrepared(s, target:target)
            return s
        }
        let s = try execute("status",["lease":old.lease])
        guard s.sequence == old.sequence || s.sequence == unresolvedSequence else { throw USBCoexistenceError.identity }
        try accept(s,sequence:s.sequence)
        // A status proves what sequence was accepted, including definite rejection.
        unresolvedSequence = nil
        return s
    }
    private func acceptPrepared(_ s: USBCoexistenceStatus, target: USBCoexistenceTarget) throws {
        guard s.launch == launch, s.launcher == launcher, s.qemu == qemu, s.target == target,
              taskMatches(launcher), taskMatches(qemu),
              s.sequence == 1, s.guardID == 0, s.nativeID == 0,
              ledger.reserve(root:target.root,owner:owner,qemuLaunch:s.qemuLaunch,epoch:s.epoch) else { throw USBCoexistenceError.identity }
        receipt = s
    }
    private func mutate(_ op: String, fields: [String:Any]) throws -> USBCoexistenceStatus {
        guard let old = receipt, unresolvedSequence == nil, old.sequence < UInt64.max else { throw USBCoexistenceError.uncertain }
        let sequence = old.sequence + 1
        var args = fields; args["call"] = ["lease":old.lease,"sequence":String(sequence)]
        unresolvedSequence = sequence
        do {
            let s = try execute(op,args); try accept(s,sequence:sequence)
            unresolvedSequence = nil; return s
        } catch {
            // Even a matched rejection may have begun asynchronous cleanup.
            // Status resolves it without guessing from error prose or EOF.
            let s = try status()
            guard s.sequence == sequence else { throw error }
            return s
        }
    }
    private func startTimer() {
        guard automaticTimers, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue:queue)
        t.schedule(deadline:.now()+1,repeating:1)
        t.setEventHandler { [weak self] in
            guard let self, !self.mutating else { return }
            if self.phase == .native { self.renew { _ in } }
            else if self.phase == .uncertain || self.phase == .revoking { self.recover { _ in } }
        }
        timer = t; t.resume()
    }
    public func attach(target: USBCoexistenceTarget, descriptor: Data, deviceID: String, completion: @escaping (Bool)->Void) {
        queue.async { [self] in
            guard phase == .idle else { completion(false); return }
            guard !stopped, taskMatches(launcher), taskMatches(qemu),
                  target.descriptorHash == USBCoexistenceTarget.hash(descriptor),
                  deviceID.range(of:"^[A-Za-z0-9_.-]{1,64}$",options:.regularExpression) != nil,
                  ledger.claim(root:target.root,owner:owner) else { set(.refused); completion(false); return }
            keepAlive = self; set(.preparing); mutating = true
            do {
                lookupTarget = target
                let s: USBCoexistenceStatus
                do {
                    s = try execute("prepare",["launcher":["launch":launch,"task":launcher.wire],"sequence":"1","target":target.wire])
                } catch {
                    // Lost or rejected prepare can have applied. Never replay it.
                    s = try execute("status",["launcher":["launch":launch,"task":launcher.wire],"target":target.wire])
                }
                try acceptPrepared(s,target:target)
                startTimer()
                guard s.state == "guard-pending", s.drained else { throw USBCoexistenceError.uncertain }
                let binding = USBRootGuardBinding(launcher:USBCoexistenceCodec.uuid(launch),qemu:USBCoexistenceCodec.uuid(s.qemuLaunch),epoch:s.epoch,request:owner)
                let r = USBRootGuardReceipt(binding:binding,rootID:target.root,sessionID:s.session,interfaceID:target.interface,hidID:target.hid,cacheClientID:s.cache,qemuPID:qemu.pid,launcherPID:launcher.pid,serial:target.serial,descriptor:descriptor)
                let g = factory(r) { [weak self] t, reason in
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        if self.ticket == nil { self.ticket = t }
                        guard self.ticket == t, !self.closed else { return }
                        self.stopped = true
                        if !self.mutating { self.revoke(reason:reason == .requestingClose ? "requesting-close" : "guard-loss") { _ in } }
                    }
                }
                guardOwner = g; noGuard = false; set(.acquiring)
                g.acquire { result in self.queue.async {
                    switch result {
                    case .failure:
                        g.acquisitionCleanup { disposition in self.queue.async {
                            switch disposition {
                            case .success(let held):
                                self.ticket = held; self.noGuard = held == nil
                            case .failure: break // retain unresolved ownership
                            }
                            self.mutating = false
                            self.revoke(reason:"attach-failed") { _ in completion(false) }
                        } }
                    case .success(let t):
                        self.ticket = t
                        if self.stopped { self.mutating = false; self.revoke(reason:"shutdown") { _ in completion(false) }; return }
                        g.beginCommit(t) { ok in self.queue.async {
                            guard ok && !self.stopped else { self.mutating = false; self.revoke(reason:"guard-loss") { _ in completion(false) }; return }
                            self.commit(deviceID:deviceID, completion:completion)
                        } }
                    }
                } }
            } catch {
                mutating = false; set(.uncertain); startTimer(); completion(false)
            }
        }
    }
    private func guardFields() -> [String:Any] {
        ["published":receipt!.published,"guard-client-id":String(ticket!.guardClientID),"guard-task":launcher.wire]
    }
    private func commit(deviceID:String, completion:@escaping(Bool)->Void) {
        set(.committing)
        do {
            var fields = guardFields(); fields["guard-open"] = "nonseizing-success"; fields["device-id"] = deviceID
            let s = try mutate("commit",fields:fields)
            guard s.state == "native", !s.uncertain, s.nativeID != 0, taskMatches(qemu), !stopped else { throw USBCoexistenceError.uncertain }
            guardOwner!.observeNativeClient(s.nativeID,ticket:ticket!) { ok in self.queue.async {
                self.mutating = false
                if ok && !self.stopped { self.set(.native); completion(true) }
                else { self.revoke(reason:"guard-loss") { _ in completion(false) } }
            } }
        } catch { mutating = false; revoke(reason:"attach-failed") { _ in completion(false) } }
    }
    public func renewNow(completion:@escaping(Bool)->Void) { queue.async { self.renew(completion) } }
    private func renew(_ completion:@escaping(Bool)->Void) {
        guard phase == .native, !mutating, !stopped, taskMatches(launcher), taskMatches(qemu) else {
            if phase == .native { revoke(reason:"shutdown") { _ in completion(false) } } else { completion(false) }; return
        }
        mutating = true
        do {
            let s = try mutate("renew",fields:guardFields())
            guard s.state == "native", !s.uncertain else { throw USBCoexistenceError.uncertain }
            guardOwner!.renew(ticket!) { ok in self.queue.async {
                self.mutating = false
                if ok && !self.stopped { completion(true) } else { self.revoke(reason:"guard-loss") { _ in completion(false) } }
            } }
        } catch { mutating = false; revoke(reason:"policy-change") { _ in completion(false) } }
    }
    public func detach(retryClose: Bool = true, completion:@escaping(Bool)->Void) {
        queue.async {
            self.stopped = true
            // Only an explicit user retry may retry the same acknowledged drain.
            if retryClose && !self.mutating { self.closeFailed = false }
            if self.receipt == nil && self.phase != .refused { self.recover(completion) }
            else { self.revoke(reason:"user",completion:completion) }
        }
    }
    public func stop() { queue.async { self.stopped = true; if !self.mutating { self.revoke(reason:"shutdown") { _ in } } } }
    private func revoke(reason:String, completion:@escaping(Bool)->Void) {
        guard phase != .retired && phase != .refused else { completion(true); return }
        guard !mutating, let current = receipt, !closeFailed else { completion(false); return }
        guard !current.uncertain, current.state != "uncertain" else {
            // Canonical uncertainty revokes local authority too. It is not a
            // native-drain ACK: retain the guard and root until proof arrives.
            set(.uncertain); guardOwner?.revoke()
            completion(false); return
        }
        mutating = true; set(.revoking)
        guardOwner?.revoke()
        do {
            // Resolve outstanding receipt before constructing a fresh sequence.
            if unresolvedSequence != nil { _ = try status() }
            // A previously accepted revoke is not replayed while real drain is
            // pending. STATUS may now finish the runtime's neverstarted ACK.
            if receipt!.state == "revoking" &&
                (ticket.map { receipt!.guardID == $0.guardClientID } == true ||
                 noGuardHandoffSequence.map { receipt!.sequence >= $0 } == true) {
                let pending = try status()
                guard pending.state != "revoking", !pending.uncertain else { throw USBCoexistenceError.uncertain }
            }
            if receipt!.state == "guard-release" { finishDrain(completion); return }
            if receipt!.state == "retired", closed { finishRetired(); completion(true); return }
            var fields: [String:Any] = ["reason":reason]
            if let id = ticket?.guardClientID ?? (noGuard ? UInt64(0) : nil) {
                fields["published"] = receipt!.published
                fields["guard-client-id"] = String(id)
                fields["guard-task"] = launcher.wire
                if id == 0 { noGuardHandoffSequence = receipt!.sequence + 1 }
            }
            // Cleanup-only extended REVOKE, never COMMIT after local revocation.
            // An unresolved acquisition may revoke bare but cannot close/release.
            let s = try mutate("revoke",fields:fields)
            guard s.state == "guard-release", s.drained else { throw USBCoexistenceError.uncertain }
            finishDrain(completion)
        } catch { mutating = false; set(.uncertain); completion(false) }
    }
    private func recover(_ completion:@escaping(Bool)->Void) {
        guard !mutating, !closeFailed else { completion(false); return }
        // EOF and even failed PID measurement are not native-drain proof. A dead
        // QEMU with no final ACK remains quarantined; never close/thaw by guess.
        do {
            let s = try status()
            if s.state == "guard-release", s.drained { mutating = true; finishDrain(completion) }
            else if s.state == "retired", closed { finishRetired(); completion(true) }
            else if !s.uncertain && s.state != "uncertain" { revoke(reason:"shutdown",completion:completion) }
            else { completion(false) }
        } catch { set(.uncertain); completion(false) }
    }
    private func finishDrain(_ completion:@escaping(Bool)->Void) {
        guard !closeFailed, let s = receipt, s.state == "guard-release", s.drained,
              let id = ticket?.guardClientID ?? (noGuard ? UInt64(0) : nil), s.guardID == id,
              id != 0 || (s.nativeID == 0 && noGuardHandoffSequence.map { s.sequence >= $0 } == true)
        else { mutating = false; set(.uncertain); completion(false); return }
        func release() {
            do {
                guard let disposition = self.disposition else { throw USBCoexistenceError.uncertain }
                var fields: [String:Any] = ["guard-client-id":String(self.ticket?.guardClientID ?? 0),"guard-closed":disposition == .closed]
                if disposition == .disposedGone { fields["guard-disposed-gone"] = true }
                let result = try self.mutate("release",fields:fields)
                guard result.state == "retired", result.drained else { throw USBCoexistenceError.uncertain }
                self.finishRetired(); completion(true)
            } catch { self.mutating = false; self.set(.uncertain); completion(false) }
        }
        if closed { release(); return }
        guard let g = guardOwner, let t = ticket else { disposition = .closed; release(); return }
        // Guard serial queue orders revoke before acknowledgeDrain.
        g.revoke()
        g.acknowledgeDrain(t,nativeClientID:s.nativeID == 0 ? nil : s.nativeID) { result in self.queue.async {
            if case .success(let disposition) = result { self.disposition = disposition; release() }
            else { self.closeFailed = true; self.mutating = false; self.set(.uncertain); completion(false) }
        } }
    }
    private func finishRetired() {
        if let r = receipt { ledger.retire(root:r.target.root,owner:owner) }
        timer?.cancel(); timer = nil; mutating = false; set(.retired)
        guardOwner = nil; keepAlive = nil
    }
}
