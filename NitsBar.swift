import AppKit
import Darwin
import Foundation
import ServiceManagement

private let displayServicesFrameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
private let totalBrightnessSteps = 32
private let controlPortName = "com.nickmauro.NitsBar.control"
private let decreaseBrightnessMessageID: Int32 = 1
private let increaseBrightnessMessageID: Int32 = 2

private struct BrightnessState {
    let stepIndex: Int
    let normalizedValue: Double
}

private final class DisplayBrightnessController {
    private typealias GetBrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var getBrightness: GetBrightnessFunction?
    private var setBrightness: SetBrightnessFunction?
    private var displayIDs: [CGDirectDisplayID] = []
    private(set) var lastFailure = "none"

    var isAvailable: Bool { getBrightness != nil && setBrightness != nil }

    init() {
        frameworkHandle = dlopen(displayServicesFrameworkPath, RTLD_NOW)
        if let frameworkHandle,
           let getSymbol = dlsym(frameworkHandle, "DisplayServicesGetBrightness"),
           let setSymbol = dlsym(frameworkHandle, "DisplayServicesSetBrightness") {
            getBrightness = unsafeBitCast(getSymbol, to: GetBrightnessFunction.self)
            setBrightness = unsafeBitCast(setSymbol, to: SetBrightnessFunction.self)
        }
        refreshDisplays()
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    func currentMainState() -> BrightnessState? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(CGMainDisplayID(), &value) == 0, value.isFinite else { return nil }
        return state(for: value)
    }

    @discardableResult
    func adjustAllDisplays(bySteps stepDelta: Int) -> BrightnessState? {
        guard stepDelta != 0,
              let getBrightness,
              let setBrightness else {
            lastFailure = "DisplayServices brightness functions are unavailable"
            return nil
        }

        let mainDisplayID = CGMainDisplayID()
        var mainState: BrightnessState?
        var firstState: BrightnessState?
        var failures: [String] = []

        for displayID in activeDisplayIDs() {
            var currentValue: Float = 0
            let getResult = getBrightness(displayID, &currentValue)
            guard getResult == 0, currentValue.isFinite else {
                failures.append("display \(displayID) read returned \(getResult)")
                continue
            }

            let currentStep = state(for: currentValue).stepIndex
            let targetStep = min(max(currentStep + stepDelta, 0), totalBrightnessSteps)
            let targetValue = Float(targetStep) / Float(totalBrightnessSteps)
            let setResult = setBrightness(displayID, targetValue)
            guard setResult == 0 else {
                failures.append("display \(displayID) write returned \(setResult)")
                continue
            }

            let targetState = BrightnessState(stepIndex: targetStep, normalizedValue: Double(targetValue))
            if displayID == mainDisplayID { mainState = targetState }
            if firstState == nil { firstState = targetState }
        }

        if mainState == nil, firstState == nil {
            lastFailure = failures.isEmpty ? "no active display accepted brightness control" : failures.joined(separator: "; ")
        } else {
            lastFailure = "none"
        }
        return mainState ?? firstState
    }

    @discardableResult
    func setAllDisplays(toStep requestedStep: Int) -> BrightnessState? {
        guard let setBrightness else { return nil }

        let targetStep = min(max(requestedStep, 0), totalBrightnessSteps)
        let targetValue = Float(targetStep) / Float(totalBrightnessSteps)
        let targetState = BrightnessState(stepIndex: targetStep, normalizedValue: Double(targetValue))
        let mainDisplayID = CGMainDisplayID()
        var mainState: BrightnessState?
        var firstState: BrightnessState?

        for displayID in activeDisplayIDs() {
            guard setBrightness(displayID, targetValue) == 0 else { continue }
            if displayID == mainDisplayID { mainState = targetState }
            if firstState == nil { firstState = targetState }
        }

        return mainState ?? firstState
    }

    func diagnosticLine() -> String {
        guard let state = currentMainState() else { return "unavailable" }
        let displayName = NSScreen.main?.localizedName ?? NSScreen.screens.first?.localizedName ?? "Display"
        return String(
            format: "step=%d/%d brightness=%.6f display=%@",
            state.stepIndex,
            totalBrightnessSteps,
            state.normalizedValue,
            displayName
        )
    }

    func refreshDisplays() {
        var seen = Set<CGDirectDisplayID>()
        displayIDs = NSScreen.screens.compactMap { screen in
            guard let displayID = (
                screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            )?.uint32Value,
                seen.insert(displayID).inserted else { return nil }
            return displayID
        }
        if displayIDs.isEmpty {
            displayIDs = [CGMainDisplayID()]
        }
    }

    private func state(for brightness: Float) -> BrightnessState {
        let normalized = Double(min(max(brightness, 0), 1))
        let step = min(max(Int((normalized * Double(totalBrightnessSteps)).rounded()), 0), totalBrightnessSteps)
        return BrightnessState(stepIndex: step, normalizedValue: normalized)
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        displayIDs
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let brightnessController = DisplayBrightnessController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let valueItem = NSMenuItem(title: "Reading brightness…", action: nil, keyEquivalent: "")
    private let stepItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let brightnessControlItem = NSMenuItem()
    private let brightnessLabel = NSTextField(labelWithString: "Brightness")
    private let brightnessFractionLabel = NSTextField(labelWithString: "—/32")
    private let brightnessSlider = NSSlider(value: 0, minValue: 0, maxValue: 32, target: nil, action: nil)
    private lazy var launchAtLoginItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin),
        keyEquivalent: ""
    )
    private var timer: Timer?
    private var lastStepIndex: Int?
    private var authoritativeState: BrightnessState?
    private var authoritativeUntil = Date.distantPast
    private var controlPort: CFMessagePort?
    private var controlRunLoopSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        updateHUD(force: true)
        configureControlPort()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateHUD()
        }
        timer?.tolerance = 0.05

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let controlRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), controlRunLoopSource, .commonModes)
        }
        if let controlPort {
            CFMessagePortInvalidate(controlPort)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginState()
        updateHUD(force: true)
    }

    @objc private func screenConfigurationChanged() {
        brightnessController.refreshDisplays()
        authoritativeState = nil
        authoritativeUntil = .distantPast
        updateHUD(force: true)
    }

    fileprivate func handleControlMessage(_ messageID: Int32) -> BrightnessState? {
        switch messageID {
        case decreaseBrightnessMessageID:
            return adjustBrightness(bySteps: -1)
        case increaseBrightnessMessageID:
            return adjustBrightness(bySteps: 1)
        default:
            return nil
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.toolTip = "Exact macOS display brightness step"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        valueItem.isEnabled = false
        stepItem.isEnabled = false
        launchAtLoginItem.target = self
        configureBrightnessControl()

        menu.addItem(valueItem)
        menu.addItem(stepItem)
        menu.addItem(.separator())
        menu.addItem(brightnessControlItem)
        menu.addItem(.separator())
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Brightness HUD", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func configureControlPort() {
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        var shouldFreeInfo = DarwinBoolean(false)
        guard let port = CFMessagePortCreateLocal(
            kCFAllocatorDefault,
            controlPortName as CFString,
            controlMessagePortCallback,
            &context,
            &shouldFreeInfo
        ), let source = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return
        }

        controlPort = port
        controlRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func configureBrightnessControl() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))

        brightnessLabel.frame = NSRect(x: 14, y: 31, width: 170, height: 17)
        brightnessLabel.font = .systemFont(ofSize: 12, weight: .medium)

        brightnessFractionLabel.frame = NSRect(x: 204, y: 31, width: 62, height: 17)
        brightnessFractionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        brightnessFractionLabel.alignment = .right

        brightnessSlider.frame = NSRect(x: 14, y: 7, width: 252, height: 20)
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessSliderChanged)
        brightnessSlider.isContinuous = false
        brightnessSlider.isEnabled = brightnessController.isAvailable
        brightnessSlider.setAccessibilityLabel("Display brightness step")

        view.addSubview(brightnessLabel)
        view.addSubview(brightnessFractionLabel)
        view.addSubview(brightnessSlider)
        brightnessControlItem.view = view
    }

    private func updateHUD(force: Bool = false, knownState: BrightnessState? = nil) {
        if let knownState {
            authoritativeState = knownState
            authoritativeUntil = Date().addingTimeInterval(0.30)
        }

        let state: BrightnessState?
        if Date() < authoritativeUntil, let authoritativeState {
            state = authoritativeState
        } else {
            authoritativeState = nil
            state = brightnessController.currentMainState()
        }

        guard let state else {
            brightnessSlider.isEnabled = false
            brightnessFractionLabel.stringValue = "—/32"
            if force || lastStepIndex != nil {
                lastStepIndex = nil
                setStatusTitle("—/32", accessibilityLabel: "Display brightness unavailable")
                valueItem.title = "Brightness unavailable"
                stepItem.title = "This display does not expose software brightness control"
            }
            return
        }

        brightnessSlider.isEnabled = true
        brightnessSlider.integerValue = state.stepIndex
        brightnessFractionLabel.stringValue = "\(state.stepIndex)/\(totalBrightnessSteps)"

        guard force || state.stepIndex != lastStepIndex else { return }
        lastStepIndex = state.stepIndex

        let fraction = "\(state.stepIndex)/\(totalBrightnessSteps)"
        setStatusTitle(fraction, accessibilityLabel: "Display brightness, \(state.stepIndex) of \(totalBrightnessSteps)")
        valueItem.attributedTitle = NSAttributedString(
            string: "Brightness · \(fraction)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        stepItem.title = "Each keypress moves 1/32 · 3.125%"
    }

    @discardableResult
    private func adjustBrightness(bySteps stepDelta: Int) -> BrightnessState? {
        guard let target = brightnessController.adjustAllDisplays(bySteps: stepDelta) else {
            NSSound.beep()
            return nil
        }
        updateHUD(force: true, knownState: target)
        return target
    }

    private func setStatusTitle(_ title: String, accessibilityLabel: String) {
        guard let button = statusItem.button else { return }
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        button.setAccessibilityLabel(accessibilityLabel)
    }

    private func updateLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            launchAtLoginItem.isHidden = true
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t update Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        updateLaunchAtLoginState()
    }

    @objc private func brightnessSliderChanged(_ sender: NSSlider) {
        let requestedStep = Int(sender.doubleValue.rounded())
        guard let target = brightnessController.setAllDisplays(toStep: requestedStep) else {
            NSSound.beep()
            updateHUD(force: true)
            return
        }
        updateHUD(force: true, knownState: target)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private let controlMessagePortCallback: CFMessagePortCallBack = { _, messageID, _, info in
    guard let info else { return nil }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
    let acceptedStep = delegate.handleControlMessage(messageID)?.stepIndex ?? 255

    let acknowledgement = Data([UInt8(acceptedStep)]) as CFData
    return Unmanaged.passRetained(acknowledgement)
}

private func sendStepRequest(_ delta: Int) -> Int? {
    let messageID: Int32
    switch delta {
    case -1:
        messageID = decreaseBrightnessMessageID
    case 1:
        messageID = increaseBrightnessMessageID
    default:
        return nil
    }

    guard let remotePort = CFMessagePortCreateRemote(kCFAllocatorDefault, controlPortName as CFString) else {
        return nil
    }

    var response: Unmanaged<CFData>?
    let result = CFMessagePortSendRequest(
        remotePort,
        messageID,
        Data() as CFData,
        1.0,
        1.0,
        CFRunLoopMode.defaultMode.rawValue,
        &response
    )
    guard result == kCFMessagePortSuccess,
          let responseData = response?.takeRetainedValue(),
          CFDataGetLength(responseData) == 1,
          let byte = CFDataGetBytePtr(responseData),
          byte.pointee <= totalBrightnessSteps else { return nil }
    return Int(byte.pointee)
}

@main
private struct NitsBarMain {
    static func main() {
        if let requestIndex = CommandLine.arguments.firstIndex(of: "--request-step") {
            guard requestIndex + 1 < CommandLine.arguments.count,
                  let delta = Int(CommandLine.arguments[requestIndex + 1]),
                  delta == -1 || delta == 1 else {
                fputs("usage: NitsBar --request-step <-1|1>\n", stderr)
                exit(2)
            }
            guard let acceptedStep = sendStepRequest(delta) else {
                fputs("Brightness HUD is not running or did not accept the step request.\n", stderr)
                exit(1)
            }
            print("\(acceptedStep)/\(totalBrightnessSteps)")
            return
        }

        if CommandLine.arguments.contains("--print-brightness")
            || CommandLine.arguments.contains("--print-reading") {
            print(DisplayBrightnessController().diagnosticLine())
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
