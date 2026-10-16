import Foundation
func coexistenceInventoryTests(root:USBScan.Entry) {
    let pending = USBCoexistenceCandidate.resolve(root,qemuPID:200)
    precondition(pending?.target.root == 1)
    precondition(USBCoexistenceCandidate.resolve(root) == nil, "unattributed cache is not own QEMU")
    precondition(USBCoexistenceCandidate.resolve(root,qemuPID:201) == nil, "foreign cache must not be offered")
    precondition(USBHID.resolve(root) == nil, "pending must not globally relax HID policy")
    var d = USBDevice(id:.init(vendor:1234,product:5678),name:"board",deviceClass:0,interfaces:[.init(number:0,interfaceClass:3,users:["IOHIDDevice"])])
    d.coexistence = pending
    precondition(d.availability == .pendingCoexistence)
    precondition(USBQMP.attachArguments(d).isEmpty, "pending must never produce ordinary device_add")
    var bad = root; bad.children.append(root.children[1])
    precondition(USBCoexistenceCandidate.resolve(bad,qemuPID:200) == nil)
    bad = root; bad.children[0].properties["bInterfaceProtocol"] = 1
    precondition(USBCoexistenceCandidate.resolve(bad,qemuPID:200) == nil)
    bad = root; bad.properties["built-in"] = true
    precondition(USBCoexistenceCandidate.resolve(bad,qemuPID:200) == nil)
    bad = root; bad.children[1].properties["IOUserClientCreator"] = nil
    precondition(USBCoexistenceCandidate.resolve(bad,qemuPID:200) == nil)
    print("PASS pending inventory preserves policy and refuses ordinary fallback")
}
