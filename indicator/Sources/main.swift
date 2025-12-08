import AppKit
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
    var isBlinking = false

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
    }

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

        let startItem = NSMenuItem(title: "Start Recording...", action: #selector(showStartDialog), keyEquivalent: "r")
        startItem.target = self
        menu.addItem(startItem)

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

    @objc func startRecording(name: String) {
        // Run transcriptor start in background
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "transcriptor start \"\(name)\" &"]

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
