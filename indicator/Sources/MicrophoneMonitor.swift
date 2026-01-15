import Foundation
import CoreAudio
import AudioToolbox

/// Monitors the system microphone to detect when any app starts using it.
/// This allows automatic recording when joining a meeting/call.
class MicrophoneMonitor {
    static let shared = MicrophoneMonitor()

    /// Callback when microphone activity changes
    var onMicrophoneActivityChanged: ((Bool) -> Void)?

    private var isMonitoring = false
    private var defaultInputDevice: AudioDeviceID = kAudioObjectUnknown
    private var propertyListenerBlock: AudioObjectPropertyListenerBlock?

    // Track state changes
    private(set) var isMicrophoneInUse = false

    // Debounce timer to avoid rapid on/off triggers
    private var debounceTimer: Timer?
    private var pendingState: Bool?

    // Grace period for brief mic pauses (e.g., muting during a call)
    private let debounceDelay: TimeInterval = 3.0

    init() {}

    deinit {
        stopMonitoring()
    }

    /// Start monitoring microphone activity
    func startMonitoring() {
        guard !isMonitoring else { return }

        // Get the default input device
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
            print("MicrophoneMonitor: Failed to get default input device, status: \(status)")
            return
        }

        defaultInputDevice = deviceID

        // Check initial state
        isMicrophoneInUse = checkIfMicrophoneIsInUse()

        // Register for changes to "device is running somewhere" property
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Create the listener block
        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] (numberAddresses, addresses) in
            DispatchQueue.main.async {
                self?.handleMicrophoneStateChange()
            }
        }

        propertyListenerBlock = listenerBlock

        let addStatus = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &runningAddress,
            DispatchQueue.main,
            listenerBlock
        )

        if addStatus != noErr {
            print("MicrophoneMonitor: Failed to add property listener, status: \(addStatus)")
            return
        }

        // Also monitor for default device changes
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            DispatchQueue.main,
            { [weak self] (_, _) in
                DispatchQueue.main.async {
                    self?.handleDefaultDeviceChange()
                }
            }
        )

        isMonitoring = true
        print("MicrophoneMonitor: Started monitoring, initial state: \(isMicrophoneInUse ? "in use" : "idle")")
    }

    /// Stop monitoring microphone activity
    func stopMonitoring() {
        guard isMonitoring, let listenerBlock = propertyListenerBlock else { return }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            defaultInputDevice,
            &runningAddress,
            DispatchQueue.main,
            listenerBlock
        )

        debounceTimer?.invalidate()
        debounceTimer = nil
        isMonitoring = false
        propertyListenerBlock = nil
    }

    /// Check if the microphone is currently being used by any app
    private func checkIfMicrophoneIsInUse() -> Bool {
        var isRunning: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            defaultInputDevice,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &isRunning
        )

        if status != noErr {
            print("MicrophoneMonitor: Failed to check mic status, status: \(status)")
            return false
        }

        return isRunning != 0
    }

    /// Handle microphone state changes with debouncing
    private func handleMicrophoneStateChange() {
        let newState = checkIfMicrophoneIsInUse()

        // Cancel any pending debounce
        debounceTimer?.invalidate()

        if newState {
            // Mic became active - trigger immediately (no debounce for activation)
            if !isMicrophoneInUse {
                isMicrophoneInUse = true
                print("MicrophoneMonitor: Microphone became active")
                onMicrophoneActivityChanged?(true)
            }
        } else {
            // Mic became inactive - debounce to handle brief pauses
            pendingState = false
            debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceDelay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if self.pendingState == false {
                    self.isMicrophoneInUse = false
                    print("MicrophoneMonitor: Microphone became idle (after debounce)")
                    self.onMicrophoneActivityChanged?(false)
                }
            }
        }
    }

    /// Handle changes to the default input device
    private func handleDefaultDeviceChange() {
        // Stop monitoring old device
        stopMonitoring()

        // Start monitoring new device
        startMonitoring()
    }

    /// Get the name of the current input device
    func getInputDeviceName() -> String? {
        guard defaultInputDevice != kAudioObjectUnknown else { return nil }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceName: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.size)

        let status = AudioObjectGetPropertyData(
            defaultInputDevice,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceName
        )

        if status == noErr {
            return deviceName as String
        }
        return nil
    }
}
