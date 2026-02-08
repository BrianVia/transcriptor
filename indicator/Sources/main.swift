import AppKit
import EventKit
import Foundation

// MARK: - State Management

struct RecordingState: Codable {
    var isRecording: Bool
    var meetingName: String?
    var startTime: String?
    var outputDir: String?
    var audioPid: Int?
    var indicatorPid: Int?
}

class StateManager {
    static let shared = StateManager()

    private let stateFile: URL
    private let transcriptorDir: URL

    init() {
        transcriptorDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcriptor")
        stateFile = transcriptorDir.appendingPathComponent("state.json")
    }

    func loadState() -> RecordingState {
        guard FileManager.default.fileExists(atPath: stateFile.path),
              let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(RecordingState.self, from: data) else {
            return RecordingState(isRecording: false)
        }
        return state
    }

    func getElapsedTime() -> String? {
        let state = loadState()
        guard state.isRecording, let startTimeStr = state.startTime else { return nil }

        // JavaScript's toISOString() produces: 2024-12-08T10:30:00.000Z
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let startTime = formatter.date(from: startTimeStr) else { return nil }

        let elapsed = Int(Date().timeIntervalSince(startTime))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var timer: Timer?
    var calendarTimer: Timer?
    var isBlinking = false

    // Cache for upcoming meeting display
    var cachedNextMeeting: UpcomingMeeting?

    // Track if we started recording via mic detection (for auto-stop)
    var micTriggeredRecording = false
    var autoStartedRecording = false
    var micAutoStopTimer: Timer?

    // Track last known recording state to avoid rebuilding menu unnecessarily
    // Starts as nil so the first updateStatusItem() call always sets up the icon/menu
    private var lastKnownRecordingState: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateStatusItem()

        // Update timer - check state every second
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatusItem()
        }

        // Setup signal handling
        setupSignalHandling()

        // Setup calendar integration
        setupCalendarIntegration()

        // Setup microphone monitoring
        setupMicrophoneMonitoring()
    }

    // MARK: - Calendar Integration

    func setupCalendarIntegration() {
        let config = ConfigManager.shared.loadConfig()

        guard config.calendarEnabled else {
            return
        }

        // Request calendar access
        CalendarManager.shared.requestAccess { [weak self] granted in
            if granted {
                self?.startCalendarPolling()
            } else {
                self?.showCalendarAccessDeniedAlert()
            }
        }
    }

    func startCalendarPolling() {
        // Poll every 30 seconds for upcoming meetings
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkForUpcomingMeetings()
        }

        // Also check immediately
        checkForUpcomingMeetings()
    }

    func checkForUpcomingMeetings() {
        let config = ConfigManager.shared.loadConfig()
        guard config.calendarEnabled else {
            cachedNextMeeting = nil
            return
        }

        // Don't check if already recording
        let state = StateManager.shared.loadState()
        if state.isRecording {
            cachedNextMeeting = nil
            return
        }

        // Get meetings starting within configured window + 1 minute buffer
        let meetings = CalendarManager.shared.getUpcomingMeetings(
            within: config.reminderMinutesBefore + 1,
            config: config
        )

        let now = Date()

        // Find meetings sorted by start time
        let sortedMeetings = meetings.sorted { $0.startDate < $1.startDate }

        // For menu display: only show meetings that haven't started yet
        cachedNextMeeting = sortedMeetings.first { $0.startDate > now }

        // For auto-start: check if any meeting is within the start window (-60s to +60s)
        for meeting in sortedMeetings {
            let timeUntilStart = meeting.startDate.timeIntervalSince(now)
            if timeUntilStart <= 60 && timeUntilStart >= -60 {
                if config.autoStartRecording &&
                    config.requireGoogleMeetLinkForCalendarAutoStart &&
                    !meeting.hasGoogleMeetLink {
                    continue
                }
                handleMeetingStart(meeting, config: config)
                break  // Only handle one meeting at a time
            }
        }
    }

    func handleMeetingStart(_ meeting: UpcomingMeeting, config: CalendarConfig) {
        // Mark as handled immediately to prevent duplicate triggers
        CalendarManager.shared.markEventAsHandled(meeting.eventId)

        // Clear the cached meeting immediately so menu updates
        cachedNextMeeting = nil

        // Calendar-triggered - don't auto-stop based on mic
        micTriggeredRecording = false

        if config.autoStartRecording {
            autoStartedRecording = true
            // Auto-start recording without dialog
            startRecording(name: meeting.title)
        } else {
            autoStartedRecording = false
            // Show confirmation dialog
            showMeetingStartDialog(meeting)
        }

        // Refresh cache to show next meeting (after a brief delay for state to settle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshUpcomingMeetingCache()
        }
    }

    func refreshUpcomingMeetingCache() {
        let config = ConfigManager.shared.loadConfig()
        guard config.calendarEnabled else {
            cachedNextMeeting = nil
            return
        }

        let state = StateManager.shared.loadState()
        if state.isRecording {
            cachedNextMeeting = nil
            return
        }

        // Get meetings within a longer window for display
        let meetings = CalendarManager.shared.getUpcomingMeetings(
            within: 60,  // Look ahead 1 hour for "Next" display
            config: config
        )

        let now = Date()
        let futureMeetings = meetings.filter { $0.startDate > now }
        cachedNextMeeting = futureMeetings.sorted { $0.startDate < $1.startDate }.first
    }

    func showMeetingStartDialog(_ meeting: UpcomingMeeting) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Meeting Starting"
        alert.informativeText = "Start recording \"\(meeting.title)\"?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Skip")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            autoStartedRecording = false
            startRecording(name: meeting.title)
        }
    }

    func showCalendarAccessDeniedAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Calendar Access Required"
            alert.informativeText = "Transcriptor needs calendar access to auto-record meetings. Enable it in System Settings > Privacy & Security > Calendars."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Dismiss")

            NSApp.activate(ignoringOtherApps: true)

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - Microphone Monitoring

    func setupMicrophoneMonitoring() {
        let config = ConfigManager.shared.loadConfig()

        guard config.microphoneDetectionEnabled else {
            return
        }

        // Set up callback for microphone activity changes
        MicrophoneMonitor.shared.onMicrophoneActivityChanged = { [weak self] isActive in
            self?.handleMicrophoneActivityChange(isActive: isActive)
        }

        // Start monitoring
        MicrophoneMonitor.shared.startMonitoring()
    }

    func handleMicrophoneActivityChange(isActive: Bool) {
        let config = ConfigManager.shared.loadConfig()
        let state = StateManager.shared.loadState()

        if isActive {
            // Microphone became active
            micAutoStopTimer?.invalidate()
            micAutoStopTimer = nil

            // Only auto-start if enabled, not already recording, and auto-start is on
            if config.microphoneAutoStart && !state.isRecording {
                handleMicrophoneActivated(config: config)
            }
        } else {
            // Microphone became idle
            if config.microphoneAutoStop && state.isRecording && micTriggeredRecording {
                // Start countdown to auto-stop
                let delay = TimeInterval(config.microphoneIdleDelaySeconds)
                micAutoStopTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.handleMicrophoneAutoStop()
                }
            }
        }
    }

    func handleMicrophoneActivated(config: CalendarConfig) {
        // Check if there's an upcoming calendar meeting to use as the name
        var meetingName: String? = nil

        if config.calendarEnabled, let nextMeeting = cachedNextMeeting {
            // If meeting is starting soon (within 5 minutes), use its name
            let timeUntilStart = nextMeeting.startDate.timeIntervalSince(Date())
            if timeUntilStart <= 300 && timeUntilStart >= -300 {
                meetingName = nextMeeting.title
                CalendarManager.shared.markEventAsHandled(nextMeeting.eventId)
                cachedNextMeeting = nil
            }
        }

        // Default name if no calendar match
        let name = meetingName ?? "Call \(formatDate(Date()))"

        // Mark as mic-triggered for auto-stop tracking
        micTriggeredRecording = true
        autoStartedRecording = true

        // Show brief notification and start recording
        showMicrophoneDetectedNotification(meetingName: name)
        startRecording(name: name)

        // Refresh the meeting cache
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshUpcomingMeetingCache()
        }
    }

    func handleMicrophoneAutoStop() {
        let state = StateManager.shared.loadState()
        guard state.isRecording && micTriggeredRecording else { return }

        // Verify mic is still idle
        if !MicrophoneMonitor.shared.isMicrophoneInUse {
            micTriggeredRecording = false
            autoStartedRecording = false
            stopRecording()
        }
    }

    func showMicrophoneDetectedNotification(meetingName: String) {
        // Post a user notification
        let notification = NSUserNotification()
        notification.title = "Recording Started"
        notification.informativeText = "Microphone detected. Recording: \(meetingName)"
        notification.soundName = nil
        NSUserNotificationCenter.default.deliver(notification)
    }

    @objc func toggleMicrophoneDetection() {
        var config = ConfigManager.shared.loadConfig()
        config.microphoneDetectionEnabled = !config.microphoneDetectionEnabled
        ConfigManager.shared.saveConfig(config)

        if config.microphoneDetectionEnabled {
            MicrophoneMonitor.shared.startMonitoring()
        } else {
            MicrophoneMonitor.shared.stopMonitoring()
        }

        updateStatusItem()
    }

    // MARK: - UI Updates

    func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let state = StateManager.shared.loadState()
        let stateChanged = state.isRecording != lastKnownRecordingState

        if state.isRecording {
            enforceAutoRecordingTimeoutIfNeeded(state: state)

            // Recording state - blinking red dot with timer
            isBlinking.toggle()

            let meetingName = state.meetingName ?? "Recording"
            let elapsed = StateManager.shared.getElapsedTime() ?? "0:00"

            // Only update image on state change (expensive operation)
            if stateChanged {
                if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Recording") {
                    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    button.image = image.withSymbolConfiguration(config)
                    button.image?.isTemplate = true
                }
                button.imagePosition = .imageLeft
            }

            // Update title every tick (cheap operation)
            let dot = isBlinking ? "●" : "○"
            button.title = " \(dot) \(elapsed)"

            // Only rebuild menu on state change
            if stateChanged {
                setupRecordingMenu(meetingName: meetingName, elapsed: elapsed)
                lastKnownRecordingState = true
            }
        } else {
            if stateChanged {
                micTriggeredRecording = false
                autoStartedRecording = false
            }

            // Idle state - clean waveform icon
            // Only update on state change
            if stateChanged {
                if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcriptor") {
                    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                    button.image = image.withSymbolConfiguration(config)
                    button.image?.isTemplate = true
                }
                button.title = ""
                button.imagePosition = .imageOnly

                setupIdleMenu()
                lastKnownRecordingState = false
            }
        }
    }

    func setupIdleMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Transcriptor", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Show microphone status if monitoring is enabled
        let config = ConfigManager.shared.loadConfig()
        if config.microphoneDetectionEnabled {
            let micStatus = MicrophoneMonitor.shared.isMicrophoneInUse ? "🎤 Mic Active" : "🎤 Listening..."
            let micStatusItem = NSMenuItem(title: micStatus, action: nil, keyEquivalent: "")
            micStatusItem.isEnabled = false
            menu.addItem(micStatusItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Show upcoming meeting if any
        if config.calendarEnabled, let nextMeeting = cachedNextMeeting {
            let timeStr = formatRelativeTime(nextMeeting.startDate)
            let upcomingItem = NSMenuItem(
                title: "Next: \(nextMeeting.title) (\(timeStr))",
                action: nil,
                keyEquivalent: ""
            )
            upcomingItem.isEnabled = false
            menu.addItem(upcomingItem)
            menu.addItem(NSMenuItem.separator())
        }

        let startItem = NSMenuItem(title: "Start Recording...", action: #selector(showStartDialog), keyEquivalent: "r")
        startItem.target = self
        menu.addItem(startItem)

        menu.addItem(NSMenuItem.separator())

        // Microphone detection toggle
        let micLabel = config.microphoneDetectionEnabled ? "Mic Detection: On" : "Mic Detection: Off"
        let micItem = NSMenuItem(title: micLabel, action: #selector(toggleMicrophoneDetection), keyEquivalent: "")
        micItem.target = self
        menu.addItem(micItem)

        // Calendar toggle if enabled
        if config.calendarEnabled {
            let autoLabel = config.autoStartRecording ? "Calendar Auto-Record: On" : "Calendar Auto-Record: Off"
            let autoItem = NSMenuItem(title: autoLabel, action: #selector(toggleAutoRecording), keyEquivalent: "")
            autoItem.target = self
            menu.addItem(autoItem)
        }

        menu.addItem(NSMenuItem.separator())

        let listItem = NSMenuItem(title: "View Transcripts", action: #selector(openTranscripts), keyEquivalent: "")
        listItem.target = self
        menu.addItem(listItem)

        let configItem = NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    func setupRecordingMenu(meetingName: String, elapsed: String) {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Recording: \(meetingName)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Duration: \(elapsed)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "s")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit (stops recording)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc func showStartDialog() {
        let alert = NSAlert()
        alert.messageText = "Start Recording"
        alert.informativeText = "Enter a name for this recording:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        inputField.placeholderString = "Meeting Name"
        inputField.stringValue = "Meeting \(formatDate(Date()))"
        alert.accessoryView = inputField

        // Bring app to front
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let meetingName = inputField.stringValue.isEmpty ? "Untitled" : inputField.stringValue
            micTriggeredRecording = false  // Manual start - don't auto-stop based on mic
            autoStartedRecording = false
            startRecording(name: meetingName)
        }
    }

    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    func formatRelativeTime(_ date: Date) -> String {
        let now = Date()
        let seconds = Int(date.timeIntervalSince(now))

        if seconds < 0 {
            return "started"
        } else if seconds < 60 {
            return "in <1 min"
        } else if seconds < 3600 {
            let minutes = seconds / 60
            return "in \(minutes) min"
        } else {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "at \(formatter.string(from: date))"
        }
    }

    func enforceAutoRecordingTimeoutIfNeeded(state: RecordingState) {
        let config = ConfigManager.shared.loadConfig()
        guard autoStartedRecording else { return }
        guard config.maxAutoRecordingMinutes > 0 else { return }
        guard let startTimeStr = state.startTime else { return }
        guard let startTime = parseISO8601(startTimeStr) else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        let maxDuration = TimeInterval(config.maxAutoRecordingMinutes * 60)

        if elapsed >= maxDuration {
            micTriggeredRecording = false
            autoStartedRecording = false
            stopRecording()
        }
    }

    func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    @objc func startRecording(name: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Try paths in order of preference
        let wrapperPath = home.appendingPathComponent(".transcriptor/bin/transcriptor").path
        let bunBinPath = home.appendingPathComponent(".bun/bin/transcriptor").path

        var executablePath: String?
        var arguments: [String] = []

        if FileManager.default.fileExists(atPath: wrapperPath) {
            // Use the installed wrapper script
            executablePath = wrapperPath
            arguments = ["start", name]
        } else if FileManager.default.fileExists(atPath: bunBinPath) {
            // Use bun's global install
            executablePath = bunBinPath
            arguments = ["start", name]
        }

        guard let path = executablePath else {
            showError("Transcriptor CLI not found. Run install.sh first.")
            return
        }

        // Run in background using Process
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            showError("Failed to start recording: \(error.localizedDescription)")
        }
    }

    @objc func stopRecording() {
        autoStartedRecording = false
        // Write stop signal - the running CLI process watches for this
        let stopFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcriptor")
            .appendingPathComponent("stop-signal")

        try? "stop".write(to: stopFile, atomically: true, encoding: .utf8)
    }

    @objc func toggleAutoRecording() {
        var config = ConfigManager.shared.loadConfig()
        config.autoStartRecording = !config.autoStartRecording
        ConfigManager.shared.saveConfig(config)
        updateStatusItem() // Refresh menu
    }

    @objc func openTranscripts() {
        let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("transcripts")
        NSWorkspace.shared.open(transcriptsDir)
    }

    @objc func openConfig() {
        let configFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcriptor")
            .appendingPathComponent("config.json")
        NSWorkspace.shared.open(configFile)
    }

    @objc func quitApp() {
        // Stop recording if active
        let state = StateManager.shared.loadState()
        if state.isRecording {
            stopRecording()
            // Give it a moment to stop
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApplication.shared.terminate(nil)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    func setupSignalHandling() {
        signal(SIGINT) { _ in
            NSApplication.shared.terminate(nil)
        }
        signal(SIGTERM) { _ in
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // No dock icon
app.run()
