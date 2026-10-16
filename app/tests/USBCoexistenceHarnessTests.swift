import Foundation

func coexistenceHarnessTests(root:USBScan.Entry,receipt:USBRootGuardReceipt) throws {
    final class Peer: USBQMPTransport {
        var current:CoexistencePeer
        var bulk = false, adds = 0
        init(_ current:CoexistencePeer) { self.current = current }
        func execute(_ command:String,_ args:[String:Any]?) throws -> [String:Any] {
            if command.hasPrefix("x-omacvm-") { return try current.execute(command,args) }
            if command == "device_add" {
                precondition(current.wire["state"] as? String == "retired")
                precondition(args?["driver"] as? String == "usb-host")
                bulk = true; adds += 1
            }
            if command == "device_del" { bulk = false }
            if command == "human-monitor-command" { return ["text":bulk ? "Device, ID: usbh-00000001" : ""] }
            return [:]
        }
    }
    let peer = Peer(CoexistencePeer(root:root,descriptor:receipt.descriptor))
    let initial = try USBCoexistenceStatus(wire:peer.current.wire)
    let ledger = USBCoexistenceLedger()
    var factories = 0, alive = true
    let control = LiveCoexistenceController(transport:peer,qemu:initial.qemu,launch:initial.launch,childMatches:{ alive },factory:{
        factories += 1
        let native = peer.current
        return USBCoexistenceCoordinator(transport:native,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:false,taskMatches:{ _ in alive },guardFactory:{ r,revoke in USBRootGuard(driver:native.driver,receipt:r,lifetime:30,onRevoke:revoke) })
    })
    let dir = URL(fileURLWithPath:ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("control-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
    defer { try? FileManager.default.removeItem(at:dir) }
    let target = dir.appendingPathComponent("target.json"), descriptor = dir.appendingPathComponent("descriptor.bin")
    try JSONSerialization.data(withJSONObject:initial.target.wire).write(to:target)
    try receipt.descriptor.write(to:descriptor)
    func send(_ obj:[String:Any]) throws { control.submit(try JSONSerialization.data(withJSONObject:obj)) }
    func wait(_ state:String) {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while control.state != state && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval:0.005) }
        precondition(control.state == state,"harness expected \(state), got \(control.state)")
    }
    let attach:[String:Any] = ["command":"attach","target-file":target.path,"descriptor-file":descriptor.path]
    let bulk:[String:Any] = ["command":"bulk","vendor":"1234","product":"5679","location":"1","address":"2"]
    try send(attach); wait("native")
    precondition(control.sessionStates[1] == .connected,"controller must attach through actual USBSession, not bypass it")
    try send(attach); try send(bulk)
    precondition(factories == 1 && peer.adds == 0,"active lease must block both replacements")
    try send(["command":"detach"]); wait("retired")
    try send(bulk); wait("bulk")
    try send(attach); precondition(factories == 1,"bulk ownership must block HID")
    try send(["command":"detach"]); wait("retired")
    peer.current = CoexistencePeer(root:root,descriptor:receipt.descriptor)
    var lease = peer.current.wire["lease"] as! [String:Any]; lease["lease-epoch"] = "2"; peer.current.wire["lease"] = lease
    try send(attach); wait("native")
    precondition(control.sessionStates[1] == .connected,"controller must attach through actual USBSession, not bypass it")
    precondition(factories == 2 && peer.adds == 1)
    try send(["command":"detach"]); wait("retired")
    alive = false; try send(attach); try send(bulk)
    precondition(factories == 2 && peer.adds == 1)
    print("PASS actual live controller DI: attach/bulk/attach same launch and QEMU identity; retirement and death gates; no process or registry execution")
}
