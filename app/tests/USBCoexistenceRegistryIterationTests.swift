import Foundation

// Actual production adapter's injected API boundary only; no IOKit execution.
// Models the parent's SDK probe: unpublished registry entries (including
// IOUserClients) are visible in the plane but NOT in published-service matching.
func coexistenceRegistryIterationTests() throws {
    final class Registry {
        var entries: [(UInt32, UInt64?)] = [(20, 100), (21, 200)]
        let published: Set<UInt64> = [100]
        var status: Int32 = 0
        var iterator: UInt32 = 10
        var initiallyValid = true, invalidateAtEnd = false
        var invalidAfter: Int?
        var budget = 262_144
        var cursor = 0, creates = 0
        var ended = false
        var acquired: [UInt32] = [], released: [UInt32] = []
        func publishedMatching(_ id: UInt64) -> (Int32, UInt32) {
            precondition(!published.contains(id))
            return (0, 0) // Exactly the ambiguous SDK result; NOT absence proof.
        }
        func lookup() -> USBRootGuardRegistryLookup {
            USBRootGuardRegistryLookup(iterate: {
                self.creates += 1; self.cursor = 0; self.ended = false
                if self.iterator != 0 { self.acquired.append(self.iterator) }
                return (self.status, self.iterator)
            }, next: next, valid: { _ in
                self.initiallyValid && !(self.invalidateAtEnd && self.ended) &&
                (self.invalidAfter.map { self.cursor < $0 } ?? true)
            }, identity: identity, release: release, maximumEntries: budget)
        }
        func next(_ iterator: UInt32) -> UInt32 {
            precondition(iterator == 10)
            guard cursor < entries.count else { ended = true; return 0 }
            let entry = entries[cursor].0
            cursor += 1; acquired.append(entry); return entry
        }
        func identity(_ entry: UInt32) -> UInt64? { entries.first { $0.0 == entry }?.1 }
        func release(_ object: UInt32) { precondition(object != 0); released.append(object) }
        func balanced(holding: [UInt32] = []) {
            func counts(_ objects: [UInt32]) -> [UInt32:Int] {
                Dictionary(objects.map { ($0,1) }, uniquingKeysWith: +)
            }
            precondition(counts(acquired) == counts(released + holding), "all acquired refs released or transferred exactly once")
        }
    }
    do {
        let registry = Registry()
        precondition(registry.publishedMatching(1).1 == 0)
        precondition(registry.publishedMatching(200).1 == 0)
        let observed = registry.lookup().presence(1)
        precondition(observed == .absent, "complete registry plane proves old root absent despite ambiguous published matching")
        registry.balanced()
        print("PASS registry full-plane exact old-root absence; published matching indistinguishable from unpublished client")
    }
    for id: UInt64 in [1,5,6] {
        let registry = Registry()
        precondition(registry.lookup().presence(id) == .absent)
        precondition(registry.ended && registry.cursor == registry.entries.count)
        registry.balanced()
        print("PASS registry full-plane positive absent old ID \(id)")
    }
    for id: UInt64 in [100,200,5,6] {
        let registry = Registry()
        if id == 5 || id == 6 { registry.entries.insert((22,id),at:0) }
        if id != 100 { precondition(registry.publishedMatching(id).1 == 0) }
        precondition(registry.lookup().presence(id) == .present)
        precondition(registry.ended, "a first match must not skip the remainder")
        registry.balanced()
        print("PASS registry full-plane surviving exact ID \(id) including unpublished old clients")
    }
    do {
        let registry = Registry()
        let entry = try registry.lookup().service(200)
        precondition(entry == 21 && registry.ended)
        registry.balanced(holding:[21])
        registry.release(entry!); registry.balanced()
        print("PASS registry full-plane transfers one retained exact entry only after complete scan")
    }
    for mode in ["status-failure", "status-failure-null", "success-null", "invalid-start", "invalid-after-child",
                 "invalid-after-match", "invalid-at-end", "id-read-failure", "zero-id", "late-id-read-failure",
                 "duplicate", "duplicate-same-reference", "max-budget", "max-budget-after-match", "zero-budget"] {
        let registry = Registry()
        switch mode {
        case "status-failure": registry.status = -1
        case "status-failure-null": registry.status = -1; registry.iterator = 0
        case "success-null": registry.iterator = 0
        case "invalid-start": registry.initiallyValid = false
        case "invalid-after-child": registry.invalidAfter = 1
        case "invalid-after-match": registry.entries.reverse(); registry.invalidAfter = 2
        case "invalid-at-end": registry.invalidateAtEnd = true
        case "id-read-failure": registry.entries[0].1 = nil
        case "zero-id": registry.entries[0].1 = 0
        case "late-id-read-failure": registry.entries = [(21,200),(20,nil)]
        case "duplicate": registry.entries.append((22,200))
        case "duplicate-same-reference": registry.entries.append((21,200))
        case "max-budget": registry.budget = 1
        case "max-budget-after-match": registry.entries.reverse(); registry.budget = 1
        case "zero-budget": registry.budget = 0
        default: preconditionFailure(mode)
        }
        precondition(registry.lookup().presence(200) == .unknown, mode)
        registry.balanced()
        if mode == "zero-budget" { precondition(registry.creates == 0) }
        print("PASS registry full-plane fail-closed \(mode) with balanced references")
    }
    for count in [0,1,2] {
        let registry = Registry()
        registry.entries = Array(registry.entries.prefix(count)); registry.budget = max(1,count)
        precondition(registry.lookup().presence(1) == .absent && registry.ended)
        registry.balanced()
        print("PASS registry full-plane complete empty/exact-budget count \(count)")
    }
    do {
        let registry = Registry()
        precondition(registry.lookup().presence(0) == .unknown && registry.creates == 0)
        registry.balanced()
        print("PASS registry full-plane zero target refused before enumeration")
    }
    for survivor: UInt64 in [0,5,6] {
        let registry = Registry()
        if survivor != 0 { registry.entries.append((22,survivor)) }
        var closes = 0, probes: [UInt64] = []
        let boundary = USBRootGuardCloseBoundary(close: { closes += 1; return 0 },presence: {
            probes.append($0); return registry.lookup().presence($0)
        })
        var accepted = false
        do { try boundary.closeAfterDrain(rootID:1,clientIDs:[5,6]); accepted = true } catch {}
        precondition(accepted == (survivor == 0) && closes == 1)
        precondition(probes.first == 1 && probes.contains(5) && (survivor == 5 || probes.contains(6)))
        registry.balanced()
        print("PASS registry full-plane actual checked-close boundary survivor \(survivor)")
    }
    do {
        let registry = Registry()
        registry.entries.append((22,1))
        var probes: [UInt64] = []
        let boundary = USBRootGuardCloseBoundary(close: { 0 },presence: {
            probes.append($0); return registry.lookup().presence($0)
        })
        try boundary.closeAfterDrain(rootID:1,clientIDs:[5,6])
        precondition(probes == [1], "present root retains existing normal-close policy")
        registry.balanced()
        print("PASS registry full-plane present root preserves existing normal-close policy")
    }
}
