import Foundation

/// Checked full IOService-plane lookup, including unpublished IOUserClients.
/// Published-service matching cannot distinguish those entries from absence.
/// Dependency injection covers iterator errors without executing registry APIs.
struct USBRootGuardRegistryLookup {
    let iterate: () -> (Int32, UInt32)
    let next: (UInt32) -> UInt32
    let valid: (UInt32) -> Bool
    let identity: (UInt32) -> UInt64?
    let release: (UInt32) -> Void
    var maximumEntries = 262_144

    /// Caller owns a nonzero result. Nil requires a complete, valid plane scan.
    /// Any unreadable ID, duplicate target, invalidation or budget overrun is unknown.
    func service(_ id: UInt64) throws -> UInt32? {
        guard id != 0 else { throw USBRootGuardError.refused }
        guard maximumEntries > 0 else { throw USBRootGuardError.uncertain }
        let (result, iterator) = iterate()
        defer { if iterator != 0 { release(iterator) } }
        guard result == 0, iterator != 0, valid(iterator) else { throw USBRootGuardError.uncertain }
        var found: UInt32 = 0, count = 0
        var transferred = false
        defer { if !transferred && found != 0 { release(found) } }
        while case let entry = next(iterator), entry != 0 {
            var keep = false
            defer { if !keep { release(entry) } }
            guard count < maximumEntries, valid(iterator),
                  let entryID = identity(entry), entryID != 0 else { throw USBRootGuardError.uncertain }
            count += 1
            if entryID == id {
                guard found == 0 else { throw USBRootGuardError.uncertain }
                found = entry; keep = true
            }
        }
        guard valid(iterator) else { throw USBRootGuardError.uncertain }
        transferred = true
        return found == 0 ? nil : found
    }
    func presence(_ id: UInt64) -> USBRootGuardPresence {
        do {
            guard let entry = try service(id) else { return .absent }
            release(entry); return .present
        } catch { return .unknown }
    }
}
