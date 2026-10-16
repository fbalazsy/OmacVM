import Foundation

func coexistenceCodecTests() throws {
    let maximum = try USBCoexistenceCodec.u64("18446744073709551615")
    precondition(maximum == UInt64.max)
    for bad: Any in ["01", "-1", "1e2", "18446744073709551616", " 1", NSNumber(value: 1), true] {
        precondition((try? USBCoexistenceCodec.u64(bad)) == nil)
    }
    for bad in ["{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "{\"nested\":{\"a\":1,\"a\":2}}", "{\"pid\":1.0}"] {
        precondition((try? USBCoexistenceCodec.decode(Data(bad.utf8))) == nil)
    }
    let task = try USBCoexistenceTask(wire: ["pid": 100, "start-sec":"1", "start-usec":"999999"])
    precondition(task.pid == 100)
    for bad: Any in [true, 1.5, "100", -1, 2147483648 as Int64] {
        precondition((try? USBCoexistenceTask(wire:["pid":bad,"start-sec":"1","start-usec":"0"])) == nil)
    }
    precondition((try? USBCoexistenceTask(wire:["pid":100,"start-sec":"1","start-usec":"1000000"])) == nil)
    print("PASS strict coexistence wire uint64 duplicate keys task identity")
}
