import Foundation

// Fake only the IOKit boundary, not the collector or its property helpers.
typealias io_registry_entry_t = UInt32
typealias io_iterator_t = UInt32
let KERN_SUCCESS: Int32 = 0, kIOServicePlane = "IOService"
struct Node {
    var cls = "IOUSBHostDevice", conforms = Set<String>()
    var properties: [String: Any] = [:], children: [UInt32] = []
}
var nodes: [UInt32: Node] = [:], iterators: [UInt32: [UInt32]] = [:]
var refs: [UInt32: Int] = [:], keys: [UInt32: [String]] = [:], conformCalls: [String] = []
var names = 0, nextIterator: UInt32 = 10000, failIterator: UInt32 = 0, failures = 0
var nullIterator: UInt32 = 0, invalidateBefore: UInt32 = 0, invalidIterators = Set<UInt32>()
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL") \(name)"); if !condition { failures += 1 }
}
func IORegistryEntryGetRegistryEntryID(_ e: UInt32, _ id: inout UInt64) { id = UInt64(e) }
func IOObjectGetClass(_ e: UInt32, _ buffer: UnsafeMutablePointer<CChar>) -> Int32 {
    for (i, b) in nodes[e]!.cls.utf8.enumerated() { buffer[i] = CChar(bitPattern: b) }; return 0
}
func IORegistryEntryGetName(_ e: UInt32, _ buffer: UnsafeMutablePointer<CChar>) -> Int32 { names += 1; return 0 }
func IOObjectConformsTo(_ e: UInt32, _ cls: String) -> Int32 {
    conformCalls.append(cls); return nodes[e]!.conforms.contains(cls) ? 1 : 0
}
func IORegistryEntryCreateCFProperty(_ e: UInt32, _ key: CFString, _ allocator: CFAllocator?, _ options: UInt32) -> Unmanaged<CFTypeRef>? {
    let key = key as String; keys[e, default: []].append(key)
    return nodes[e]!.properties[key].map { Unmanaged.passRetained($0 as AnyObject) }
}
func IORegistryEntryGetChildIterator(_ e: UInt32, _ plane: String, _ it: inout UInt32) -> Int32 {
    if e == failIterator { return -1 }
    if e == nullIterator { it = 0; return KERN_SUCCESS }
    it = nextIterator; nextIterator += 1; iterators[it] = nodes[e]!.children; refs[it, default: 0] += 1; return 0
}
func IOIteratorNext(_ it: UInt32) -> UInt32 {
    guard let first = iterators[it]?.first else { return 0 }
    if first == invalidateBefore { invalidIterators.insert(it); return 0 }
    iterators[it]!.removeFirst(); refs[first, default: 0] += 1; return first
}
func IOIteratorIsValid(_ it: UInt32) -> Int32 { iterators[it] != nil && !invalidIterators.contains(it) ? 1 : 0 }
@discardableResult func IOObjectRelease(_ e: UInt32) -> Int32 { refs[e, default: 0] -= 1; return 0 }
let wanted = Set(["idVendor", "idProduct", "bDeviceClass", "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol",
                  "VendorID", "ProductID", "SerialNumber", "Product", "Transport", "ReportDescriptor",
                  "Built-In", "PrimaryUsagePage", "PrimaryUsage", "DeviceUsagePairs"])
func reset() {
    refs = [:]; keys = [:]; conformCalls = []; names = 0; iterators = [:]; failIterator = 0
    nullIterator = 0; invalidateBefore = 0; invalidIterators = []
}
@main struct CollectorTest {
    static func main() {
        let metadata: [String: Any] = ["idVendor": 0x1209, "idProduct": 7, "bDeviceClass": 0,
            "bInterfaceClass": 3, "bInterfaceSubClass": 0, "bInterfaceProtocol": 0,
            "VendorID": 0x1209, "ProductID": 7, "SerialNumber": " A\nΩ ", "Product": "Fixture", "Transport": "USB",
            "ReportDescriptor": Data([6,0,255,9,1,161,1,117,8,149,60,129,2,145,2,192]),
            "Built-In": false, "PrimaryUsagePage": 65280, "PrimaryUsage": 1,
            "DeviceUsagePairs": [["DeviceUsagePage": 65280, "DeviceUsage": 1]]]
        for i: UInt32 in 1...4 { nodes[i] = Node(properties: metadata, children: i < 4 ? [i + 1] : []) }
        nodes[2]!.cls = "IOUSBHostInterface"; nodes[3]!.cls = "AppleUserHIDDevice"
        nodes[3]!.conforms = ["IOHIDDevice"]; nodes[4]!.cls = "IOHIDInterface"
        var budget = 128
        let root = USBScan.readEntry(1, depth: 0, budget: &budget)
        check(root.descendants.count == 4 && budget == 124 && root.descendants.allSatisfy(\.complete), "complete topology and budget")
        check(keys.count == 4 && keys.values.allSatisfy { $0.count == 16 && Set($0) == wanted }, "exact admission key reads on every level: 64 total")
        check(conformCalls == Array(repeating: "IOHIDDevice", count: 4) && names == 0, "only HID conformance; no registry-name reads")
        check(root.descendants.allSatisfy { NSDictionary(dictionary: $0.properties).isEqual(to: metadata) }, "all metadata retained at every level")
        check(USBHID.resolve(root)?.serial == " A\nΩ " && USBHID.resolve(root)?.registryID == 3, "collected snapshot admitted with raw identity")
        check(refs.values.allSatisfy { $0 == 0 }, "all acquired children and iterators released; root borrowed")
        // NSNumber float/Bool must not become integers, nor Data/String lose bytes.
        for value: Any in [NSNumber(value: 65280.0), NSNumber(value: true), "65280", Data([0,255])] {
            reset(); nodes[2]!.properties["PrimaryUsagePage"] = value; budget = 128
            let snapshot = USBScan.readEntry(1, depth: 0, budget: &budget)
            let actual = snapshot.children[0].properties["PrimaryUsagePage"]! as AnyObject
            check(CFGetTypeID(actual) == CFGetTypeID(value as AnyObject) && actual.isEqual(value), "CF property type and value preserved")
            check(USBHID.resolve(snapshot) == nil, "malformed ancestor metadata remains visible to admission")
        }
        nodes[2]!.properties = metadata
        for level: UInt32 in 1...4 {
            reset(); nodes[level]!.properties["Built-In"] = true; budget = 128
            let snapshot = USBScan.readEntry(1, depth: 0, budget: &budget)
            check(USBHID.resolve(snapshot) == nil, "internal metadata retained at level \(level)")
            nodes[level]!.properties["Built-In"] = false
            reset(); failIterator = level; budget = 128
            let incomplete = USBScan.readEntry(1, depth: 0, budget: &budget)
            check(incomplete.descendants.contains { !$0.complete } && USBHID.resolve(incomplete) == nil
                  && refs.values.allSatisfy { $0 == 0 }, "iterator failure fails closed and balances releases at level \(level)")
        }
        for depth in [0, 16] {
            reset(); budget = depth == 0 ? 0 : 128
            let bounded = USBScan.readEntry(1, depth: depth, budget: &budget)
            check(!bounded.complete && keys.isEmpty && conformCalls.isEmpty && refs.isEmpty, "depth/budget pre-read bound \(depth)")
        }
        // Next returning zero can hide protected descendants, not just end a valid empty leaf.
        nodes[5] = Node(cls: "IOHIDEventService")
        nodes[6] = Node(cls: "IOHIDEventService")
        for mode in ["invalid-before", "invalid-after", "success-null", "empty-valid"] {
            reset(); budget = 128
            nodes[1]!.children = mode == "invalid-after" ? [2, 6] : [2]
            nodes[4]!.children = ["invalid-before", "success-null"].contains(mode) ? [5] : []
            invalidateBefore = mode == "invalid-before" ? 5 : mode == "invalid-after" ? 6 : 0
            nullIterator = mode == "success-null" ? 4 : 0
            let snapshot = USBScan.readEntry(1, depth: 0, budget: &budget)
            let complete = snapshot.descendants.allSatisfy(\.complete), admitted = USBHID.resolve(snapshot) != nil
            print("ITERATOR mode=\(mode) complete=\(complete) admitted=\(admitted) releasedNull=\(refs[0] ?? 0)")
            check(complete == (mode == "empty-valid") && admitted == (mode == "empty-valid"),
                  "iterator completeness and admission: \(mode)")
            check(refs.values.allSatisfy { $0 == 0 } && refs[0] == nil && refs[1] == nil && refs[6] == nil
                  && refs[5] == nil && refs.count == (mode == "success-null" ? 6 : 7)
                  && snapshot.descendants.count == 4 && keys.count == 4,
                  "only acquired nonzero references balanced: \(mode)")
        }
        reset(); nodes[1]!.children = Array(2...130)
        for i: UInt32 in 2...130 { nodes[i] = Node(properties: metadata) }
        budget = 128
        let bounded = USBScan.readEntry(1, depth: 0, budget: &budget)
        check(!bounded.complete && bounded.descendants.count == 128 && budget == 0 && keys.count == 128,
              "wide tree bounded to 128 property snapshots")
        check(refs.values.allSatisfy { $0 == 0 } && refs[129] == nil, "budget stop releases acquired references only")
        print("property calls \(keys.values.reduce(0) { $0 + $1.count }); failures \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
