import Foundation

struct CalendarConfig: Codable {
    var calendarEnabled: Bool
    var autoStartRecording: Bool
    var reminderMinutesBefore: Int
    var onlyVideoMeetings: Bool
    var excludedCalendars: [String]
    var excludedTitlePatterns: [String]

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
        excludedCalendars: [],
        excludedTitlePatterns: ["Focus", "Deep Work", "Do Not Disturb", "Blocked", "Busy", "Lunch", "Break", "OOO", "Out of Office", "Personal", "Hold"]
    )

    init(
        calendarEnabled: Bool = true,
        autoStartRecording: Bool = true,
        reminderMinutesBefore: Int = 1,
        onlyVideoMeetings: Bool = false,
        excludedCalendars: [String] = [],
        excludedTitlePatterns: [String] = ["Focus", "Deep Work", "Do Not Disturb", "Blocked", "Busy", "Lunch", "Break", "OOO", "Out of Office", "Personal", "Hold"]
    ) {
        self.calendarEnabled = calendarEnabled
        self.autoStartRecording = autoStartRecording
        self.reminderMinutesBefore = reminderMinutesBefore
        self.onlyVideoMeetings = onlyVideoMeetings
        self.excludedCalendars = excludedCalendars
        self.excludedTitlePatterns = excludedTitlePatterns
    }

    // Custom decoding to handle missing fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.calendarEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarEnabled) ?? Self.defaults.calendarEnabled
        self.autoStartRecording = try container.decodeIfPresent(Bool.self, forKey: .autoStartRecording) ?? Self.defaults.autoStartRecording
        self.reminderMinutesBefore = try container.decodeIfPresent(Int.self, forKey: .reminderMinutesBefore) ?? Self.defaults.reminderMinutesBefore
        self.onlyVideoMeetings = try container.decodeIfPresent(Bool.self, forKey: .onlyVideoMeetings) ?? Self.defaults.onlyVideoMeetings
        self.excludedCalendars = try container.decodeIfPresent([String].self, forKey: .excludedCalendars) ?? Self.defaults.excludedCalendars
        self.excludedTitlePatterns = try container.decodeIfPresent([String].self, forKey: .excludedTitlePatterns) ?? Self.defaults.excludedTitlePatterns

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
        existingData["excludedCalendars"] = config.excludedCalendars
        existingData["excludedTitlePatterns"] = config.excludedTitlePatterns

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
