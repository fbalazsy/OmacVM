import Foundation

// One actual USBSession + USBQMPMachine + ledger + launcher/QEMU identity across
// A1 HID -> A2 ordinary -> A3 HID, using only fake transport/kernel boundaries.
func coexistenceModeCycleTests(root: USBScan.Entry, receipt: USBRootGuardReceipt) throws {
    final class Peer: USBQMPTransport {
        var native: CoexistencePeer
        var ordinary = false
        var ordinaryAdds = 0
        init(_ native: CoexistencePeer) { self.native = native }
        func execute(_ command:String,_ args:[String:Any]?) throws -> [String:Any] {
            if command.hasPrefix("x-omacvm-") { return try native.execute(command,args) }
            if command == "device_add" {
                precondition(native.wire["state"] as? String == "retired", "bulk before old lease retired")
                precondition(args?["driver"] as? String == "usb-host")
                ordinary = true; ordinaryAdds += 1
            }
            if command == "device_del" { ordinary = false }
            if command == "human-monitor-command" { return ["text":ordinary ? "Device 0.1, Port 1, Speed 12 Mb/s, Product fixture, ID: usbh-00000001" : ""] }
            return [:]
        }
    }
    let a1 = CoexistencePeer(root:root,descriptor:receipt.descriptor)
    let initial = try USBCoexistenceStatus(wire:a1.wire)
    let peer = Peer(a1), ledger = USBCoexistenceLedger()
    let ui = DispatchQueue(label:"mode-cycle-session")
    let machine = USBQMPMachine(transport:peer,coexistenceFactory:{ _ in
        let current = peer.native
        return USBCoexistenceCoordinator(transport:current,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:false,taskMatches:{ _ in true },guardFactory:{ r, revoke in
            USBRootGuard(driver:current.driver,receipt:r,lifetime:30,pollInterval:10,onRevoke:revoke)
        })
    },deliver:{ body in ui.async { body() } })
    var hid = USBDevice(id:.init(vendor:1234,product:5678),name:"A1",deviceClass:0,interfaces:[.init(number:0,interfaceClass:3,users:[])],location:1)
    hid.coexistence = USBCoexistenceCandidate.resolve(root,qemuPID:200)!
    hid.coexistenceRootID = 1
    var bulk = USBDevice(id:.init(vendor:1234,product:5679),name:"A2",deviceClass:0,interfaces:[],location:1)
    bulk.coexistenceRootID = 50
    var memory = USBMemory(); memory.remember(hid,.omarchy); memory.remember(bulk,.mac)
    let session = USBSession(vmName:"same-process",memory:memory,machine:machine,asker:CoexistenceAsker(),clock:CoexistenceClock(),save:{ _ in },log:{ _ in })
    machine.onCoexistencePhase = { phase,d in session.coexistencePhase(phase,device:d) }
    func until(_ label:String,_ predicate:() -> Bool) {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while !ui.sync(execute:predicate) && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval:0.005) }
        precondition(ui.sync(execute:predicate),label)
    }
    ui.sync { session.plugged(hid) }
    until("A1 native") { session.plugs[1]?.state == .connected }
    var presence:USBRootGuardPresence = .unknown
    var closeCalls = 0
    let boundary = USBRootGuardCloseBoundary(close:{ closeCalls += 1; return 0 },presence:{ _ in presence })
    a1.driver.drainedClose = { try boundary.closeAfterDrain(rootID:$0,clientIDs:$1) }
    ui.sync { session.plugged(bulk); session.unplugged(location:1,rootID:1) }
    until("unknown held") { session.plugs[1]?.state == .coexistencePending }
    // Wait through coordinator completion before changing the injected read.
    let barrier = DispatchSemaphore(value:0)
    machine.detach(hid) { _ in barrier.signal() }
    precondition(barrier.wait(timeout:.now()+3) == .success)
    precondition(a1.driver.released == 0 && peer.ordinaryAdds == 0)
    presence = .absent
    ui.sync { session.disconnectNow(location:1) }
    until("A2 own Mac plan") { session.plugs[1]?.device == bulk && session.plugs[1]?.state == .onMac(remembered:true) }
    precondition(closeCalls == 1 && a1.driver.released == 1 && peer.ordinaryAdds == 0)
    ui.sync { session.unplugged(location:1,rootID:1); session.connectNow(location:1) }
    until("A2 explicit ordinary") { session.plugs[1]?.state == .connected }
    ui.sync { session.disconnectNow(location:1) }
    until("A2 closed") { session.plugs[1]?.state == .onMac(remembered:false) }
    ui.sync { session.unplugged(location:1,rootID:50) }

    func shift(_ node:USBScan.Entry) -> USBScan.Entry {
        var n = node; n.registryID += 100; n.children = n.children.map(shift); return n
    }
    var newRoot = shift(root); newRoot.properties["sessionID"] = UInt64(199)
    let a3 = CoexistencePeer(root:newRoot,descriptor:receipt.descriptor)
    a3.guardID = 105; a3.nativeID = 106; a3.driver.guardID = 105
    var lease = a3.wire["lease"] as! [String:Any]; lease["lease-epoch"] = "2"; a3.wire["lease"] = lease
    var published = a3.wire["published"] as! [String:Any]
    let candidate = USBCoexistenceCandidate.resolve(newRoot,qemuPID:200)!
    published["target"] = candidate.target.wire; published["session"] = "199"; published["cache-client-id"] = "104"; a3.wire["published"] = published
    peer.native = a3
    var next = hid; next.name = "A3"; next.coexistence = candidate; next.coexistenceRootID = 101
    ui.sync { session.plugged(next) }
    until("A3 native same app/QEMU") { session.plugs[1]?.state == .connected }
    precondition(a3.commands.filter{$0 == "prepare"}.count == 1 && peer.ordinaryAdds == 1)
    precondition(!ledger.claim(root:101,owner:UUID()))
    ui.sync { session.unplugged(location:1,rootID:1) }
    precondition(ui.sync { session.plugs[1]?.device == next })
    let goneA3 = USBRootGuardCloseBoundary(close:{ 0 },presence:{ _ in .absent })
    a3.driver.drainedClose = { try goneA3.closeAfterDrain(rootID:$0,clientIDs:$1) }
    ui.sync { session.unplugged(location:1,rootID:101) }
    until("A3 physical removal retired") { session.plugs[1] == nil }
    precondition(a3.driver.successfulCloses == 1)
    var replugRoot = shift(newRoot); replugRoot.properties["sessionID"] = UInt64(299)
    let a4 = CoexistencePeer(root:replugRoot,descriptor:receipt.descriptor)
    a4.guardID = 205; a4.nativeID = 206; a4.driver.guardID = 205
    lease["lease-epoch"] = "3"; a4.wire["lease"] = lease
    let replug = USBCoexistenceCandidate.resolve(replugRoot,qemuPID:200)!
    published["target"] = replug.target.wire; published["session"] = "299"; published["cache-client-id"] = "204"; a4.wire["published"] = published
    peer.native = a4
    next.name = "A4-replug"; next.coexistence = replug; next.coexistenceRootID = 201
    ui.sync { session.plugged(next) }
    until("physical replug without restart") { session.plugs[1]?.state == .connected }
    ui.sync { session.disconnectNow(location:1) }
    until("A4 retired") { session.plugs[1]?.state == .onMac(remembered:false) }
    precondition(a4.driver.successfulCloses == 1)
    print("PASS normal physical remove/replug actual session and coordinator without app/QEMU restart")
    print("PASS actual session/machine/coordinator A1-HID A2-bulk A3-HID same app/QEMU; own Mac policy, unknown quarantine, old removal ignored")
}
