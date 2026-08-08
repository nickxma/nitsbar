import AppKit
import Foundation
import IOKit
import ObjectiveC.runtime
import ServiceManagement

private let brightnessFrameworkPath = "/System/Library/PrivateFrameworks/BrightnessControl.framework/BrightnessControl"
private let displayServicesFrameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
private let brightIntoshBundleIdentifier = "de.brightintosh.app"
private let brightIntoshDefaultsSuite = "group.de.brightintosh.app"
private let appleDisplayVendorID: UInt32 = 0x610
private let studioDisplayXDRModelID: UInt32 = 0xae42
private let studioDisplayXDRPeakNits = 2_000.0

private struct LuminanceReading {
    let sdrNits: Double
    let edrGain: Double
    let effectiveNits: Double
    let edrCeilingNits: Double

    var isExtended: Bool { edrGain > 1.01 }
}

private final class BrightnessReader {
    private typealias CopyControlsFunction = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias GetNitsFunction = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<AnyObject?>?) -> Double
    private typealias GetLinearBrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var displayServicesHandle: UnsafeMutableRawPointer?
    private var getLinearBrightness: GetLinearBrightnessFunction?
    private var control: NSObject?
    private var isBuiltInDisplay = false
    private(set) var displayName = "Display"
    private(set) var minimumNits: Double?
    private(set) var maximumNits: Double?
    private(set) var physicalPeakNits: Double?

    init() {
        frameworkHandle = dlopen(brightnessFrameworkPath, RTLD_NOW)
        displayServicesHandle = dlopen(displayServicesFrameworkPath, RTLD_NOW)
        if let displayServicesHandle,
           let symbol = dlsym(displayServicesHandle, "DisplayServicesGetLinearBrightness") {
            getLinearBrightness = unsafeBitCast(symbol, to: GetLinearBrightnessFunction.self)
        }
        refreshDisplay()
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
        if let displayServicesHandle {
            dlclose(displayServicesHandle)
        }
    }

    func refreshDisplay() {
        displayName = NSScreen.main?.localizedName ?? NSScreen.screens.first?.localizedName ?? "Display"
        isBuiltInDisplay = CGDisplayIsBuiltin(CGMainDisplayID()) != 0
        control = findReadableControl()
        minimumNits = control?.value(forKey: "minNits") as? Double
        maximumNits = control?.value(forKey: "maxNits") as? Double
        physicalPeakNits = currentPhysicalPeakNits()
    }

    func currentReading() -> LuminanceReading? {
        guard let sdrNits = currentCalibratedSDRNits() ?? currentBuiltInSDRNits() else { return nil }
        let transferGain = currentTransferGain()
        let overlayGain = currentBrightIntoshOverlayGain()
        let uncappedGain = max(1, transferGain * overlayGain)
        let peak = physicalPeakNits ?? maximumNits ?? sdrNits
        let effectiveNits = min(sdrNits * uncappedGain, peak)
        let gain = sdrNits > 0 ? effectiveNits / sdrNits : 1

        return LuminanceReading(
            sdrNits: sdrNits,
            edrGain: gain,
            effectiveNits: effectiveNits,
            edrCeilingNits: max(effectiveNits, peak)
        )
    }

    func diagnosticLine() -> String {
        guard let reading = currentReading() else { return "unavailable" }
        return String(
            format: "sdr=%.3f gain=%.4f effective=%.3f peak=%.3f display=%@",
            reading.sdrNits,
            reading.edrGain,
            reading.effectiveNits,
            reading.edrCeilingNits,
            displayName
        )
    }

    private func currentBuiltInSDRNits() -> Double? {
        guard isBuiltInDisplay,
              let getLinearBrightness,
              let maximumNits,
              maximumNits > 0 else { return nil }

        var linearBrightness: Float = 0
        guard getLinearBrightness(CGMainDisplayID(), &linearBrightness) == 0,
              linearBrightness.isFinite else { return nil }

        let minimum = max(0, minimumNits ?? 0)
        return max(minimum, maximumNits * min(max(Double(linearBrightness), 0), 1))
    }

    private func currentCalibratedSDRNits() -> Double? {
        guard let control else { return nil }
        let selector = NSSelectorFromString("getNitsWithError:")
        guard let method = class_getInstanceMethod(type(of: control), selector) else { return nil }

        let function = unsafeBitCast(method_getImplementation(method), to: GetNitsFunction.self)
        var error: AnyObject?
        let value = function(control, selector, &error)
        guard error == nil, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func currentBuiltInPanelNits() -> Double? {
        for className in ["IOMobileFramebufferShim", "IOMobileFramebuffer"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != 0 {
                let currentService = service
                defer { IOObjectRelease(currentService) }

                let external = IORegistryEntryCreateCFProperty(
                    currentService,
                    "external" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? NSNumber

                if external?.boolValue != true,
                   let fixedPoint = IORegistryEntryCreateCFProperty(
                       currentService,
                       "IOMFBBrightnessLevel" as CFString,
                       kCFAllocatorDefault,
                       0
                   )?.takeRetainedValue() as? NSNumber {
                    let nits = fixedPoint.doubleValue / 65_536
                    if nits.isFinite, nits > 0, nits < 10_000 {
                        return nits
                    }
                }

                service = IOIteratorNext(iterator)
            }
        }
        return nil
    }

    private func currentPhysicalPeakNits() -> Double? {
        let capabilities = control?.value(forKey: "capabilities") as? NSDictionary
        for key in ["MaxNitsEDR", "MaxNitsPanel", "LmaxProduct"] {
            if let value = capabilities?[key] as? NSNumber {
                let nits = value.doubleValue
                if nits.isFinite, nits > 0 { return nits }
            }
        }

        // Studio Display XDR's HID brightness control reports only its normal
        // 4–600-nit SDR range. Identify the panel by its stable CoreGraphics
        // hardware IDs so that range is not mistaken for the physical HDR peak.
        let displayID = CGMainDisplayID()
        if CGDisplayVendorNumber(displayID) == appleDisplayVendorID,
           CGDisplayModelNumber(displayID) == studioDisplayXDRModelID {
            return studioDisplayXDRPeakNits
        }

        return currentBuiltInPanelNits().flatMap { panelNits in
            guard let maximumNits, panelNits > maximumNits else { return nil }
            return panelNits
        }
    }

    private func currentTransferGain() -> Double {
        let capacity: UInt32 = 4096
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var sampleCount: UInt32 = 0

        guard CGGetDisplayTransferByTable(
            CGMainDisplayID(),
            capacity,
            &red,
            &green,
            &blue,
            &sampleCount
        ) == .success, sampleCount > 0 else {
            return 1
        }

        let last = Int(sampleCount - 1)
        // Neutral UI white uses all three channels. Weight the live transfer
        // endpoints by luminance so color-temperature adjustments do not look
        // like an artificial brightness increase.
        let whiteGain = 0.2126 * Double(red[last])
            + 0.7152 * Double(green[last])
            + 0.0722 * Double(blue[last])
        guard whiteGain.isFinite else { return 1 }
        return max(1, whiteGain)
    }

    private func currentEDRHeadroom() -> Double {
        let displayID = CGMainDisplayID()
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == displayID
        } ?? NSScreen.main
        let headroom = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        guard headroom.isFinite else { return 1 }
        return max(1, headroom)
    }

    private func currentBrightIntoshOverlayGain() -> Double {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: brightIntoshBundleIdentifier)
            .contains(where: { !$0.isTerminated }),
              let defaults = UserDefaults(suiteName: brightIntoshDefaultsSuite),
              defaults.bool(forKey: "active"),
              defaults.bool(forKey: "useAlternateBrightnessBackend") else {
            return 1
        }

        let headroom = currentEDRHeadroom()
        guard headroom > 1.05 else { return 1 }

        let referenceEDR: Double
        let bonus: Double
        if isBuiltInDisplay {
            if (maximumNits ?? 0) >= 590 {
                (referenceEDR, bonus) = (2.66, 0.50)
            } else {
                (referenceEDR, bonus) = (3.2, 0.59)
            }
        } else {
            (referenceEDR, bonus) = (2.66, 0.60)
        }

        let ratio = headroom / referenceEDR
        guard defaults.bool(forKey: "fineGrainedBrightnessControl") else {
            return 1 + bonus * min(ratio, 1)
        }

        let requested = min(max(defaults.double(forKey: "brightness"), 0), 1)
        if requested > 0.995 {
            return 1 + bonus * ratio
        }
        return 1 + bonus * min(ratio, requested)
    }

    private func findReadableControl() -> NSObject? {
        // Apple displays connected over USB/Thunderbolt expose their calibrated
        // luminance through the HID controller. Built-in displays use the
        // AppleBacklight controller, so keep that as a fallback.
        var calibratedFallback: NSObject?
        for className in ["BCHIDBrtControl", "BCAppleBacklightBrtControl"] {
            for candidate in availableControls(forClassNamed: className) {
                if calibratedFallback == nil,
                   candidate.responds(to: NSSelectorFromString("minNits")),
                   candidate.responds(to: NSSelectorFromString("maxNits")),
                   let minimum = candidate.value(forKey: "minNits") as? Double,
                   let maximum = candidate.value(forKey: "maxNits") as? Double,
                   minimum >= 0,
                   maximum > minimum {
                    calibratedFallback = candidate
                }

                let selector = NSSelectorFromString("getNitsWithError:")
                guard let method = class_getInstanceMethod(type(of: candidate), selector) else { continue }
                let function = unsafeBitCast(method_getImplementation(method), to: GetNitsFunction.self)
                var error: AnyObject?
                let value = function(candidate, selector, &error)
                if error == nil, value.isFinite, value >= 0 {
                    return candidate
                }
            }
        }
        return calibratedFallback
    }

    private func availableControls(forClassNamed className: String) -> [NSObject] {
        guard frameworkHandle != nil,
              let controlClass: AnyClass = NSClassFromString(className)
        else { return [] }

        let selector = NSSelectorFromString("copyAvailableControls")
        guard let method = class_getClassMethod(controlClass, selector) else { return [] }
        let function = unsafeBitCast(method_getImplementation(method), to: CopyControlsFunction.self)
        guard let result = function(controlClass, selector)?.takeRetainedValue() as? NSArray else { return [] }
        return result.compactMap { $0 as? NSObject }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let reader = BrightnessReader()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let valueItem = NSMenuItem(title: "Reading display…", action: nil, keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
    private let rangeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var launchAtLoginItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin),
        keyEquivalent: ""
    )
    private var timer: Timer?
    private var lastRoundedValue: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.15

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
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginState()
        refresh(force: true)
    }

    @objc private func screenConfigurationChanged() {
        reader.refreshDisplay()
        refresh(force: true)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.toolTip = "Current effective display luminance"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        valueItem.isEnabled = false
        displayItem.isEnabled = false
        rangeItem.isEnabled = false
        launchAtLoginItem.target = self

        menu.addItem(valueItem)
        menu.addItem(displayItem)
        menu.addItem(rangeItem)
        menu.addItem(.separator())
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NitsBar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func refresh(force: Bool = false) {
        guard let reading = reader.currentReading() else {
            if force || lastRoundedValue != nil {
                lastRoundedValue = nil
                setStatusTitle("— nits")
                valueItem.title = "Luminance unavailable"
                displayItem.title = reader.displayName
                rangeItem.title = "This display does not expose calibrated nits"
            }
            return
        }

        let rounded = Int(reading.effectiveNits.rounded())
        guard force || rounded != lastRoundedValue else { return }
        lastRoundedValue = rounded

        let effective = formatNits(rounded)
        setStatusTitle("\(effective) nits")
        valueItem.attributedTitle = NSAttributedString(
            string: "\(effective) nits · \(reading.isExtended ? "Vivid/EDR" : "SDR")",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        if reading.isExtended {
            displayItem.title = "\(formatNits(Int(reading.sdrNits.rounded()))) nits SDR × \(String(format: "%.2f", reading.edrGain))"
            rangeItem.title = "Display peak: \(formatNits(Int(reading.edrCeilingNits.rounded()))) nits"
        } else {
            displayItem.title = reader.displayName

            if let minimum = reader.minimumNits, let maximum = reader.maximumNits {
                rangeItem.title = "Calibrated range: \(formatNits(Int(minimum.rounded())))–\(formatNits(Int(maximum.rounded()))) nits"
            } else {
                rangeItem.title = "Updates automatically"
            }
        }
    }

    private func formatNits(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func setStatusTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        button.setAccessibilityLabel("Display luminance, \(title)")
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
private struct NitsBarMain {
    static func main() {
        if CommandLine.arguments.contains("--print-reading") {
            print(BrightnessReader().diagnosticLine())
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
