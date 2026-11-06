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
import Darwin
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

// MARK: - DDC bus lock
//
// One DDC transaction at a time per user. The CLI (bin/monitor) uses the same
// directory lock, so the app and a script cannot talk to the monitor at the same
// time — concurrent access is what makes m1ddc crash.

final class DDCLock {
    private static let lockPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/MonitorBar/ddc.lock")

    static func acquire() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        for _ in 0..<80 {
            do {
                try fm.createDirectory(at: lockPath, withIntermediateDirectories: false)
                return true
            } catch {
                usleep(50_000)
            }
        }
        // Probably a leftover lock from a crashed process.
        try? fm.removeItem(at: lockPath)
        return (try? fm.createDirectory(at: lockPath, withIntermediateDirectories: false)) != nil
    }

    static func release() {
        try? FileManager.default.removeItem(at: lockPath)
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
        let locked = DDCLock.acquire()
        defer { if locked { DDCLock.release() } }

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

    /// Retries once: DDC reads occasionally fail right after a write.
    func setLuminance(_ percent: Int, display index: String) -> Bool {
        for attempt in 0..<2 {
            if run(["display", index, "set", "luminance", String(percent)]).status == 0 { return true }
            if attempt == 0 { usleep(100_000) }
        }
        return false
    }

    func luminance(display index: String) -> Int? {
        for attempt in 0..<2 {
            let output = run(["display", index, "get", "luminance"]).output
            let digits = output.filter(\.isNumber)
            if let value = Int(digits) { return value }
            if attempt == 0 { usleep(100_000) }
        }
        return nil
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
    let ddcIndex: String?
    var onChange: ((Int) -> Void)?

    init(title: String, value: Int, ddcIndex: String? = nil) {
        self.title = title
        self.ddcIndex = ddcIndex
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
    private struct DisplayCache {
        var entries: [DisplayEntry] = []
        var values: [String: Int] = [:]
        var fetched = false
    }

    private let services = DisplayServices.shared
    private let ddc = DDC()
    private let lid = LidAngle()
    private let monitorName = ProcessInfo.processInfo.environment["MONITOR_NAME"] ?? "ARZOPA"
    private let debug = ProcessInfo.processInfo.environment["MONITORBAR_DEBUG"] == "1"
    private let defaults = UserDefaults.standard
    private let agentLabel = "com.paulonahes.monitorbar"

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var syncItem: NSMenuItem?
    private var syncNowItem: NSMenuItem?
    private var monitorItem: NSMenuItem?
    private var angleItem: NSMenuItem?
    private var angleBarItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    private var rows: [BrightnessRow] = []
    private var builtinRow: BrightnessRow?
    private var cache = DisplayCache()

    private var displayIndex: String?
    private var lastResolve = Date.distantPast
    private var lastApplied: Int?
    private var applying = false
    private var pending: Int?
    private var pendingWork: DispatchWorkItem?
    private var lastAngle: Int?
    private var lastError: String?
    private var refreshing = false
    private var sleeping = false
    private var applyBackoff = Date.distantPast

    private var loginEnabled = false
    private var loginAvailable = false

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
        observeSystemChanges()
        rebuildMenu()
        refreshLoginState()
        updateTimerState()
        tick()
        refreshDisplays()
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

    private func observeSystemChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemChanged), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }

    // MARK: polling policy

    /// Polls only when there is something live to follow: sync on, or the angle
    /// shown in the menu bar. Otherwise the menu reads the values when it opens.
    private func updateTimerState() {
        let needed = (syncing && builtinDisplay() != nil) || showAngleInBar
        if needed { startTimer() } else { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if ddc.available && !cache.fetched { refreshDisplaysSync() }
        rebuildMenu()
        refreshDisplays()
    }

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

            for entry in cache.entries {
                guard let value = cache.values[entry.index] else { continue }
                let row = BrightnessRow(title: entry.name, value: value, ddcIndex: entry.index)
                row.onChange = { [weak self] value in
                    guard let self else { return }
                    self.lastApplied = value
                    if !self.ddc.setLuminance(value, display: entry.index) {
                        self.setError("DDC write failed at \(self.timestamp())")
                    }
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

        loginItem = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem?.target = self
        loginItem?.state = loginEnabled ? .on : .off
        loginItem?.isEnabled = loginAvailable
        if let loginItem { menu.addItem(loginItem) }

        if let lastError {
            let item = NSMenuItem(title: "Last error: \(lastError)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        updateAngle()
        if debug {
            NSLog("MonitorBar: menu rebuilt, rows=%d sync=%d", rows.count, syncActive ? 1 : 0)
        }
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
        if let index = displayIndex {
            monitorItem.title = "Monitor: \(monitorName) (\(index))"
        } else {
            monitorItem.title = "Monitor: not found"
        }
    }

    // MARK: display cache (keeps the menu snappy)

    private func refreshDisplaysSync() {
        guard ddc.available else { return }
        let entries = ddc.displays()
        var values: [String: Int] = [:]
        for entry in entries {
            if let value = ddc.luminance(display: entry.index) { values[entry.index] = value }
        }
        cache = DisplayCache(entries: entries, values: values, fetched: true)
        adoptDisplayIndex(from: entries)
    }

    private func refreshDisplays() {
        guard ddc.available, !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let entries = self.ddc.displays()
            var values: [String: Int] = [:]
            for entry in entries {
                if let value = self.ddc.luminance(display: entry.index) { values[entry.index] = value }
            }
            DispatchQueue.main.async {
                self.refreshing = false
                self.cache = DisplayCache(entries: entries, values: values, fetched: true)
                self.adoptDisplayIndex(from: entries)
                self.applyCacheToMenu()
            }
        }
    }

    private func adoptDisplayIndex(from entries: [DisplayEntry]) {
        if let match = entries.first(where: { $0.name.lowercased().contains(monitorName.lowercased()) }) {
            displayIndex = match.index
        }
        updateMonitorItem()
    }

    private func applyCacheToMenu() {
        for row in rows {
            guard let index = row.ddcIndex, let value = cache.values[index] else { continue }
            row.setValue(value)
        }
    }

    // MARK: sync loop

    private func tick() {
        guard !sleeping else { return }
        updateAngle()

        guard let display = builtinDisplay(), let value = services.brightness(of: display) else {
            return
        }

        let percent = Int((value * 100).rounded())
        builtinRow?.setValue(percent)

        if debug { NSLog("MonitorBar: internal=%d%% lid=%d°", percent, lastAngle ?? -1) }

        guard syncing else { return }
        if let last = lastApplied, abs(last - percent) < 1 { return }
        guard Date() >= applyBackoff else { return }
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
        guard !sleeping else { return }
        if applying {
            pending = percent
            return
        }
        guard let index = resolveDisplayIfNeeded() else {
            // Back off: the display may be unplugged or asleep. Hot-plug, wake
            // and "Sync now" reset this immediately.
            applyBackoff = Date().addingTimeInterval(10)
            setError("monitor not found at \(timestamp())")
            monitorItem?.title = "Monitor: not found"
            return
        }

        applying = true
        ddc.run(["display", index, "set", "luminance", String(percent)]) { [weak self] status in
            guard let self else { return }
            self.applying = false
            if status == 0 {
                self.lastApplied = percent
                self.lastError = nil
                self.applyBackoff = .distantPast
                self.monitorItem?.title = "Monitor: \(self.monitorName) (\(index))"
            } else {
                self.displayIndex = nil
                self.lastApplied = nil
                self.setError("DDC write failed at \(self.timestamp())")
            }
            if let next = self.pending, next != percent {
                self.pending = nil
                self.apply(next)
            } else {
                self.pending = nil
            }
        }
    }

    private func resolveDisplayIfNeeded() -> String? {
        if let index = displayIndex { return index }
        guard Date().timeIntervalSince(lastResolve) > 5 else { return nil }
        lastResolve = Date()
        if let match = cache.entries.first(where: { $0.name.lowercased().contains(monitorName.lowercased()) }) {
            displayIndex = match.index
            return displayIndex
        }
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
        updateTimerState()
        if syncing { tick() }
    }

    @objc private func toggleAngleInBar() {
        showAngleInBar.toggle()
        angleBarItem?.state = showAngleInBar ? .on : .off
        if !showAngleInBar { statusItem.button?.title = "" }
        updateAngle()
        updateTimerState()
    }

    @objc private func toggleLogin() {
        guard loginAvailable else { return }
        loginEnabled.toggle()
        loginItem?.state = loginEnabled ? .on : .off
        _ = runTool("/bin/launchctl", [loginEnabled ? "enable" : "disable", "gui/\(getuid())/\(agentLabel)"])
    }

    @objc private func syncNow() {
        lastApplied = nil
        displayIndex = nil
        lastResolve = .distantPast
        applyBackoff = .distantPast
        tick()
    }

    @objc private func systemWillSleep() {
        sleeping = true
    }

    @objc private func systemChanged() {
        sleeping = false
        displayIndex = nil
        lastResolve = .distantPast
        lastApplied = nil
        applyBackoff = .distantPast
        cache = DisplayCache()
        updateTimerState()
        tick()
        refreshDisplays()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: login item

    private var agentPlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
    }

    private func refreshLoginState() {
        loginAvailable = FileManager.default.fileExists(atPath: agentPlistPath)
        guard loginAvailable else {
            loginEnabled = false
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let output = self.runTool("/bin/launchctl", ["print-disabled", "gui/\(getuid())"]) ?? ""
            var enabled = true
            for line in output.split(separator: "\n") where line.contains(self.agentLabel) {
                enabled = !line.contains("=> disabled")
            }
            DispatchQueue.main.async {
                self.loginEnabled = enabled
                self.loginItem?.state = enabled ? .on : .off
                self.loginItem?.isEnabled = true
            }
        }
    }

    private func runTool(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: helpers

    private func setError(_ message: String) {
        if lastError != message { NSLog("MonitorBar: %@", message) }
        lastError = message
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
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
