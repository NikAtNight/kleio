import AppKit
import EventKit
import Foundation
@preconcurrency import UserNotifications

struct Meeting: Identifiable, Equatable {
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let calendarIdentifier: String
    let calendarTitle: String
    let calendarColor: NSColor
    let joinURL: URL?
    let attendeeCount: Int

    var id: String { "\(eventID)-\(start.timeIntervalSince1970)" }

    static func == (lhs: Meeting, rhs: Meeting) -> Bool {
        lhs.eventID == rhs.eventID &&
        lhs.title == rhs.title &&
        lhs.start == rhs.start &&
        lhs.end == rhs.end &&
        lhs.calendarIdentifier == rhs.calendarIdentifier &&
        lhs.calendarTitle == rhs.calendarTitle &&
        lhs.calendarColor.isEqual(rhs.calendarColor) &&
        lhs.joinURL == rhs.joinURL &&
        lhs.attendeeCount == rhs.attendeeCount
    }
}

enum MeetingDetector {
    private static let conferencePattern = #"(?i)(?:https?://)?(?:[a-z0-9-]+\.)?(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com)(?:/[^\s<>\]\[\"']*)?|facetime:(?://)?[^\s<>\]\[\"']+"#

    static func firstConferenceURL(url: String?, location: String?, notes: String?) -> URL? {
        firstConferenceURL(in: [url, location, notes].compactMap { $0 })
    }

    static func firstConferenceURL(in strings: [String]) -> URL? {
        let expression = try? NSRegularExpression(pattern: conferencePattern)
        for string in strings {
            let range = NSRange(string.startIndex..., in: string)
            guard let match = expression?.firstMatch(in: string, range: range),
                  let matchRange = Range(match.range, in: string) else { continue }
            var value = String(string[matchRange])
            if !value.lowercased().hasPrefix("http") && !value.lowercased().hasPrefix("facetime:") {
                value = "https://\(value)"
            }
            if let result = URL(string: value) {
                return result
            }
        }
        return nil
    }

    static func qualifies(joinURL: URL?, attendeeCount: Int, onlyWithLinks: Bool) -> Bool {
        joinURL != nil || (!onlyWithLinks && attendeeCount >= 2)
    }
}

@MainActor
final class CalendarSync: NSObject, ObservableObject {
    static let syncEnabledKey = "calendarSyncEnabled"
    static let leadMinutesKey = "calendarLeadMinutes"
    static let selectedIDsKey = "calendarSelectedIDs"
    static let onlyWithLinksKey = "calendarOnlyWithLinks"
    static let autoRecordEnabledKey = "autoRecordEnabled"
    static let autoRecordCalendarIDsKey = "autoRecordCalendarIDs"
    static let autoRecordLateJoinMinutesKey = "autoRecordLateJoinMinutes"
    static let autoRecordGraceMinutesKey = "autoRecordGraceMinutes"
    static let autoRecordSilenceMinutesKey = "autoRecordSilenceMinutes"
    static let autoRecordEventOverridesKey = "autoRecordEventOverrides"
    static let autoRecordConsentShownKey = "autoRecordConsentShown"
    static let autoRecordStoreEventDetailsKey = "autoRecordStoreEventDetails"

    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var availableCalendars: [EKCalendar] = []
    @Published private(set) var upcomingMeetings: [Meeting] = []
    @Published private(set) var autoRecordProblem: String?

    private let eventStore = EKEventStore()
    private let defaults: UserDefaults
    private var refreshTimer: Timer?
    private var fetchedMeetings: [Meeting] = []

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.syncEnabledKey) }
        set {
            defaults.set(newValue, forKey: Self.syncEnabledKey)
            if newValue {
                Task { await enableAndRefresh() }
            } else {
                upcomingMeetings = []
                removeCalendarNotifications()
            }
        }
    }

    var leadMinutes: Int {
        get {
            let value = defaults.object(forKey: Self.leadMinutesKey) as? Int
            return value ?? 2
        }
        set {
            defaults.set(newValue, forKey: Self.leadMinutesKey)
            refresh()
        }
    }

    var selectedCalendarIDs: [String] {
        get { defaults.stringArray(forKey: Self.selectedIDsKey) ?? [] }
        set {
            defaults.set(newValue, forKey: Self.selectedIDsKey)
            refresh()
        }
    }

    var onlyWithLinks: Bool {
        get { defaults.object(forKey: Self.onlyWithLinksKey) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Self.onlyWithLinksKey)
            refresh()
        }
    }

    var autoRecordEnabled: Bool {
        get { defaults.bool(forKey: Self.autoRecordEnabledKey) }
        set {
            defaults.set(newValue, forKey: Self.autoRecordEnabledKey)
            if newValue { autoRecordProblem = nil }
            if newValue {
                Task { await enableAndRefresh() }
            } else {
                refresh()
            }
        }
    }

    var autoRecordCalendarIDs: [String] {
        get { defaults.stringArray(forKey: Self.autoRecordCalendarIDsKey) ?? [] }
        set {
            defaults.set(newValue, forKey: Self.autoRecordCalendarIDsKey)
            refresh()
        }
    }

    var autoRecordLateJoinMinutes: Int {
        get { defaults.object(forKey: Self.autoRecordLateJoinMinutesKey) as? Int ?? 15 }
        set { defaults.set(newValue, forKey: Self.autoRecordLateJoinMinutesKey) }
    }

    var autoRecordGraceMinutes: Int {
        get { defaults.object(forKey: Self.autoRecordGraceMinutesKey) as? Int ?? 5 }
        set { defaults.set(newValue, forKey: Self.autoRecordGraceMinutesKey) }
    }

    var autoRecordSilenceMinutes: Int {
        get { defaults.object(forKey: Self.autoRecordSilenceMinutesKey) as? Int ?? 3 }
        set { defaults.set(newValue, forKey: Self.autoRecordSilenceMinutesKey) }
    }

    var hasShownAutoRecordConsent: Bool {
        get { defaults.bool(forKey: Self.autoRecordConsentShownKey) }
        set { defaults.set(newValue, forKey: Self.autoRecordConsentShownKey) }
    }

    var storesAutoRecordEventDetails: Bool {
        get { defaults.object(forKey: Self.autoRecordStoreEventDetailsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoRecordStoreEventDetailsKey) }
    }

    var autoRecordConfiguration: AutoRecordConfiguration {
        AutoRecordConfiguration(
            enabled: isEnabled && autoRecordEnabled && authorizationStatus == .fullAccess,
            leadMinutes: leadMinutes,
            lateJoinMinutes: autoRecordLateJoinMinutes,
            graceMinutes: autoRecordGraceMinutes,
            silenceMinutes: autoRecordSilenceMinutes
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreChanged),
            name: .EKEventStoreChanged,
            object: eventStore
        )
    }

    func start() {
        guard isEnabled else { return }
        refresh()
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func refresh() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard isEnabled, authorizationStatus == .fullAccess else {
            upcomingMeetings = []
            fetchedMeetings = []
            return
        }

        availableCalendars = eventStore.calendars(for: .event).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let enabledIDs = Set(selectedCalendarIDs)
        let autoIDs = Set(autoRecordCalendarIDs)
        let displayedCalendars = enabledIDs.isEmpty ? availableCalendars : availableCalendars.filter { enabledIDs.contains($0.calendarIdentifier) }
        let fetchedCalendarIDs = Set(displayedCalendars.map(\.calendarIdentifier)).union(autoIDs)
        let calendars = availableCalendars.filter { fetchedCalendarIDs.contains($0.calendarIdentifier) }
        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-TimeInterval(autoRecordLateJoinMinutes * 60)),
            end: now.addingTimeInterval(7 * 24 * 60 * 60),
            calendars: calendars
        )
        fetchedMeetings = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && !isDeclined($0) && $0.status != .canceled }
            .compactMap(makeMeeting)
            .sorted { $0.start < $1.start }
        let displayedCalendarIDs = Set(displayedCalendars.map(\.calendarIdentifier))
        upcomingMeetings = fetchedMeetings.filter { meeting in
            meeting.end >= now && displayedCalendarIDs.contains(meeting.calendarIdentifier)
        }
        scheduleNotifications(now: now)
    }

    func autoRecordMeetings(at now: Date) -> [AutoRecordEvent] {
        guard autoRecordEnabled else { return [] }
        let enabledCalendarIDs = Set(autoRecordCalendarIDs)
        return fetchedMeetings.compactMap { meeting in
            let override = autoRecordOverride(for: meeting.eventID)
            guard override ?? enabledCalendarIDs.contains(meeting.calendarIdentifier) else { return nil }
            let armDate = meeting.start.addingTimeInterval(-TimeInterval(leadMinutes * 60))
            let expiry = meeting.start.addingTimeInterval(TimeInterval(autoRecordLateJoinMinutes * 60))
            guard now >= armDate && now <= expiry else { return nil }
            return AutoRecordEvent(
                eventID: meeting.eventID,
                title: meeting.title,
                start: meeting.start,
                end: meeting.end,
                joinURL: meeting.joinURL
            )
        }
    }

    func autoRecordOverride(for eventID: String) -> Bool? {
        guard let value = defaults.dictionary(forKey: Self.autoRecordEventOverridesKey)?[eventID] else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    func setAutoRecordOverride(_ value: Bool?, for eventID: String) {
        var overrides = defaults.dictionary(forKey: Self.autoRecordEventOverridesKey) ?? [:]
        overrides[eventID] = value
        defaults.set(overrides, forKey: Self.autoRecordEventOverridesKey)
    }

    func autoRecordIsEnabled(for meeting: Meeting) -> Bool {
        autoRecordOverride(for: meeting.eventID) ?? autoRecordCalendarIDs.contains(meeting.calendarIdentifier)
    }

    func suspendAutoRecord(with problem: String) {
        autoRecordProblem = problem
        defaults.set(false, forKey: Self.autoRecordEnabledKey)
    }

    func handleNotificationAction(identifier: String, userInfo: [AnyHashable: Any]) {
        guard identifier == "MEETING_JOIN",
              let rawURL = userInfo["joinURL"] as? String,
              let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func enableAndRefresh() async {
        requestNotificationAuthorization()
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus == .notDetermined {
            do {
                try await eventStore.requestFullAccessToEvents()
            } catch {
                authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                return
            }
        }
        start()
    }

    private func makeMeeting(_ event: EKEvent) -> Meeting? {
        let joinURL = MeetingDetector.firstConferenceURL(
            url: event.url?.absoluteString,
            location: event.location,
            notes: event.notes
        )
        let attendeeCount = event.attendees?.count ?? 0
        guard MeetingDetector.qualifies(joinURL: joinURL, attendeeCount: attendeeCount, onlyWithLinks: onlyWithLinks) else {
            return nil
        }
        let color = event.calendar.cgColor.flatMap(NSColor.init(cgColor:)) ?? .secondaryLabelColor
        return Meeting(
            eventID: event.eventIdentifier,
            title: event.title?.isEmpty == false ? event.title! : "Untitled event",
            start: event.startDate,
            end: event.endDate,
            calendarIdentifier: event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            calendarColor: color,
            joinURL: joinURL,
            attendeeCount: attendeeCount
        )
    }

    private func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    @objc private func eventStoreChanged() {
        refresh()
    }

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func requestNotificationAuthorization() {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleNotifications(now: Date) {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        let notificationMeetings = upcomingMeetings.filter {
            $0.start > now && $0.start <= now.addingTimeInterval(24 * 60 * 60)
        }
        let currentIDs = Set(notificationMeetings.map(notificationIdentifier))
        center.getPendingNotificationRequests { [weak self] requests in
            Task { @MainActor in
                guard let self else { return }
                let staleIDs = requests.map(\.identifier).filter {
                    $0.hasPrefix("meeting-") && !currentIDs.contains($0)
                }
                center.removePendingNotificationRequests(withIdentifiers: staleIDs)
                self.addNotifications(for: notificationMeetings, now: now, center: center)
            }
        }
    }

    private func notificationIdentifier(for meeting: Meeting) -> String {
        "meeting-\(meeting.eventID)-\(Int(meeting.start.timeIntervalSince1970))"
    }

    private func addNotifications(for meetings: [Meeting], now: Date, center: UNUserNotificationCenter) {
        for meeting in meetings {
            let identifier = notificationIdentifier(for: meeting)
            let content = UNMutableNotificationContent()
            content.title = "Upcoming meeting"
            // The body is read at delivery time (leadMinutes before start), so
            // the countdown must reflect the lead, not the scheduling moment.
            content.body = "\(meeting.title) \(startText(forLeadMinutes: leadMinutes))."
            content.sound = .default
            content.categoryIdentifier = "MEETING_START"
            if let joinURL = meeting.joinURL {
                content.userInfo["joinURL"] = joinURL.absoluteString
            }
            let fireDate = meeting.start.addingTimeInterval(-Double(leadMinutes * 60))
            guard fireDate > now else { continue }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDate.timeIntervalSince(now), repeats: false)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }

    private func startText(forLeadMinutes minutes: Int) -> String {
        switch minutes {
        case ..<1: return "starts now"
        case 1: return "starts in 1 minute"
        default: return "starts in \(minutes) minutes"
        }
    }

    private func removeCalendarNotifications() {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix("meeting-") })
        }
    }
}
