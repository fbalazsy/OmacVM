import Foundation

/// A discovery hint, NOT an admission receipt. The only projected node is one
/// exact root cache-shaped client with kernel creator metadata. Prepare must
/// independently attribute it to its singleton ordinary context and live task.
public struct USBCoexistenceCandidate: Equatable, Sendable {
    public let target: USBCoexistenceTarget
    public let descriptor: Data
    /// Explicit target hint for the owned live controller, never an admission
    /// receipt. Guard and QEMU still independently validate the real tree.
    public init(target: USBCoexistenceTarget, descriptor: Data) throws {
        guard target.descriptorHash == USBCoexistenceTarget.hash(descriptor) else { throw USBCoexistenceError.identity }
        self.target = target; self.descriptor = descriptor
    }
    public static func resolve(_ root: USBScan.Entry, qemuPID: Int32? = nil) -> Self? {
        guard root.registryID != 0, root.descendants.allSatisfy({ $0.properties["built-in"] == nil }),
              let serial = root.properties["USB Serial Number"] as? String else { return nil }
        var projected = root
        let clients = root.children.filter { $0.className == "AppleUSBHostDeviceUserClient" }
        guard clients.count <= 1 else { return nil }
        if let client = clients.first {
            guard let qemuPID, qemuPID > 0, USBRootGuardPolicy.creator(client,pid:qemuPID),
                  client.registryID != 0, client.children.isEmpty,
                  let creator = client.properties["IOUserClientCreator"] as? String,
                  creator.range(of:"^pid [1-9][0-9]*, .+$",options:.regularExpression) != nil else { return nil }
            // Validate original protected metadata through unchanged policy.
            let index = projected.children.firstIndex { $0.registryID == client.registryID }!
            projected.children[index].className = "AppleUSBHostCompositeDevice"
        }
        guard let hid = USBHID.resolve(projected), Data(hid.serial.utf8) == Data(serial.utf8),
              let interface = root.children.first(where: { $0.className == "IOUSBHostInterface" }),
              let node = interface.children.first(where: { $0.registryID == hid.registryID }),
              let descriptor = node.properties["ReportDescriptor"] as? Data,
              let target = try? USBCoexistenceTarget(wire:["root-id":String(root.registryID),"interface-id":String(interface.registryID),"hid-id":String(hid.registryID),"vendor-id":root.properties["idVendor"] as Any,"product-id":root.properties["idProduct"] as Any,"serial-utf8":serial,"descriptor-sha256":USBCoexistenceTarget.hash(descriptor)]) else { return nil }
        return try? Self(target:target,descriptor:descriptor)
    }
}
