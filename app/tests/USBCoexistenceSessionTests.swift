import Foundation

final class CoexistenceSessionMachine: USBMachine {
    var answer: ((USBAttachResult)->Void)?
    var release: ((Bool)->Void)?
    var attaches = 0
    func attach(_ d:USBDevice,done:@escaping(USBAttachResult)->Void) { attaches += 1; answer = done }
    func detach(_ d:USBDevice,done:@escaping(Bool)->Void) { release = done }
    func isAttached(_ d:USBDevice,done:@escaping(Bool)->Void) { done(true) }
}
final class CoexistenceAsker: USBAsker {
    func ask(_ q:USBQuestion,answer:@escaping(USBAnswer)->Void) { answer(.init(connect:true,always:false)) }
    func cancel() {}
    func notice(title:String,text:String) {}
}
final class CoexistenceClock: USBClock { func after(_ seconds:Double,_ run:@escaping()->Void) {} }
func coexistenceSessionTests(root:USBScan.Entry) {
    var d = USBDevice(id:.init(vendor:1234,product:5678),name:"board",deviceClass:0,interfaces:[.init(number:0,interfaceClass:3,users:["IOHIDDevice"])],location:1)
    d.coexistence = USBCoexistenceCandidate.resolve(root,qemuPID:200)!
    let machine = CoexistenceSessionMachine()
    let session = USBSession(vmName:"test",memory:USBMemory(),machine:machine,asker:CoexistenceAsker(),clock:CoexistenceClock(),save:{_ in},log:{_ in})
    session.plugged(d); machine.answer?(.failed("EOF"))
    let rows = USBListRows.make(memory:session.memory,devices:[d],states:session.plugs.mapValues(\.state),vmName:"test")
    precondition(rows.plugged.count == 1 && !rows.plugged[0].canConnect, "unknown ownership cannot display On Mac / retry")
    precondition(rows.plugged[0].status.contains("pending"))
    var replacement = d; replacement.coexistence = nil; replacement.interfaces = []
    session.plugged(replacement); session.connectNow(location:1)
    precondition(machine.attaches == 1, "unknown candidate must not ordinary fallback on replacement")
    let earlyMachine = CoexistenceSessionMachine()
    let early = USBSession(vmName:"test",memory:USBMemory(),machine:earlyMachine,asker:CoexistenceAsker(),clock:CoexistenceClock(),save:{_ in},log:{_ in})
    var unready = d; unready.coexistence = nil
    early.plugged(unready)
    early.plugged(d)
    precondition(earlyMachine.attaches == 1, "late pending candidate must replace unavailable snapshot even with nil HID")
    // A user may reconnect the identical target after a terminal phase is
    // delivered but before the old attempt's failed completion is delivered.
    do {
        let m = CoexistenceSessionMachine()
        let s = USBSession(vmName:"same-target-retry",memory:USBMemory(),machine:m,asker:CoexistenceAsker(),clock:CoexistenceClock(),save:{ _ in },log:{ _ in })
        s.plugged(d)
        let old = m.answer!
        s.coexistencePhase(.retired,device:d)
        s.connectNow(location:1)
        let fresh = m.answer!
        precondition(m.attaches == 2 && s.plugs[1]?.state == .connecting)
        old(.failed("old attempt already retired"))
        precondition(s.plugs[1]?.state == .connecting,"late identical-target completion must not overwrite a new attempt")
        fresh(.attached)
        precondition(s.plugs[1]?.state == .connected)
        print("PASS same-target reconnect rejects previous retired attempt completion")
        s.disconnectNow(location:1)
        let oldRelease = m.release!
        s.coexistencePhase(.retired,device:d)
        s.connectNow(location:1)
        let third = m.answer!
        oldRelease(true)
        precondition(s.plugs[1]?.state == .connecting,"late identical-target release must not retire a new attempt")
        third(.attached)
        precondition(s.plugs[1]?.state == .connected)
        print("PASS same-target reconnect rejects previous retired release completion")
    }
    print("PASS session uncertain ownership prevents retry and ordinary replacement")
}
