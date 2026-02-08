import EventKit
import Foundation

struct UpcomingMeeting {
    let eventId: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isVideoMeeting: Bool
    let hasGoogleMeetLink: Bool
    let calendarTitle: String
}

class CalendarManager {
    static let shared = CalendarManager()

    let eventStore = EKEventStore()
    private(set) var accessGranted = false
    private var handledEventIds: Set<String> = []

    // MARK: - Authorization

    func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, error in
                DispatchQueue.main.async {
                    self.accessGranted = granted
                    completion(granted)
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                DispatchQueue.main.async {
                    self.accessGranted = granted
                    completion(granted)
                }
            }
        }
    }

    // MARK: - Meeting Detection

    func getUpcomingMeetings(within minutes: Int, config: CalendarConfig) -> [UpcomingMeeting] {
        guard accessGranted else { return [] }

        let now = Date()
        let lookAheadEnd = now.addingTimeInterval(TimeInterval(minutes * 60))

        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-60), // Include just-started meetings
            end: lookAheadEnd,
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)

        return events.compactMap { event -> UpcomingMeeting? in
            guard shouldTrackEvent(event, config: config) else { return nil }

            return UpcomingMeeting(
                eventId: event.eventIdentifier,
                title: event.title ?? "Untitled Meeting",
                startDate: event.startDate,
                endDate: event.endDate,
                isVideoMeeting: hasVideoConferenceLink(event),
                hasGoogleMeetLink: hasGoogleMeetLink(event),
                calendarTitle: event.calendar.title
            )
        }
    }

    // MARK: - Event Filtering

    private func shouldTrackEvent(_ event: EKEvent, config: CalendarConfig) -> Bool {
        // Skip all-day events
        if event.isAllDay {
            return false
        }

        // Skip events we've already handled
        if handledEventIds.contains(event.eventIdentifier) {
            return false
        }

        // Skip declined events
        if let attendees = event.attendees {
            for attendee in attendees where attendee.isCurrentUser {
                if attendee.participantStatus == .declined {
                    return false
                }
            }
        }

        // Skip cancelled events
        if event.status == .canceled {
            return false
        }

        // Skip excluded calendars
        if config.excludedCalendars.contains(event.calendar.title) {
            return false
        }

        // Skip events matching excluded title patterns
        let lowercaseTitle = (event.title ?? "").lowercased()
        for pattern in config.excludedTitlePatterns {
            if lowercaseTitle.contains(pattern.lowercased()) {
                return false
            }
        }

        // If only video meetings, check for video link
        if config.onlyVideoMeetings && !hasVideoConferenceLink(event) {
            return false
        }

        return true
    }

    private func hasVideoConferenceLink(_ event: EKEvent) -> Bool {
        let videoPatterns = [
            "zoom.us", "zoom.com",
            "meet.google.com",
            "teams.microsoft.com", "teams.live.com",
            "webex.com",
            "whereby.com",
            "around.co",
            "tuple.app",
            "pop.com",
            "loom.com"
        ]

        return hasConferenceLink(event, matchingAnyDomain: videoPatterns)
    }

    private func hasGoogleMeetLink(_ event: EKEvent) -> Bool {
        hasConferenceLink(event, matchingAnyDomain: ["meet.google.com"])
    }

    private func hasConferenceLink(_ event: EKEvent, matchingAnyDomain domains: [String]) -> Bool {
        let links = extractConferenceLinks(from: event)
        let normalizedDomains = domains.map { $0.lowercased() }

        for link in links {
            guard let url = URL(string: link), let host = url.host?.lowercased() else {
                continue
            }

            if normalizedDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                return true
            }
        }
        return false
    }

    private func extractConferenceLinks(from event: EKEvent) -> [String] {
        var links: [String] = []

        if let url = event.url?.absoluteString {
            links.append(url)
        }

        if let notes = event.notes {
            links.append(contentsOf: extractLinks(from: notes))
        }

        if let location = event.location {
            links.append(contentsOf: extractLinks(from: location))
        }

        return links
    }

    private func extractLinks(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let nsText = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { $0.url?.absoluteString }
    }

    // MARK: - Event Tracking

    func markEventAsHandled(_ eventId: String) {
        handledEventIds.insert(eventId)
    }

    func isEventHandled(_ eventId: String) -> Bool {
        return handledEventIds.contains(eventId)
    }

    func clearHandledEvents() {
        handledEventIds.removeAll()
    }

    // Clean up old event IDs periodically
    func cleanupOldEventIds() {
        if handledEventIds.count > 100 {
            handledEventIds = Set(Array(handledEventIds).suffix(50))
        }
    }
}
