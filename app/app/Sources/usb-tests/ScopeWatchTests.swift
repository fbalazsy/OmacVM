import Foundation
import OmacVMUSB

func scopeWatchTests() {
    // Same notification order as vanilla: ordinary USB does not gain HID ordering.
    var r = USBWatch.Reads()
    let old = r.begin(11), new = r.begin(12)
    expect(r.finish(12, ticket: new, location: 1, hid: false) && r.finish(11, ticket: old, location: 1, hid: false),
           "SCOPE2 ordinary watch publishes both completed snapshots in completion order")
    expect(r.remove(12) == 1 && r.remove(11) == 1,
           "SCOPE2 ordinary watch preserves each original termination mapping")
    let pending = r.begin(13)
    expect(r.remove(13) == nil && !r.finish(13, ticket: pending, location: 2, hid: false),
           "SCOPE2 ordinary watch suppresses removal while settling")
    for publicationFirst in [false, true] {
        var overlap = USBWatch.Reads()
        let parent = overlap.begin(11), hid = overlap.begin(11, publication: true)
        if publicationFirst {
            expect(overlap.finish(11, ticket: hid, location: 1, hid: true, publication: true)
                   && !overlap.finish(11, ticket: parent, location: 1, hid: false),
                   "C2-3 newer HID completion suppresses an older parent snapshot")
        } else {
            expect(overlap.finish(11, ticket: parent, location: 1, hid: false)
                   && overlap.finish(11, ticket: hid, location: 1, hid: true, publication: true),
                   "C2-3 parent completion does not erase a pending newer HID publication")
        }
        expect(overlap.remove(11) == 1 && overlap.remove(11) == nil,
               "C2-3 either completion order leaves one termination mapping")
    }
    // HID notification can also precede the initial USB notification; both reads now see HID.
    for initialCompletesFirst in [false, true] {
        var overlap = USBWatch.Reads()
        let publication = overlap.begin(11, publication: true), initial = overlap.begin(11)
        let fresh: Bool, stale: Bool
        if initialCompletesFirst {
            fresh = overlap.finish(11, ticket: initial, location: 1, hid: true)
            stale = overlap.finish(11, ticket: publication, location: 1, hid: true, publication: true)
        } else {
            stale = overlap.finish(11, ticket: publication, location: 1, hid: true, publication: true)
            fresh = overlap.finish(11, ticket: initial, location: 1, hid: true)
        }
        expect(fresh && !stale, "C2-3 reversed notification order still publishes newest target once")
        expect(overlap.remove(11) == 1, "C2-3 reversed notification order retains target removal")
    }
}
