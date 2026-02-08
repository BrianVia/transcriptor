import Foundation

struct CalendarConfig: Codable {
    var calendarEnabled: Bool
    var autoStartRecording: Bool
    var reminderMinutesBefore: Int
    var onlyVideoMeetings: Bool
    var requireGoogleMeetLinkForCalendarAutoStart: Bool
    var excludedCalendars: [String]
    var excludedTitlePatterns: [String]

    // Microphone detection settings
    var microphoneDetectionEnabled: Bool
    var microphoneAutoStart: Bool
    var microphoneAutoStop: Bool
    var microphoneIdleDelaySeconds: Int  // How long to wait after mic goes idle before auto-stopping
    var maxAutoRecordingMinutes: Int  // Hard cap for unattended auto-start sessions

    // Existing config fields (optional for decoding flexibility)
    var audioRetentionDays: Int?
    var transcriptRetentionDays: Int?
    var deleteAudioAfterTranscript: Bool?
    var whisperModel: String?
    var chunkDurationSeconds: Int?

    static let defaults = CalendarConfig(
        calendarEnabled: true,
        autoStartRecording: true,
        reminderMinutesBefore: 1,
        onlyVideoMeetings: false,
        requireGoogleMeetLinkForCalendarAutoStart: true,
        excludedCalendars: [],
        excludedTitlePatterns: ["Focus", "Deep Work", "Do Not Disturb", "Blocked", "Busy", "Lunch", "Break", "OOO", "Out of Office", "Personal", "Hold"],
        microphoneDetectionEnabled: true,
        microphoneAutoStart: true,
        microphoneAutoStop: false,
        microphoneIdleDelaySeconds: 30,
        maxAutoRecordingMinutes: 120
    )

    init(
        calendarEnabled: Bool = true,
        autoStartRecording: Bool = true,
        reminderMinutesBefore: Int = 1,
        onlyVideoMeetings: Bool = false,
        requireGoogleMeetLinkForCalendarAutoStart: Bool = true,
        excludedCalendars: [String] = [],
        excludedTitlePatterns: [String] = ["Focus", "Deep Work", "Do Not Disturb", "Blocked", "Busy", "Lunch", "Break", "OOO", "Out of Office", "Personal", "Hold"],
        microphoneDetectionEnabled: Bool = true,
        microphoneAutoStart: Bool = true,
        microphoneAutoStop: Bool = false,
        microphoneIdleDelaySeconds: Int = 30,
        maxAutoRecordingMinutes: Int = 120
    ) {
        self.calendarEnabled = calendarEnabled
        self.autoStartRecording = autoStartRecording
        self.reminderMinutesBefore = reminderMinutesBefore
        self.onlyVideoMeetings = onlyVideoMeetings
        self.requireGoogleMeetLinkForCalendarAutoStart = requireGoogleMeetLinkForCalendarAutoStart
        self.excludedCalendars = excludedCalendars
        self.excludedTitlePatterns = excludedTitlePatterns
        self.microphoneDetectionEnabled = microphoneDetectionEnabled
        self.microphoneAutoStart = microphoneAutoStart
        self.microphoneAutoStop = microphoneAutoStop
        self.microphoneIdleDelaySeconds = microphoneIdleDelaySeconds
        self.maxAutoRecordingMinutes = maxAutoRecordingMinutes
    }

    // Custom decoding to handle missing fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.calendarEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarEnabled) ?? Self.defaults.calendarEnabled
        self.autoStartRecording = try container.decodeIfPresent(Bool.self, forKey: .autoStartRecording) ?? Self.defaults.autoStartRecording
        self.reminderMinutesBefore = try container.decodeIfPresent(Int.self, forKey: .reminderMinutesBefore) ?? Self.defaults.reminderMinutesBefore
        self.onlyVideoMeetings = try container.decodeIfPresent(Bool.self, forKey: .onlyVideoMeetings) ?? Self.defaults.onlyVideoMeetings
        self.requireGoogleMeetLinkForCalendarAutoStart = try container.decodeIfPresent(Bool.self, forKey: .requireGoogleMeetLinkForCalendarAutoStart) ?? Self.defaults.requireGoogleMeetLinkForCalendarAutoStart
        self.excludedCalendars = try container.decodeIfPresent([String].self, forKey: .excludedCalendars) ?? Self.defaults.excludedCalendars
        self.excludedTitlePatterns = try container.decodeIfPresent([String].self, forKey: .excludedTitlePatterns) ?? Self.defaults.excludedTitlePatterns

        // Microphone detection settings
        self.microphoneDetectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .microphoneDetectionEnabled) ?? Self.defaults.microphoneDetectionEnabled
        self.microphoneAutoStart = try container.decodeIfPresent(Bool.self, forKey: .microphoneAutoStart) ?? Self.defaults.microphoneAutoStart
        self.microphoneAutoStop = try container.decodeIfPresent(Bool.self, forKey: .microphoneAutoStop) ?? Self.defaults.microphoneAutoStop
        self.microphoneIdleDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .microphoneIdleDelaySeconds) ?? Self.defaults.microphoneIdleDelaySeconds
        self.maxAutoRecordingMinutes = try container.decodeIfPresent(Int.self, forKey: .maxAutoRecordingMinutes) ?? Self.defaults.maxAutoRecordingMinutes

        // Existing fields
        self.audioRetentionDays = try container.decodeIfPresent(Int.self, forKey: .audioRetentionDays)
        self.transcriptRetentionDays = try container.decodeIfPresent(Int.self, forKey: .transcriptRetentionDays)
        self.deleteAudioAfterTranscript = try container.decodeIfPresent(Bool.self, forKey: .deleteAudioAfterTranscript)
        self.whisperModel = try container.decodeIfPresent(String.self, forKey: .whisperModel)
        self.chunkDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .chunkDurationSeconds)
    }
}

class ConfigManager {
    static let shared = ConfigManager()

    private let configFile: URL
    private var cachedConfig: CalendarConfig?
    private var lastModified: Date?

    init() {
        configFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcriptor")
            .appendingPathComponent("config.json")
    }

    func loadConfig() -> CalendarConfig {
        // Check if file was modified since last read
        if let cached = cachedConfig,
           let lastMod = lastModified,
           let attrs = try? FileManager.default.attributesOfItem(atPath: configFile.path),
           let fileMod = attrs[.modificationDate] as? Date,
           fileMod <= lastMod {
            return cached
        }

        guard FileManager.default.fileExists(atPath: configFile.path),
              let data = try? Data(contentsOf: configFile) else {
            return CalendarConfig.defaults
        }

        do {
            let decoder = JSONDecoder()
            let config = try decoder.decode(CalendarConfig.self, from: data)
            cachedConfig = config
            lastModified = Date()
            return config
        } catch {
            // Config exists but parsing failed - return defaults
            return CalendarConfig.defaults
        }
    }

    func saveConfig(_ config: CalendarConfig) {
        // Read existing config to preserve non-calendar settings
        var existingData: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existingData = json
        }

        // Update calendar settings
        existingData["calendarEnabled"] = config.calendarEnabled
        existingData["autoStartRecording"] = config.autoStartRecording
        existingData["reminderMinutesBefore"] = config.reminderMinutesBefore
        existingData["onlyVideoMeetings"] = config.onlyVideoMeetings
        existingData["requireGoogleMeetLinkForCalendarAutoStart"] = config.requireGoogleMeetLinkForCalendarAutoStart
        existingData["excludedCalendars"] = config.excludedCalendars
        existingData["excludedTitlePatterns"] = config.excludedTitlePatterns

        // Update microphone detection settings
        existingData["microphoneDetectionEnabled"] = config.microphoneDetectionEnabled
        existingData["microphoneAutoStart"] = config.microphoneAutoStart
        existingData["microphoneAutoStop"] = config.microphoneAutoStop
        existingData["microphoneIdleDelaySeconds"] = config.microphoneIdleDelaySeconds
        existingData["maxAutoRecordingMinutes"] = config.maxAutoRecordingMinutes

        if let data = try? JSONSerialization.data(withJSONObject: existingData, options: .prettyPrinted) {
            try? data.write(to: configFile)
            cachedConfig = config
            lastModified = Date()
        }
    }

    func invalidateCache() {
        cachedConfig = nil
        lastModified = nil
    }
}
