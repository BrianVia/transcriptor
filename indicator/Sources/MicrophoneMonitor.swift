import Foundation
import CoreAudio
import AudioToolbox
import os.log

private let logger = Logger(subsystem: "com.transcriptor.indicator", category: "MicrophoneMonitor")

/// Monitors the system microphone to detect when any app starts using it.
/// This allows automatic recording when joining a meeting/call.
class MicrophoneMonitor {
    static let shared = MicrophoneMonitor()

    private struct DeviceActivitySnapshot {
        let deviceID: AudioDeviceID
        let name: String
        let isDefaultInput: Bool
        let isRunningSomewhere: Bool
        let runningSomewhereStatus: OSStatus
        let isRunning: Bool
        let runningStatus: OSStatus

        var isActive: Bool {
            isRunningSomewhere || isRunning
        }
    }

    /// Callback when microphone activity changes
    var onMicrophoneActivityChanged: ((Bool) -> Void)?

    private var isMonitoring = false
    private var defaultInputDevice: AudioDeviceID = kAudioObjectUnknown
    private var monitoredInputDevices = Set<AudioDeviceID>()
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var systemListenerBlock: AudioObjectPropertyListenerBlock?

    // Track state changes
    private(set) var isMicrophoneInUse = false

    // Debounce timer to avoid rapid on/off triggers
    private var debounceTimer: Timer?
    private var pollingTimer: Timer?
    private var pendingState: Bool?
    private var lastKnownDeviceStates = [AudioDeviceID: Bool]()
    private var sessionActiveDevices = Set<AudioDeviceID>()

    // Devices that were already active at startup — treated as baseline (e.g. Wispr Flow)
    private var baselineActiveDevices = Set<AudioDeviceID>()

    // Grace period for brief mic pauses (e.g., muting during a call)
    private let debounceDelay: TimeInterval = 3.0
    private let pollingInterval: TimeInterval = 2.0

    init() {}

    deinit {
        stopMonitoring()
    }

    /// Start monitoring microphone activity
    func startMonitoring() {
        guard !isMonitoring else { return }

        refreshDefaultInputDevice()

        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] (numberAddresses, addresses) in
            self?.handleMicrophoneStateChange(reason: "device property change")
        }
        deviceListenerBlock = listenerBlock

        let systemBlock: AudioObjectPropertyListenerBlock = { [weak self] (_, _) in
            self?.handleHardwareChange()
        }
        systemListenerBlock = systemBlock

        refreshMonitoredDevices()
        addSystemListeners()

        let initialSnapshots = currentDeviceActivitySnapshots()
        lastKnownDeviceStates = Dictionary(uniqueKeysWithValues: initialSnapshots.map { ($0.deviceID, $0.isActive) })
        sessionActiveDevices.removeAll()
        isMicrophoneInUse = false

        // Record devices already active at startup as baseline — these are likely
        // always-on apps (e.g. Wispr Flow) and should not trigger recording on their own.
        // Only a NEW device activating (not in baseline) will trigger.
        baselineActiveDevices = Set(initialSnapshots.filter(\.isActive).map(\.deviceID))

        startPolling()

        isMonitoring = true
        let baselineNames = describeDevices(Array(baselineActiveDevices), fallback: "none")
        logger.notice("Started monitoring \(self.monitoredInputDevices.count) input device(s), baseline active: \(baselineNames, privacy: .public)")
        logger.notice("Initial device snapshot: \(self.describeSnapshots(initialSnapshots), privacy: .public)")
    }

    /// Stop monitoring microphone activity
    func stopMonitoring() {
        guard isMonitoring else { return }

        removeAllDeviceListeners()
        removeSystemListeners()

        debounceTimer?.invalidate()
        debounceTimer = nil
        pollingTimer?.invalidate()
        pollingTimer = nil
        pendingState = nil
        lastKnownDeviceStates.removeAll()
        sessionActiveDevices.removeAll()
        baselineActiveDevices.removeAll()
        isMonitoring = false
        deviceListenerBlock = nil
        systemListenerBlock = nil
        monitoredInputDevices.removeAll()
    }

    /// Check if the microphone is currently being used by any app
    private func checkIfMicrophoneIsInUse() -> Bool {
        !currentActiveInputDevices().isEmpty
    }

    /// Handle microphone state changes with debouncing
    private func handleMicrophoneStateChange(reason: String) {
        let snapshots = currentDeviceActivitySnapshots()
        let currentStates = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.deviceID, $0.isActive) })

        // A device is "newly activated" if it just transitioned to active AND
        // it's not a baseline device (always-on like Wispr Flow).
        // Baseline devices are only interesting if they went inactive then came back.
        let newlyActivatedDevices = snapshots
            .filter { snapshot in
                guard snapshot.isActive else { return false }
                guard lastKnownDeviceStates[snapshot.deviceID] != true else { return false }
                // If this is a baseline device that went inactive and came back, that's a real activation
                // If it's a baseline device that was always active, skip it
                if baselineActiveDevices.contains(snapshot.deviceID) {
                    // Only count if it was previously tracked as inactive (went off then back on)
                    return lastKnownDeviceStates[snapshot.deviceID] == false
                }
                return true
            }
            .map(\.deviceID)

        let trackedDevicesStillActive = sessionActiveDevices.filter { currentStates[$0] == true }

        // Only log on actual state changes, not every poll
        let stateChanged = currentStates != lastKnownDeviceStates
        if stateChanged {
            logger.notice("\(self.snapshotLogLabel(for: reason), privacy: .public): \(self.describeSnapshots(snapshots), privacy: .public)")
        }

        lastKnownDeviceStates = currentStates

        // Cancel any pending debounce
        debounceTimer?.invalidate()
        debounceTimer = nil

        if !newlyActivatedDevices.isEmpty {
            // Mic became active - trigger immediately (no debounce for activation)
            pendingState = nil
            sessionActiveDevices.formUnion(newlyActivatedDevices)
            if !isMicrophoneInUse {
                isMicrophoneInUse = true
                logger.notice("Microphone became active via \(self.describeDevices(newlyActivatedDevices, fallback: "unknown input device"), privacy: .public) [reason: \(reason, privacy: .public)]")
                onMicrophoneActivityChanged?(true)
            } else {
                logger.notice("Additional microphone device became active via \(self.describeDevices(newlyActivatedDevices, fallback: "unknown input device"), privacy: .public) [reason: \(reason, privacy: .public)]")
            }
        } else {
            // Mic became inactive - debounce to handle brief pauses
            guard isMicrophoneInUse else { return }
            guard trackedDevicesStillActive.isEmpty else { return }
            pendingState = false
            debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceDelay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let currentStates = Dictionary(uniqueKeysWithValues: self.currentDeviceActivitySnapshots().map { ($0.deviceID, $0.isActive) })
                let trackedDevicesStillActive = self.sessionActiveDevices.filter { currentStates[$0] == true }
                if self.pendingState == false, trackedDevicesStillActive.isEmpty {
                    self.isMicrophoneInUse = false
                    self.pendingState = nil
                    self.sessionActiveDevices.removeAll()
                    logger.notice("Microphone became idle (after debounce) [reason: \(reason, privacy: .public)]")
                    self.onMicrophoneActivityChanged?(false)
                }
            }
        }
    }

    private func handleHardwareChange() {
        refreshDefaultInputDevice()
        refreshMonitoredDevices()
        handleMicrophoneStateChange(reason: "hardware change")
    }

    private func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.handleMicrophoneStateChange(reason: "poll")
        }
    }

    /// Get the name of the current input device
    func getInputDeviceName() -> String? {
        guard defaultInputDevice != kAudioObjectUnknown else { return nil }
        return getDeviceName(for: defaultInputDevice)
    }

    private func refreshDefaultInputDevice() {
        var deviceID = kAudioObjectUnknown
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.notice("Failed to get default input device, status: \(status)")
            defaultInputDevice = kAudioObjectUnknown
            return
        }

        defaultInputDevice = deviceID
    }

    private func refreshMonitoredDevices() {
        let nextDevices = Set(getInputCapableDevices())
        let removedDevices = monitoredInputDevices.subtracting(nextDevices)
        let addedDevices = nextDevices.subtracting(monitoredInputDevices)

        for deviceID in removedDevices {
            removeDeviceListeners(for: deviceID)
        }

        monitoredInputDevices = nextDevices
        lastKnownDeviceStates = lastKnownDeviceStates.filter { monitoredInputDevices.contains($0.key) }
        sessionActiveDevices = sessionActiveDevices.intersection(monitoredInputDevices)

        for deviceID in addedDevices {
            addDeviceListeners(for: deviceID)
        }

        if monitoredInputDevices.isEmpty {
            logger.notice("No input-capable audio devices available for monitoring")
        } else {
            logger.notice("Monitoring devices: \(self.describeDevices(Array(self.monitoredInputDevices), fallback: "none"), privacy: .public)")
        }
    }

    private func addSystemListeners() {
        guard let systemListenerBlock else { return }

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            systemListenerBlock
        )

        if defaultStatus != noErr {
            logger.notice("Failed to add default input listener, status: \(defaultStatus)")
        }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            systemListenerBlock
        )

        if devicesStatus != noErr {
            logger.notice("Failed to add device list listener, status: \(devicesStatus)")
        }
    }

    private func removeSystemListeners() {
        guard let systemListenerBlock else { return }

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            systemListenerBlock
        )

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            systemListenerBlock
        )
    }

    private func addDeviceListeners(for deviceID: AudioDeviceID) {
        guard let deviceListenerBlock else { return }

        for selector in [kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioDevicePropertyDeviceIsRunning] {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            let status = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &propertyAddress,
                DispatchQueue.main,
                deviceListenerBlock
            )

            if status != noErr {
                logger.notice("Failed to add listener for device \(deviceID), selector \(selector), status: \(status)")
            }
        }
    }

    private func removeDeviceListeners(for deviceID: AudioDeviceID) {
        guard let deviceListenerBlock else { return }

        for selector in [kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioDevicePropertyDeviceIsRunning] {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectRemovePropertyListenerBlock(
                deviceID,
                &propertyAddress,
                DispatchQueue.main,
                deviceListenerBlock
            )
        }
    }

    private func removeAllDeviceListeners() {
        for deviceID in monitoredInputDevices {
            removeDeviceListeners(for: deviceID)
        }
    }

    private func currentActiveInputDevices() -> [AudioDeviceID] {
        currentDeviceActivitySnapshots().filter(\.isActive).map(\.deviceID)
    }

    private func isInputDeviceActive(_ deviceID: AudioDeviceID) -> Bool {
        snapshotForDevice(deviceID).isActive
    }

    private func isDeviceRunning(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> (status: OSStatus, isRunning: Bool) {
        var isRunning: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &isRunning
        )

        return (status, status == noErr && isRunning != 0)
    }

    private func getInputCapableDevices() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard sizeStatus == noErr else {
            logger.notice("Failed to get audio device list size, status: \(sizeStatus)")
            return []
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: deviceCount)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        guard dataStatus == noErr else {
            logger.notice("Failed to get audio device list, status: \(dataStatus)")
            return []
        }

        return deviceIDs.filter { hasInputStreams(deviceID: $0) }
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        return status == noErr && propertySize > 0
    }

    private func getDeviceName(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceName: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceName
        )

        guard status == noErr else {
            return nil
        }

        return deviceName?.takeUnretainedValue() as String?
    }

    private func describeDevices(_ deviceIDs: [AudioDeviceID], fallback: String) -> String {
        let names = deviceIDs.compactMap { getDeviceName(for: $0) }
        return names.isEmpty ? fallback : names.joined(separator: ", ")
    }

    private func currentDeviceActivitySnapshots() -> [DeviceActivitySnapshot] {
        monitoredInputDevices
            .sorted()
            .map { snapshotForDevice($0) }
    }

    private func snapshotForDevice(_ deviceID: AudioDeviceID) -> DeviceActivitySnapshot {
        let runningSomewhere = isDeviceRunning(deviceID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        let running = isDeviceRunning(deviceID, selector: kAudioDevicePropertyDeviceIsRunning)

        return DeviceActivitySnapshot(
            deviceID: deviceID,
            name: getDeviceName(for: deviceID) ?? "Device \(deviceID)",
            isDefaultInput: deviceID == defaultInputDevice,
            isRunningSomewhere: runningSomewhere.isRunning,
            runningSomewhereStatus: runningSomewhere.status,
            isRunning: running.isRunning,
            runningStatus: running.status
        )
    }

    private func describeSnapshots(_ snapshots: [DeviceActivitySnapshot]) -> String {
        guard !snapshots.isEmpty else { return "no input devices" }

        return snapshots.map { snapshot in
            let defaultMarker = snapshot.isDefaultInput ? "*" : ""
            return "\(snapshot.name)\(defaultMarker)[id=\(snapshot.deviceID),runningSomewhere=\(snapshot.isRunningSomewhere),status=\(snapshot.runningSomewhereStatus),running=\(snapshot.isRunning),status=\(snapshot.runningStatus)]"
        }
        .joined(separator: "; ")
    }

    private func snapshotLogLabel(for reason: String) -> String {
        switch reason {
        case "poll":
            return "Poll snapshot"
        case "hardware change":
            return "Hardware-change snapshot"
        case "device property change":
            return "Property-change snapshot"
        default:
            return "Microphone snapshot"
        }
    }
}
