import Foundation
import OmacVMUSB

func scopeDecoderTests() {
    var t = hidTree(); t.children = []
    t.properties["idVendor"] = 0x11209
    t.properties["idProduct"] = 0x10007
    expect(USBScan.device(t)?.id == USBDeviceID(vendor: 0x1209, product: 7), "SCOPE3 shallow snapshot keeps upstream numeric truncation")
    t = hidTree(); t.children = []; t.name = "registry fallback"
    t.properties["USB Product Name"] = ""; t.properties["kUSBProductString"] = "alternate"
    t.properties["USB Serial Number"] = ""; t.properties["kUSBSerialNumberString"] = " A\nB "
    expect(USBScan.device(t)?.name == "alternate" && USBScan.device(t)?.serial == "AB", "SCOPE3 shallow snapshot keeps empty-property alias fallback")
    t = hidTree(); t.children[0].className = "SpecializedUSBInterface"
    expect(USBScan.device(t)?.hid == nil && USBScan.device(t)?.availability == .usedByMac("in use on the Mac (SpecializedUSBInterface)"),
           "SCOPE3 specialized interface is a vanilla root driver, not a new target")
}
