import AppKit
import EventKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcriptor.indicator", category: "AppDelegate")

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
    private let ioQueue = DispatchQueue(label: "com.transcriptor.state-io", qos: .utility)

    // Cached state updated from background queue — always safe to read from main thread
    private(set) var cachedState = RecordingState(isRecording: false)
    private(set) var cachedElapsedTime: String?

    // Reusable formatters (creating these is expensive)
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        transcriptorDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcriptor")
        stateFile = transcriptorDir.appendingPathComponent("state.json")
    }

    /// Reads state.json on a background queue and updates cached values.
    /// Calls the completion on the main queue when done.
    func refreshState(completion: @escaping () -> Void) {
        ioQueue.async { [self] in
            let state: RecordingState
            if FileManager.default.fileExists(atPath: stateFile.path),
               let data = try? Data(contentsOf: stateFile),
               let decoded = try? JSONDecoder().decode(RecordingState.self, from: data) {
                state = decoded
            } else {
                state = RecordingState(isRecording: false)
            }

            let elapsed = Self.computeElapsed(state: state, isoFormatter: isoFormatter, isoFormatterNoFrac: isoFormatterNoFrac)

            DispatchQueue.main.async {
                self.cachedState = state
                self.cachedElapsedTime = elapsed
                completion()
            }
        }
    }

    private static func computeElapsed(state: RecordingState, isoFormatter: ISO8601DateFormatter, isoFormatterNoFrac: ISO8601DateFormatter) -> String? {
        guard state.isRecording, let startTimeStr = state.startTime else { return nil }
        guard let startTime = isoFormatter.date(from: startTimeStr) ?? isoFormatterNoFrac.date(from: startTimeStr) else { return nil }

        let elapsed = Int(Date().timeIntervalSince(startTime))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct MeetingAppContext {
        let appName: String
        let recordingName: String
        let reason: String
    }

    private let knownMeetingApps: [(bundleID: String, appName: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.slack.Slack", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
    ]

    private let slackBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.slack.Slack",
    ]

    private let ignoredVoiceInputBundleIDs: Set<String> = [
        "com.electron.wispr-flow",
        "com.electron.wispr-flow.accessibility-mac-app",
        "com.electron.wispr-flow.helper",
    ]

    private let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
    ]

    var statusItem: NSStatusItem?
    var timer: Timer?
    var calendarTimer: Timer?
    var isBlinking = false

    // Cache for upcoming meeting display
    var cachedNextMeeting: UpcomingMeeting?

    // Live transcript sidebar state
    var transcriptPanel: NSPanel?
    var transcriptTextView: NSTextView?
    var transcriptPanelOutputDir: String?
    var transcriptPanelLastModified: Date?
    var transcriptPanelLastSize: Int64?
    var transcriptPanelTranscriptPath: String?
    let transcriptPlaceholderText = "Waiting for transcript…\n\nTranscript will appear here as chunks finish."
    let transcriptMaxLines = 250

    // Track if we started recording via mic detection (for auto-stop)
    var micTriggeredRecording = false
    var autoStartedRecording = false
    var micAutoStopTimer: Timer?

    // Track last known recording state to avoid rebuilding menu unnecessarily
    // Starts as nil so the first updateStatusItem() call always sets up the icon/menu
    private var lastKnownRecordingState: Bool?
    private var lastKnownTranscriptPanelVisibility: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent macOS from auto-terminating this windowless accessory app
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar indicator must remain running")
        ProcessInfo.processInfo.disableSuddenTermination()

        logger.notice("Transcriptor indicator starting up")

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateStatusItem()

        // Update timer - refresh state from disk (background) every second, then update UI
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            StateManager.shared.refreshState {
                self?.updateStatusItem()
                self?.refreshLiveTranscriptPanelIfNeeded()
            }
        }

        // Setup signal handling
        setupSignalHandling()

        // Setup calendar integration
        let config = ConfigManager.shared.loadConfig()
        logger.notice("Config loaded — calendar: \(config.calendarEnabled), micDetection: \(config.microphoneDetectionEnabled), micAutoStart: \(config.microphoneAutoStart)")
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
        let state = StateManager.shared.cachedState
        if state.isRecording {
            cachedNextMeeting = nil
            return
        }

        // Look ahead far enough: reminder window + 5 minutes for late joins + buffer
        let lookAheadMinutes = max(config.reminderMinutesBefore + 1, 10)
        let meetings = CalendarManager.shared.getUpcomingMeetings(
            within: lookAheadMinutes,
            config: config
        )

        let now = Date()
        let sortedMeetings = meetings.sorted { $0.startDate < $1.startDate }

        if !sortedMeetings.isEmpty {
            let descriptions = sortedMeetings.map { m in
                let delta = Int(m.startDate.timeIntervalSince(now))
                return "\(m.title) (\(delta)s, meet=\(m.hasGoogleMeetLink), video=\(m.isVideoMeeting))"
            }
            logger.notice("Calendar check: \(descriptions.joined(separator: "; "), privacy: .public)")
        }

        // For menu display: only show meetings that haven't started yet
        cachedNextMeeting = sortedMeetings.first { $0.startDate > now }

        // For auto-start: check if any meeting is within the start window
        // Allow up to 5 minutes after scheduled start (late joins) and 60s before
        for meeting in sortedMeetings {
            let timeUntilStart = meeting.startDate.timeIntervalSince(now)
            if timeUntilStart <= 60 && timeUntilStart >= -300 {
                if config.autoStartRecording &&
                    config.requireGoogleMeetLinkForCalendarAutoStart &&
                    !meeting.hasGoogleMeetLink {
                    logger.notice("Skipping auto-start for '\(meeting.title, privacy: .public)': no Google Meet link")
                    continue
                }
                logger.notice("Auto-starting for '\(meeting.title, privacy: .public)' (delta: \(Int(timeUntilStart))s)")
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

        let state = StateManager.shared.cachedState
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
        let state = StateManager.shared.cachedState

        logger.notice("Mic activity changed: active=\(isActive), autoStart=\(config.microphoneAutoStart), isRecording=\(state.isRecording)")

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
        guard let meetingContext = detectMeetingAppContext(config: config) else {
            logger.notice("Mic activation ignored because no supported meeting context was found")
            return
        }

        if let nearbyMeeting = nearestCalendarMeeting(config: config) {
            let timeUntilStart = nearbyMeeting.startDate.timeIntervalSince(Date())
            if timeUntilStart <= 300 && timeUntilStart >= -300 {
                CalendarManager.shared.markEventAsHandled(nearbyMeeting.eventId)
                cachedNextMeeting = nil
            }
        }

        // Mark as mic-triggered for auto-stop tracking
        micTriggeredRecording = true
        autoStartedRecording = true

        logger.notice("Mic activation matched app context: app=\(meetingContext.appName, privacy: .public), reason=\(meetingContext.reason, privacy: .public), recordingName=\(meetingContext.recordingName, privacy: .public)")

        // Show brief notification and start recording
        showMicrophoneDetectedNotification(meetingName: meetingContext.recordingName)
        startRecording(name: meetingContext.recordingName)

        // Refresh the meeting cache
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshUpcomingMeetingCache()
        }
    }

    func handleMicrophoneAutoStop() {
        let state = StateManager.shared.cachedState
        guard state.isRecording && micTriggeredRecording else { return }

        // Verify mic is still idle
        if !MicrophoneMonitor.shared.isMicrophoneInUse {
            micTriggeredRecording = false
            autoStartedRecording = false
            stopRecording()
        }
    }

    func showMicrophoneDetectedNotification(meetingName: String) {
        let escaped = meetingName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"Microphone detected. Recording: \(escaped)\" with title \"Recording Started\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    private func detectMeetingAppContext(config: CalendarConfig) -> MeetingAppContext? {
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let nearbyMeeting = nearestCalendarMeeting(config: config)
        let nearbyGoogleMeetMeeting = nearestCalendarMeeting(config: config, requireGoogleMeetLink: true)
        let hasNearbyMeeting = nearbyMeeting != nil

        if let frontmostBundleID, ignoredVoiceInputBundleIDs.contains(frontmostBundleID) {
            logger.notice("Ignoring mic activation because frontmost app is excluded voice input app: \(frontmostBundleID, privacy: .public)")
            return nil
        }

        if let frontmostBundleID, slackBundleIDs.contains(frontmostBundleID) {
            let recordingName = nearbyMeeting?.title ?? "Slack Huddle \(formatDate(Date()))"
            return MeetingAppContext(
                appName: "Slack",
                recordingName: recordingName,
                reason: "slack-frontmost"
            )
        }

        if hasNearbyMeeting && !runningBundleIDs.isDisjoint(with: slackBundleIDs) {
            let recordingName = nearbyMeeting?.title ?? "Slack Huddle \(formatDate(Date()))"
            return MeetingAppContext(
                appName: "Slack",
                recordingName: recordingName,
                reason: "slack-running-near-calendar-meeting"
            )
        }

        if let frontmostBundleID,
           let frontmostMeetingApp = knownMeetingApps.first(where: { $0.bundleID == frontmostBundleID }) {
            let recordingName = nearbyMeeting?.title ?? "\(frontmostMeetingApp.appName) Call \(formatDate(Date()))"
            return MeetingAppContext(
                appName: frontmostMeetingApp.appName,
                recordingName: recordingName,
                reason: "frontmost-meeting-app"
            )
        }

        if hasNearbyMeeting {
            for meetingApp in knownMeetingApps where !slackBundleIDs.contains(meetingApp.bundleID) {
                if runningBundleIDs.contains(meetingApp.bundleID) {
                    let recordingName = nearbyMeeting?.title ?? "\(meetingApp.appName) Call \(formatDate(Date()))"
                    return MeetingAppContext(
                        appName: meetingApp.appName,
                        recordingName: recordingName,
                        reason: "known-meeting-app-running-near-calendar-meeting"
                    )
                }
            }
        }

        if let frontmostBundleID,
           browserBundleIDs.contains(frontmostBundleID),
           let googleMeetMeeting = nearbyGoogleMeetMeeting {
            return MeetingAppContext(
                appName: "Google Meet",
                recordingName: googleMeetMeeting.title,
                reason: "google-meet-frontmost-browser"
            )
        }

        if let googleMeetMeeting = nearbyGoogleMeetMeeting,
           !runningBundleIDs.isDisjoint(with: browserBundleIDs),
           hasNearbyMeeting {
            return MeetingAppContext(
                appName: "Google Meet",
                recordingName: googleMeetMeeting.title,
                reason: "google-meet-near-calendar-meeting-browser-running"
            )
        }

        if let nearbyMeeting,
           nearbyMeeting.isVideoMeeting,
           let frontmostBundleID,
           browserBundleIDs.contains(frontmostBundleID) {
            return MeetingAppContext(
                appName: "Calendar Meeting",
                recordingName: nearbyMeeting.title,
                reason: "nearby-video-calendar-meeting-frontmost-browser"
            )
        }

        return nil
    }

    private func nearestCalendarMeeting(config: CalendarConfig, requireGoogleMeetLink: Bool = false) -> UpcomingMeeting? {
        guard config.calendarEnabled else { return nil }

        let meetings = CalendarManager.shared.getUpcomingMeetings(within: 10, config: config)
        let now = Date()

        return meetings
            .filter { meeting in
                let delta = meeting.startDate.timeIntervalSince(now)
                guard delta <= 300 && delta >= -300 else { return false }
                return !requireGoogleMeetLink || meeting.hasGoogleMeetLink
            }
            .sorted { lhs, rhs in
                abs(lhs.startDate.timeIntervalSince(now)) < abs(rhs.startDate.timeIntervalSince(now))
            }
            .first
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

        let state = StateManager.shared.cachedState
        let stateChanged = state.isRecording != lastKnownRecordingState
        let transcriptPanelVisibility = isTranscriptPanelVisible
        let transcriptPanelVisibilityChanged = transcriptPanelVisibility != lastKnownTranscriptPanelVisibility

        if state.isRecording {
            enforceAutoRecordingTimeoutIfNeeded(state: state)

            // Recording state - blinking red dot with timer
            isBlinking.toggle()

            let meetingName = state.meetingName ?? "Recording"
            let elapsed = StateManager.shared.cachedElapsedTime ?? "0:00"

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

            // Surface the live transcript automatically when a recording starts.
            if stateChanged {
                showTranscriptPanel(activate: false)
            }

            if stateChanged || transcriptPanelVisibilityChanged {
                setupRecordingMenu(meetingName: meetingName, elapsed: elapsed)
                lastKnownRecordingState = true
                lastKnownTranscriptPanelVisibility = isTranscriptPanelVisible
            }
        } else {
            if stateChanged {
                micTriggeredRecording = false
                autoStartedRecording = false
                hideTranscriptPanel()
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
                lastKnownTranscriptPanelVisibility = nil
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

        let transcriptTitle = isTranscriptPanelVisible ? "Hide Live Transcript" : "Show Live Transcript"
        let transcriptItem = NSMenuItem(title: transcriptTitle, action: #selector(toggleLiveTranscriptPanel), keyEquivalent: "")
        transcriptItem.target = self
        menu.addItem(transcriptItem)
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

    // MARK: - Live Transcript Panel

    private var isTranscriptPanelVisible: Bool {
        transcriptPanel?.isVisible == true
    }

    @objc func toggleLiveTranscriptPanel() {
        if isTranscriptPanelVisible {
            hideTranscriptPanel()
        } else {
            showTranscriptPanel()
        }

        updateStatusItem()
    }

    private func showTranscriptPanel(activate: Bool = true) {
        ensureTranscriptPanel()
        if let panel = transcriptPanel {
            panel.level = .floating
            if activate {
                panel.makeKeyAndOrderFront(nil)
                panel.orderFrontRegardless()
            } else {
                panel.orderFront(nil)
            }
            refreshLiveTranscriptPanel(force: true)
        }
    }

    private func hideTranscriptPanel() {
        transcriptPanel?.orderOut(nil)
    }

    private func ensureTranscriptPanel() {
        guard transcriptPanel == nil else { return }

        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 360)
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Live Transcript"
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let scrollView = NSScrollView(frame: panel.contentView?.bounds ?? contentRect)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = transcriptPlaceholderText

        scrollView.documentView = textView
        scrollView.contentView.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: 1))

        if let contentView = panel.contentView {
            contentView.addSubview(scrollView)
        }

        transcriptPanel = panel
        transcriptTextView = textView
    }

    private func refreshLiveTranscriptPanelIfNeeded() {
        guard isTranscriptPanelVisible else { return }
        refreshLiveTranscriptPanel()
    }

    private func transcriptFileURL() -> URL? {
        let state = StateManager.shared.cachedState
        if let outputDir = state.outputDir {
            transcriptPanelOutputDir = outputDir
        }
        if let outputDir = transcriptPanelOutputDir {
            let filePath = URL(fileURLWithPath: outputDir).appendingPathComponent("transcript.md")
            if transcriptPanelTranscriptPath != filePath.path {
                transcriptPanelTranscriptPath = filePath.path
                transcriptPanelLastModified = nil
                transcriptPanelLastSize = nil
            }
            return filePath
        }
        return nil
    }

    private func refreshLiveTranscriptPanel(force: Bool = false) {
        guard isTranscriptPanelVisible else { return }
        guard transcriptTextView != nil else { return }

        guard let fileURL = transcriptFileURL() else {
            transcriptPanelLastModified = nil
            setTranscriptText(transcriptPlaceholderText)
            return
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modifiedDate = attrs[.modificationDate] as? Date,
              let fileSize = attrs[.size] as? NSNumber else {
            if transcriptPanelLastModified == nil {
                setTranscriptText(transcriptPlaceholderText)
            }
            return
        }
        let fileSizeValue = fileSize.int64Value

        if !force && transcriptPanelLastModified == modifiedDate && transcriptPanelLastSize == fileSizeValue {
            return
        }
        transcriptPanelLastModified = modifiedDate
        transcriptPanelLastSize = fileSizeValue

        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            if transcriptPanelLastModified == nil {
                setTranscriptText(transcriptPlaceholderText)
            }
            return
        }

        let displayText = formatTranscriptForDisplay(contents)
        if displayText.isEmpty {
            setTranscriptText("Waiting for transcript to be generated…")
            return
        }

        setTranscriptText(displayText)
    }

    private func setTranscriptText(_ text: String) {
        guard let textView = transcriptTextView else { return }
        if textView.string == text { return }
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }

    private func formatTranscriptForDisplay(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        var index = 0

        if lines.first == "---" {
            index = 1
            while index < lines.count && lines[index] != "---" {
                index += 1
            }
            if index < lines.count {
                index += 1
            }
        }

        if index < lines.count && lines[index].hasPrefix("# ") {
            index += 1
        }

        while index < lines.count && lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }

        guard index < lines.count else { return "" }

        var contentLines = Array(lines[index...])
        if contentLines.count > transcriptMaxLines {
            contentLines = Array(contentLines.suffix(transcriptMaxLines))
            return "…\n\n" + contentLines.joined(separator: "\n")
        }

        return contentLines.joined(separator: "\n")
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
        let wrapperPath = home.appendingPathComponent(".transcriptor/bin/transcriptor").path

        guard FileManager.default.fileExists(atPath: wrapperPath) else {
            showError("Transcriptor CLI not found at \(wrapperPath). Run install.sh first.")
            return
        }

        let escapedName = name.replacingOccurrences(of: "'", with: "'\\''")
        logger.notice("Starting recording: \(name, privacy: .public) via \(wrapperPath, privacy: .public)")

        // Launch via /bin/zsh so the wrapper script's shebang and PATH setup work
        // even from a LaunchAgent with minimal environment
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "'\(wrapperPath)' start '\(escapedName)' &"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            logger.notice("Failed to start recording: \(error.localizedDescription, privacy: .public)")
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
        let state = StateManager.shared.cachedState
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

    func windowWillClose(_ notification: Notification) {
        guard let closedPanel = notification.object as? NSPanel,
              closedPanel == transcriptPanel else { return }

        updateStatusItem()
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
