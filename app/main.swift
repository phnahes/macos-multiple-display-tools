//
//  MonitorBar — mantém o brilho de um monitor externo (DDC/CI) em sincronia
//  com o brilho do display integrado do Mac, com controle na barra de menu.
//
//  O brilho do display interno é lido/escrito pela API privada DisplayServices
//  (a mesma que o Control Center usa). O monitor externo é controlado pelo
//  binário m1ddc (brew install m1ddc).
//
import AppKit
import CoreGraphics
import IOKit
import IOKit.hid

// MARK: - DisplayServices (framework privado da Apple)

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

    /// Índice do display cujo nome contém `name` (ou MONITOR_ID, se definido).
    func resolveIndex(name: String) -> String? {
        if let forced = ProcessInfo.processInfo.environment["MONITOR_ID"], !forced.isEmpty {
            return forced
        }
        for line in displayList().split(separator: "\n") {
            guard line.lowercased().contains(name.lowercased()),
                  let open = line.firstIndex(of: "["),
                  let close = line.firstIndex(of: "]") else { continue }
            return String(line[line.index(after: open)..<close])
        }
        return nil
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

// MARK: - Sensor de ângulo da tampa
//
// O MacBook tem um sensor Hall no hinge, exposto como HID (usage page 0x20,
// usage 0x8A, report feature 1). Os dois primeiros bytes, little-endian, são
// o ângulo em graus.

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
    private var syncItem: NSMenuItem!
    private var monitorItem: NSMenuItem!
    private var internalItem: NSMenuItem!
    private var angleItem: NSMenuItem!
    private var angleBarItem: NSMenuItem!
    private var slider: NSSlider!
    private var lastAngle: Int?

    private var displayIndex: String?
    private var lastResolve = Date.distantPast
    private var lastApplied: Int?
    private var applying = false
    private var pending: Int?
    private var pendingWork: DispatchWorkItem?

    private var syncing: Bool {
        get { defaults.bool(forKey: "syncEnabled") }
        set { defaults.set(newValue, forKey: "syncEnabled") }
    }

    private var showAngleInBar: Bool {
        get { defaults.bool(forKey: "showAngleInBar") }
        set { defaults.set(newValue, forKey: "showAngleInBar") }
    }

    // MARK: ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["syncEnabled": true, "showAngleInBar": false])
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        startTimer()
        tick()
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brilho do monitor")
            image?.isTemplate = true
            button.image = image
            button.image?.size = NSSize(width: 18, height: 18)
            button.imagePosition = .imageLeading
            button.toolTip = "MonitorBar"
        }

        let menu = NSMenu()
        menu.delegate = self

        internalItem = NSMenuItem(title: "Brilho do Mac: —", action: nil, keyEquivalent: "")
        internalItem.isEnabled = false
        menu.addItem(internalItem)

        let sliderItem = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 14, y: 6, width: 192, height: 20)
        slider.controlSize = .small
        container.addSubview(slider)
        sliderItem.view = container
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        syncItem = NSMenuItem(title: "Seguir o brilho do Mac", action: #selector(toggleSync), keyEquivalent: "")
        syncItem.target = self
        syncItem.state = syncing ? .on : .off
        menu.addItem(syncItem)

        let syncNow = NSMenuItem(title: "Sincronizar agora", action: #selector(syncNow), keyEquivalent: "")
        syncNow.target = self
        menu.addItem(syncNow)

        menu.addItem(.separator())

        monitorItem = NSMenuItem(title: "Monitor: —", action: nil, keyEquivalent: "")
        monitorItem.isEnabled = false
        menu.addItem(monitorItem)

        angleItem = NSMenuItem(title: "Tampa: —", action: nil, keyEquivalent: "")
        angleItem.isEnabled = false
        menu.addItem(angleItem)

        angleBarItem = NSMenuItem(title: "Mostrar ângulo na barra", action: #selector(toggleAngleInBar), keyEquivalent: "")
        angleBarItem.target = self
        angleBarItem.state = showAngleInBar ? .on : .off
        menu.addItem(angleBarItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Sair", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: laço de sincronização

    private func tick() {
        updateAngle()

        guard let display = builtinDisplay(), let value = services.brightness(of: display) else {
            internalItem.title = "Brilho do Mac: indisponível"
            return
        }

        let percent = Int((value * 100).rounded())
        internalItem.title = "Brilho do Mac: \(percent)%"
        if syncing { slider.doubleValue = Double(percent) }

        if debug { NSLog("MonitorBar: interno=%d%% tampa=%d°", percent, lastAngle ?? -1) }

        guard syncing else { return }
        if let last = lastApplied, abs(last - percent) < 1 { return }
        scheduleApply(percent)
    }

    /// Atualiza o ângulo da tampa (sensor Hall do hinge, via HID).
    private func updateAngle() {
        guard let angle = lid.read() else {
            if angleItem.title != "Tampa: sensor indisponível" {
                angleItem.title = "Tampa: sensor indisponível"
            }
            return
        }
        lastAngle = angle
        let text = "Tampa: \(angle)°"
        if angleItem.title != text { angleItem.title = text }

        guard showAngleInBar else { return }
        if statusItem.button?.title != "\(angle)°" {
            statusItem.button?.title = "\(angle)°"
        }
    }

    /// Espera o brilho parar de mudar antes de escrever no monitor: durante um
    /// ajuste com F1/F2 o valor interno muda várias vezes por segundo, e um
    /// write DDC por passo satura o barramento.
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
            monitorItem.title = "Monitor: não encontrado"
            return
        }

        applying = true
        ddc.run(["display", index, "set", "luminance", String(percent)]) { [weak self] status in
            guard let self else { return }
            self.applying = false
            if status == 0 {
                self.lastApplied = percent
                self.monitorItem.title = "Monitor: \(self.monitorName) (\(index))"
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

    private func resolveDisplayIfNeeded() -> String? {
        if let index = displayIndex { return index }
        guard Date().timeIntervalSince(lastResolve) > 5 else { return nil }
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

    // MARK: ações

    @objc private func sliderChanged(_ sender: NSSlider) {
        let percent = Int(sender.doubleValue.rounded())
        if syncing, let display = builtinDisplay() {
            services.setBrightness(Float(percent) / 100, of: display)
            lastApplied = nil
            apply(percent)
        } else if let index = resolveDisplayIfNeeded() {
            lastApplied = percent
            _ = ddc.setLuminance(percent, display: index)
        }
    }

    @objc private func toggleSync() {
        syncing.toggle()
        syncItem.state = syncing ? .on : .off
        if syncing {
            lastApplied = nil
            tick()
        }
    }

    @objc private func toggleAngleInBar() {
        showAngleInBar.toggle()
        angleBarItem.state = showAngleInBar ? .on : .off
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

    func menuWillOpen(_ menu: NSMenu) {
        if !syncing, let index = resolveDisplayIfNeeded(), let value = ddc.luminance(display: index) {
            slider.doubleValue = Double(value)
        }
        monitorItem.title = displayIndex.map { "Monitor: \(monitorName) (\($0))" } ?? "Monitor: não encontrado"
        if !services.available {
            internalItem.title = "Brilho do Mac: API indisponível"
        }
        if !ddc.available {
            monitorItem.title = "m1ddc não encontrado (brew install m1ddc)"
            syncItem.isEnabled = false
        }
    }
}

// MARK: - utilitário

extension DDC {
    /// Executa em background e devolve o status na main queue.
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
