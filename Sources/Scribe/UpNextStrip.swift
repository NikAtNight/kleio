import AppKit
import SwiftUI

struct UpNextStrip: View {
    @EnvironmentObject private var calendarSync: CalendarSync

    private var todaysMeetings: [Meeting] {
        calendarSync.upcomingMeetings.filter { Calendar.current.isDateInToday($0.start) }
    }

    var body: some View {
        if calendarSync.isEnabled && !todaysMeetings.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(todaysMeetings) { meeting in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(nsColor: meeting.calendarColor))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.start, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(meeting.title)
                                    .lineLimit(1)
                            }
                            if let joinURL = meeting.joinURL {
                                Button("Join") { NSWorkspace.shared.open(joinURL) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }
}
