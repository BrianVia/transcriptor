import EventKit
import Foundation

struct UpcomingMeeting {
    let eventId: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isVideoMeeting: Bool
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

        // Check URL field
        if let url = event.url?.absoluteString.lowercased() {
            if videoPatterns.contains(where: { url.contains($0) }) {
                return true
            }
        }

        // Check notes/description
        if let notes = event.notes?.lowercased() {
            if videoPatterns.contains(where: { notes.contains($0) }) {
                return true
            }
        }

        // Check location (Zoom often puts link in location)
        if let location = event.location?.lowercased() {
            if videoPatterns.contains(where: { location.contains($0) }) {
                return true
            }
        }

        return false
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
