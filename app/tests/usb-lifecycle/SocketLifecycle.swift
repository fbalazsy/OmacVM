import Foundation
import Combine
import OmacVMUSB
@main struct AdvancedComposition {
 @MainActor static func main() async throws {
  let path=CommandLine.arguments[1],mode=CommandLine.arguments[2]
  let folder=URL(fileURLWithPath:CommandLine.arguments[3]);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  if mode.hasPrefix("ordinary-") { try await ordinary(path: path, mode: mode, folder: folder); return }
  if mode.hasPrefix("late-") { try await late(path: path, mode: mode, folder: folder); return }
  if mode.hasPrefix("identity-") { try await identity(path: path, mode: mode, folder: folder); return }
  let raw = mode.hasPrefix("rawUnicode") ? "\u{e9}" : " A\nB "
  let secondRaw = mode.hasSuffix("Same") ? raw : mode.hasPrefix("rawUnicode") ? "e\u{301}" : "AB"
  let first=USBScan.device(fixture(raw))!,second=USBScan.device(fixture(secondRaw,generation:102))!
  let before=USBListBefore(folder:folder,vmName:"Omarchy",preview:[first]);before.start();before.setPlan(.omarchy,row:before.rows.plugged[0])
  if mode == "rawCollision" || mode == "rawUnicodeDifferent" {
   let other=USBListBefore(folder:folder,vmName:"Omarchy",preview:[second]);other.start();other.setPlan(.mac,row:other.rows.plugged[0]);other.stop()
  }
  let memory=USBMemory.load(folder:folder),clock=EdgeMachine(),machine=USBQMPMachine(socketPath:path)
  let s=USBSession(vmName:"Omarchy",memory:memory,machine:machine,asker:clock,clock:clock,save:{try! $0.save(folder:folder)},log:{_ in})
  func wait(_ test:()->Bool) async {
   for _ in 0..<800 {if test(){return};try? await Task.sleep(nanoseconds:25_000_000)}
   fatalError("deadline \(mode) \(s.plugs)")
  }
  if mode.hasPrefix("watch") {
   var reads=USBWatch.Reads(), earlyTree=fixture(" A\nB ")
   earlyTree.children=[]
   let early=USBScan.device(earlyTree)!
   let parent=reads.begin(3101),publication=reads.begin(3101,publication:true)
   s.inFront=false
   func parentDone() { if reads.finish(3101,ticket:parent,location:first.location,hid:false) { s.plugged(early) } }
   func hidDone() { if reads.finish(3101,ticket:publication,location:first.location,hid:true,publication:true) { s.plugged(first) } }
   if mode == "watchParentFirst" { parentDone();hidDone() } else { hidDone();parentDone() }
   s.inFront=true
  } else { s.plugged(first) }
  await wait {s.plugs[first.location]?.state != .connecting}
  if mode.hasPrefix("raw") {
   precondition(s.plugs[first.location]?.state == .connected)
   s.unplugged(location:first.location);s.plugged(second);clock.fire()
   await wait {s.plugs[first.location]?.state == .connected || s.plugs[first.location]?.state == .onMac(remembered:true)}
  } else if !mode.hasPrefix("rollback") && !mode.hasPrefix("watch") {
   precondition(s.plugs[first.location]?.state == .connected)
   s.disconnectNow(location:first.location)
   await wait {s.plugs[first.location]?.state != .disconnecting}
  }
  if mode.hasSuffix("Retry") {
   precondition(s.plugs[first.location]?.state == .releaseFailed)
   precondition(s.rows.remembered.first{$0.device != nil}!.canDisconnect)
   s.connectNow(location:first.location) // Must not send another add while cleanup is unresolved.
   s.disconnectNow(location:first.location)
   await wait {s.plugs[first.location]?.state != .disconnecting}
  }
  let row=(s.rows.remembered+s.rows.plugged).first{$0.device != nil}!
  let record:[String:Any]=["mode":mode,"state":"\(s.plugs[first.location]!.state)","canConnect":row.canConnect,"canDisconnect":row.canDisconnect,"secondMemoryPlan":memory.plan(for:second).rawValue,"questions":clock.questions,"currentRaw":s.plugs[first.location]!.device.hid?.serial ?? "ordinary"]
  try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("observed.json"))
  print(String(data:try JSONSerialization.data(withJSONObject:record),encoding:.utf8)!)
  before.stop();s.stop()
 }

 @MainActor static func ordinary(path: String, mode: String, folder: URL) async throws {
  let parts = mode.split(separator: "-").map(String.init), a = USBScan.device(fixture("hid-A"))!
  let plan = USBPlan(rawValue: parts[2])!, order = parts[3], retry = parts[4] == "retry"
  var tree = fixture("ordinary-B", generation: 102)
  if parts[1] == "different" { tree.properties["idVendor"] = 0x0483; tree.properties["idProduct"] = 0x3748 }
  tree.properties["USB Address"] = 8; tree.children[0].properties["bInterfaceClass"] = 255; tree.children[0].children = []
  let b = USBScan.device(tree)!
  var memory = USBMemory(); memory.remember(a, .omarchy); memory.remember(b, plan); try memory.save(folder: folder)
  let clock = EdgeMachine(), machine = USBQMPMachine(socketPath: path)
  let s = USBSession(vmName: "Fixture", memory: USBMemory.load(folder: folder), machine: machine, asker: clock, clock: clock, save: { try! $0.save(folder: folder) }, log: { _ in })
  var reads = USBWatch.Reads(), delivery: [String] = []
  func publish(_ d: USBDevice, _ entry: UInt64) {
   let t = reads.begin(entry), ok = reads.finish(entry, ticket: t, location: d.location, hid: d.hid != nil)
   delivery.append("publish:\(entry):\(ok)"); if ok { s.plugged(d) }
  }
  func remove() { let loc = reads.remove(3101); delivery.append("remove:\(loc != nil)"); if let loc { s.unplugged(location: loc) } }
  func wait(_ test: () -> Bool) async {
   for _ in 0..<800 { if test() { return }; try? await Task.sleep(nanoseconds: 25_000_000) }
   fatalError("deadline \(mode) \(s.plugs)")
  }
  publish(a, 3101); await wait { s.plugs[a.location]?.state == .connected }
  if order != "publish" { remove() }
  if order != "released" { publish(b, 3102) }
  if order == "publish" { remove() }
  clock.fire()
  await wait { ![USBSession.State.connecting, .disconnecting, .leaving].contains(s.plugs[a.location]?.state ?? .waiting) }
  var blocked = true
  if retry {
   blocked = s.plugs[a.location]?.state == .releaseFailed && s.plugs[a.location]?.device == a
   s.connectNow(location: a.location); s.disconnectNow(location: a.location)
   await wait { s.plugs[a.location]?.state != .disconnecting && s.plugs[a.location]?.state != .connecting }
  }
  if order == "released" { publish(b, 3102); await wait { s.plugs[b.location]?.state != .connecting } }
  let routed = "\(s.plugs[b.location]?.state ?? .waiting)"
  if plan == .ask { clock.answer?(.init(connect: true, always: false)) }
  if plan == .mac { s.connectNow(location: b.location) }
  await wait { s.plugs[b.location]?.state != .connecting }
  var drained = false; machine.isAttached(b) { _ in drained = true }; await wait { drained }
  let record: [String: Any] = ["state": "\(s.plugs[b.location]?.state ?? .waiting)", "routed": routed, "questions": clock.questions,
    "blockedUntilRelease": blocked, "delivery": delivery, "currentOrdinary": s.plugs[b.location]?.device == b,
    "storedPlan": USBMemory.load(folder: folder).plan(for: b).rawValue]
  try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("observed.json")); s.stop()
 }

 @MainActor static func identity(path: String, mode: String, folder: URL) async throws {
  let parts = mode.split(separator: "-").map(String.init)
  let kind = parts[1], keep = parts[2] == "keep", gap = parts[3], removeFirst = parts[4] == "remove"
  let raw = kind == "ascii" ? "serial-A" : "\u{e9}"
  let a = USBScan.device(fixture(raw))!
  var tree = fixture(kind == "ascii" ? "serial-B" : kind == "unicode" ? "e\u{301}" : raw, generation: 102)
  if kind == "product" { tree.properties["idProduct"] = 8; tree.children[0].children[0].properties["ProductID"] = 8 }
  let b = USBScan.device(tree)!
  var memory = USBMemory(); memory.remember(a, keep ? .ask : .mac)
  if kind != "same" { memory.remember(b, .omarchy) }
  try memory.save(folder: folder)
  let clock = EdgeMachine(), machine = USBQMPMachine(socketPath: path)
  let s = USBSession(vmName: "Fixture", memory: USBMemory.load(folder: folder), machine: machine, asker: clock, clock: clock,
                     save: { try! $0.save(folder: folder) }, log: { _ in })
  s.inFront = keep
  var reads = USBWatch.Reads(), delivery: [String] = []
  func publish(_ d: USBDevice, _ parent: UInt64) {
   let ticket = reads.begin(parent), ok = reads.finish(parent, ticket: ticket, location: d.location, hid: true)
   delivery.append("publish:\(parent):\(ok)"); if ok { s.plugged(d) }
  }
  func remove() { let loc = reads.remove(3101); delivery.append("remove:\(loc != nil)"); if let loc { s.unplugged(location: loc) } }
  publish(a, 3101)
  if keep { precondition(clock.answer != nil); clock.answer?(.init(connect: false, always: false)); s.inFront = false }
  if gap != "none" {
   var incomplete = fixture(raw)
   if gap == "incomplete" { incomplete.children[0].children = [] }
   else { incomplete.children[0].children[0].properties["ReportDescriptor"] = Data([0x05, 1, 0x09, 6, 0xa1, 1, 0xc0]) }
   publish(USBScan.device(incomplete)!, 3101)
  }
  if removeFirst { remove(); publish(b, 3102) } else { publish(b, 3102); remove() }
  for _ in 0..<800 { if s.plugs[a.location]?.state != .connecting { break }; try? await Task.sleep(nanoseconds: 25_000_000) }
  var drained = false; machine.isAttached(b) { _ in drained = true }
  for _ in 0..<800 { if drained { break }; try? await Task.sleep(nanoseconds: 25_000_000) }; precondition(drained)
  let row = (s.rows.remembered + s.rows.plugged).first { $0.device?.location == b.location }!
  let record: [String: Any] = ["state": "\(s.plugs[a.location]!.state)", "questions": clock.questions, "plan": row.plan.rawValue,
                              "currentUTF8": Array(s.plugs[a.location]!.device.hid!.serial.utf8), "delivery": delivery,
                              "storedPlan": USBMemory.load(folder: folder).plan(for: b).rawValue]
  try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("observed.json")); s.stop()
 }

 @MainActor static func late(path: String, mode: String, folder: URL) async throws {
  let parts = mode.split(separator: "-").map(String.init)
  let parentPlan = USBPlan(rawValue: parts[1])!, targetPlan = USBPlan(rawValue: parts[2])!
  let hidFirst = parts[3] == "hid", action = parts[4]
  let target = USBScan.device(fixture("\u{e9}"))!
  var tree = fixture("\u{e9}"); tree.children = []
  let parent = USBScan.device(tree)!
  var pending = fixture("\u{e9}"); pending.children[0].children = []
  let incomplete = USBScan.device(pending)!
  var memory = USBMemory(); memory.remember(parent, parentPlan); memory.remember(target, targetPlan)
  try memory.save(folder: folder)
  let clock = EdgeMachine(), machine = USBQMPMachine(socketPath: path)
  let s = USBSession(vmName: "Fixture", memory: USBMemory.load(folder: folder), machine: machine, asker: clock, clock: clock,
                     save: { try! $0.save(folder: folder) }, log: { _ in })
  s.inFront = action == "keep" || action == "always"
  func wait(_ test: () -> Bool) async {
   for _ in 0..<800 { if test() { return }; try? await Task.sleep(nanoseconds: 25_000_000) }
   fatalError("deadline \(mode) \(s.plugs)")
  }
  var reads = USBWatch.Reads(); let p = reads.begin(3101), h = reads.begin(3101, publication: true)
  func parentDone() { if reads.finish(3101, ticket: p, location: target.location, hid: false) { s.plugged(parent) } }
  func hidDone() { if reads.finish(3101, ticket: h, location: target.location, hid: true, publication: true) { s.plugged(target) } }
  if hidFirst { hidDone() } else { parentDone() }
  await wait { s.plugs[target.location]?.state != .connecting }
  switch action {
  case "keep", "always": clock.answer?(USBAnswer(connect: false, always: action == "always"))
  case "disconnect": s.disconnectNow(location: target.location)
  case "connect", "connectFailed": s.connectNow(location: target.location)
  case "future": s.setPlan(.omarchy, for: parent)
  default: break
  }
  await wait { s.plugs[target.location]?.state != .connecting }
  if hidFirst { parentDone() } else { hidDone() }
  clock.fire()
  await wait { ![USBSession.State.connecting, .disconnecting, .leaving].contains(s.plugs[target.location]!.state) }
  if ["keep", "always", "disconnect", "connectFailed"].contains(action) {
   s.setPlan(.omarchy, for: target)
   for _ in 0..<2 { s.plugged(incomplete); s.connectNow(location: target.location); s.plugged(target) }
  }
  var drained = false; machine.isAttached(target) { _ in drained = true }; await wait { drained }
  let loaded = USBMemory.load(folder: folder)
  let record: [String: Any] = ["state": "\(s.plugs[target.location]!.state)", "questions": clock.questions,
                             "parentPlan": loaded.plan(for: parent).rawValue, "targetPlan": loaded.plan(for: target).rawValue,
                             "storedCount": loaded.devices.count, "currentRaw": s.plugs[target.location]!.device.hid?.serial ?? "ordinary"]
  try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("observed.json"))
  s.stop()
 }
}

import Foundation
import CoreFoundation
import OmacVMUSB

func fixture(_ serial: String = "fixture-01", generation: UInt64 = 101) -> USBScan.Entry {
    let metadata: [String: Any] = ["PrimaryUsagePage": 65280, "PrimaryUsage": 1, "DeviceUsagePairs": [["DeviceUsagePage": 65280, "DeviceUsage": 1]]]
    var props = metadata
    props.merge(["VendorID": 0x1209, "ProductID": 7, "SerialNumber": serial, "Product": "Fixture", "Transport": "USB", "ReportDescriptor": Data([0x06,0,0xff,0x09,1,0xa1,1,0x75,8,0x95,60,0x81,2,0x91,2,0xc0])]) { _, b in b }
    let leaf = USBScan.Entry(registryID: generation + 1000, className: "IOHIDInterface", properties: metadata)
    let hid = USBScan.Entry(registryID: generation, className: "AppleUserHIDDevice", conforms: ["IOHIDDevice"], properties: props, children: [leaf])
    let iface = USBScan.Entry(registryID: generation + 2000, className: "IOUSBHostInterface", properties: ["bInterfaceClass":3,"bInterfaceSubClass":0,"bInterfaceProtocol":0], children: [hid])
    return USBScan.Entry(registryID: generation + 3000, className: "IOUSBHostDevice", properties: ["idVendor":0x1209,"idProduct":7,"USB Serial Number":serial,"locationID":0x01100000,"USB Address":5], children: [iface])
}

final class EdgeMachine: USBMachine, USBAsker, USBClock {
    var added: [USBDevice] = [], removed: [USBDevice] = [], questions = 0
    var answer: ((USBAnswer) -> Void)?
    var tasks: [() -> Void] = []
    func attach(_ d: USBDevice, done: @escaping (USBAttachResult) -> Void) { added.append(d); done(.attached) }
    func detach(_ d: USBDevice, done: @escaping (Bool) -> Void) { removed.append(d); done(true) }
    func isAttached(_ d: USBDevice, done: @escaping (Bool) -> Void) { done(false) }
    func ask(_ q: USBQuestion, answer: @escaping (USBAnswer) -> Void) { questions += 1; self.answer = answer }
    func cancel() { answer = nil }
    func notice(title: String, text: String) {}
    func after(_ seconds: Double, _ run: @escaping () -> Void) { tasks.append(run) }
    func fire() { let pending=tasks; tasks=[]; pending.forEach { $0() } }
}
