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

        if config.autoStartRecording {
            // Auto-start recording without dialog
            startRecording(name: meeting.title)
        } else {
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

    // MARK: - UI Updates

    func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let state = StateManager.shared.loadState()

        if state.isRecording {
            // Recording state - blinking red dot with timer
            isBlinking.toggle()

            let meetingName = state.meetingName ?? "Recording"
            let elapsed = StateManager.shared.getElapsedTime() ?? "0:00"

            // Use SF Symbol for waveform with red recording dot
            if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Recording") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = image.withSymbolConfiguration(config)
                button.image?.isTemplate = true
            }

            // Show recording indicator
            let dot = isBlinking ? "●" : "○"
            button.title = " \(dot) \(elapsed)"
            button.imagePosition = .imageLeft

            setupRecordingMenu(meetingName: meetingName, elapsed: elapsed)
        } else {
            // Idle state - clean waveform icon
            if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcriptor") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                button.image = image.withSymbolConfiguration(config)
                button.image?.isTemplate = true
            }
            button.title = ""
            button.imagePosition = .imageOnly

            setupIdleMenu()
        }
    }

    func setupIdleMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Transcriptor", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Show upcoming meeting if any
        let config = ConfigManager.shared.loadConfig()
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

        // Calendar toggle if enabled
        if config.calendarEnabled {
            let autoLabel = config.autoStartRecording ? "Auto-Record: On" : "Auto-Record: Off"
            let autoItem = NSMenuItem(title: autoLabel, action: #selector(toggleAutoRecording), keyEquivalent: "")
            autoItem.target = self
            menu.addItem(autoItem)
            menu.addItem(NSMenuItem.separator())
        }

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

    @objc func startRecording(name: String) {
        // Run transcriptor start in background
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")

        // Use login shell to get user's PATH, or fall back to common locations
        let transcriptorPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bun/bin/transcriptor").path
        task.arguments = ["-c", "\"\(transcriptorPath)\" start \"\(name)\" &"]

        do {
            try task.run()
        } catch {
            showError("Failed to start recording: \(error.localizedDescription)")
        }
    }

    @objc func stopRecording() {
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
