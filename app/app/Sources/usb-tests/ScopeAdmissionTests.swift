import Foundation
import OmacVMUSB

func scopeAdmissionTests() {
    // Parent's read-only topology, not a new enumeration or transport claim.
    var actual = hidTree(serial: "tFIXTUR0E123")
    actual.registryID = 1001
    actual.properties["idVendor"] = 49745; actual.properties["idProduct"] = 5889
    actual.children[0].registryID = 1002
    actual.children[0].children[0].registryID = 1003
    actual.children[0].children[0].properties["VendorID"] = 49745
    actual.children[0].children[0].properties["ProductID"] = 5889
    actual.children[0].children[0].className = "AppleUserHIDDevice"
    actual.children[0].children[0].name = "AppleUserUSBHostHIDDevice"
    let usage: [String: Any] = ["PrimaryUsagePage": 65280, "PrimaryUsage": 1,
        "DeviceUsagePairs": [["DeviceUsagePage": 65280, "DeviceUsage": 1]]]
    actual.children[0].children[0].properties.merge(usage) { _, b in b }
    actual.children[0].children[0].children = [.init(registryID: 1004, className: "IOHIDInterface", properties: usage)]
    actual.children.append(.init(registryID: 33, className: "AppleUSBHostCompositeDevice"))
    expect(USBScan.device(actual)?.hid != nil, "SCOPE1 actual generic AppleUserHIDDevice + vendor IOHIDInterface topology admitted")
    func denied(_ label: String, _ mutate: (inout USBScan.Entry) -> Void) {
        var t = actual; mutate(&t)
        expect(USBScan.device(t)?.hid == nil, "SCOPE1 reject " + label)
    }
    for depth in 0...3 {
        func mutate(_ t: inout USBScan.Entry, _ body: (inout USBScan.Entry) -> Void) {
            switch depth {
            case 0: body(&t)
            case 1: body(&t.children[0])
            case 2: body(&t.children[0].children[0])
            default: body(&t.children[0].children[0].children[0])
            }
        }
        for value: Any in [true, 1, "false", Data([1])] {
            denied("Built-In at depth \(depth) type \(type(of: value))") { t in mutate(&t) { $0.properties["Built-In"] = value } }
        }
        for page in [1, 7, 0x0d, 0xf1d0] {
            denied("semantic page \(page) at depth \(depth)") { t in mutate(&t) {
                $0.properties["PrimaryUsagePage"] = page
                $0.properties["PrimaryUsage"] = 5
                $0.properties["DeviceUsagePairs"] = [["DeviceUsagePage": page, "DeviceUsage": 5]]
            } }
        }
        denied("malformed usage pair at depth \(depth)") { t in mutate(&t) { $0.properties["DeviceUsagePairs"] = "vendor" } }
    }
    for key in ["PrimaryUsagePage", "PrimaryUsage", "DeviceUsagePairs"] {
        denied("missing HID \(key)") { $0.children[0].children[0].properties[key] = nil }
        denied("malformed HID \(key)") { $0.children[0].children[0].properties[key] = true }
    }
    denied("out-of-range raw VID cannot become truncated HID identity") {
        $0.properties["idVendor"] = 0x11209
        $0.children[0].children[0].properties["VendorID"] = 0x11209
    }
    denied("out-of-range raw PID cannot become truncated HID identity") {
        $0.properties["idProduct"] = 0x10007
        $0.children[0].children[0].properties["ProductID"] = 0x10007
    }
    denied("empty usage pairs") { $0.children[0].children[0].properties["DeviceUsagePairs"] = [] as [[String: Any]] }
    denied("contradictory usage pairs") { $0.children[0].children[0].properties["DeviceUsagePairs"] = [["DeviceUsagePage": 0xff01, "DeviceUsage": 1]] }
    denied("metadata disagrees with descriptor application") {
        $0.children[0].children[0].properties["PrimaryUsagePage"] = 0xff01
        $0.children[0].children[0].properties["DeviceUsagePairs"] = [["DeviceUsagePage": 0xff01, "DeviceUsage": 1]]
    }
    denied("metadata usage disagrees with descriptor application") {
        $0.children[0].children[0].properties["PrimaryUsage"] = 2
        $0.children[0].children[0].properties["DeviceUsagePairs"] = [["DeviceUsagePage": 0xff00, "DeviceUsage": 2]]
    }
    denied("leaf disagrees with selected service") {
        $0.children[0].children[0].children[0].properties["PrimaryUsagePage"] = 0xff01
        $0.children[0].children[0].children[0].properties["DeviceUsagePairs"] = [["DeviceUsagePage": 0xff01, "DeviceUsage": 1]]
    }
    for cls in ["AppleMultitouchHIDEventDriver", "VendorSpecialHIDDevice", "IOHIDEventService"] {
        denied("specialized conforming class \(cls)") { $0.children[0].children[0].className = cls }
    }
    for owner in ["OmacVM@501", "qemu-system-aarch64@501", "other@501"] {
        for depth in [2, 3] {
            denied("owned descendant \(owner) at depth \(depth)") {
                let client = USBScan.Entry(registryID: 99, className: "IOHIDLibUserClient", name: owner)
                if depth == 2 { $0.children[0].children[0].children.append(client) }
                else { $0.children[0].children[0].children[0].children.append(client) }
            }
        }
    }
    denied("look-only root client hiding owner") {
        $0.children.append(.init(registryID: 98, className: "IOUSBHostDeviceUserClient", children: [.init(registryID: 99, className: "IOHIDLibUserClient", name: "OmacVM@501")]))
    }
}
