import Combine
import OmacVMUSB
import SwiftUI

/// The VM's USB devices (docs/usb.md) in the VM window: a switch, off by
/// default (the VM folder's usb-enabled file). On: the VM gets a USB
/// controller at its start, and while it runs the app asks for each device
/// plugged in (USBSession). Devices… opens the list of remembered devices.
struct USBRow: View {
    @ObservedObject var state: AppState
    @State private var on = false
    @State private var memory = USBMemory()
    @State private var error: String?
    @State private var showDevices = false

    private var folder: URL { state.config.folder }

    static let explanation = "When it’s on and you plug in a device while the VM runs, OmacVM asks whether to connect it to the VM or keep it on the Mac. Your answer counts for that plug-in only, unless you check “Always do this for this device”. Devices… lists the remembered ones, to change or forget. Ordinary USB connects devices macOS doesn’t use: debug probes, SDR sticks, logic analysers, phones in fastboot. Supported vendor HID is offered in the same list only through explicit Connect and administrator approval for this plug and VM run; Always never authorizes it. Keyboards, security keys, USB disks, serial adapters, audio and cameras stay with the Mac and are never asked about."

    var body: some View {
        SettingRow(title: "USB devices", badge: "experimental",
                   subtitle: error ?? (on ? USBListRows.summary(memory: memory) : "Debug probes, SDR sticks and other devices the Mac doesn’t use."),
                   subtitleIsError: error != nil, info: Self.explanation, probe: "usb") {
            if on {
                Button("Devices…") { showDevices = true }
                    .accessibilityLabel("USB devices list")
            }
            RowSwitch(title: "USB devices", isOn: Binding(get: { on }, set: { setOn($0) }))
        }
        .sheet(isPresented: $showDevices, onDismiss: refresh) {
            USBDeviceList(source: .before(folder), vmName: state.config.name) { showDevices = false }
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config.folder) { _, _ in error = nil; refresh() }
        .onChange(of: state.tick) { _, _ in refresh() }
    }

    private func setOn(_ value: Bool) {
        do {
            try USBSwitch.set(value, folder: folder)
            error = nil
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        // Moves a 3.0.1-3.0.3 `usb` file in first (it decides the switch).
        memory = USBMemory.load(folder: folder)
        on = USBSwitch.isOn(folder: folder)
    }
}

/// The remembered devices before the VM starts: usb.json, and the devices
/// plugged in now (USBWatch, live). Changes are saved at once.
@MainActor
final class USBListBefore: ObservableObject {
    let folder: URL
    let vmName: String
    @Published private(set) var rows = USBListRows()
    private var memory = USBMemory()
    private var devices: [UInt32: USBDevice] = [:]
    private let watch = USBWatch()
    private let preview: [USBDevice]?
    @Published var error: String?

    /// preview: these devices instead of the Mac's (the window pictures).
    init(folder: URL, vmName: String, preview: [USBDevice]? = nil) {
        self.folder = folder
        self.vmName = vmName
        self.preview = preview
    }

    func start() {
        memory = USBMemory.load(folder: folder)
        if let preview {
            for d in preview { devices[d.location] = d }
        } else {
            watch.onPlug = { [weak self] d in self?.devices[d.location] = d; self?.refresh() }
            watch.onUnplugExact = { [weak self] loc, registryID in
                guard let self, self.devices[loc]?.registryID == registryID else { return }
                self.devices[loc] = nil; self.refresh()
            }
            watch.start()
        }
        refresh()
    }

    func stop() { watch.stop() }

    func setPlan(_ plan: USBPlan, row: USBListRows.Row) {
        if let key = row.key { memory.set(key: key, plan) } else if let d = row.device { memory.remember(d, plan) }
        save()
    }

    func forget(_ row: USBListRows.Row) {
        guard let key = row.key else { return }
        memory.forget(key: key)
        save()
    }

    private func save() {
        do {
            try memory.save(folder: folder)
            error = nil
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        rows = USBListRows.make(memory: memory, devices: devices.values.sorted { $0.location < $1.location },
                                states: nil, vmName: vmName)
    }
}

/// "USB Devices": the remembered devices (what happens when each is plugged
/// in: Ask Each Time, Connect to Omarchy, Keep on Mac; Forget), the devices
/// plugged in now that a VM can have, and the ones macOS keeps (why). While
/// the VM runs, also Connect and Disconnect, now. A choice here changes only
/// later plug-ins.
struct USBDeviceList: View {
    enum Source {
        case before(URL)
        case running(USBRun)
        /// Fixed rows (the window pictures of the list while a VM runs).
        case picture(USBListRows, running: Bool)
    }

    let vmName: String
    var done: () -> Void
    @StateObject private var before: USBListBefore
    @ObservedObject private var running: USBRunHolder

    init(source: Source, vmName: String, preview: [USBDevice]? = nil, showsTitle: Bool = true, done: @escaping () -> Void) {
        self.vmName = vmName
        self.done = done
        self.showsTitle = showsTitle
        switch source {
        case .before(let folder):
            _before = StateObject(wrappedValue: USBListBefore(folder: folder, vmName: vmName, preview: preview))
            _running = ObservedObject(wrappedValue: USBRunHolder(nil))
        case .running(let run):
            _before = StateObject(wrappedValue: USBListBefore(folder: run.config.folder, vmName: vmName, preview: []))
            _running = ObservedObject(wrappedValue: USBRunHolder(run))
        case .picture(let rows, let isRunning):
            _before = StateObject(wrappedValue: USBListBefore(folder: URL(fileURLWithPath: "/nonexistent"), vmName: vmName, preview: []))
            _running = ObservedObject(wrappedValue: USBRunHolder(nil))
            fixed = rows
            pictureRunning = isRunning
        }
    }

    private var fixed: USBListRows?
    private var pictureRunning = false
    private var rows: USBListRows {
        if let fixed { return fixed }
        if let r = running.run { return r.rows }
        let b: USBListBefore = before
        return b.rows
    }
    private var isRunning: Bool { running.run != nil || pictureRunning }

    /// In the running VM's panel the window has the title already.
    private let showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle { Text("USB Devices").font(.system(size: 15, weight: .semibold)) }
            if (rows.plugged + rows.remembered).contains(where: { $0.device?.captureCandidate == true }) {
                Text("Vendor HID: Connect authorizes this plug and VM run only. Administrator approval installs a native helper; you trust this local app/account. New plugs always require Connect. Keyboards and security devices are refused.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if rows.isEmpty {
                        Card {
                            Text("No devices yet. When \(vmName) runs and you plug in a device it can use, \(Product.name) asks what to do.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                    }
                    if !rows.plugged.isEmpty {
                        SheetHeading(text: "Plugged in now")
                        Card { ForEach(rows.plugged) { row in deviceRow(row) } }
                    }
                    if !rows.remembered.isEmpty {
                        SheetHeading(text: "Remembered")
                        Card { ForEach(rows.remembered) { row in deviceRow(row) } }
                    }
                    if !rows.kept.isEmpty {
                        DisclosureGroup("Kept by macOS (\(rows.kept.count))") {
                            Card {
                                ForEach(rows.kept) { k in
                                    SettingRow(k.name, subtitle: k.why)
                                        .accessibilityElement(children: .combine)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.subheadline)
                        .padding(.leading, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                if let e = before.error {
                    Text(e).font(.subheadline).foregroundStyle(Look.red)
                } else {
                    Text("A choice here counts the next time the device is plugged in.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .background(Look.window)
        .onAppear { if running.run == nil && fixed == nil { before.start() } }
        .onDisappear { before.stop() }
    }

    private func planBinding(_ row: USBListRows.Row) -> Binding<USBPlan> {
        Binding(get: { row.plan }, set: { p in
            if fixed != nil { return }
            if let r = running.run { r.setPlan(p, row: row) } else { before.setPlan(p, row: row) }
        })
    }

    private func forget(_ row: USBListRows.Row) {
        if let r = running.run { r.forget(row) } else { before.forget(row) }
    }

    @ViewBuilder
    private func deviceRow(_ row: USBListRows.Row) -> some View {
        SettingRow(title: row.name, subtitle: [row.detail, row.status].filter { !$0.isEmpty }.joined(separator: " · ")) {
            if row.device?.captureCandidate != true {
            Picker("When “\(row.name)” is plugged in", selection: planBinding(row)) {
                Text("Ask Each Time").tag(USBPlan.ask)
                Text("Connect to \(vmName)").tag(USBPlan.omarchy)
                Text("Keep on Mac").tag(USBPlan.mac)
            }
            .labelsHidden()
            .fixedSize()
            }
            if row.canConnect && isRunning {
                Button("Connect") { running.run?.connect(row) }
                    .accessibilityLabel("Connect \(row.name) to \(vmName)")
            }
            if row.canDisconnect && isRunning {
                Button("Disconnect") { running.run?.disconnect(row) }
                    .accessibilityLabel("Disconnect \(row.name)")
            }
            if row.key != nil {
                Button { forget(row) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Forget this device: asked about again next time")
                    .accessibilityLabel("Forget \(row.name)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name), \(row.detail), \(row.status)")
        .contextMenu {
            if row.key != nil { Button("Forget Device") { forget(row) } }
        }
    }
}

/// The running VM's USB state for the list (nil before a start).
@MainActor
final class USBRunHolder: ObservableObject {
    let run: USBRun?
    private var sub: Any?
    init(_ run: USBRun?) {
        self.run = run
        sub = run?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
