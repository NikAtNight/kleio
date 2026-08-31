import AppKit
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject private var calendarSync: CalendarSync
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var recording: RecordingSession

    let meetingID: String

    private var meeting: Meeting? {
        calendarSync.upcomingMeetings.first { $0.id == meetingID }
    }

    var body: some View {
        Group {
            if let meeting {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header(for: meeting)
                        actions(for: meeting)
                        detailsCard(for: meeting)
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "This meeting has passed",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Choose another upcoming meeting from the sidebar.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paperBackground)
    }

    private func header(for meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(Theme.displayTitle())
                .textSelection(.enabled)

            Text(metadata(for: meeting))
                .font(Theme.metaValue)
                .foregroundStyle(.secondary)
        }
    }

    private func actions(for meeting: Meeting) -> some View {
        HStack(spacing: 10) {
            Button {
                if let joinURL = meeting.joinURL {
                    NSWorkspace.shared.open(joinURL)
                }
                Task {
                    // Passing the event names the recording after the meeting
                    // and links it for attendee speaker suggestions.
                    await recording.start(
                        mode: .meeting,
                        library: library,
                        calendarEvent: AutoRecordEvent(
                            eventID: meeting.eventID,
                            title: meeting.title,
                            start: meeting.start,
                            end: meeting.end,
                            joinURL: meeting.joinURL
                        )
                    )
                }
            } label: {
                Label("Join & Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button("Open in Calendar") {
                if let calendarURL = URL(string: "ical://") {
                    NSWorkspace.shared.open(calendarURL)
                }
            }
            .buttonStyle(.bordered)

            Button("Copy Link") {
                guard let joinURL = meeting.joinURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(joinURL.absoluteString, forType: .string)
            }
            .buttonStyle(.bordered)
            .disabled(meeting.joinURL == nil)
        }
    }

    private func detailsCard(for meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            detailRow(label: "WHEN") {
                Text(whenText(for: meeting))
                    .textSelection(.enabled)
            }

            detailRow(label: "WHERE") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(MeetingPresentation.providerName(for: meeting.joinURL) ?? meeting.location ?? meeting.calendarTitle)
                    if let joinURL = meeting.joinURL {
                        Link(joinURL.absoluteString, destination: joinURL)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            detailRow(label: "ATTENDEES") {
                Text(attendeeText(for: meeting))
            }

            detailRow(label: "DESCRIPTION") {
                if let notes = meeting.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    ScrollView(.vertical) {
                        Text(notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 140)
                } else {
                    Text("No description")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private func detailRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(Theme.metaLabel)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadata(for meeting: Meeting) -> String {
        let provider = MeetingPresentation.providerName(for: meeting.joinURL) ?? meeting.calendarTitle
        return "\(MeetingPresentation.relativeStart(for: meeting.start)) · \(MeetingPresentation.duration(from: meeting.start, to: meeting.end)) · \(provider)"
    }

    private func whenText(for meeting: Meeting) -> String {
        let date = meeting.start.formatted(.dateTime.weekday(.wide).month().day().year())
        let start = meeting.start.formatted(date: .omitted, time: .shortened)
        let end = meeting.end.formatted(date: .omitted, time: .shortened)
        return "\(date), \(start) to \(end)"
    }

    private func attendeeText(for meeting: Meeting) -> String {
        switch meeting.attendeeCount {
        case 0: "No attendees listed"
        case 1: "1 attendee"
        default: "\(meeting.attendeeCount) attendees"
        }
    }
}

enum MeetingPresentation {
    static func relativeStart(for date: Date, now: Date = Date()) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.down))
        guard minutes > 0 else { return "now" }

        if minutes < 60 {
            return "in \(max(1, minutes))m"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0 ? "in \(hours)h" : "in \(hours)h \(remainingMinutes)m"
        }

        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "in \(days)d" : "in \(days)d \(remainingHours)h"
    }

    static func duration(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int((end.timeIntervalSince(start) / 60).rounded()))
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 { return "\(remainingMinutes)m" }
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    static func providerName(for joinURL: URL?) -> String? {
        guard let joinURL else { return nil }
        if joinURL.scheme?.lowercased() == "facetime" { return "FaceTime" }

        let host = joinURL.host?.lowercased() ?? ""
        if host.contains("zoom.us") { return "Zoom" }
        if host.contains("meet.google.com") { return "Meet" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        return nil
    }
}
