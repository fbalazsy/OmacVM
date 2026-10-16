import Foundation
import Darwin
import OmacVMUSB

// Error dependency only; no AppDelegate, Runner, USBWatch or app entry point.
enum HelperError: Error { case io(String) }

@main struct CoexistenceSocketTests {
    static func main() throws {
        for (payload, valid) in [
            ("{\"id\":\"fixture-1\",\"return\":{\"n\":\"18446744073709551615\"}}",true),
            ("{\"id\":\"fixture-1\",\"return\":{\"n\":\"1\",\"n\":\"2\"}}",false),
            ("{\"id\":\"fixture-1\",\"return\":{},\"error\":\"bad\"}",false),
            ("{\"id\":\"fixture-1\",\"return\":{\"pid\":1.0}}",false),
            ("{\"id\":\"fixture-1\",\"error\":{\"class\":\"GenericError\",\"desc\":\"COEX_POLICY test\"}}",false),
            ("EOF",false), ("TIMEOUT",false)
        ] {
            var pair:[Int32] = [0,0]; precondition(socketpair(AF_UNIX,SOCK_STREAM,0,&pair) == 0)
            let server = pair[1]; let client = pair[0]
            let ended = DispatchSemaphore(value:0)
            DispatchQueue.global().async {
                defer { Darwin.close(server); ended.signal() }
                func send(_ s:String) { let bytes=Array((s+"\n").utf8); _ = bytes.withUnsafeBytes { Darwin.write(server,$0.baseAddress,bytes.count) } }
                func read() { var b:UInt8=0; while Darwin.read(server,&b,1) == 1 && b != 10 {} }
                send("{\"QMP\":{}}")
                read(); send("{\"id\":\"fixture-capabilities\",\"return\":{}}")
                read()
                if payload == "EOF" { return }
                if payload == "TIMEOUT" { Thread.sleep(forTimeInterval:0.12); return }
                send(payload)
            }
            let q = try QMPConnection(connectedDescriptor:client,identifierPrefix:"fixture")
            let value = try? q.execute("x-omacvm-usb-coexistence-status",timeoutMilliseconds:50)
            precondition((value != nil) == valid)
            q.close(); precondition(ended.wait(timeout:.now()+2) == .success)
        }
        print("PASS actual QMPConnection strict raw frames: uint64, duplicates, contradictory envelope, float, rejection, EOF, timeout")
    }
}
