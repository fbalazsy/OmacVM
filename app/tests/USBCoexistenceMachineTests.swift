import Foundation

func coexistenceMachineTests(root:USBScan.Entry,receipt:USBRootGuardReceipt) throws {
    func result<T>(_ body: (@escaping (T)->Void)->Void) -> T {
        let s = DispatchSemaphore(value:0); var value:T?
        body { value=$0; s.signal() }; precondition(s.wait(timeout:.now()+3) == .success); return value!
    }
    let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
    let initial = try USBCoexistenceStatus(wire:peer.wire)
    var d = USBDevice(id:.init(vendor:1234,product:5678),name:"board",deviceClass:0,interfaces:[.init(number:0,interfaceClass:3,users:[])],location:1)
    d.coexistence = USBCoexistenceCandidate.resolve(root,qemuPID:200)
    let machine = USBQMPMachine(transport:peer,coexistenceFactory:{ _ in
        USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:USBCoexistenceLedger(),automaticTimers:false,taskMatches:{_ in true},guardFactory:{ r, revoke in
            USBRootGuard(driver:peer.driver,receipt:r,lifetime:5,onRevoke:revoke)
        })
    },deliver:{$0()})
    precondition(result { machine.attach(d,done:$0) } == .attached)
    var replacement = d; replacement.coexistence = nil
    precondition(result { machine.attach(replacement,done:$0) } != .attached)
    precondition(result { machine.isAttached(d,done:$0) })
    precondition(result { machine.detach(d,done:$0) })
    precondition(!peer.commands.contains("device_add") && !peer.commands.contains("device_del"))
    print("PASS production USBQMPMachine uses coordinator and protects owned location")

    final class Ordinary: USBQMPTransport {
        var commands:[String] = []
        var attached = false
        func execute(_ command:String,_ args:[String:Any]?) throws -> [String:Any] {
            commands.append(command)
            if command == "device_add" { precondition(args?["driver"] as? String == "usb-host"); attached=true }
            if command == "device_del" { attached=false }
            if command == "human-monitor-command" { return ["text":attached ? "  Device 0.1, Port 1, Speed 12 Mb/s, Product fixture, ID: usbh-00000001" : ""] }
            return [:]
        }
    }
    let ordinary = Ordinary(); let control = USBQMPMachine(transport:ordinary,deliver:{$0()})
    precondition(result { control.attach(replacement,done:$0) } == .attached)
    precondition(result { control.detach(replacement,done:$0) })
    precondition(ordinary.commands == ["device_add","human-monitor-command","device_del","human-monitor-command"])
    let off = USBQMPMachine(transport:ordinary,deliver:{$0()})
    precondition(result { off.attach(d,done:$0) } != .attached)
    precondition(ordinary.commands.count == 4)
    precondition(!USBVendorHID.isOn(fileText:nil))
    print("PASS ordinary production machine trace and default OFF refusal")
}
