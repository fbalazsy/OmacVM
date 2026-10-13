import Foundation

/// Issued only by foreground Connect, for this registry generation and VM session.
/// Ordinary remembered USB choices cannot manufacture this grant.
public struct USBCaptureGrant: Equatable, Sendable {
    public let attempt: UUID
    public let run: UUID
    public let device: USBDevice
    init(run: UUID, device: USBDevice) {
        self.attempt = UUID(); self.run = run; self.device = device
    }
}

public enum USBCaptureEvent: Equatable, Sendable {
    case authorizing, capturing, connected, releasing
    case released(hidRestored: Bool)
    case refused(String) // proven no native/QMP ownership
    case uncertain(String) // owner MUST be retained
}

public protocol USBCaptureMachine: AnyObject {
    func capture(_ grant: USBCaptureGrant, event: @escaping (USBCaptureEvent) -> Void)
    func cancelCapture(_ attempt: UUID)
}
