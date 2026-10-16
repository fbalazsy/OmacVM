import Foundation
@main struct LiveControlTests {
    static func main() throws {
        let detach = try LiveControl.parse(Data("{\"command\":\"detach\"}".utf8))
        let retry = try LiveControl.parse(Data("retry".utf8))
        let attach = try LiveControl.parse(Data("{\"command\":\"attach\",\"target-file\":\"/a\",\"descriptor-file\":\"/b\"}".utf8))
        precondition(detach == .detach && retry == .retry && attach == .attach("/a","/b"))
        for input in ["{\"command\":\"detach\",\"command\":\"status\"}", "{\"command\":\"kill\"}", "{\"command\":\"retry\",\"extra\":1}", "{\"command\":\"attach\",\"target-file\":\"relative\",\"descriptor-file\":\"/b\"}", String(repeating:"x",count:4097)] {
            do { _ = try LiveControl.parse(Data(input.utf8)); preconditionFailure("accepted invalid control") } catch {}
        }
        let dir = URL(fileURLWithPath:ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("live-file-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:dir) }
        let file = dir.appendingPathComponent("regular")
        try Data(repeating:1,count:65536).write(to:file)
        let bounded = try LiveControl.readFile(file.path)
        precondition(bounded.count == 65536)
        try Data(repeating:1,count:65537).write(to:file)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        let fifo = dir.appendingPathComponent("fifo")
        precondition(mkfifo(fifo.path,0o600) == 0)
        for path in [file.path,dir.path,link.path,fifo.path] {
            do { _ = try LiveControl.readFile(path); preconditionFailure("accepted oversized or non-regular input") } catch {}
        }
        print("PASS bounded nonblocking regular input files: exact cap, oversized, directory, symlink, FIFO")
        print("PASS bounded live control parser: repeated attachment commands, no exit/kill, strict fields")
    }
}
