//
//  MonitorBar — keeps an external monitor's brightness (DDC/CI) in sync with
//  the Mac's built-in display, with controls in the menu bar.
//
//  The built-in display brightness is read/written through Apple's private
//  DisplayServices API (the same one Control Center uses). The external monitor
//  is driven by the m1ddc binary (brew install m1ddc).
//
import AppKit
import CoreGraphics
import IOKit
import IOKit.hid

// MARK: - DisplayServices (Apple private framework)

private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

final class DisplayServices {
    static let shared = DisplayServices()

    private var getFn: GetBrightnessFn?
    private var setFn: SetBrightnessFn?

    var available: Bool { getFn != nil }

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            getFn = unsafeBitCast(sym, to: GetBrightnessFn.self)
        }
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
            setFn = unsafeBitCast(sym, to: SetBrightnessFn.self)
        }
    }

    func brightness(of display: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        guard getFn(display, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    func setBrightness(_ value: Float, of display: CGDirectDisplayID) -> Bool {
        guard let setFn else { return false }
        return setFn(display, value) == 0
    }
}

// MARK: - m1ddc

struct DisplayEntry {
    let index: String
    let name: String
}

final class DDC {
    private let path: String?

    init() {
        path = DDC.locate()
    }

    var available: Bool { path != nil }

    private static func locate() -> String? {
        let fm = FileManager.default
        if let custom = ProcessInfo.processInfo.environment["M1DDC_BIN"], fm.isExecutableFile(atPath: custom) {
            return custom
        }
        for candidate in ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"] where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in searchPath.split(separator: ":") {
            let candidate = String(dir) + "/m1ddc"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    func run(_ arguments: [String]) -> (status: Int32, output: String) {
        guard let path else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func displayList() -> String {
        run(["display", "list"]).output
    }

    /// Parses m1ddc's list: "[2] ARZOPA (7EC3C4DC-...)".
    func displays() -> [DisplayEntry] {
        displayList().split(separator: "\n").compactMap { line in
            guard let open = line.firstIndex(of: "["),
                  let close = line.firstIndex(of: "]") else { return nil }
            let index = String(line[line.index(after: open)..<close])
            var name = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let paren = name.range(of: " (", options: .backwards) {
                name = String(name[..<paren.lowerBound])
            }
            return DisplayEntry(index: index, name: name.isEmpty ? "Display \(index)" : name)
        }
    }

    /// Index of the display whose name contains `name` (or MONITOR_ID, if set).
    func resolveIndex(name: String) -> String? {
        if let forced = ProcessInfo.processInfo.environment["MONITOR_ID"], !forced.isEmpty {
            return forced
        }
        return displays().first { $0.name.lowercased().contains(name.lowercased()) }?.index
    }

    func setLuminance(_ percent: Int, display index: String) -> Bool {
        run(["display", index, "set", "luminance", String(percent)]).status == 0
    }

    func luminance(display index: String) -> Int? {
        let output = run(["display", index, "get", "luminance"]).output
        let digits = output.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }
}

// MARK: - Lid angle sensor
//
// MacBooks have a Hall sensor in the hinge, exposed as HID (usage page 0x20,
// usage 0x8A, feature report 1). The first two bytes, little-endian, are the
// angle in degrees.

final class LidAngle {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?

    var available: Bool { device != nil }

    init() {
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x20,
            kIOHIDDeviceUsageKey as String: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let first = devices.first,
              IOHIDDeviceOpen(first, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return }
        device = first
    }

    func read() -> Int? {
        guard let device else { return nil }
        var buffer = [UInt8](repeating: 0, count: 8)
        var length = 8
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buffer, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        return Int(buffer[1]) | (Int(buffer[2]) << 8)
    }
}

// MARK: - Menu row (label + slider)

final class BrightnessRow: NSObject {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
    let label = NSTextField(labelWithString: "")
    let slider = NSSlider()
    let title: String
    var onChange: ((Int) -> Void)?

    init(title: String, value: Int) {
        self.title = title
        super.init()

        label.frame = NSRect(x: 14, y: 7, width: 110, height: 17)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor

        slider.frame = NSRect(x: 128, y: 5, width: 138, height: 20)
        slider.minValue = 0
        slider.maxValue = 100
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed(_:))

        container.addSubview(label)
        container.addSubview(slider)
        setValue(value)
    }

    @objc private func changed(_ sender: NSSlider) {
        let value = Int(sender.doubleValue.rounded())
        updateLabel(value)
        onChange?(value)
    }

    func setValue(_ value: Int) {
        slider.doubleValue = Double(value)
        updateLabel(value)
    }

    private func updateLabel(_ value: Int) {
        label.stringValue = "\(title) \(value)%"
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let services = DisplayServices.shared
    private let ddc = DDC()
    private let lid = LidAngle()
    private let monitorName = ProcessInfo.processInfo.environment["MONITOR_NAME"] ?? "ARZOPA"
    private let debug = ProcessInfo.processInfo.environment["MONITORBAR_DEBUG"] == "1"
    private let defaults = UserDefaults.standard

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var syncItem: NSMenuItem?
    private var syncNowItem: NSMenuItem?
    private var monitorItem: NSMenuItem?
    private var angleItem: NSMenuItem?
    private var angleBarItem: NSMenuItem?

    private var rows: [BrightnessRow] = []
    private var builtinRow: BrightnessRow?

    private var displayIndex: String?
    private var lastResolve = Date.distantPast
    private var lastApplied: Int?
    private var applying = false
    private var pending: Int?
    private var pendingWork: DispatchWorkItem?
    private var lastAngle: Int?

    private var syncing: Bool {
        get { defaults.bool(forKey: "syncEnabled") }
        set { defaults.set(newValue, forKey: "syncEnabled") }
    }

    private var showAngleInBar: Bool {
        get { defaults.bool(forKey: "showAngleInBar") }
        set { defaults.set(newValue, forKey: "showAngleInBar") }
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["syncEnabled": true, "showAngleInBar": false])
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        rebuildMenu()
        startTimer()
        tick()
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Monitor brightness")
            image?.isTemplate = true
            button.image = image
            button.image?.size = NSSize(width: 18, height: 18)
            button.imagePosition = .imageLeading
            button.toolTip = "MonitorBar"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: menu

    /// Rebuilt on every open: with sync on there is a single slider (the Mac's
    /// brightness, which the external monitor follows); with sync off there is
    /// one slider per connected display.
    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        rows.removeAll()
        builtinRow = nil

        let builtin = services.available ? builtinDisplay() : nil
        let hasBuiltin = builtin != nil
        let builtinValue = builtin
            .flatMap { services.brightness(of: $0) }
            .map { Int(($0 * 100).rounded()) } ?? 0
        let syncActive = syncing && hasBuiltin

        if !services.available {
            let item = NSMenuItem(title: "Mac brightness: API unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if syncActive {
            let row = BrightnessRow(title: "Mac brightness", value: builtinValue)
            row.onChange = { [weak self] value in
                self?.setBuiltinBrightness(value, pushToMonitor: true)
            }
            add(row, to: menu)
            builtinRow = row
        } else {
            if hasBuiltin {
                let row = BrightnessRow(title: "Built-in display", value: builtinValue)
                row.onChange = { [weak self] value in
                    self?.setBuiltinBrightness(value, pushToMonitor: false)
                }
                add(row, to: menu)
                builtinRow = row
            }

            for entry in ddc.displays() {
                // Displays that do not answer a DDC read (the built-in panel, or
                // a monitor without DDC) get no slider.
                guard let value = ddc.luminance(display: entry.index) else { continue }
                let row = BrightnessRow(title: entry.name, value: value)
                row.onChange = { [weak self] value in
                    guard let self else { return }
                    self.lastApplied = value
                    _ = self.ddc.setLuminance(value, display: entry.index)
                    if self.displayIndex == nil { self.displayIndex = entry.index }
                }
                add(row, to: menu)
            }

            if rows.isEmpty {
                let item = NSMenuItem(title: "No controllable displays", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        syncItem = NSMenuItem(title: "Follow Mac brightness", action: #selector(toggleSync), keyEquivalent: "")
        syncItem?.target = self
        syncItem?.state = syncActive ? .on : .off
        syncItem?.isEnabled = hasBuiltin && ddc.available
        if let syncItem { menu.addItem(syncItem) }

        syncNowItem = NSMenuItem(title: "Sync now", action: #selector(syncNow), keyEquivalent: "")
        syncNowItem?.target = self
        syncNowItem?.isEnabled = syncActive
        if let syncNowItem { menu.addItem(syncNowItem) }

        menu.addItem(.separator())

        monitorItem = NSMenuItem(title: "Monitor: —", action: nil, keyEquivalent: "")
        monitorItem?.isEnabled = false
        if let monitorItem { menu.addItem(monitorItem) }
        updateMonitorItem()

        angleItem = NSMenuItem(title: lastAngle.map { "Lid: \($0)°" } ?? "Lid: —", action: nil, keyEquivalent: "")
        angleItem?.isEnabled = false
        if let angleItem { menu.addItem(angleItem) }

        angleBarItem = NSMenuItem(title: "Show angle in menu bar", action: #selector(toggleAngleInBar), keyEquivalent: "")
        angleBarItem?.target = self
        angleBarItem?.state = showAngleInBar ? .on : .off
        if let angleBarItem { menu.addItem(angleBarItem) }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        if debug { NSLog("MonitorBar: menu rebuilt, rows=%d sync=%d", rows.count, syncActive ? 1 : 0) }
    }

    private func add(_ row: BrightnessRow, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = row.container
        menu.addItem(item)
        rows.append(row)
    }

    private func updateMonitorItem() {
        guard let monitorItem else { return }
        if !ddc.available {
            monitorItem.title = "m1ddc not found (brew install m1ddc)"
            return
        }
        if let index = displayIndex ?? resolveDisplayIfNeeded(force: true) {
            monitorItem.title = "Monitor: \(monitorName) (\(index))"
        } else {
            monitorItem.title = "Monitor: not found"
        }
    }

    // MARK: sync loop

    private func tick() {
        updateAngle()

        guard let display = builtinDisplay(), let value = services.brightness(of: display) else {
            return
        }

        let percent = Int((value * 100).rounded())
        builtinRow?.setValue(percent)

        if debug { NSLog("MonitorBar: internal=%d%% lid=%d°", percent, lastAngle ?? -1) }

        guard syncing else { return }
        if let last = lastApplied, abs(last - percent) < 1 { return }
        scheduleApply(percent)
    }

    /// Updates the lid angle (hinge Hall sensor, via HID).
    private func updateAngle() {
        guard let angle = lid.read() else {
            if angleItem?.title != "Lid: sensor unavailable" {
                angleItem?.title = "Lid: sensor unavailable"
            }
            return
        }
        lastAngle = angle
        let text = "Lid: \(angle)°"
        if angleItem?.title != text { angleItem?.title = text }

        guard showAngleInBar else { return }
        if statusItem.button?.title != "\(angle)°" {
            statusItem.button?.title = "\(angle)°"
        }
    }

    /// Waits for the brightness to stop changing before writing to the monitor:
    /// an F1/F2 ramp changes the internal value several times per second, and one
    /// DDC write per step saturates the bus.
    private func scheduleApply(_ percent: Int) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply(percent) }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func apply(_ percent: Int) {
        if applying {
            pending = percent
            return
        }
        guard let index = resolveDisplayIfNeeded() else {
            monitorItem?.title = "Monitor: not found"
            return
        }

        applying = true
        ddc.run(["display", index, "set", "luminance", String(percent)]) { [weak self] status in
            guard let self else { return }
            self.applying = false
            if status == 0 {
                self.lastApplied = percent
                self.monitorItem?.title = "Monitor: \(self.monitorName) (\(index))"
            } else {
                self.displayIndex = nil
                self.lastApplied = nil
            }
            if let next = self.pending, next != percent {
                self.pending = nil
                self.apply(next)
            } else {
                self.pending = nil
            }
        }
    }

    private func resolveDisplayIfNeeded(force: Bool = false) -> String? {
        if let index = displayIndex { return index }
        guard force || Date().timeIntervalSince(lastResolve) > 5 else { return nil }
        lastResolve = Date()
        displayIndex = ddc.resolveIndex(name: monitorName)
        return displayIndex
    }

    private func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: actions

    private func setBuiltinBrightness(_ value: Int, pushToMonitor: Bool) {
        guard let display = builtinDisplay() else { return }
        services.setBrightness(Float(value) / 100, of: display)
        if pushToMonitor {
            apply(value)
        }
    }

    @objc private func toggleSync() {
        guard builtinDisplay() != nil else { return }
        syncing.toggle()
        syncItem?.state = syncing ? .on : .off
        syncNowItem?.isEnabled = syncing
        lastApplied = nil
        if syncing { tick() }
    }

    @objc private func toggleAngleInBar() {
        showAngleInBar.toggle()
        angleBarItem?.state = showAngleInBar ? .on : .off
        if !showAngleInBar { statusItem.button?.title = "" }
        updateAngle()
    }

    @objc private func syncNow() {
        lastApplied = nil
        displayIndex = nil
        lastResolve = .distantPast
        tick()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}

// MARK: - utilities

extension DDC {
    /// Runs in the background and reports the status back on the main queue.
    func run(_ arguments: [String], completion: @escaping (Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = self?.run(arguments).status ?? -1
            DispatchQueue.main.async { completion(status) }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
