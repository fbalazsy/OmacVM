import Foundation

/// Absence requires a complete, valid bounded registry-plane scan, not matching.
enum USBRootGuardPresence { case present, absent, unknown }

/// Truthful cleanup receipt: disposal is deliberately NOT successful Close.
public enum USBRootGuardDisposition: Equatable, Sendable { case closed, disposedGone }

/// Queue-confined, injectable boundary. Only a validated native-drain path calls
/// this. The optional disposer is a capability to destroy the actual owned refs;
/// without it all nonzero Close results retain their original failure behavior.
final class USBRootGuardCloseBoundary {
    private let close: () -> Int32
    private let presence: (UInt64) -> USBRootGuardPresence
    private let dispose: (() -> Void)?
    private var closed = false
    private var destroyedIDs: [UInt64]?
    init(close: @escaping () -> Int32, presence: @escaping (UInt64) -> USBRootGuardPresence,
         dispose: (() -> Void)? = nil) {
        self.close = close; self.presence = presence; self.dispose = dispose
    }
    @discardableResult
    func closeAfterDrain(rootID: UInt64, clientIDs: [UInt64], allowGone: Bool = true) throws -> USBRootGuardDisposition {
        guard rootID != 0, !clientIDs.isEmpty, clientIDs.allSatisfy({ $0 != 0 }) else { throw USBRootGuardError.refused }
        let ids = [rootID] + clientIDs
        if let destroyedIDs {
            // Destruction completed, but proof may still be pending. Never touch
            // the destroyed object again, even after unknown proof or a stale ACK.
            guard allowGone, ids == destroyedIDs else { throw USBRootGuardError.stale }
            guard ids.allSatisfy({ presence($0) == .absent }) else { throw USBRootGuardError.disposalProofPending }
            return .disposedGone
        }
        if !closed {
            let result = close()
            FileHandle.standardError.write(Data("COEX_GUARD_CLOSE result=\(result) root=\(rootID)\n".utf8))
            if result != 0 {
                // kIOReturnNoDevice only; all other errors remain errors. The
                // two clients MUST be immutable original guard + native IDs.
                guard result == -536870208, allowGone, let dispose,
                      clientIDs.count == 2, Set(ids).count == 3 else {
                    throw USBRootGuardError.native("USBDeviceClose: \(result)")
                }
                guard ids.allSatisfy({ presence($0) == .absent }) else { throw USBRootGuardError.uncertain }
                destroyedIDs = ids
                dispose()
                guard ids.allSatisfy({ presence($0) == .absent }) else { throw USBRootGuardError.disposalProofPending }
                FileHandle.standardError.write(Data("COEX_GUARD_DISPOSAL old-generation-gone Release=executed post-release-absence=proven (NOT Close0) root=\(rootID)\n".utf8))
                return .disposedGone
            }
            closed = true
        }
        switch presence(rootID) {
        case .present: return .closed
        case .absent:
            guard clientIDs.allSatisfy({ presence($0) == .absent }) else { throw USBRootGuardError.uncertain }
        case .unknown: throw USBRootGuardError.uncertain
        }
        return .closed
    }
}
