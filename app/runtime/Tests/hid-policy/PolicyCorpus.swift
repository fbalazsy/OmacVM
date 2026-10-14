import Foundation
import OmacVMUSB

// Offline adapter: the same plist graph/properties as the native API shim.
@main struct PolicyCorpus {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let corpus = try PropertyListSerialization.propertyList(from: data, format: nil) as! [[String: Any]]
        var failures = 0
        for item in corpus {
            let name = item["name"] as! String
            let nodes = item["nodes"] as! [[String: Any]]
            func entry(_ index: Int) -> USBScan.Entry {
                let n = nodes[index - 1]
                return .init(registryID: index == 1 ? 123 : UInt64(10000 + index),
                             className: n["cls"] as! String,
                             conforms: Set(n["conforms"] as! [String]),
                             properties: n["props"] as! [String: Any],
                             children: nodes.indices.filter { (nodes[$0]["parent"] as! Int) == index }.map { entry($0 + 1) })
            }
            let device = USBScan.device(entry(2))
            let expected = (item["swift"] as! NSNumber).boolValue
            var accepted = false
            if let d = device {
                let rows = USBListRows.make(memory: USBMemory(), devices: [d], states: nil, vmName: "Fixture")
                let args = USBQMP.attachArguments(d)
                accepted = d.hid != nil && d.availability == .free && rows.plugged.count == 1 &&
                           args["driver"] as? String == "usb-host-hid" &&
                           args["registry-id"] as? UInt64 == 123 &&
                           args["serial"] as? String == nodes[0]["props"].flatMap { ($0 as? [String:Any])?["SerialNumber"] as? String } &&
                           args["hostbus"] == nil && args["hostaddr"] == nil
            }
            let pass = expected == accepted
            if !pass { failures += 1 }
            print("\(pass ? "PASS" : "FAIL") \(name) expected=\(expected) actual=\(accepted)")
        }
        print("Swift scan→rows→args: \(corpus.count) cases, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
