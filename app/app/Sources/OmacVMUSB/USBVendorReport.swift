import Foundation

extension USBDevice {
    /// Discovery only. Root repeats topology/report validation before and after capture.
    /// Unknown, composite, boot, keyboard/mouse/FIDO reports remain unavailable.
    public var captureCandidate: Bool {
        guard registryID != 0, location != 0, id.vendor != 0,
              !rawSerial.isEmpty, rawSerial.utf8.count <= 255, !rawSerial.utf8.contains(0),
              deviceClass == 0 || deviceClass == 3, interfaces.count == 1,
              let i = interfaces.first, i.interfaceClass == 3, i.interfaceSubclass == 0,
              i.interfaceProtocol == 0, let report = i.reportDescriptor else { return false }
        return USBVendorReport.preliminary(report)
    }
}

public enum USBVendorReport {
    /// Deliberately narrow short-item subset. This is not a replacement for native policy.
    public static func preliminary(_ data: Data) -> Bool {
        let b = Array(data)
        guard !b.isEmpty, b.count <= 4096 else { return false }
        var offset = 0, page: UInt32 = 0, depth = 0, fields = 0
        while offset < b.count {
            let tag = b[offset]; offset += 1
            guard tag != 0xfe else { return false }
            let count = tag & 3 == 3 ? 4 : Int(tag & 3)
            guard offset + count <= b.count else { return false }
            var value: UInt32 = 0
            for j in 0..<count { value |= UInt32(b[offset + j]) << (j * 8) }
            offset += count
            switch tag & 0xfc {
            case 0x04: // global usage page
                guard value >= 0xff00, value <= 0xffff else { return false }
                page = value
            case 0x08, 0x18, 0x28: // usage, usage min/max; extended usage embeds page
                guard page >= 0xff00, count != 4 || value >> 16 >= 0xff00 else { return false }
            case 0xa0:
                guard page >= 0xff00, value == 1, depth == 0 else { return false }
                depth += 1
            case 0xc0:
                guard count == 0, depth == 1 else { return false }; depth -= 1
            case 0x80, 0x90, 0xb0:
                guard depth == 1, page >= 0xff00 else { return false }; fields += 1
            case 0x14, 0x24, 0x34, 0x44, 0x54, 0x64, 0x74, 0x84, 0x94:
                break // bounded numeric globals; native validates actual report/endpoint sizes
            default: return false // push/pop, delimiters, reserved or long items
            }
        }
        return depth == 0 && fields > 0
    }
}
